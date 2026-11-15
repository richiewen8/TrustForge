using TrustForge.Core.CertificateJobs;

namespace TrustForge.Core.DeploymentVersions;

/// <summary>Deployment history writes are lease-fenced and forward-only so stage replays stay idempotent.</summary>
public interface IDeploymentVersionStore
{
    Task<bool> RecordStagedAsync(CertificateJob job, Guid leaseToken, string releaseId, DateTimeOffset certificateNotAfter, CancellationToken cancellationToken = default);
    Task<bool> MarkActiveAsync(Guid jobId, Guid leaseToken, string? previousReleaseId, CancellationToken cancellationToken = default);
    Task<bool> MarkVerifiedAsync(Guid jobId, Guid leaseToken, CancellationToken cancellationToken = default);
    Task<bool> MarkRolledBackAsync(Guid jobId, Guid leaseToken, string? restoredReleaseId, CancellationToken cancellationToken = default);
    Task<bool> MarkRollbackFailedAsync(Guid jobId, Guid leaseToken, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DeploymentVersion>> ListByServiceAsync(Guid serviceId, int limit, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DeploymentVersion>> ListAsync(Guid? serviceId, DateTimeOffset? from, DateTimeOffset? to, int limit, CancellationToken cancellationToken = default);
}