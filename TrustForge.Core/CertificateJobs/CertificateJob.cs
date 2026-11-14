namespace TrustForge.Core.CertificateJobs;

/// <summary>Aggregate for one manual certificate issuance and deployment attempt.</summary>
public sealed class CertificateJob
{
    private static readonly IReadOnlyDictionary<CertificateJobState, CertificateJobState[]> AllowedTransitions =
        new Dictionary<CertificateJobState, CertificateJobState[]>
        {
            [CertificateJobState.Queued] = [CertificateJobState.Connecting, CertificateJobState.Cancelled],
            [CertificateJobState.Connecting] = [CertificateJobState.GeneratingCsr, CertificateJobState.Failed, CertificateJobState.Cancelled],
            [CertificateJobState.GeneratingCsr] = [CertificateJobState.CreatingOrder, CertificateJobState.Failed, CertificateJobState.Cancelled],
            [CertificateJobState.CreatingOrder] = [CertificateJobState.AwaitingChallenge, CertificateJobState.Failed, CertificateJobState.Cancelled],
            [CertificateJobState.AwaitingChallenge] = [CertificateJobState.Signing, CertificateJobState.Failed, CertificateJobState.Cancelled],
            [CertificateJobState.Signing] = [CertificateJobState.Staging, CertificateJobState.Failed, CertificateJobState.Cancelled],
            [CertificateJobState.Staging] = [CertificateJobState.Activating, CertificateJobState.Failed, CertificateJobState.Cancelled],
            [CertificateJobState.Activating] = [CertificateJobState.Verifying, CertificateJobState.FailedRolledBack, CertificateJobState.RollbackFailed],
            [CertificateJobState.Verifying] = [CertificateJobState.Succeeded, CertificateJobState.Simulated, CertificateJobState.FailedRolledBack, CertificateJobState.RollbackFailed]
        };

    private readonly List<CertificateJobTransition> _transitions = [];

    private CertificateJob(Guid id, Guid serviceId, string requestedBy, string idempotencyKey, DateTimeOffset createdAt)
    {
        Id = id;
        ServiceId = serviceId;
        RequestedBy = requestedBy;
        IdempotencyKey = idempotencyKey;
        CreatedAt = createdAt;
        State = CertificateJobState.Queued;
    }

    public Guid Id { get; }
    public Guid ServiceId { get; }
    public string RequestedBy { get; }
    public string IdempotencyKey { get; }
    public DateTimeOffset CreatedAt { get; }
    public DateTimeOffset? FinishedAt { get; private set; }
    public CertificateJobState State { get; private set; }
    public long Version { get; private set; }
    public Guid? CertificateId { get; private set; }
    public string? CertificateFingerprint { get; private set; }
    public string? FailureStage { get; private set; }
    public string? FailureSummary { get; private set; }
    public CertificateJobCheckpoint Checkpoint { get; private set; } = new();
    public IReadOnlyList<CertificateJobTransition> Transitions => _transitions.AsReadOnly();

    public static CertificateJob Create(Guid serviceId, string requestedBy, string idempotencyKey, DateTimeOffset createdAt)
    {
        if (serviceId == Guid.Empty)
            throw new ArgumentException("A service ID is required.", nameof(serviceId));
        ArgumentException.ThrowIfNullOrWhiteSpace(requestedBy);
        ArgumentException.ThrowIfNullOrWhiteSpace(idempotencyKey);

        return new CertificateJob(Guid.NewGuid(), serviceId, requestedBy.Trim(), idempotencyKey.Trim(), createdAt);
    }

    public static CertificateJob Restore(
        Guid id,
        Guid serviceId,
        string requestedBy,
        string idempotencyKey,
        DateTimeOffset createdAt,
        DateTimeOffset? finishedAt,
        CertificateJobState state,
        long version,
        Guid? certificateId,
        string? certificateFingerprint,
        string? failureStage,
        string? failureSummary,
        IEnumerable<CertificateJobTransition> transitions,
        CertificateJobCheckpoint? checkpoint = null)
    {
        if (id == Guid.Empty)
            throw new ArgumentException("A job ID is required.", nameof(id));

        CertificateJob job = new(id, serviceId, requestedBy, idempotencyKey, createdAt)
        {
            FinishedAt = finishedAt,
            State = state,
            Version = version,
            CertificateId = certificateId,
            CertificateFingerprint = certificateFingerprint,
            FailureStage = failureStage,
            FailureSummary = failureSummary,
            Checkpoint = checkpoint ?? new CertificateJobCheckpoint()
        };

        CertificateJobState expectedFrom = CertificateJobState.Queued;
        long expectedVersion = 1;
        foreach (CertificateJobTransition transition in transitions.OrderBy(item => item.Version))
        {
            if (transition.Version != expectedVersion || transition.From != expectedFrom)
                throw new InvalidOperationException("Persisted certificate job transition history is inconsistent.");

            job._transitions.Add(transition);
            expectedFrom = transition.To;
            expectedVersion++;
        }

        if (job.Version != expectedVersion - 1 || job.State != expectedFrom)
            throw new InvalidOperationException("Persisted certificate job state does not match its transition history.");

        return job;
    }

    public void SetCheckpoint(CertificateJobCheckpoint checkpoint)
    {
        ArgumentNullException.ThrowIfNull(checkpoint);
        Checkpoint = checkpoint;
    }

    public void TransitionTo(
        CertificateJobState nextState,
        string actor,
        DateTimeOffset occurredAt,
        string? failureStage = null,
        string? failureSummary = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(actor);
        if (!AllowedTransitions.TryGetValue(State, out CertificateJobState[]? allowed) || !allowed.Contains(nextState))
            throw new InvalidCertificateJobTransitionException(State, nextState);

        bool isFailure = nextState is CertificateJobState.Failed
            or CertificateJobState.FailedRolledBack
            or CertificateJobState.RollbackFailed;
        if (isFailure)
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(failureStage);
            ArgumentException.ThrowIfNullOrWhiteSpace(failureSummary);
            FailureStage = failureStage.Trim();
            FailureSummary = failureSummary.Trim();
        }

        CertificateJobState previousState = State;
        State = nextState;
        Version++;
        if (IsTerminal(nextState))
            FinishedAt = occurredAt;

        _transitions.Add(new CertificateJobTransition(
            Version, previousState, nextState, occurredAt, actor.Trim(),
            isFailure ? FailureStage : null, isFailure ? FailureSummary : null));
    }

    public void SetIssuedCertificate(Guid certificateId, string fingerprint)
    {
        if (State != CertificateJobState.Signing)
            throw new InvalidOperationException("An issued certificate can only be attached while the job is signing.");
        if (certificateId == Guid.Empty)
            throw new ArgumentException("A certificate ID is required.", nameof(certificateId));
        ArgumentException.ThrowIfNullOrWhiteSpace(fingerprint);

        CertificateId = certificateId;
        CertificateFingerprint = fingerprint.Trim();
    }

    public static bool IsTerminal(CertificateJobState state) => state is
        CertificateJobState.Succeeded or CertificateJobState.Simulated or CertificateJobState.Failed or CertificateJobState.FailedRolledBack or
        CertificateJobState.RollbackFailed or CertificateJobState.Cancelled;
}
