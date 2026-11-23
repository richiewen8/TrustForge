using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;
using Npgsql;
using TrustForge.Core.CertificateAlerts;
using TrustForge.Core.Revocation;

namespace TrustForge.Persistence.Revocation;

public sealed class PostgresCertificateRevocationStore(IDbContextFactory<TrustForgeDbContext> contextFactory) : ICertificateRevocationStore
{
    public async Task<bool> TryAddAsync(CertificateRevocation revocation, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        int inserted = await db.Database.ExecuteSqlInterpolatedAsync($"""
            INSERT INTO certificate_revocations (id, service_id, job_id, fingerprint, serial, reason, requested_by, idempotency_key, requested_at, state, attempt_count, revoked_at, next_attempt_at, last_error)
            VALUES ({revocation.Id}, {revocation.ServiceId}, {revocation.JobId}, {revocation.Fingerprint}, {revocation.Serial}, {revocation.Reason.ToString()}, {revocation.RequestedBy}, {revocation.IdempotencyKey}, {revocation.RequestedAt}, {revocation.State.ToString()}, {revocation.AttemptCount}, {revocation.RevokedAt}, {revocation.NextAttemptAt}, {revocation.LastError})
            ON CONFLICT DO NOTHING
            """, cancellationToken);
        return inserted == 1;
    }

    public async Task<CertificateRevocation?> FindByIdAsync(Guid id, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        CertificateRevocationRecord? record = await db.CertificateRevocations.AsNoTracking().FirstOrDefaultAsync(item => item.Id == id, cancellationToken);
        return record is null ? null : ToDomain(record);
    }

    public async Task<CertificateRevocation?> FindByIdempotencyKeyAsync(string idempotencyKey, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        CertificateRevocationRecord? record = await db.CertificateRevocations.AsNoTracking()
            .FirstOrDefaultAsync(item => item.IdempotencyKey == idempotencyKey, cancellationToken);
        return record is null ? null : ToDomain(record);
    }

    public async Task<IReadOnlyList<CertificateRevocation>> ListAsync(Guid? serviceId, DateTimeOffset? from, DateTimeOffset? to, int limit, CancellationToken cancellationToken = default)
    {
        limit = Math.Clamp(limit, 1, 200);
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        IQueryable<CertificateRevocationRecord> query = db.CertificateRevocations.AsNoTracking();
        if (serviceId is not null)
            query = query.Where(item => item.ServiceId == serviceId);
        if (from is not null)
            query = query.Where(item => item.RequestedAt >= from);
        if (to is not null)
            query = query.Where(item => item.RequestedAt <= to);
        List<CertificateRevocationRecord> records = await query
            .OrderByDescending(item => item.RequestedAt)
            .ThenByDescending(item => item.Id)
            .Take(limit)
            .ToListAsync(cancellationToken);
        return records.Select(ToDomain).ToArray();
    }

    public async Task<CertificateRevocation?> FindLiveBySerialAsync(string serial, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        CertificateRevocationRecord? record = await db.CertificateRevocations.AsNoTracking()
            .FirstOrDefaultAsync(item => item.Serial == serial && item.State != "Failed", cancellationToken);
        return record is null ? null : ToDomain(record);
    }

    public async Task<bool> MarkRevokedAsync(Guid id, CertificateAlert alert, DateTimeOffset occurredAt, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await using IDbContextTransaction transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        // The CA revocation and its audit alert commit together, so a revoked certificate can never lack an alert.
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE certificate_revocations
            SET state = 'Revoked', revoked_at = {occurredAt}, next_attempt_at = NULL, last_error = NULL
            WHERE id = {id} AND state = 'Pending'
            """, cancellationToken);
        if (changed != 1)
        {
            await transaction.RollbackAsync(cancellationToken);
            return false;
        }

        await InsertAlertAsync(db, alert, cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return true;
    }

    public async Task<bool> MarkAttemptFailedAsync(Guid id, int expectedAttemptCount, string error, TimeSpan? retryDelay, CertificateAlert? terminalAlert, CancellationToken cancellationToken = default)
    {
        if (retryDelay < TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(retryDelay));
        bool giveUp = retryDelay is null;
        TimeSpan delay = retryDelay ?? TimeSpan.Zero;
        string lastError = error.Length <= 2000 ? error : error[..2000];

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await using IDbContextTransaction transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE certificate_revocations
            SET state = CASE WHEN {giveUp} THEN 'Failed' ELSE 'Pending' END,
                next_attempt_at = CASE WHEN {giveUp} THEN NULL ELSE clock_timestamp() + {delay} END,
                last_error = {lastError}
            WHERE id = {id} AND state = 'Pending' AND attempt_count = {expectedAttemptCount}
            """, cancellationToken);
        if (changed != 1)
        {
            await transaction.RollbackAsync(cancellationToken);
            return false;
        }

