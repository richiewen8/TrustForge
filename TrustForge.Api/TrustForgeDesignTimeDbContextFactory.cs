using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;
using TrustForge.Persistence;

namespace TrustForge.Api;

public sealed class TrustForgeDesignTimeDbContextFactory : IDesignTimeDbContextFactory<TrustForgeDbContext>
{
    public TrustForgeDbContext CreateDbContext(string[] args)
    {
        string connectionString = Environment.GetEnvironmentVariable("TRUSTFORGE_DESIGN_CONNECTION")
            ?? "Host=localhost;Database=trustforge_design;Username=trustforge";
        DbContextOptions<TrustForgeDbContext> options = new DbContextOptionsBuilder<TrustForgeDbContext>()
            .UseNpgsql(connectionString, npgsql =>
                npgsql.MigrationsAssembly(typeof(TrustForgeDbContext).Assembly.FullName))
            .Options;
        return new TrustForgeDbContext(options);
    }
}
