using Microsoft.EntityFrameworkCore;
using TrustForge.Persistence.CertificateAlerts;
using TrustForge.Persistence.CertificateJobs;
using TrustForge.Persistence.DeploymentVersions;
using TrustForge.Persistence.ManagedServices;

namespace TrustForge.Persistence;

public sealed class TrustForgeDbContext(DbContextOptions<TrustForgeDbContext> options) : DbContext(options)
{
    internal DbSet<CertificateJobRecord> CertificateJobs => Set<CertificateJobRecord>();
    internal DbSet<CertificateJobTransitionRecord> CertificateJobTransitions => Set<CertificateJobTransitionRecord>();
    internal DbSet<ManagedServiceRecord> ManagedServices => Set<ManagedServiceRecord>();
    internal DbSet<DeploymentVersionRecord> DeploymentVersions => Set<DeploymentVersionRecord>();
    internal DbSet<CertificateAlertRecord> CertificateAlerts => Set<CertificateAlertRecord>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<CertificateJobRecord>(entity =>
        {
            entity.ToTable("certificate_jobs", table =>
            {
                table.HasCheckConstraint("ck_certificate_jobs_version_nonnegative", "version >= 0");
                table.HasCheckConstraint("ck_certificate_jobs_attempt_count_nonnegative", "attempt_count >= 0");
                table.HasCheckConstraint("ck_certificate_jobs_lease_consistent", "(worker_lease_token IS NULL AND worker_lease_owner IS NULL AND worker_lease_expires_at IS NULL) OR (worker_lease_token IS NOT NULL AND worker_lease_owner IS NOT NULL AND worker_lease_expires_at IS NOT NULL)");
            });
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
            entity.Property(job => job.WorkerLeaseOwner).HasColumnName("worker_lease_owner").HasMaxLength(128);
            entity.Property(job => job.WorkerLeaseToken).HasColumnName("worker_lease_token");
            entity.Property(job => job.WorkerLeaseExpiresAt).HasColumnName("worker_lease_expires_at");
            entity.Property(job => job.NextAttemptAt).HasColumnName("next_attempt_at");
            entity.Property(job => job.AttemptCount).HasColumnName("attempt_count").IsRequired();
            entity.Property(job => job.ExecutionCheckpoint).HasColumnName("execution_checkpoint").HasColumnType("jsonb").IsRequired();

            entity.HasIndex(job => new { job.ServiceId, job.RequestedBy, job.IdempotencyKey })
                .IsUnique()
                .HasDatabaseName("ux_certificate_jobs_idempotency");
            entity.HasIndex(job => new { job.State, job.CreatedAt })
                .HasDatabaseName("ix_certificate_jobs_state_created_at");
            entity.HasIndex(job => new { job.State, job.NextAttemptAt, job.WorkerLeaseExpiresAt, job.CreatedAt })
                .HasDatabaseName("ix_certificate_jobs_worker_claim");
            entity.HasIndex(job => job.ServiceId)
                .IsUnique()
                .HasDatabaseName("ux_certificate_jobs_active_service")
                .HasFilter("state IN ('Queued','Connecting','GeneratingCsr','CreatingOrder','AwaitingChallenge','Signing','Staging','Activating','Verifying')");

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
            entity.Property(service => service.RenewalEnabled).HasColumnName("renewal_enabled").IsRequired();
            entity.Property(service => service.RenewalLeadTime).HasColumnName("renewal_lead_time").IsRequired();
            entity.Property(service => service.Enabled).HasColumnName("enabled").IsRequired();
            entity.Property(service => service.CreatedAt).HasColumnName("created_at").IsRequired();
            entity.Property(service => service.UpdatedAt).HasColumnName("updated_at").IsRequired();
            entity.HasIndex(service => new { service.Enabled, service.Environment })
                .HasDatabaseName("ix_managed_services_enabled_environment");
        });

