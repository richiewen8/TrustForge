namespace TrustForge.Core.CertificateAlerts;

/// <summary>Alert delivery queue. Claims carry a visibility timeout; delivery is at-least-once and receivers dedupe by alert ID.</summary>
public interface ICertificateAlertStore
{
    Task<IReadOnlyList<CertificateAlert>> ClaimDueAsync(int limit, TimeSpan visibilityTimeout, CancellationToken cancellationToken = default);
    Task<bool> MarkDeliveredAsync(Guid id, int expectedAttemptCount, CancellationToken cancellationToken = default);
    Task<bool> TryAddAsync(CertificateAlert alert, CancellationToken cancellationToken = default);
    Task<bool> MarkAttemptFailedAsync(Guid id, int expectedAttemptCount, string error, TimeSpan? retryDelay, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<CertificateAlert>> ListAsync(Guid? serviceId, CertificateAlertDeliveryState? deliveryState, DateTimeOffset? from, DateTimeOffset? to, int limit, CancellationToken cancellationToken = default);
}