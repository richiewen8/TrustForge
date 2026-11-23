#!/usr/bin/env bash
# Read-only preflight for a real CA / real target acceptance drill.
#
# Proves every external input drill.sh depends on before an ACME order exists: the CA
# directory over TLS verified by the root certificate, the CRL endpoint, the ACME account
# key, the control-plane API and OIDC roles, the Technitium token and challenge zone, and
# each target's reachability and pinned host key. Nothing here writes to the CA, the DNS
# server, a target, or the database -- and no check relaxes TLS verification.
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE="${ACCEPTANCE_ENV:-acceptance.env}"
if [ ! -f "$ENV_FILE" ]; then
    echo "Missing $ENV_FILE. Copy acceptance.env.example and fill in the real values." >&2
    exit 1
fi
set -a; . "$ENV_FILE"; set +a

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

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
            echo "      $(printf '%s\n' "$output" | tail -n 1)"
        fi
        failures=$((failures + 1))
    fi
}

info() { echo "      $*"; }

# Informational probe: reported, but never a preflight failure. A target legitimately has no
# usable TLS listener before its first issuance, and the drill asserts the handshake itself.
# The command's own output is shown, so write it to stdout rather than stderr.
probe() {
    local description="$1"
    shift
    local output=""
    local rc=0
    output=$("$@" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "NOTE: $description -- already serving"
    else
        echo "NOTE: $description -- not serving yet (expected before the first issuance)"
    fi
    if [ -n "$output" ]; then
        printf '      %s\n' "$output"
    fi
}

json_get() {
    python -c 'import json,sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(value if not isinstance(value, (dict, list)) else json.dumps(value))' "$1"
}

no_placeholders() {
    local file
    for file in "$@"; do
        if grep -qE 'REPLACE_WITH|replace-with|CHANGEME' "$file"; then
            grep -nE 'REPLACE_WITH|replace-with|CHANGEME' "$file" | sed 's/^/    /'
            return 1
        fi
    done
}

[ -f "${TF_HOSTS_FILE:-}" ] || { echo "Missing TF_HOSTS_FILE=${TF_HOSTS_FILE:-}." >&2; exit 1; }

echo "== Configuration =="
for var in TF_API_URL TF_OIDC_TOKEN_URL TF_OIDC_CLIENT_ID TF_OIDC_AUDIENCE TF_OPERATOR_USERNAME \
           TF_ACME_DIRECTORY_URL TF_ACME_ROOT_CA_FILE TF_ACME_ACCOUNT_KEY_FILE \
           TF_TECHNITIUM_URL TF_TECHNITIUM_TOKEN_FILE TF_DNS_ALLOWED_ZONE TF_DNS_RESOLVER TF_HOSTS_FILE; do
    check "$var is set" test -n "${!var:-}"
done
check "no placeholder values left in $ENV_FILE or ${TF_HOSTS_FILE}" \
    no_placeholders "$ENV_FILE" "$TF_HOSTS_FILE"
check "hosts file is a non-empty JSON array" python -c 'import json,sys
hosts = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if isinstance(hosts, list) and hosts else 1)' "$TF_HOSTS_FILE"

REQUIRED_KEYS='["name","environment","owner","host","port","hostKeyFingerprint","sshCredentialRef","profileId","sans","certificatePath","chainPath","privateKeyPath","fileOwner","fileGroup","fileMode","remoteHelperId","reloadActionId","healthCheckId"]'
check "every host entry carries the fields POST /api/v1/services requires" python -c 'import json,sys
required = json.loads(sys.argv[2])
missing = [(h.get("name"), key) for h in json.load(open(sys.argv[1], encoding="utf-8")) for key in required if not h.get(key)]
for name, key in missing:
    print(f"    {name}: missing {key}")
sys.exit(1 if missing else 0)' "$TF_HOSTS_FILE" "$REQUIRED_KEYS"
check "no host is renewal-enabled (the drill must leave no background renewals)" python -c 'import json,sys
on = [h.get("name") for h in json.load(open(sys.argv[1], encoding="utf-8")) if h.get("renewalEnabled")]
print("    renewal-enabled: " + ", ".join(on) if on else "")
sys.exit(1 if on else 0)' "$TF_HOSTS_FILE"
check "every host uses the supported helper id" python -c 'import json,sys
bad = [h.get("name") for h in json.load(open(sys.argv[1], encoding="utf-8")) if h.get("remoteHelperId") != "trustforge-certctl-v1"]
print("    unsupported: " + ", ".join(bad) if bad else "")
sys.exit(1 if bad else 0)' "$TF_HOSTS_FILE"

