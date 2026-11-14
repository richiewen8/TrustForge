using Microsoft.Extensions.Options;
using TrustForge.Core.CertificateJobs;

namespace TrustForge.Api;

public sealed class CertificateJobWorker(
    IServiceScopeFactory scopeFactory,
    IOptions<CertificateJobWorkerOptions> options,
    ILogger<CertificateJobWorker> logger) : BackgroundService
{
    private readonly CertificateJobWorkerOptions _options = options.Value;
    private readonly string _owner = $"{Environment.MachineName}:{Guid.NewGuid():N}";

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await using AsyncServiceScope scope = scopeFactory.CreateAsyncScope();
                ICertificateJobStore store = scope.ServiceProvider.GetRequiredService<ICertificateJobStore>();
                LeasedCertificateJob? leased = await store.TryClaimNextAsync(_owner, _options.LeaseDuration, stoppingToken);
                if (leased is null)
                {
                    await Task.Delay(_options.PollInterval, stoppingToken);
                    continue;
                }

                ICertificateJobProcessor processor = scope.ServiceProvider.GetRequiredService<ICertificateJobProcessor>();
                CertificateJobCoordinator coordinator = scope.ServiceProvider.GetRequiredService<CertificateJobCoordinator>();
                await ProcessClaimAsync(store, processor, coordinator, leased, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                logger.LogError(exception, "Certificate job worker iteration failed.");
                await Task.Delay(_options.PollInterval, stoppingToken);
            }
        }
    }

    private async Task ProcessClaimAsync(
        ICertificateJobStore store,
        ICertificateJobProcessor processor,
        CertificateJobCoordinator coordinator,
        LeasedCertificateJob leased,
        CancellationToken stoppingToken)
    {
        using CancellationTokenSource processing = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        using CancellationTokenSource heartbeatStop = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        Task heartbeat = RenewUntilFinishedAsync(store, leased, processing, heartbeatStop.Token);
        try
        {
            await processor.ProcessAsync(leased, coordinator, processing.Token);
            CertificateJob? persisted = await store.FindByIdAsync(leased.Job.Id, stoppingToken);
            TimeSpan retryDelay = persisted is { Version: var version } && version == leased.Job.Version
                ? GetRetryDelay(leased.Lease.AttemptCount)
                : TimeSpan.Zero;
            await store.ReleaseLeaseAsync(leased.Job.Id, leased.Lease.Token, retryDelay, stoppingToken);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            await TryReleaseAsync(store, leased, TimeSpan.Zero);
        }
        catch (OperationCanceledException) when (processing.IsCancellationRequested)
        {
            logger.LogWarning("Certificate job {JobId} processing stopped after its lease was lost.", leased.Job.Id);
        }
        catch (Exception exception)
        {
            TimeSpan retryDelay = GetRetryDelay(leased.Lease.AttemptCount);
            logger.LogError(exception, "Certificate job {JobId} failed during processing; it will be retried after {RetryDelay}.", leased.Job.Id, retryDelay);
            await TryReleaseAsync(store, leased, retryDelay);
        }
        finally
        {
            processing.Cancel();
            heartbeatStop.Cancel();
            try { await heartbeat; }
            catch (OperationCanceledException) { }
        }
    }

    private async Task RenewUntilFinishedAsync(
        ICertificateJobStore store,
        LeasedCertificateJob leased,
        CancellationTokenSource processing,
        CancellationToken heartbeatToken)
    {
        TimeSpan interval = TimeSpan.FromTicks(Math.Max(TimeSpan.FromSeconds(1).Ticks, _options.LeaseDuration.Ticks / 3));
        using PeriodicTimer timer = new(interval);
        while (await timer.WaitForNextTickAsync(heartbeatToken))
        {
            if (!await store.RenewLeaseAsync(leased.Job.Id, leased.Lease.Token, _options.LeaseDuration, heartbeatToken))
            {
                processing.Cancel();
                return;
            }
        }
    }

    private async Task TryReleaseAsync(ICertificateJobStore store, LeasedCertificateJob leased, TimeSpan retryDelay)
    {
        try
        {
            await store.ReleaseLeaseAsync(leased.Job.Id, leased.Lease.Token, retryDelay, CancellationToken.None);
        }
        catch (Exception exception)
        {
            logger.LogWarning(exception, "Could not release certificate job lease {JobId}; it will expire automatically.", leased.Job.Id);
        }
    }

    private static TimeSpan GetRetryDelay(int attemptCount)
    {
        int exponent = Math.Clamp(attemptCount, 1, 8);
        return TimeSpan.FromSeconds(Math.Min(300, Math.Pow(2, exponent)));
    }
}
