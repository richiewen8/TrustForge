namespace TrustForge.Persistence.Revocation;

public sealed class CertificateRevocationRecord
{
    public Guid Id { get; set; }
    public Guid ServiceId { get; set; }
    public Guid JobId { get; set; }
    public required string Fingerprint { get; set; }
    public required string Serial { get; set; }
    public required string Reason { get; set; }
    public required string RequestedBy { get; set; }
    public required string IdempotencyKey { get; set; }
    public DateTimeOffset RequestedAt { get; set; }
    public required string State { get; set; }
    public int AttemptCount { get; set; }
    public DateTimeOffset? RevokedAt { get; set; }
    public DateTimeOffset? NextAttemptAt { get; set; }
    public string? LastError { get; set; }
}
