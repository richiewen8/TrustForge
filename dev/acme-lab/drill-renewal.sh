#!/usr/bin/env bash
# Phase 6 renewal drills against a lab bootstrapped by setup.sh and drilled by
# drill-deployment.sh:
#  1. database-level concurrency guard: a second active job for the same service
#     is rejected with HTTP 409 service_job_active
#  2. renewal scheduler: a renewal-enabled service whose active certificate is in
#     its lead-time window gets exactly one renewal job (requested_by
#     renewal-scheduler), which succeeds and is not re-issued on the next scans
# The drill finishes with a fresh svc1 deployment so svc1 owns the shared
# /etc/trustforge-demo/current symlink again (verify.sh checks the served cert).
# Results are appended to secrets/lab-state.json for verify.sh.
set -euo pipefail
cd "$(dirname "$0")"
# Container paths like /etc/... must not be rewritten to Windows paths by Git Bash.
export MSYS_NO_PATHCONV=1

if [ ! -f .env ] || [ ! -f secrets/lab-state.json ]; then
    echo "Run ./setup.sh first." >&2
    exit 1
fi
if ! python -c 'import json,sys
state = json.load(open("secrets/lab-state.json", encoding="utf-8"))
sys.exit(0 if all(key in state for key in ("drillServiceId", "rolledBackJobId")) else 1)'; then
    echo "Run ./drill-deployment.sh before drill-renewal.sh." >&2
    exit 1
fi
set -a; . ./.env; set +a

API="http://127.0.0.1:${LAB_API_PORT:-5080}"
DNS_API="http://127.0.0.1:${LAB_DNS_UI_PORT:-5780}"
OIDC="http://127.0.0.1:${LAB_OIDC_PORT:-8280}"
TARGET_IP="${LAB_SUBNET_PREFIX:-172.30.90}.30"
PG_USER="${LAB_POSTGRES_USER:-trustforge}"
PG_DB="${LAB_POSTGRES_DB:-trustforge_lab}"

compose() { docker compose "$@"; }

json_get() {
    python -c 'import json,sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(value if not isinstance(value, (dict, list)) else json.dumps(value))' "$1"
}

service_id=$(json_get serviceId < secrets/lab-state.json)

access_token=$(curl -fsS -X POST "$OIDC/realms/trustforge-dev/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=trustforge-cli \
    --data-urlencode "username=$LAB_OIDC_DEV_USERNAME" --data-urlencode "password=$LAB_OIDC_DEV_PASSWORD" | json_get access_token)

job_state() {
    curl -fsS "$API/api/v1/certificate-jobs/$1" -H "Authorization: Bearer $access_token" | json_get state
}

create_job() {
    curl -fsS -X POST "$API/api/v1/services/$1/certificate-jobs" \
        -H "Authorization: Bearer $access_token" -H "Idempotency-Key: $2" | json_get id
}

# Prints "<http_code> <body>"; does not fail on 4xx so the guard can be asserted.
create_job_raw() {
    local response
    response=$(curl -sS -w '\n%{http_code}' -X POST "$API/api/v1/services/$1/certificate-jobs" \
        -H "Authorization: Bearer $access_token" -H "Idempotency-Key: $2")
    printf '%s %s' "$(printf '%s' "$response" | tail -n1)" "$(printf '%s' "$response" | sed '$d')"
}

wait_terminal() {
    local job="$1" expected="$2" state=""
    for _ in $(seq 1 150); do
        state=$(job_state "$job")
        case "$state" in
            Succeeded|Failed|FailedRolledBack|RollbackFailed|Cancelled) break ;;
        esac
        sleep 2
    done
    if [ "$state" != "$expected" ]; then
        echo "Drill job $job ended in '$state', expected '$expected'." >&2
        exit 1
    fi
}

psql_query() {
    compose exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -tAc "$1" | tr -d '[:space:]'
}

echo "== Drill 1: database-level concurrency guard on svc1 =="
concurrency_key="lab-concurrency-accept-$(date +%s)"
rejected_key="lab-concurrency-reject-$(date +%s)"
accepted_raw=$(create_job_raw "$service_id" "$concurrency_key")
accepted_code=${accepted_raw%% *}
concurrency_job_id=$(printf '%s' "${accepted_raw#* }" | json_get id)
if [ "$accepted_code" != "202" ]; then
    echo "First concurrent job was not accepted (HTTP $accepted_code)." >&2
    exit 1
fi
rejected_raw=$(create_job_raw "$service_id" "$rejected_key")
rejected_code=${rejected_raw%% *}
rejected_error=$(printf '%s' "${rejected_raw#* }" | json_get error)
if [ "$rejected_code" != "409" ] || [ "$rejected_error" != "service_job_active" ]; then
    echo "Second concurrent job expected HTTP 409 service_job_active, got HTTP $rejected_code '$rejected_error'." >&2
    exit 1
fi
echo "Second active job for svc1 rejected with 409 service_job_active."
wait_terminal "$concurrency_job_id" Succeeded
echo "Concurrency drill job $concurrency_job_id reached Succeeded."

