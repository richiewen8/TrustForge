#!/usr/bin/env bash
# Bootstraps the isolated TrustForge ACME lab: step-ca, Technitium zone/token,
# SSH target preparation, service registration and one real issuance job.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
    cp .env.example .env
    echo "Created .env from .env.example. Replace every REPLACE_WITH_* password, then re-run." >&2
    exit 1
fi
set -a; . ./.env; set +a

API="http://127.0.0.1:${LAB_API_PORT:-5080}"
DNS_API="http://127.0.0.1:${LAB_DNS_UI_PORT:-5780}"
OIDC="http://127.0.0.1:${LAB_OIDC_PORT:-8280}"
TARGET_IP="${LAB_SUBNET_PREFIX:-172.30.90}.30"

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

mkdir -p secrets/ssh
# The bind mount must be a file before the target container first starts.
[ -f secrets/ssh/authorized_keys ] || touch secrets/ssh/authorized_keys

echo "== Starting postgres, step-ca and target =="
compose up -d --build postgres step-ca target
wait_for "step-ca health" 90 compose exec -T step-ca step ca health

if [ ! -f secrets/root_ca.crt ]; then
    compose cp step-ca:/home/step/certs/root_ca.crt secrets/root_ca.crt
fi
if [ ! -f secrets/acme-account.pem ]; then
    # PKCS#8 ("BEGIN PRIVATE KEY"); Certes cannot read SEC1 "EC PRIVATE KEY" PEM.
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out secrets/acme-account.pem
fi
if [ ! -f secrets/ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N "" -f secrets/ssh/id_ed25519 -C trustforge-lab-deployer
    cp secrets/ssh/id_ed25519.pub secrets/ssh/authorized_keys
    compose restart target
fi

echo "== Starting trustforge and keycloak =="
compose up -d trustforge keycloak
wait_for "API readiness" 90 curl -fsS "$API/health/ready"
wait_for "Keycloak realm" 90 curl -fsS "$OIDC/realms/trustforge-dev/.well-known/openid-configuration"

echo "== Configuring Technitium zone and least-privilege API token =="
admin_token=$(curl -fsS -G "$DNS_API/api/user/login" \
    --data-urlencode "user=admin" --data-urlencode "pass=$LAB_DNS_ADMIN_PASSWORD" | json_get token)

if ! curl -fsS -G "$DNS_API/api/zones/create" -H "Authorization: Bearer $admin_token" \
    --data-urlencode "zone=trustforge.lab" --data-urlencode "type=Primary" >/dev/null; then
    echo "Zone trustforge.lab already exists; continuing."
fi
if ! curl -fsS -G "$DNS_API/api/admin/users/create" -H "Authorization: Bearer $admin_token" \
    --data-urlencode "user=trustforge-acme" --data-urlencode "pass=$LAB_DNS_ACME_PASSWORD" >/dev/null; then
    echo "User trustforge-acme already exists; continuing."
fi
curl -fsS -G "$DNS_API/api/zones/permissions/set" -H "Authorization: Bearer $admin_token" \
    --data-urlencode "zone=trustforge.lab" \
    --data-urlencode "userPermissions=trustforge-acme|true|true|true" >/dev/null

curl -fsS -G "$DNS_API/api/user/createToken" \
    --data-urlencode "user=trustforge-acme" --data-urlencode "pass=$LAB_DNS_ACME_PASSWORD" \
    --data-urlencode "tokenName=trustforge-acme" | json_get token > secrets/dns-api-token

curl -fsS -G "$DNS_API/api/zones/records/add" -H "Authorization: Bearer $(cat secrets/dns-api-token)" \
    --data-urlencode "domain=svc1.trustforge.lab" --data-urlencode "zone=trustforge.lab" \
    --data-urlencode "type=A" --data-urlencode "ipAddress=$TARGET_IP" \
    --data-urlencode "overwrite=true" >/dev/null

echo "== Preparing SSH credential and host fingerprint =="
python -c 'import json
pem = open("secrets/ssh/id_ed25519", encoding="utf-8").read()
json.dump({"username": "trustforge-deployer", "privateKeyPem": pem}, open("secrets/ssh-credential.json", "w", encoding="utf-8"))'
# MSYS_NO_PATHCONV stops Git Bash from rewriting the container path to a Windows path.
fingerprint=$(MSYS_NO_PATHCONV=1 compose exec -T target ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')

echo "== Obtaining Keycloak access token =="
access_token=$(curl -fsS -X POST "$OIDC/realms/trustforge-dev/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=trustforge-cli \
    --data-urlencode "username=$LAB_OIDC_DEV_USERNAME" --data-urlencode "password=$LAB_OIDC_DEV_PASSWORD" | json_get access_token)

register_service() {
    local name="$1" san="$2"
    curl -fsS -X POST "$API/api/v1/services" \
        -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" -d @- <<EOF | json_get id
{
  "name": "$name",
  "environment": "lab",
  "owner": "trustforge-lab",
  "host": "target",
  "port": 22,
  "hostKeyFingerprint": "$fingerprint",
  "sshCredentialRef": "secret://file//run/trustforge/secrets/ssh-credential.json",
  "profileId": "11111111-1111-1111-1111-111111111111",
  "sans": ["$san"],
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
}

write_target_registration() {
    local service_id="$1"
    local guid_nodash
    guid_nodash=$(printf '%s' "$service_id" | tr -d '-')
    compose exec -T target sh -c "umask 077; cat > /etc/trustforge/services/$guid_nodash.json" <<EOF
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
}

echo "== Registering services =="
service_id=$(register_service "demo-tls" "svc1.trustforge.lab")
write_target_registration "$service_id"
failure_service_id=$(register_service "demo-tls-out-of-zone" "svc2.not-allowed.example")
write_target_registration "$failure_service_id"

echo "== Creating certificate jobs =="
job_id=$(curl -fsS -X POST "$API/api/v1/services/$service_id/certificate-jobs" \
    -H "Authorization: Bearer $access_token" -H "Idempotency-Key: lab-success-$(date +%s)" | json_get id)
failure_job_id=$(curl -fsS -X POST "$API/api/v1/services/$failure_service_id/certificate-jobs" \
    -H "Authorization: Bearer $access_token" -H "Idempotency-Key: lab-failure-$(date +%s)" | json_get id)

python -c 'import json,sys
json.dump({"serviceId": sys.argv[1], "jobId": sys.argv[2], "failureServiceId": sys.argv[3], "failureJobId": sys.argv[4]},
          open("secrets/lab-state.json", "w", encoding="utf-8"))' \
    "$service_id" "$job_id" "$failure_service_id" "$failure_job_id"

echo "== Waiting for the success job to finish =="
state=""
for i in $(seq 1 150); do
    state=$(curl -fsS "$API/api/v1/certificate-jobs/$job_id" -H "Authorization: Bearer $access_token" | json_get state)
    case "$state" in
        Succeeded|Failed|FailedRolledBack|RollbackFailed|Cancelled) break ;;
    esac
    sleep 2
done

echo "Success job $job_id finished in state: $state"
echo "Run ./verify.sh to check the Phase 4 completion conditions."
[ "$state" = "Succeeded" ]