#!/usr/bin/env bash
# Phase 5 deployment drills against a lab bootstrapped by setup.sh:
#  1. health failure after activation -> rollback -> FailedRolledBack + Warning alert
#  2. health failure during rollback  -> RollbackFailed + Critical alert
#  3. two more successful deployments -> retention prunes the oldest release/key slot
# Results are appended to secrets/lab-state.json for verify.sh.
set -euo pipefail
cd "$(dirname "$0")"
# Container paths like /tmp/... must not be rewritten to Windows paths by Git Bash.
export MSYS_NO_PATHCONV=1

if [ ! -f .env ] || [ ! -f secrets/lab-state.json ]; then
    echo "Run ./setup.sh first." >&2
    exit 1
fi
set -a; . ./.env; set +a

API="http://127.0.0.1:${LAB_API_PORT:-5080}"
OIDC="http://127.0.0.1:${LAB_OIDC_PORT:-8280}"

compose() { docker compose "$@"; }

json_get() {
    python -c 'import json,sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(value if not isinstance(value, (dict, list)) else json.dumps(value))' "$1"
}

service_id=$(json_get serviceId < secrets/lab-state.json)
first_job_id=$(json_get jobId < secrets/lab-state.json)

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

# The marker must appear after Connecting (which runs the first health check) and before
# the Verifying health call. No health check runs between Connecting and Verifying, so arming
# as early as GeneratingCsr gives the whole issuance+staging lead time and avoids the race
# where a narrow Staging/Activating/Verifying window is missed on a fast pipeline.
arm_marker_at_deployment() {
    local job="$1" marker="$2" state=""
    for _ in $(seq 1 300); do
        state=$(job_state "$job")
        case "$state" in
            GeneratingCsr|CreatingOrder|AwaitingChallenge|Signing|Staging|Activating|Verifying)
                compose exec -T target touch "$marker"
                return 0 ;;
            Succeeded|Failed|FailedRolledBack|RollbackFailed|Cancelled)
                echo "Drill job $job reached '$state' before the failure marker could be armed." >&2
                exit 1 ;;
        esac
        sleep 0.2
    done
    echo "Timed out arming the failure marker for job $job." >&2
    exit 1
}

echo "== Checking the lab alert receiver =="
compose exec -T target python3 -c "import socket; socket.create_connection(('127.0.0.1', 8444), 3).close()"

echo "== Registering the drill service =="
fingerprint=$(MSYS_NO_PATHCONV=1 compose exec -T target ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')
drill_service_id=$(curl -fsS -X POST "$API/api/v1/services" \
    -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" -d @- <<EOF | json_get id
{
  "name": "demo-tls-drill",
  "environment": "lab",
  "owner": "trustforge-lab",
  "host": "target",
  "port": 22,
  "hostKeyFingerprint": "$fingerprint",
  "sshCredentialRef": "secret://file//run/trustforge/secrets/ssh-credential.json",
  "profileId": "11111111-1111-1111-1111-111111111111",
  "sans": ["svc3.trustforge.lab"],
  "certificatePath": "/etc/trustforge-demo/current/certificate.pem",
  "chainPath": "/etc/trustforge-demo/current/chain.pem",
  "privateKeyPath": "/etc/trustforge-demo/current/private-key.pem",
  "fileOwner": "root",
  "fileGroup": "root",
  "fileMode": "0600",
  "remoteHelperId": "trustforge-certctl-v1",
  "reloadActionId": "demo-tls-reload",
  "healthCheckId": "demo-tls-health-conditional"
}
EOF
)
drill_nodash=$(printf '%s' "$drill_service_id" | tr -d '-')
compose exec -T target sh -c "umask 077; cat > /etc/trustforge/services/$drill_nodash.json" <<EOF
{
  "certificatePath": "/etc/trustforge-demo/current/certificate.pem",
  "chainPath": "/etc/trustforge-demo/current/chain.pem",
  "privateKeyPath": "/etc/trustforge-demo/current/private-key.pem",
  "fileOwner": "root",
  "fileGroup": "root",
  "fileMode": "0600",
  "remoteHelperId": "trustforge-certctl-v1",
  "reloadActionId": "demo-tls-reload",
  "healthCheckId": "demo-tls-health-conditional"
}
EOF

echo "== Drill 1: verify health failure must roll back =="
rolled_back_job_id=$(create_job "$drill_service_id" "lab-drill-rollback-$(date +%s)")
arm_marker_at_deployment "$rolled_back_job_id" /tmp/trustforge-health-fail
wait_terminal "$rolled_back_job_id" FailedRolledBack
echo "Drill 1 job $rolled_back_job_id reached FailedRolledBack."

echo "== Drill 2: rollback health failure must stop and alert =="
rollback_failed_job_id=$(create_job "$drill_service_id" "lab-drill-rollbackfail-$(date +%s)")
arm_marker_at_deployment "$rollback_failed_job_id" /tmp/trustforge-health-fail-always
wait_terminal "$rollback_failed_job_id" RollbackFailed
compose exec -T target rm -f /tmp/trustforge-health-fail-always
echo "Drill 2 job $rollback_failed_job_id reached RollbackFailed; marker cleared."

echo "== Two more successful deployments for retention cleanup =="
second_job_id=$(create_job "$service_id" "lab-retention-2-$(date +%s)")
wait_terminal "$second_job_id" Succeeded
third_job_id=$(create_job "$service_id" "lab-retention-3-$(date +%s)")
wait_terminal "$third_job_id" Succeeded

python -c 'import json,sys
path = "secrets/lab-state.json"
state = json.load(open(path, encoding="utf-8"))
state.update({"jobId": sys.argv[1], "firstJobId": sys.argv[2], "drillServiceId": sys.argv[3],
              "rolledBackJobId": sys.argv[4], "rollbackFailedJobId": sys.argv[5]})
json.dump(state, open(path, "w", encoding="utf-8"))' \
    "$third_job_id" "$first_job_id" "$drill_service_id" "$rolled_back_job_id" "$rollback_failed_job_id"

echo "Drills complete. Run ./verify.sh to check the Phase 4/5 completion conditions."