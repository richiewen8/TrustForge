using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using TrustForge.Core.CertificateJobs;
using TrustForge.Persistence.CertificateJobs;

namespace TrustForge.Persistence;

public static class PersistenceServiceCollectionExtensions
{
    public static IServiceCollection AddTrustForgePersistence(this IServiceCollection services, string connectionString)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        services.AddDbContextFactory<TrustForgeDbContext>(options =>
            options.UseNpgsql(connectionString, npgsql =>
                npgsql.MigrationsAssembly(typeof(TrustForgeDbContext).Assembly.FullName)));
        services.AddScoped<ICertificateJobStore, PostgresCertificateJobStore>();
        services.AddScoped<TrustForgeDatabaseMigrator>();
        return services;
    }
}
