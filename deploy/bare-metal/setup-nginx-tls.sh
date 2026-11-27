#!/usr/bin/env bash
# Configures Nginx HTTPS reverse proxy on the TrustForge host for TrustForge API (and optional
# local Keycloak OIDC), registers the service(s) in TrustForge with auto-renewal enabled,
# and triggers initial ACME DNS-01 certificate issuance.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

ENV_FILE=/etc/trustforge/trustforge.env
SECRETS_DIR=/etc/trustforge/secrets
STEP_PATH=/etc/step-ca
API_URL="http://127.0.0.1:5000"
API_DOMAIN=""
OIDC_DOMAIN=""
TARGET_HOST="127.0.0.1"
SSH_SECRET_FILE="$SECRETS_DIR/ssh-local.json"
RENEWAL_LEAD_TIME="0.08:00:00"
SKIP_ISSUE=0

usage() {
    cat <<'EOF'
Usage: setup-nginx-tls.sh --api-domain FQDN [OPTION]...

Configures Nginx as the HTTPS reverse proxy in front of TrustForge API (127.0.0.1:5000) and
optionally local Keycloak OIDC (127.0.0.1:8280), registers the TLS service in TrustForge
with automatic renewal enabled, and issues the first real ACME DNS-01 certificate.

Options:
  --api-domain FQDN            HTTPS domain for TrustForge API (e.g. api.trustforge.internal)
  --oidc-domain FQDN           Optional HTTPS domain for local Keycloak (proxies to 127.0.0.1:8280)
  --ssh-secret PATH            SSH credential JSON path (default: /etc/trustforge/secrets/ssh-local.json)
  --renewal-lead-time SPAN     .NET TimeSpan strictly less than CA cert lifetime (default: 0.08:00:00)
  --skip-issue                 Configure Nginx + bootstrap cert only; do not register/issue via API yet
  -h, --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --api-domain) API_DOMAIN=${2:?--api-domain needs a domain}; shift 2 ;;
        --oidc-domain) OIDC_DOMAIN=${2:?--oidc-domain needs a domain}; shift 2 ;;
        --ssh-secret) SSH_SECRET_FILE=${2:?--ssh-secret needs a path}; shift 2 ;;
        --renewal-lead-time) RENEWAL_LEAD_TIME=${2:?--renewal-lead-time needs a TimeSpan}; shift 2 ;;
        --skip-issue) SKIP_ISSUE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; tf_die "unknown option: $1" ;;
    esac
done

mint_bootstrap_cert() {
    local name=$1 domain=$2
    local base="/etc/nginx/trustforge/${name}"
    local boot="${base}/bootstrap"
    local current="${base}/current"

    if [[ -L $current && -s $current/chain.pem && -s $current/private-key.pem ]]; then
        tf_ok "existing TLS symlink $current preserved"
        return 0
    fi

    install -d -m 0755 -o root -g root "$base" "$boot"
    if [[ -f $STEP_PATH/certs/root_ca.crt ]] && command -v step >/dev/null 2>&1 && [[ -r $STEP_PATH/password.txt ]]; then
        local ca_port=9000
        if [[ -f $STEP_PATH/config/ca.json ]]; then
            ca_port=$(python3 -c 'import json,sys; addr=json.load(open(sys.argv[1])).get("address",":9000"); print(addr.split(":")[-1])' "$STEP_PATH/config/ca.json" || echo 9000)
        fi
        STEPPATH="$STEP_PATH" step ca certificate "$domain" \
            "$boot/chain.pem" "$boot/private-key.pem" \
            --ca-url "https://127.0.0.1:${ca_port}" \
            --root "$STEP_PATH/certs/root_ca.crt" \
            --provisioner "admin" \
            --provisioner-password-file "$STEP_PATH/password.txt" \
            --force >/dev/null
        cp "$boot/chain.pem" "$boot/certificate.pem"
    else
        openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
            -keyout "$boot/private-key.pem" -out "$boot/certificate.pem" \
            -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1
        cp "$boot/certificate.pem" "$boot/chain.pem"
    fi

    chown root:www-data "$boot/certificate.pem" "$boot/chain.pem" "$boot/private-key.pem"
    chmod 0644 "$boot/certificate.pem" "$boot/chain.pem"
    chmod 0640 "$boot/private-key.pem"
    ln -sfn "$boot" "$current"
    tf_ok "prepared bootstrap symlink $current -> $boot for $domain"
}

