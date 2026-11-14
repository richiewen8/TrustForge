using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace TrustForge.Persistence.Migrations;

[DbContext(typeof(TrustForgeDbContext))]
[Migration("202611140002_ManagedServices")]
public sealed class ManagedServices : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.CreateTable(
            name: "managed_services",
            columns: table => new
            {
                id = table.Column<Guid>(type: "uuid", nullable: false),
                name = table.Column<string>(type: "character varying(128)", maxLength: 128, nullable: false),
                environment = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                owner = table.Column<string>(type: "character varying(256)", maxLength: 256, nullable: false),
                host = table.Column<string>(type: "character varying(253)", maxLength: 253, nullable: false),
                port = table.Column<int>(type: "integer", nullable: false),
                host_key_fingerprint = table.Column<string>(type: "character varying(128)", maxLength: 128, nullable: false),
                ssh_credential_ref = table.Column<string>(type: "character varying(512)", maxLength: 512, nullable: false),
                profile_id = table.Column<Guid>(type: "uuid", nullable: false),
                sans = table.Column<string[]>(type: "text[]", nullable: false),
                certificate_path = table.Column<string>(type: "character varying(1024)", maxLength: 1024, nullable: false),
                chain_path = table.Column<string>(type: "character varying(1024)", maxLength: 1024, nullable: false),
                private_key_path = table.Column<string>(type: "character varying(1024)", maxLength: 1024, nullable: false),
                file_owner = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                file_group = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                file_mode = table.Column<string>(type: "character varying(4)", maxLength: 4, nullable: false),
                remote_helper_id = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                reload_action_id = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                health_check_id = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                enabled = table.Column<bool>(type: "boolean", nullable: false),
                created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                updated_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
            },
            constraints: table =>
            {
                table.PrimaryKey("pk_managed_services", x => x.id);
                table.CheckConstraint("ck_managed_services_port_range", "port BETWEEN 1 AND 65535");
            });

        migrationBuilder.CreateIndex(
            name: "ix_managed_services_enabled_environment",
            table: "managed_services",
            columns: new[] { "enabled", "environment" });
    }

    protected override void Down(MigrationBuilder migrationBuilder) => migrationBuilder.DropTable(name: "managed_services");
}
