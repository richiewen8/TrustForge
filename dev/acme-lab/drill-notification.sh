#!/usr/bin/env bash
# Phase 3 outbox drill: proves the transactional LISTEN/NOTIFY wake signal (not polling)
# wakes the worker, and that polling remains the loss-safe fallback.
#
# Method (phase anchoring): with a high PollInterval (30s), create an anchor job; once it
# reaches a terminal state the worker immediately re-claims (nothing queued) and enters a
# fresh full-interval wait. After a 2s settle we create job B, so B's latency is deterministic:
#   * NotificationEnabled=false -> B is poll-bound (~28s, asserted >= 20s).
#   * NotificationEnabled=true  -> NOTIFY wakes the worker at once (~2-3s, asserted < 12s).
# The contrast conclusively attributes the fast wake to NOTIFY rather than poll-phase luck.
# Only svc1 is used (renewalEnabled=false) to avoid renewal-scheduler races.
#
# Recreating trustforge invalidates Keycloak's shared netns, so keycloak is brought up with
# `up -d` (never restart). Runs AFTER verify.sh; restores base config and records results.
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1

if [ ! -f .env ] || [ ! -f secrets/lab-state.json ]; then
    echo "Run ./setup.sh first." >&2
    exit 1
fi
set -a; . ./.env; set +a

API="http://127.0.0.1:${LAB_API_PORT:-5080}"
OIDC="http://127.0.0.1:${LAB_OIDC_PORT:-8280}"
PG_USER="${LAB_POSTGRES_USER:-trustforge}"
PG_DB="${LAB_POSTGRES_DB:-trustforge_lab}"
OVERRIDE="secrets/notification-override.yml"

compose() { docker compose "$@"; }
compose_override() { docker compose -f docker-compose.yml -f "$OVERRIDE" "$@"; }
compose_base() { docker compose -f docker-compose.yml "$@"; }

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

service_id=$(json_get serviceId < secrets/lab-state.json)
access_token=""

write_override() {
    cat > "$OVERRIDE" <<EOF
services:
  trustforge:
    environment:
      CertificateJobs__Worker__PollInterval: "00:00:30"
      CertificateJobs__Worker__NotificationEnabled: "$1"
EOF
}

recreate_app() {
    compose_override up -d --no-deps --force-recreate trustforge
    compose_override up -d keycloak
    wait_for "API readiness" 90 curl -fsS "$API/health/ready"
    access_token=""
    for _ in $(seq 1 90); do
        access_token=$(curl -fsS -X POST "$OIDC/realms/trustforge-dev/protocol/openid-connect/token" \
            -d grant_type=password -d client_id=trustforge-cli \
            --data-urlencode "username=$LAB_OIDC_DEV_USERNAME" --data-urlencode "password=$LAB_OIDC_DEV_PASSWORD" 2>/dev/null \
            | json_get access_token 2>/dev/null) && break
        sleep 2
    done
    if [ -z "$access_token" ]; then
        echo "Keycloak did not issue a token." >&2
        exit 1
    fi
}

create_job() {
    curl -fsS -X POST "$API/api/v1/services/$1/certificate-jobs" \
        -H "Authorization: Bearer $access_token" -H "Idempotency-Key: $2" | json_get id
}

job_state() {
    curl -fsS "$API/api/v1/certificate-jobs/$1" -H "Authorization: Bearer $access_token" | json_get state
}

wait_terminal() {
    local job="$1" state=""
    for _ in $(seq 1 150); do
        state=$(job_state "$job")
        case "$state" in
            Succeeded|Failed|FailedRolledBack|RollbackFailed|Cancelled) break ;;
        esac
        sleep 2
    done
    if [ "$state" != "Succeeded" ]; then
        echo "Anchor job $job ended in '$state', expected Succeeded." >&2
        exit 1
    fi
}

# Sets PHASE_JOB_ID and PHASE_LATENCY (seconds from B creation to terminal).
measure_phase() {
    local label="$1" enabled="$2" anchor b start state
    write_override "$enabled"
    recreate_app
    echo "== $label phase (NotificationEnabled=$enabled, PollInterval=30s) =="
    anchor=$(create_job "$service_id" "lab-notif-anchor-$label-$(date +%s)")
    wait_terminal "$anchor"
    sleep 2
    b=$(create_job "$service_id" "lab-notif-$label-$(date +%s)")
    start=$SECONDS
    state=""
    for _ in $(seq 1 120); do
        state=$(job_state "$b")
        case "$state" in
            Succeeded|Failed|FailedRolledBack|RollbackFailed|Cancelled) break ;;
        esac
        sleep 1
    done
    if [ "$state" != "Succeeded" ]; then
        echo "$label job $b ended in '$state', expected Succeeded." >&2
        exit 1
    fi
    PHASE_JOB_ID="$b"
    PHASE_LATENCY=$((SECONDS - start))
    echo "$label phase: job $b latency ${PHASE_LATENCY}s."
}

measure_phase control false
control_job="$PHASE_JOB_ID"
control_latency="$PHASE_LATENCY"
if [ "$control_latency" -lt 20 ]; then
    echo "Control latency ${control_latency}s < 20s; expected poll-bound latency at a 30s interval." >&2
    exit 1
fi

measure_phase notify true
notify_job="$PHASE_JOB_ID"
notify_latency="$PHASE_LATENCY"
if [ "$notify_latency" -ge 12 ]; then
    echo "Notify latency ${notify_latency}s >= 12s; NOTIFY wake not demonstrated." >&2
    exit 1
fi
listener_count=$(psql_query "SELECT count(*) FROM pg_stat_activity WHERE application_name='trustforge-job-listener'")
if [ "$listener_count" -lt 1 ]; then
    echo "No trustforge-job-listener connection found in pg_stat_activity." >&2
    exit 1
fi
echo "LISTEN connection present (pg_stat_activity rows: $listener_count)."

echo "== Restoring base configuration =="
compose_base up -d --no-deps --force-recreate trustforge
compose_base up -d keycloak
wait_for "API readiness" 90 curl -fsS "$API/health/ready"
# Leave Keycloak fully ready so a following drill (e.g. drill-renewal) can get a token at once.
for _ in $(seq 1 90); do
    curl -fsS -X POST "$OIDC/realms/trustforge-dev/protocol/openid-connect/token" \
        -d grant_type=password -d client_id=trustforge-cli \
        --data-urlencode "username=$LAB_OIDC_DEV_USERNAME" --data-urlencode "password=$LAB_OIDC_DEV_PASSWORD" >/dev/null 2>&1 && break
    sleep 2
done
rm -f "$OVERRIDE"

python -c 'import json,sys
path = "secrets/lab-state.json"
state = json.load(open(path, encoding="utf-8"))
state["jobId"] = sys.argv[1]
state["notificationDrill"] = {"controlJobId": sys.argv[2], "controlLatencySeconds": int(sys.argv[3]),
                              "notifyJobId": sys.argv[1], "notifyLatencySeconds": int(sys.argv[4])}
json.dump(state, open(path, "w", encoding="utf-8"))' \
    "$notify_job" "$control_job" "$control_latency" "$notify_latency"

echo "Notification drill complete: control ${control_latency}s (poll-bound) vs notify ${notify_latency}s (NOTIFY wake)."