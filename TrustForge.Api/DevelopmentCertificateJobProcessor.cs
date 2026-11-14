using TrustForge.Core.CertificateJobs;

namespace TrustForge.Api;

/// <summary>
/// Exercises the durable state machine without contacting a CA, DNS server, or Linux host.
/// It always ends in the explicit Simulated terminal state and never fabricates a certificate.
/// </summary>
public sealed class DevelopmentCertificateJobProcessor : ICertificateJobProcessor
{
    public async Task ProcessAsync(
        LeasedCertificateJob leased,
        CertificateJobCoordinator coordinator,
        CancellationToken cancellationToken)
    {
        CertificateJobState next = leased.Job.State switch
        {
            CertificateJobState.Queued => CertificateJobState.Connecting,
            CertificateJobState.Connecting => CertificateJobState.GeneratingCsr,
            CertificateJobState.GeneratingCsr => CertificateJobState.CreatingOrder,
            CertificateJobState.CreatingOrder => CertificateJobState.AwaitingChallenge,
            CertificateJobState.AwaitingChallenge => CertificateJobState.Signing,
            CertificateJobState.Signing => CertificateJobState.Staging,
            CertificateJobState.Staging => CertificateJobState.Activating,
            CertificateJobState.Activating => CertificateJobState.Verifying,
            CertificateJobState.Verifying => CertificateJobState.Simulated,
            _ => throw new InvalidOperationException($"The simulator cannot process job state '{leased.Job.State}'.")
        };

        await coordinator.TransitionLeasedAsync(
            leased.Job.Id,
            leased.Job.Version,
            leased.Lease.Token,
            next,
            "development-simulator",
            cancellationToken: cancellationToken);
    }
}
