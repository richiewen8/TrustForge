#!/usr/bin/env bash
# Configures Technitium DNS challenge zone, least-privilege ACME API token,
# ACME account key, and TrustForge certificate worker settings in /etc/trustforge/trustforge.env.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

ENV_FILE=/etc/trustforge/trustforge.env
SECRETS_DIR=/etc/trustforge/secrets
DNS_UI_URL="http://127.0.0.1:5380"
ZONE=""
ACCOUNT_EMAIL=""
DIRECTORY_URL=""
ROOT_CERT="$SECRETS_DIR/root_ca.crt"
DNS_USER="trustforge-acme"
DNS_ADMIN_PASSWORD_FILE="$SECRETS_DIR/dns-admin-password"
SCAN_INTERVAL="00:05:00"
MIN_RENEWAL_INTERVAL="01:00:00"
RECORDS=()
NO_RESTART=0

usage() {
    cat <<'EOF'
Usage: setup-acme-dns.sh --zone ZONE [OPTION]...

Automates Technitium DNS-01 preparation and enables the TrustForge certificate worker:
  1. Creates the Primary DNS zone (if missing) and optional initial A records
  2. Creates a least-privilege Technitium user with View/Modify/Delete on that zone only
  3. Mints a non-expiring Technitium API token into /etc/trustforge/secrets/dns-api-token
  4. Generates an EC P-256 PKCS#8 ACME account key at /etc/trustforge/secrets/acme-account.pem
  5. Writes CertificateJobs__Worker__Enabled=true, SmallstepAcme__*, TechnitiumDns__* into trustforge.env

Options:
  --zone ZONE                    DNS challenge zone (required, e.g. trustforge.internal)
  --account-email EMAIL          ACME account contact email (default: ops@<zone>)
  --directory-url URL            step-ca ACME directory URL (reads trustforge.env if already set)
  --root-cert PATH               CA root PEM path (default: /etc/trustforge/secrets/root_ca.crt)
  --record FQDN=IP               Add/overwrite an A record in ZONE (repeatable)
  --dns-admin-password-file FILE File holding Technitium admin password (default: /etc/trustforge/secrets/dns-admin-password)
  --scan-interval SPAN           Renewal scan interval (default: 00:05:00)
  --min-renewal-interval SPAN    Minimum renewal interval (default: 01:00:00)
  --no-restart                   Do not restart trustforge after updating trustforge.env
  -h, --help                     Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --zone) ZONE=${2:?--zone needs a domain}; shift 2 ;;
        --account-email) ACCOUNT_EMAIL=${2:?--account-email needs an email}; shift 2 ;;
        --directory-url) DIRECTORY_URL=${2:?--directory-url needs a URL}; shift 2 ;;
        --root-cert) ROOT_CERT=${2:?--root-cert needs a path}; shift 2 ;;
        --record) RECORDS+=("${2:?--record needs FQDN=IP}"); shift 2 ;;
        --dns-admin-password-file) DNS_ADMIN_PASSWORD_FILE=${2:?--dns-admin-password-file needs a path}; shift 2 ;;
        --scan-interval) SCAN_INTERVAL=${2:?--scan-interval needs a TimeSpan}; shift 2 ;;
        --min-renewal-interval) MIN_RENEWAL_INTERVAL=${2:?--min-renewal-interval needs a TimeSpan}; shift 2 ;;
        --no-restart) NO_RESTART=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; tf_die "unknown option: $1" ;;
    esac
done

tech_call() {
    local path=$1
    shift
    local resp status
    resp=$(curl -fsS -G "${DNS_UI_URL}${path}" "$@")
    status=$(printf '%s' "$resp" | tf_json_get status)
    if [[ $status != "ok" ]]; then
        printf 'Technitium API %s failed: %s\n' "$path" "$resp" >&2
        return 1
    fi
    printf '%s' "$resp"
}

