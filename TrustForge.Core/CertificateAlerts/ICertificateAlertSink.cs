namespace TrustForge.Core.CertificateAlerts;

/// <summary>Receives alerts at least once; implementations must tolerate duplicate deliveries of the same alert ID.</summary>
public interface ICertificateAlertSink
{
    Task DeliverAsync(CertificateAlert alert, CancellationToken cancellationToken = default);
}