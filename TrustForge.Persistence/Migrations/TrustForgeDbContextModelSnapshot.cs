using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;

namespace TrustForge.Persistence.Migrations;

[DbContext(typeof(TrustForgeDbContext))]
public sealed class TrustForgeDbContextModelSnapshot : ModelSnapshot
{
    protected override void BuildModel(ModelBuilder modelBuilder)
    {
        modelBuilder
            .HasAnnotation("ProductVersion", "10.0.15")
            .HasAnnotation("Relational:MaxIdentifierLength", 63);

        modelBuilder.Entity("TrustForge.Persistence.CertificateJobs.CertificateJobRecord", entity =>
        {
            entity.Property<Guid>("Id").HasColumnType("uuid").HasColumnName("id");
            entity.Property<Guid>("ServiceId").IsRequired().HasColumnType("uuid").HasColumnName("service_id");
            entity.Property<string>("RequestedBy").IsRequired().HasMaxLength(256).HasColumnType("character varying(256)").HasColumnName("requested_by");
            entity.Property<string>("IdempotencyKey").IsRequired().HasMaxLength(200).HasColumnType("character varying(200)").HasColumnName("idempotency_key");
            entity.Property<DateTimeOffset>("CreatedAt").IsRequired().HasColumnType("timestamp with time zone").HasColumnName("created_at");
            entity.Property<DateTimeOffset?>("FinishedAt").HasColumnType("timestamp with time zone").HasColumnName("finished_at");
            entity.Property<string>("State").IsRequired().HasMaxLength(32).HasColumnType("character varying(32)").HasColumnName("state");
            entity.Property<long>("Version").IsConcurrencyToken().HasColumnType("bigint").HasColumnName("version");
            entity.Property<Guid?>("CertificateId").HasColumnType("uuid").HasColumnName("certificate_id");
            entity.Property<string>("CertificateFingerprint").HasMaxLength(256).HasColumnType("character varying(256)").HasColumnName("certificate_fingerprint");
            entity.Property<string>("FailureStage").HasMaxLength(100).HasColumnType("character varying(100)").HasColumnName("failure_stage");
            entity.Property<string>("FailureSummary").HasColumnType("text").HasColumnName("failure_summary");
            entity.Property<string>("WorkerLeaseOwner").HasMaxLength(128).HasColumnType("character varying(128)").HasColumnName("worker_lease_owner");
            entity.Property<Guid?>("WorkerLeaseToken").HasColumnType("uuid").HasColumnName("worker_lease_token");
            entity.Property<DateTimeOffset?>("WorkerLeaseExpiresAt").HasColumnType("timestamp with time zone").HasColumnName("worker_lease_expires_at");
            entity.Property<DateTimeOffset?>("NextAttemptAt").HasColumnType("timestamp with time zone").HasColumnName("next_attempt_at");
            entity.Property<int>("AttemptCount").IsRequired().HasColumnType("integer").HasColumnName("attempt_count");
            entity.HasKey("Id").HasName("pk_certificate_jobs");
            entity.HasIndex("ServiceId", "RequestedBy", "IdempotencyKey").IsUnique().HasDatabaseName("ux_certificate_jobs_idempotency");
            entity.HasIndex("State", "CreatedAt").HasDatabaseName("ix_certificate_jobs_state_created_at");
            entity.HasIndex("State", "NextAttemptAt", "WorkerLeaseExpiresAt", "CreatedAt").HasDatabaseName("ix_certificate_jobs_worker_claim");
            entity.ToTable("certificate_jobs", table =>
            {
                table.HasCheckConstraint("ck_certificate_jobs_version_nonnegative", "version >= 0");
                table.HasCheckConstraint("ck_certificate_jobs_attempt_count_nonnegative", "attempt_count >= 0");
                table.HasCheckConstraint("ck_certificate_jobs_lease_consistent", "(worker_lease_token IS NULL AND worker_lease_owner IS NULL AND worker_lease_expires_at IS NULL) OR (worker_lease_token IS NOT NULL AND worker_lease_owner IS NOT NULL AND worker_lease_expires_at IS NOT NULL)");
            });
        });

        modelBuilder.Entity("TrustForge.Persistence.ManagedServices.ManagedServiceRecord", entity =>
        {
            entity.Property<Guid>("Id").HasColumnType("uuid").HasColumnName("id");
            entity.Property<string>("Name").IsRequired().HasMaxLength(128).HasColumnType("character varying(128)").HasColumnName("name");
            entity.Property<string>("Environment").IsRequired().HasMaxLength(64).HasColumnType("character varying(64)").HasColumnName("environment");
            entity.Property<string>("Owner").IsRequired().HasMaxLength(256).HasColumnType("character varying(256)").HasColumnName("owner");
            entity.Property<string>("Host").IsRequired().HasMaxLength(253).HasColumnType("character varying(253)").HasColumnName("host");
            entity.Property<int>("Port").IsRequired().HasColumnType("integer").HasColumnName("port");
            entity.Property<string>("HostKeyFingerprint").IsRequired().HasMaxLength(128).HasColumnType("character varying(128)").HasColumnName("host_key_fingerprint");
            entity.Property<string>("SshCredentialRef").IsRequired().HasMaxLength(512).HasColumnType("character varying(512)").HasColumnName("ssh_credential_ref");
            entity.Property<Guid>("ProfileId").IsRequired().HasColumnType("uuid").HasColumnName("profile_id");
            entity.Property<string[]>("Sans").IsRequired().HasColumnType("text[]").HasColumnName("sans");
            entity.Property<string>("CertificatePath").IsRequired().HasMaxLength(1024).HasColumnType("character varying(1024)").HasColumnName("certificate_path");
            entity.Property<string>("ChainPath").IsRequired().HasMaxLength(1024).HasColumnType("character varying(1024)").HasColumnName("chain_path");
            entity.Property<string>("PrivateKeyPath").IsRequired().HasMaxLength(1024).HasColumnType("character varying(1024)").HasColumnName("private_key_path");
            entity.Property<string>("FileOwner").IsRequired().HasMaxLength(32).HasColumnType("character varying(32)").HasColumnName("file_owner");
            entity.Property<string>("FileGroup").IsRequired().HasMaxLength(32).HasColumnType("character varying(32)").HasColumnName("file_group");
            entity.Property<string>("FileMode").IsRequired().HasMaxLength(4).HasColumnType("character varying(4)").HasColumnName("file_mode");
            entity.Property<string>("RemoteHelperId").IsRequired().HasMaxLength(64).HasColumnType("character varying(64)").HasColumnName("remote_helper_id");
            entity.Property<string>("ReloadActionId").IsRequired().HasMaxLength(64).HasColumnType("character varying(64)").HasColumnName("reload_action_id");
            entity.Property<string>("HealthCheckId").IsRequired().HasMaxLength(64).HasColumnType("character varying(64)").HasColumnName("health_check_id");
            entity.Property<bool>("Enabled").IsRequired().HasColumnType("boolean").HasColumnName("enabled");
            entity.Property<DateTimeOffset>("CreatedAt").IsRequired().HasColumnType("timestamp with time zone").HasColumnName("created_at");
            entity.Property<DateTimeOffset>("UpdatedAt").IsRequired().HasColumnType("timestamp with time zone").HasColumnName("updated_at");
            entity.HasKey("Id").HasName("pk_managed_services");
            entity.HasIndex("Enabled", "Environment").HasDatabaseName("ix_managed_services_enabled_environment");
            entity.ToTable("managed_services", table => table.HasCheckConstraint("ck_managed_services_port_range", "port BETWEEN 1 AND 65535"));
        });

        modelBuilder.Entity("TrustForge.Persistence.CertificateJobs.CertificateJobTransitionRecord", entity =>
        {
            entity.Property<Guid>("JobId").HasColumnType("uuid").HasColumnName("job_id");
            entity.Property<long>("Version").HasColumnType("bigint").HasColumnName("version");
            entity.Property<string>("From").IsRequired().HasMaxLength(32).HasColumnType("character varying(32)").HasColumnName("from_state");
            entity.Property<string>("To").IsRequired().HasMaxLength(32).HasColumnType("character varying(32)").HasColumnName("to_state");
            entity.Property<DateTimeOffset>("OccurredAt").IsRequired().HasColumnType("timestamp with time zone").HasColumnName("occurred_at");
            entity.Property<string>("Actor").IsRequired().HasMaxLength(256).HasColumnType("character varying(256)").HasColumnName("actor");
            entity.Property<string>("FailureStage").HasMaxLength(100).HasColumnType("character varying(100)").HasColumnName("failure_stage");
            entity.Property<string>("FailureSummary").HasColumnType("text").HasColumnName("failure_summary");
            entity.HasKey("JobId", "Version").HasName("pk_certificate_job_transitions");
            entity.ToTable("certificate_job_transitions");
        });

        modelBuilder.Entity("TrustForge.Persistence.CertificateJobs.CertificateJobTransitionRecord", entity =>
        {
            entity.HasOne("TrustForge.Persistence.CertificateJobs.CertificateJobRecord", "Job")
                .WithMany("Transitions")
                .HasForeignKey("JobId")
                .OnDelete(DeleteBehavior.Cascade)
                .IsRequired();
            entity.Navigation("Job");
        });

        modelBuilder.Entity("TrustForge.Persistence.CertificateJobs.CertificateJobRecord", entity =>
        {
            entity.Navigation("Transitions");
        });
    }
}
