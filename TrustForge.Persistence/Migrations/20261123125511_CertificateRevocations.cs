using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace TrustForge.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class CertificateRevocations : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "certificate_revocations",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    service_id = table.Column<Guid>(type: "uuid", nullable: false),
                    job_id = table.Column<Guid>(type: "uuid", nullable: false),
                    fingerprint = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    serial = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    reason = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    requested_by = table.Column<string>(type: "character varying(256)", maxLength: 256, nullable: false),
                    idempotency_key = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: false),
                    requested_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    state = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    attempt_count = table.Column<int>(type: "integer", nullable: false),
                    revoked_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    next_attempt_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    last_error = table.Column<string>(type: "text", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_certificate_revocations", x => x.id);
                    table.CheckConstraint("ck_certificate_revocations_attempt_count_nonnegative", "attempt_count >= 0");
                    table.CheckConstraint("ck_certificate_revocations_failed_error", "state <> 'Failed' OR last_error IS NOT NULL");
                    table.CheckConstraint("ck_certificate_revocations_reason", "reason IN ('Unspecified','KeyCompromise','CaCompromise','AffiliationChanged','Superseded','CessationOfOperation')");
                    table.CheckConstraint("ck_certificate_revocations_revoked_at", "state = 'Revoked' OR revoked_at IS NULL");
                    table.CheckConstraint("ck_certificate_revocations_state", "state IN ('Pending','Revoked','Failed')");
                    table.ForeignKey(
                        name: "fk_certificate_revocations_certificate_jobs",
                        column: x => x.job_id,
                        principalTable: "certificate_jobs",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_certificate_revocations_managed_services",
                        column: x => x.service_id,
                        principalTable: "managed_services",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "ix_certificate_revocations_due",
                table: "certificate_revocations",
                columns: new[] { "state", "next_attempt_at", "requested_at" });

            migrationBuilder.CreateIndex(
                name: "ix_certificate_revocations_job_id",
                table: "certificate_revocations",
                column: "job_id");

            migrationBuilder.CreateIndex(
                name: "ix_certificate_revocations_service_requested",
                table: "certificate_revocations",
                columns: new[] { "service_id", "requested_at" },
                descending: new[] { false, true });

            migrationBuilder.CreateIndex(
                name: "ux_certificate_revocations_idempotency",
                table: "certificate_revocations",
                column: "idempotency_key",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ux_certificate_revocations_live_serial",
                table: "certificate_revocations",
                column: "serial",
                unique: true,
                filter: "state <> 'Failed'");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "certificate_revocations");
        }
    }
}
