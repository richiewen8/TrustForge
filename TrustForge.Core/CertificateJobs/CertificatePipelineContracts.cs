using TrustForge.Core.ManagedServices;

namespace TrustForge.Core.CertificateJobs;

public sealed record Dns01Challenge(string AuthorizationUrl, string RecordName, string TxtValue);

public sealed record IssuedCertificateBundle(
    string LeafCertificatePem,
    string ChainPem,
    string FingerprintSha256,
    DateTimeOffset NotBefore,
    DateTimeOffset NotAfter);

/// <summary>Creates/reconciles an ACME order, exposes its DNS-01 authorization, and finalizes the CSR.</summary>
public interface ICertificateIssuer
{
    Task<string> CreateOrResumeOrderAsync(
        Guid jobId,
        string? persistedOrderUrl,
        string csrPem,
        IReadOnlyList<string> identifiers,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<Dns01Challenge>> GetDns01ChallengesAsync(string orderUrl, CancellationToken cancellationToken = default);

    Task TriggerDnsAuthorizationAsync(string orderUrl, string authorizationUrl, CancellationToken cancellationToken = default);

    Task WaitForAuthorizationAsync(string orderUrl, string authorizationUrl, CancellationToken cancellationToken = default);

    Task<IssuedCertificateBundle> FinalizeAndDownloadAsync(
        string orderUrl,
        string csrPem,
        CancellationToken cancellationToken = default);
}

/// <summary>Creates, waits for, and removes only the DNS-01 TXT record owned by the specified job.</summary>
public interface IDnsChallengeProvider
{
    Task PresentAsync(Guid jobId, ManagedService service, Dns01Challenge challenge, CancellationToken cancellationToken = default);

    Task WaitForPropagationAsync(Dns01Challenge challenge, CancellationToken cancellationToken = default);

    Task CleanupAsync(Guid jobId, ManagedService service, Dns01Challenge challenge, CancellationToken cancellationToken = default);
}

/// <summary>Performs pinned-host-key SSH/SFTP operations without returning or storing the service private key.</summary>
public interface ILinuxCertificateDeployer
{
    Task ConnectAndValidateAsync(ManagedService service, CancellationToken cancellationToken = default);

    Task<string> GenerateCsrAsync(ManagedService service, Guid jobId, CancellationToken cancellationToken = default);

    Task<string> StageAsync(
        ManagedService service,
        Guid jobId,
        IssuedCertificateBundle certificate,
        CancellationToken cancellationToken = default);

    Task<string?> ActivateAsync(ManagedService service, Guid jobId, string releaseId, CancellationToken cancellationToken = default);

    Task VerifyAsync(ManagedService service, Guid jobId, string releaseId, string expectedFingerprint, CancellationToken cancellationToken = default);

    Task<string?> RollbackAsync(ManagedService service, Guid jobId, string releaseId, CancellationToken cancellationToken = default);
}
