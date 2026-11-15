using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Renci.SshNet;
using Renci.SshNet.Common;
using TrustForge.Core.CertificateJobs;
using TrustForge.Core.ManagedServices;
using TrustForge.Core.Security;

namespace TrustForge.Api;

/// <summary>
/// SSH.NET adapter for the fixed, root-owned TrustForge remote helper. The helper owns
/// private-key generation, atomic release switching, service reload, health checks and rollback.
/// </summary>
public sealed class SshLinuxCertificateDeployer(ISecretResolver secrets) : ILinuxCertificateDeployer
{
    private const string HelperCommand = "sudo -n /usr/local/sbin/trustforge-certctl";
    private const int MaxResponseBytes = 2 * 1024 * 1024;

    public async Task ConnectAndValidateAsync(ManagedService service, CancellationToken cancellationToken = default)
    {
        using SshClient client = await ConnectAsync(service, cancellationToken);
        _ = await InvokeAsync<HelperResponse>(client, new("validate", service.Id), cancellationToken);
    }

    public async Task<string> GenerateCsrAsync(ManagedService service, Guid jobId, CancellationToken cancellationToken = default)
    {
        using SshClient client = await ConnectAsync(service, cancellationToken);
        HelperResponse response = await InvokeAsync<HelperResponse>(client,
            new("generate-csr", service.Id, jobId, Sans: service.Sans.ToArray()), cancellationToken);
        return Required(response.CsrPem, "Remote helper did not return a CSR.");
    }

    public async Task<string> StageAsync(ManagedService service, Guid jobId, IssuedCertificateBundle certificate, CancellationToken cancellationToken = default)
    {
        using SshClient client = await ConnectAsync(service, cancellationToken);
        HelperResponse response = await InvokeAsync<HelperResponse>(client, new(
            "stage", service.Id, jobId,
            LeafCertificatePem: certificate.LeafCertificatePem,
            ChainPem: certificate.ChainPem,
            FingerprintSha256: certificate.FingerprintSha256,
            NotBefore: certificate.NotBefore,
            NotAfter: certificate.NotAfter), cancellationToken);
        return Required(response.ReleaseId, "Remote helper did not return a staged release ID.");
    }

    public async Task<string?> ActivateAsync(ManagedService service, Guid jobId, string releaseId, CancellationToken cancellationToken = default)
    {
        using SshClient client = await ConnectAsync(service, cancellationToken);
        HelperResponse response = await InvokeAsync<HelperResponse>(client, new("activate", service.Id, jobId, releaseId), cancellationToken);
        return response.PreviousReleaseId;
    }

    public async Task VerifyAsync(ManagedService service, Guid jobId, string releaseId, string expectedFingerprint, CancellationToken cancellationToken = default)
    {
        using SshClient client = await ConnectAsync(service, cancellationToken);
        _ = await InvokeAsync<HelperResponse>(client, new("verify", service.Id, jobId, releaseId, expectedFingerprint), cancellationToken);
    }

    public async Task<string?> RollbackAsync(ManagedService service, Guid jobId, string releaseId, CancellationToken cancellationToken = default)
    {
        using SshClient client = await ConnectAsync(service, cancellationToken);
        HelperResponse response = await InvokeAsync<HelperResponse>(client, new("rollback", service.Id, jobId, releaseId), cancellationToken);
        return response.PreviousReleaseId;
    }

    public async Task PruneReleasesAsync(ManagedService service, int retainedReleases, CancellationToken cancellationToken = default)
    {
        using SshClient client = await ConnectAsync(service, cancellationToken);
        _ = await InvokeAsync<HelperResponse>(client, new("prune", service.Id, RetainedReleases: retainedReleases), cancellationToken);
    }

