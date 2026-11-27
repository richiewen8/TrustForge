#!/usr/bin/env bash
# Installs and configures trustforge-certctl on a Linux target host (either remote or --local).
# Self-contained (no external script dependency) so it can be copied onto any target machine alongside
# remote-helper/trustforge-certctl.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SSH_USER="trustforge-deployer"
LOCAL_MODE=0
SECRET_NAME=""
PUBKEY_FILE=""
HELPER_SRC=""
RELOAD_ID="nginx-reload"
RELOAD_CMD="/usr/bin/systemctl reload nginx"

log() { printf '%s %s\n' "[$(date -u +%H:%M:%S)]" "$*"; }
ok() { printf '  PASS  %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install-target-helper.sh [OPTION]...

Installs the root-owned trustforge-certctl helper, creates the dedicated SSH deployer user
with restricted sudoers, installs the TLS verification script, and prints the SSH host
key fingerprint required when registering services in TrustForge.

Options:
  --helper-path PATH          Path to trustforge-certctl executable source
  --ssh-user USER             SSH deployer account name (default: trustforge-deployer)
  --authorized-key-file PATH  Public key file to append to deployer authorized_keys
  --local                     Also generate SSH keypair and write TrustForge control-plane secret JSON
  --control-plane-secret NAME Secret filename under /etc/trustforge/secrets (e.g. ssh-local.json)
  --reload-action-id ID       Reload action ID to register in /etc/trustforge/actions.json (default: nginx-reload)
  --reload-cmd "ARG1 ARG2..." Argv command for reload action (default: "/usr/bin/systemctl reload nginx")
  -h, --help                  Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --helper-path) HELPER_SRC=${2:?--helper-path needs a path}; shift 2 ;;
        --ssh-user) SSH_USER=${2:?--ssh-user needs a user}; shift 2 ;;
        --authorized-key-file) PUBKEY_FILE=${2:?--authorized-key-file needs a path}; shift 2 ;;
        --local) LOCAL_MODE=1; shift ;;
        --control-plane-secret) SECRET_NAME=${2:?--control-plane-secret needs a filename}; LOCAL_MODE=1; shift 2 ;;
        --reload-action-id) RELOAD_ID=${2:?--reload-action-id needs an ID}; shift 2 ;;
        --reload-cmd) RELOAD_CMD=${2:?--reload-cmd needs a command}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

