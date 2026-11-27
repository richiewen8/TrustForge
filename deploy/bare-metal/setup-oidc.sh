#!/usr/bin/env bash
# Installs a local Keycloak OIDC provider on Ubuntu 24.04 for standalone TrustForge deployments
# without an existing enterprise OIDC server.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

ENV_FILE=/etc/trustforge/trustforge.env
SECRETS_DIR=/etc/trustforge/secrets
KC_USER=keycloak
KC_HOME=/opt/keycloak
KC_VERSION=26.8.2
KC_HOST=127.0.0.1
KC_PORT=8280
OIDC_DOMAIN=""
OIDC_ISSUER_URL=""
AUDIENCE="trustforge-api"
ADMIN_USER="trustforge-operator"
ADMIN_EMAIL=""
NO_RESTART=0

usage() {
    cat <<'EOF'
Usage: setup-oidc.sh [OPTION]...

Installs Keycloak locally (bound to 127.0.0.1:8280) with the TrustForge realm
(PlatformAdmin, CertificateOperator, Auditor roles and trustforge-cli client),
writes credentials to /etc/trustforge/secrets/oidc-credentials.env, and updates
/etc/trustforge/trustforge.env.

Options:
  --domain HOST             Public HTTPS hostname for OIDC (e.g. id.trustforge.internal)
  --issuer-url URL          Explicit issuer URL (overrides https://<domain>/realms/trustforge-dev)
  --audience NAME           JWT audience (default: trustforge-api)
  --port PORT               Loopback HTTP port for Keycloak (default: 8280)
  --admin-user USER         Initial PlatformAdmin username (default: trustforge-operator)
  --admin-email EMAIL       Initial PlatformAdmin email (default: <admin-user>@<domain>)
  --keycloak-version VER    Keycloak release version (default: 26.8.2)
  --no-restart              Do not restart trustforge after updating trustforge.env
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) OIDC_DOMAIN=${2:?--domain needs a hostname}; shift 2 ;;
        --issuer-url) OIDC_ISSUER_URL=${2:?--issuer-url needs a URL}; shift 2 ;;
        --audience) AUDIENCE=${2:?--audience needs a value}; shift 2 ;;
        --port) KC_PORT=${2:?--port needs a port}; shift 2 ;;
        --admin-user) ADMIN_USER=${2:?--admin-user needs a username}; shift 2 ;;
        --admin-email) ADMIN_EMAIL=${2:?--admin-email needs an email}; shift 2 ;;
        --keycloak-version) KC_VERSION=${2:?--keycloak-version needs a version}; shift 2 ;;
        --no-restart) NO_RESTART=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; tf_die "unknown option: $1" ;;
    esac
done