ca_fetch() {
    if [ -n "${TF_CA_RESOLVE_IP:-}" ]; then
        python tlsfetch.py "$@" --override-ip "$TF_CA_RESOLVE_IP" --cacert "$TF_ACME_ROOT_CA_FILE"
    else
        python tlsfetch.py "$@" --cacert "$TF_ACME_ROOT_CA_FILE"
    fi
}

is_p256_key() { openssl pkey -in "$1" -text -noout 2>/dev/null | head -n 1 | grep -q "256 bit"; }

is_sha256_fingerprint() { printf '%s' "$1" | grep -qE '^SHA256:[A-Za-z0-9+/]{43}$'; }

tls_probe_verifies() {
    local address="$1" port="$2" server_name="$3" der="$4"
    if ! python tlsfetch.py "https://$server_name:$port/" --override-ip "$address" \
            --cacert "$TF_ACME_ROOT_CA_FILE" --peek --out "$der" 2>"$TMPD/tls-$server_name.err"; then
        echo "no verified handshake for $server_name at $address:$port: $(tail -n 1 "$TMPD/tls-$server_name.err")"
        return 1
    fi
    openssl x509 -inform DER -in "$der" -noout -subject -serial -enddate | sed 's/^/    /'
}

host_key_matches() {
    local address="$1" port="$2" expected="$3" capture="$4" observed
    if ! ssh-keyscan -t ed25519 -p "$port" -T 10 "$address" > "$capture" 2>/dev/null || [ ! -s "$capture" ]; then
        echo "ssh-keyscan returned no ed25519 host key from $address:$port"
        return 1
    fi
    observed=$(ssh-keygen -lf "$capture" | cut -d' ' -f2)
    if [ "$observed" != "$expected" ]; then
        echo "observed $observed, inventory says $expected"
        return 1
    fi
    echo "observed $observed"
}

crl_next_update_future() {
    python -c 'import re,subprocess,sys,datetime
text = subprocess.run(["openssl","crl","-in",sys.argv[1],"-noout","-text"],capture_output=True,text=True).stdout
match = re.search(r"Next Update: (.*)", text)
if not match:
    print("    the CRL carries no nextUpdate")
    sys.exit(1)
next_update = datetime.datetime.strptime(match.group(1).strip(), "%b %d %H:%M:%S %Y %Z")
print(f"    nextUpdate {next_update:%Y-%m-%d %H:%M} UTC")
sys.exit(0 if next_update > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) else 1)' "$1"
}

echo
echo "== Certificate authority =="
check "root certificate file exists" test -f "$TF_ACME_ROOT_CA_FILE"
check "root certificate parses as X.509" openssl x509 -in "$TF_ACME_ROOT_CA_FILE" -noout -subject
if openssl x509 -in "$TF_ACME_ROOT_CA_FILE" -noout -text > "$TMPD/root.txt" 2>/dev/null; then
    check "root certificate is a CA certificate" grep -q "CA:TRUE" "$TMPD/root.txt"
    check "root certificate is currently valid" python -c 'import re,subprocess,sys,datetime
text = subprocess.run(["openssl","x509","-in",sys.argv[1],"-noout","-dates"],capture_output=True,text=True).stdout
fmt = "%b %d %H:%M:%S %Y %Z"
not_before = datetime.datetime.strptime(re.search(r"notBefore=(.*)", text).group(1).strip(), fmt)
not_after = datetime.datetime.strptime(re.search(r"notAfter=(.*)", text).group(1).strip(), fmt)
now = datetime.datetime.utcnow()
print(f"    root valid {not_before:%Y-%m-%d} .. {not_after:%Y-%m-%d}")
sys.exit(0 if not_before <= now <= not_after else 1)' "$TF_ACME_ROOT_CA_FILE"
    info "subject: $(openssl x509 -in "$TF_ACME_ROOT_CA_FILE" -noout -subject | sed 's/^subject=//')"
fi

directory_json=""
if ca_fetch "$TF_ACME_DIRECTORY_URL" > "$TMPD/dir.json" 2>"$TMPD/dir.err"; then
    echo "PASS: ACME directory loads with TLS verified against the root certificate"
    printf '      %s\n' "$(python -c 'import json,sys
print(" ".join(sorted(json.load(open(sys.argv[1], encoding="utf-8")))))' "$TMPD/dir.json")"
else
    echo "FAIL: ACME directory loads with TLS verified against the root certificate"
    info "$(tail -n 1 "$TMPD/dir.err")"
    failures=$((failures + 1))
    printf 'null' > "$TMPD/dir.json"