write_nginx_site() {
    local name=$1 domain=$2 upstream=$3
    cat >/etc/nginx/sites-available/trustforge-"${name}".conf <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};

    ssl_certificate     /etc/nginx/trustforge/${name}/current/chain.pem;
    ssl_certificate_key /etc/nginx/trustforge/${name}/current/private-key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass ${upstream};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
    }
}
EOF
    ln -sfn "/etc/nginx/sites-available/trustforge-${name}.conf" "/etc/nginx/sites-enabled/trustforge-${name}.conf"
}

register_health_action() {
    local action_id=$1 sni=$2
    python3 -c '
import json, sys
path = "/etc/trustforge/actions.json"
data = json.load(open(path, encoding="utf-8"))
data[sys.argv[1]] = ["/usr/local/libexec/trustforge/check-tls", "{service_id}", "443", sys.argv[2]]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$action_id" "$sni"
    chmod 0600 /etc/trustforge/actions.json
}

get_oidc_token() {
    local oidc_cred="$SECRETS_DIR/oidc-credentials.env"
    [[ -r $oidc_cred ]] || tf_die "OIDC credentials file $oidc_cred not found; obtain a token from your OIDC provider or run setup-oidc.sh"
    local auth_url dev_user dev_pass token_endpoint
    auth_url=$(tf_env_get "$ENV_FILE" "Authentication__Authority")
    dev_user=$(tf_env_get "$oidc_cred" "TF_OIDC_DEV_USERNAME")
    dev_pass=$(tf_env_get "$oidc_cred" "TF_OIDC_DEV_PASSWORD")

    tf_wait_for "OIDC discovery at $auth_url" 30 curl -fsS --max-time 5 "${auth_url}/.well-known/openid-configuration" ||
        tf_die "OIDC discovery unreachable at ${auth_url}/.well-known/openid-configuration"
    token_endpoint=$(curl -fsS --max-time 10 "${auth_url}/.well-known/openid-configuration" | tf_json_get token_endpoint)
    curl -fsS -X POST "$token_endpoint" \
        -d grant_type=password -d client_id=trustforge-cli \
        --data-urlencode "username=$dev_user" --data-urlencode "password=$dev_pass" | tf_json_get access_token
}

