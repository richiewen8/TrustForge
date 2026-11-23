using Microsoft.Extensions.Options;
using TrustForge.Core.Revocation;

namespace TrustForge.Api;

/// <summary>Retries revocations the CA did not acknowledge, so an emergency revocation is never lost.</summary>
public sealed class RevocationRetryWorker(
    IServiceScopeFactory scopeFactory,
    IOptions<CertificateRevocationOptions> options,
    ILogger<RevocationRetryWorker> logger) : BackgroundService
{
    private readonly CertificateRevocationOptions _options = options.Value;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await using AsyncServiceScope scope = scopeFactory.CreateAsyncScope();
                ICertificateRevocationStore store = scope.ServiceProvider.GetRequiredService<ICertificateRevocationStore>();
                CertificateRevocationService service = scope.ServiceProvider.GetRequiredService<CertificateRevocationService>();
                IReadOnlyList<CertificateRevocation> due = await store.ClaimDueAsync(5, _options.VisibilityTimeout, stoppingToken);
                if (due.Count == 0)
                {
                    await Task.Delay(_options.PollInterval, stoppingToken);
                    continue;
                }

                foreach (CertificateRevocation revocation in due)
                {
                    try
                    {
                        await service.CompleteAsync(revocation, stoppingToken);
                    }
                    catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (Exception exception)
                    {
                        logger.LogError(exception, "Revocation {RevocationId} retry attempt failed.", revocation.Id);
                    }
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                logger.LogError(exception, "Revocation retry iteration failed.");
                await Task.Delay(_options.PollInterval, stoppingToken);
            }
        }
    }
}
