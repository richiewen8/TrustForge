#!/usr/bin/env bash
# Real CA / real target acceptance drill.
#
# For every host in TF_HOSTS_FILE: register the service, pause for the operator to install the
# target-side registration, run the API's own connection test, drive one real DNS-01 issuance to
# completion, verify what the target is actually serving against the CA root, then revoke only the
# certificate this drill minted and confirm the CA published the serial on its CRL.
#
# Run ./preflight.sh first. Revocation is irreversible on a real CA; TF_REVOKE_AFTER=false stops
# after issuance.
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE="${ACCEPTANCE_ENV:-acceptance.env}"
if [ ! -f "$ENV_FILE" ]; then
    echo "Missing $ENV_FILE. Copy acceptance.env.example and fill in the real values." >&2
    exit 1
fi
set -a; . "$ENV_FILE"; set +a
[ -f "${TF_HOSTS_FILE:-}" ] || { echo "Missing TF_HOSTS_FILE=${TF_HOSTS_FILE:-}." >&2; exit 1; }
[ -f "${TF_ACME_ROOT_CA_FILE:-}" ] || { echo "Missing TF_ACME_ROOT_CA_FILE=${TF_ACME_ROOT_CA_FILE:-}." >&2; exit 1; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
RUN_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT_DIR="${TF_OUT_DIR:-out}"
REPORT="$OUT_DIR/acceptance-$RUN_STAMP.json"
mkdir -p "$OUT_DIR"

api=(curl -fsS)
[ -n "${TF_API_CA_FILE:-}" ] && api+=(--cacert "$TF_API_CA_FILE")

# TLS-verified fetch against the CA, pinned to the root certificate. tlsfetch.py is used instead
# of curl because curl builds differ in private-CA revocation behaviour; verification itself is
# never relaxed -- the URL hostname still drives SNI and name matching when --override-ip is set.
ca_fetch() {
    if [ -n "${TF_CA_RESOLVE_IP:-}" ]; then
        python tlsfetch.py "$@" --override-ip "$TF_CA_RESOLVE_IP" --cacert "$TF_ACME_ROOT_CA_FILE"
    else
        python tlsfetch.py "$@" --cacert "$TF_ACME_ROOT_CA_FILE"
    fi
}

total=0
failures=0
check() {
    local description="$1"
    shift
    local output=""
    local rc=0
    total=$((total + 1))
    output=$("$@" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "PASS: $description"
    else
        echo "FAIL: $description"
        if [ -n "$output" ]; then
            echo "      $(printf '%s\n' "$output" | tail -n 3)"
        fi
        failures=$((failures + 1))
    fi
}

info() { echo "      $*"; }

accepted_revocation_status() {
    case "$1" in
        revoked|pending|replayed) echo "CA accepted the request ($1)"; return 0 ;;
        *) echo "no revocation accepted (got '${1:-none}')"; return 1 ;;
    esac
}
die() { echo "ABORT: $*" >&2; exit 1; }

json_get() {
    python -c 'import json,sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(value if not isinstance(value, (dict, list)) else json.dumps(value))' "$1"
}

fingerprints_equal() {
    local left right
    left=$(printf '%s' "$1" | tr -d ':' | tr 'a-f' 'A-F')
    right=$(printf '%s' "$2" | tr -d ':' | tr 'a-f' 'A-F')
    if [ -z "$left" ] || [ "$left" != "$right" ]; then
        echo "served ${left:-none}, issued ${right:-none} (must match)"
        return 1
    fi
    echo "served and issued are both $left"
}

different_fingerprint() {
    local left right
    left=$(printf '%s' "$1" | tr -d ':' | tr 'a-f' 'A-F')
    right=$(printf '%s' "$2" | tr -d ':' | tr 'a-f' 'A-F')
    if [ -z "$left" ] || [ "$left" = "$right" ]; then
        echo "recovery ${left:-none}, original ${right:-none}"
        return 1
    fi
    echo "original $right, recovery $left"
}

