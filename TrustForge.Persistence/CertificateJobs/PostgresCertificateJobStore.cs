using Microsoft.EntityFrameworkCore;
using Npgsql;
using TrustForge.Core.CertificateJobs;

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
        db.CertificateJobs.Add(ToRecord(job));
        try
        {
            await db.SaveChangesAsync(cancellationToken);
            return true;
        }
        catch (DbUpdateException exception) when (IsUniqueConstraintViolation(exception))
        {
            return false;
        }
    }

    public async Task<bool> TryUpdateAsync(CertificateJob job, long expectedVersion, CancellationToken cancellationToken = default)
    {
        if (job.Version != expectedVersion + 1 || job.Transitions.Count == 0 || job.Transitions[^1].Version != job.Version)
            throw new InvalidOperationException("A persisted update must contain exactly one new versioned transition.");

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        CertificateJobRecord record = ToRecord(job, includeTransitions: false);
        var entry = db.Attach(record);
        entry.State = EntityState.Modified;
        entry.Property(item => item.Id).IsModified = false;
        entry.Property(item => item.Version).OriginalValue = expectedVersion;

        db.CertificateJobTransitions.Add(ToRecord(job.Id, job.Transitions[^1]));
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

    private static bool IsUniqueConstraintViolation(DbUpdateException exception)
    {
        for (Exception? current = exception; current is not null; current = current.InnerException)
        {
            if (current is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
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
            FailureSummary = job.FailureSummary
        };

        if (includeTransitions)
            record.Transitions.AddRange(job.Transitions.Select(transition => ToRecord(job.Id, transition)));
        return record;
    }

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
            transitions);
    }
}
