using Microsoft.Extensions.Options;
using TrustForge.Core.CertificateJobs;
using TrustForge.Core.Renewal;

namespace TrustForge.Api;

/// <summary>Queues renewal jobs for services whose active certificate enters its renewal window.</summary>
public sealed class RenewalSchedulerWorker(
    IServiceScopeFactory scopeFactory,
    IOptions<CertificateRenewalOptions> options,
    ILogger<RenewalSchedulerWorker> logger) : BackgroundService
{
    private readonly CertificateRenewalOptions _options = options.Value;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (_options.ScanInterval <= TimeSpan.Zero)
            throw new InvalidOperationException("CertificateJobs:Renewal:ScanInterval must be positive.");
        if (_options.MinimumRenewalInterval < TimeSpan.Zero)
            throw new InvalidOperationException("CertificateJobs:Renewal:MinimumRenewalInterval must not be negative.");

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await using AsyncServiceScope scope = scopeFactory.CreateAsyncScope();
                IRenewalCandidateStore candidates = scope.ServiceProvider.GetRequiredService<IRenewalCandidateStore>();
                CertificateJobCoordinator coordinator = scope.ServiceProvider.GetRequiredService<CertificateJobCoordinator>();
                TimeProvider timeProvider = scope.ServiceProvider.GetRequiredService<TimeProvider>();
                IReadOnlyList<RenewalCandidate> due = await candidates.ListDueAsync(timeProvider.GetUtcNow(), _options.MinimumRenewalInterval, stoppingToken);
                foreach (RenewalCandidate candidate in due)
                {
                    try
                    {
                        CertificateJob job = await coordinator.CreateManualJobAsync(
                            candidate.ServiceId,
                            CertificateRenewal.RequestedBy,
                            $"renewal-{candidate.Fingerprint}",
                            stoppingToken);
                        logger.LogInformation("Renewal job {JobId} queued for service {ServiceId}; certificate expires at {NotAfter}.", job.Id, candidate.ServiceId, candidate.NotAfter);
                    }
                    catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (CertificateJobActiveConflictException)
                    {
                        // Another job for this service won the race; the next scan re-evaluates.
                    }
                    catch (Exception exception)
                    {
                        logger.LogWarning(exception, "Failed to queue renewal job for service {ServiceId}.", candidate.ServiceId);
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
                logger.LogError(exception, "Renewal scan iteration failed.");
                await Task.Delay(_options.ScanInterval, stoppingToken);
            }
        }
    }
}