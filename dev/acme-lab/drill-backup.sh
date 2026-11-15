#!/usr/bin/env bash
# Phase 6 backup drill: captures a consistent backup of the whole lab state —
# PostgreSQL (pg_dump -Fc), the step-ca / artifacts / dns-config named volumes,
# the SSH target's writable layer (registrations, releases, job keys, alerts) and
# the host-side secrets — then writes secrets/backup/manifest.json with row counts
# and the dump hash so drill-restore.sh can assert a faithful restore.
# The lab is brought back up afterwards; this drill is non-destructive.
# NOTE: the backup contains sensitive material (CA keys, target private keys);
# secrets/ is gitignored. Treat a real backup with the same care.
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1

if [ ! -f .env ] || [ ! -f secrets/lab-state.json ]; then
    echo "Run ./setup.sh first." >&2
    exit 1
fi
if ! python -c 'import json,sys
state = json.load(open("secrets/lab-state.json", encoding="utf-8"))
sys.exit(0 if "drillServiceId" in state else 1)'; then
    echo "Run ./drill-deployment.sh before drill-backup.sh." >&2
    exit 1
fi
set -a; . ./.env; set +a

API="http://127.0.0.1:${LAB_API_PORT:-5080}"
OIDC="http://127.0.0.1:${LAB_OIDC_PORT:-8280}"
PG_USER="${LAB_POSTGRES_USER:-trustforge}"
PG_DB="${LAB_POSTGRES_DB:-trustforge_lab}"
BACKUP_DIR="secrets/backup"

compose() { docker compose "$@"; }

json_get() {
    python -c 'import json,sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(value if not isinstance(value, (dict, list)) else json.dumps(value))' "$1"
}

wait_for() {
    local description="$1" attempts="$2"
    shift 2
    local i
    for i in $(seq 1 "$attempts"); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    echo "Timed out waiting for $description." >&2
    return 1
}

psql_query() {
    compose exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -tAc "$1" | tr -d '[:space:]'
}

# Tars a named volume read-only through a helper container. --entrypoint sh is
# required: the target image ENTRYPOINT otherwise starts lab services and blocks.
tar_volume() {
    local volume="$1" outfile="$2"
    docker run --rm -v "trustforge-acme-lab_$volume:/data:ro" --entrypoint sh trustforge-lab-target:local \
        -c 'tar -czf - -C /data .' > "$outfile"
}

mkdir -p "$BACKUP_DIR"
backup_job_id=$(json_get jobId < secrets/lab-state.json)

echo "== Quiescing writers (stop trustforge, keycloak, step-ca) =="
compose stop keycloak trustforge step-ca

echo "== Dumping PostgreSQL =="
compose exec -T postgres pg_dump -U "$PG_USER" -d "$PG_DB" -Fc > "$BACKUP_DIR/trustforge.dump"
dump_sha256=$(sha256sum "$BACKUP_DIR/trustforge.dump" | cut -d' ' -f1)

echo "== Archiving named volumes =="
tar_volume lab-stepca-data "$BACKUP_DIR/stepca.tar.gz"
tar_volume lab-artifacts "$BACKUP_DIR/artifacts.tar.gz"
tar_volume lab-dns-config "$BACKUP_DIR/dns-config.tar.gz"

echo "== Archiving the target writable layer =="
compose exec -T target tar -czf - -C / \
    etc/trustforge var/lib/trustforge etc/trustforge-demo var/lib/trustforge-demo \
    > "$BACKUP_DIR/target.tar.gz"

echo "== Copying host-side secrets =="
mkdir -p "$BACKUP_DIR/secrets-copy/ssh"
cp secrets/root_ca.crt secrets/acme-account.pem secrets/dns-api-token secrets/ssh-credential.json secrets/lab-state.json "$BACKUP_DIR/secrets-copy/"
cp secrets/ssh/id_ed25519 secrets/ssh/id_ed25519.pub secrets/ssh/authorized_keys "$BACKUP_DIR/secrets-copy/ssh/"

echo "== Writing the manifest =="
services_count=$(psql_query "SELECT count(*) FROM managed_services")
jobs_count=$(psql_query "SELECT count(*) FROM certificate_jobs")
versions_count=$(psql_query "SELECT count(*) FROM deployment_versions")
alerts_count=$(psql_query "SELECT count(*) FROM certificate_alerts")
python -c 'import json,sys
manifest = {
    "backupJobId": sys.argv[1],
    "dumpSha256": sys.argv[2],
    "counts": {
        "managed_services": int(sys.argv[3]),
        "certificate_jobs": int(sys.argv[4]),
        "deployment_versions": int(sys.argv[5]),
        "certificate_alerts": int(sys.argv[6]),
    },
}
json.dump(manifest, open("secrets/backup/manifest.json", "w", encoding="utf-8"), indent=2)' \
    "$backup_job_id" "$dump_sha256" "$services_count" "$jobs_count" "$versions_count" "$alerts_count"

echo "== Bringing the lab back up =="
compose up -d step-ca trustforge keycloak
wait_for "API readiness" 90 curl -fsS "$API/health/ready"
wait_for "Keycloak token" 90 curl -fsS -X POST "$OIDC/realms/trustforge-dev/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=trustforge-cli \
    --data-urlencode "username=$LAB_OIDC_DEV_USERNAME" --data-urlencode "password=$LAB_OIDC_DEV_PASSWORD"

echo "Backup complete: $BACKUP_DIR (jobs=$jobs_count versions=$versions_count alerts=$alerts_count services=$services_count)."
echo "Run ./drill-restore.sh to restore into a fresh lab and assert recovery."