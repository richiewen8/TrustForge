using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace TrustForge.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class DeploymentVersionsAndAlerts : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "certificate_alerts",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    job_id = table.Column<Guid>(type: "uuid", nullable: false),
                    service_id = table.Column<Guid>(type: "uuid", nullable: false),
                    kind = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    severity = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    stage = table.Column<string>(type: "character varying(100)", maxLength: 100, nullable: false),
                    summary = table.Column<string>(type: "text", nullable: false),
                    occurred_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    delivery_state = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    attempt_count = table.Column<int>(type: "integer", nullable: false),
                    next_attempt_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    delivered_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    last_error = table.Column<string>(type: "text", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_certificate_alerts", x => x.id);
                    table.CheckConstraint("ck_certificate_alerts_attempt_count_nonnegative", "attempt_count >= 0");
                    table.CheckConstraint("ck_certificate_alerts_delivery_state", "delivery_state IN ('Pending','Delivered','Failed')");
                    table.ForeignKey(
                        name: "fk_certificate_alerts_certificate_jobs",
                        column: x => x.job_id,
                        principalTable: "certificate_jobs",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_certificate_alerts_managed_services",
                        column: x => x.service_id,
                        principalTable: "managed_services",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "deployment_versions",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    service_id = table.Column<Guid>(type: "uuid", nullable: false),
                    job_id = table.Column<Guid>(type: "uuid", nullable: false),
                    certificate_id = table.Column<Guid>(type: "uuid", nullable: true),
                    fingerprint = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    release_id = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    previous_release_id = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: true),
                    status = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    health_status = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    staged_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    activated_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    verified_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_deployment_versions", x => x.id);
                    table.CheckConstraint("ck_deployment_versions_health_status", "health_status IN ('Pending','Healthy','Unhealthy','Unknown')");
                    table.CheckConstraint("ck_deployment_versions_status", "status IN ('Staged','Active','Superseded','RolledBack','RollbackFailed')");
                    table.ForeignKey(
                        name: "fk_deployment_versions_certificate_jobs",
                        column: x => x.job_id,
                        principalTable: "certificate_jobs",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_deployment_versions_managed_services",
                        column: x => x.service_id,
                        principalTable: "managed_services",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "ix_certificate_alerts_due",
                table: "certificate_alerts",
                columns: new[] { "delivery_state", "next_attempt_at", "occurred_at" });

            migrationBuilder.CreateIndex(
                name: "IX_certificate_alerts_service_id",
                table: "certificate_alerts",
                column: "service_id");

            migrationBuilder.CreateIndex(
                name: "ux_certificate_alerts_job_id",
                table: "certificate_alerts",
                column: "job_id",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_deployment_versions_service_staged",
                table: "deployment_versions",
                columns: new[] { "service_id", "staged_at" },
                descending: new[] { false, true });

            migrationBuilder.CreateIndex(
                name: "ux_deployment_versions_job_id",
                table: "deployment_versions",
                column: "job_id",
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "certificate_alerts");

            migrationBuilder.DropTable(
                name: "deployment_versions");
        }
    }
}
