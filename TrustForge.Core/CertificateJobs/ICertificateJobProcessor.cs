namespace TrustForge.Core.CertificateJobs;

/// <summary>
/// Executes one resumable unit for a claimed job. Implementations must make external side effects
/// idempotent and persist state changes through TransitionLeasedAsync using the supplied fencing token.
/// </summary>
public interface ICertificateJobProcessor
{
    Task ProcessAsync(LeasedCertificateJob job, CertificateJobCoordinator coordinator, CancellationToken cancellationToken);
}