find_realm_template() {
    local candidate
    for candidate in \
        "$SCRIPT_DIR/keycloak/trustforge-dev-realm.json" \
        "$SCRIPT_DIR/../../TrustForge.Api/keycloak/trustforge-dev-realm.json"; do
        if [[ -f $candidate ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    tf_die "trustforge-dev-realm.json not found under $SCRIPT_DIR/keycloak or TrustForge.Api/keycloak"
}

main() {
    tf_require_root
    tf_require_ubuntu_2404

    if [[ -z $OIDC_DOMAIN && -z $OIDC_ISSUER_URL ]]; then
        OIDC_DOMAIN="id.trustforge.internal"
    fi
    if [[ -z $OIDC_ISSUER_URL ]]; then
        OIDC_ISSUER_URL="https://${OIDC_DOMAIN}/realms/trustforge-dev"
    fi
    if [[ -z $OIDC_DOMAIN ]]; then
        OIDC_DOMAIN=$(python3 -c 'import urllib.parse, sys; print(urllib.parse.urlparse(sys.argv[1]).hostname or "localhost")' "$OIDC_ISSUER_URL")
    fi
    if [[ -z $ADMIN_EMAIL ]]; then
        ADMIN_EMAIL="${ADMIN_USER}@${OIDC_DOMAIN}"
    fi

    local realm_src
    realm_src=$(find_realm_template)

    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -qq -y --no-install-recommends install ca-certificates curl tar python3 openjdk-21-jre-headless openssl

    id -u "$KC_USER" >/dev/null 2>&1 ||
        useradd --system --user-group --home-dir "$KC_HOME" --shell /usr/sbin/nologin "$KC_USER"

    if [[ ! -x $KC_HOME/bin/kc.sh ]]; then
        local dl_tmp tarball
        dl_tmp=$(mktemp -d "${TMPDIR:-/var/tmp}/trustforge-kc.XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -rf '$dl_tmp'" EXIT
        tarball="$dl_tmp/keycloak-${KC_VERSION}.tar.gz"
        tf_log "downloading Keycloak ${KC_VERSION}"
        curl -fsSL --max-time 300 "https://github.com/keycloak/keycloak/releases/download/${KC_VERSION}/keycloak-${KC_VERSION}.tar.gz" -o "$tarball"
        install -d -m 0755 "$KC_HOME"
        tar -xzf "$tarball" --strip-components=1 -C "$KC_HOME"
        chown -R "$KC_USER:$KC_USER" "$KC_HOME"
        tf_ok "installed Keycloak ${KC_VERSION} to $KC_HOME"
    else
        tf_ok "Keycloak already installed at $KC_HOME"
    fi

    install -d -m 0750 -o root -g root "$SECRETS_DIR"
    local cred_file="$SECRETS_DIR/oidc-credentials.env"
    local kc_admin_pass dev_pass
    if [[ -f $cred_file ]]; then
        kc_admin_pass=$(tf_env_get "$cred_file" "KC_BOOTSTRAP_ADMIN_PASSWORD" || true)
        dev_pass=$(tf_env_get "$cred_file" "TF_OIDC_DEV_PASSWORD" || true)
    fi
    [[ -n ${kc_admin_pass:-} ]] || kc_admin_pass=$(openssl rand -hex 16)
    [[ -n ${dev_pass:-} ]] || dev_pass=$(openssl rand -hex 16)

    (
        umask 077
        cat >"$cred_file" <<EOF
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=${kc_admin_pass}
TF_OIDC_DEV_USERNAME=${ADMIN_USER}
TF_OIDC_DEV_EMAIL=${ADMIN_EMAIL}
TF_OIDC_DEV_PASSWORD=${dev_pass}
EOF
    )
    chown root:root "$cred_file"
    chmod 0600 "$cred_file"

    install -d -m 0750 -o "$KC_USER" -g "$KC_USER" "$KC_HOME/data/import"
    cp "$realm_src" "$KC_HOME/data/import/trustforge-dev-realm.json"
    chown "$KC_USER:$KC_USER" "$KC_HOME/data/import/trustforge-dev-realm.json"
    chmod 0640 "$KC_HOME/data/import/trustforge-dev-realm.json"

    local kc_hostname
    kc_hostname=$(python3 -c 'import urllib.parse, sys; u = urllib.parse.urlparse(sys.argv[1]); print(f"{u.scheme}://{u.netloc}")' "$OIDC_ISSUER_URL")

    local kc_env=/etc/trustforge/keycloak.env
    install -d -m 0755 /etc/trustforge
    (
        umask 077
        cat >"$kc_env" <<EOF
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=${kc_admin_pass}
TF_OIDC_DEV_USERNAME=${ADMIN_USER}
TF_OIDC_DEV_EMAIL=${ADMIN_EMAIL}
TF_OIDC_DEV_PASSWORD=${dev_pass}
KC_HOSTNAME=${kc_hostname}
KC_HOSTNAME_STRICT=false
KC_HTTP_ENABLED=true
KC_HTTP_HOST=${KC_HOST}
KC_HTTP_PORT=${KC_PORT}
KC_PROXY_HEADERS=xforwarded
EOF
    )
    chown root:"$KC_USER" "$kc_env"
    chmod 0640 "$kc_env"

    cat >/etc/systemd/system/keycloak.service <<EOF
[Unit]
Description=Keycloak OIDC Provider for TrustForge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${KC_USER}
Group=${KC_USER}
EnvironmentFile=${kc_env}
WorkingDirectory=${KC_HOME}
ExecStart=${KC_HOME}/bin/kc.sh start-dev --import-realm
Restart=on-failure
RestartSec=5
TimeoutStartSec=300
NoNewPrivileges=yes
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now keycloak.service
    systemctl restart keycloak.service

    tf_wait_for "Keycloak realm readiness" 90 \
        curl -fsS --max-time 5 "http://${KC_HOST}:${KC_PORT}/realms/trustforge-dev/.well-known/openid-configuration" ||
        { journalctl -u keycloak -n 40 --no-pager >&2 || true; tf_die "Keycloak did not become ready"; }
    tf_ok "Keycloak listening on http://${KC_HOST}:${KC_PORT} (issuer: $OIDC_ISSUER_URL)"

    if [[ -f $ENV_FILE ]]; then
        tf_env_set "$ENV_FILE" "Authentication__Authority" "$OIDC_ISSUER_URL"
        tf_env_set "$ENV_FILE" "Authentication__Audience" "$AUDIENCE"
        if [[ $OIDC_ISSUER_URL == http://127.0.0.1* || $OIDC_ISSUER_URL == http://localhost* ]]; then
            tf_env_set "$ENV_FILE" "ASPNETCORE_ENVIRONMENT" "Development"
            tf_env_set "$ENV_FILE" "Authentication__AllowInsecureLoopback" "true"
        fi
        tf_ok "updated $ENV_FILE with Authentication__Authority=$OIDC_ISSUER_URL"
        if [[ $NO_RESTART -eq 0 ]] && systemctl is-active --quiet trustforge; then
            systemctl restart trustforge
            tf_wait_for "TrustForge API readiness" 40 curl -fsS --max-time 5 "http://127.0.0.1:5000/health/ready" ||
                tf_die "TrustForge API did not become ready after OIDC config update"
        fi
    fi

    tf_log "OIDC credentials saved in $cred_file (operator: $ADMIN_USER, client_id: trustforge-cli)"
}

main
