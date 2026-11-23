#!/usr/bin/env bash
# Phase 1 migration-upgrade drill: builds a database at the
# 202611150001_DeploymentVersionsAndAlerts baseline, seeds production-like rows,
# and upgrades it through the REAL product path (one-off `TrustForge.dll --migrate`
# containers) to 202611150003_ExpiryReminders. Proves: delta-only upgrade, data
# preservation, defaults on existing rows, idempotent re-run, new-shape writes,
# and that the new active-job guard rejects a dirty database (rolled back).
# Uses ONLY disposable side databases inside the lab postgres; never touches
# trustforge_lab data or the running app/keycloak containers.
# Runs AFTER drill-notification.sh and BEFORE drill-renewal.sh (keeps the
# renewal -> verify 2-minute window intact; see README).
set -euo pipefail
cd "$(dirname "$0")"
# Container paths like /etc/... must not be rewritten to Windows paths by Git Bash.
export MSYS_NO_PATHCONV=1

if [ ! -f .env ] || [ ! -f secrets/lab-state.json ]; then
    echo "Run ./setup.sh first." >&2
    exit 1
fi
set -a; . ./.env; set +a

PG_USER="${LAB_POSTGRES_USER:-trustforge}"
PG_DB="${LAB_POSTGRES_DB:-trustforge_lab}"
UPG_DB="trustforge_upgrade"
UPG_BAD_DB="trustforge_upgrade_bad"
BASELINE_MIGRATION="202611150001_DeploymentVersionsAndAlerts"
TARGET_MIGRATION="202611150003_ExpiryReminders"   # update when the migration chain grows
IMAGE="trustforge:acme-lab"
LAB_NETWORK="trustforge-acme-lab_lab"
BASELINE_SQL="secrets/upgrade-baseline.sql"
SEED_SQL="secrets/upgrade-seed.sql"

if [ "$PG_DB" = "$UPG_DB" ] || [ "$PG_DB" = "$UPG_BAD_DB" ]; then
    echo "Refusing to run: drill database name collides with LAB_POSTGRES_DB." >&2
    exit 1
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "Run ./setup.sh first (missing $IMAGE)." >&2; exit 1; }
command -v dotnet >/dev/null || { echo "dotnet SDK + dotnet-ef are required on the host." >&2; exit 1; }

compose() { docker compose "$@"; }

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

upg_query() { compose exec -T postgres psql -U "$PG_USER" -d "$UPG_DB" -tAc "$1" | tr -d '[:space:]'; }
bad_query() { compose exec -T postgres psql -U "$PG_USER" -d "$UPG_BAD_DB" -tAc "$1" | tr -d '[:space:]'; }

assert_eq() {
    if [ "$3" != "$2" ]; then
        echo "FAIL: $1 (expected '$2', got '$3')" >&2
        exit 1
    fi
    echo "  ok: $1 = $3"
}

# DROP DATABASE cannot run inside a multi-statement implicit transaction, so each
# statement gets its own -c flag. Only ever targets the hardcoded drill names.
reset_db() {
    compose exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
        -c "DROP DATABASE IF EXISTS $1 WITH (FORCE)" -c "CREATE DATABASE $1"
}

# The real product upgrade path: override the baked shell entrypoint so only
# `TrustForge.dll --migrate` runs (Program.cs applies migrations then returns).
run_migrator() {
    docker run --rm --network "$LAB_NETWORK" --entrypoint dotnet \
        -e ASPNETCORE_ENVIRONMENT=Production \
        -e ConnectionStrings__TrustForge="Host=postgres;Port=5432;Database=$1;Username=$PG_USER;Password=$LAB_POSTGRES_PASSWORD" \
        "$IMAGE" TrustForge.dll --migrate >"$2" 2>&1
}

expect_rejection() {
    local label="$1" sql="$2" token="$3" rc=0
    set +e
    compose exec -T postgres psql -U "$PG_USER" -d "$UPG_DB" -v ON_ERROR_STOP=1 -c "$sql" \
        > secrets/upgrade-reject.log 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: $label was accepted." >&2
        exit 1
    fi
    if ! grep -q "$token" secrets/upgrade-reject.log; then
        echo "FAIL: $label rejected for the wrong reason (see secrets/upgrade-reject.log)." >&2
        exit 1
    fi
    echo "  ok: $label rejected via $token"
}

