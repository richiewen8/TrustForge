#!/usr/bin/env bash
# TrustForge bare-metal installer: Ubuntu 24.04, systemd, no Docker.
# Every decision this script freezes at first boot is explained in BAREMETAL.md.
set -euo pipefail

APP_ROOT=/opt/trustforge
RUNTIME_ROOT=/opt/dotnet
BUILD_ROOT=/var/tmp/trustforge-build
CONF_ROOT=/etc/trustforge
DNS_CONFIG_DIR=/etc/trustforge/dns
SECRETS_DIR=/etc/trustforge/secrets
DATA_ROOT=/var/lib/trustforge
ARTIFACT_DIR=/var/lib/trustforge/artifacts
DNS_LOG_DIR=/var/log/technitium/dns
ENV_FILE=/etc/trustforge/trustforge.env
UNIT_FILE=/etc/systemd/system/trustforge.service
STATE_FILE=/var/lib/trustforge/install.json
INSTALL_LOG=/opt/trustforge/install.log
SERVICE_USER=trustforge
PG_VERSION=17
PG_CLUSTER=main
API_PORT=5000
DNS_UI_PORT=5380
DNS_PORT=53
PGDG_KEY_URL=https://www.postgresql.org/media/keys/ACCC4CF8.asc
MS_REPO_DEB=https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb
DOTNET_INSTALL_URL=https://dot.net/v1/dotnet-install.sh
DOTNET_CHANNEL=10.0
LIB_PROJECTS=(TechnitiumLibrary.ByteTree TechnitiumLibrary.Net TechnitiumLibrary.Security.OTP)

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

CHECK_ONLY=0
DRY_RUN=0
ASSUME_YES=0
RESEED_DNS=0
SKIP_POSTGRES=0
SOURCE_ROOT=$REPO_ROOT
DB_PASSWORD_FILE=
OIDC_AUTHORITY=
OIDC_AUDIENCE=
TECH_LIBRARY=
DB_PASSWORD=
DB_PASSWORD_ORIGIN=

pass=0
fail=0
note=0

usage() {
    cat <<'EOF'
Usage: install.sh [OPTION]...

Installs TrustForge (API + embedded DNS engine) with PostgreSQL 17 on a physical or virtual
Ubuntu 24.04 host, with no container runtime. Run it as root. It refuses to run inside a
container and refuses to coexist with a Docker deployment of TrustForge.

Options:
  --check-only             Run the read-only preflight, then exit. No build, no changes.
  --dry-run                Preflight, then print the ordered mutation plan and exit.
                           Issues read-only network probes; leaves no state behind.
  --yes                    Never prompt.
  --source-dir DIR         TrustForge checkout (default: this script's repository). The build
                           runs on this host and needs a sibling TechnitiumLibrary checkout.
  --technitium-library DIR Library checkout, when it is not the sibling of --source-dir.
  --skip-postgres          Do not install or provision PostgreSQL: the cluster, role, database and
                           password are yours already. Implies --db-password-file.
  --db-password-file FILE  File containing only the trustforge database password. Without it a
                           password is generated once and kept in /etc/trustforge/secrets.
  --oidc-authority URL     HTTPS OIDC issuer. Required; the API throws without it.
  --oidc-audience NAME     TrustForge API audience. Required.
  --reseed-dns             Archive the existing first-boot DNS config and seed it again.
  -h, --help               This text.
EOF
}

log() { printf '%s %s\n' "[$(date -u +%H:%M:%S)]" "$*"; }
vlog() { printf '%s %s\n' "[$(date -u +%H:%M:%S)]" "$*" >>"$INSTALL_LOG" 2>/dev/null || true; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ok() { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*" >&2; fail=$((fail + 1)); }
hint() { printf '  NOTE  %s\n' "$*"; note=$((note + 1)); }
probe() { printf '        %s\n' "$*"; }

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply=
    printf '%s [y/N] ' "$1" >/dev/tty
    IFS= read -r reply </dev/tty || return 1
    [[ $reply == y || $reply == Y ]]
}

# iproute2 renders owners as: users:(("named",pid=812,fd=20))
port_pids() {
    local proto=$1 port=$2
    ss -Hl"${proto}np" "sport = :$port" 2>/dev/null |
        grep -oE 'users:\(?\(?"[^"]+' | sed 's/.*"//' | sort -u | paste -sd, - || true
}

port_listening() {
    local proto=$1 port=$2
    ss -Hl"${proto}n" "sport = :$port" 2>/dev/null | grep -q .
}

port_exposed_broadly() {
    local port=$1
    ss -Hltn "sport = :$port" 2>/dev/null | grep -qE '(0\.0\.0\.0|\*):'"$port"
}

wait_for() {
    local desc=$1 attempts=$2
    shift 2
    local i
    for ((i = 1; i <= attempts; i++)); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 3
    done
    printf 'timed out waiting for: %s\n' "$desc" >&2
    return 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check-only) CHECK_ONLY=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --yes) ASSUME_YES=1 ;;
            --reseed-dns) RESEED_DNS=1 ;;
            --skip-postgres) SKIP_POSTGRES=1 ;;
            --source-dir) SOURCE_ROOT=${2:?--source-dir needs a path}; shift ;;
            --technitium-library) TECH_LIBRARY=${2:?--technitium-library needs a path}; shift ;;
            --db-password-file) DB_PASSWORD_FILE=${2:?--db-password-file needs a path}; shift ;;
            --oidc-authority) OIDC_AUTHORITY=${2:?--oidc-authority needs a URL}; shift ;;
            --oidc-audience) OIDC_AUDIENCE=${2:?--oidc-audience needs a name}; shift ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; die "unknown option: $1" ;;
        esac
        shift
    done
}

