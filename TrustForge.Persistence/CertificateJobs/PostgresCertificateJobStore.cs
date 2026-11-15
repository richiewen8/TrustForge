using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;
using Npgsql;
using System.Text.Json;
using TrustForge.Core.CertificateAlerts;
using TrustForge.Core.CertificateJobs;
using TrustForge.Persistence.CertificateAlerts;

namespace TrustForge.Persistence.CertificateJobs;

public sealed class PostgresCertificateJobStore(IDbContextFactory<TrustForgeDbContext> contextFactory) : ICertificateJobStore
{
    public async Task<CertificateJob?> FindByIdAsync(Guid id, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        CertificateJobRecord? record = await db.CertificateJobs
            .AsNoTracking()
            .Include(job => job.Transitions)
            .SingleOrDefaultAsync(job => job.Id == id, cancellationToken);
        return record is null ? null : ToDomain(record);
    }

    public async Task<CertificateJob?> FindByIdempotencyKeyAsync(
        Guid serviceId,
        string requestedBy,
        string idempotencyKey,
        CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        CertificateJobRecord? record = await db.CertificateJobs
            .AsNoTracking()
            .Include(job => job.Transitions)
            .SingleOrDefaultAsync(job => job.ServiceId == serviceId
                && job.RequestedBy == requestedBy.Trim()
                && job.IdempotencyKey == idempotencyKey.Trim(), cancellationToken);
        return record is null ? null : ToDomain(record);
    }

    public async Task<bool> TryAddAsync(CertificateJob job, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await using IDbContextTransaction transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        db.CertificateJobs.Add(ToRecord(job));
        try
        {
            await db.SaveChangesAsync(cancellationToken);
        }
        catch (DbUpdateException exception) when (IsUniqueConstraintViolation(exception))
        {
            if (HasConstraint(exception, "ux_certificate_jobs_active_service"))
                throw new CertificateJobActiveConflictException(job.ServiceId);
            return false;
        }

        // Transactional NOTIFY: listeners wake only on commit, so submission and wake are atomic; polling stays the fallback.
        await using (NpgsqlCommand command = (NpgsqlCommand)db.Database.GetDbConnection().CreateCommand())
        {
            command.Transaction = (NpgsqlTransaction)transaction.GetDbTransaction();
            command.CommandText = $"NOTIFY {PostgresJobSubmissionChannel.SubmissionChannelName}";
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        await transaction.CommitAsync(cancellationToken);
        return true;
    }

    public async Task<bool> TryUpdateAsync(CertificateJob job, long expectedVersion, CertificateAlert? alert = null, CancellationToken cancellationToken = default)
    {
        if (job.Version != expectedVersion + 1 || job.Transitions.Count == 0 || job.Transitions[^1].Version != job.Version)
            throw new InvalidOperationException("A persisted update must contain exactly one new versioned transition.");

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        CertificateJobRecord record = ToRecord(job, includeTransitions: false);
        var entry = db.Attach(record);
        entry.State = EntityState.Modified;
        entry.Property(item => item.Id).IsModified = false;
        entry.Property(item => item.Version).OriginalValue = expectedVersion;
        entry.Property(item => item.WorkerLeaseOwner).IsModified = false;
        entry.Property(item => item.WorkerLeaseToken).IsModified = false;
        entry.Property(item => item.WorkerLeaseExpiresAt).IsModified = false;
        entry.Property(item => item.NextAttemptAt).IsModified = false;
        entry.Property(item => item.AttemptCount).IsModified = false;
        entry.Property(item => item.ExecutionCheckpoint).IsModified = false;

        db.CertificateJobTransitions.Add(ToRecord(job.Id, job.Transitions[^1]));
        if (alert is not null)
            db.CertificateAlerts.Add(ToRecord(alert));
        try
        {
            await db.SaveChangesAsync(cancellationToken);
            return true;
        }
        catch (DbUpdateConcurrencyException)
        {
            return false;
        }
    }

    public async Task<LeasedCertificateJob?> TryClaimNextAsync(string owner, TimeSpan leaseDuration, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(owner) || owner.Trim().Length > 128)
            throw new ArgumentException("Worker owner must contain 1 to 128 characters.", nameof(owner));
        if (leaseDuration <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(leaseDuration));

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        Guid token = Guid.NewGuid();
        Guid? jobId;
        DateTimeOffset expiresAt;
        int attemptCount;
        await using IDbContextTransaction transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        await using (NpgsqlCommand command = (NpgsqlCommand)db.Database.GetDbConnection().CreateCommand())
        {
            command.Transaction = (NpgsqlTransaction)transaction.GetDbTransaction();
            command.CommandText = $"""
                WITH candidate AS (
                    SELECT id
                    FROM certificate_jobs
                    WHERE state IN ('Queued','Connecting','GeneratingCsr','CreatingOrder','AwaitingChallenge','Signing','Staging','Activating','Verifying')
                      AND (next_attempt_at IS NULL OR next_attempt_at <= clock_timestamp())
                      AND (worker_lease_expires_at IS NULL OR worker_lease_expires_at <= clock_timestamp())
                    ORDER BY created_at, id
                    FOR UPDATE SKIP LOCKED
                    LIMIT 1
                )
                UPDATE certificate_jobs AS job
                SET worker_lease_owner = @owner,
                    worker_lease_token = @token,
                    worker_lease_expires_at = clock_timestamp() + @lease_duration,
                    next_attempt_at = NULL,
                    attempt_count = attempt_count + 1
                FROM candidate
                WHERE job.id = candidate.id
                RETURNING job.id, job.worker_lease_expires_at, job.attempt_count;
                """;
            command.Parameters.AddWithValue("owner", owner.Trim());
            command.Parameters.AddWithValue("token", token);
            command.Parameters.AddWithValue("lease_duration", leaseDuration);
            await using NpgsqlDataReader reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return null;
            jobId = reader.GetGuid(0);
            expiresAt = reader.GetFieldValue<DateTimeOffset>(1);
            attemptCount = reader.GetInt32(2);
        }
        await transaction.CommitAsync(cancellationToken);

        CertificateJob? job = await FindByIdAsync(jobId!.Value, cancellationToken);
        return job is null ? null : new LeasedCertificateJob(job, new CertificateJobLease(owner.Trim(), token, expiresAt, attemptCount));
    }

