#!/usr/bin/env bash
# Installs and configures Smallstep step-ca (with ACME + CRL + nosql orderIDs fix) on Ubuntu 24.04,
# or registers an existing external step-ca root certificate for TrustForge.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

ENV_FILE=/etc/trustforge/trustforge.env
SECRETS_DIR=/etc/trustforge/secrets
STEP_USER=step
STEP_PATH=/etc/step-ca
STEP_CA_TAG=0.30.2

EXTERNAL=0
USE_APT_STEP_CA=0
CA_NAME="TrustForge Internal CA"
CA_DOMAIN="ca.trustforge.internal"
CA_PORT=9000
CA_BIND_ADDRESS=""
EXTERNAL_DIRECTORY_URL=""
EXTERNAL_ROOT_CERT=""
ADMIN_PROVISIONER="admin"
ACME_PROVISIONER="acme"

usage() {
    cat <<'EOF'
Usage: setup-step-ca.sh [OPTION]...

Sets up Smallstep step-ca as a hardened systemd service for TrustForge on Ubuntu 24.04,
or imports an existing external step-ca root certificate.

Local CA options:
  --ca-name NAME            CA display name (default: "TrustForge Internal CA")
  --ca-domain HOST          CA DNS name included in TLS SANs (default: ca.trustforge.internal)
  --ca-port PORT            HTTPS listen port (default: 9000)
  --ca-bind ADDR            Listen address (default: :<ca-port>)
  --step-ca-tag VER         step-ca source tag when building patched binary (default: 0.30.2)
  --use-apt-step-ca         Install prebuilt step-ca from Smallstep APT instead of building patched binary
                            (note: unpatched v0.30.2 nosql backend has an ACME order-index bug)

External CA options:
  --external                Do not install step-ca locally; import an existing CA root & URL
  --directory-url URL       External ACME directory URL (https://.../acme/.../directory)
  --root-cert PATH          Path to existing CA root PEM file

General:
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --ca-name) CA_NAME=${2:?--ca-name needs a value}; shift 2 ;;
        --ca-domain) CA_DOMAIN=${2:?--ca-domain needs a value}; shift 2 ;;
        --ca-port) CA_PORT=${2:?--ca-port needs a port}; shift 2 ;;
        --ca-bind) CA_BIND_ADDRESS=${2:?--ca-bind needs an address}; shift 2 ;;
        --step-ca-tag) STEP_CA_TAG=${2:?--step-ca-tag needs a tag}; shift 2 ;;
        --use-apt-step-ca) USE_APT_STEP_CA=1; shift ;;
        --external) EXTERNAL=1; shift ;;
        --directory-url) EXTERNAL_DIRECTORY_URL=${2:?--directory-url needs a URL}; shift 2 ;;
        --root-cert) EXTERNAL_ROOT_CERT=${2:?--root-cert needs a path}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; tf_die "unknown option: $1" ;;
    esac
done

install_root_cert_for_trustforge() {
    local src=$1
    [[ -r $src ]] || tf_die "root certificate not readable: $src"
    openssl x509 -in "$src" -noout >/dev/null 2>&1 || tf_die "invalid PEM certificate: $src"

    if id -u trustforge >/dev/null 2>&1; then
        install -d -m 0750 -o root -g trustforge "$SECRETS_DIR"
        install -m 0640 -o root -g trustforge "$src" "$SECRETS_DIR/root_ca.crt"
    else
        install -d -m 0750 -o root -g root "$SECRETS_DIR"
        install -m 0644 -o root -g root "$src" "$SECRETS_DIR/root_ca.crt"
    fi

    install -d -m 0755 /usr/local/share/ca-certificates
    install -m 0644 -o root -g root "$src" /usr/local/share/ca-certificates/step-ca-root.crt
    update-ca-certificates >/dev/null
    tf_ok "installed root CA to $SECRETS_DIR/root_ca.crt and system trust store"
}