resolve_library_dir() {
    local parent
    parent=$(cd -- "$SOURCE_ROOT/.." && pwd)
    [[ -n $TECH_LIBRARY ]] || TECH_LIBRARY=$parent/TechnitiumLibrary
    TECH_LIBRARY=$(cd -- "$TECH_LIBRARY" 2>/dev/null && pwd) || TECH_LIBRARY=$parent/TechnitiumLibrary
}

require_root_and_systemd() {
    [[ $EUID -eq 0 ]] || die "run as root (or sudo): this installs a systemd unit, a service account and PostgreSQL."
    [[ $(ps --no-headers -o comm 1 | tr -d '\n') == systemd ]] || die "PID 1 is not systemd; there is no sysvinit or openrc path here."
}

require_ubuntu_2404() {
    local id="" version=""
    [[ -r /etc/os-release ]] || die "/etc/os-release is unreadable; cannot identify the distribution."
    # shellcheck disable=SC1091
    id=$(. /etc/os-release && printf '%s' "${ID:-}")
    # shellcheck disable=SC1091
    version=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
    [[ $id == ubuntu && $version == 24.04 ]] ||
        die "unsupported host ($id $version): this installer is Ubuntu 24.04 only. Use the Docker path from DEPLOYMENT.md elsewhere."
    if [[ -e /.dockerenv ]]; then
        die "running inside a container; the bare-metal path assumes a host. Use DEPLOYMENT.md's Docker Compose setup instead."
    fi
    if grep -qaE '(docker|containerd|kubepods|lxc|snapshot)' /proc/1/cgroup 2>/dev/null; then
        die "PID 1 sits in a container cgroup; refusing to install."
    fi
    ok "Ubuntu 24.04 on systemd, not containerised"
}

require_build_inputs() {
    [[ -f $SOURCE_ROOT/TrustForge.Api/TrustForge.Api.csproj ]] ||
        die "$SOURCE_ROOT has no TrustForge.Api project; pass --source-dir."
    [[ -f $SCRIPT_DIR/trustforge.service && -f $SCRIPT_DIR/trustforge.env.example ]] ||
        die "trustforge.service / trustforge.env.example are missing beside install.sh."
    if [[ ! -d $TECH_LIBRARY ]]; then
        bad "no TechnitiumLibrary checkout at $TECH_LIBRARY (Dockerfile:1-12 compiles against it)."
        probe "clone it beside $SOURCE_ROOT, or pass --technitium-library DIR."
        return 0
    fi
    local missing=0 name
    for name in "${LIB_PROJECTS[@]}"; do
        [[ -f $TECH_LIBRARY/$name/$name.csproj ]] || { bad "missing $TECH_LIBRARY/$name/$name.csproj"; missing=1; }
    done
    [[ $missing -eq 0 ]] && ok "TechnitiumLibrary present with all three projects"
    [[ -f $SOURCE_ROOT/Dockerfile ]] || hint "$SOURCE_ROOT/Dockerfile is absent; the build mirrors it step for step."
    return 0
}

occupied_by() {
    local who
    who=$(port_pids "$1" "$2")
    printf '%s' "${who:-an unidentified process}"
}

check_ports() {
    # Port 53 cannot be moved: DnsServer.cs:464-599 exposes no address/port variable and
    # DnsServerHostedService.cs:24 passes throwIfBindFails:true, so a failed bind kills the API.
    local proto label
    for proto in t u; do
        label=tcp
        [[ $proto == u ]] && label=udp
        if port_listening "$proto" "$DNS_PORT"; then
            bad "port 53/$label is taken by $(occupied_by "$proto" "$DNS_PORT")"
        else
            ok "port 53/$label is free"
        fi
    done
    # The console and the API are TCP-only listeners.
    if port_listening t "$DNS_UI_PORT"; then
        bad "port $DNS_UI_PORT/tcp is taken by $(occupied_by t "$DNS_UI_PORT")"
    else
        ok "port $DNS_UI_PORT/tcp is free"
    fi
    if port_listening t "$API_PORT"; then
        bad "port $API_PORT/tcp is taken by $(occupied_by t "$API_PORT")"
    else
        ok "port $API_PORT/tcp is free"
    fi
}

