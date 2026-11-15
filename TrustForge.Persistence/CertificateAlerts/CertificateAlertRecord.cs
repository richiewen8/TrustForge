namespace TrustForge.Persistence.CertificateAlerts;

internal sealed class CertificateAlertRecord
{
    public Guid Id { get; set; }
    public Guid? JobId { get; set; }
    public Guid ServiceId { get; set; }
    public required string Kind { get; set; }
    public required string Severity { get; set; }
    public required string Stage { get; set; }
    public required string Summary { get; set; }
    public DateTimeOffset OccurredAt { get; set; }
    public required string DeliveryState { get; set; }
    public int AttemptCount { get; set; }
    public DateTimeOffset? NextAttemptAt { get; set; }
    public DateTimeOffset? DeliveredAt { get; set; }
    public string? LastError { get; set; }
    public string? DedupeKey { get; set; }
}