fi
total=$((total + 1))
for resource in newNonce newAccount newOrder revokeCert; do
    check "directory advertises $resource" python -c 'import json,sys
resources = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if isinstance(resources, dict) and sys.argv[2] in resources else 1)' "$TMPD/dir.json" "$resource"
done
nonce_url=$(json_get newNonce < "$TMPD/dir.json" 2>/dev/null || true)
check "newNonce issues a replay nonce" ca_fetch "$nonce_url" --method HEAD --require-header Replay-Nonce

check "ACME account key parses as a private key" openssl pkey -in "$TF_ACME_ACCOUNT_KEY_FILE" -noout
check "ACME account key is EC P-256 (target keys must never be reused)" is_p256_key "$TF_ACME_ACCOUNT_KEY_FILE"

if [ -n "${TF_CRL_URL:-}" ]; then
    if ca_fetch "$TF_CRL_URL" --out "$TMPD/crl.der" 2>"$TMPD/crl.err" \
        && openssl crl -in "$TMPD/crl.der" -inform DER -out "$TMPD/crl.pem" -outform PEM 2>/dev/null; then
        echo "PASS: CRL endpoint returns a decodable CRL over TLS verified against the root certificate"
        openssl crl -in "$TMPD/crl.pem" -noout -lastupdate -nextupdate | sed 's/^/      /'
        info "revoked serials currently published: $(openssl crl -in "$TMPD/crl.pem" -noout -text | grep -c "Serial Number:" || true)"
        total=$((total + 1))
        if crl_next_update_future "$TMPD/crl.pem"; then
            echo "PASS: CRL nextUpdate is in the future (the CA is still publishing)"
        else
            echo "FAIL: CRL nextUpdate is in the future (the CA is still publishing)"
            failures=$((failures + 1))
        fi
    else
        echo "FAIL: CRL endpoint returns a decodable CRL over TLS verified against the root certificate"
        info "$(tail -n 1 "$TMPD/crl.err")"
        info "step-ca only serves /1.0/crl when its provisioner JSON enables the crl block."
        failures=$((failures + 2))
        total=$((total + 1))
    fi
else
    info "TF_CRL_URL is empty: revocation will still succeed, but the drill cannot confirm CRL publication."
fi

echo
echo "== Control plane =="
check "API reports ready" curl -fsS "$TF_API_URL/health/ready" -o "$TMPD/ready"
access_token=""
if access_token=$(curl -fsS -X POST "$TF_OIDC_TOKEN_URL" \
        -d grant_type=password -d client_id="$TF_OIDC_CLIENT_ID" \
        --data-urlencode "username=${TF_OPERATOR_USERNAME:-}" --data-urlencode "password=${TF_OPERATOR_PASSWORD:-}" \
        | json_get access_token 2>/dev/null); then
    echo "PASS: operator can obtain an access token from the real issuer"
else
    echo "FAIL: operator can obtain an access token from the real issuer"
    failures=$((failures + 1))
    access_token=""
fi
if [ -n "$access_token" ]; then
    check "token audience is the configured API audience" python -c 'import base64,json,sys
part = sys.argv[1].split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
aud = claims.get("aud")
aud = aud if isinstance(aud, list) else [aud]
print("    aud=" + ",".join(str(item) for item in aud))
sys.exit(0 if sys.argv[2] in aud else 1)' "$access_token" "$TF_OIDC_AUDIENCE"
    check "token carries PlatformAdmin (the only role permitted to revoke)" python -c 'import base64,json,sys
part = sys.argv[1].split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
roles = set(claims.get("role") or []) | set(claims.get("realm_access", {}).get("roles") or [])
print("    roles=" + ",".join(sorted(roles)))
sys.exit(0 if "PlatformAdmin" in roles else 1)' "$access_token"
fi

echo
echo "== Technitium DNS =="
check "API token file exists and is not empty" test -s "$TF_TECHNITIUM_TOKEN_FILE"
dns_token=$(cat "$TF_TECHNITIUM_TOKEN_FILE" 2>/dev/null || true)
records_json=""
if records_json=$(curl -fsS -X POST "$TF_TECHNITIUM_URL/api/zones/records/get" \
        -H "Authorization: Bearer $dns_token" \
        --data-urlencode "domain=$TF_DNS_ALLOWED_ZONE" --data-urlencode "zone=$TF_DNS_ALLOWED_ZONE" \
        --data-urlencode "type=SOA" --data-urlencode "listZone=false" 2>"$TMPD/dns.err"); then
    echo "PASS: DNS token is accepted by the same records/get call the pipeline uses"
    total=$((total + 1))
    if printf '%s' "$records_json" | python -c 'import json,sys
