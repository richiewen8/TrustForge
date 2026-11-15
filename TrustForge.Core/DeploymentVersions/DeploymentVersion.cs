namespace TrustForge.Core.DeploymentVersions;

public enum DeploymentVersionStatus
{
    Staged,
    Active,
    Superseded,
    RolledBack,
    RollbackFailed
}

public enum DeploymentHealthStatus
{
    Pending,
    Healthy,
    Unhealthy,
    Unknown
}

/// <summary>Per-service deployment history entry; never contains private key material.</summary>
public sealed record DeploymentVersion(
    Guid Id,
    Guid ServiceId,
    Guid JobId,
    Guid? CertificateId,
    string Fingerprint,
    string ReleaseId,
    string? PreviousReleaseId,
    DeploymentVersionStatus Status,
    DeploymentHealthStatus HealthStatus,
    DateTimeOffset StagedAt,
    DateTimeOffset? ActivatedAt,
    DateTimeOffset? VerifiedAt,
    DateTimeOffset? CertificateNotAfter);