explain_port_53_remediation() {
    port_listening t "$DNS_PORT" || port_listening u "$DNS_PORT" || return 0
    cat >&2 <<'EOF'

Port 53 must be free: the embedded DNS engine binds it on every start and cannot be told to use
another port. This installer will not touch your resolver configuration. To free it yourself:

  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNSStubListener=no\n' >/etc/systemd/resolved.conf.d/10-trustforge.conf
  systemctl restart systemd-resolved
  # 127.0.0.53:53 disappears with the stub listener, and /etc/resolv.conf usually symlinks to a
  # stub file that then stops working:
  #   rm -f /etc/resolv.conf && printf 'nameserver 127.0.0.1\n' >/etc/resolv.conf
  # (TrustForge itself will answer recursive queries from this host once it is running.)

If the occupant is not systemd-resolved, identify it directly: ss -Hltnp 'sport = :53'
EOF
}

check_docker_coexistence() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local names volumes
        names=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i trustforge || true)
        volumes=$(docker volume ls -q 2>/dev/null | grep -i trustforge || true)
        if [[ -n $names || -n $volumes ]]; then
            bad "a Docker deployment of TrustForge exists here (containers: ${names:-none}; volumes: ${volumes:-none})."
            probe "it holds port 53 and the same paths; this installer will not share them."
            probe "remove it first: docker compose down  (add -v only if destroying the volumes is intended)."
        else
            ok "docker is present but no TrustForge containers or volumes"
        fi
    else
        ok "no reachable Docker daemon to conflict with"
    fi
}

check_postgres_host() {
    if [[ $SKIP_POSTGRES -eq 1 ]]; then
        ok "--skip-postgres: an external cluster is assumed"
        [[ -n $DB_PASSWORD_FILE ]] ||
            hint "--skip-postgres normally pairs with --db-password-file; without it a password is generated for the connection string you must already own."
        return 0
    fi
    if command -v pg_lsclusters >/dev/null 2>&1 && pg_lsclusters -h 2>/dev/null | grep -q .; then
        bad "this host already has a PostgreSQL cluster:"
        probe "$(pg_lsclusters -h 2>/dev/null | head -3 | tr '\n' ' ')"
        probe "install into it with --skip-postgres plus your own role, or decommission it deliberately first."
        return 0
    fi
    ok "no existing PostgreSQL cluster; $PG_VERSION will come from PGDG"
}

check_resources_and_time() {
    local mem_kb avail_kb
    mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || printf '0')
    if ((mem_kb >= 2 * 1024 * 1024)); then
        ok "memory $((mem_kb / 1024 / 1024)) GiB"
    else
        bad "only $((mem_kb / 1024)) MiB RAM; PostgreSQL and the DNS engine together need at least 2 GiB."
    fi

    avail_kb=$(df -Pk /var 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -n $avail_kb ]] && ((avail_kb >= 10 * 1024 * 1024)); then
        ok "free space on /var $((avail_kb / 1024 / 1024)) GiB"
    else
        hint "under 10 GiB free on /var: the database, certificate artifacts and DNS logs all grow there."
    fi

    if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -qx true; then
        ok "clock synchronised (DNSSEC validation is on by default)"
    elif command -v chronyc >/dev/null 2>&1 && chronyc tracking >/dev/null 2>&1; then
        ok "chrony is tracking (DNSSEC validation is on by default)"
    else
        hint "no time synchronisation detected: DNSSEC validation, ACME timestamps and certificate validity all depend on the clock."
    fi

    if command -v apparmor_status >/dev/null 2>&1; then
        hint "AppArmor is active; a denial on /opt/dotnet or the cluster shows up as EACCES in journalctl -u trustforge."
    fi
}

check_outbound() {
    local url
    for url in "$DOTNET_INSTALL_URL" https://api.nuget.org/v3/index.json \
        "https://apt.postgresql.org/pub/repos/apt/dists/noble-pgdg/Release"; do
        if curl -fsS --max-time 20 -o /dev/null "$url"; then
            ok "reachable: $url"
        else
            bad "unreachable: $url. The build runs on this host and needs it."
        fi
    done
    if [[ -n $OIDC_AUTHORITY ]]; then
        if curl -fsS --max-time 20 -o /dev/null "$OIDC_AUTHORITY/.well-known/openid-configuration"; then
            ok "OIDC discovery answers for $OIDC_AUTHORITY"
        else
            hint "OIDC discovery failed for $OIDC_AUTHORITY: the API will start, and every token check will then fail."
        fi
    fi
}

check_dns_seed_state() {
    if [[ -e $DNS_CONFIG_DIR/webservice.config || -e $DNS_CONFIG_DIR/auth.config ]]; then
        hint "DNS config already exists in $DNS_CONFIG_DIR, so the DNS_SERVER_* block in $ENV_FILE is inert for it."
        [[ $RESEED_DNS -eq 1 ]] && probe "--reseed-dns: the existing directory will be archived before the first start."
    else
        ok "no DNS config yet; the hardened DNS_SERVER_* values will be honoured at first start"
    fi
}