echo "== Registering the renewal-enabled service =="
fingerprint=$(compose exec -T target ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')
renewal_service_id=$(curl -fsS -X POST "$API/api/v1/services" \
    -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" -d @- <<EOF | json_get id
{
  "name": "demo-tls-renewal",
  "environment": "lab",
  "owner": "trustforge-lab",
  "host": "target",
  "port": 22,
  "hostKeyFingerprint": "$fingerprint",
  "sshCredentialRef": "secret://file//run/trustforge/secrets/ssh-credential.json",
  "profileId": "11111111-1111-1111-1111-111111111111",
  "sans": ["svc4.trustforge.lab"],
  "certificatePath": "/etc/trustforge-demo/current/certificate.pem",
  "chainPath": "/etc/trustforge-demo/current/chain.pem",
  "privateKeyPath": "/etc/trustforge-demo/current/private-key.pem",
  "fileOwner": "root",
  "fileGroup": "root",
  "fileMode": "0600",
  "remoteHelperId": "trustforge-certctl-v1",
  "reloadActionId": "demo-tls-reload",
  "healthCheckId": "demo-tls-health",
  "renewalEnabled": true,
  "renewalLeadTime": "1.01:00:00"
}
EOF
)
renewal_nodash=$(printf '%s' "$renewal_service_id" | tr -d '-')
compose exec -T target sh -c "umask 077; cat > /etc/trustforge/services/$renewal_nodash.json" <<EOF
{
  "certificatePath": "/etc/trustforge-demo/current/certificate.pem",
  "chainPath": "/etc/trustforge-demo/current/chain.pem",
  "privateKeyPath": "/etc/trustforge-demo/current/private-key.pem",
  "fileOwner": "root",
  "fileGroup": "root",
  "fileMode": "0600",
  "remoteHelperId": "trustforge-certctl-v1",
  "reloadActionId": "demo-tls-reload",
  "healthCheckId": "demo-tls-health"
}
EOF
curl -fsS -G "$DNS_API/api/zones/records/add" -H "Authorization: Bearer $(cat secrets/dns-api-token)" \
    --data-urlencode "domain=svc4.trustforge.lab" --data-urlencode "zone=trustforge.lab" \
    --data-urlencode "type=A" --data-urlencode "ipAddress=$TARGET_IP" \
    --data-urlencode "overwrite=true" >/dev/null

echo "== Bootstrapping the renewal service with a manual job =="
bootstrap_job_id=$(create_job "$renewal_service_id" "lab-renewal-bootstrap-$(date +%s)")
wait_terminal "$bootstrap_job_id" Succeeded
echo "Bootstrap job $bootstrap_job_id reached Succeeded; certificate now in the 25h renewal window."

echo "== Drill 2: waiting for the renewal scheduler to issue one renewal job =="
renewal_job_id=""
for _ in $(seq 1 60); do
    renewal_job_id=$(psql_query "SELECT id FROM certificate_jobs WHERE service_id='$renewal_service_id' AND requested_by='renewal-scheduler' ORDER BY created_at LIMIT 1")
    [ -n "$renewal_job_id" ] && break
    sleep 2
done
if [ -z "$renewal_job_id" ]; then
    echo "The renewal scheduler did not create a renewal job for $renewal_service_id." >&2
    exit 1
fi
wait_terminal "$renewal_job_id" Succeeded
echo "Renewal job $renewal_job_id reached Succeeded."

echo "== Asserting no duplicate renewal across subsequent scans =="
sleep 15
renewal_count=$(psql_query "SELECT count(*) FROM certificate_jobs WHERE service_id='$renewal_service_id' AND requested_by='renewal-scheduler'")
if [ "$renewal_count" != "1" ]; then
    echo "Expected exactly 1 renewal job for $renewal_service_id, found $renewal_count." >&2
    exit 1
fi
echo "Exactly one renewal job exists after repeated scans (minimum renewal interval honored)."

echo "== Final svc1 deployment so svc1 owns the shared current symlink =="
final_job_id=$(create_job "$service_id" "lab-renewal-final-$(date +%s)")
wait_terminal "$final_job_id" Succeeded
echo "Final svc1 job $final_job_id reached Succeeded."

python -c 'import json,sys
path = "secrets/lab-state.json"
state = json.load(open(path, encoding="utf-8"))
state.update({"jobId": sys.argv[1], "renewalServiceId": sys.argv[2], "renewalJobId": sys.argv[3],
              "renewalBootstrapJobId": sys.argv[4], "concurrencyJobId": sys.argv[5],
              "concurrencyRejectedKey": sys.argv[6]})
json.dump(state, open(path, "w", encoding="utf-8"))' \
    "$final_job_id" "$renewal_service_id" "$renewal_job_id" "$bootstrap_job_id" "$concurrency_job_id" "$rejected_key"

echo "Renewal drills complete. Run ./verify.sh to check the Phase 4/5/6 completion conditions."