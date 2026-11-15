using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using TrustForge.Core.CertificateAlerts;
using TrustForge.Core.CertificateJobs;
using TrustForge.Core.DeploymentVersions;
using TrustForge.Core.Expiry;
using TrustForge.Core.ManagedServices;
using TrustForge.Core.Renewal;
using TrustForge.Persistence.CertificateAlerts;
using TrustForge.Persistence.CertificateJobs;
using TrustForge.Persistence.DeploymentVersions;
using TrustForge.Persistence.Expiry;
using TrustForge.Persistence.ManagedServices;
using TrustForge.Persistence.Renewal;

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
        services.AddScoped<IManagedServiceStore, PostgresManagedServiceStore>();
        services.AddScoped<IDeploymentVersionStore, PostgresDeploymentVersionStore>();
        services.AddScoped<ICertificateAlertStore, PostgresCertificateAlertStore>();
        services.AddScoped<IRenewalCandidateStore, PostgresRenewalCandidateStore>();
        services.AddScoped<IExpiryCandidateStore, PostgresExpiryCandidateStore>();
        services.AddScoped<TrustForgeDatabaseMigrator>();
        services.AddSingleton<IJobSubmissionChannel>(sp =>
            new PostgresJobSubmissionChannel(connectionString, sp.GetRequiredService<ILogger<PostgresJobSubmissionChannel>>()));
        return services;
    }
}
