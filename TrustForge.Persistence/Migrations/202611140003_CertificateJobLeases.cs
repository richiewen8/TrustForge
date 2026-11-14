using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace TrustForge.Persistence.Migrations;

[DbContext(typeof(TrustForgeDbContext))]
[Migration("202611140003_CertificateJobLeases")]
public sealed class CertificateJobLeases : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.AddColumn<string>(
            name: "worker_lease_owner", table: "certificate_jobs",
            type: "character varying(128)", maxLength: 128, nullable: true);
        migrationBuilder.AddColumn<Guid>(
            name: "worker_lease_token", table: "certificate_jobs", type: "uuid", nullable: true);
        migrationBuilder.AddColumn<DateTimeOffset>(
            name: "worker_lease_expires_at", table: "certificate_jobs", type: "timestamp with time zone", nullable: true);
        migrationBuilder.AddColumn<DateTimeOffset>(
            name: "next_attempt_at", table: "certificate_jobs", type: "timestamp with time zone", nullable: true);
        migrationBuilder.AddColumn<int>(
            name: "attempt_count", table: "certificate_jobs", type: "integer", nullable: false, defaultValue: 0);

        migrationBuilder.AddCheckConstraint(
            name: "ck_certificate_jobs_lease_consistent",
            table: "certificate_jobs",
            sql: "(worker_lease_token IS NULL AND worker_lease_owner IS NULL AND worker_lease_expires_at IS NULL) OR (worker_lease_token IS NOT NULL AND worker_lease_owner IS NOT NULL AND worker_lease_expires_at IS NOT NULL)");
        migrationBuilder.AddCheckConstraint(
            name: "ck_certificate_jobs_attempt_count_nonnegative",
            table: "certificate_jobs",
            sql: "attempt_count >= 0");
        migrationBuilder.CreateIndex(
            name: "ix_certificate_jobs_worker_claim",
            table: "certificate_jobs",
            columns: new[] { "state", "next_attempt_at", "worker_lease_expires_at", "created_at" });
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropIndex(name: "ix_certificate_jobs_worker_claim", table: "certificate_jobs");
        migrationBuilder.DropCheckConstraint(name: "ck_certificate_jobs_lease_consistent", table: "certificate_jobs");
        migrationBuilder.DropCheckConstraint(name: "ck_certificate_jobs_attempt_count_nonnegative", table: "certificate_jobs");
        migrationBuilder.DropColumn(name: "worker_lease_owner", table: "certificate_jobs");
        migrationBuilder.DropColumn(name: "worker_lease_token", table: "certificate_jobs");
        migrationBuilder.DropColumn(name: "worker_lease_expires_at", table: "certificate_jobs");
        migrationBuilder.DropColumn(name: "next_attempt_at", table: "certificate_jobs");
        migrationBuilder.DropColumn(name: "attempt_count", table: "certificate_jobs");
    }
}