wait_for "PostgreSQL readiness" 30 compose exec -T postgres pg_isready -U "$PG_USER" -d "$PG_DB"

echo "== Generating baseline schema SQL (offline, migrations 1-5) =="
# The 10.0.14 ef tools cannot resolve a named migration target in `script`
# (tools/runtime version mismatch), but the full script works. Generate the full
# script and keep the transaction blocks up to and including the baseline.
( cd ../.. && dotnet ef migrations script \
    --project TrustForge.Persistence --startup-project TrustForge.Api \
    --output dev/acme-lab/secrets/upgrade-full.sql )
python -c 'import sys
baseline = sys.argv[1]
full = open("secrets/upgrade-full.sql", encoding="utf-8").read()
marker = "START TRANSACTION;"
parts = full.split(marker)
out = [parts[0]]
found = False
for block in parts[1:]:
    out.append(marker + block)
    if baseline in block:
        found = True
        break
if not found:
    sys.exit("Baseline migration not found in the full script.")
open("secrets/upgrade-baseline.sql", "w", encoding="utf-8").write("".join(out))' "$BASELINE_MIGRATION"
assert_eq "baseline script embeds 5 history INSERTs" 5 \
    "$(grep -c 'INSERT INTO "__EFMigrationsHistory"' "$BASELINE_SQL" | tr -d '[:space:]')"
# Derived from the generated script rather than hard-coded, so a new migration cannot silently
# turn this drill's "complete" assertion into a stale expectation.
TOTAL_HISTORY=$(grep -c 'INSERT INTO "__EFMigrationsHistory"' secrets/upgrade-full.sql | tr -d '[:space:]')
POST_BASELINE_COUNT=$((TOTAL_HISTORY - 5))
echo "  ok: schema has $TOTAL_HISTORY migrations, $POST_BASELINE_COUNT after the baseline"

echo "== Creating $UPG_DB at the baseline =="
reset_db "$UPG_DB"
compose exec -T postgres psql -U "$PG_USER" -d "$UPG_DB" -v ON_ERROR_STOP=1 < "$BASELINE_SQL"
assert_eq "baseline history rows" 5 "$(upg_query 'SELECT count(*) FROM "__EFMigrationsHistory"')"
assert_eq "renewal_enabled absent before upgrade" 0 \
    "$(upg_query "SELECT count(*) FROM information_schema.columns WHERE table_name='managed_services' AND column_name='renewal_enabled'")"
assert_eq "active-job guard absent before upgrade" 0 \
    "$(upg_query "SELECT count(*) FROM pg_indexes WHERE indexname='ux_certificate_jobs_active_service'")"

echo "== Seeding production-like rows at the baseline schema =="
cat > "$SEED_SQL" <<'SQL'
INSERT INTO managed_services (
    id, name, environment, owner, host, port, host_key_fingerprint, ssh_credential_ref,
    profile_id, sans, certificate_path, chain_path, private_key_path,
    file_owner, file_group, file_mode, remote_helper_id, reload_action_id, health_check_id,
    enabled, created_at, updated_at)
VALUES
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'svc-a.trustforge.lab', 'lab', 'lab-operator',
 'svc-a.trustforge.lab', 8443, 'SHA256:' || repeat('A', 43),
 'secret://file//run/trustforge/secrets/ssh-credential.json',
 'e0000000-0000-4000-8000-000000000001', ARRAY['svc-a.trustforge.lab'],
 '/etc/trustforge-demo/current/certificate.pem', '/etc/trustforge-demo/current/chain.pem',
 '/etc/trustforge-demo/current/private-key.pem', 'root', 'root', '0600',
 'trustforge-certctl-v1', 'demo-tls-reload', 'demo-tls-health',
 true, '2026-11-14T00:00:00+00', '2026-11-14T00:00:00+00'),
('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'svc-b.trustforge.lab', 'lab', 'lab-operator',
 'svc-b.trustforge.lab', 8443, 'SHA256:' || repeat('B', 43),
 'secret://file//run/trustforge/secrets/ssh-credential.json',
 'e0000000-0000-4000-8000-000000000002', ARRAY['svc-b.trustforge.lab'],
 '/etc/trustforge-demo/current/certificate.pem', '/etc/trustforge-demo/current/chain.pem',
 '/etc/trustforge-demo/current/private-key.pem', 'root', 'root', '0600',
 'trustforge-certctl-v1', 'demo-tls-reload', 'demo-tls-health',
 true, '2026-11-14T00:00:00+00', '2026-11-14T00:00:00+00');

