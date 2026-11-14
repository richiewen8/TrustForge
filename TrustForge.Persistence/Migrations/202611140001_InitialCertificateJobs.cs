using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace TrustForge.Persistence.Migrations;

[DbContext(typeof(TrustForgeDbContext))]
[Migration("202611140001_InitialCertificateJobs")]
public sealed class InitialCertificateJobs : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.CreateTable(
            name: "certificate_jobs",
            columns: table => new
            {
                id = table.Column<Guid>(type: "uuid", nullable: false),
                service_id = table.Column<Guid>(type: "uuid", nullable: false),
                requested_by = table.Column<string>(type: "character varying(256)", maxLength: 256, nullable: false),
                idempotency_key = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: false),
                created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                finished_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                state = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                version = table.Column<long>(type: "bigint", nullable: false),
                certificate_id = table.Column<Guid>(type: "uuid", nullable: true),
                certificate_fingerprint = table.Column<string>(type: "character varying(256)", maxLength: 256, nullable: true),
                failure_stage = table.Column<string>(type: "character varying(100)", maxLength: 100, nullable: true),
                failure_summary = table.Column<string>(type: "text", nullable: true)
            },
            constraints: table =>
            {
                table.PrimaryKey("pk_certificate_jobs", x => x.id);
                table.CheckConstraint("ck_certificate_jobs_version_nonnegative", "version >= 0");
            });

        migrationBuilder.CreateTable(
            name: "certificate_job_transitions",
            columns: table => new
            {
                job_id = table.Column<Guid>(type: "uuid", nullable: false),
                version = table.Column<long>(type: "bigint", nullable: false),
                from_state = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                to_state = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                occurred_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                actor = table.Column<string>(type: "character varying(256)", maxLength: 256, nullable: false),
                failure_stage = table.Column<string>(type: "character varying(100)", maxLength: 100, nullable: true),
                failure_summary = table.Column<string>(type: "text", nullable: true)
            },
            constraints: table =>
            {
                table.PrimaryKey("pk_certificate_job_transitions", x => new { x.job_id, x.version });
                table.ForeignKey(
                    name: "fk_certificate_job_transitions_certificate_jobs_job_id",
                    column: x => x.job_id,
                    principalTable: "certificate_jobs",
                    principalColumn: "id",
                    onDelete: ReferentialAction.Cascade);
            });

        migrationBuilder.CreateIndex(
            name: "ux_certificate_jobs_idempotency",
            table: "certificate_jobs",
            columns: new[] { "service_id", "requested_by", "idempotency_key" },
            unique: true);
        migrationBuilder.CreateIndex(
            name: "ix_certificate_jobs_state_created_at",
            table: "certificate_jobs",
            columns: new[] { "state", "created_at" });
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropTable(name: "certificate_job_transitions");
        migrationBuilder.DropTable(name: "certificate_jobs");
    }
}
