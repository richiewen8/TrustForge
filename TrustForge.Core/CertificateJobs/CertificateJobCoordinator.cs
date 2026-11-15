namespace TrustForge.Core.CertificateJobs;

/// <summary>Coordinates durable job creation and guarded transitions.</summary>
public sealed class CertificateJobCoordinator(ICertificateJobStore store, TimeProvider timeProvider)
{
    public async Task<CertificateJob> CreateManualJobAsync(
        Guid serviceId,
        string requestedBy,
        string idempotencyKey,
        CancellationToken cancellationToken = default)
    {
        CertificateJob? existing = await store.FindByIdempotencyKeyAsync(serviceId, requestedBy, idempotencyKey, cancellationToken);
        if (existing is not null)
            return existing;

        CertificateJob job = CertificateJob.Create(serviceId, requestedBy, idempotencyKey, timeProvider.GetUtcNow());
        if (await store.TryAddAsync(job, cancellationToken))
            return job;

        existing = await store.FindByIdempotencyKeyAsync(serviceId, requestedBy, idempotencyKey, cancellationToken);
        if (existing is not null)
            return existing;
        throw new InvalidOperationException("The certificate job could not be created.");
    }

    public async Task<CertificateJob> TransitionAsync(
        Guid jobId,
        long expectedVersion,
        CertificateJobState nextState,
        string actor,
        string? failureStage = null,
        string? failureSummary = null,
        CancellationToken cancellationToken = default)
    {
        CertificateJob job = await store.FindByIdAsync(jobId, cancellationToken)
            ?? throw new KeyNotFoundException($"Certificate job '{jobId}' was not found.");
        if (job.Version != expectedVersion)
            throw new CertificateJobConcurrencyException(jobId, expectedVersion, job.Version);

        long storedVersion = job.Version;
        job.TransitionTo(nextState, actor, timeProvider.GetUtcNow(), failureStage, failureSummary);
        if (!await store.TryUpdateAsync(job, storedVersion, cancellationToken))
            throw new CertificateJobConcurrencyException(jobId, expectedVersion, null);
        return job;
    }

    public async Task<CertificateJob> TransitionLeasedAsync(
        Guid jobId,
        long expectedVersion,
        Guid leaseToken,
        CertificateJobState nextState,
        string actor,
        string? failureStage = null,
        string? failureSummary = null,
        CancellationToken cancellationToken = default)
    {
        CertificateJob job = await store.FindByIdAsync(jobId, cancellationToken)
            ?? throw new KeyNotFoundException($"Certificate job '{jobId}' was not found.");
        if (job.Version != expectedVersion)
            throw new CertificateJobConcurrencyException(jobId, expectedVersion, job.Version);

        long storedVersion = job.Version;
        job.TransitionTo(nextState, actor, timeProvider.GetUtcNow(), failureStage, failureSummary);
        if (!await store.TryUpdateLeasedAsync(job, storedVersion, leaseToken, cancellationToken))
            throw new CertificateJobConcurrencyException(jobId, expectedVersion, null);
        return job;
    }

    public async Task SaveCheckpointLeasedAsync(
        Guid jobId,
        long expectedVersion,
        Guid leaseToken,
        CertificateJobCheckpoint checkpoint,
        CancellationToken cancellationToken = default)
    {
        CertificateJob job = await store.FindByIdAsync(jobId, cancellationToken)
            ?? throw new KeyNotFoundException($"Certificate job '{jobId}' was not found.");
        if (job.Version != expectedVersion)
            throw new CertificateJobConcurrencyException(jobId, expectedVersion, job.Version);
        if (!await store.TryUpdateCheckpointLeasedAsync(jobId, expectedVersion, leaseToken, checkpoint, cancellationToken))
            throw new CertificateJobConcurrencyException(jobId, expectedVersion, null);
    }

    public async Task AttachIssuedCertificateLeasedAsync(
        Guid jobId,
        long expectedVersion,
        Guid leaseToken,
        Guid certificateId,
        string fingerprint,
        CancellationToken cancellationToken = default)
    {
        CertificateJob job = await store.FindByIdAsync(jobId, cancellationToken)
            ?? throw new KeyNotFoundException($"Certificate job '{jobId}' was not found.");
        if (job.Version != expectedVersion)
            throw new CertificateJobConcurrencyException(jobId, expectedVersion, job.Version);
        job.SetIssuedCertificate(certificateId, fingerprint);
        if (!await store.TryAttachCertificateLeasedAsync(jobId, expectedVersion, leaseToken, certificateId, fingerprint, cancellationToken))
            throw new CertificateJobConcurrencyException(jobId, expectedVersion, null);
    }
}