setup_external_ca() {
    [[ -n $EXTERNAL_DIRECTORY_URL ]] || tf_die "--external requires --directory-url"
    [[ $EXTERNAL_DIRECTORY_URL == https://* ]] || tf_die "--directory-url must use https://"
    [[ -n $EXTERNAL_ROOT_CERT ]] || tf_die "--external requires --root-cert"

    install_root_cert_for_trustforge "$EXTERNAL_ROOT_CERT"
    curl -fsS --cacert "$SECRETS_DIR/root_ca.crt" --max-time 15 "$EXTERNAL_DIRECTORY_URL" >/dev/null ||
        tf_die "ACME directory unreachable or root CA mismatch: $EXTERNAL_DIRECTORY_URL"
    tf_ok "verified external ACME directory: $EXTERNAL_DIRECTORY_URL"

    if [[ -f $ENV_FILE ]]; then
        tf_env_set "$ENV_FILE" "SmallstepAcme__DirectoryUrl" "$EXTERNAL_DIRECTORY_URL"
        tf_env_set "$ENV_FILE" "SmallstepAcme__RootCertificatePath" "$SECRETS_DIR/root_ca.crt"
        tf_ok "updated $ENV_FILE with external ACME CA settings"
    fi
}

install_smallstep_apt_repo() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -qq -y --no-install-recommends install ca-certificates curl gpg openssl python3 git
    install -d -m 0755 /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/smallstep.asc ]]; then
        curl -fsSL --max-time 60 https://packages.smallstep.com/keys/apt/repo-signing-key.gpg |
            gpg --dearmor --yes -o /etc/apt/keyrings/smallstep.asc
        chmod 0644 /etc/apt/keyrings/smallstep.asc
    fi
    cat >/etc/apt/sources.list.d/smallstep.sources <<'EOF'
Types: deb
URIs: https://packages.smallstep.com/stable/debian
Suites: debs
Components: main
Signed-By: /etc/apt/keyrings/smallstep.asc
EOF
    chmod 0644 /etc/apt/sources.list.d/smallstep.sources
    apt-get -qq update
}

build_patched_step_ca() {
    local build_root arch go_ver go_tarball
    arch=$(dpkg --print-architecture)
    case "$arch" in
        amd64|arm64) ;;
        *) tf_die "unsupported architecture for Go toolchain download: $arch" ;;
    esac

    if [[ -x /usr/local/bin/step-ca ]] && /usr/local/bin/step-ca version 2>/dev/null | grep -q "$STEP_CA_TAG"; then
        tf_ok "patched /usr/local/bin/step-ca ($STEP_CA_TAG) already present"
        return 0
    fi

    build_root=$(mktemp -d "${TMPDIR:-/var/tmp}/trustforge-stepca-build.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$build_root'" RETURN

    go_ver=$(curl -fsSL --max-time 30 "https://go.dev/VERSION?m=text" | head -n1 | tr -d '\r\n')
    [[ $go_ver == go* ]] || tf_die "failed to resolve Go version from go.dev"
    go_tarball="$build_root/${go_ver}.linux-${arch}.tar.gz"

    tf_log "downloading $go_ver to build patched step-ca v$STEP_CA_TAG (temp dir will be removed)"
    curl -fsSL --max-time 180 "https://go.dev/dl/${go_ver}.linux-${arch}.tar.gz" -o "$go_tarball"
    tar -xzf "$go_tarball" -C "$build_root"

    git clone --depth 1 --branch "v${STEP_CA_TAG}" https://github.com/smallstep/certificates "$build_root/src"
    python3 -c '
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "acme/db/nosql/order.go"
text = p.read_text(encoding="utf-8")
if text.count("_new = nil") != 1 or text.count("_old = nil") != 1:
    sys.exit("unexpected acme/db/nosql/order.go layout; cannot safely apply orderIDs fix")
text = text.replace("_new = nil", "_new = pendOids", 1)
text = text.replace("_old = nil", "if oldOids == nil { _old = nil }", 1)
p.write_text(text, encoding="utf-8")
' "$build_root/src"

    tf_log "compiling step-ca v$STEP_CA_TAG with ACME orderIDs fix"
    (
        cd "$build_root/src"
        export PATH="$build_root/go/bin:$PATH"
        export GOPATH="$build_root/gopath"
        export GOCACHE="$build_root/gocache"
        export GOTMPDIR="$build_root"
        export CGO_ENABLED=0
        go build -trimpath -o /usr/local/bin/step-ca.new ./cmd/step-ca
    )
    chmod 0755 /usr/local/bin/step-ca.new
    mv -f /usr/local/bin/step-ca.new /usr/local/bin/step-ca
    tf_ok "built patched /usr/local/bin/step-ca (v$STEP_CA_TAG)"
}

install_step_binaries() {
    install_smallstep_apt_repo
    apt-get -qq -y --no-install-recommends install step-cli
    tf_ok "installed step CLI: $(step version | head -n1)"

    if [[ $USE_APT_STEP_CA -eq 1 ]]; then
        apt-get -qq -y --no-install-recommends install step-ca
        tf_hint "installed unpatched step-ca from APT; see OPERATIONS.md §2.1 regarding nosql orderIDs"
    else
        build_patched_step_ca
    fi
}

step_ca_bin() {
    if [[ $USE_APT_STEP_CA -eq 0 && -x /usr/local/bin/step-ca ]]; then
        printf '/usr/local/bin/step-ca'
    elif command -v step-ca >/dev/null 2>&1; then
        command -v step-ca
    else
        tf_die "step-ca binary not found"
    fi
}

