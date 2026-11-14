using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace TrustForge.Persistence.Migrations;

[DbContext(typeof(TrustForgeDbContext))]
[Migration("202611140004_CertificateJobExecutionCheckpoint")]
public sealed class CertificateJobExecutionCheckpoint : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.AddColumn<string>(
        name: "execution_checkpoint",
        table: "certificate_jobs",
        type: "jsonb",
        nullable: false,
        defaultValue: "{}");

    protected override void Down(MigrationBuilder migrationBuilder) =>
        migrationBuilder.DropColumn(name: "execution_checkpoint", table: "certificate_jobs");
}
