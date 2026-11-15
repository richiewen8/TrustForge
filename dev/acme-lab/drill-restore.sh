#!/usr/bin/env bash
# Phase 6 restore drill: destroys the lab (down -v) and rebuilds it purely from
# secrets/backup, proving an operator can recover PostgreSQL, the CA config/keys
# and the target deployment state from a backup alone.
#
# Critical ordering (see OPERATIONS.md):
#  * pg_restore runs BEFORE trustforge starts, so its --migrate is a no-op.
#  * the step-ca volume is restored BEFORE step-ca first starts, otherwise
#    DOCKER_STEPCA_INIT_* re-initializes a brand-new CA on the empty volume.
#  * the target image is NEVER rebuilt here: its SSH host keys are baked into the
#    image, and rebuilding would change the pinned host-key fingerprint.
#  * keycloak is brought up with `up -d` (not restart): recreating trustforge
#    invalidates the shared network namespace.
# After restore it asserts row counts match the manifest, then issues a fresh svc1
# job end-to-end to prove the recovered CA keys and target state actually work.
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1

if [ ! -f .env ] || [ ! -f secrets/backup/manifest.json ] || [ ! -f secrets/backup/trustforge.dump ]; then
    echo "Run ./drill-backup.sh first." >&2
    exit 1
fi
set -a; . ./.env; set +a

API="http://127.0.0.1:${LAB_API_PORT:-5080}"
OIDC="http://127.0.0.1:${LAB_OIDC_PORT:-8280}"
TLS_PORT="${LAB_TARGET_TLS_PORT:-8443}"
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

restore_volume() {
    local volume="$1" infile="$2"
    docker run --rm -i -v "trustforge-acme-lab_$volume:/data" --entrypoint sh trustforge-lab-target:local \
        -c 'tar -xzf - -C /data' < "$infile"
}

service_id=$(json_get serviceId < secrets/lab-state.json)
backup_job_id=$(python -c 'import json; print(json.load(open("secrets/backup/manifest.json", encoding="utf-8"))["backupJobId"])')

echo "== Destroying the lab (down -v) =="
compose down -v

echo "== Restoring PostgreSQL =="
compose up -d postgres
wait_for "PostgreSQL readiness" 90 compose exec -T postgres pg_isready -U "$PG_USER" -d "$PG_DB"
compose exec -T postgres pg_restore -U "$PG_USER" -d "$PG_DB" --no-owner --no-privileges --exit-on-error \
    < "$BACKUP_DIR/trustforge.dump"

echo "== Restoring named volumes before their services start =="
restore_volume lab-stepca-data "$BACKUP_DIR/stepca.tar.gz"
restore_volume lab-artifacts "$BACKUP_DIR/artifacts.tar.gz"
restore_volume lab-dns-config "$BACKUP_DIR/dns-config.tar.gz"

echo "== Starting step-ca on the restored CA state =="
compose up -d step-ca
wait_for "step-ca health" 90 compose exec -T step-ca step ca health

echo "== Starting the target and restoring its writable layer =="
# Existing image only: host keys are baked in and must not change.
compose up -d target
wait_for "target SSH" 60 compose exec -T target true
compose exec -T target tar -xzf - -C / < "$BACKUP_DIR/target.tar.gz"
compose restart target

echo "== Starting trustforge (migrate no-op) and keycloak =="
compose up -d trustforge
wait_for "API readiness" 90 curl -fsS "$API/health/ready"
compose up -d keycloak
access_token=""
for _ in $(seq 1 90); do
    access_token=$(curl -fsS -X POST "$OIDC/realms/trustforge-dev/protocol/openid-connect/token" \
        -d grant_type=password -d client_id=trustforge-cli \
        --data-urlencode "username=$LAB_OIDC_DEV_USERNAME" --data-urlencode "password=$LAB_OIDC_DEV_PASSWORD" 2>/dev/null | json_get access_token) && break
    sleep 2
done
if [ -z "$access_token" ]; then
    echo "Keycloak did not issue a token after restore." >&2
    exit 1
fi

echo "== Asserting restored row counts match the manifest =="
for table in managed_services certificate_jobs deployment_versions certificate_alerts; do
    expected=$(python -c "import json; print(json.load(open('secrets/backup/manifest.json', encoding='utf-8'))['counts']['$table'])")
    actual=$(psql_query "SELECT count(*) FROM $table")
    if [ "$actual" != "$expected" ]; then
        echo "Restored $table count $actual != manifest $expected." >&2
        exit 1
    fi
    echo "  $table: $actual rows (matches manifest)"
done

echo "== Issuing a fresh svc1 job to prove the recovered CA keys and target state =="
fresh_job_id=$(curl -fsS -X POST "$API/api/v1/services/$service_id/certificate-jobs" \
    -H "Authorization: Bearer $access_token" -H "Idempotency-Key: lab-restore-$(date +%s)" | json_get id)
state=""
for _ in $(seq 1 150); do
    state=$(curl -fsS "$API/api/v1/certificate-jobs/$fresh_job_id" -H "Authorization: Bearer $access_token" | json_get state)
    case "$state" in
        Succeeded|Failed|FailedRolledBack|RollbackFailed|Cancelled) break ;;
    esac
    sleep 2
done
if [ "$state" != "Succeeded" ]; then
    echo "Post-restore job $fresh_job_id ended in '$state', expected Succeeded." >&2
    exit 1
fi
fresh_fingerprint=$(curl -fsS "$API/api/v1/certificate-jobs/$fresh_job_id" -H "Authorization: Bearer $access_token" | json_get certificateFingerprint)
served_fingerprint=$(echo | openssl s_client -connect "127.0.0.1:$TLS_PORT" 2>/dev/null | openssl x509 -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1 || true)
if [ "$(printf '%s' "$fresh_fingerprint" | tr 'A-F' 'a-f')" != "$served_fingerprint" ]; then
    echo "Post-restore served certificate does not match the fresh job." >&2
    exit 1
fi
echo "Post-restore job $fresh_job_id reached Succeeded; served certificate matches."

python -c 'import json,sys
path = "secrets/lab-state.json"
state = json.load(open(path, encoding="utf-8"))
state["jobId"] = sys.argv[1]
state["restoreDrill"] = {"backupJobId": sys.argv[2], "postRestoreJobId": sys.argv[1]}
json.dump(state, open(path, "w", encoding="utf-8"))' \
    "$fresh_job_id" "$backup_job_id"

echo "Restore drill complete. Run ./drill-renewal.sh then ./verify.sh."