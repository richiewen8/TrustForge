using Microsoft.Extensions.Options;
using TrustForge.Core.CertificateAlerts;

namespace TrustForge.Api;

/// <summary>Delivers durable failure alerts at least once; receivers dedupe by alert ID.</summary>
public sealed class CertificateAlertDeliveryWorker(
    IServiceScopeFactory scopeFactory,
    IOptions<CertificateAlertOptions> options,
    ILogger<CertificateAlertDeliveryWorker> logger) : BackgroundService
{
    private readonly CertificateAlertOptions _options = options.Value;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await using AsyncServiceScope scope = scopeFactory.CreateAsyncScope();
                ICertificateAlertStore store = scope.ServiceProvider.GetRequiredService<ICertificateAlertStore>();
                ICertificateAlertSink sink = scope.ServiceProvider.GetRequiredService<ICertificateAlertSink>();
                IReadOnlyList<CertificateAlert> alerts = await store.ClaimDueAsync(10, _options.VisibilityTimeout, stoppingToken);
                if (alerts.Count == 0)
                {
                    await Task.Delay(_options.PollInterval, stoppingToken);
                    continue;
                }

                foreach (CertificateAlert alert in alerts)
                {
                    try
                    {
                        await sink.DeliverAsync(alert, stoppingToken);
                        await store.MarkDeliveredAsync(alert.Id, alert.AttemptCount, stoppingToken);
                    }
                    catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (Exception exception)
                    {
                        TimeSpan? retryDelay = alert.AttemptCount >= _options.MaxAttempts ? null : GetRetryDelay(alert.AttemptCount);
                        logger.LogWarning(exception, "Certificate alert {AlertId} delivery attempt {Attempt} failed.", alert.Id, alert.AttemptCount);
                        await store.MarkAttemptFailedAsync(alert.Id, alert.AttemptCount, exception.Message, retryDelay, stoppingToken);
                    }
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                logger.LogError(exception, "Certificate alert delivery iteration failed.");
                await Task.Delay(_options.PollInterval, stoppingToken);
            }
        }
    }

    private static TimeSpan GetRetryDelay(int attemptCount)
    {
        int exponent = Math.Clamp(attemptCount, 1, 8);
        return TimeSpan.FromSeconds(Math.Min(300, Math.Pow(2, exponent)));
    }
}