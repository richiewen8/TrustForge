using Microsoft.EntityFrameworkCore;
using Npgsql;
using TrustForge.Core.Renewal;

namespace TrustForge.Persistence.Renewal;

public sealed class PostgresRenewalCandidateStore(IDbContextFactory<TrustForgeDbContext> contextFactory) : IRenewalCandidateStore
{
    public async Task<IReadOnlyList<RenewalCandidate>> ListDueAsync(DateTimeOffset now, TimeSpan minimumRenewalInterval, CancellationToken cancellationToken = default)
    {
        if (minimumRenewalInterval < TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(minimumRenewalInterval));

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await db.Database.OpenConnectionAsync(cancellationToken);
        List<RenewalCandidate> candidates = [];
        await using NpgsqlCommand command = (NpgsqlCommand)db.Database.GetDbConnection().CreateCommand();
        command.CommandText = """
            SELECT s.id, v.fingerprint, v.certificate_not_after
            FROM managed_services s
            JOIN deployment_versions v ON v.service_id = s.id AND v.status = 'Active'
            WHERE s.enabled AND s.renewal_enabled
              AND v.certificate_not_after IS NOT NULL
              AND v.certificate_not_after <= @now + s.renewal_lead_time
              AND NOT EXISTS (
                  SELECT 1 FROM certificate_jobs j
                  WHERE j.service_id = s.id
                    AND j.state IN ('Queued','Connecting','GeneratingCsr','CreatingOrder','AwaitingChallenge','Signing','Staging','Activating','Verifying'))
              AND NOT EXISTS (
                  SELECT 1 FROM certificate_jobs j
                  WHERE j.service_id = s.id
                    AND j.requested_by = @requested_by
                    AND j.created_at > @now - @minimum_interval)
            ORDER BY v.certificate_not_after, s.id
            LIMIT 50
            """;
        command.Parameters.AddWithValue("now", now);
        command.Parameters.AddWithValue("requested_by", CertificateRenewal.RequestedBy);
        command.Parameters.AddWithValue("minimum_interval", minimumRenewalInterval);
        await using NpgsqlDataReader reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            candidates.Add(new RenewalCandidate(
                reader.GetGuid(0),
                reader.GetString(1),
                reader.GetFieldValue<DateTimeOffset>(2)));
        }

        return candidates;
    }
}