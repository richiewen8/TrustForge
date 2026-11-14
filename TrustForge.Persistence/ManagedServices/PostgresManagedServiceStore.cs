using Microsoft.EntityFrameworkCore;
using Npgsql;
using TrustForge.Core.ManagedServices;

namespace TrustForge.Persistence.ManagedServices;

public sealed class PostgresManagedServiceStore(IDbContextFactory<TrustForgeDbContext> contextFactory) : IManagedServiceStore
{
    public async Task<bool> TryAddAsync(ManagedService service, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        db.ManagedServices.Add(ToRecord(service));
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

    public async Task<ManagedService?> FindByIdAsync(Guid id, CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        ManagedServiceRecord? record = await db.ManagedServices
            .AsNoTracking()
            .SingleOrDefaultAsync(service => service.Id == id, cancellationToken);
        return record is null ? null : ToDomain(record);
    }

    private static ManagedServiceRecord ToRecord(ManagedService service) => new()
    {
        Id = service.Id,
        Name = service.Name,
        Environment = service.Environment,
        Owner = service.Owner,
        Host = service.Host,
        Port = service.Port,
        HostKeyFingerprint = service.HostKeyFingerprint,
        SshCredentialRef = service.SshCredentialRef,
        ProfileId = service.ProfileId,
        Sans = service.Sans.ToArray(),
        CertificatePath = service.CertificatePath,
        ChainPath = service.ChainPath,
        PrivateKeyPath = service.PrivateKeyPath,
        FileOwner = service.FileOwner,
        FileGroup = service.FileGroup,
        FileMode = service.FileMode,
        RemoteHelperId = service.RemoteHelperId,
        ReloadActionId = service.ReloadActionId,
        HealthCheckId = service.HealthCheckId,
        Enabled = service.Enabled,
        CreatedAt = service.CreatedAt,
        UpdatedAt = service.UpdatedAt
    };

    private static ManagedService ToDomain(ManagedServiceRecord record) => new(
        record.Id, record.Name, record.Environment, record.Owner, record.Host, record.Port,
        record.HostKeyFingerprint, record.SshCredentialRef, record.ProfileId, record.Sans,
        record.CertificatePath, record.ChainPath, record.PrivateKeyPath, record.FileOwner,
        record.FileGroup, record.FileMode, record.RemoteHelperId, record.ReloadActionId,
        record.HealthCheckId, record.Enabled, record.CreatedAt, record.UpdatedAt);

    private static bool IsUniqueConstraintViolation(DbUpdateException exception)
    {
        for (Exception? current = exception; current is not null; current = current.InnerException)
        {
            if (current is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
                return true;
        }

        return false;
    }
}
