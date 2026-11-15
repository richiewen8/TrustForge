#!/usr/bin/env bash
# Asserts the Phase 4 completion conditions against a lab bootstrapped by setup.sh.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ] || [ ! -f secrets/lab-state.json ]; then
    echo "Run ./setup.sh first." >&2
    exit 1
fi
set -a; . ./.env; set +a

API="http://127.0.0.1:${LAB_API_PORT:-5080}"
DNS_API="http://127.0.0.1:${LAB_DNS_UI_PORT:-5780}"
OIDC="http://127.0.0.1:${LAB_OIDC_PORT:-8280}"
TLS_PORT="${LAB_TARGET_TLS_PORT:-8443}"

compose() { docker compose "$@"; }

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
service_nodash=$(printf '%s' "$service_id" | tr -d '-')
job_nodash=$(printf '%s' "$job_id" | tr -d '-')

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

echo
if [ "$failures" -eq 0 ]; then
    echo "All Phase 4 completion checks passed."
else
    echo "$failures check(s) failed." >&2
    exit 1
fi