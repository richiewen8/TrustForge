using Microsoft.EntityFrameworkCore;
using TrustForge.Persistence.CertificateJobs;
using TrustForge.Persistence.ManagedServices;

namespace TrustForge.Persistence;

public sealed class TrustForgeDbContext(DbContextOptions<TrustForgeDbContext> options) : DbContext(options)
{
    internal DbSet<CertificateJobRecord> CertificateJobs => Set<CertificateJobRecord>();
    internal DbSet<CertificateJobTransitionRecord> CertificateJobTransitions => Set<CertificateJobTransitionRecord>();
    internal DbSet<ManagedServiceRecord> ManagedServices => Set<ManagedServiceRecord>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<CertificateJobRecord>(entity =>
        {
            entity.ToTable("certificate_jobs", table =>
                table.HasCheckConstraint("ck_certificate_jobs_version_nonnegative", "version >= 0"));
            entity.HasKey(job => job.Id).HasName("pk_certificate_jobs");
            entity.Property(job => job.Id).HasColumnName("id").ValueGeneratedNever();
            entity.Property(job => job.ServiceId).HasColumnName("service_id").IsRequired();
            entity.Property(job => job.RequestedBy).HasColumnName("requested_by").HasMaxLength(256).IsRequired();
            entity.Property(job => job.IdempotencyKey).HasColumnName("idempotency_key").HasMaxLength(200).IsRequired();
            entity.Property(job => job.CreatedAt).HasColumnName("created_at").IsRequired();
            entity.Property(job => job.FinishedAt).HasColumnName("finished_at");
            entity.Property(job => job.State).HasColumnName("state").HasConversion<string>().HasMaxLength(32).IsRequired();
            entity.Property(job => job.Version).HasColumnName("version").IsConcurrencyToken();
            entity.Property(job => job.CertificateId).HasColumnName("certificate_id");
            entity.Property(job => job.CertificateFingerprint).HasColumnName("certificate_fingerprint").HasMaxLength(256);
            entity.Property(job => job.FailureStage).HasColumnName("failure_stage").HasMaxLength(100);
            entity.Property(job => job.FailureSummary).HasColumnName("failure_summary");

            entity.HasIndex(job => new { job.ServiceId, job.RequestedBy, job.IdempotencyKey })
                .IsUnique()
                .HasDatabaseName("ux_certificate_jobs_idempotency");
            entity.HasIndex(job => new { job.State, job.CreatedAt })
                .HasDatabaseName("ix_certificate_jobs_state_created_at");

            entity.HasMany(job => job.Transitions)
                .WithOne(transition => transition.Job)
                .HasForeignKey(transition => transition.JobId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<CertificateJobTransitionRecord>(entity =>
        {
            entity.ToTable("certificate_job_transitions");
            entity.HasKey(transition => new { transition.JobId, transition.Version })
                .HasName("pk_certificate_job_transitions");
            entity.Property(transition => transition.JobId).HasColumnName("job_id");
            entity.Property(transition => transition.Version).HasColumnName("version");
            entity.Property(transition => transition.From).HasColumnName("from_state").HasConversion<string>().HasMaxLength(32).IsRequired();
            entity.Property(transition => transition.To).HasColumnName("to_state").HasConversion<string>().HasMaxLength(32).IsRequired();
            entity.Property(transition => transition.OccurredAt).HasColumnName("occurred_at").IsRequired();
            entity.Property(transition => transition.Actor).HasColumnName("actor").HasMaxLength(256).IsRequired();
            entity.Property(transition => transition.FailureStage).HasColumnName("failure_stage").HasMaxLength(100);
            entity.Property(transition => transition.FailureSummary).HasColumnName("failure_summary");
        });

        modelBuilder.Entity<ManagedServiceRecord>(entity =>
        {
            entity.ToTable("managed_services", table =>
                table.HasCheckConstraint("ck_managed_services_port_range", "port BETWEEN 1 AND 65535"));
            entity.HasKey(service => service.Id).HasName("pk_managed_services");
            entity.Property(service => service.Id).HasColumnName("id").ValueGeneratedNever();
            entity.Property(service => service.Name).HasColumnName("name").HasMaxLength(128).IsRequired();
            entity.Property(service => service.Environment).HasColumnName("environment").HasMaxLength(64).IsRequired();
            entity.Property(service => service.Owner).HasColumnName("owner").HasMaxLength(256).IsRequired();
            entity.Property(service => service.Host).HasColumnName("host").HasMaxLength(253).IsRequired();
            entity.Property(service => service.Port).HasColumnName("port").IsRequired();
            entity.Property(service => service.HostKeyFingerprint).HasColumnName("host_key_fingerprint").HasMaxLength(128).IsRequired();
            entity.Property(service => service.SshCredentialRef).HasColumnName("ssh_credential_ref").HasMaxLength(512).IsRequired();
            entity.Property(service => service.ProfileId).HasColumnName("profile_id").IsRequired();
            entity.Property(service => service.Sans).HasColumnName("sans").IsRequired();
            entity.Property(service => service.CertificatePath).HasColumnName("certificate_path").HasMaxLength(1024).IsRequired();
            entity.Property(service => service.ChainPath).HasColumnName("chain_path").HasMaxLength(1024).IsRequired();
            entity.Property(service => service.PrivateKeyPath).HasColumnName("private_key_path").HasMaxLength(1024).IsRequired();
            entity.Property(service => service.FileOwner).HasColumnName("file_owner").HasMaxLength(32).IsRequired();
            entity.Property(service => service.FileGroup).HasColumnName("file_group").HasMaxLength(32).IsRequired();
            entity.Property(service => service.FileMode).HasColumnName("file_mode").HasMaxLength(4).IsRequired();
            entity.Property(service => service.RemoteHelperId).HasColumnName("remote_helper_id").HasMaxLength(64).IsRequired();
            entity.Property(service => service.ReloadActionId).HasColumnName("reload_action_id").HasMaxLength(64).IsRequired();
            entity.Property(service => service.HealthCheckId).HasColumnName("health_check_id").HasMaxLength(64).IsRequired();
            entity.Property(service => service.Enabled).HasColumnName("enabled").IsRequired();
            entity.Property(service => service.CreatedAt).HasColumnName("created_at").IsRequired();
            entity.Property(service => service.UpdatedAt).HasColumnName("updated_at").IsRequired();
            entity.HasIndex(service => new { service.Enabled, service.Environment })
                .HasDatabaseName("ix_managed_services_enabled_environment");
        });
    }
}