    public async Task<bool> RenewLeaseAsync(Guid jobId, Guid leaseToken, TimeSpan leaseDuration, CancellationToken cancellationToken = default)
    {
        if (leaseDuration <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(leaseDuration));
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE certificate_jobs
            SET worker_lease_expires_at = clock_timestamp() + {leaseDuration}
            WHERE id = {jobId}
              AND worker_lease_token = {leaseToken}
              AND worker_lease_expires_at > clock_timestamp()
              AND state IN ('Queued','Connecting','GeneratingCsr','CreatingOrder','AwaitingChallenge','Signing','Staging','Activating','Verifying')
            """, cancellationToken);
        return changed == 1;
    }

    public async Task<bool> ReleaseLeaseAsync(Guid jobId, Guid leaseToken, TimeSpan retryDelay, CancellationToken cancellationToken = default)
    {
        if (retryDelay < TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(retryDelay));
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE certificate_jobs
            SET worker_lease_owner = NULL,
                worker_lease_token = NULL,
                worker_lease_expires_at = NULL,
                next_attempt_at = clock_timestamp() + {retryDelay}
            WHERE id = {jobId} AND worker_lease_token = {leaseToken}
            """, cancellationToken);
        return changed == 1;
    }

    public async Task<bool> TryUpdateLeasedAsync(CertificateJob job, long expectedVersion, Guid leaseToken, CertificateAlert? alert = null, CancellationToken cancellationToken = default)
    {
        if (job.Version != expectedVersion + 1 || job.Transitions.Count == 0 || job.Transitions[^1].Version != job.Version)
            throw new InvalidOperationException("A persisted update must contain exactly one new versioned transition.");

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await using IDbContextTransaction transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        // A nullable DateTimeOffset parameter used only in IS NOT NULL has no inferable SQL type (42P18); pass a typed bool instead.
        bool finished = job.FinishedAt is not null;
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE certificate_jobs
            SET state = {job.State.ToString()}, version = {job.Version}, finished_at = {job.FinishedAt},
                certificate_id = {job.CertificateId}, certificate_fingerprint = {job.CertificateFingerprint},
                failure_stage = {job.FailureStage}, failure_summary = {job.FailureSummary},
                worker_lease_owner = CASE WHEN {finished} THEN NULL ELSE worker_lease_owner END,
                worker_lease_token = CASE WHEN {finished} THEN NULL ELSE worker_lease_token END,
                worker_lease_expires_at = CASE WHEN {finished} THEN NULL ELSE worker_lease_expires_at END
            WHERE id = {job.Id} AND version = {expectedVersion}
              AND worker_lease_token = {leaseToken}
              AND worker_lease_expires_at > clock_timestamp()
            """, cancellationToken);
        if (changed != 1)
            return false;

        db.CertificateJobTransitions.Add(ToRecord(job.Id, job.Transitions[^1]));
        if (alert is not null)
            db.CertificateAlerts.Add(ToRecord(alert));
        await db.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return true;
    }

    public async Task<bool> TryUpdateCheckpointLeasedAsync(
        Guid jobId,
        long expectedVersion,
        Guid leaseToken,
        CertificateJobCheckpoint checkpoint,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(checkpoint);
        string json = JsonSerializer.Serialize(checkpoint);
        if (json.Length > 65536)
            throw new ArgumentException("The execution checkpoint must not exceed 64 KiB.", nameof(checkpoint));

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE certificate_jobs
            SET execution_checkpoint = CAST({json} AS jsonb)
            WHERE id = {jobId} AND version = {expectedVersion}
              AND worker_lease_token = {leaseToken}
              AND worker_lease_expires_at > clock_timestamp()
              AND state IN ('Queued','Connecting','GeneratingCsr','CreatingOrder','AwaitingChallenge','Signing','Staging','Activating','Verifying')
            """, cancellationToken);
        return changed == 1;
    }

    public async Task<bool> TryAttachCertificateLeasedAsync(Guid jobId, long expectedVersion, Guid leaseToken, Guid certificateId, string fingerprint, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE certificate_jobs
            SET certificate_id = {certificateId}, certificate_fingerprint = {fingerprint}
            WHERE id = {jobId} AND version = {expectedVersion}
              AND worker_lease_token = {leaseToken}
              AND worker_lease_expires_at > clock_timestamp()
              AND state = 'Signing'
            """, cancellationToken);
        return changed == 1;
    }

    public async Task<IReadOnlyList<CertificateJob>> ListAsync(Guid? serviceId, DateTimeOffset? from, DateTimeOffset? to, int limit, CancellationToken cancellationToken = default)
    {
        limit = Math.Clamp(limit, 1, 200);
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        IQueryable<CertificateJobRecord> query = db.CertificateJobs.AsNoTracking().Include(job => job.Transitions);
        if (serviceId is not null)
            query = query.Where(job => job.ServiceId == serviceId);
        if (from is not null)
            query = query.Where(job => job.CreatedAt >= from);
        if (to is not null)
            query = query.Where(job => job.CreatedAt <= to);
        List<CertificateJobRecord> records = await query
            .OrderByDescending(job => job.CreatedAt)
            .ThenByDescending(job => job.Id)
            .Take(limit)
            .ToListAsync(cancellationToken);
        return records.Select(ToDomain).ToArray();
    }

    private static bool IsUniqueConstraintViolation(DbUpdateException exception)
    {
        for (Exception? current = exception; current is not null; current = current.InnerException)
        {
            if (current is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
                return true;
        }

        return false;
    }

    private static bool HasConstraint(DbUpdateException exception, string constraintName)
    {
        for (Exception? current = exception; current is not null; current = current.InnerException)
        {
            if (current is PostgresException postgres && postgres.ConstraintName == constraintName)
                return true;
        }

        return false;
    }

    private static CertificateJobRecord ToRecord(CertificateJob job, bool includeTransitions = true)
    {
        CertificateJobRecord record = new()
        {
            Id = job.Id,
            ServiceId = job.ServiceId,
            RequestedBy = job.RequestedBy,
            IdempotencyKey = job.IdempotencyKey,
            CreatedAt = job.CreatedAt,
            FinishedAt = job.FinishedAt,
            State = job.State.ToString(),
            Version = job.Version,
            CertificateId = job.CertificateId,
            CertificateFingerprint = job.CertificateFingerprint,
            FailureStage = job.FailureStage,
            FailureSummary = job.FailureSummary,
            ExecutionCheckpoint = JsonSerializer.Serialize(job.Checkpoint)
        };

        if (includeTransitions)
            record.Transitions.AddRange(job.Transitions.Select(transition => ToRecord(job.Id, transition)));
        return record;
    }

    private static CertificateAlertRecord ToRecord(CertificateAlert alert) => new()
    {
        Id = alert.Id,
        JobId = alert.JobId,
        ServiceId = alert.ServiceId,
        Kind = alert.Kind.ToString(),
        Severity = alert.Severity.ToString(),
        Stage = alert.Stage,
        Summary = alert.Summary,
        OccurredAt = alert.OccurredAt,
        DeliveryState = alert.DeliveryState.ToString(),
        AttemptCount = alert.AttemptCount,
        NextAttemptAt = alert.NextAttemptAt,
        DeliveredAt = alert.DeliveredAt,
        LastError = alert.LastError,
        DedupeKey = alert.DedupeKey
    };

    private static CertificateJobTransitionRecord ToRecord(Guid jobId, CertificateJobTransition transition) => new()
    {
        JobId = jobId,
        Version = transition.Version,
        From = transition.From.ToString(),
        To = transition.To.ToString(),
        OccurredAt = transition.OccurredAt,
        Actor = transition.Actor,
        FailureStage = transition.FailureStage,
        FailureSummary = transition.FailureSummary
    };

    private static CertificateJob ToDomain(CertificateJobRecord record)
    {
        CertificateJobTransition[] transitions = record.Transitions
            .Select(item => new CertificateJobTransition(
                item.Version,
                Enum.Parse<CertificateJobState>(item.From),
                Enum.Parse<CertificateJobState>(item.To),
                item.OccurredAt,
                item.Actor,
                item.FailureStage,
                item.FailureSummary))
            .ToArray();

        return CertificateJob.Restore(
            record.Id,
            record.ServiceId,
            record.RequestedBy,
            record.IdempotencyKey,
            record.CreatedAt,
            record.FinishedAt,
            Enum.Parse<CertificateJobState>(record.State),
            record.Version,
            record.CertificateId,
            record.CertificateFingerprint,
            record.FailureStage,
            record.FailureSummary,
            transitions,
            JsonSerializer.Deserialize<CertificateJobCheckpoint>(record.ExecutionCheckpoint));
    }
}