run_preflight() {
    log "preflight (read-only)"
    require_ubuntu_2404
    require_build_inputs
    check_ports
    check_docker_coexistence
    check_postgres_host
    check_resources_and_time
    check_outbound
    check_dns_seed_state
    log "preflight: $pass passed, $fail failed, $note noted"
    if ((fail > 0)); then
        explain_port_53_remediation
        die "preflight found $fail blocking problem(s); nothing on this host was changed."
    fi
}

print_plan() {
    cat <<EOF

Ordered mutations that would follow:
  1  apt-get install ca-certificates curl gnupg git openssh-client openssl libicu74 dnsutils
  2  add the PGDG apt source (signed-by /etc/apt/keyrings/postgresql.gpg), install postgresql-$PG_VERSION,
     start postgresql@$PG_VERSION-$PG_CLUSTER
  3  fetch $MS_REPO_DEB for libmsquic; failure here only costs DoQ/DoH3
  4  install the ASP.NET Core $DOTNET_CHANNEL runtime into $RUNTIME_ROOT (permanent), link
     /usr/bin/dotnet only when absent
  5  install the .NET SDK into $BUILD_ROOT/dotnet-sdk, build the three TechnitiumLibrary projects,
     publish TrustForge.Api there, then rm -rf $BUILD_ROOT (no SDK, no NuGet cache, no sources left)
  6  stage the publish output as $APP_ROOT/app/<release-id>, flip $APP_ROOT/app/current atomically
  7  useradd --system $SERVICE_USER; create $DNS_CONFIG_DIR $DATA_ROOT $ARTIFACT_DIR $DNS_LOG_DIR
     (0750 $SERVICE_USER) and $SECRETS_DIR (0750 root:$SERVICE_USER, files 0640) - the secrets
     directory stays out of the unit's ReadWritePaths so it remains read-only under the host
  8  generate $ENV_FILE (0600) from trustforge.env.example, substituting the database password and
     OIDC values; write $SECRETS_DIR/dns-admin-password
  9  CREATE ROLE / CREATE DATABASE over the unix socket; verify pg_hba.conf, never rewrite it
 10  dotnet TrustForge.dll --migrate in the foreground as $SERVICE_USER
 11  install $UNIT_FILE, daemon-reload, systemctl enable --now
 12  assert the sockets that actually exist: 53 tcp+udp bound, $DNS_UI_PORT and $API_PORT loopback-only
EOF
}

ensure_apt_prerequisites() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update || die "apt-get update failed; no packages could be installed."
    apt-get -qq -y --no-install-recommends install \
        ca-certificates curl gnupg git openssh-client openssl iproute2 util-linux coreutils sed ||
        die "the base toolchain could not be installed."
    if ! ldconfig -p | grep -q libicu; then
        log "installing ICU (the runtime needs it)"
        apt-get -qq -y --no-install-recommends install libicu74 ||
            die "libicu74 is not installable here; .NET cannot run without an ICU build."
    fi
    apt-get -qq -y --no-install-recommends install dnsutils || hint "dnsutils missing: BAREMETAL.md's dig checks will not run."
}

install_postgres_repo() {
    [[ $SKIP_POSTGRES -eq 1 ]] && { log "--skip-postgres: not adding the PGDG source"; return 0; }
    install -d -m 0755 /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/postgresql.gpg ]]; then
        curl -fsS --max-time 90 "$PGDG_KEY_URL" | gpg --dearmor --yes -o /etc/apt/keyrings/postgresql.gpg ||
            die "could not dearmor the PGDG signing key."
        chmod 0644 /etc/apt/keyrings/postgresql.gpg
    fi
    printf 'deb [signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt noble-pgdg main\n' \
        >/etc/apt/sources.list.d/pgdg.list
    chmod 0644 /etc/apt/sources.list.d/pgdg.list
    # Falling back to Ubuntu's PostgreSQL is refused on purpose: every validation record in this
    # repository (docker-compose.yml, HSM-KMS-HA-EVALUATION.md) is against 17.
    apt-get -qq update || die "the PGDG index could not be fetched; not falling back to Ubuntu's older PostgreSQL."
    apt-cache show "postgresql-$PG_VERSION" >/dev/null 2>&1 || die "postgresql-$PG_VERSION is not available from PGDG."
    apt-get -qq -y --no-install-recommends install "postgresql-$PG_VERSION" || die "postgresql-$PG_VERSION failed to install."
    systemctl enable --now "postgresql@$PG_VERSION-$PG_CLUSTER" >>"$INSTALL_LOG" 2>&1 ||
        systemctl start "postgresql@$PG_VERSION-$PG_CLUSTER" >>"$INSTALL_LOG" 2>&1 ||
        die "the PostgreSQL $PG_VERSION cluster did not start; see $INSTALL_LOG"
    wait_for "PostgreSQL to accept connections" 20 runuser -u postgres -- pg_isready -q ||
        die "PostgreSQL is installed but not answering."
}