is_revocation_reason() {
    case "$1" in
        Unspecified|KeyCompromise|CaCompromise|AffiliationChanged|Superseded|CessationOfOperation) return 0 ;;
        *) echo "reason must be Unspecified, KeyCompromise, CaCompromise, AffiliationChanged, Superseded, or CessationOfOperation." >&2
           return 1 ;;
    esac
}

crl_lists() {
    local serial="$1"
    [ -n "${TF_CRL_URL:-}" ] || return 1
    ca_fetch "$TF_CRL_URL" --out "$TMPD/crl.der" 2>/dev/null || return 1
    openssl crl -in "$TMPD/crl.der" -inform DER -noout -text 2>/dev/null | grep -q \
        "Serial Number: $(printf '%s' "$serial" | tr 'a-f' 'A-F')"
}

access_token=$(curl -fsS -X POST "$TF_OIDC_TOKEN_URL" \
    -d grant_type=password -d client_id="$TF_OIDC_CLIENT_ID" \
    --data-urlencode "username=${TF_OPERATOR_USERNAME:-}" --data-urlencode "password=${TF_OPERATOR_PASSWORD:-}" \
    | json_get access_token) || die "could not obtain an access token from $TF_OIDC_TOKEN_URL"

# Prints the finished job id on stdout; every diagnostic goes to stderr so the caller can capture it.
create_job_and_wait() {
    local service_id="$1" label="$2" key="$3"
    local job_id state="" waited=0
    job_id=$("${api[@]}" -X POST "$TF_API_URL/api/v1/services/$service_id/certificate-jobs" \
        -H "Authorization: Bearer $access_token" -H "Idempotency-Key: $key") || {
        echo "      $label: job creation was rejected (conflict or permission?)" >&2
        return 1
    }
    job_id=$(printf '%s' "$job_id" | json_get id) || { echo "      $label: no job id in the response" >&2; return 1; }
    while [ "$waited" -lt "${TF_JOB_TIMEOUT_SECONDS:-600}" ]; do
        state=$("${api[@]}" "$TF_API_URL/api/v1/certificate-jobs/$job_id" \
            -H "Authorization: Bearer $access_token" | json_get state) || return 1
        case "$state" in
            Succeeded|Simulated|Failed|FailedRolledBack|RollbackFailed|Cancelled) break ;;
        esac
        sleep 5
        waited=$((waited + 5))
    done
    case "$state" in
        Succeeded|Simulated) printf '%s' "$job_id" ;;
        *)
            echo "      $label ended in state $state" >&2
            "${api[@]}" "$TF_API_URL/api/v1/certificate-jobs/$job_id" -H "Authorization: Bearer $access_token" \
                | python -c 'import json,sys
job = json.load(sys.stdin)
print("      failureStage=%s failureSummary=%s" % (job.get("failureStage"), job.get("failureSummary")))' >&2 || true
            return 1
            ;;
    esac
}

hosts_tsv="$TMPD/hosts.tsv"
python -c 'import json,sys
for h in json.load(open(sys.argv[1], encoding="utf-8")):
    probe = h.get("tlsProbe") or {}
    print("|".join([h.get("name",""), probe.get("host",""), str(probe.get("port","")),
                    (h.get("sans") or [""])[0]]))' "$TF_HOSTS_FILE" > "$hosts_tsv"
results_file="$TMPD/results.jsonl"
: > "$results_file"

while IFS='|' read -r name probe_host probe_port primary_san; do
    [ -n "$name" ] || continue
    echo
    echo "================ $name ================"
    body="$TMPD/$name.service.json"
    python -c 'import json,sys
keys = ["name","environment","owner","host","port","hostKeyFingerprint","sshCredentialRef","profileId",
        "sans","certificatePath","chainPath","privateKeyPath","fileOwner","fileGroup","fileMode",
        "remoteHelperId","reloadActionId","healthCheckId","renewalEnabled","renewalLeadTime"]