INSERT INTO certificate_jobs (
    id, service_id, requested_by, idempotency_key, created_at, finished_at, state, version,
    certificate_id, certificate_fingerprint, failure_stage, failure_summary,
    attempt_count, execution_checkpoint)
VALUES
('a0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 'lab-operator', 'drill-a-ok', '2026-11-14T01:00:00+00', '2026-11-14T01:05:00+00',
 'Succeeded', 3, 'f0000000-0000-4000-8000-000000000001', repeat('ab', 32), NULL, NULL, 0,
 '{"AcmeOrderUrl":"https://step-ca:9000/acme/acme/order/drill-a1","DnsChallenges":[{"AuthorizationUrl":"https://step-ca:9000/acme/acme/authz/drill-a1","RecordName":"_acme-challenge.svc-a.trustforge.lab","TxtValue":"drill-txt-value"}],"CertificateArtifactRef":"a0000000-0000-4000-8000-000000000001.certificate.json","DeploymentReleaseId":"rel-a-0002","PreviousReleaseId":"rel-a-0001"}'),
('a0000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 'lab-operator', 'drill-a-fail', '2026-11-14T02:00:00+00', '2026-11-14T02:03:00+00',
 'Failed', 3, NULL, NULL, 'Staging', 'helper refused staging: disk full', 2, DEFAULT),
('a0000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 'lab-operator', 'drill-a-queued', '2026-11-14T03:00:00+00', NULL,
 'Queued', 0, NULL, NULL, NULL, NULL, 0, DEFAULT),
('b0000000-0000-4000-8000-000000000001', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
 'lab-operator', 'drill-b-ok', '2026-11-14T00:30:00+00', '2026-11-14T00:35:00+00',
 'Succeeded', 2, 'f0000000-0000-4000-8000-000000000002', repeat('cd', 32), NULL, NULL, 0, DEFAULT),
('b0000000-0000-4000-8000-000000000002', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
 'lab-operator', 'drill-b-fail', '2026-11-14T04:00:00+00', '2026-11-14T04:01:00+00',
 'Failed', 2, NULL, NULL, 'AwaitingChallenge', 'zone not allowed', 1, DEFAULT);

INSERT INTO certificate_job_transitions (job_id, version, from_state, to_state, occurred_at, actor, failure_stage, failure_summary) VALUES
('a0000000-0000-4000-8000-000000000001', 1, 'Queued', 'Connecting', '2026-11-14T01:01:00+00', 'worker:lab', NULL, NULL),
('a0000000-0000-4000-8000-000000000001', 2, 'Connecting', 'Signing', '2026-11-14T01:02:00+00', 'worker:lab', NULL, NULL),
('a0000000-0000-4000-8000-000000000001', 3, 'Signing', 'Succeeded', '2026-11-14T01:05:00+00', 'worker:lab', NULL, NULL),
('a0000000-0000-4000-8000-000000000002', 1, 'Queued', 'Connecting', '2026-11-14T02:01:00+00', 'worker:lab', NULL, NULL),
('a0000000-0000-4000-8000-000000000002', 2, 'Connecting', 'Staging', '2026-11-14T02:02:00+00', 'worker:lab', NULL, NULL),
('a0000000-0000-4000-8000-000000000002', 3, 'Staging', 'Failed', '2026-11-14T02:03:00+00', 'worker:lab', 'Staging', 'helper refused staging: disk full'),
('b0000000-0000-4000-8000-000000000001', 1, 'Queued', 'Connecting', '2026-11-14T00:31:00+00', 'worker:lab', NULL, NULL),
('b0000000-0000-4000-8000-000000000001', 2, 'Connecting', 'Succeeded', '2026-11-14T00:35:00+00', 'worker:lab', NULL, NULL),
('b0000000-0000-4000-8000-000000000002', 1, 'Queued', 'Connecting', '2026-11-14T04:00:30+00', 'worker:lab', NULL, NULL),
('b0000000-0000-4000-8000-000000000002', 2, 'Connecting', 'Failed', '2026-11-14T04:01:00+00', 'worker:lab', 'AwaitingChallenge', 'zone not allowed');

