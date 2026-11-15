#!/usr/bin/env bash
# Asserts the Phase 4/5/6 completion conditions against a lab bootstrapped by
# setup.sh and drilled by drill-deployment.sh and drill-renewal.sh.
set -euo pipefail
cd "$(dirname "$0")"
# Container paths like /var/lib/... must not be rewritten to Windows paths by Git Bash.
export MSYS_NO_PATHCONV=1

if [ ! -f .env ] || [ ! -f secrets/lab-state.json ]; then
    echo "Run ./setup.sh first." >&2
    exit 1
fi
if ! python -c 'import json,sys
state = json.load(open("secrets/lab-state.json", encoding="utf-8"))
sys.exit(0 if all(key in state for key in ("firstJobId", "drillServiceId", "rolledBackJobId", "rollbackFailedJobId")) else 1)'; then
    echo "Run ./drill-deployment.sh before verify.sh (Phase 5 drills)." >&2
    exit 1
fi
if ! python -c 'import json,sys
state = json.load(open("secrets/lab-state.json", encoding="utf-8"))
sys.exit(0 if all(key in state for key in ("renewalServiceId", "renewalJobId", "concurrencyJobId", "concurrencyRejectedKey")) else 1)'; then
    echo "Run ./drill-renewal.sh before verify.sh (Phase 6 drills)." >&2
    exit 1
fi
set -a; . ./.env; set +a

API="http://127.0.0.1:${LAB_API_PORT:-5080}"
DNS_API="http://127.0.0.1:${LAB_DNS_UI_PORT:-5780}"
OIDC="http://127.0.0.1:${LAB_OIDC_PORT:-8280}"
TLS_PORT="${LAB_TARGET_TLS_PORT:-8443}"
PG_USER="${LAB_POSTGRES_USER:-trustforge}"
PG_DB="${LAB_POSTGRES_DB:-trustforge_lab}"

compose() { docker compose "$@"; }

psql_query() {
    compose exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -tAc "$1" | tr -d '[:space:]'
}

json_get() {
    python -c 'import json,sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(value if not isinstance(value, (dict, list)) else json.dumps(value))' "$1"
}

service_id=$(json_get serviceId < secrets/lab-state.json)
job_id=$(json_get jobId < secrets/lab-state.json)
failure_job_id=$(json_get failureJobId < secrets/lab-state.json)
first_job_id=$(json_get firstJobId < secrets/lab-state.json)
drill_service_id=$(json_get drillServiceId < secrets/lab-state.json)
rolled_back_job_id=$(json_get rolledBackJobId < secrets/lab-state.json)
rollback_failed_job_id=$(json_get rollbackFailedJobId < secrets/lab-state.json)
renewal_service_id=$(json_get renewalServiceId < secrets/lab-state.json)
renewal_job_id=$(json_get renewalJobId < secrets/lab-state.json)
renewal_bootstrap_job_id=$(json_get renewalBootstrapJobId < secrets/lab-state.json)
concurrency_job_id=$(json_get concurrencyJobId < secrets/lab-state.json)
concurrency_rejected_key=$(json_get concurrencyRejectedKey < secrets/lab-state.json)
service_nodash=$(printf '%s' "$service_id" | tr -d '-')
job_nodash=$(printf '%s' "$job_id" | tr -d '-')
first_job_nodash=$(printf '%s' "$first_job_id" | tr -d '-')

failures=0
check() {
    local description="$1"
    shift
    if "$@"; then
        echo "PASS: $description"
    else
        echo "FAIL: $description"
        failures=$((failures + 1))
    fi
}

