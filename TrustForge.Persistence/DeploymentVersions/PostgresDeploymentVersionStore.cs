using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;
using TrustForge.Core.CertificateJobs;
using TrustForge.Core.DeploymentVersions;

namespace TrustForge.Persistence.DeploymentVersions;

public sealed class PostgresDeploymentVersionStore(IDbContextFactory<TrustForgeDbContext> contextFactory) : IDeploymentVersionStore
{
    public async Task<bool> RecordStagedAsync(CertificateJob job, Guid leaseToken, string releaseId, DateTimeOffset certificateNotAfter, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(releaseId) || releaseId.Length > 32)
            throw new ArgumentException("A deployment release ID must contain 1 to 32 characters.", nameof(releaseId));
        string fingerprint = job.CertificateFingerprint
            ?? throw new InvalidOperationException("The job has no issued certificate fingerprint to record.");

        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        int inserted = await db.Database.ExecuteSqlInterpolatedAsync($"""
            INSERT INTO deployment_versions (id, service_id, job_id, certificate_id, fingerprint, release_id, status, health_status, staged_at, certificate_not_after)
            SELECT {Guid.NewGuid()}, {job.ServiceId}, {job.Id}, {job.CertificateId}, {fingerprint}, {releaseId}, 'Staged', 'Pending', clock_timestamp(), {certificateNotAfter}
            WHERE EXISTS (
                SELECT 1 FROM certificate_jobs j
                WHERE j.id = {job.Id} AND j.worker_lease_token = {leaseToken} AND j.worker_lease_expires_at > clock_timestamp())
            ON CONFLICT (job_id) DO NOTHING
            """, cancellationToken);
        if (inserted == 1)
            return true;

        string? existingRelease = await db.DeploymentVersions.AsNoTracking()
            .Where(version => version.JobId == job.Id)
            .Select(version => version.ReleaseId)
            .SingleOrDefaultAsync(cancellationToken);
        return existingRelease == releaseId;
    }

    public async Task<bool> MarkActiveAsync(Guid jobId, Guid leaseToken, string? previousReleaseId, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await using IDbContextTransaction transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE deployment_versions v
            SET status = 'Active',
                activated_at = CASE WHEN v.status = 'Staged' THEN clock_timestamp() ELSE v.activated_at END,
                previous_release_id = CASE WHEN v.status = 'Staged' THEN {previousReleaseId} ELSE v.previous_release_id END
            WHERE v.job_id = {jobId} AND v.status IN ('Staged','Active')
              AND EXISTS (
                  SELECT 1 FROM certificate_jobs j
                  WHERE j.id = {jobId} AND j.worker_lease_token = {leaseToken} AND j.worker_lease_expires_at > clock_timestamp())
            """, cancellationToken);
        if (changed != 1)
            return false;

        await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE deployment_versions
            SET status = 'Superseded'
            WHERE service_id = (SELECT service_id FROM deployment_versions WHERE job_id = {jobId})
              AND status = 'Active' AND job_id <> {jobId}
            """, cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return true;
    }

    public async Task<bool> MarkVerifiedAsync(Guid jobId, Guid leaseToken, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE deployment_versions
            SET health_status = 'Healthy', verified_at = COALESCE(verified_at, clock_timestamp())
            WHERE job_id = {jobId} AND status = 'Active'
              AND EXISTS (
                  SELECT 1 FROM certificate_jobs j
                  WHERE j.id = {jobId} AND j.worker_lease_token = {leaseToken} AND j.worker_lease_expires_at > clock_timestamp())
            """, cancellationToken);
        return changed == 1;
    }

    public async Task<bool> MarkRolledBackAsync(Guid jobId, Guid leaseToken, string? restoredReleaseId, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await using IDbContextTransaction transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE deployment_versions
            SET status = 'RolledBack', health_status = 'Unknown'
            WHERE job_id = {jobId} AND status IN ('Staged','Active','RolledBack')
              AND EXISTS (
                  SELECT 1 FROM certificate_jobs j
                  WHERE j.id = {jobId} AND j.worker_lease_token = {leaseToken} AND j.worker_lease_expires_at > clock_timestamp())
            """, cancellationToken);
        if (changed != 1)
            return false;

        if (restoredReleaseId is not null)
            await db.Database.ExecuteSqlInterpolatedAsync($"""
                UPDATE deployment_versions
                SET status = 'Active'
                WHERE service_id = (SELECT service_id FROM deployment_versions WHERE job_id = {jobId})
                  AND release_id = {restoredReleaseId} AND status = 'Superseded'
                """, cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return true;
    }

    public async Task<bool> MarkRollbackFailedAsync(Guid jobId, Guid leaseToken, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        int changed = await db.Database.ExecuteSqlInterpolatedAsync($"""
            UPDATE deployment_versions
            SET status = 'RollbackFailed', health_status = 'Unhealthy'
            WHERE job_id = {jobId} AND status IN ('Staged','Active','RollbackFailed')
              AND EXISTS (
                  SELECT 1 FROM certificate_jobs j
                  WHERE j.id = {jobId} AND j.worker_lease_token = {leaseToken} AND j.worker_lease_expires_at > clock_timestamp())
            """, cancellationToken);
        return changed == 1;
    }

    public async Task<IReadOnlyList<DeploymentVersion>> ListByServiceAsync(Guid serviceId, int limit, CancellationToken cancellationToken = default)
    {
        limit = Math.Clamp(limit, 1, 200);
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        List<DeploymentVersionRecord> records = await db.DeploymentVersions.AsNoTracking()
            .Where(version => version.ServiceId == serviceId)
            .OrderByDescending(version => version.StagedAt)
            .ThenByDescending(version => version.Id)
            .Take(limit)
            .ToListAsync(cancellationToken);
        return records.Select(ToDomain).ToArray();
    }

    public async Task<IReadOnlyList<DeploymentVersion>> ListAsync(Guid? serviceId, DateTimeOffset? from, DateTimeOffset? to, int limit, CancellationToken cancellationToken = default)
    {
        limit = Math.Clamp(limit, 1, 200);
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        IQueryable<DeploymentVersionRecord> query = db.DeploymentVersions.AsNoTracking();
        if (serviceId is not null)
            query = query.Where(version => version.ServiceId == serviceId);
        if (from is not null)
            query = query.Where(version => version.StagedAt >= from);
        if (to is not null)
            query = query.Where(version => version.StagedAt <= to);
        List<DeploymentVersionRecord> records = await query
            .OrderByDescending(version => version.StagedAt)
            .ThenByDescending(version => version.Id)
            .Take(limit)
            .ToListAsync(cancellationToken);
        return records.Select(ToDomain).ToArray();
    }

    private static DeploymentVersion ToDomain(DeploymentVersionRecord record) => new(
        record.Id,
        record.ServiceId,
        record.JobId,
        record.CertificateId,
        record.Fingerprint,
        record.ReleaseId,
        record.PreviousReleaseId,
        Enum.Parse<DeploymentVersionStatus>(record.Status),
        Enum.Parse<DeploymentHealthStatus>(record.HealthStatus),
        record.StagedAt,
        record.ActivatedAt,
        record.VerifiedAt,
        record.CertificateNotAfter);
}