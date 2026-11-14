using Microsoft.EntityFrameworkCore;

namespace TrustForge.Persistence;

/// <summary>Applies checked-in EF Core migrations. The host controls when this runs.</summary>
public sealed class TrustForgeDatabaseMigrator(IDbContextFactory<TrustForgeDbContext> contextFactory)
{
    public async Task ApplyAsync(CancellationToken cancellationToken = default)
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        await db.Database.MigrateAsync(cancellationToken);
    }
}
