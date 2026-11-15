using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace TrustForge.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class RenewalAndActiveJobGuard : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "renewal_enabled",
                table: "managed_services",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<TimeSpan>(
                name: "renewal_lead_time",
                table: "managed_services",
                type: "interval",
                nullable: false,
                defaultValue: new TimeSpan(0, 0, 0, 0, 0));

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "certificate_not_after",
                table: "deployment_versions",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.CreateIndex(
                name: "ux_certificate_jobs_active_service",
                table: "certificate_jobs",
                column: "service_id",
                unique: true,
                filter: "state IN ('Queued','Connecting','GeneratingCsr','CreatingOrder','AwaitingChallenge','Signing','Staging','Activating','Verifying')");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "ux_certificate_jobs_active_service",
                table: "certificate_jobs");

            migrationBuilder.DropColumn(
                name: "renewal_enabled",
                table: "managed_services");

            migrationBuilder.DropColumn(
                name: "renewal_lead_time",
                table: "managed_services");

            migrationBuilder.DropColumn(
                name: "certificate_not_after",
                table: "deployment_versions");
        }
    }
}
