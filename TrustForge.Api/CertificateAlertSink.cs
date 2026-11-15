using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using TrustForge.Core.CertificateAlerts;

namespace TrustForge.Api;

public sealed class CertificateAlertSink(
    IHttpClientFactory httpClientFactory,
    IOptions<CertificateAlertOptions> options,
    ILogger<CertificateAlertSink> logger) : ICertificateAlertSink
{
    public async Task DeliverAsync(CertificateAlert alert, CancellationToken cancellationToken = default)
    {
        string? webhookUrl = options.Value.WebhookUrl;
        if (string.IsNullOrWhiteSpace(webhookUrl))
        {
            if (alert.Severity == CertificateAlertSeverity.Critical)
                logger.LogCritical("Certificate alert {AlertId} ({Kind}) for service {ServiceId}, job {JobId} at {Stage}: {Summary}",
                    alert.Id, alert.Kind, alert.ServiceId, alert.JobId, alert.Stage, alert.Summary);
            else
                logger.LogWarning("Certificate alert {AlertId} ({Kind}) for service {ServiceId}, job {JobId} at {Stage}: {Summary}",
                    alert.Id, alert.Kind, alert.ServiceId, alert.JobId, alert.Stage, alert.Summary);
            return;
        }

        using HttpClient client = httpClientFactory.CreateClient("CertificateAlerts");
        // StringContent guarantees Content-Length; JsonContent may send chunked, which simple webhook receivers reject.
        string payload = JsonSerializer.Serialize(new
        {
            id = alert.Id,
            jobId = alert.JobId,
            serviceId = alert.ServiceId,
            kind = alert.Kind.ToString(),
            severity = alert.Severity.ToString(),
            stage = alert.Stage,
            summary = alert.Summary,
            occurredAt = alert.OccurredAt,
            dedupeKey = alert.DedupeKey
        });
        using StringContent content = new(payload, Encoding.UTF8, "application/json");
        using HttpResponseMessage response = await client.PostAsync(webhookUrl, content, cancellationToken);
        response.EnsureSuccessStatusCode();
    }
}