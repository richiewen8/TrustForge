using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace TrustForge.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class ExpiryReminders : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "ux_certificate_alerts_job_id",
                table: "certificate_alerts");

            migrationBuilder.AlterColumn<Guid>(
                name: "job_id",
                table: "certificate_alerts",
                type: "uuid",
                nullable: true,
                oldClrType: typeof(Guid),
                oldType: "uuid");

            migrationBuilder.AddColumn<string>(
                name: "dedupe_key",
                table: "certificate_alerts",
                type: "character varying(200)",
                maxLength: 200,
                nullable: true);

            migrationBuilder.CreateIndex(
                name: "ux_certificate_alerts_dedupe_key",
                table: "certificate_alerts",
                column: "dedupe_key",
                unique: true,
                filter: "dedupe_key IS NOT NULL");

            migrationBuilder.CreateIndex(
                name: "ux_certificate_alerts_job_id",
                table: "certificate_alerts",
                column: "job_id",
                unique: true,
                filter: "job_id IS NOT NULL");

            migrationBuilder.AddCheckConstraint(
                name: "ck_certificate_alerts_identity",
                table: "certificate_alerts",
                sql: "job_id IS NOT NULL OR dedupe_key IS NOT NULL");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "ux_certificate_alerts_dedupe_key",
                table: "certificate_alerts");

            migrationBuilder.DropIndex(
                name: "ux_certificate_alerts_job_id",
                table: "certificate_alerts");

            migrationBuilder.DropCheckConstraint(
                name: "ck_certificate_alerts_identity",
                table: "certificate_alerts");

            migrationBuilder.DropColumn(
                name: "dedupe_key",
                table: "certificate_alerts");

            migrationBuilder.AlterColumn<Guid>(
                name: "job_id",
                table: "certificate_alerts",
                type: "uuid",
                nullable: false,
                defaultValue: new Guid("00000000-0000-0000-0000-000000000000"),
                oldClrType: typeof(Guid),
                oldType: "uuid",
                oldNullable: true);

            migrationBuilder.CreateIndex(
                name: "ux_certificate_alerts_job_id",
                table: "certificate_alerts",
                column: "job_id",
                unique: true);
        }
    }
}
