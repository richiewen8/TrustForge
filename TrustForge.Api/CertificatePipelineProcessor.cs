using TrustForge.Core.CertificateJobs;
using TrustForge.Core.ManagedServices;

namespace TrustForge.Api;

/// <summary>Resumes one durable pipeline stage per worker claim; remote operations must be idempotent.</summary>
public sealed class CertificatePipelineProcessor(
    IManagedServiceStore services,
    ILinuxCertificateDeployer deployer,
    ICertificateIssuer issuer,
    IDnsChallengeProvider dns,
    ICertificateArtifactStore artifacts,
    IssuedCertificateValidator validator,
    ILogger<CertificatePipelineProcessor> logger) : ICertificateJobProcessor
{
    private readonly string _actor = $"pipeline:{Environment.MachineName}";

    public async Task ProcessAsync(LeasedCertificateJob leased, CertificateJobCoordinator coordinator, CancellationToken cancellationToken)
    {
        CertificateJob job = leased.Job;
        ManagedService? service = null;
        CertificateJobCheckpoint checkpoint = job.Checkpoint;
        try
        {
            switch (job.State)
            {
                case CertificateJobState.Queued:
                    await AdvanceAsync(leased, coordinator, CertificateJobState.Connecting, cancellationToken);
                    break;
                case CertificateJobState.Connecting:
                    service = await RequireServiceAsync(job.ServiceId, cancellationToken);
                    await deployer.ConnectAndValidateAsync(service, cancellationToken);
                    await AdvanceAsync(leased, coordinator, CertificateJobState.GeneratingCsr, cancellationToken);
                    break;
                case CertificateJobState.GeneratingCsr:
                    service = await RequireServiceAsync(job.ServiceId, cancellationToken);
                    string csr = checkpoint.CsrPem ?? await deployer.GenerateCsrAsync(service, job.Id, cancellationToken);
                    validator.ValidateCsr(csr, service);
                    await SaveAsync(leased, coordinator, checkpoint with { CsrPem = csr }, cancellationToken);
                    await AdvanceAsync(leased, coordinator, CertificateJobState.CreatingOrder, cancellationToken);
                    break;
                case CertificateJobState.CreatingOrder:
                    service = await RequireServiceAsync(job.ServiceId, cancellationToken);
                    string order = await issuer.CreateOrResumeOrderAsync(job.Id, checkpoint.AcmeOrderUrl, Required(checkpoint.CsrPem, "CSR checkpoint is missing."), service.Sans, cancellationToken);
                    await SaveAsync(leased, coordinator, checkpoint with { AcmeOrderUrl = order }, cancellationToken);
                    await AdvanceAsync(leased, coordinator, CertificateJobState.AwaitingChallenge, cancellationToken);
                    break;
                case CertificateJobState.AwaitingChallenge:
                    service = await RequireServiceAsync(job.ServiceId, cancellationToken);
                    await ProcessChallengesAsync(leased, coordinator, service, Required(checkpoint.AcmeOrderUrl, "ACME order checkpoint is missing."), cancellationToken);
                    await AdvanceAsync(leased, coordinator, CertificateJobState.Signing, cancellationToken);
                    break;
                case CertificateJobState.Signing:
                    service = await RequireServiceAsync(job.ServiceId, cancellationToken);
                    IssuedCertificateBundle certificate = await issuer.FinalizeAndDownloadAsync(
                        Required(checkpoint.AcmeOrderUrl, "ACME order checkpoint is missing."),
                        Required(checkpoint.CsrPem, "CSR checkpoint is missing."), cancellationToken);
                    validator.Validate(certificate, Required(checkpoint.CsrPem, "CSR checkpoint is missing."), service);
                    Guid certificateId = job.CertificateId ?? Guid.NewGuid();
                    await artifacts.PutAsync(job.Id, certificate, cancellationToken);
                    await SaveAsync(leased, coordinator, checkpoint with { CertificateArtifactRef = job.Id.ToString("N") }, cancellationToken);
                    await coordinator.AttachIssuedCertificateLeasedAsync(job.Id, job.Version, leased.Lease.Token, certificateId, certificate.FingerprintSha256, cancellationToken);
                    await AdvanceAsync(leased, coordinator, CertificateJobState.Staging, cancellationToken);
                    break;
                case CertificateJobState.Staging:
                    service = await RequireServiceAsync(job.ServiceId, cancellationToken);
                    IssuedCertificateBundle stagedCertificate = await artifacts.GetAsync(job.Id, cancellationToken);
                    string release = checkpoint.DeploymentReleaseId ?? await deployer.StageAsync(service, job.Id, stagedCertificate, cancellationToken);
                    await SaveAsync(leased, coordinator, checkpoint with { DeploymentReleaseId = release }, cancellationToken);
                    await AdvanceAsync(leased, coordinator, CertificateJobState.Activating, cancellationToken);
                    break;
                case CertificateJobState.Activating:
                    service = await RequireServiceAsync(job.ServiceId, cancellationToken);
                    string? previousRelease = await deployer.ActivateAsync(service, job.Id, Required(checkpoint.DeploymentReleaseId, "Deployment release checkpoint is missing."), cancellationToken);
                    await SaveAsync(leased, coordinator, checkpoint with { PreviousReleaseId = previousRelease }, cancellationToken);
                    await AdvanceAsync(leased, coordinator, CertificateJobState.Verifying, cancellationToken);
                    break;
                case CertificateJobState.Verifying:
                    service = await RequireServiceAsync(job.ServiceId, cancellationToken);
                    await deployer.VerifyAsync(service, job.Id,
                        Required(checkpoint.DeploymentReleaseId, "Deployment release checkpoint is missing."),
                        Required(job.CertificateFingerprint, "Issued certificate fingerprint is missing."), cancellationToken);
                    await AdvanceAsync(leased, coordinator, CertificateJobState.Succeeded, cancellationToken);
                    break;
                default:
                    throw new InvalidOperationException($"The pipeline cannot process job state '{job.State}'.");
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            logger.LogError(exception, "Certificate pipeline stage {Stage} failed for job {JobId}.", job.State, job.Id);
            await RecordFailureAsync(leased, coordinator, service, exception, cancellationToken);
        }
    }

    private async Task ProcessChallengesAsync(LeasedCertificateJob leased, CertificateJobCoordinator coordinator, ManagedService service, string orderUrl, CancellationToken cancellationToken)
    {
        Guid jobId = leased.Job.Id;
        CertificateJobCheckpoint checkpoint = leased.Job.Checkpoint;
        IReadOnlyList<Dns01Challenge> challenges;
        if (checkpoint.DnsChallenges is { Count: > 0 } persisted)
        {
            challenges = [.. persisted.Select(item => new Dns01Challenge(item.AuthorizationUrl, item.RecordName, item.TxtValue))];
        }
        else
        {
            challenges = await issuer.GetDns01ChallengesAsync(orderUrl, cancellationToken);
            if (challenges.Count == 0)
                return;
            // Persist before presenting so any presented TXT record can be cleaned up after a crash or lease loss.
            await SaveAsync(leased, coordinator, checkpoint with
            {
                DnsChallenges = [.. challenges.Select(item => new CertificateJobDnsChallengeCheckpoint(item.AuthorizationUrl, item.RecordName, item.TxtValue))]
            }, cancellationToken);
        }

        Exception? operationFailure = null;
        try
        {
            foreach (Dns01Challenge challenge in challenges)
            {
                await dns.PresentAsync(jobId, service, challenge, cancellationToken);
                await dns.WaitForPropagationAsync(challenge, cancellationToken);
                await issuer.TriggerDnsAuthorizationAsync(orderUrl, challenge.AuthorizationUrl, cancellationToken);
                await issuer.WaitForAuthorizationAsync(orderUrl, challenge.AuthorizationUrl, cancellationToken);
            }
        }
        catch (Exception exception)
        {
            operationFailure = exception;
        }
        List<Exception> cleanupFailures = [];
        foreach (Dns01Challenge challenge in challenges)
            try { await dns.CleanupAsync(jobId, service, challenge, CancellationToken.None); }
            catch (Exception exception) { cleanupFailures.Add(exception); }
        if (operationFailure is not null && cleanupFailures.Count > 0)
            throw new AggregateException("ACME DNS validation failed and one or more challenge records could not be cleaned up.", [operationFailure, .. cleanupFailures]);
        if (operationFailure is not null)
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(operationFailure).Throw();
        if (cleanupFailures.Count > 0)
            throw new AggregateException("One or more ACME DNS challenge records could not be cleaned up.", cleanupFailures);
        await SaveAsync(leased, coordinator, checkpoint with { DnsChallenges = null }, cancellationToken);
    }

    private async Task RecordFailureAsync(LeasedCertificateJob leased, CertificateJobCoordinator coordinator, ManagedService? service, Exception exception, CancellationToken cancellationToken)
    {
        CertificateJob job = leased.Job;
        // The Queued stage has no external side effects; a failure here is infrastructure-level, so let the worker retry instead of recording a terminal failure.
        if (job.State == CertificateJobState.Queued)
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(exception).Throw();
        string summary = exception.Message.Length > 1000 ? exception.Message[..1000] : exception.Message;
        if (job.State is CertificateJobState.Activating or CertificateJobState.Verifying)
        {
            try
            {
                if (service is null || string.IsNullOrWhiteSpace(job.Checkpoint.DeploymentReleaseId))
                    throw new InvalidOperationException("No staged release ID is available for rollback.");
                string? previous = await deployer.RollbackAsync(service, job.Id, job.Checkpoint.DeploymentReleaseId, cancellationToken);
                CertificateJobCheckpoint recovered = job.Checkpoint with { PreviousReleaseId = previous };
                await SaveAsync(leased, coordinator, recovered, cancellationToken);
                await coordinator.TransitionLeasedAsync(job.Id, job.Version, leased.Lease.Token,
                    CertificateJobState.FailedRolledBack, _actor, job.State.ToString(), summary, cancellationToken);
            }
            catch (Exception rollbackException) when (rollbackException is not OperationCanceledException)
            {
                string rollbackSummary = $"{summary}; rollback failed: {rollbackException.Message}";
                if (rollbackSummary.Length > 1000) rollbackSummary = rollbackSummary[..1000];
                await coordinator.TransitionLeasedAsync(job.Id, job.Version, leased.Lease.Token,
                    CertificateJobState.RollbackFailed, _actor, job.State.ToString(), rollbackSummary, cancellationToken);
            }
            return;
        }

        await coordinator.TransitionLeasedAsync(job.Id, job.Version, leased.Lease.Token,
            CertificateJobState.Failed, _actor, job.State.ToString(), summary, cancellationToken);
    }

    private Task SaveAsync(LeasedCertificateJob leased, CertificateJobCoordinator coordinator, CertificateJobCheckpoint checkpoint, CancellationToken cancellationToken) =>
        coordinator.SaveCheckpointLeasedAsync(leased.Job.Id, leased.Job.Version, leased.Lease.Token, checkpoint, cancellationToken);

    private Task AdvanceAsync(LeasedCertificateJob leased, CertificateJobCoordinator coordinator, CertificateJobState state, CancellationToken cancellationToken)
    {
        CertificateJob job = leased.Job;
        return coordinator.TransitionLeasedAsync(job.Id, job.Version, leased.Lease.Token, state, _actor, cancellationToken: cancellationToken);
    }

    private async Task<ManagedService> RequireServiceAsync(Guid serviceId, CancellationToken cancellationToken) =>
        await services.FindByIdAsync(serviceId, cancellationToken)
        ?? throw new InvalidOperationException("The managed service for this certificate job no longer exists.");

    private static string Required(string? value, string message) =>
        string.IsNullOrWhiteSpace(value) ? throw new InvalidOperationException(message) : value;
}
