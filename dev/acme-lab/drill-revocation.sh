#!/usr/bin/env bash
# Phase 7 revocation drills against a lab bootstrapped by setup.sh (which enables
# step-ca CRL generation) and drilled by drill-deployment.sh:
#  1. RBAC: revocation is PlatformAdmin-only, reading stays CertificateReader, anonymous is 401
#  2. conflict paths: no active certificate, an in-flight job, missing/invalid request fields
#  3. real ACME revocation with the lab account key, recorded durably with the CA's serial
#  4. CRL distribution: the revoked serial and its reason appear in the CA's CRL
#  5. audit alert: one Critical alert for keyCompromise, one Warning for unspecified, both delivered
#  6. replay protection: a fresh idempotency key and a reused key both return the same record
#  7. durable retry: a CA outage parks the revocation in Pending, the retry worker finishes it
#  8. no collateral damage: other services' certificates stay out of the CRL
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
    echo "Run ./drill-deployment.sh before drill-revocation.sh." >&2
    exit 1
fi
set -a; . ./.env; set +a

API="http://127.0.0.1:${LAB_API_PORT:-5080}"
DNS_API="http://127.0.0.1:${LAB_DNS_UI_PORT:-5780}"
OIDC="http://127.0.0.1:${LAB_OIDC_PORT:-8280}"
STEP_CA="https://127.0.0.1:${LAB_STEP_CA_PORT:-9000}"
TARGET_IP="${LAB_SUBNET_PREFIX:-172.30.90}.30"
PG_USER="${LAB_POSTGRES_USER:-trustforge}"
PG_DB="${LAB_POSTGRES_DB:-trustforge_lab}"
CO_USER="trustforge-cert-operator"

compose() { docker compose "$@"; }

die() { echo "REVOCATION DRILL FAILED: $*" >&2; exit 1; }
say() { echo "ok: $*"; }

json_get() {
    python -c 'import json,sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(value if not isinstance(value, (dict, list)) else json.dumps(value))' "$1"
}

# Reads one claim from a JWT access token; list claims are joined with commas.
jwt_claim() {
    printf '%s' "$1" | python -c 'import base64,json,sys
segment = sys.stdin.read().strip().split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))
value = claims.get(sys.argv[1])
print(",".join(value) if isinstance(value, list) else value)' "$2"
}

wait_for() {
    local description="$1" attempts="$2"
    shift 2
    for _ in $(seq 1 "$attempts"); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    die "timed out waiting for $description"
}

psql_query() {
    compose exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -tAc "$1" | tr -d '[:space:]'
}

# Downloads and decodes the CA CRL; crl_lists / crl_entry / crl_serials come from lab-crl.sh.
. ./lab-crl.sh

active_serial() {
    compose exec -T target sh -c \
        'openssl x509 -in /etc/trustforge-demo/current/certificate.pem -noout -serial' | sed 's/^serial=//' | tr -d '\r'
}

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
    [ "$state" = "$expected" ] || die "job $job ended in '$state', expected '$expected'"
    say "job $job reached $expected"
}

# Prints only the HTTP status code of a request. Git Bash hands "/dev/null" to the native
# curl.exe verbatim while MSYS_NO_PATHCONV is set, so the response body is dropped by the
# pipe rather than with -o.
http_code() {
    curl -sS -w '\n%{http_code}' "$@" | tail -n1
}

# revoke <token> <service> <idempotency-key> <reason> -> "<http_code> <body>"
revoke_raw() {
    local response
    response=$(curl -sS -w '\n%{http_code}' -X POST "$API/api/v1/services/$2/revocations" \
        -H "Authorization: Bearer $1" -H "Content-Type: application/json" -H "Idempotency-Key: $3" \
        -d "{\"reason\":\"$4\"}")
    printf '%s %s' "$(printf '%s' "$response" | tail -n1)" "$(printf '%s' "$response" | sed '$d')"
}