main() {
    tf_require_root
    [[ -n $ZONE ]] || tf_die "--zone is required"
    [[ -f $ENV_FILE ]] || tf_die "$ENV_FILE not found; run install.sh first"
    [[ -r $DNS_ADMIN_PASSWORD_FILE ]] || tf_die "DNS admin password file unreadable: $DNS_ADMIN_PASSWORD_FILE"

    if [[ -z $ACCOUNT_EMAIL ]]; then
        ACCOUNT_EMAIL="ops@${ZONE}"
    fi
    if [[ -z $DIRECTORY_URL ]]; then
        DIRECTORY_URL=$(tf_env_get "$ENV_FILE" "SmallstepAcme__DirectoryUrl" || true)
    fi
    [[ -n $DIRECTORY_URL ]] || tf_die "SmallstepAcme__DirectoryUrl is not set; run setup-step-ca.sh first or pass --directory-url"
    [[ -r $ROOT_CERT ]] || tf_die "CA root certificate not found at $ROOT_CERT; run setup-step-ca.sh first or pass --root-cert"

    tf_wait_for "Technitium DNS console" 30 curl -fsS --max-time 3 "${DNS_UI_URL}/api/user/login" >/dev/null 2>&1 || true

    local admin_pass admin_token
    admin_pass=$(tr -d '\r\n' <"$DNS_ADMIN_PASSWORD_FILE")
    admin_token=$(curl -fsS -G "${DNS_UI_URL}/api/user/login" \
        --data-urlencode "user=admin" --data-urlencode "pass=$admin_pass" | tf_json_get token)
    [[ -n $admin_token ]] || tf_die "failed to authenticate against Technitium DNS at $DNS_UI_URL"
    tf_ok "authenticated with Technitium DNS API"

    # Create primary zone if absent
    local existing_zones
    existing_zones=$(tech_call "/api/zones/list" -H "Authorization: Bearer $admin_token" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print("\n".join(z["name"] for z in data.get("response", {}).get("zones", [])))
')
    if grep -Fxq "$ZONE" <<<"$existing_zones"; then
        tf_ok "DNS zone $ZONE already exists"
    else
        tech_call "/api/zones/create" -H "Authorization: Bearer $admin_token" \
            --data-urlencode "zone=$ZONE" --data-urlencode "type=Primary" >/dev/null
        tf_ok "created Primary DNS zone: $ZONE"
    fi

    # Create or rotate least-privilege ACME DNS user and token
    local acme_dns_pass_file="$SECRETS_DIR/dns-acme-password"
    local acme_dns_pass
    if [[ -s $acme_dns_pass_file ]]; then
        acme_dns_pass=$(tr -d '\r\n' <"$acme_dns_pass_file")
    else
        acme_dns_pass=$(openssl rand -hex 20)
        (umask 077; printf '%s\n' "$acme_dns_pass" >"$acme_dns_pass_file")
        chown root:trustforge "$acme_dns_pass_file"
        chmod 0640 "$acme_dns_pass_file"
    fi

    local user_exists
    user_exists=$(tech_call "/api/admin/users/list" -H "Authorization: Bearer $admin_token" | python3 -c '
import json, sys
target = sys.argv[1]
users = json.load(sys.stdin).get("response", {}).get("users", [])
print("yes" if any(u.get("username") == target for u in users) else "no")
' "$DNS_USER")
    if [[ $user_exists == "no" ]]; then
        tech_call "/api/admin/users/create" -H "Authorization: Bearer $admin_token" \
            --data-urlencode "user=$DNS_USER" --data-urlencode "pass=$acme_dns_pass" >/dev/null
        tf_ok "created least-privilege Technitium user: $DNS_USER"
    else
        tech_call "/api/admin/users/set" -H "Authorization: Bearer $admin_token" \
            --data-urlencode "user=$DNS_USER" --data-urlencode "newPass=$acme_dns_pass" >/dev/null
        tf_ok "reused Technitium user: $DNS_USER"
    fi

    tech_call "/api/zones/permissions/set" -H "Authorization: Bearer $admin_token" \
        --data-urlencode "zone=$ZONE" \
        --data-urlencode "userPermissions=${DNS_USER}|true|true|true" >/dev/null
    tf_ok "granted View/Modify/Delete on $ZONE exclusively to $DNS_USER"

    local dns_token_file="$SECRETS_DIR/dns-api-token"
    local dns_token
    dns_token=$(tech_call "/api/user/createToken" \
        --data-urlencode "user=$DNS_USER" \
        --data-urlencode "pass=$acme_dns_pass" \
        --data-urlencode "tokenName=trustforge-acme" | tf_json_get token)
    (umask 077; printf '%s' "$dns_token" >"$dns_token_file")
    chown root:trustforge "$dns_token_file"
    chmod 0640 "$dns_token_file"
    tf_ok "wrote least-privilege DNS API token to $dns_token_file"

    # Optional initial A records
    local rec fqdn ip
    for rec in "${RECORDS[@]}"; do
        [[ $rec == *=* ]] || tf_die "invalid --record '$rec' (expected FQDN=IP)"
        fqdn=${rec%%=*}
        ip=${rec#*=}
        tech_call "/api/zones/records/add" -H "Authorization: Bearer $dns_token" \
            --data-urlencode "domain=$fqdn" \
            --data-urlencode "zone=$ZONE" \
            --data-urlencode "type=A" \
            --data-urlencode "ipAddress=$ip" \
            --data-urlencode "overwrite=true" >/dev/null
        tf_ok "DNS A record set: $fqdn -> $ip"
    done

    # Generate EC P-256 PKCS#8 ACME account key if absent
    local acme_key="$SECRETS_DIR/acme-account.pem"
    if [[ ! -s $acme_key ]]; then
        (
            umask 077
            openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$acme_key"
        )
        chown root:trustforge "$acme_key"
        chmod 0640 "$acme_key"
        tf_ok "generated EC P-256 PKCS#8 ACME account key at $acme_key"
    else
        chown root:trustforge "$acme_key"
        chmod 0640 "$acme_key"
        tf_ok "reusing existing ACME account key at $acme_key"
    fi

    # Update trustforge.env
    tf_env_set "$ENV_FILE" "CertificateJobs__Worker__Enabled" "true"
    tf_env_set "$ENV_FILE" "CertificateJobs__Revocation__Enabled" "true"
    tf_env_set "$ENV_FILE" "CertificateJobs__Renewal__ScanInterval" "$SCAN_INTERVAL"
    tf_env_set "$ENV_FILE" "CertificateJobs__Renewal__MinimumRenewalInterval" "$MIN_RENEWAL_INTERVAL"
    tf_env_set "$ENV_FILE" "SmallstepAcme__DirectoryUrl" "$DIRECTORY_URL"
    tf_env_set "$ENV_FILE" "SmallstepAcme__AccountEmail" "$ACCOUNT_EMAIL"
    tf_env_set "$ENV_FILE" "SmallstepAcme__AccountKeySecretRef" "secret://file//${acme_key}"
    tf_env_set "$ENV_FILE" "SmallstepAcme__RootCertificatePath" "$ROOT_CERT"
    tf_env_set "$ENV_FILE" "TechnitiumDns__BaseUrl" "$DNS_UI_URL"
    tf_env_set "$ENV_FILE" "TechnitiumDns__ApiTokenSecretRef" "secret://file//${dns_token_file}"
    tf_env_set "$ENV_FILE" "TechnitiumDns__AllowedZones__0" "$ZONE"
    tf_env_set "$ENV_FILE" "TechnitiumDns__ResolverAddress" "127.0.0.1"
    tf_env_set "$ENV_FILE" "TechnitiumDns__ResolverPort" "53"
    tf_ok "updated $ENV_FILE with ACME + Technitium DNS-01 configuration"

    if [[ $NO_RESTART -eq 0 ]]; then
        systemctl restart trustforge
        tf_wait_for "TrustForge API readiness" 40 curl -fsS --max-time 5 "http://127.0.0.1:5000/health/ready" ||
            { journalctl -u trustforge -n 40 --no-pager >&2 || true; tf_die "TrustForge failed to become ready"; }
        tf_ok "TrustForge restarted and ready with certificate worker enabled"
    fi
}

main
