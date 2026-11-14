namespace TrustForge.Core.CertificateJobs;

/// <summary>A database-backed, fencing-token lease held by one worker attempt.</summary>
public sealed record CertificateJobLease(string Owner, Guid Token, DateTimeOffset ExpiresAt, int AttemptCount);

public sealed record LeasedCertificateJob(CertificateJob Job, CertificateJobLease Lease);