    private async Task<SshClient> ConnectAsync(ManagedService service, CancellationToken cancellationToken)
    {
        SshCredential credential = JsonSerializer.Deserialize<SshCredential>(
            await secrets.ResolveAsync(service.SshCredentialRef, cancellationToken), JsonOptions)
            ?? throw new InvalidOperationException("SSH credential secret must be a JSON object.");
        if (string.IsNullOrWhiteSpace(credential.Username) || string.IsNullOrWhiteSpace(credential.PrivateKeyPem))
            throw new InvalidOperationException("SSH credential secret requires username and privateKeyPem.");

        using MemoryStream keyStream = new(Encoding.UTF8.GetBytes(credential.PrivateKeyPem));
        PrivateKeyFile key = credential.Passphrase is null ? new PrivateKeyFile(keyStream) : new PrivateKeyFile(keyStream, credential.Passphrase);
        Renci.SshNet.ConnectionInfo connection = new(service.Host, service.Port, credential.Username, new PrivateKeyAuthenticationMethod(credential.Username, key))
        {
            Timeout = TimeSpan.FromSeconds(20)
        };
        SshClient client = new(connection);
        string expectedFingerprint = service.HostKeyFingerprint["SHA256:".Length..];
        client.HostKeyReceived += (_, args) => args.CanTrust = CryptographicOperations.FixedTimeEquals(
            Encoding.ASCII.GetBytes(args.FingerPrintSHA256), Encoding.ASCII.GetBytes(expectedFingerprint));
        try
        {
            await client.ConnectAsync(cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            return client;
        }
        catch
        {
            client.Dispose();
            throw;
        }
    }

    private static async Task<T> InvokeAsync<T>(SshClient client, HelperRequest request, CancellationToken cancellationToken)
    {
        using SshCommand command = client.CreateCommand(HelperCommand);
        // SSH.NET only exposes the input stream while the command is executing; the helper blocks on stdin until EOF.
        Task execute = command.ExecuteAsync(cancellationToken);
        using Stream input = command.CreateInputStream();
        byte[] requestBytes = JsonSerializer.SerializeToUtf8Bytes(request, JsonOptions);
        await input.WriteAsync(requestBytes, cancellationToken);
        await input.FlushAsync(cancellationToken);
        input.Close();
        await execute;
        string output = command.Result;
        if (command.ExitStatus != 0)
            // The helper reports failures as JSON on stdout with exit 1; stderr is usually empty.
            throw new InvalidOperationException($"TrustForge remote helper failed (exit {command.ExitStatus}): {Limit(command.Error + output, 2048)}");
        if (Encoding.UTF8.GetByteCount(output) > MaxResponseBytes)
            throw new InvalidOperationException("TrustForge remote helper response exceeded the configured size limit.");
        HelperResponse response = JsonSerializer.Deserialize<HelperResponse>(output, JsonOptions)
            ?? throw new InvalidOperationException("TrustForge remote helper returned an empty response.");
        if (!response.Success)
            throw new InvalidOperationException($"TrustForge remote helper rejected the operation: {Limit(response.Error ?? "unspecified error", 2048)}");
        return response is T result ? result : throw new InvalidOperationException("Unexpected remote helper response type.");
    }

    private static string Required(string? value, string message) =>
        string.IsNullOrWhiteSpace(value) ? throw new InvalidOperationException(message) : value;

    private static string Limit(string value, int maxLength) => value.Length <= maxLength ? value : value[..maxLength];

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private sealed record SshCredential(string Username, string PrivateKeyPem, string? Passphrase);
    private sealed record HelperRequest(
        string Operation,
        Guid ServiceId,
        Guid? JobId = null,
        string? ReleaseId = null,
        string? ExpectedFingerprint = null,
        string[]? Sans = null,
        string? LeafCertificatePem = null,
        string? ChainPem = null,
        string? FingerprintSha256 = null,
        DateTimeOffset? NotBefore = null,
        DateTimeOffset? NotAfter = null,
        int? RetainedReleases = null);
    private sealed record HelperResponse(
        bool Success,
        string? Error = null,
        string? CsrPem = null,
        string? ReleaseId = null,
        string? PreviousReleaseId = null);
}
