using Microsoft.Extensions.Options;
using TrustForge.Core.CertificateAlerts;
using TrustForge.Core.Expiry;

namespace TrustForge.Api;

/// <summary>Raises durable expiry reminders for active certificates inside the reminder window, deduped per certificate.</summary>
public sealed class ExpiryReminderWorker(
    IServiceScopeFactory scopeFactory,
    IOptions<CertificateExpiryOptions> options,
    ILogger<ExpiryReminderWorker> logger) : BackgroundService
{
    private readonly CertificateExpiryOptions _options = options.Value;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (_options.ScanInterval <= TimeSpan.Zero)
            throw new InvalidOperationException("CertificateJobs:Expiry:ScanInterval must be positive.");
        if (_options.ReminderWindow <= TimeSpan.Zero)
            throw new InvalidOperationException("CertificateJobs:Expiry:ReminderWindow must be positive.");

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await using AsyncServiceScope scope = scopeFactory.CreateAsyncScope();
                IExpiryCandidateStore candidates = scope.ServiceProvider.GetRequiredService<IExpiryCandidateStore>();
                ICertificateAlertStore alerts = scope.ServiceProvider.GetRequiredService<ICertificateAlertStore>();
                TimeProvider timeProvider = scope.ServiceProvider.GetRequiredService<TimeProvider>();
                DateTimeOffset now = timeProvider.GetUtcNow();
                IReadOnlyList<ExpiringCertificate> expiring = await candidates.ListExpiringAsync(now, _options.ReminderWindow, stoppingToken);
                foreach (ExpiringCertificate certificate in expiring)
                {
                    try
                    {
                        CertificateAlert alert = CertificateAlert.ForExpiring(certificate.ServiceId, certificate.Fingerprint, certificate.NotAfter, now);
                        if (await alerts.TryAddAsync(alert, stoppingToken))
                            logger.LogInformation("Expiry reminder {AlertId} raised for service {ServiceId}; certificate expires at {NotAfter}.", alert.Id, certificate.ServiceId, certificate.NotAfter);
                    }
                    catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (Exception exception)
                    {
                        logger.LogWarning(exception, "Failed to raise expiry reminder for service {ServiceId}.", certificate.ServiceId);
                    }
                }

                await Task.Delay(_options.ScanInterval, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                logger.LogError(exception, "Expiry scan iteration failed.");
                await Task.Delay(_options.ScanInterval, stoppingToken);
            }
        }
    }
}