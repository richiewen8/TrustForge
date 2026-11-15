using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;
using Npgsql;
using TrustForge.Core.CertificateAlerts;

namespace TrustForge.Persistence.CertificateAlerts;

public sealed class PostgresCertificateAlertStore(IDbContextFactory<TrustForgeDbContext> contextFactory) : ICertificateAlertStore
{
    public async Task<IReadOnlyList<CertificateAlert>> ClaimDueAsync(int limit, TimeSpan visibilityTimeout, CancellationToken cancellationToken = default)
    {
        if (limit is < 1 or > 100)
            throw new ArgumentOutOfRangeException(nameof(limit));
        if (visibilityTimeout <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(visibilityTimeout));

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await using IDbContextTransaction transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        List<CertificateAlert> alerts = [];
        await using (NpgsqlCommand command = (NpgsqlCommand)db.Database.GetDbConnection().CreateCommand())
        {
            command.Transaction = (NpgsqlTransaction)transaction.GetDbTransaction();
            // Claiming pushes next_attempt_at into the future as a visibility timeout; a lost worker's claims become due again.
            command.CommandText = """
                WITH candidate AS (
                    SELECT id
                    FROM certificate_alerts
                    WHERE delivery_state = 'Pending'
                      AND (next_attempt_at IS NULL OR next_attempt_at <= clock_timestamp())
                    ORDER BY occurred_at, id
                    FOR UPDATE SKIP LOCKED
                    LIMIT @limit
                )
                UPDATE certificate_alerts AS alert
                SET attempt_count = alert.attempt_count + 1,
                    next_attempt_at = clock_timestamp() + @visibility_timeout
                FROM candidate
                WHERE alert.id = candidate.id
                RETURNING alert.id, alert.job_id, alert.service_id, alert.kind, alert.severity, alert.stage, alert.summary,
                          alert.occurred_at, alert.delivery_state, alert.attempt_count, alert.next_attempt_at, alert.delivered_at, alert.last_error, alert.dedupe_key;
                """;
            command.Parameters.AddWithValue("limit", limit);
            command.Parameters.AddWithValue("visibility_timeout", visibilityTimeout);
            await using NpgsqlDataReader reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                alerts.Add(new CertificateAlert(
                    reader.GetGuid(0),
                    reader.IsDBNull(1) ? null : reader.GetGuid(1),
                    reader.GetGuid(2),
                    Enum.Parse<CertificateAlertKind>(reader.GetString(3)),
                    Enum.Parse<CertificateAlertSeverity>(reader.GetString(4)),
                    reader.GetString(5),
                    reader.GetString(6),
                    reader.GetFieldValue<DateTimeOffset>(7),
                    Enum.Parse<CertificateAlertDeliveryState>(reader.GetString(8)),
                    reader.GetInt32(9),
                    reader.IsDBNull(10) ? null : reader.GetFieldValue<DateTimeOffset>(10),
                    reader.IsDBNull(11) ? null : reader.GetFieldValue<DateTimeOffset>(11),
                    reader.IsDBNull(12) ? null : reader.GetString(12),
                    reader.IsDBNull(13) ? null : reader.GetString(13)));
        }
        await transaction.CommitAsync(cancellationToken);
        return alerts;
    }

    public async Task<bool> TryAddAsync(CertificateAlert alert, CancellationToken cancellationToken = default)
    {
        if (alert.JobId is null && alert.DedupeKey is null)
            throw new ArgumentException("An alert must carry either a job ID or a dedupe key.", nameof(alert));

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        // No conflict target: covers both partial unique indexes (job_id for failure alerts, dedupe_key for reminders).
        int inserted = await db.Database.ExecuteSqlInterpolatedAsync($"""
            INSERT INTO certificate_alerts (id, job_id, service_id, kind, severity, stage, summary, occurred_at, delivery_state, attempt_count, next_attempt_at, delivered_at, last_error, dedupe_key)
            VALUES ({alert.Id}, {alert.JobId}, {alert.ServiceId}, {alert.Kind.ToString()}, {alert.Severity.ToString()}, {alert.Stage}, {alert.Summary}, {alert.OccurredAt}, {alert.DeliveryState.ToString()}, {alert.AttemptCount}, {alert.NextAttemptAt}, {alert.DeliveredAt}, {alert.LastError}, {alert.DedupeKey})
            ON CONFLICT DO NOTHING
            """, cancellationToken);
        return inserted == 1;
    }

    public async Task<bool> MarkDeliveredAsync(Guid id, int expectedAttemptCount, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE certificate_alerts
            SET delivery_state = 'Delivered', delivered_at = clock_timestamp(), next_attempt_at = NULL, last_error = NULL
            WHERE id = {id} AND delivery_state = 'Pending' AND attempt_count = {expectedAttemptCount}
            """, cancellationToken);
        return changed == 1;
    }

    public async Task<bool> MarkAttemptFailedAsync(Guid id, int expectedAttemptCount, string error, TimeSpan? retryDelay, CancellationToken cancellationToken = default)
    {
        if (retryDelay < TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(retryDelay));
        bool giveUp = retryDelay is null;
        TimeSpan delay = retryDelay ?? TimeSpan.Zero;
        string lastError = error.Length <= 2000 ? error : error[..2000];

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE certificate_alerts
            SET delivery_state = CASE WHEN {giveUp} THEN 'Failed' ELSE 'Pending' END,
                next_attempt_at = CASE WHEN {giveUp} THEN NULL ELSE clock_timestamp() + {delay} END,
                last_error = {lastError}
            WHERE id = {id} AND delivery_state = 'Pending' AND attempt_count = {expectedAttemptCount}
            """, cancellationToken);
        return changed == 1;
    }

    public async Task<IReadOnlyList<CertificateAlert>> ListAsync(Guid? serviceId, CertificateAlertDeliveryState? deliveryState, DateTimeOffset? from, DateTimeOffset? to, int limit, CancellationToken cancellationToken = default)
    {
        limit = Math.Clamp(limit, 1, 200);
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        IQueryable<CertificateAlertRecord> query = db.CertificateAlerts.AsNoTracking();
        if (serviceId is not null)
            query = query.Where(alert => alert.ServiceId == serviceId);
        if (deliveryState is not null)
        {
            string state = deliveryState.Value.ToString();
            query = query.Where(alert => alert.DeliveryState == state);
        }
        if (from is not null)
            query = query.Where(alert => alert.OccurredAt >= from);
        if (to is not null)
            query = query.Where(alert => alert.OccurredAt <= to);
        List<CertificateAlertRecord> records = await query
            .OrderByDescending(alert => alert.OccurredAt)
            .ThenByDescending(alert => alert.Id)
            .Take(limit)
            .ToListAsync(cancellationToken);
        return records.Select(ToDomain).ToArray();
    }

    private static CertificateAlert ToDomain(CertificateAlertRecord record) => new(
        record.Id,
        record.JobId,
        record.ServiceId,
        Enum.Parse<CertificateAlertKind>(record.Kind),
        Enum.Parse<CertificateAlertSeverity>(record.Severity),
        record.Stage,
        record.Summary,
        record.OccurredAt,
        Enum.Parse<CertificateAlertDeliveryState>(record.DeliveryState),
        record.AttemptCount,
        record.NextAttemptAt,
        record.DeliveredAt,
        record.LastError,
        record.DedupeKey);
}