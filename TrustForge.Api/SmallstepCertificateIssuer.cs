using System.Net.Security;
using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Certes;
using Certes.Acme;
using Certes.Acme.Resource;
using Certes.Jws;
using Microsoft.Extensions.Options;
using TrustForge.Core.CertificateJobs;
using TrustForge.Core.Security;

namespace TrustForge.Api;

public sealed class SmallstepCertificateIssuer(
    ISecretResolver secretResolver,
    IOptions<SmallstepAcmeOptions> options,
    ILogger<SmallstepCertificateIssuer> logger) : ICertificateIssuer
{
    private const string AccountDoesNotExist = "urn:ietf:params:acme:error:accountDoesNotExist";
    private static readonly JsonSerializerOptions JwsJsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private readonly SmallstepAcmeOptions _options = options.Value;

    public async Task<string> CreateOrResumeOrderAsync(
        Guid jobId,
        string? persistedOrderUrl,
        string csrPem,
        IReadOnlyList<string> identifiers,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (identifiers.Count == 0 || identifiers.Any(name => string.IsNullOrWhiteSpace(name) || IPAddress.TryParse(name, out _)))
            throw new InvalidOperationException("Smallstep DNS-01 orders require DNS identifiers; IP identifiers are unsupported.");
        if (string.IsNullOrWhiteSpace(csrPem))
            throw new ArgumentException("A target-generated CSR is required.", nameof(csrPem));
        string[] requestedIdentifiers = [.. identifiers.Select(name => name.Trim()).Distinct(StringComparer.OrdinalIgnoreCase)];

        await using AcmeSession session = await CreateSessionAsync(cancellationToken);
        await EnsureAccountAsync(session.Context, cancellationToken);

        if (persistedOrderUrl is not null)
        {
            Uri orderUri = ValidateResourceUrl(persistedOrderUrl, "ACME order URL");
            Order persisted = await session.Context.Order(orderUri).Resource();
            if (persisted.Status == OrderStatus.Invalid)
                throw new InvalidOperationException($"The persisted ACME order '{orderUri}' is invalid; create a new certificate job.");
            if (!IdentifiersMatch(persisted, requestedIdentifiers))
                throw new InvalidOperationException("The persisted ACME order identifiers do not match the approved service SANs.");
            return orderUri.ToString();
        }

        Uri? reconciled = await FindReconcilableOrderAsync(session, requestedIdentifiers, cancellationToken);
        if (reconciled is not null)
        {
            logger.LogInformation("Reconciled existing ACME order {OrderUrl} for job {JobId} instead of creating a duplicate.", reconciled, jobId);
            return reconciled.ToString();
        }

        IOrderContext order = await session.Context.NewOrder(requestedIdentifiers.ToList());
        if (order.Location is null)
            throw new InvalidOperationException($"ACME server returned no order URL for job '{jobId}'.");
        Order created = await order.Resource();
        if (!IdentifiersMatch(created, requestedIdentifiers))
            throw new InvalidOperationException("The ACME order identifiers returned by the CA do not match the approved service SANs.");
        return order.Location.ToString();
    }

    private async Task<Uri?> FindReconcilableOrderAsync(AcmeSession session, string[] requestedIdentifiers, CancellationToken cancellationToken)
    {
        Certes.Acme.Resource.Account account = await (await session.Context.Account()).Resource();
        if (account.Orders is null)
            return null;

        List<Uri> orderUrls = await ListAccountOrderUrlsAsync(session, account.Orders, cancellationToken);
        DateTimeOffset now = DateTimeOffset.UtcNow;
        // step-ca lists orders oldest-first; only recent pending/ready orders can belong to an interrupted job.
        foreach (Uri orderUrl in orderUrls.AsEnumerable().Reverse().Take(100))
        {
            cancellationToken.ThrowIfCancellationRequested();
            Order candidate = await session.Context.Order(orderUrl).Resource();
            if (candidate.Status is not (OrderStatus.Pending or OrderStatus.Ready))
                continue;
            if (candidate.Expires is DateTimeOffset expires && expires <= now)
                continue;
            if (IdentifiersMatch(candidate, requestedIdentifiers))
                return orderUrl;
        }
        return null;
    }

    private async Task<List<Uri>> ListAccountOrderUrlsAsync(AcmeSession session, Uri ordersUrl, CancellationToken cancellationToken)
    {
        List<Uri> orderUrls = [];
        Uri? next = ordersUrl;
        for (int page = 0; page < 10 && next is not null; page++)
        {
            using HttpResponseMessage response = await PostAsGetAsync(session, next, cancellationToken);
            using JsonDocument document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
            // step-ca returns a bare JSON array; RFC 8555 servers wrap it in an "orders" property.
            JsonElement orders = document.RootElement.ValueKind == JsonValueKind.Array
                ? document.RootElement
                : document.RootElement.GetProperty("orders");
            foreach (JsonElement item in orders.EnumerateArray())
                if (item.ValueKind == JsonValueKind.String && Uri.TryCreate(item.GetString(), UriKind.Absolute, out Uri? orderUrl))
                    orderUrls.Add(orderUrl);
            next = response.Headers.TryGetValues("Link", out IEnumerable<string>? links) ? ParseNextLink(links) : null;
        }
        return orderUrls;
    }

    private static async Task<HttpResponseMessage> PostAsGetAsync(AcmeSession session, Uri url, CancellationToken cancellationToken)
    {
        for (int attempt = 0; ; attempt++)
        {
            JwsPayload payload = await session.Context.Sign(null, url);
            // step-ca rejects Content-Type with a charset parameter; send bare application/jose+json.
            ByteArrayContent content = new(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload, JwsJsonOptions)));
            content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/jose+json");
            using HttpRequestMessage request = new(HttpMethod.Post, url) { Content = content };
            HttpResponseMessage response = await session.HttpClient.SendAsync(request, cancellationToken);
            if (response.IsSuccessStatusCode)
                return response;
            string body = await response.Content.ReadAsStringAsync(cancellationToken);
            int statusCode = (int)response.StatusCode;
            response.Dispose();
            if (attempt == 0 && body.Contains("urn:ietf:params:acme:error:badNonce", StringComparison.Ordinal))
                continue;
            throw new InvalidOperationException($"The ACME account order listing failed (HTTP {statusCode}): {(body.Length > 500 ? body[..500] : body)}");
        }
    }

    private static Uri? ParseNextLink(IEnumerable<string> linkHeaders)
    {
        foreach (string header in linkHeaders)
            foreach (string part in header.Split(','))
            {
                string[] segments = part.Split(';');
                if (segments.Length < 2)
                    continue;
                bool isNext = segments.Skip(1).Any(segment =>
                    segment.Trim().Replace("\"", string.Empty, StringComparison.Ordinal).Equals("rel=next", StringComparison.OrdinalIgnoreCase));
                string target = segments[0].Trim();
                if (isNext && target.StartsWith('<') && target.EndsWith('>')
                    && Uri.TryCreate(target[1..^1], UriKind.Absolute, out Uri? next))
                    return next;
            }
        return null;
    }

    private static bool IdentifiersMatch(Order order, string[] requestedIdentifiers)
    {
        if (order.Identifiers is null || order.Identifiers.Count != requestedIdentifiers.Length)
            return false;
        HashSet<string> requested = requestedIdentifiers.Select(NormalizeIdentifier).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (Identifier identifier in order.Identifiers)
        {
            if (identifier.Type != IdentifierType.Dns)
                return false;
            if (!requested.Remove(NormalizeIdentifier(identifier.Value)))
                return false;
        }
        return requested.Count == 0;
    }

    private static string NormalizeIdentifier(string value) => value.Trim().TrimEnd('.');

    public async Task<IReadOnlyList<Dns01Challenge>> GetDns01ChallengesAsync(string orderUrl, CancellationToken cancellationToken = default)
    {
        await using AcmeSession session = await CreateSessionAsync(cancellationToken);
        await EnsureAccountAsync(session.Context, cancellationToken);
        IOrderContext order = session.Context.Order(ValidateResourceUrl(orderUrl, "ACME order URL"));
        List<Dns01Challenge> challenges = [];
        int authorizationCount = 0;
        foreach (IAuthorizationContext authorizationContext in await order.Authorizations())
        {
            cancellationToken.ThrowIfCancellationRequested();
            authorizationCount++;
            Certes.Acme.Resource.Authorization authorization = await authorizationContext.Resource();
            if (authorization.Status == AuthorizationStatus.Valid)
                continue;
            if (authorization.Status == AuthorizationStatus.Invalid)
                throw new InvalidOperationException("An ACME authorization is already invalid.");

            IChallengeContext challenge = await authorizationContext.Dns();
            string identifier = authorization.Identifier.Value;
            if (identifier.StartsWith("*.", StringComparison.Ordinal))
                identifier = identifier[2..];
            challenges.Add(new Dns01Challenge(
                authorizationContext.Location.ToString(),
                $"_acme-challenge.{identifier.TrimEnd('.')}",
                session.Context.AccountKey.DnsTxt(challenge.Token)));
        }

        if (authorizationCount == 0)
            throw new InvalidOperationException("The ACME order has no authorizations.");
        // An empty list means every authorization is already valid; a resumed job must advance, not fail.
        return challenges;
    }

    public async Task TriggerDnsAuthorizationAsync(string orderUrl, string authorizationUrl, CancellationToken cancellationToken = default)
    {
        await using AcmeSession session = await CreateSessionAsync(cancellationToken);
        await EnsureAccountAsync(session.Context, cancellationToken);
        _ = session.Context.Order(ValidateResourceUrl(orderUrl, "ACME order URL"));
        IAuthorizationContext authorization = session.Context.Authorization(ValidateResourceUrl(authorizationUrl, "ACME authorization URL"));
        Certes.Acme.Resource.Authorization resource = await authorization.Resource();
        if (resource.Status == AuthorizationStatus.Valid)
            return;
        if (resource.Status != AuthorizationStatus.Pending)
            throw new InvalidOperationException($"ACME authorization cannot be triggered from state '{resource.Status}'.");

        IChallengeContext challenge = await authorization.Dns();
        _ = await challenge.Validate();
    }

    public async Task WaitForAuthorizationAsync(string orderUrl, string authorizationUrl, CancellationToken cancellationToken = default)
    {
        await using AcmeSession session = await CreateSessionAsync(cancellationToken);
        await EnsureAccountAsync(session.Context, cancellationToken);
        _ = session.Context.Order(ValidateResourceUrl(orderUrl, "ACME order URL"));
        IAuthorizationContext authorization = session.Context.Authorization(ValidateResourceUrl(authorizationUrl, "ACME authorization URL"));
        DateTimeOffset deadline = DateTimeOffset.UtcNow + _options.AuthorizationTimeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Certes.Acme.Resource.Authorization resource = await authorization.Resource();
            if (resource.Status == AuthorizationStatus.Valid)
                return;
            if (resource.Status != AuthorizationStatus.Pending)
                throw new InvalidOperationException($"ACME authorization ended in state '{resource.Status}'.");
            await Task.Delay(_options.PollInterval, cancellationToken);
        }

        throw new TimeoutException("Timed out waiting for Smallstep ACME DNS-01 authorization.");
    }

    public async Task<IssuedCertificateBundle> FinalizeAndDownloadAsync(
        string orderUrl,
        string csrPem,
        CancellationToken cancellationToken = default)
    {
        await using AcmeSession session = await CreateSessionAsync(cancellationToken);
        await EnsureAccountAsync(session.Context, cancellationToken);
        IOrderContext order = session.Context.Order(ValidateResourceUrl(orderUrl, "ACME order URL"));
        Order resource = await order.Resource();
        if (resource.Status is OrderStatus.Ready or OrderStatus.Pending)
            _ = await order.Finalize(ParseCsrPem(csrPem));
        else if (resource.Status is not (OrderStatus.Processing or OrderStatus.Valid))
            throw new InvalidOperationException($"ACME order cannot be finalized from state '{resource.Status}'.");

        DateTimeOffset deadline = DateTimeOffset.UtcNow + _options.AuthorizationTimeout;
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            resource = await order.Resource();
            if (resource.Status == OrderStatus.Valid)
                break;
            if (resource.Status != OrderStatus.Processing || DateTimeOffset.UtcNow >= deadline)
                throw new InvalidOperationException($"ACME order did not become valid (state '{resource.Status}').");
            await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(order.RetryAfter, 1, 10)), cancellationToken);
        }

        CertificateChain chain = await order.Download();
        string chainPem = chain.ToPem();
        using X509Certificate2 leaf = X509Certificate2.CreateFromPem(chainPem);
        string fingerprint = Convert.ToHexString(leaf.GetCertHash(HashAlgorithmName.SHA256));
        logger.LogInformation("Smallstep issued certificate with fingerprint {CertificateFingerprint}.", fingerprint);
        return new IssuedCertificateBundle(
            leaf.ExportCertificatePem(),
            chainPem,
            fingerprint,
            new DateTimeOffset(leaf.NotBefore.ToUniversalTime()),
            new DateTimeOffset(leaf.NotAfter.ToUniversalTime()));
    }

    private async Task<AcmeSession> CreateSessionAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!Uri.TryCreate(_options.DirectoryUrl, UriKind.Absolute, out Uri? directory)
            || directory.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("Configure SmallstepAcme:DirectoryUrl as an HTTPS ACME directory URL.");
        if (string.IsNullOrWhiteSpace(_options.AccountKeySecretRef))
            throw new InvalidOperationException("Configure SmallstepAcme:AccountKeySecretRef to a protected secret reference.");
        if (_options.HttpTimeout <= TimeSpan.Zero || _options.AuthorizationTimeout <= TimeSpan.Zero || _options.PollInterval <= TimeSpan.Zero)
            throw new InvalidOperationException("Smallstep ACME timeouts and poll interval must be positive.");

        string accountKeyPem = await secretResolver.ResolveAsync(_options.AccountKeySecretRef, cancellationToken);
        IKey accountKey = KeyFactory.FromPem(accountKeyPem);
        HttpClientHandler handler = new();
        X509Certificate2? rootCertificate = null;
        if (!string.IsNullOrWhiteSpace(_options.RootCertificatePath))
        {
            rootCertificate = SmallstepRootCertificate.Load(_options.RootCertificatePath);
            handler.ServerCertificateCustomValidationCallback = (_, certificate, presentedChain, errors) =>
                ValidateServerCertificate(certificate, presentedChain, errors, rootCertificate);
        }

        HttpClient client = new(handler, disposeHandler: true) { Timeout = _options.HttpTimeout };
        AcmeContext context = new(directory, accountKey, new AcmeHttpClient(directory, client));
        await context.GetDirectory();
        return new AcmeSession(context, client, rootCertificate);
    }

    private async Task EnsureAccountAsync(AcmeContext context, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            _ = await context.Account();
            return;
        }
        catch (AcmeRequestException exception) when (exception.Error?.Type == AccountDoesNotExist)
        {
            if (string.IsNullOrWhiteSpace(_options.AccountEmail))
                throw new InvalidOperationException("Configure SmallstepAcme:AccountEmail to register the ACME account.");
        }

        string? eabSecret = null;
        if (!string.IsNullOrWhiteSpace(_options.EabKeyId) || !string.IsNullOrWhiteSpace(_options.EabKeySecretRef))
        {
            if (string.IsNullOrWhiteSpace(_options.EabKeyId) || string.IsNullOrWhiteSpace(_options.EabKeySecretRef))
                throw new InvalidOperationException("Both SmallstepAcme:EabKeyId and EabKeySecretRef must be configured together.");
            eabSecret = await secretResolver.ResolveAsync(_options.EabKeySecretRef, cancellationToken);
            if (_options.EabKeyAlgorithm is not ("HS256" or "HS384" or "HS512"))
                throw new InvalidOperationException("SmallstepAcme:EabKeyAlgorithm must be HS256, HS384, or HS512.");
        }

        try
        {
            _ = await context.NewAccount(
                [$"mailto:{_options.AccountEmail!.Trim()}"],
                true,
                _options.EabKeyId,
                eabSecret,
                _options.EabKeyAlgorithm);
        }
        catch (AcmeRequestException)
        {
            // Concurrent first-use requests may register the same account key. Verify it now exists.
            _ = await context.Account();
        }
    }

    internal static bool ValidateServerCertificate(
        X509Certificate? certificate,
        X509Chain? presentedChain,
        SslPolicyErrors errors,
        X509Certificate2 rootCertificate)
    {
        if (certificate is null)
            return false;
        if (errors == SslPolicyErrors.None)
            return true;
        if (errors != SslPolicyErrors.RemoteCertificateChainErrors)
            return false;

        using X509Certificate2 leaf = new(certificate);
        using X509Chain chain = new();
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        chain.ChainPolicy.CustomTrustStore.Add(rootCertificate);
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        if (presentedChain is not null)
        {
            foreach (X509ChainElement element in presentedChain.ChainElements.Cast<X509ChainElement>().Skip(1))
                chain.ChainPolicy.ExtraStore.Add(element.Certificate);
        }
        return chain.Build(leaf);
    }

    private static Uri ValidateResourceUrl(string value, string description)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out Uri? uri) || uri.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException($"The persisted {description} is not a valid HTTPS URL.");
        return uri;
    }

    private static byte[] ParseCsrPem(string pem)
    {
        string normalized = pem.Replace("\r", string.Empty, StringComparison.Ordinal);
        const string begin = "-----BEGIN CERTIFICATE REQUEST-----";
        const string end = "-----END CERTIFICATE REQUEST-----";
        int beginIndex = normalized.IndexOf(begin, StringComparison.Ordinal);
        int endIndex = normalized.IndexOf(end, StringComparison.Ordinal);
        if (beginIndex < 0 || endIndex <= beginIndex)
            throw new InvalidOperationException("The remote host returned an invalid PEM certificate signing request.");
        string base64 = string.Concat(normalized[(beginIndex + begin.Length)..endIndex].Where(character => !char.IsWhiteSpace(character)));
        return Convert.FromBase64String(base64);
    }

    private sealed class AcmeSession(AcmeContext context, HttpClient httpClient, X509Certificate2? rootCertificate) : IAsyncDisposable
    {
        public AcmeContext Context { get; } = context;
        public HttpClient HttpClient { get; } = httpClient;

        public ValueTask DisposeAsync()
        {
            HttpClient.Dispose();
            rootCertificate?.Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