install_libmsquic() {
    if curl -fsSL --max-time 120 "$MS_REPO_DEB" -o "$BUILD_ROOT/packages-microsoft-prod.deb" &&
        dpkg -i "$BUILD_ROOT/packages-microsoft-prod.deb" >>"$INSTALL_LOG" 2>&1 &&
        apt-get -qq update >>"$INSTALL_LOG" 2>&1 &&
        apt-get -qq -y --no-install-recommends install libmsquic >>"$INSTALL_LOG" 2>&1; then
        ok "libmsquic installed (DNS-over-QUIC / DoH3 available if configured)"
    else
        hint "libmsquic could not be installed. It is inert until DoQ is enabled (DnsServer.cs:6476-6485), so everything else works."
    fi
}

install_dotnet_runtime() {
    [[ -s $BUILD_ROOT/dotnet-install.sh ]] ||
        curl -fsSL --max-time 120 "$DOTNET_INSTALL_URL" -o "$BUILD_ROOT/dotnet-install.sh" ||
        die "could not fetch $DOTNET_INSTALL_URL"
    if ! "$RUNTIME_ROOT/dotnet" --list-runtimes 2>/dev/null | grep -q "Microsoft.AspNetCore.App $DOTNET_CHANNEL"; then
        log "installing the ASP.NET Core $DOTNET_CHANNEL runtime into $RUNTIME_ROOT"
        bash "$BUILD_ROOT/dotnet-install.sh" -c "$DOTNET_CHANNEL" --runtime aspnetcore --no-path \
            --install-dir "$RUNTIME_ROOT" >>"$INSTALL_LOG" 2>&1 ||
            die "the ASP.NET Core runtime install failed; see $INSTALL_LOG"
    fi
    [[ -e /usr/bin/dotnet ]] || ln -s "$RUNTIME_ROOT/dotnet" /usr/bin/dotnet
    ok "ASP.NET Core $DOTNET_CHANNEL runtime available"
}

build_and_stage_release() {
    local release_id=$1
    local sdk_dir=$BUILD_ROOT/dotnet-sdk publish_dir=$BUILD_ROOT/publish
    local -a buildenv=(
        "DOTNET_ROOT=$sdk_dir"
        "PATH=$sdk_dir:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "NUGET_PACKAGES=$BUILD_ROOT/nuget"
        "DOTNET_CLI_HOME=$BUILD_ROOT/cli-home"
        "HOME=$BUILD_ROOT/cli-home"
        "DOTNET_CLI_TELEMETRY_OPTOUT=1"
        "DOTNET_NOLOGO=1"
    )

    # The SDK lives only under $BUILD_ROOT, which the EXIT trap deletes: a host holding the CA
    # account key and the SSH deployer keys should not keep a compiler toolchain or a source tree.
    bash "$BUILD_ROOT/dotnet-install.sh" -c "$DOTNET_CHANNEL" --no-path --install-dir "$sdk_dir" \
        >>"$INSTALL_LOG" 2>&1 || die "the .NET SDK install failed; see $INSTALL_LOG"

    log "building on this host (Dockerfile:6-12 equivalent); output in $INSTALL_LOG"
    # shellcheck disable=SC2016  # the inner script expands its positional parameters, not these
    env "${buildenv[@]}" bash -euo pipefail -c '
        lib=$1; src=$2; out=$3; logfile=$4
        for name in TechnitiumLibrary.ByteTree TechnitiumLibrary.Net TechnitiumLibrary.Security.OTP; do
            dotnet build "$lib/$name/$name.csproj" -c Release >>"$logfile" 2>&1
        done
        dotnet publish "$src/TrustForge.Api/TrustForge.Api.csproj" -c Release -o "$out" >>"$logfile" 2>&1
    ' _ "$TECH_LIBRARY" "$SOURCE_ROOT" "$publish_dir" "$INSTALL_LOG" ||
        die "the build or publish failed. The existing release and its 'current' symlink are untouched; see $INSTALL_LOG"
    [[ -f $publish_dir/TrustForge.dll ]] || die "publish produced no TrustForge.dll; see $INSTALL_LOG"

    install -d -m 0755 "$APP_ROOT/app/$release_id"
    cp -a "$publish_dir/." "$APP_ROOT/app/$release_id/"
    ln -sfn "$APP_ROOT/app/$release_id" "$APP_ROOT/app/.current.new"
    mv -T "$APP_ROOT/app/.current.new" "$APP_ROOT/app/current"
    chmod -R a-w "$APP_ROOT/app/$release_id"
    ok "release $release_id staged and 'current' flipped"
}

prune_releases() {
    local current_dir dir
    current_dir=$(readlink -f "$APP_ROOT/app/current" 2>/dev/null || printf '')
    find "$APP_ROOT/app" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | awk 'NR>3 {print $2}' |
        while read -r dir; do
            [[ $dir == "$current_dir" ]] && continue
            log "pruning superseded release $(basename "$dir")"
            chmod -R u+w "$dir" 2>/dev/null || true
            rm -rf "$dir"
        done
}

