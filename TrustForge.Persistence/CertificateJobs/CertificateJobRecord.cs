namespace TrustForge.Persistence.CertificateJobs;

internal sealed class CertificateJobRecord
{
    public Guid Id { get; set; }
    public Guid ServiceId { get; set; }
    public required string RequestedBy { get; set; }
    public required string IdempotencyKey { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? FinishedAt { get; set; }
    public required string State { get; set; }
    public long Version { get; set; }
    public Guid? CertificateId { get; set; }
    public string? CertificateFingerprint { get; set; }
    public string? FailureStage { get; set; }
    public string? FailureSummary { get; set; }
    public List<CertificateJobTransitionRecord> Transitions { get; set; } = [];
}