INSERT INTO deployment_versions (id, service_id, job_id, certificate_id, fingerprint, release_id, previous_release_id, status, health_status, staged_at, activated_at, verified_at) VALUES
('c0000000-0000-4000-8000-000000000002', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'b0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000002', repeat('cd', 32), 'rel-b-0001', NULL, 'Superseded', 'Healthy', '2026-11-14T00:34:00+00', '2026-11-14T00:34:30+00', '2026-11-14T00:35:00+00'),
('c0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'a0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001', repeat('ab', 32), 'rel-a-0002', 'rel-a-0001', 'Active', 'Healthy', '2026-11-14T01:04:00+00', '2026-11-14T01:04:30+00', '2026-11-14T01:05:00+00'),
('c0000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'a0000000-0000-4000-8000-000000000002', NULL, repeat('ef', 32), 'rel-a-0003', 'rel-a-0002', 'Staged', 'Unknown', '2026-11-14T02:02:30+00', NULL, NULL);

INSERT INTO certificate_alerts (id, job_id, service_id, kind, severity, stage, summary, occurred_at, delivery_state, attempt_count, next_attempt_at, delivered_at, last_error) VALUES
('d0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'JobFailed', 'Critical', 'Staging', 'certificate job failed at Staging', '2026-11-14T02:03:00+00', 'Delivered', 1, NULL, '2026-11-14T02:03:05+00', NULL),
('d0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000002', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'JobFailed', 'Warning', 'AwaitingChallenge', 'certificate job failed at AwaitingChallenge', '2026-11-14T04:01:00+00', 'Failed', 3, '2026-11-14T04:10:00+00', NULL, 'webhook returned 503');
SQL
compose exec -T postgres psql -U "$PG_USER" -d "$UPG_DB" -v ON_ERROR_STOP=1 < "$SEED_SQL"
assert_eq "seeded services" 2 "$(upg_query 'SELECT count(*) FROM managed_services')"
assert_eq "seeded jobs" 5 "$(upg_query 'SELECT count(*) FROM certificate_jobs')"
assert_eq "seeded transitions" 10 "$(upg_query 'SELECT count(*) FROM certificate_job_transitions')"
assert_eq "seeded versions" 3 "$(upg_query 'SELECT count(*) FROM deployment_versions')"
assert_eq "seeded alerts" 2 "$(upg_query 'SELECT count(*) FROM certificate_alerts')"

echo "== Upgrading via the production --migrate path =="
if ! run_migrator "$UPG_DB" secrets/upgrade-migrate.log; then
    echo "Upgrade failed; see secrets/upgrade-migrate.log" >&2
    exit 1
fi

echo "== Asserting data preservation and the new schema =="
assert_eq "history now complete" "$TOTAL_HISTORY" "$(upg_query 'SELECT count(*) FROM "__EFMigrationsHistory"')"
assert_eq "every post-baseline migration recorded" "$POST_BASELINE_COUNT" \
    "$(upg_query "SELECT count(*) FROM \"__EFMigrationsHistory\" WHERE \"MigrationId\" > '$BASELINE_MIGRATION'")"
assert_eq "services preserved" 2 "$(upg_query 'SELECT count(*) FROM managed_services')"
assert_eq "jobs preserved" 5 "$(upg_query 'SELECT count(*) FROM certificate_jobs')"
assert_eq "transitions preserved" 10 "$(upg_query 'SELECT count(*) FROM certificate_job_transitions')"
assert_eq "versions preserved" 3 "$(upg_query 'SELECT count(*) FROM deployment_versions')"
assert_eq "alerts preserved" 2 "$(upg_query 'SELECT count(*) FROM certificate_alerts')"
assert_eq "existing rows got renewal defaults" 2 \
    "$(upg_query "SELECT count(*) FROM managed_services WHERE renewal_enabled = false AND renewal_lead_time = INTERVAL '0'")"
assert_eq "certificate_not_after NULL on old versions" 3 \
    "$(upg_query 'SELECT count(*) FROM deployment_versions WHERE certificate_not_after IS NULL')"
assert_eq "old alerts keep job_id, no dedupe_key" 2 \
    "$(upg_query 'SELECT count(*) FROM certificate_alerts WHERE job_id IS NOT NULL AND dedupe_key IS NULL')"
assert_eq "new indexes present" 3 \
    "$(upg_query "SELECT count(*) FROM pg_indexes WHERE indexname IN ('ux_certificate_jobs_active_service','ux_certificate_alerts_dedupe_key','ux_certificate_alerts_job_id')")"
assert_eq "alerts job_id index is now PARTIAL" 1 \
    "$(upg_query "SELECT count(*) FROM pg_indexes WHERE indexname='ux_certificate_alerts_job_id' AND indexdef LIKE '%job_id IS NOT NULL%'")"
assert_eq "identity check constraint present" 1 \
    "$(upg_query "SELECT count(*) FROM pg_constraint WHERE conname='ck_certificate_alerts_identity' AND contype='c'")"
assert_eq "revocation table created by the upgrade" 1 \
    "$(upg_query "SELECT count(*) FROM information_schema.tables WHERE table_name='certificate_revocations'")"
assert_eq "revocation indexes created by the upgrade" 2 \
    "$(upg_query "SELECT count(*) FROM pg_indexes WHERE indexname IN ('ix_certificate_revocations_due','ux_certificate_revocations_idempotency')")"
assert_eq "live-serial guard is PARTIAL (one live row per serial, Failed rows excluded)" 1 \
    "$(upg_query "SELECT count(*) FROM pg_indexes WHERE indexname='ux_certificate_revocations_live_serial' AND indexdef LIKE '%::text <> ''Failed''%'")"
assert_eq "revocation foreign keys present" 2 \
    "$(upg_query "SELECT count(*) FROM pg_constraint WHERE conname IN ('fk_certificate_revocations_certificate_jobs','fk_certificate_revocations_managed_services') AND contype='f'")"
assert_eq "checkpoint JSON preserved" "rel-a-0002" \
    "$(upg_query "SELECT execution_checkpoint->>'DeploymentReleaseId' FROM certificate_jobs WHERE id='a0000000-0000-4000-8000-000000000001'")"
assert_eq "alert job_id preserved" "a0000000-0000-4000-8000-000000000002" \
    "$(upg_query "SELECT job_id FROM certificate_alerts WHERE id='d0000000-0000-4000-8000-000000000001'")"
assert_eq "failed-delivery alert state preserved" "Failed|3" \
    "$(upg_query "SELECT delivery_state || '|' || attempt_count FROM certificate_alerts WHERE id='d0000000-0000-4000-8000-000000000002'")"
assert_eq "version statuses preserved" "Superseded,Active,Staged" \
    "$(upg_query "SELECT string_agg(status, ',' ORDER BY staged_at) FROM deployment_versions")"
assert_eq "still exactly one active job for svc-a" 1 \
    "$(upg_query "SELECT count(*) FROM certificate_jobs WHERE service_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' AND state IN ('Queued','Connecting','GeneratingCsr','CreatingOrder','AwaitingChallenge','Signing','Staging','Activating','Verifying')")"

echo "== Re-running --migrate (must be a no-op) =="
if ! run_migrator "$UPG_DB" secrets/upgrade-migrate-2.log; then
    echo "Second --migrate run failed; see secrets/upgrade-migrate-2.log" >&2
    exit 1
fi
assert_eq "history unchanged after re-run" "$TOTAL_HISTORY" "$(upg_query 'SELECT count(*) FROM "__EFMigrationsHistory"')"
assert_eq "jobs unchanged after re-run" 5 "$(upg_query 'SELECT count(*) FROM certificate_jobs')"

echo "== New-shape expiry reminders (job_id NULL + dedupe_key) =="
compose exec -T postgres psql -U "$PG_USER" -d "$UPG_DB" -v ON_ERROR_STOP=1 -c \
"INSERT INTO certificate_alerts (id, job_id, service_id, kind, severity, stage, summary, occurred_at, delivery_state, attempt_count, next_attempt_at, delivered_at, last_error, dedupe_key)
 VALUES ('d0000000-0000-4000-8000-000000000003', NULL, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'CertificateExpiring', 'Warning', 'Expiry', 'certificate expires within 7 days', '2026-11-15T00:00:00+00', 'Pending', 0, NULL, NULL, NULL, 'expiring:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:' || repeat('ab', 32))"
compose exec -T postgres psql -U "$PG_USER" -d "$UPG_DB" -v ON_ERROR_STOP=1 -c \
"INSERT INTO certificate_alerts (id, job_id, service_id, kind, severity, stage, summary, occurred_at, delivery_state, attempt_count, dedupe_key)
 VALUES ('d0000000-0000-4000-8000-000000000006', NULL, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'CertificateExpiring', 'Warning', 'Expiry', 'certificate expires within 7 days', '2026-11-15T00:00:00+00', 'Pending', 0, 'expiring:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb:' || repeat('cd', 32))"
echo "  ok: two NULL-job expiry reminders accepted (partial unique allows many NULL job_ids)"
expect_rejection "duplicate dedupe_key" \
"INSERT INTO certificate_alerts (id, job_id, service_id, kind, severity, stage, summary, occurred_at, delivery_state, attempt_count, dedupe_key)
 VALUES ('d0000000-0000-4000-8000-000000000004', NULL, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'CertificateExpiring', 'Warning', 'Expiry', 'dup', '2026-11-15T00:00:00+00', 'Pending', 0, 'expiring:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:' || repeat('ab', 32))" \
    "ux_certificate_alerts_dedupe_key"
expect_rejection "alert with neither job_id nor dedupe_key" \
"INSERT INTO certificate_alerts (id, job_id, service_id, kind, severity, stage, summary, occurred_at, delivery_state, attempt_count)
 VALUES ('d0000000-0000-4000-8000-000000000005', NULL, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'JobFailed', 'Warning', 'Staging', 'identity violation', '2026-11-15T00:00:00+00', 'Pending', 0)" \
    "ck_certificate_alerts_identity"

echo "== Negative test: duplicate active jobs must block the upgrade =="
reset_db "$UPG_BAD_DB"
compose exec -T postgres psql -U "$PG_USER" -d "$UPG_BAD_DB" -v ON_ERROR_STOP=1 < "$BASELINE_SQL"
compose exec -T postgres psql -U "$PG_USER" -d "$UPG_BAD_DB" -v ON_ERROR_STOP=1 < "$SEED_SQL"
compose exec -T postgres psql -U "$PG_USER" -d "$UPG_BAD_DB" -v ON_ERROR_STOP=1 -c \
"INSERT INTO certificate_jobs (id, service_id, requested_by, idempotency_key, created_at, state, version)
 VALUES ('a0000000-0000-4000-8000-000000000004', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'lab-operator', 'drill-a-queued-2', '2026-11-14T03:05:00+00', 'Queued', 0)"
guard_rc=0
set +e
run_migrator "$UPG_BAD_DB" secrets/upgrade-guard.log
guard_rc=$?
set -e
if [ "$guard_rc" -eq 0 ]; then
    echo "FAIL: upgrade accepted two active jobs for one service." >&2
    exit 1
fi
grep -q "ux_certificate_jobs_active_service" secrets/upgrade-guard.log \
    || { echo "FAIL: guard failure did not name the index (see secrets/upgrade-guard.log)." >&2; exit 1; }
assert_eq "failed migration rolled back (history stays at baseline)" 5 \
    "$(bad_query 'SELECT count(*) FROM "__EFMigrationsHistory"')"
assert_eq "failed migration left no partial schema" 0 \
    "$(bad_query "SELECT count(*) FROM information_schema.columns WHERE table_name='managed_services' AND column_name='renewal_enabled'")"
echo "  ok: dirty database rejected (23505) and left at baseline"

echo "== Cleaning up drill databases =="
compose exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS $UPG_DB WITH (FORCE)" \
    -c "DROP DATABASE IF EXISTS $UPG_BAD_DB WITH (FORCE)"

python -c 'import json,sys
path = "secrets/lab-state.json"
state = json.load(open(path, encoding="utf-8"))
state["migrationDrill"] = {"baselineMigration": sys.argv[1], "targetMigration": sys.argv[2],
    "preservedServices": 2, "preservedJobs": 5, "preservedTransitions": 10,
    "preservedVersions": 3, "preservedAlerts": 2,
    "idempotent": True, "guardRejected": True, "dedupeRejected": True, "identityRejected": True}
json.dump(state, open(path, "w", encoding="utf-8"))' "$BASELINE_MIGRATION" "$TARGET_MIGRATION"

echo "Migration upgrade drill complete. Run ./drill-renewal.sh then ./verify.sh."