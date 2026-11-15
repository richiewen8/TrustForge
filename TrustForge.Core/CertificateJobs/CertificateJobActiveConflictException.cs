namespace TrustForge.Core.CertificateJobs;

/// <summary>Raised when a service already has a non-terminal certificate job; callers surface a conflict instead of queueing a duplicate.</summary>
public sealed class CertificateJobActiveConflictException(Guid serviceId)
    : Exception($"Service '{serviceId}' already has an active certificate job.")
{
    public Guid ServiceId { get; } = serviceId;
}