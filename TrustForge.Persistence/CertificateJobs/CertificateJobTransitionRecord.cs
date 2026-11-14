namespace TrustForge.Persistence.CertificateJobs;

internal sealed class CertificateJobTransitionRecord
{
    public Guid JobId { get; set; }
    public long Version { get; set; }
    public required string From { get; set; }
    public required string To { get; set; }
    public DateTimeOffset OccurredAt { get; set; }
    public required string Actor { get; set; }
    public string? FailureStage { get; set; }
    public string? FailureSummary { get; set; }
    public CertificateJobRecord? Job { get; set; }
}