revoke() {
    local raw code body
    raw=$(revoke_raw "$access_token" "$1" "$2" "$3")
    code=${raw%% *}
    body=${raw#* }
    [ "$code" = "$4" ] || die "revoke $1 expected HTTP $4, got $code $body"
    printf '%s' "$body"
}

alert_for() {
    curl -fsS "$API/api/v1/certificate-alerts?limit=200" -H "Authorization: Bearer $access_token" \
        | python -c 'import json,sys
items = json.load(sys.stdin)
matches = [a for a in items if a.get("dedupeKey") == sys.argv[1]]
print(json.dumps(matches[0]) if matches else "")' "$1"
}

wait_alert() {
    local key="$1" json=""
    for _ in $(seq 1 45); do
        json=$(alert_for "$key")
        [ -n "$json" ] && break
        sleep 2
    done
    [ -n "$json" ] || die "no alert with dedupe key $key"
    printf '%s' "$json"
}

revocation_state() {
    curl -fsS "$API/api/v1/certificate-revocations/$1" -H "Authorization: Bearer $access_token" | json_get state
}

service_id=$(json_get serviceId < secrets/lab-state.json)
failure_service_id=$(json_get failureServiceId < secrets/lab-state.json)

access_token=$(curl -fsS -X POST "$OIDC/realms/trustforge-dev/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=trustforge-cli \
    --data-urlencode "username=$LAB_OIDC_DEV_USERNAME" --data-urlencode "password=$LAB_OIDC_DEV_PASSWORD" | json_get access_token)
dev_sub=$(jwt_claim "$access_token" sub)

echo "== Preconditions: CRL distribution is enabled on step-ca =="
wait_for "CRL endpoint" 30 crl_text
crl_text | grep -q 'Issuing Distribution Point' || die "the CRL carries no issuing distribution point"
say "step-ca serves a CRL with an issuing distribution point"

echo "== Capturing the svc1 serial for the no-collateral check =="
svc1_serial=$(active_serial)
[ -n "$svc1_serial" ] || die "could not read the deployed svc1 serial"
crl_lists "$svc1_serial" && die "svc1 serial $svc1_serial was already revoked before the drill"
say "svc1 active serial $svc1_serial is not revoked"

echo "== Signing in as the realm-imported CertificateOperator-only user =="
co_token=$(curl -fsS -X POST "$OIDC/realms/trustforge-dev/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=trustforge-cli \
    --data-urlencode "username=$CO_USER" --data-urlencode "password=$LAB_OIDC_DEV_PASSWORD" | json_get access_token)
co_roles=$(jwt_claim "$co_token" role)
case "$co_roles" in
    *CertificateOperator*) ;;
    *) die "user $CO_USER does not hold CertificateOperator (roles: $co_roles); re-import the dev realm" ;;
esac
case "$co_roles" in
    *PlatformAdmin*) die "user $CO_USER must not hold PlatformAdmin (roles: $co_roles)" ;;
esac
say "user $CO_USER holds [$co_roles], so the 403 below is about the role and not a missing account"

echo "== Drill 1: revocation is narrower than issuance =="
anon_code=$(http_code -X POST "$API/api/v1/services/$service_id/revocations" \
    -H 'Content-Type: application/json' -H 'Idempotency-Key: drill-anon' -d '{"reason":"KeyCompromise"}')
[ "$anon_code" = "401" ] || die "anonymous revocation expected 401, got $anon_code"
say "anonymous revocation is 401"
co_raw=$(revoke_raw "$co_token" "$service_id" "drill-co-forbidden" "KeyCompromise")
[ "${co_raw%% *}" = "403" ] || die "CertificateOperator revocation expected 403, got $co_raw"
say "CertificateOperator is 403 on POST /revocations"
co_read=$(http_code "$API/api/v1/services/$service_id/revocations" -H "Authorization: Bearer $co_token")
[ "$co_read" = "200" ] || die "CertificateOperator reading expected 200, got $co_read"
say "CertificateOperator keeps read access"
co_issue_raw=$(curl -sS -w '\n%{http_code}' -X POST "$API/api/v1/services/$service_id/certificate-jobs" \
    -H "Authorization: Bearer $co_token" -H "Idempotency-Key: lab-drill-co-issues-$(date +%s)")
[ "$(printf '%s' "$co_issue_raw" | tail -n1)" = "202" ] || die "CertificateOperator issuance expected 202, got $co_issue_raw"
# The svc1 job must finish before svc5 deploys, because both services share the target's
# /etc/trustforge-demo/current path and the serial assertions read it.
wait_terminal "$(printf '%s' "$co_issue_raw" | sed '$d' | json_get id)" Succeeded
say "CertificateOperator can still issue, so only revocation is restricted"

echo "== Drill 2: request validation and conflicts =="
no_key=$(http_code -X POST "$API/api/v1/services/$service_id/revocations" \
    -H "Authorization: Bearer $access_token" -H 'Content-Type: application/json' -d '{"reason":"KeyCompromise"}')
