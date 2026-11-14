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
}