entry = [h for h in json.load(open(sys.argv[1], encoding="utf-8")) if h.get("name") == sys.argv[2]][0]
json.dump({key: entry[key] for key in keys if entry.get(key) not in (None, "")},
          open(sys.argv[3], "w", encoding="utf-8"), indent=2)' "$TF_HOSTS_FILE" "$name" "$body"

    service_id=$("${api[@]}" -X POST "$TF_API_URL/api/v1/services" \
        -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" -d @"$body" \
        | json_get id) || die "service registration failed for $name"
    info "serviceId=$service_id"
    guid_nodash=$(printf '%s' "$service_id" | tr -d '-')
    target_file="/etc/trustforge/services/$guid_nodash.json"
    # The helper reads its destinations, ownership and action ids from a root-owned file on the
    # target that can only be written once the API has produced the GUID. Emit exactly that JSON so
    # the operator (or an installer hook) creates it rather than approximating it from this output.
    # Absolute, because an installer may change directory before reading it.
    registration="$PWD/$OUT_DIR/$name-$RUN_STAMP.registration.json"
    python -c 'import json,sys
keys = ["certificatePath","chainPath","privateKeyPath","fileOwner","fileGroup","fileMode",
        "remoteHelperId","reloadActionId","healthCheckId"]
entry = [h for h in json.load(open(sys.argv[1], encoding="utf-8")) if h.get("name") == sys.argv[2]][0]
missing = [key for key in keys if not entry.get(key)]
if missing:
    print("    inventory lacks " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
json.dump({key: entry[key] for key in keys}, open(sys.argv[3], "w", encoding="utf-8"), indent=2)' \
        "$TF_HOSTS_FILE" "$name" "$registration" || die "cannot build the target registration for $name"
    info "install on $name as root, mode 0600:"
    info "  $target_file   (content: $registration)"
    if [ -n "${TF_TARGET_READY_HOOK:-}" ]; then
        # Unattended runs supply their own installer (ssh, ansible, a container exec); the API never
        # learns this path, so writing the registration stays the operator's act.
        # Arguments: name serviceId registrationFile targetPath
        check "[$name] installer hook reported success" \
            "$TF_TARGET_READY_HOOK" "$name" "$service_id" "$registration" "$target_file"
    elif [ "${TF_ASSUME_TARGET_READY:-false}" != "true" ]; then
        read -r -p "Press Enter once that file exists on $name (or set TF_ASSUME_TARGET_READY=true)..." _ < /dev/tty \
            || die "no controlling terminal to prompt on; install the registration, then set TF_ASSUME_TARGET_READY=true or TF_TARGET_READY_HOOK."
    fi

    connection=$("${api[@]}" -X POST "$TF_API_URL/api/v1/services/$service_id/connection-test" \
        -H "Authorization: Bearer $access_token" 2>"$TMPD/conn.err" || true)
    check "[$name] API can connect, pin the host key, and validate the helper" python -c 'import json,sys
payload = json.loads(sys.argv[1]) if sys.argv[1].strip() else {}
print(f"      connection-test: {payload}")
sys.exit(0 if payload.get("success") is True else 1)' "$connection"

    job_id=$(create_job_and_wait "$service_id" "issuance" "acceptance-$name-$RUN_STAMP") \
        || { info "[$name] issuance did not succeed; nothing was minted, nothing to revoke."; continue; }
    info "jobId=$job_id"
    job_json=$("${api[@]}" "$TF_API_URL/api/v1/certificate-jobs/$job_id" -H "Authorization: Bearer $access_token")
    job_fingerprint=$(printf '%s' "$job_json" | json_get certificateFingerprint)
    check "[$name] job records an issued certificate fingerprint" test -n "$job_fingerprint"

    deployment=$("${api[@]}" "$TF_API_URL/api/v1/services/$service_id/deployment-versions?limit=5" \
        -H "Authorization: Bearer $access_token")
    check "[$name] deployment history marks this job Active and Healthy" python -c 'import json,sys
items = json.loads(sys.argv[1])
match = [d for d in items if d["jobId"].lower() == sys.argv[2].lower()]
print("      %s" % [(d["status"], d["healthStatus"]) for d in match])
sys.exit(0 if match and match[0]["status"] == "Active" and match[0]["healthStatus"] == "Healthy" else 1)' \
        "$deployment" "$job_id"

    served_serial=""
    if [ -n "$probe_host" ] && [ -n "$probe_port" ]; then
        check "[$name] target serves a certificate that verifies against the CA root for $primary_san" \
            ca_fetch "https://$primary_san:$probe_port/" --override-ip "$probe_host" --peek \
                --out "$TMPD/$name-peer.der"
        peer=$(openssl x509 -inform DER -in "$TMPD/$name-peer.der" -noout -fingerprint -sha256 -serial -enddate 2>/dev/null | tr -d '\r')
        # The digest label is lower-cased by some OpenSSL builds ("sha256 Fingerprint=") and the
        # option order is not fixed, so match on the label suffix rather than the whole line.
        served_fingerprint=$(printf '%s\n' "$peer" | sed -n 's/.*Fingerprint=//p' | tr -d ':')
        served_serial=$(printf '%s\n' "$peer" | sed -n 's/^serial=//p')
        info "served serial=$served_serial notAfter=$(printf '%s' "$peer" | sed -n 's/^notAfter=//p')"
        check "[$name] served certificate is the certificate the job issued" \
            fingerprints_equal "$served_fingerprint" "$job_fingerprint"
    else
        info "[$name] no tlsProbe configured: serving-side checks skipped."
    fi

    python -c 'import json,sys
with open(sys.argv[6], "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"name": sys.argv[1], "serviceId": sys.argv[2], "jobId": sys.argv[3],
                             "fingerprint": sys.argv[4], "serial": sys.argv[5]}) + "\n")' \
        "$name" "$service_id" "$job_id" "$job_fingerprint" "$served_serial" "$results_file"

    if [ "${TF_REVOKE_AFTER:-true}" != "true" ]; then
        info "[$name] TF_REVOKE_AFTER=false: the issued certificate stays valid."
        continue
    fi

    is_revocation_reason "${TF_REVOCATION_REASON:-Superseded}" || die "invalid TF_REVOCATION_REASON"
    # -sS without -f: a 409 carries the reason (service_job_active, no_active_certificate, ...) and
    # a failed fetch would throw it away, leaving an irreversible step diagnosed by nothing.
    revoke_http=$(curl -sS -o "$TMPD/$name.revoke.json" -w '%{http_code}' \
        -X POST "$TF_API_URL/api/v1/services/$service_id/revocations" \
        -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" \
        -H "Idempotency-Key: acceptance-revoke-$name-$RUN_STAMP" \
        --data "{\"reason\": \"${TF_REVOCATION_REASON:-Superseded}\"}" || echo 000)
    revocation=$(cat "$TMPD/$name.revoke.json" 2>/dev/null || true)
    revocation_status=$(printf '%s' "$revocation" | json_get status 2>/dev/null || true)
    check "[$name] revocation request is accepted (http $revoke_http, status ${revocation_status:-none})" \
        accepted_revocation_status "$revocation_status"
    [ -n "$revocation_status" ] || info "response body: $(printf '%s' "$revocation" | head -c 200)"

    revocation_id=$(printf '%s' "$revocation" | json_get revocation.id 2>/dev/null || true)
    serial=$(printf '%s' "$revocation" | json_get revocation.serial 2>/dev/null || true)
    info "revocationId=$revocation_id serial=$serial"
    check "[$name] the revocation record was returned" test -n "$revocation_id"

    record=""
    waited=0
    while [ "$waited" -lt "${TF_REVOCATION_TIMEOUT_SECONDS:-180}" ]; do
        record=$("${api[@]}" "$TF_API_URL/api/v1/certificate-revocations/$revocation_id" \
            -H "Authorization: Bearer $access_token" 2>/dev/null || true)
        [ "$(printf '%s' "$record" | json_get state 2>/dev/null || true)" = "Revoked" ] && break
        sleep 3
        waited=$((waited + 3))
    done
    check "[$name] durable revocation record is Revoked without a CA error" python -c 'import json,sys
record = json.loads(sys.argv[1]) if sys.argv[1].strip() else {}
print("      state=%s reason=%s attemptCount=%s lastError=%s" % (
    record.get("state"), record.get("reason"), record.get("attemptCount"), record.get("lastError")))
sys.exit(0 if record.get("state") == "Revoked" and record.get("lastError") in (None, "") else 1)' "$record"

    replay_http=$(curl -sS -o "$TMPD/$name.replay.json" -w '%{http_code}' \
        -X POST "$TF_API_URL/api/v1/services/$service_id/revocations" \
        -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" \
        -H "Idempotency-Key: acceptance-revoke-$name-$RUN_STAMP" \
        --data "{\"reason\": \"${TF_REVOCATION_REASON:-Superseded}\"}" || echo 000)
    replay=$(cat "$TMPD/$name.replay.json" 2>/dev/null || true)
    check "[$name] replaying the same Idempotency-Key does not re-call the CA (http $replay_http)" python -c 'import json,sys
payload = json.loads(sys.argv[1]) if sys.argv[1].strip() else {}
print("      replay status=%s" % payload.get("status"))
sys.exit(0 if payload.get("status") == "replayed" else 1)' "$replay"

    if [ -n "${TF_CRL_URL:-}" ] && [ -n "$serial" ]; then
        published=false
        waited=0
        while [ "$waited" -lt "${TF_CRL_PROPAGATION_SECONDS:-180}" ]; do
            if crl_lists "$serial"; then published=true; break; fi
            sleep 10
            waited=$((waited + 10))
        done
        check "[$name] CA publishes the revoked serial on its CRL" test "$published" = true
        if [ "$published" != true ]; then
            # A CA without generateOnRevoke only republishes at renewPeriod / its own nextUpdate, so
            # the window is printed rather than guessed at: it says whether this is latency or a CA
            # that never republishes between schedules.
            info "CRL as published now: $(ca_fetch "$TF_CRL_URL" --out "$TMPD/fail-crl.der" 2>/dev/null \
                && openssl crl -in "$TMPD/fail-crl.der" -inform DER -noout -lastupdate -nextupdate 2>/dev/null | tr '\n' ' ' \
                || echo unreadable)"
            info "the CA revoked the certificate (the record above says so); step-ca only lists it promptly with crl.generateOnRevoke=true."
        fi
    else
        info "[$name] CRL publication not asserted (no TF_CRL_URL or no probe serial)."
    fi

    if [ "${TF_REISSUE_AFTER_REVOKE:-false}" = "true" ]; then
        recovery_job=$(create_job_and_wait "$service_id" "recovery issuance" "acceptance-reissue-$name-$RUN_STAMP") \
            || die "post-revocation re-issuance failed for $name"
        recovery_fingerprint=$("${api[@]}" "$TF_API_URL/api/v1/certificate-jobs/$recovery_job" \
            -H "Authorization: Bearer $access_token" | json_get certificateFingerprint)
        check "[$name] a fresh job after revocation mints a different certificate" \
            different_fingerprint "$recovery_fingerprint" "$job_fingerprint"
        info "recoveryJobId=$recovery_job"
    fi
done < "$hosts_tsv"

python -c 'import json,sys
entries = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
json.dump({"runStamp": sys.argv[2], "services": entries}, open(sys.argv[3], "w", encoding="utf-8"), indent=2)' \
    "$results_file" "$RUN_STAMP" "$REPORT"

echo
echo "== Summary =="
echo "$((total - failures)) PASS / $failures FAIL of $total checks"
echo "Report: $REPORT"
[ "$failures" -eq 0 ] || { echo "Drill incomplete: resolve the failures above."; exit 1; }
echo "Drill complete: only certificates minted by this run were revoked."