        modelBuilder.Entity<DeploymentVersionRecord>(entity =>
        {
            entity.ToTable("deployment_versions", table =>
            {
                table.HasCheckConstraint("ck_deployment_versions_status", "status IN ('Staged','Active','Superseded','RolledBack','RollbackFailed')");
                table.HasCheckConstraint("ck_deployment_versions_health_status", "health_status IN ('Pending','Healthy','Unhealthy','Unknown')");
            });
            entity.HasKey(version => version.Id).HasName("pk_deployment_versions");
            entity.Property(version => version.Id).HasColumnName("id").ValueGeneratedNever();
            entity.Property(version => version.ServiceId).HasColumnName("service_id").IsRequired();
            entity.Property(version => version.JobId).HasColumnName("job_id").IsRequired();
            entity.Property(version => version.CertificateId).HasColumnName("certificate_id");
            entity.Property(version => version.Fingerprint).HasColumnName("fingerprint").HasMaxLength(64).IsRequired();
            entity.Property(version => version.ReleaseId).HasColumnName("release_id").HasMaxLength(32).IsRequired();
            entity.Property(version => version.PreviousReleaseId).HasColumnName("previous_release_id").HasMaxLength(32);
            entity.Property(version => version.Status).HasColumnName("status").HasMaxLength(32).IsRequired();
            entity.Property(version => version.HealthStatus).HasColumnName("health_status").HasMaxLength(32).IsRequired();
            entity.Property(version => version.StagedAt).HasColumnName("staged_at").IsRequired();
            entity.Property(version => version.ActivatedAt).HasColumnName("activated_at");
            entity.Property(version => version.VerifiedAt).HasColumnName("verified_at");
            entity.Property(version => version.CertificateNotAfter).HasColumnName("certificate_not_after");

            entity.HasIndex(version => version.JobId)
                .IsUnique()
                .HasDatabaseName("ux_deployment_versions_job_id");
            entity.HasIndex(version => new { version.ServiceId, version.StagedAt })
                .IsDescending(false, true)
                .HasDatabaseName("ix_deployment_versions_service_staged");

            entity.HasOne<CertificateJobRecord>()
                .WithMany()
                .HasForeignKey(version => version.JobId)
                .OnDelete(DeleteBehavior.Cascade)
                .HasConstraintName("fk_deployment_versions_certificate_jobs");
            entity.HasOne<ManagedServiceRecord>()
                .WithMany()
                .HasForeignKey(version => version.ServiceId)
                .OnDelete(DeleteBehavior.Cascade)
                .HasConstraintName("fk_deployment_versions_managed_services");
        });

        modelBuilder.Entity<CertificateAlertRecord>(entity =>
        {
            entity.ToTable("certificate_alerts", table =>
            {
                table.HasCheckConstraint("ck_certificate_alerts_delivery_state", "delivery_state IN ('Pending','Delivered','Failed')");
                table.HasCheckConstraint("ck_certificate_alerts_attempt_count_nonnegative", "attempt_count >= 0");
                table.HasCheckConstraint("ck_certificate_alerts_identity", "job_id IS NOT NULL OR dedupe_key IS NOT NULL");
            });
            entity.HasKey(alert => alert.Id).HasName("pk_certificate_alerts");
            entity.Property(alert => alert.Id).HasColumnName("id").ValueGeneratedNever();
            entity.Property(alert => alert.JobId).HasColumnName("job_id");
            entity.Property(alert => alert.ServiceId).HasColumnName("service_id").IsRequired();
            entity.Property(alert => alert.Kind).HasColumnName("kind").HasMaxLength(32).IsRequired();
            entity.Property(alert => alert.Severity).HasColumnName("severity").HasMaxLength(16).IsRequired();
            entity.Property(alert => alert.Stage).HasColumnName("stage").HasMaxLength(100).IsRequired();
            entity.Property(alert => alert.Summary).HasColumnName("summary").IsRequired();
            entity.Property(alert => alert.OccurredAt).HasColumnName("occurred_at").IsRequired();
            entity.Property(alert => alert.DeliveryState).HasColumnName("delivery_state").HasMaxLength(16).IsRequired();
            entity.Property(alert => alert.AttemptCount).HasColumnName("attempt_count").IsRequired();
            entity.Property(alert => alert.NextAttemptAt).HasColumnName("next_attempt_at");
            entity.Property(alert => alert.DeliveredAt).HasColumnName("delivered_at");
            entity.Property(alert => alert.LastError).HasColumnName("last_error");
            entity.Property(alert => alert.DedupeKey).HasColumnName("dedupe_key").HasMaxLength(200);

            entity.HasIndex(alert => alert.JobId)
                .IsUnique()
                .HasDatabaseName("ux_certificate_alerts_job_id")
                .HasFilter("job_id IS NOT NULL");
            entity.HasIndex(alert => alert.DedupeKey)
                .IsUnique()
                .HasDatabaseName("ux_certificate_alerts_dedupe_key")
                .HasFilter("dedupe_key IS NOT NULL");
            entity.HasIndex(alert => new { alert.DeliveryState, alert.NextAttemptAt, alert.OccurredAt })
                .HasDatabaseName("ix_certificate_alerts_due");

            entity.HasOne<CertificateJobRecord>()
                .WithMany()
                .HasForeignKey(alert => alert.JobId)
                .OnDelete(DeleteBehavior.Cascade)
                .HasConstraintName("fk_certificate_alerts_certificate_jobs");
            entity.HasOne<ManagedServiceRecord>()
                .WithMany()
                .HasForeignKey(alert => alert.ServiceId)
                .OnDelete(DeleteBehavior.Cascade)
                .HasConstraintName("fk_certificate_alerts_managed_services");
        });
    }
}