        if (giveUp && terminalAlert is not null)
            await InsertAlertAsync(db, terminalAlert, cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return true;
    }

    private static Task InsertAlertAsync(TrustForgeDbContext db, CertificateAlert alert, CancellationToken cancellationToken) => db.Database.ExecuteSqlInterpolatedAsync($"""
        INSERT INTO certificate_alerts (id, job_id, service_id, kind, severity, stage, summary, occurred_at, delivery_state, attempt_count, next_attempt_at, delivered_at, last_error, dedupe_key)
        VALUES ({alert.Id}, {alert.JobId}, {alert.ServiceId}, {alert.Kind.ToString()}, {alert.Severity.ToString()}, {alert.Stage}, {alert.Summary}, {alert.OccurredAt}, {alert.DeliveryState.ToString()}, {alert.AttemptCount}, {alert.NextAttemptAt}, {alert.DeliveredAt}, {alert.LastError}, {alert.DedupeKey})
        ON CONFLICT DO NOTHING
        """, cancellationToken);

    public async Task<IReadOnlyList<CertificateRevocation>> ClaimDueAsync(int limit, TimeSpan visibilityTimeout, CancellationToken cancellationToken = default)
    {
        if (limit is < 1 or > 100)
            throw new ArgumentOutOfRangeException(nameof(limit));
        if (visibilityTimeout <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(visibilityTimeout));

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await using IDbContextTransaction transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        List<CertificateRevocation> revocations = [];
        await using (NpgsqlCommand command = (NpgsqlCommand)db.Database.GetDbConnection().CreateCommand())
        {
            command.Transaction = (NpgsqlTransaction)transaction.GetDbTransaction();
            command.CommandText = """
                WITH candidate AS (
                    SELECT id
                    FROM certificate_revocations
                    WHERE state = 'Pending'
                      AND (next_attempt_at IS NULL OR next_attempt_at <= clock_timestamp())
                    ORDER BY requested_at, id
                    FOR UPDATE SKIP LOCKED
                    LIMIT @limit
                )
                UPDATE certificate_revocations AS revocation
                SET attempt_count = revocation.attempt_count + 1,
                    next_attempt_at = clock_timestamp() + @visibility_timeout
                FROM candidate
                WHERE revocation.id = candidate.id
                RETURNING revocation.id, revocation.service_id, revocation.job_id, revocation.fingerprint, revocation.serial,
                          revocation.reason, revocation.requested_by, revocation.idempotency_key, revocation.requested_at,
                          revocation.state, revocation.attempt_count, revocation.revoked_at, revocation.next_attempt_at, revocation.last_error;
                """;
            command.Parameters.AddWithValue("limit", limit);
            command.Parameters.AddWithValue("visibility_timeout", visibilityTimeout);
            await using NpgsqlDataReader reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                revocations.Add(new CertificateRevocation(
                    reader.GetGuid(0),
                    reader.GetGuid(1),
                    reader.GetGuid(2),
                    reader.GetString(3),
                    reader.GetString(4),
                    Enum.Parse<CertificateRevocationReason>(reader.GetString(5)),
                    reader.GetString(6),
                    reader.GetString(7),
                    reader.GetFieldValue<DateTimeOffset>(8),
                    Enum.Parse<CertificateRevocationState>(reader.GetString(9)),
                    reader.GetInt32(10),
                    reader.IsDBNull(11) ? null : reader.GetFieldValue<DateTimeOffset>(11),
                    reader.IsDBNull(12) ? null : reader.GetFieldValue<DateTimeOffset>(12),
                    reader.IsDBNull(13) ? null : reader.GetString(13)));
        }
        await transaction.CommitAsync(cancellationToken);
        return revocations;
    }

    private static CertificateRevocation ToDomain(CertificateRevocationRecord record) => new(
        record.Id,
        record.ServiceId,
        record.JobId,
        record.Fingerprint,
        record.Serial,
        Enum.Parse<CertificateRevocationReason>(record.Reason),
        record.RequestedBy,
        record.IdempotencyKey,
        record.RequestedAt,
        Enum.Parse<CertificateRevocationState>(record.State),
        record.AttemptCount,
        record.RevokedAt,
        record.NextAttemptAt,
        record.LastError);
}
