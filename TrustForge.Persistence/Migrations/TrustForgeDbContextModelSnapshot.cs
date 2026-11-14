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
            entity.HasKey("Id").HasName("pk_certificate_jobs");
            entity.HasIndex("ServiceId", "RequestedBy", "IdempotencyKey").IsUnique().HasDatabaseName("ux_certificate_jobs_idempotency");
            entity.HasIndex("State", "CreatedAt").HasDatabaseName("ix_certificate_jobs_state_created_at");
            entity.ToTable("certificate_jobs", table => table.HasCheckConstraint("ck_certificate_jobs_version_nonnegative", "version >= 0"));
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