[ "$no_key" = "400" ] || die "missing Idempotency-Key expected 400, got $no_key"
bad_reason=$(revoke_raw "$access_token" "$service_id" "drill-bad-reason" "keyload")
[ "${bad_reason%% *}" = "400" ] || die "unknown reason expected 400, got $bad_reason"
say "missing idempotency key and unknown reason are 400"
no_cert=$(revoke_raw "$access_token" "$failure_service_id" "drill-no-cert" "KeyCompromise")
no_cert_code=${no_cert%% *}
no_cert_error=$(printf '%s' "${no_cert#* }" | json_get error)
[ "$no_cert_code" = "409" ] && [ "$no_cert_error" = "no_active_certificate" ] \
    || die "service without a certificate expected 409 no_active_certificate, got $no_cert_code $no_cert_error"
say "a service with no active deployment is 409 no_active_certificate"

echo "== Registering the revocation drill service =="
fingerprint=$(compose exec -T target ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')
revoke_service_id=$(curl -fsS -X POST "$API/api/v1/services" \
    -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" -d @- <<EOF | json_get id
{
  "name": "demo-tls-revocation",
  "environment": "lab",
  "owner": "trustforge-lab",
  "host": "target",
  "port": 22,
  "hostKeyFingerprint": "$fingerprint",
  "sshCredentialRef": "secret://file//run/trustforge/secrets/ssh-credential.json",
  "profileId": "11111111-1111-1111-1111-111111111111",
  "sans": ["svc5.trustforge.lab"],
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
)
revoke_nodash=$(printf '%s' "$revoke_service_id" | tr -d '-')
compose exec -T target sh -c "umask 077; mkdir -p /etc/trustforge/services; cat > /etc/trustforge/services/$revoke_nodash.json" <<EOF
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
    --data-urlencode "domain=svc5.trustforge.lab" --data-urlencode "zone=trustforge.lab" \
    --data-urlencode "type=A" --data-urlencode "ipAddress=$TARGET_IP" \
    --data-urlencode "overwrite=true" >/dev/null
say "service demo-tls-revocation (svc5.trustforge.lab) registered as $revoke_service_id"

echo "== Bootstrapping svc5 with a manual job =="
job_a=$(create_job "$revoke_service_id" "lab-revoke-bootstrap-$(date +%s)")
busy=$(revoke_raw "$access_token" "$revoke_service_id" "drill-job-active" "KeyCompromise")
busy_code=${busy%% *}
busy_error=$(printf '%s' "${busy#* }" | json_get error)
if [ "$busy_code" = "409" ] && [ "$busy_error" = "service_job_active" ]; then
    say "revoking while a job is in flight is 409 service_job_active"
else
    echo "NOTE: the in-flight window had already closed (HTTP $busy_code $busy_error); the guard is covered by drill-renewal for jobs."
fi
wait_terminal "$job_a" Succeeded
serial_a=$(active_serial)
crl_lists "$serial_a" && die "svc5 serial $serial_a was revoked before the drill asked for it"
say "svc5 active serial $serial_a is absent from the CRL"

echo "== Drill 3: revoking the active svc5 certificate for keyCompromise =="
key_a="lab-revoke-a-$(date +%s)"
revoked_a=$(revoke "$revoke_service_id" "$key_a" "KeyCompromise" 200)
[ "$(printf '%s' "$revoked_a" | json_get status)" = "revoked" ] || die "expected status revoked, got $revoked_a"
revocation_a=$(printf '%s' "$revoked_a" | json_get revocation.id)
[ "$(printf '%s' "$revoked_a" | json_get revocation.state)" = "Revoked" ] || die "record not Revoked: $revoked_a"
[ "$(printf '%s' "$revoked_a" | json_get revocation.serial)" = "$serial_a" ] \
    || die "recorded serial $(printf '%s' "$revoked_a" | json_get revocation.serial) != deployed serial $serial_a"
[ "$(printf '%s' "$revoked_a" | json_get revocation.reason)" = "KeyCompromise" ] || die "reason not recorded: $revoked_a"
[ "$(printf '%s' "$revoked_a" | json_get revocation.jobId)" = "$job_a" ] || die "revocation is not bound to the active job: $revoked_a"
[ "$(printf '%s' "$revoked_a" | json_get revocation.requestedBy)" = "$dev_sub" ] || die "revocation did not record the caller subject: $revoked_a"
[ "$(printf '%s' "$revoked_a" | json_get revocation.revokedAt)" != "None" ] || die "revokedAt is missing: $revoked_a"
say "revocation $revocation_a revoked serial $serial_a with the CA-side serial recorded"

echo "== Drill 4: the CA publishes the revocation in its CRL =="
for _ in $(seq 1 30); do crl_lists "$serial_a" && break; sleep 2; done
crl_lists "$serial_a" || die "serial $serial_a never appeared in the CA CRL"
entry_reason=$(crl_entry "$serial_a")
[ "$entry_reason" = "Key Compromise" ] || die "CRL entry reason for $serial_a is '$entry_reason', expected 'Key Compromise'"
say "the CRL lists $serial_a with reason '$entry_reason'"

echo "== Drill 5: the revocation raised its audit alert =="
alert_a=$(wait_alert "revoked:$serial_a")
[ "$(printf '%s' "$alert_a" | json_get kind)" = "CertificateRevoked" ] || die "unexpected alert kind: $alert_a"
[ "$(printf '%s' "$alert_a" | json_get severity)" = "Critical" ] || die "keyCompromise must alert Critical: $alert_a"
[ "$(printf '%s' "$alert_a" | json_get jobId)" = "$job_a" ] || die "the alert lost its job linkage: $alert_a"
alert_a_id=$(printf '%s' "$alert_a" | json_get id)
for _ in $(seq 1 30); do
    [ "$(printf '%s' "$(alert_for "revoked:$serial_a")" | json_get deliveryState)" = "Delivered" ] && break
    sleep 2
done
[ "$(printf '%s' "$(alert_for "revoked:$serial_a")" | json_get deliveryState)" = "Delivered" ] || die "the revocation alert was never delivered"
wait_for "webhook receiver log" 15 compose exec -T target grep -q "$alert_a_id" /var/lib/trustforge-demo/alerts.jsonl
say "alert $alert_a_id is Critical, job-linked, delivered to the webhook receiver"

echo "== Drill 6: replay protection =="
replay_new_key=$(revoke "$revoke_service_id" "lab-revoke-a-retry-$(date +%s)" "KeyCompromise" 200)
[ "$(printf '%s' "$replay_new_key" | json_get status)" = "replayed" ] || die "a second key must replay: $replay_new_key"
[ "$(printf '%s' "$replay_new_key" | json_get revocation.id)" = "$revocation_a" ] || die "replay returned a different record: $replay_new_key"
replay_same_key=$(revoke "$revoke_service_id" "$key_a" "Unspecified" 200)
[ "$(printf '%s' "$replay_same_key" | json_get status)" = "replayed" ] || die "the same key must replay: $replay_same_key"
[ "$(printf '%s' "$replay_same_key" | json_get revocation.id)" = "$revocation_a" ] || die "the same key created a second record: $replay_same_key"
rows_a=$(psql_query "SELECT count(*) FROM certificate_revocations WHERE serial='$serial_a'")
[ "$rows_a" = "1" ] || die "expected 1 revocation row for $serial_a, found $rows_a"
say "renewed and reused idempotency keys both replay revocation $revocation_a (1 row in the database)"
listed=$(curl -fsS "$API/api/v1/services/$revoke_service_id/revocations" -H "Authorization: Bearer $access_token" \
    | python -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$listed" = "1" ] || die "the service listing returned $listed records, expected 1"
say "GET /services/{id}/revocations lists the record"

echo "== Drill 7: re-issuing after a revocation, then a CA outage during revocation =="
job_b=$(create_job "$revoke_service_id" "lab-revoke-reresolve-$(date +%s)")
wait_terminal "$job_b" Succeeded
serial_b=$(active_serial)
[ "$serial_b" != "$serial_a" ] || die "re-issue after revocation returned the same serial"
crl_lists "$serial_b" && die "the replacement serial $serial_b is already revoked"
say "re-issue after revocation succeeded: new serial $serial_b"

compose stop step-ca >/dev/null
key_b="lab-revoke-b-$(date +%s)"
pending_b=$(revoke "$revoke_service_id" "$key_b" "Unspecified" 202)
revocation_b=$(printf '%s' "$pending_b" | json_get revocation.id)
[ "$(printf '%s' "$pending_b" | json_get status)" = "pending" ] || die "expected status pending, got $pending_b"
[ "$(printf '%s' "$pending_b" | json_get revocation.state)" = "Pending" ] || die "record should stay Pending: $pending_b"
# A freshly queued row is instantly claimable, so the retry worker may already own the attempts by the
# time the request reads the row back: either the inline failure recorded its reason, or the worker's
# claim did. Which of the two wrote it is not a correctness property; that the row is Pending with a
# scheduled next attempt is.
attempt_b=$(printf '%s' "$pending_b" | json_get revocation.attemptCount)
error_b=$(printf '%s' "$pending_b" | json_get revocation.lastError)
{ [ "$error_b" != "None" ] || [ "$attempt_b" != "0" ]; } \
    || die "the unreachable CA left no trace on the row: $pending_b"
say "revocation with the CA down is durable: Pending, attemptCount=$attempt_b, lastError=$( [ "$error_b" = "None" ] && echo 'owned by the retry worker' || echo "$error_b" )"
compose start step-ca >/dev/null
wait_for "step-ca health after the outage" 60 compose exec -T step-ca step ca health
revoked_b=""
for _ in $(seq 1 60); do
    revoked_b=$(revocation_state "$revocation_b")
    [ "$revoked_b" = "Revoked" ] && break
    sleep 2
done
[ "$revoked_b" = "Revoked" ] || die "revocation $revocation_b stayed in state '$revoked_b' after the CA came back"
retried=$(curl -fsS "$API/api/v1/certificate-revocations/$revocation_b" -H "Authorization: Bearer $access_token")
[ "$(printf '%s' "$retried" | json_get attemptCount)" != "0" ] \
    || die "revocation $revocation_b was never claimed by the retry worker: $retried"
[ "$(printf '%s' "$retried" | json_get revokedAt)" != "None" ] || die "the retried revocation has no revokedAt: $retried"
[ "$(printf '%s' "$retried" | json_get lastError)" = "None" ] \
    || die "a completed revocation still reports lastError: $retried"
crl_lists "$serial_b" || die "serial $serial_b is missing from the CRL after the retry"
rows_b=$(psql_query "SELECT count(*) FROM certificate_revocations WHERE serial='$serial_b'")
[ "$rows_b" = "1" ] || die "the retry produced $rows_b rows for $serial_b"
alert_b=$(wait_alert "revoked:$serial_b")
[ "$(printf '%s' "$alert_b" | json_get severity)" = "Warning" ] || die "an unspecified revocation must alert Warning: $alert_b"
giveup_alerts=$(psql_query "SELECT count(*) FROM certificate_alerts WHERE kind='RevocationFailed' AND service_id='$revoke_service_id'")
[ "$giveup_alerts" = "0" ] || die "a recovered revocation raised a give-up alert ($giveup_alerts rows)"
say "revocation $revocation_b survived the CA outage: Pending -> Revoked by the retry worker, 1 row, Warning alert, no give-up alert"

echo "== Drill 8: no collateral damage =="
crl_lists "$svc1_serial" && die "revoking svc5 also revoked svc1's certificate $svc1_serial"
say "svc1 serial $svc1_serial is still absent from the CRL"
audit=$(curl -fsS "$API/api/v1/audit/export?serviceId=$revoke_service_id&limit=200" -H "Authorization: Bearer $access_token")
printf '%s' "$audit" | python -c 'import json,sys
bundle = json.load(sys.stdin)
items = bundle["revocations"]
serials = {r["serial"] for r in items}
missing = [s for s in sys.argv[2:] if s not in serials]
if missing:
    raise SystemExit("the audit export is missing " + ", ".join(missing))
if any(r["serviceId"] != sys.argv[1] for r in items):
    raise SystemExit("the audit export leaked revocations of another service")' \
    "$revoke_service_id" "$serial_a" "$serial_b" \
    || die "the audit export does not carry both svc5 revocations"
say "the audit export includes revocations, scoped by serviceId"

echo "== Final svc1 deployment so svc1 owns the shared current symlink =="
final_job_id=$(create_job "$service_id" "lab-revoke-final-$(date +%s)")
wait_terminal "$final_job_id" Succeeded
final_svc1_serial=$(active_serial)
crl_lists "$final_svc1_serial" && die "the freshly deployed svc1 certificate $final_svc1_serial is revoked"
say "the newly deployed svc1 serial $final_svc1_serial is absent from the CRL"

python -c 'import json,sys
path = "secrets/lab-state.json"
state = json.load(open(path, encoding="utf-8"))
state.update({
    "jobId": sys.argv[1],
    "revocationDrill": {
        "serviceId": sys.argv[2],
        "revocationId": sys.argv[3],
        "serial": sys.argv[4],
        "retryRevocationId": sys.argv[5],
        "retrySerial": sys.argv[6],
        "unaffectedSerial": sys.argv[7],
        "finalSvc1Serial": sys.argv[8],
        "operatorUsername": sys.argv[9],
    },
})
json.dump(state, open(path, "w", encoding="utf-8"))' \
    "$final_job_id" "$revoke_service_id" "$revocation_a" "$serial_a" "$revocation_b" "$serial_b" "$svc1_serial" "$final_svc1_serial" "$CO_USER"

echo "Revocation drills complete. Run ./verify.sh to check the Phase 7 completion conditions."
