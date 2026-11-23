using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Certes;
using Certes.Acme;
using Certes.Jws;
using Microsoft.Extensions.Options;
using TrustForge.Core.Revocation;
using TrustForge.Core.Security;

namespace TrustForge.Api;

/// <summary>
/// Revokes certificates at the Smallstep CA over the ACME <c>revoke-cert</c> endpoint, authorized by the
/// same ACME account key that issued them. step-ca rejects other authorizations, so the target service
/// private key is never needed and never leaves its host.
/// </summary>
public sealed class SmallstepCertificateRevoker(
    ISecretResolver secretResolver,
    IOptions<SmallstepAcmeOptions> options,
    ILogger<SmallstepCertificateRevoker> logger) : ICertificateRevocationChannel
{
    private const string AlreadyRevoked = "urn:ietf:params:acme:error:alreadyRevoked";
    private static readonly JsonSerializerOptions JwsJsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private readonly SmallstepAcmeOptions _options = options.Value;

    public async Task<RevocationReceipt> RevokeAsync(
        string certificatePem,
        CertificateRevocationReason reason,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentException.ThrowIfNullOrWhiteSpace(certificatePem);
        if (!Uri.TryCreate(_options.DirectoryUrl, UriKind.Absolute, out Uri? directory) || directory.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("Configure SmallstepAcme:DirectoryUrl as an HTTPS ACME directory URL.");
        if (string.IsNullOrWhiteSpace(_options.AccountKeySecretRef))
            throw new InvalidOperationException("Configure SmallstepAcme:AccountKeySecretRef to a protected secret reference.");

        byte[] der;
        using (X509Certificate2 leaf = X509Certificate2.CreateFromPem(certificatePem))
            der = leaf.RawData;

        string accountKeyPem = await secretResolver.ResolveAsync(_options.AccountKeySecretRef, cancellationToken);
        IKey accountKey = KeyFactory.FromPem(accountKeyPem);
        HttpClientHandler handler = new();
        X509Certificate2? rootCertificate = null;
        if (!string.IsNullOrWhiteSpace(_options.RootCertificatePath))
        {
            rootCertificate = SmallstepRootCertificate.Load(_options.RootCertificatePath);
            handler.ServerCertificateCustomValidationCallback = (_, certificate, presentedChain, errors) =>
                SmallstepCertificateIssuer.ValidateServerCertificate(certificate, presentedChain, errors, rootCertificate);
        }

        try
        {
            HttpClient client = new(handler, disposeHandler: true) { Timeout = _options.HttpTimeout };
            AcmeContext context = new(directory, accountKey, new AcmeHttpClient(directory, client));
            await context.GetDirectory();
            // Certes derives the JWS kid from the account location, which step-ca matches literally.
            _ = await context.Account();

            Uri revokeUrl = await ReadRevokeCertificateUrlAsync(client, directory, cancellationToken);
            // RFC 8555 section 7.6. Certes serializes and base64url-encodes the payload object itself, so it
            // must not be pre-serialized here: a JSON string would be encoded twice and the CA would reject it.
            Dictionary<string, object> payload = new()
            {
                ["resource"] = "revokeCert",
                ["certificate"] = ToBase64Url(der),
                ["reason"] = (int)reason,
            };

            return await PostRevocationAsync(context, client, revokeUrl, payload, cancellationToken);
        }
        finally
        {
            rootCertificate?.Dispose();
        }
    }

    private static async Task<Uri> ReadRevokeCertificateUrlAsync(HttpClient client, Uri directory, CancellationToken cancellationToken)
    {
        // The revoke URL is read from the directory rather than derived from the configured path, so a CA
        // that nests or renames its ACME prefixes stays supported.
        using HttpResponseMessage response = await client.GetAsync(directory, cancellationToken);
        response.EnsureSuccessStatusCode();
        using JsonDocument document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
        if (!document.RootElement.TryGetProperty("revokeCert", out JsonElement value)
            || !Uri.TryCreate(value.GetString(), UriKind.Absolute, out Uri? revokeUrl)
            || revokeUrl.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("The ACME directory exposes no HTTPS revokeCert URL; the CA provisioner cannot revoke.");
        return revokeUrl;
    }

    private async Task<RevocationReceipt> PostRevocationAsync(AcmeContext context, HttpClient client, Uri url, object payload, CancellationToken cancellationToken)
    {
        for (int attempt = 0; ; attempt++)
        {
            JwsPayload signed = await context.Sign(payload, url);
            // step-ca rejects Content-Type with a charset parameter; send bare application/jose+json.
            ByteArrayContent content = new(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(signed, JwsJsonOptions)));
            content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/jose+json");
            using HttpRequestMessage request = new(HttpMethod.Post, url) { Content = content };
            HttpResponseMessage response = await client.SendAsync(request, cancellationToken);
            string body = await response.Content.ReadAsStringAsync(cancellationToken);
            int statusCode = (int)response.StatusCode;
            response.Dispose();

            if (statusCode == 200)
            {
                logger.LogInformation("Revoked a certificate at the CA through the ACME account.");
                return new RevocationReceipt(false, DateTimeOffset.UtcNow);
            }

            if (attempt == 0 && body.Contains("urn:ietf:params:acme:error:badNonce", StringComparison.Ordinal))
                continue;
            if (body.Contains(AlreadyRevoked, StringComparison.Ordinal))
            {
                logger.LogInformation("The CA reports this certificate as already revoked; treating the revocation as complete.");
                return new RevocationReceipt(true, DateTimeOffset.UtcNow);
            }

            throw new InvalidOperationException($"The ACME revocation request failed (HTTP {statusCode}): {(body.Length > 500 ? body[..500] : body)}");
        }
    }

    private static string ToBase64Url(byte[] value) =>
        Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
