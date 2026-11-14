namespace TrustForge.Core.CertificateJobs;

public sealed record CertificateJobTransition(
    long Version,
    CertificateJobState From,
    CertificateJobState To,
    DateTimeOffset OccurredAt,
    string Actor,
    string? FailureStage = null,
    string? FailureSummary = null);