create_service_account() {
    id -u "$SERVICE_USER" >/dev/null 2>&1 && { vlog "service account $SERVICE_USER already exists"; return 0; }
    useradd --system --home-dir "$APP_ROOT" --shell /usr/sbin/nologin --user-group "$SERVICE_USER"
    vlog "created the system account $SERVICE_USER"
}

create_directories() {
    install -d -m 0755 -o root -g root "$APP_ROOT" "$APP_ROOT/app" "$CONF_ROOT"
    install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" \
        "$DNS_CONFIG_DIR" "$DATA_ROOT" "$ARTIFACT_DIR" "$DNS_LOG_DIR"
    # root:$SERVICE_USER 0750, files inside 0640: the service may read its secrets and never write
    # them, and this directory is not in the unit's ReadWritePaths.
    install -d -m 0750 -o root -g "$SERVICE_USER" "$SECRETS_DIR"
}

# A generated or operator-supplied value lands inside a sed replacement and then inside systemd and
# .NET configuration, so metacharacters are refused here rather than escaped through three layers.
assert_shell_safe_value() {
    local label=$1 value=$2
    local unsafe='[^A-Za-z0-9._:/?%@+-]'
    [[ -n $value ]] || die "$label is empty."
    [[ $value =~ $unsafe ]] &&
        die "$label contains a character this script will not interpolate (=, &, |, \\, space, quotes...). Restrict it to A-Z a-z 0-9 . _ : / ? % @ + -"
    return 0
}

generate_env_file() {
    local dns_admin_password=$1

    if [[ ! -f $SECRETS_DIR/dns-admin-password ]]; then
        (umask 077; printf '%s\n' "$dns_admin_password" >"$SECRETS_DIR/dns-admin-password")
        chown root:"$SERVICE_USER" "$SECRETS_DIR/dns-admin-password"
        chmod 0640 "$SECRETS_DIR/dns-admin-password"
        log "the DNS console administrator password is in $SECRETS_DIR/dns-admin-password (it is only read on first boot)"
    else
        hint "$SECRETS_DIR/dns-admin-password already exists and was kept; DNS_SERVER_ADMIN_PASSWORD_FILE does not rotate an existing auth.config."
    fi

    if [[ -e $ENV_FILE ]]; then
        install -m 0600 -o root -g root "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"
        log "existing $ENV_FILE backed up beside it"
    else
        install -m 0600 -o root -g root "$SCRIPT_DIR/trustforge.env.example" "$ENV_FILE"
    fi
    if grep -q '__TF_' "$ENV_FILE"; then
        sed -i "s|__TF_DB_PASSWORD__|$DB_PASSWORD|g; s|__TF_OIDC_AUTHORITY__|$OIDC_AUTHORITY|g; s|__TF_OIDC_AUDIENCE__|$OIDC_AUDIENCE|g" "$ENV_FILE"
    fi
    if grep -q '__TF_' "$ENV_FILE"; then
        die "an unexpanded sentinel remains in $ENV_FILE."
    fi
    chmod 0600 "$ENV_FILE"
    chown root:root "$ENV_FILE"
}

record_existing_decisions() {
    [[ -f $STATE_FILE ]] || return 0
    log "a previous installation is recorded in $STATE_FILE:"
    grep -E '"(installedAt|release|postgres|secretsDir|apiBind)"' "$STATE_FILE" | sed 's/^/       /'
    probe "those decisions are reused; the role, the password and the DNS seed are not recreated."
}

provision_postgres() {
    [[ $SKIP_POSTGRES -eq 1 ]] && { log "--skip-postgres: role, database and pg_hba are the operator's responsibility"; return 0; }

    local hba lax role_exists="" roles dbs
    # An empty result must not be read as "the role exists": that would fall through to the
    # "role already exists" error below when the real problem is an unreachable cluster.
    roles=$(runuser -u postgres -- psql -tAc "SELECT count(*) FROM pg_roles WHERE rolname='$SERVICE_USER'") ||
        die "cannot query the cluster as the postgres user; check that the cluster is running."
    if [[ $roles == 0 ]]; then
        runuser -u postgres -- psql -v ON_ERROR_STOP=1 -v pw="$DB_PASSWORD" \
            -c "CREATE ROLE $SERVICE_USER LOGIN PASSWORD :'pw'" >>"$INSTALL_LOG" 2>&1 ||
            die "could not create the '$SERVICE_USER' role."
        vlog "created the $SERVICE_USER role"
    else
        role_exists=yes
    fi

    dbs=$(runuser -u postgres -- psql -tAc "SELECT count(*) FROM pg_database WHERE datname='$SERVICE_USER'") ||
        die "cannot query the cluster as the postgres user."
    if [[ $dbs == 0 ]]; then
        runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE $SERVICE_USER OWNER $SERVICE_USER" >>"$INSTALL_LOG" 2>&1 ||
            die "could not create the '$SERVICE_USER' database."
        vlog "created the $SERVICE_USER database"
    fi

    if [[ -n $role_exists ]]; then
        # CREATE ROLE is skipped, so the password in hand was never applied to the role. That is
        # only harmless when it came from the record the role was originally created with.
        if [[ $DB_PASSWORD_ORIGIN == recorded ]]; then
            ok "the '$SERVICE_USER' role already exists and the recorded password was reused"
        else
            die "the '$SERVICE_USER' role already exists but this run did not obtain its password. The connection string would not authenticate. Re-run with --db-password-file pointing at the role's real password, or set it first: sudo -u postgres psql -c \"ALTER ROLE $SERVICE_USER PASSWORD '<from that file>'\"."
        fi
    fi

    # pg_hba.conf is first-match: an appended stricter line would not override an existing lax one,
    # and rewriting it in place is how operators lock themselves out of their own cluster.
    hba=$(runuser -u postgres -- psql -tAc "SHOW hba_file")
    lax=$(grep -E '^[[:space:]]*host[[:space:]]' "$hba" 2>/dev/null |
        grep -E '[[:space:]](trust|md5|password)([[:space:]]|$)' || true)
    if [[ -n $lax ]]; then
        printf 'ERROR: %s grants weak authentication; fix it yourself, then run: sudo -u postgres psql -c "SELECT pg_reload_conf()"\n' "$hba" >&2
        printf '%s\n' "$lax" | head -5 >&2
        die "refusing to rewrite pg_hba.conf."
    fi
    ok "PostgreSQL role, database and authentication method checked"
}