find_helper() {
    local candidate
    if [[ -n $HELPER_SRC ]]; then
        [[ -f $HELPER_SRC ]] || die "helper not found at $HELPER_SRC"
        printf '%s' "$HELPER_SRC"
        return 0
    fi
    for candidate in \
        "$SCRIPT_DIR/trustforge-certctl" \
        "$SCRIPT_DIR/../../remote-helper/trustforge-certctl" \
        "/opt/trustforge/remote-helper/trustforge-certctl"; do
        if [[ -f $candidate ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    die "trustforge-certctl not found; pass --helper-path"
}

main() {
    [[ $EUID -eq 0 ]] || die "run as root (or sudo)."

    local helper
    helper=$(find_helper)

    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
        apt-get -qq update
        apt-get -qq -y --no-install-recommends install python3 openssl openssh-server sudo
    fi

    install -o root -g root -m 0750 "$helper" /usr/local/sbin/trustforge-certctl
    install -d -o root -g root -m 0755 /etc/trustforge
    install -d -o root -g root -m 0700 /etc/trustforge/services
    install -d -o root -g root -m 0700 /var/lib/trustforge
    install -d -o root -g root -m 0755 /usr/local/libexec/trustforge
    ok "installed /usr/local/sbin/trustforge-certctl"

    cat >/usr/local/libexec/trustforge/check-tls <<'EOF'
#!/usr/bin/env bash
# Verifies served TLS leaf certificate SHA-256 against the active TrustForge release.
# Usage: check-tls <service_id_nodash> [port] [server_name]
set -euo pipefail
service_id=${1:?service_id required}
port=${2:-443}
server_name=${3:-}
reg="/etc/trustforge/services/${service_id}.json"
[ -r "$reg" ] || exit 1
cert_path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["certificatePath"])' "$reg")
current_dir=$(dirname "$cert_path")

# First-install validation runs before any certificate exists; absence is healthy.
if [ ! -L "$current_dir" ]; then
    exit 0
fi

expected=$(openssl x509 -in "$cert_path" -outform DER | sha256sum | awk '{print $1}')
sni_args=()
if [ -n "$server_name" ]; then
    sni_args=(-servername "$server_name")
fi

attempt=0
while [ "$attempt" -lt 10 ]; do
    actual=$(echo | openssl s_client -connect "127.0.0.1:${port}" "${sni_args[@]}" 2>/dev/null \
        | openssl x509 -outform DER 2>/dev/null | sha256sum | awk '{print $1}' || true)
    if [ -n "$actual" ] && [ "$expected" = "$actual" ]; then
        exit 0
    fi
    sleep 1
    attempt=$((attempt + 1))
done
echo "TLS endpoint 127.0.0.1:${port} did not serve expected cert $expected (last: ${actual:-none})" >&2
exit 1
EOF
    chown root:root /usr/local/libexec/trustforge/check-tls
    chmod 0755 /usr/local/libexec/trustforge/check-tls

    # Ensure /etc/trustforge/actions.json exists and merges the reload + generic health action
    python3 -c '
import json, os, shlex, sys
path = "/etc/trustforge/actions.json"
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
reload_id, reload_cmd = sys.argv[1], sys.argv[2]
data[reload_id] = shlex.split(reload_cmd)
data.setdefault("tls-health-443", ["/usr/local/libexec/trustforge/check-tls", "{service_id}", "443"])
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$RELOAD_ID" "$RELOAD_CMD"
    chown root:root /etc/trustforge/actions.json
    chmod 0600 /etc/trustforge/actions.json
    ok "configured /etc/trustforge/actions.json"

    # Dedicated SSH account + restricted sudoers
    if ! id -u "$SSH_USER" >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash "$SSH_USER"
        passwd -l "$SSH_USER" >/dev/null 2>&1 || true
    fi
    local home_dir
    home_dir=$(getent passwd "$SSH_USER" | cut -d: -f6)
    install -d -m 0700 -o "$SSH_USER" -g "$SSH_USER" "$home_dir/.ssh"
    touch "$home_dir/.ssh/authorized_keys"
    chown "$SSH_USER:$SSH_USER" "$home_dir/.ssh/authorized_keys"
    chmod 0600 "$home_dir/.ssh/authorized_keys"

    if [[ -n $PUBKEY_FILE ]]; then
        [[ -r $PUBKEY_FILE ]] || die "public key file unreadable: $PUBKEY_FILE"
        local pubkey
        pubkey=$(cat "$PUBKEY_FILE")
        if ! grep -Fxq "$pubkey" "$home_dir/.ssh/authorized_keys"; then
            printf '%s\n' "$pubkey" >>"$home_dir/.ssh/authorized_keys"
        fi
        ok "added public key to $home_dir/.ssh/authorized_keys"
    fi

    cat >/etc/sudoers.d/trustforge-certctl <<EOF
${SSH_USER} ALL=(root) NOPASSWD: /usr/local/sbin/trustforge-certctl
EOF
    chown root:root /etc/sudoers.d/trustforge-certctl
    chmod 0440 /etc/sudoers.d/trustforge-certctl
    visudo -cf /etc/sudoers.d/trustforge-certctl >/dev/null
    ok "configured restricted sudoers for $SSH_USER"

    if [[ $LOCAL_MODE -eq 1 ]]; then
        local secrets_dir=/etc/trustforge/secrets
        local secret_file="${SECRET_NAME:-ssh-local.json}"
        local key_priv="$secrets_dir/${secret_file%.json}.ed25519"
        if id -u trustforge >/dev/null 2>&1; then
            install -d -m 0750 -o root -g trustforge "$secrets_dir"
        else
            install -d -m 0750 -o root -g root "$secrets_dir"
        fi
        if [[ ! -f $key_priv ]]; then
            ssh-keygen -t ed25519 -N "" -f "$key_priv" -C "trustforge-deployer" >/dev/null
            chmod 0600 "$key_priv"
        fi
        local pub
        pub=$(cat "${key_priv}.pub")
        if ! grep -Fxq "$pub" "$home_dir/.ssh/authorized_keys"; then
            printf '%s\n' "$pub" >>"$home_dir/.ssh/authorized_keys"
        fi
        python3 -c '
import json, sys
user, key_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
pem = open(key_path, encoding="utf-8").read()
with open(out_path, "w", encoding="utf-8") as f:
    json.dump({"username": user, "privateKeyPem": pem}, f)
    f.write("\n")
' "$SSH_USER" "$key_priv" "$secrets_dir/$secret_file"
        if id -u trustforge >/dev/null 2>&1; then
            chown root:trustforge "$secrets_dir/$secret_file"
            chmod 0640 "$secrets_dir/$secret_file"
        else
            chmod 0600 "$secrets_dir/$secret_file"
        fi
        ok "wrote SSH deployer credential to $secrets_dir/$secret_file"
    fi

    systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true

    local host_pub="/etc/ssh/ssh_host_ed25519_key.pub"
    if [[ ! -f $host_pub ]]; then
        ssh-keygen -A >/dev/null
    fi
    local fp
    fp=$(ssh-keygen -lf "$host_pub" | awk '{print $2}')
    log "Target helper ready. SSH host key fingerprint: $fp"
}

main
