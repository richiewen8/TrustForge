using Microsoft.EntityFrameworkCore;
using Npgsql;
using TrustForge.Core.Expiry;

namespace TrustForge.Persistence.Expiry;

public sealed class PostgresExpiryCandidateStore(IDbContextFactory<TrustForgeDbContext> contextFactory) : IExpiryCandidateStore
{
    public async Task<IReadOnlyList<ExpiringCertificate>> ListExpiringAsync(DateTimeOffset now, TimeSpan reminderWindow, CancellationToken cancellationToken = default)
    {
        if (reminderWindow <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(reminderWindow));

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await db.Database.OpenConnectionAsync(cancellationToken);
        List<ExpiringCertificate> candidates = [];
        await using NpgsqlCommand command = (NpgsqlCommand)db.Database.GetDbConnection().CreateCommand();
        // Reminders cover every enabled service regardless of renewal policy; per-certificate dedupe happens at alert insert.
        command.CommandText = """
            SELECT s.id, v.fingerprint, v.certificate_not_after
            FROM managed_services s
            JOIN deployment_versions v ON v.service_id = s.id AND v.status = 'Active'
            WHERE s.enabled
              AND v.certificate_not_after IS NOT NULL
              AND v.certificate_not_after <= @now + @window
            ORDER BY v.certificate_not_after, s.id
            LIMIT 50
            """;
        command.Parameters.AddWithValue("now", now);
        command.Parameters.AddWithValue("window", reminderWindow);
        await using NpgsqlDataReader reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            candidates.Add(new ExpiringCertificate(
                reader.GetGuid(0),
                reader.GetString(1),
                reader.GetFieldValue<DateTimeOffset>(2)));
        }

        return candidates;
    }
}