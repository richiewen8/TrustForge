namespace TrustForge.Persistence.DeploymentVersions;

internal sealed class DeploymentVersionRecord
{
    public Guid Id { get; set; }
    public Guid ServiceId { get; set; }
    public Guid JobId { get; set; }
    public Guid? CertificateId { get; set; }
    public required string Fingerprint { get; set; }
    public required string ReleaseId { get; set; }
    public string? PreviousReleaseId { get; set; }
    public required string Status { get; set; }
    public required string HealthStatus { get; set; }
    public DateTimeOffset StagedAt { get; set; }
    public DateTimeOffset? ActivatedAt { get; set; }
    public DateTimeOffset? VerifiedAt { get; set; }
    public DateTimeOffset? CertificateNotAfter { get; set; }
}