#!/usr/bin/env bash
# Shared helper functions for TrustForge bare-metal operational scripts.
# Sourced by install.sh companion scripts; do not execute directly.

tf_log() { printf '%s %s\n' "[$(date -u +%H:%M:%S)]" "$*"; }
tf_ok() { printf '  PASS  %s\n' "$*"; }
tf_hint() { printf '  NOTE  %s\n' "$*"; }
tf_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

tf_require_root() {
    [[ $EUID -eq 0 ]] || tf_die "run as root (or sudo)."
}

tf_require_ubuntu_2404() {
    local id="" version=""
    [[ -r /etc/os-release ]] || tf_die "/etc/os-release is unreadable; cannot identify OS."
    # shellcheck disable=SC1091
    id=$(. /etc/os-release && printf '%s' "${ID:-}")
    # shellcheck disable=SC1091
    version=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
    [[ $id == ubuntu && $version == 24.04 ]] ||
        tf_die "unsupported OS ($id $version): Ubuntu 24.04 is required."
}

tf_wait_for() {
    local desc=$1 attempts=$2
    shift 2
    local i
    for ((i = 1; i <= attempts; i++)); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 2
    done
    printf 'timed out waiting for: %s\n' "$desc" >&2
    return 1
}

# Safely reads a value from systemd EnvironmentFile without executing ';' as shell commands.
tf_env_get() {
    local file=$1 key=$2
    [[ -r $file ]] || return 1
    python3 -c '
import sys
path, target = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    for line in f:
        s = line.rstrip("\r\n")
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        if k == target:
            print(v)
            sys.exit(0)
sys.exit(1)
' "$file" "$key"
}

# Updates or appends KEY=VALUE in a systemd EnvironmentFile preserving comments and permissions.
tf_env_set() {
    local file=$1 key=$2 val=$3
    [[ -f $file ]] || tf_die "env file does not exist: $file"
    python3 -c '
import os, sys, tempfile
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines(keepends=True)

found = False
out = []
for line in lines:
    stripped = line.rstrip("\r\n")
    if stripped and not stripped.startswith("#") and "=" in stripped:
        k, _ = stripped.split("=", 1)
        if k == key:
            out.append(f"{key}={val}\n")
            found = True
            continue
    out.append(line)

if not found:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append(f"{key}={val}\n")

mode = os.stat(path).st_mode & 0o777
fd, tmp = tempfile.mkstemp(prefix=".tf-env-", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(out)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
' "$file" "$key" "$val"
}

tf_json_get() {
    python3 -c '
import json, sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    if isinstance(value, list):
        value = value[int(key)]
    else:
        value = value[key]
print(value if not isinstance(value, (dict, list)) else json.dumps(value))
' "$1"
}

tf_detect_primary_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true
}
