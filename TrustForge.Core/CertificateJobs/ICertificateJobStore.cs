namespace TrustForge.Core.CertificateJobs;

/// <summary>Persistence boundary. Implementations enforce idempotency and optimistic concurrency atomically.</summary>
public interface ICertificateJobStore
{
    Task<CertificateJob?> FindByIdAsync(Guid id, CancellationToken cancellationToken = default);
    Task<CertificateJob?> FindByIdempotencyKeyAsync(
        Guid serviceId,
        string requestedBy,
        string idempotencyKey,
        CancellationToken cancellationToken = default);
    Task<bool> TryAddAsync(CertificateJob job, CancellationToken cancellationToken = default);
    Task<bool> TryUpdateAsync(CertificateJob job, long expectedVersion, CancellationToken cancellationToken = default);
    Task<LeasedCertificateJob?> TryClaimNextAsync(string owner, TimeSpan leaseDuration, CancellationToken cancellationToken = default);
    Task<bool> RenewLeaseAsync(Guid jobId, Guid leaseToken, TimeSpan leaseDuration, CancellationToken cancellationToken = default);
    Task<bool> ReleaseLeaseAsync(Guid jobId, Guid leaseToken, TimeSpan retryDelay, CancellationToken cancellationToken = default);
    Task<bool> TryUpdateLeasedAsync(CertificateJob job, long expectedVersion, Guid leaseToken, CancellationToken cancellationToken = default);
    Task<bool> TryUpdateCheckpointLeasedAsync(Guid jobId, long expectedVersion, Guid leaseToken, CertificateJobCheckpoint checkpoint, CancellationToken cancellationToken = default);
}