configure_ca_json() {
    local ca_json="$STEP_PATH/config/ca.json"
    local idp_url="https://${CA_DOMAIN}:${CA_PORT}/1.0/crl"
    python3 -c '
import json, sys
path, acme_name, idp_url = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)

provisioners = cfg.setdefault("authority", {}).setdefault("provisioners", [])
if not any(p.get("type") == "ACME" and p.get("name") == acme_name for p in provisioners):
    provisioners.append({"type": "ACME", "name": acme_name})

cfg["crl"] = {
    "enabled": True,
    "generateOnRevoke": True,
    "cacheDuration": "3600s",
    "renewPeriod": "600s",
    "idpURL": idp_url,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
' "$ca_json" "$ACME_PROVISIONER" "$idp_url"
    chown "$STEP_USER:$STEP_USER" "$ca_json"
    chmod 0640 "$ca_json"
}

setup_local_ca() {
    local bind=${CA_BIND_ADDRESS:-":${CA_PORT}"}
    local bin host_ip dns_args

    install_step_binaries
    bin=$(step_ca_bin)

    id -u "$STEP_USER" >/dev/null 2>&1 ||
        useradd --system --user-group --home-dir "$STEP_PATH" --shell /usr/sbin/nologin "$STEP_USER"

    install -d -m 0750 -o "$STEP_USER" -g "$STEP_USER" "$STEP_PATH"

    if [[ ! -f $STEP_PATH/config/ca.json ]]; then
        local pw_file="$STEP_PATH/password.txt"
        if [[ ! -f $pw_file ]]; then
            (umask 077; openssl rand -hex 24 >"$pw_file")
        fi
        chown "$STEP_USER:$STEP_USER" "$pw_file"
        chmod 0400 "$pw_file"

        host_ip=$(tf_detect_primary_ip)
        dns_args=("--dns=$CA_DOMAIN" "--dns=localhost" "--dns=127.0.0.1")
        if [[ -n $host_ip && $host_ip != "127.0.0.1" ]]; then
            dns_args+=("--dns=$host_ip")
        fi

        tf_log "initializing step-ca in $STEP_PATH"
        runuser -u "$STEP_USER" -- env STEPPATH="$STEP_PATH" step ca init \
            --name="$CA_NAME" \
            "${dns_args[@]}" \
            --address="$bind" \
            --provisioner="$ADMIN_PROVISIONER" \
            --password-file="$pw_file" \
            --deployment-type="standalone" >/dev/null
        tf_ok "initialized local CA at $STEP_PATH"
    else
        tf_ok "reusing existing step-ca config at $STEP_PATH/config/ca.json"
    fi

    configure_ca_json

    cat >/etc/systemd/system/step-ca.service <<EOF
[Unit]
Description=Smallstep step-ca Private ACME Certificate Authority
Documentation=https://smallstep.com/docs/step-ca
After=network-online.target trustforge.service
Wants=network-online.target

[Service]
Type=simple
User=${STEP_USER}
Group=${STEP_USER}
Environment=STEPPATH=${STEP_PATH}
WorkingDirectory=${STEP_PATH}
ExecStart=${bin} ${STEP_PATH}/config/ca.json --password-file ${STEP_PATH}/password.txt
ExecReload=/bin/kill --signal HUP \$MAINPID
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${STEP_PATH}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now step-ca.service
    systemctl restart step-ca.service

    tf_wait_for "step-ca health" 30 env STEPPATH="$STEP_PATH" step ca health \
        --ca-url "https://127.0.0.1:${CA_PORT}" --root "$STEP_PATH/certs/root_ca.crt" ||
        { journalctl -u step-ca -n 40 --no-pager >&2 || true; tf_die "step-ca did not become healthy"; }
    tf_ok "step-ca is healthy on port $CA_PORT"

    install_root_cert_for_trustforge "$STEP_PATH/certs/root_ca.crt"

    local dir_url="https://${CA_DOMAIN}:${CA_PORT}/acme/${ACME_PROVISIONER}/directory"
    if [[ -f $ENV_FILE ]]; then
        tf_env_set "$ENV_FILE" "SmallstepAcme__DirectoryUrl" "$dir_url"
        tf_env_set "$ENV_FILE" "SmallstepAcme__RootCertificatePath" "$SECRETS_DIR/root_ca.crt"
        tf_ok "updated $ENV_FILE (SmallstepAcme__DirectoryUrl=$dir_url)"
    fi

    tf_log "step-ca ready. Root CA: $SECRETS_DIR/root_ca.crt, ACME: $dir_url"
}

main() {
    tf_require_root
    tf_require_ubuntu_2404
    if [[ $EXTERNAL -eq 1 ]]; then
        setup_external_ca
    else
        setup_local_ca
    fi
}

main