access_token=$(curl -fsS -X POST "$OIDC/realms/trustforge-dev/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=trustforge-cli \
    --data-urlencode "username=$LAB_OIDC_DEV_USERNAME" --data-urlencode "password=$LAB_OIDC_DEV_PASSWORD" | json_get access_token)

job_json=$(curl -fsS "$API/api/v1/certificate-jobs/$job_id" -H "Authorization: Bearer $access_token")
job_state=$(printf '%s' "$job_json" | json_get state)
job_fingerprint=$(printf '%s' "$job_json" | json_get certificateFingerprint)
failure_json=$(curl -fsS "$API/api/v1/certificate-jobs/$failure_job_id" -H "Authorization: Bearer $access_token")
failure_state=$(printf '%s' "$failure_json" | json_get state)
failure_stage=$(printf '%s' "$failure_json" | json_get failureStage)

echo "== Job outcomes =="
check "success job reached Succeeded" test "$job_state" = "Succeeded"
check "success job recorded a certificate fingerprint" test -n "$job_fingerprint"
check "out-of-zone job failed" test "$failure_state" = "Failed"
check "out-of-zone job failed at AwaitingChallenge" test "$failure_stage" = "AwaitingChallenge"

echo "== Target certificate matches the issued certificate =="
target_fingerprint=$(compose exec -T target sh -c \
    'openssl x509 -in /etc/trustforge-demo/current/certificate.pem -outform DER | sha256sum | cut -d" " -f1' | tr -d '\r')
check "deployed leaf fingerprint equals job fingerprint" \
    test "$(printf '%s' "$job_fingerprint" | tr 'A-F' 'a-f')" = "$target_fingerprint"
check "issued certificate public key matches the target-generated CSR key" \
    compose exec -T target sh -c "openssl req -in /var/lib/trustforge/jobs/$service_nodash/$job_nodash/request.csr -pubkey -noout > /tmp/csr.pub && openssl x509 -in /etc/trustforge-demo/current/certificate.pem -pubkey -noout > /tmp/cert.pub && cmp -s /tmp/csr.pub /tmp/cert.pub"

echo "== Challenge records cleaned up =="
dns_token=$(cat secrets/dns-api-token)
txt_count=$(curl -fsS -G "$DNS_API/api/zones/records/get" -H "Authorization: Bearer $dns_token" \
    --data-urlencode "domain=_acme-challenge.svc1.trustforge.lab" --data-urlencode "zone=trustforge.lab" \
    --data-urlencode "listZone=false" | python -c 'import json,sys
records = json.load(sys.stdin)["response"]["records"]
print(sum(1 for r in records if r.get("type") == "TXT"))')
check "no job TXT record remains in the zone" test "$txt_count" = "0"

echo "== TLS service presents the issued certificate =="
# s_client exits 1 on stdin EOF even after a successful handshake; the fingerprint comparison is the real assertion.
served_fingerprint=$(echo | openssl s_client -connect "127.0.0.1:$TLS_PORT" 2>/dev/null | openssl x509 -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1 || true)
check "served TLS fingerprint equals job fingerprint" \
    test "$(printf '%s' "$job_fingerprint" | tr 'A-F' 'a-f')" = "$served_fingerprint"
check "served chain validates against the lab root" \
    bash -c "echo | openssl s_client -connect 127.0.0.1:$TLS_PORT -CAfile secrets/root_ca.crt -verify_return_error 2>&1 | grep -q 'Verify return code: 0 (ok)'"

echo "== Key isolation =="
checkpoint_leaks=$(compose exec -T postgres psql -U "${LAB_POSTGRES_USER:-trustforge}" -d "${LAB_POSTGRES_DB:-trustforge_lab}" -tAc \
    "SELECT count(*) FROM certificate_jobs WHERE execution_checkpoint::text LIKE '%PRIVATE KEY%'")
check "no private key material in any job checkpoint" test "$(printf '%s' "$checkpoint_leaks" | tr -d '[:space:]')" = "0"
check "target private key exists with owner-only permissions" \
    compose exec -T target sh -c "test -f /var/lib/trustforge/jobs/$service_nodash/$job_nodash/private-key.pem && test \$(stat -c '%a' /var/lib/trustforge/jobs/$service_nodash/$job_nodash/private-key.pem) = 600"
artifact_leaks=$(compose exec -T trustforge sh -c "cat /var/lib/trustforge/artifacts/$job_nodash.certificate.json" | grep -c "PRIVATE KEY" || true)
check "artifact store holds only public certificate material" test "$artifact_leaks" = "0"

echo "== Deployment version records =="
versions_json=$(curl -fsS "$API/api/v1/services/$service_id/deployment-versions" -H "Authorization: Bearer $access_token")
latest_version=$(printf '%s' "$versions_json" | python -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[0]))')
check "latest deployment version belongs to the current job" test "$(json_get jobId <<< "$latest_version")" = "$job_id"
check "latest deployment version is Active" test "$(json_get status <<< "$latest_version")" = "Active"
check "latest deployment version is Healthy" test "$(json_get healthStatus <<< "$latest_version")" = "Healthy"
check "deployment version fingerprint equals job fingerprint" test "$(json_get fingerprint <<< "$latest_version")" = "$job_fingerprint"
check "latest deployment version records verifiedAt" test "$(json_get verifiedAt <<< "$latest_version")" != "None"
version_status_by_job() {
    printf '%s' "$1" | python -c 'import json,sys
items = json.load(sys.stdin)
matches = [v["status"] for v in items if v["jobId"] == sys.argv[1]]
print(matches[0] if matches else "MISSING")' "$2"
}
check "first deployment is recorded as Superseded" test "$(version_status_by_job "$versions_json" "$first_job_id")" = "Superseded"
drill_versions=$(curl -fsS "$API/api/v1/services/$drill_service_id/deployment-versions" -H "Authorization: Bearer $access_token")
check "rollback drill version is RolledBack" test "$(version_status_by_job "$drill_versions" "$rolled_back_job_id")" = "RolledBack"
check "rollback-failed drill version is RollbackFailed" test "$(version_status_by_job "$drill_versions" "$rollback_failed_job_id")" = "RollbackFailed"

echo "== Failure alerts delivered =="
alerts_json=$(curl -fsS "$API/api/v1/certificate-alerts?limit=200" -H "Authorization: Bearer $access_token")
alert_field() {
    printf '%s' "$alerts_json" | python -c 'import json,sys
items = json.load(sys.stdin)
matches = [a for a in items if a["jobId"] == sys.argv[1]]
print(matches[0][sys.argv[2]] if matches else "MISSING")' "$1" "$2"
}
check "out-of-zone failure raised a JobFailed alert" test "$(alert_field "$failure_job_id" kind)" = "JobFailed"
check "JobFailed alert is Delivered" test "$(alert_field "$failure_job_id" deliveryState)" = "Delivered"
check "rollback drill raised a DeploymentRolledBack alert" test "$(alert_field "$rolled_back_job_id" kind)" = "DeploymentRolledBack"
check "DeploymentRolledBack alert severity is Warning" test "$(alert_field "$rolled_back_job_id" severity)" = "Warning"
check "DeploymentRolledBack alert is Delivered" test "$(alert_field "$rolled_back_job_id" deliveryState)" = "Delivered"
check "rollback-failed drill raised a RollbackFailed alert" test "$(alert_field "$rollback_failed_job_id" kind)" = "RollbackFailed"
check "RollbackFailed alert severity is Critical" test "$(alert_field "$rollback_failed_job_id" severity)" = "Critical"
check "RollbackFailed alert is Delivered" test "$(alert_field "$rollback_failed_job_id" deliveryState)" = "Delivered"
for alert_job in "$failure_job_id" "$rolled_back_job_id" "$rollback_failed_job_id"; do
    alert_id=$(alert_field "$alert_job" id)
    check "webhook receiver logged alert for job $alert_job" \
        compose exec -T target grep -q "$alert_id" /var/lib/trustforge-demo/alerts.jsonl
done

echo "== Active file permissions =="
check "active private key is root:root 0600" \
    compose exec -T target sh -c 'test "$(stat -c "%U:%G:%a" /etc/trustforge-demo/current/private-key.pem)" = "root:root:600"'
check "active certificate is root:root 0644" \
    compose exec -T target sh -c 'test "$(stat -c "%U:%G:%a" /etc/trustforge-demo/current/certificate.pem)" = "root:root:644"'
check "active chain is root:root 0644" \
    compose exec -T target sh -c 'test "$(stat -c "%U:%G:%a" /etc/trustforge-demo/current/chain.pem)" = "root:root:644"'

echo "== Retention cleanup =="
check "oldest release was pruned" \
    compose exec -T target test ! -d "/var/lib/trustforge/releases/$service_nodash/$first_job_nodash"
check "oldest job key directory was pruned" \
    compose exec -T target test ! -d "/var/lib/trustforge/jobs/$service_nodash/$first_job_nodash"
release_count=$(compose exec -T target sh -c "ls /var/lib/trustforge/releases/$service_nodash | wc -l" | tr -d '[:space:]')
check "retained release count equals the policy (2)" test "$release_count" = "2"
check "current release survived pruning" \
    compose exec -T target test -d "/var/lib/trustforge/releases/$service_nodash/$job_nodash"

echo "== Renewal policy and scheduler =="
renewal_service_json=$(curl -fsS "$API/api/v1/services/$renewal_service_id" -H "Authorization: Bearer $access_token")
renewal_enabled=$(printf '%s' "$renewal_service_json" | json_get renewalEnabled)
renewal_lead_time=$(printf '%s' "$renewal_service_json" | json_get renewalLeadTime)
lead_hours=$(printf '%s' "$renewal_lead_time" | python -c 'import sys,re
m = re.match(r"^(?:(\d+)\.)?(\d+):(\d+):(\d+)$", sys.stdin.read().strip())
print(int(m.group(1) or 0) * 24 + int(m.group(2)) + int(m.group(3)) / 60 + int(m.group(4)) / 3600)')
check "renewal service persisted renewalEnabled=true" test "$renewal_enabled" = "True"
check "renewal service persisted a 25h lead time" test "$lead_hours" = "25.0"
renewal_job_json=$(curl -fsS "$API/api/v1/certificate-jobs/$renewal_job_id" -H "Authorization: Bearer $access_token")
renewal_requested_by=$(printf '%s' "$renewal_job_json" | json_get requestedBy)
renewal_state=$(printf '%s' "$renewal_job_json" | json_get state)
renewal_fingerprint=$(printf '%s' "$renewal_job_json" | json_get certificateFingerprint)
check "renewal job was created by the renewal scheduler" test "$renewal_requested_by" = "renewal-scheduler"
check "renewal job reached Succeeded" test "$renewal_state" = "Succeeded"
check "renewal job recorded a certificate fingerprint" test -n "$renewal_fingerprint"
renewal_versions=$(curl -fsS "$API/api/v1/services/$renewal_service_id/deployment-versions" -H "Authorization: Bearer $access_token")
check "renewal deployment version is Active" test "$(version_status_by_job "$renewal_versions" "$renewal_job_id")" = "Active"
renewal_not_after=$(printf '%s' "$renewal_versions" | python -c 'import json,sys
items = json.load(sys.stdin)
matches = [v["certificateNotAfter"] for v in items if v["jobId"] == sys.argv[1]]
print(matches[0] if matches else "MISSING")' "$renewal_job_id")
check "renewal deployment version records certificateNotAfter" test "$renewal_not_after" != "None"
check "bootstrap deployment version was superseded by the renewal" test "$(version_status_by_job "$renewal_versions" "$renewal_bootstrap_job_id")" = "Superseded"
renewal_db_count=$(psql_query "SELECT count(*) FROM certificate_jobs WHERE service_id='$renewal_service_id' AND requested_by='renewal-scheduler'")
check "exactly one renewal job exists (no duplicate issuance per scan)" test "$renewal_db_count" = "1"

echo "== Database-level concurrency guard =="
concurrency_state=$(curl -fsS "$API/api/v1/certificate-jobs/$concurrency_job_id" -H "Authorization: Bearer $access_token" | json_get state)
check "accepted concurrent job reached Succeeded" test "$concurrency_state" = "Succeeded"
rejected_db_count=$(psql_query "SELECT count(*) FROM certificate_jobs WHERE service_id='$service_id' AND idempotency_key='$concurrency_rejected_key'")
check "rejected concurrent job was never persisted" test "$rejected_db_count" = "0"

echo "== Expiry reminders =="
# Lab certificates live ~24h, always inside the 7d reminder window; the worker scans every 5s.
svc1_dedupe_key="expiring:$service_id:$job_fingerprint"
expiring_json=""
for _ in $(seq 1 30); do
    expiring_json=$(curl -fsS "$API/api/v1/certificate-alerts?limit=200" -H "Authorization: Bearer $access_token" | python -c 'import json,sys
items = json.load(sys.stdin)
matches = [a for a in items if a.get("dedupeKey") == sys.argv[1]]
print(json.dumps(matches[0]) if matches else "")' "$svc1_dedupe_key")
    [ -n "$expiring_json" ] && break
    sleep 2
done
expiring_field() {
    printf '%s' "$expiring_json" | python -c 'import json,sys
raw = sys.stdin.read().strip()
if not raw:
    print("MISSING"); sys.exit(0)
value = json.loads(raw).get(sys.argv[1])
print(value if value is not None else "None")' "$1"
}
check "expiry reminder raised for the active svc1 certificate" test "$(expiring_field id)" != "MISSING"
check "expiry reminder kind is CertificateExpiring" test "$(expiring_field kind)" = "CertificateExpiring"
check "expiry reminder severity is Warning" test "$(expiring_field severity)" = "Warning"
check "expiry reminder carries no job ID" test "$(expiring_field jobId)" = "None"
check "expiry reminder is Delivered" test "$(expiring_field deliveryState)" = "Delivered"
sleep 15
svc1_expiring_count=$(psql_query "SELECT count(*) FROM certificate_alerts WHERE dedupe_key='$svc1_dedupe_key'")
check "expiry reminder deduped to one row across repeated scans" test "$svc1_expiring_count" = "1"
expiring_alert_id=$(expiring_field id)
check "webhook receiver logged the expiry reminder" \
    compose exec -T target grep -q "$expiring_alert_id" /var/lib/trustforge-demo/alerts.jsonl
svc4_dedupe_key="expiring:$renewal_service_id:$renewal_fingerprint"
svc4_expiring_count=$(psql_query "SELECT count(*) FROM certificate_alerts WHERE dedupe_key='$svc4_dedupe_key'")
check "renewed svc4 certificate raised its own expiry reminder" test "$svc4_expiring_count" = "1"
check "failure alert still carries a job ID" test "$(alert_field "$failure_job_id" jobId)" != "None"
check "failure alert has no dedupe key" test "$(alert_field "$failure_job_id" dedupeKey)" = "None"

echo "== Audit export =="
audit_json=$(curl -fsS "$API/api/v1/audit/export?limit=200" -H "Authorization: Bearer $access_token")
audit_has_job() {
    printf '%s' "$audit_json" | python -c 'import json,sys
bundle = json.load(sys.stdin)
print("yes" if any(j["id"] == sys.argv[1] for j in bundle["jobs"]) else "no")' "$1"
}
check "audit export contains the current job" test "$(audit_has_job "$job_id")" = "yes"
audit_transitions_string() {
    printf '%s' "$audit_json" | python -c 'import json,sys
bundle = json.load(sys.stdin)
jobs = [j for j in bundle["jobs"] if j["id"] == sys.argv[1]]
if not jobs or not jobs[0]["transitions"]:
    print("no"); sys.exit(0)
transition = jobs[0]["transitions"][0]
print("yes" if isinstance(transition["from"], str) and isinstance(transition["to"], str) else "no")' "$1"
}
check "audit export serializes transition states as strings" test "$(audit_transitions_string "$job_id")" = "yes"
audit_has_active_version() {
    printf '%s' "$audit_json" | python -c 'import json,sys
bundle = json.load(sys.stdin)
print("yes" if any(v["jobId"] == sys.argv[1] and v["status"] == "Active" for v in bundle["deploymentVersions"]) else "no")' "$1"
}
check "audit export contains the active deployment version" test "$(audit_has_active_version "$job_id")" = "yes"
audit_alert_kinds() {
    printf '%s' "$audit_json" | python -c 'import json,sys
bundle = json.load(sys.stdin)
kinds = {a["kind"] for a in bundle["alerts"]}
print("yes" if "JobFailed" in kinds and "CertificateExpiring" in kinds else "no")'
}
check "audit export contains failure and expiry alerts" test "$(audit_alert_kinds)" = "yes"
audit_filtered=$(curl -fsS "$API/api/v1/audit/export?serviceId=$service_id&limit=200" -H "Authorization: Bearer $access_token")
audit_filter_ok() {
    printf '%s' "$audit_filtered" | python -c 'import json,sys
bundle = json.load(sys.stdin)
sid = sys.argv[1]
ok = all(j["serviceId"] == sid for j in bundle["jobs"]) \
    and all(v["serviceId"] == sid for v in bundle["deploymentVersions"]) \
    and all(a["serviceId"] == sid for a in bundle["alerts"])
print("yes" if ok else "no")' "$1"
}
check "audit export serviceId filter scopes every section" test "$(audit_filter_ok "$service_id")" = "yes"
audit_future=$(curl -fsS -G "$API/api/v1/audit/export" --data-urlencode "from=2999-01-01T00:00:00Z" --data-urlencode "limit=200" -H "Authorization: Bearer $access_token")
audit_future_empty() {
    printf '%s' "$audit_future" | python -c 'import json,sys
bundle = json.load(sys.stdin)
print("yes" if not bundle["jobs"] and not bundle["deploymentVersions"] and not bundle["alerts"] else "no")'
}
check "audit export with a future 'from' is empty" test "$(audit_future_empty)" = "yes"
audit_anon_code=$(curl -sS -w '\n%{http_code}' "$API/api/v1/audit/export" | tail -n1)
check "audit export rejects anonymous access" test "$audit_anon_code" = "401"

echo "== Backup / restore drill =="
restore_drill=$(python -c 'import json
state = json.load(open("secrets/lab-state.json", encoding="utf-8"))
value = state.get("restoreDrill")
print(json.dumps(value) if value is not None else "")')
if [ -n "$restore_drill" ]; then
    post_restore_job_id=$(printf '%s' "$restore_drill" | json_get postRestoreJobId)
    backup_job_id=$(printf '%s' "$restore_drill" | json_get backupJobId)
    post_restore_state=$(curl -fsS "$API/api/v1/certificate-jobs/$post_restore_job_id" -H "Authorization: Bearer $access_token" | json_get state)
    check "post-restore issuance job reached Succeeded (CA keys recovered)" test "$post_restore_state" = "Succeeded"
    backup_job_state=$(curl -fsS "$API/api/v1/certificate-jobs/$backup_job_id" -H "Authorization: Bearer $access_token" | json_get state)
    check "backed-up job survived the restore" test "$backup_job_state" = "Succeeded"
    check "restore drill recorded a backup manifest" test -f secrets/backup/manifest.json
else
    echo "SKIP: backup/restore drill not run (no restoreDrill in lab-state)."
fi

echo "== Notification (LISTEN/NOTIFY) drill =="
notification_drill=$(python -c 'import json
state = json.load(open("secrets/lab-state.json", encoding="utf-8"))
value = state.get("notificationDrill")
print(json.dumps(value) if value is not None else "")')
if [ -n "$notification_drill" ]; then
    notify_job_id=$(printf '%s' "$notification_drill" | json_get notifyJobId)
    notify_latency=$(printf '%s' "$notification_drill" | json_get notifyLatencySeconds)
    control_latency=$(printf '%s' "$notification_drill" | json_get controlLatencySeconds)
    notify_state=$(curl -fsS "$API/api/v1/certificate-jobs/$notify_job_id" -H "Authorization: Bearer $access_token" | json_get state)
    check "notification wake job reached Succeeded" test "$notify_state" = "Succeeded"
    check "NOTIFY wake latency is below the poll interval (<12s)" test "$notify_latency" -lt 12
    check "polling fallback latency is poll-bound (>=20s)" test "$control_latency" -ge 20
else
    echo "SKIP: notification drill not run (no notificationDrill in lab-state)."
fi

echo "== Migration upgrade drill =="
migration_drill=$(python -c 'import json
state = json.load(open("secrets/lab-state.json", encoding="utf-8"))
value = state.get("migrationDrill")
print(json.dumps(value) if value is not None else "")')
if [ -n "$migration_drill" ]; then
    check "upgrade drill started from the DeploymentVersionsAndAlerts baseline" \
        test "$(printf '%s' "$migration_drill" | json_get baselineMigration)" = "202611150001_DeploymentVersionsAndAlerts"
    check "upgrade drill reached the ExpiryReminders target" \
        test "$(printf '%s' "$migration_drill" | json_get targetMigration)" = "202611150003_ExpiryReminders"
    check "production-like rows survived the upgrade (5 jobs / 3 versions / 2 alerts)" \
        test "$(printf '%s' "$migration_drill" | json_get preservedJobs)" = "5"
    check "re-running --migrate was a no-op" \
        test "$(printf '%s' "$migration_drill" | json_get idempotent)" = "True"
    check "duplicate active jobs rejected by ux_certificate_jobs_active_service" \
        test "$(printf '%s' "$migration_drill" | json_get guardRejected)" = "True"
    check "duplicate dedupe key rejected by ux_certificate_alerts_dedupe_key" \
        test "$(printf '%s' "$migration_drill" | json_get dedupeRejected)" = "True"
    lab_history=$(psql_query 'SELECT count(*) FROM "__EFMigrationsHistory"')
    check "lab database itself is fully migrated (7 migrations)" test "$lab_history" = "7"
else
    echo "SKIP: migration upgrade drill not run (no migrationDrill in lab-state)."
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "All Phase 4/5/6 completion checks passed."
else
    echo "$failures check(s) failed." >&2
    exit 1
fi