sys.exit(0 if json.load(sys.stdin).get("status") == "ok" else 1)'; then
        echo "PASS: challenge zone is readable through the token's restricted permissions"
    else
        echo "FAIL: challenge zone is readable through the token's restricted permissions"
        info "$(printf '%s' "$records_json" | head -c 200)"
        failures=$((failures + 1))
    fi
else
    echo "FAIL: DNS token is accepted by the same records/get call the pipeline uses"
    info "$(tail -n 1 "$TMPD/dns.err")"
    info "a zone-less permission set returns 401/403 here; grant View/Modify/Delete on the challenge zone only."
    failures=$((failures + 2))
    total=$((total + 1))
fi
if [ "${TF_DNS_RESOLVER_PROBE:-dns}" = "skip" ]; then
    info "TF_DNS_RESOLVER_PROBE=skip: the resolver is reachable only from the API/CA network, so the SOA query is not run here."
else
    check "configured resolver is authoritative for the challenge zone (step-ca must see TXT records here)" \
        python dnsprobe.py "$TF_DNS_RESOLVER" "${TF_DNS_RESOLVER_PORT:-53}" "$TF_DNS_ALLOWED_ZONE" SOA
fi

echo
echo "== Targets =="
hosts_tsv="$TMPD/hosts.tsv"
python -c 'import json,sys
for h in json.load(open(sys.argv[1], encoding="utf-8")):
    probe = h.get("tlsProbe") or {}
    ssh = h.get("probeSsh") or {}
    print("|".join([
        h.get("name",""), ssh.get("host") or h.get("host",""), str(ssh.get("port") or h.get("port","")),
        h.get("hostKeyFingerprint",""), h.get("sshCredentialRef",""),
        ",".join(h.get("sans") or []), probe.get("host",""), str(probe.get("port",""))]))' \
    "$TF_HOSTS_FILE" > "$hosts_tsv"

while IFS='|' read -r name host port fingerprint credential_ref sans probe_host probe_port; do
    [ -n "$name" ] || continue
    echo "-- $name ($host:$port)"
    check "[$name] host key fingerprint is an OpenSSH SHA256 fingerprint" is_sha256_fingerprint "$fingerprint"
    for san in ${sans//,/ }; do
        check "[$name] SAN $san falls under the allowed zone $TF_DNS_ALLOWED_ZONE" python -c 'import sys
san, zone = sys.argv[1].lstrip("*.").lower(), sys.argv[2].lower().rstrip(".")
sys.exit(0 if san == zone or san.endswith("." + zone) else 1)' "$san" "$TF_DNS_ALLOWED_ZONE"
    done
    case "$credential_ref" in
        secret://file//*)
            secret_path="$TF_SECRETS_DIR/$(basename "$credential_ref")"
            check "[$name] SSH credential file is present for the secret reference" test -f "$secret_path"
            check "[$name] SSH credential JSON has username and privateKeyPem" python -c 'import json,sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if data.get("username") and data.get("privateKeyPem") else 1)' "$secret_path"
            ;;
        secret://env/*)
            info "SSH credential comes from ${credential_ref#secret://env/}; confirm it is set in the API container."
            ;;
        *)
            check "[$name] SSH credential reference uses secret://file// or secret://env/" false
            ;;
    esac
    check "[$name] SSH port accepts a TCP connection" python -c 'import socket,sys
try:
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=8):
        sys.exit(0)
except OSError as error:
    print(f"    {error}")
    sys.exit(1)' "$host" "$port"
    if command -v ssh-keyscan > /dev/null 2>&1; then
        check "[$name] presented host key matches the pinned fingerprint" \
            host_key_matches "$host" "$port" "$fingerprint" "$TMPD/keyscan-$name"
    else
        info "ssh-keyscan is unavailable: the pinned fingerprint is still enforced by the API at connect time."
    fi
    if [ -n "$probe_host" ] && [ -n "$probe_port" ]; then
        probe "[$name] TLS listener completes a handshake verified against the CA root" \
            tls_probe_verifies "$probe_host" "$probe_port" "$(printf '%s' "$sans" | cut -d, -f1)" "$TMPD/tls-$name.der"
    else
        info "[$name] no tlsProbe configured: deployment is verified through the API only."
    fi
done < "$hosts_tsv"

echo
echo "== Summary =="
echo "$((total - failures)) PASS / $failures FAIL of $total checks"
if [ "$failures" -gt 0 ]; then
    echo "Resolve every FAIL before running ./drill.sh; a real CA charges rate-limit budget per failed order."
    exit 1
fi
echo "Preflight clean. ./drill.sh may create real orders on this CA."