register_and_issue() {
    local name=$1 domain=$2 health_id=$3 access_token=$4 fingerprint=$5
    local cert_path="/etc/nginx/trustforge/${name}/current/certificate.pem"
    local chain_path="/etc/nginx/trustforge/${name}/current/chain.pem"
    local key_path="/etc/nginx/trustforge/${name}/current/private-key.pem"

    local service_id
    service_id=$(curl -fsS -X POST "${API_URL}/api/v1/services" \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" -d @- <<EOF | tf_json_get id
{
  "name": "nginx-${name}",
  "environment": "production",
  "owner": "platform-team",
  "host": "${TARGET_HOST}",
  "port": 22,
  "hostKeyFingerprint": "${fingerprint}",
  "sshCredentialRef": "secret://file//${SSH_SECRET_FILE}",
  "profileId": "11111111-1111-1111-1111-111111111111",
  "sans": ["${domain}"],
  "certificatePath": "${cert_path}",
  "chainPath": "${chain_path}",
  "privateKeyPath": "${key_path}",
  "fileOwner": "root",
  "fileGroup": "www-data",
  "fileMode": "0640",
  "remoteHelperId": "trustforge-certctl-v1",
  "reloadActionId": "nginx-reload",
  "healthCheckId": "${health_id}",
  "renewalEnabled": true,
  "renewalLeadTime": "${RENEWAL_LEAD_TIME}"
}
EOF
)

    local guid_nodash
    guid_nodash=$(printf '%s' "$service_id" | tr -d '-')
    install -d -m 0700 -o root -g root /etc/trustforge/services
    (
        umask 077
        cat >"/etc/trustforge/services/${guid_nodash}.json" <<EOF
{
  "certificatePath": "${cert_path}",
  "chainPath": "${chain_path}",
  "privateKeyPath": "${key_path}",
  "fileOwner": "root",
  "fileGroup": "www-data",
  "fileMode": "0640",
  "remoteHelperId": "trustforge-certctl-v1",
  "reloadActionId": "nginx-reload",
  "healthCheckId": "${health_id}"
}
EOF
    )
    tf_ok "registered service nginx-${name} ($service_id)"

    local job_id state="" i
    job_id=$(curl -fsS -X POST "${API_URL}/api/v1/services/${service_id}/certificate-jobs" \
        -H "Authorization: Bearer $access_token" \
        -H "Idempotency-Key: bootstrap-${name}-$(date +%s)" | tf_json_get id)
    tf_log "issuing ACME DNS-01 certificate for $domain (job: $job_id)"

    for ((i = 1; i <= 90; i++)); do
        state=$(curl -fsS "${API_URL}/api/v1/certificate-jobs/${job_id}" \
            -H "Authorization: Bearer $access_token" | tf_json_get state)
        case "$state" in
            Succeeded) break ;;
            Failed|FailedRolledBack|RollbackFailed|Cancelled)
                curl -fsS "${API_URL}/api/v1/certificate-jobs/${job_id}" \
                    -H "Authorization: Bearer $access_token" >&2 || true
                tf_die "certificate job $job_id for $domain ended in $state"
                ;;
        esac
        sleep 2
    done
    [[ $state == "Succeeded" ]] || tf_die "timed out waiting for certificate job $job_id (last state: $state)"
    tf_ok "issued and deployed certificate for https://${domain} (auto-renewal enabled, leadTime=${RENEWAL_LEAD_TIME})"
}

main() {
    tf_require_root
    tf_require_ubuntu_2404
    [[ -n $API_DOMAIN ]] || tf_die "--api-domain is required"

    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -qq -y --no-install-recommends install nginx openssl curl python3

    if [[ ! -x /usr/local/sbin/trustforge-certctl ]]; then
        "$SCRIPT_DIR/install-target-helper.sh" --local --control-plane-secret "$(basename "$SSH_SECRET_FILE")"
    fi

    mint_bootstrap_cert "api" "$API_DOMAIN"
    write_nginx_site "api" "$API_DOMAIN" "http://127.0.0.1:5000"
    register_health_action "nginx-health-api" "$API_DOMAIN"

    if [[ -n $OIDC_DOMAIN ]]; then
        mint_bootstrap_cert "oidc" "$OIDC_DOMAIN"
        write_nginx_site "oidc" "$OIDC_DOMAIN" "http://127.0.0.1:8280"
        register_health_action "nginx-health-oidc" "$OIDC_DOMAIN"
    fi

    nginx -t >/dev/null
    systemctl enable --now nginx
    systemctl reload nginx
    tf_ok "Nginx HTTPS reverse proxy running"

    if [[ $SKIP_ISSUE -eq 1 ]]; then
        tf_log "--skip-issue set; Nginx is serving bootstrap certificates."
        return 0
    fi

    local access_token fingerprint
    access_token=$(get_oidc_token)
    fingerprint=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')

    if [[ -n $OIDC_DOMAIN ]]; then
        register_and_issue "oidc" "$OIDC_DOMAIN" "nginx-health-oidc" "$access_token" "$fingerprint"
    fi
    register_and_issue "api" "$API_DOMAIN" "nginx-health-api" "$access_token" "$fingerprint"
}

main