run_migrations() {
    local line key val
    # This file is systemd EnvironmentFile syntax, not shell: the connection string contains ';',
    # which bash would execute as separate commands, so it is parsed rather than sourced.
    while IFS= read -r line; do
        [[ -z $line || $line == \#* ]] && continue
        key=${line%%=*}
        [[ $key == "$line" ]] && continue
        val=${line#*=}
        val=${val%$'\r'}
        val=${val#\"}; val=${val%\"}
        export "$key=$val"
    done <"$ENV_FILE"
    runuser --preserve-environment -u "$SERVICE_USER" -- \
        "$RUNTIME_ROOT/dotnet" "$APP_ROOT/app/current/TrustForge.dll" --migrate ||
        die "migrations failed; resolve the database problem before the service starts."
    vlog "migrations applied"
}

install_unit() {
    install -m 0644 -o root -g root "$SCRIPT_DIR/trustforge.service" "$UNIT_FILE"
    local verify
    verify=$(systemd-analyze verify "$UNIT_FILE" 2>&1 || true)
    if [[ -n $verify ]]; then
        printf '%s\n' "$verify" >>"$INSTALL_LOG"
        hint "systemd-analyze verify reported the following (see $INSTALL_LOG):"
        printf '%s\n' "$verify" | sed 's/^/        /'
    fi
    systemctl daemon-reload
    systemctl enable --now trustforge
}

verify_runtime() {
    local ui_listener=""
    if ! wait_for "the API to answer /health/ready" 40 curl -fsS --max-time 5 "http://127.0.0.1:$API_PORT/health/ready"; then
        printf 'Last log lines:\n' >&2
        journalctl -u trustforge -n 40 --no-pager >&2 || true
        die "the service never became ready."
    fi
    if ! { port_listening t "$DNS_PORT" && port_listening u "$DNS_PORT"; }; then
        printf 'ERROR: the DNS engine is not listening on 53.\n' >&2
        die "check journalctl -u trustforge."
    fi
    if port_exposed_broadly "$DNS_UI_PORT"; then
        printf 'ERROR: the DNS console is reachable on every interface, not 127.0.0.1:%s.\n' "$DNS_UI_PORT" >&2
        printf 'DNS_SERVER_WEB_SERVICE_LOCAL_ADDRESSES only applies while webservice.config does not exist.\n' >&2
        printf 'Read the re-seed procedure in BAREMETAL.md before changing %s.\n' "$ENV_FILE" >&2
        return 1
    fi
    if port_exposed_broadly "$API_PORT"; then
        printf 'ERROR: the API is exposed on every interface instead of 127.0.0.1:%s.\n' "$API_PORT" >&2
        printf 'ASPNETCORE_URLS is not frozen, so fix %s and restart.\n' "$ENV_FILE" >&2
        return 1
    fi
    ui_listener=$(ss -Hltn "sport = :$DNS_UI_PORT" | awk '{print $4}' | head -1)
    ok "runtime sockets as intended: 53 tcp+udp, console ${ui_listener:-none}, API 127.0.0.1:$API_PORT"
}

write_state() {
    local release_id=$1
    cat >"$STATE_FILE" <<EOF
{
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "release": "$release_id",
  "sourceRoot": "$SOURCE_ROOT",
  "technitiumLibrary": "$TECH_LIBRARY",
  "secretsDir": "$SECRETS_DIR",
  "dnsConfigDir": "$DNS_CONFIG_DIR",
  "artifactDir": "$ARTIFACT_DIR",
  "postgres": "$([[ $SKIP_POSTGRES -eq 1 ]] && printf external || printf local-%s "$PG_VERSION")",
  "apiBind": "127.0.0.1:$API_PORT",
  "dnsConsoleBind": "127.0.0.1:$DNS_UI_PORT",
  "dnsConfigSeeded": true
}
EOF
    chmod 0640 "$STATE_FILE"
    chown root:"$SERVICE_USER" "$STATE_FILE"
}

reseed_dns_config() {
    [[ $RESEED_DNS -eq 1 ]] || return 0
    [[ -d $DNS_CONFIG_DIR ]] || return 0
    [[ -n $(ls -A "$DNS_CONFIG_DIR" 2>/dev/null) ]] || return 0
    local archive
    archive=$DNS_CONFIG_DIR.pre-reseed-$(date +%Y%m%d%H%M%S)
    confirm "Archiving $DNS_CONFIG_DIR to $archive discards zones, the DNS-01 challenge zone, API tokens and locally created users. Continue?" ||
        die "aborted before touching the DNS config."
    systemctl stop trustforge 2>/dev/null || true
    mv "$DNS_CONFIG_DIR" "$archive"
    install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DNS_CONFIG_DIR"
    log "the previous DNS config is preserved in $archive"
}

main() {
    parse_args "$@"
    resolve_library_dir

    if [[ $CHECK_ONLY -eq 0 && $DRY_RUN -eq 0 ]]; then
        while [[ -z $OIDC_AUTHORITY ]]; do
            printf 'HTTPS OIDC issuer URL: ' >/dev/tty
            IFS= read -r OIDC_AUTHORITY </dev/tty || OIDC_AUTHORITY=
        done
        while [[ -z $OIDC_AUDIENCE ]]; do
            printf 'TrustForge API audience: ' >/dev/tty
            IFS= read -r OIDC_AUDIENCE </dev/tty || OIDC_AUDIENCE=
        done
        [[ $OIDC_AUTHORITY == https://* ]] ||
            die "the OIDC authority must start with https:// (Program.cs:85-94 rejects anything else outside Development)."
        assert_shell_safe_value "the OIDC authority" "$OIDC_AUTHORITY"
        assert_shell_safe_value "the OIDC audience" "$OIDC_AUDIENCE"
    fi

    require_root_and_systemd
    run_preflight
    [[ $CHECK_ONLY -eq 1 ]] && { log "--check-only: stopping, nothing changed."; return 0; }
    [[ $DRY_RUN -eq 1 ]] && { print_plan; log "--dry-run: nothing changed."; return 0; }

    # create_directories() re-applies this later; it must happen before the first write to
    # $INSTALL_LOG, which lives under $APP_ROOT and is the redirect target of the build step.
    install -d -m 0755 "$APP_ROOT"
    install -d -m 0700 "$BUILD_ROOT"
    trap 'rm -rf "$BUILD_ROOT"' EXIT
    : >>"$INSTALL_LOG" || die "cannot write $INSTALL_LOG."

    record_existing_decisions
    reseed_dns_config

    local release_id
    release_id="$(git -C "$SOURCE_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'local')-$(date +%Y%m%d%H%M%S)"

    log "installing TrustForge $release_id; build and service output append to $INSTALL_LOG"
    ensure_apt_prerequisites
    install_postgres_repo
    install_libmsquic
    install_dotnet_runtime
    build_and_stage_release "$release_id"
    create_service_account
    create_directories

    # After ensure_apt_prerequisites (openssl) and create_directories (the secrets directory).
    local dns_admin_password
    dns_admin_password=$(openssl rand -hex 16)
    if [[ -n $DB_PASSWORD_FILE ]]; then
        [[ -r $DB_PASSWORD_FILE ]] || die "$DB_PASSWORD_FILE is not readable."
        DB_PASSWORD=$(tr -d '\r\n' <"$DB_PASSWORD_FILE")
        DB_PASSWORD_ORIGIN="file"
    elif [[ -s $SECRETS_DIR/database-password ]]; then
        DB_PASSWORD=$(tr -d '\r\n' <"$SECRETS_DIR/database-password")
        DB_PASSWORD_ORIGIN="recorded"
        log "reusing the database password recorded in $SECRETS_DIR/database-password"
    else
        DB_PASSWORD=$(openssl rand -hex 24)
        DB_PASSWORD_ORIGIN="generated"
        (umask 077; printf '%s\n' "$DB_PASSWORD" >"$SECRETS_DIR/database-password")
        chown root:"$SERVICE_USER" "$SECRETS_DIR/database-password"
        chmod 0640 "$SECRETS_DIR/database-password"
        log "generated the database password into $SECRETS_DIR/database-password; rotate it per OPERATIONS.md section 4."
    fi
    assert_shell_safe_value "the database password" "$DB_PASSWORD"

    generate_env_file "$dns_admin_password"
    provision_postgres
    run_migrations
    install_unit
    verify_runtime
    write_state "$release_id"
    prune_releases

    log "TrustForge is running. DNS console 127.0.0.1:$DNS_UI_PORT, API 127.0.0.1:$API_PORT (put TLS in front)."
    log "Work through the smoke checklist in BAREMETAL.md before trusting this host, especially the reboot step."
}

main "$@"
