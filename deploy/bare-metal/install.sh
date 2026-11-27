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
FREE_PORT_53=0
ALLOW_UNREACHABLE_OIDC=0
WITH_STEP_CA=0
USE_APT_STEP_CA=0
WITH_LOCAL_OIDC=0
WITH_ACME_DNS=0
WITH_SELF_TLS=0
SETUP_ZONE=trustforge.internal
API_DOMAIN=
CA_DOMAIN=
OIDC_DOMAIN=
ADMIN_EMAIL=

# source            a repository checkout, built on this host (the original behaviour)
# package-extracted an unpacked release package, run as ./deploy/bare-metal/install.sh from inside it
# package-file      a release archive handed over with --package-file, extracted here
INSTALL_MODE=source
PKG_ROOT=
PKG_TOP=
PKG_STAGE=
PACKAGE_FILE=
VALIDATE_PACKAGE=
SOURCE_DIR_GIVEN=0
LIBRARY_GIVEN=0
PKG_VERSION=unknown
PKG_GIT_SHA=unknown
PKG_GIT_SHA_SHORT=unknown
PKG_LIBRARY_SHA=unknown
# The unit and the env template always live beside install.sh: the package deliberately keeps the
# deploy/bare-metal depth so this seam resolves identically in a checkout and in an unpacked release.
DEPLOY_DIR=$SCRIPT_DIR

pass=0
fail=0
note=0

usage() {
    cat <<'EOF'
Usage: install.sh [OPTION]...

Installs TrustForge (API + embedded DNS engine) with PostgreSQL 17 on a physical or virtual
Ubuntu 24.04 host, with no container runtime. Run it as root. It refuses to run inside a container
and refuses to coexist with a Docker deployment of TrustForge.

Two inputs are supported, and the choice between them is explicit rather than guessed:

  from a source checkout   builds on this host, needing the .NET SDK, the sibling TechnitiumLibrary
                           checkout and outbound access to api.nuget.org (the default here)
  from a release package   installs the published application; --package-file ARCHIVE, or run this
                           script from inside an unpacked package. No compiler is installed and no
                           build happens, but the ASP.NET Core runtime is still fetched from dot.net

Options:
  --check-only             Run the read-only preflight, then exit. No build, no changes.
  --dry-run                Preflight, then print the ordered mutation plan and exit.
                           Issues read-only network probes; leaves no state behind.
  --yes                    Never prompt.
  --package-file ARCHIVE   Install from a release .tar.gz instead of building. Refuses the archive
                           until its member listing, modes, manifest and checksums have passed;
                           mutually exclusive with --source-dir and --technitium-library.
  --validate-package ARCHIVE
                           Check an archive the way an install would and exit. Never needs root,
                           never touches the host, never installs anything.
  --source-dir DIR         TrustForge checkout (default: this script's repository). Source mode only:
                           passing it with a package is an error, because a package inside a
                           checkout makes the install content ambiguous.
  --technitium-library DIR Library checkout, when it is not the sibling of --source-dir. Source mode
                           only, for the same reason.
  --skip-postgres          Do not install or provision PostgreSQL: the cluster, role, database and
                           password are yours already. Implies --db-password-file.
  --db-password-file FILE  File containing only the trustforge database password. Without it a
                           password is generated once and kept in /etc/trustforge/secrets.
  --oidc-authority URL     HTTPS OIDC issuer. Required unless --with-local-oidc is set.
  --oidc-audience NAME     TrustForge API audience (default with --with-local-oidc: trustforge-api).
  --allow-unreachable-oidc Allow installing even when OIDC discovery is unreachable right now.
  --free-port-53           Disable systemd-resolved stub listener if it holds port 53 and point
                           /etc/resolv.conf at TrustForge (127.0.0.1) once DNS is listening.
  --with-step-ca           Also install and start local Smallstep step-ca (ACME + CRL).
  --use-apt-step-ca        Use prebuilt step-ca from APT instead of building patched binary.
  --with-local-oidc        Also install local Keycloak OIDC provider (requires HTTPS proxy or Dev).
  --with-acme-dns          Also configure Technitium challenge zone, API token, and ACME worker.
  --with-self-tls          Also install local trustforge-certctl and Nginx HTTPS reverse proxy.
  --all-in-one             Enable --free-port-53 --with-step-ca --with-local-oidc --with-acme-dns --with-self-tls.
  --zone ZONE              Challenge DNS zone for --with-acme-dns (default: trustforge.internal).
  --api-domain FQDN        HTTPS domain for TrustForge API (default: api.<zone>).
  --ca-domain FQDN         HTTPS domain for local step-ca (default: ca.<zone>).
  --oidc-domain FQDN       HTTPS domain for local OIDC (default: id.<zone>).
  --admin-email EMAIL      ACME account and OIDC admin email (default: ops@<zone>).
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
    local proto=$1 port=$2 out
    # Captured then tested rather than piped into grep -q: this script runs with pipefail, and grep
    # -q closes the pipe on its first match, so ss can die of SIGPIPE and make an occupied port read
    # as free. Every one of these checks guards a precondition the installer must not get wrong.
    out=$(ss -Hl"${proto}n" "sport = :$port" 2>/dev/null || true)
    [[ -n $out ]]
}

port_exposed_broadly() {
    local port=$1 out
    out=$(ss -Hltn "sport = :$port" 2>/dev/null || true)
    grep -qE '(0\.0\.0\.0|\*):'"$port" <<<"$out"
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
            --source-dir) SOURCE_ROOT=${2:?--source-dir needs a path}; SOURCE_DIR_GIVEN=1; shift ;;
            --technitium-library) TECH_LIBRARY=${2:?--technitium-library needs a path}; LIBRARY_GIVEN=1; shift ;;
            --package-file) PACKAGE_FILE=${2:?--package-file needs an archive}; shift ;;
            --validate-package) VALIDATE_PACKAGE=${2:?--validate-package needs an archive}; shift ;;
            --db-password-file) DB_PASSWORD_FILE=${2:?--db-password-file needs a path}; shift ;;
            --oidc-authority) OIDC_AUTHORITY=${2:?--oidc-authority needs a URL}; shift ;;
            --oidc-audience) OIDC_AUDIENCE=${2:?--oidc-audience needs a name}; shift ;;
            --allow-unreachable-oidc) ALLOW_UNREACHABLE_OIDC=1 ;;
            --free-port-53) FREE_PORT_53=1 ;;
            --with-step-ca) WITH_STEP_CA=1 ;;
            --use-apt-step-ca) USE_APT_STEP_CA=1 ;;
            --with-local-oidc) WITH_LOCAL_OIDC=1 ;;
            --with-acme-dns) WITH_ACME_DNS=1 ;;
            --with-self-tls) WITH_SELF_TLS=1 ;;
            --all-in-one)
                FREE_PORT_53=1
                WITH_STEP_CA=1
                WITH_LOCAL_OIDC=1
                WITH_ACME_DNS=1
                WITH_SELF_TLS=1
                ;;
            --zone) SETUP_ZONE=${2:?--zone needs a domain}; shift ;;
            --api-domain) API_DOMAIN=${2:?--api-domain needs a hostname}; shift ;;
            --ca-domain) CA_DOMAIN=${2:?--ca-domain needs a hostname}; shift ;;
            --oidc-domain) OIDC_DOMAIN=${2:?--oidc-domain needs a hostname}; shift ;;
            --admin-email) ADMIN_EMAIL=${2:?--admin-email needs an email}; shift ;;
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

# Flat, single-level string keys only, read with sed: jq is not in the ubuntu:24.04 base image and
# this has to work on a host that has installed nothing yet. An unknown key yields an empty string,
# which every caller then rejects rather than trusting.
manifest_value() {
    local key=$1 file=$2
    # awk rather than `sed s:...:`: the pattern has to contain a literal colon, which is also what a
    # sed delimiter would be, and no delimiter choice is safe against the characters a JSON value may
    # hold. Matching the closing quote of the key name is what keeps "gitSha" from reading
    # "gitShaShort", and the single exit is what keeps a pipe out of it under pipefail.
    awk -v key="$key" '
        { p = index($0, "\"" key "\":")
          if (p > 0) {
              rest = substr($0, p + length(key) + 3)
              if (match(rest, /"[^"]*"/)) {
                  print substr(rest, RSTART + 1, RLENGTH - 2)
                  exit
              }
          }
        }' "$file"
}

# A release archive is bytes fetched from the internet that this script then reads as root, so the
# listing is judged before anything is written and the extracted tree is judged again afterwards.
# tar is told to drop ownership; the mode and type checks below are what stop a hostile member from
# becoming an arbitrary write, and nothing here trusts a count it did not just re-derive.
check_package_listing() {
    local archive=$1 names verbose top offenders big
    names=$(tar -tzf "$archive" 2>/dev/null) || { bad "$archive is not a readable gzip tar archive."; return 1; }
    verbose=$(tar -tvzf "$archive" 2>/dev/null || true)
    [[ -n $names ]] || { bad "$archive contains no members."; return 1; }

    top=$(head -1 <<<"$names")
    top=${top%%/*}
    [[ -n $top && $top != "$names" && ! $top =~ / ]] ||
        { bad "$archive has no single top-level directory."; return 1; }
    if grep -qE '^/|(^|/)\.\.(/|$)|[[:space:]]' <<<"$names"; then
        bad "archive member names include an absolute path, a .. component, or whitespace."
        return 1
    fi
    offenders=$(grep -v "^$top/" <<<"$names" || true)
    if [[ -n $offenders ]]; then
        bad "archive has members outside the single top-level directory $top/."
        head -3 <<<"$offenders" | sed 's/^/        /' >&2
        return 1
    fi
    if grep -qE '(^|/)(\.git|node_modules)(/|$)' <<<"$names"; then
        bad "archive carries a VCS or node_modules directory."
        return 1
    fi
    # A *.env here is the expanded runtime file from somebody else's host, which would carry their
    # real database password into this one; secrets and private keys are the same story with a key.
    if grep -qE '\.(env|pem|key|p12|pfx|credential)$|(^|/)secrets(/|$)' <<<"$names"; then
        bad "archive carries a file that can hold a secret (*.env, *.pem, *.key, secrets/)."
        return 1
    fi
    # Every mode test below collects its offenders into a variable and matches against a here-string.
    # `awk … | grep -q .` would be the shorter form and is wrong: grep exits at the first match, awk
    # then dies of SIGPIPE, pipefail turns that into a non-zero pipeline, and a hostile member
    # silently reads as "no member matched".
    local modes badmode
    modes=$(awk '{print $1}' <<<"$verbose")
    if grep -qE '^l|^b|^c|^p|^s' <<<"$modes"; then
        bad "archive carries a symlink, device, FIFO or shadow member; only files and directories install."
        return 1
    fi
    badmode=$(awk '{ m = $1
                     if (substr(m, 4, 1) ~ /[sS]/ || substr(m, 7, 1) ~ /[sS]/ || substr(m, 10, 1) ~ /[tT]/ ||
                         substr(m, 6, 1) ~ /[wW]/ || substr(m, 9, 1) ~ /[wW]/) print }' <<<"$verbose")
    if [[ -n $badmode ]]; then
        bad "archive carries a setuid, setgid, sticky, group-writable or world-writable member."
        head -3 <<<"$badmode" | sed 's/^/        /' >&2
        return 1
    fi
    # Sizes are field 3 of tar -tv. One oversized member is how a compressed archive turns into a
    # full /var/tmp, and nothing in a TrustForge publish output comes close to this bound.
    big=$(awk '$3 > 209715200 { print $3 " " $NF }' <<<"$verbose")
    if [[ -n $big ]]; then
        bad "archive carries a member over 200 MiB:"
        head -3 <<<"$big" | sed 's/^/        /' >&2
        return 1
    fi
    if ! grep -q '^\-rwxr-xr-x .*deploy/bare-metal/install\.sh$' <<<"$verbose"; then
        bad "archive's install.sh is not a mode 0755 regular file."
        return 1
    fi
    if ! grep -q '^\-rwxr-xr-x .*remote-helper/trustforge-certctl$' <<<"$verbose"; then
        bad "archive's remote-helper/trustforge-certctl is missing or not mode 0755."
        return 1
    fi
    PKG_TOP=$top
    return 0
}

check_package_tree() {
    # Argument is the package's own root directory (the one holding MANIFEST.json and app/).
    local p=$1 special secret
    local required=(
        MANIFEST.json SHA256SUMS README.md
        app/TrustForge.dll app/TrustForge.runtimeconfig.json app/TrustForge.deps.json
        app/DnsServerCore.dll app/TechnitiumLibrary.Net.dll
        app/www/index.html app/dohwww/index.html app/named.root app/root-anchors.xml
        deploy/bare-metal/install.sh deploy/bare-metal/trustforge.service
        deploy/bare-metal/trustforge.env.example
        deploy/bare-metal/common.sh deploy/bare-metal/setup-step-ca.sh
        deploy/bare-metal/setup-oidc.sh deploy/bare-metal/setup-acme-dns.sh
        deploy/bare-metal/install-target-helper.sh deploy/bare-metal/setup-nginx-tls.sh
        deploy/bare-metal/keycloak/trustforge-dev-realm.json
        remote-helper/trustforge-certctl remote-helper/README.md
        docs/BAREMETAL.md docs/BARE-METAL-GUIDE.md
    )
    local missing=0 name
    for name in "${required[@]}"; do
        [[ -e $p/$name ]] || { bad "the package has no $name"; missing=1; }
    done
    [[ $missing -eq 0 ]] || return 1

    # A self-contained publish would work here too, but it is not what this repository ships, it
    # changes the runtime install requirement, and silently mixing the two is how a host ends up
    # running an artifact nobody documented.
    if [[ -e $p/app/libcoreclr.so ]]; then
        bad "the package is self-contained; this installer ships framework-dependent releases only."
        return 1
    fi
    grep -q 'Microsoft.AspNetCore.App' "$p/app/TrustForge.runtimeconfig.json" ||
        { bad "app/TrustForge.runtimeconfig.json does not reference ASP.NET Core; not a TrustForge publish output."; return 1; }
    [[ -x $p/deploy/bare-metal/install.sh ]] ||
        { bad "the package's install.sh is not executable."; return 1; }

    special=$(find "$p" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print 2>/dev/null)
    if [[ -n $special ]]; then
        bad "the extracted package contains a symlink or special file:"
        head -3 <<<"$special" | sed 's/^/        /' >&2
        return 1
    fi
    secret=$(find "$p" \( -name '*.env' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' \
        -o -path '*/secrets/*' \) -print 2>/dev/null)
    if [[ -n $secret ]]; then
        bad "the extracted package contains a file that can hold a secret:"
        head -3 <<<"$secret" | sed 's/^/        /' >&2
        return 1
    fi
    if grep -rlqI -e $'\r' "$p/deploy" "$p/remote-helper" 2>/dev/null; then
        bad "CRLF in the package's deploy/ or remote-helper/ directory: systemd rejects the unit and scripts/env templates break."
        return 1
    fi
    local token n
    for token in __TF_DB_PASSWORD__ __TF_OIDC_AUTHORITY__ __TF_OIDC_AUDIENCE__; do
        n=$(grep -c -- "$token" "$p/deploy/bare-metal/trustforge.env.example" || true)
        [[ $n == 1 ]] || { bad "trustforge.env.example does not carry $token exactly once."; return 1; }
    done

    # The archive's own SHA256SUMS covers the members it shipped with. A mismatch is either corruption
    # or a package assembled from more than one build; either way the bytes here are not the bytes
    # that were published.
    if ! (cd "$p" && sha256sum -c --quiet SHA256SUMS); then
        bad "SHA256SUMS does not verify inside the extracted package."
        return 1
    fi
    return 0
}

read_package_manifest() {
    local root=$1 file version sha sha_short lib_sha product format
    file=$root/MANIFEST.json
    [[ -r $file ]] || { bad "the package has no readable MANIFEST.json."; return 1; }
    product=$(manifest_value product "$file")
    format=$(manifest_value packageFormat "$file")
    version=$(manifest_value version "$file")
    sha=$(manifest_value gitSha "$file")
    sha_short=$(manifest_value gitShaShort "$file")
    lib_sha=$(manifest_value libraryGitSha "$file")
    [[ $product == trustforge ]] ||
        { bad "MANIFEST.json product is '${product:-empty}', not trustforge."; return 1; }
    [[ $format == 1 ]] ||
        { bad "MANIFEST.json packageFormat is '${format:-empty}'; this installer understands format 1."; return 1; }
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        { bad "MANIFEST.json version is '$version', which is not a numeric triple."; return 1; }
    # Anything taken from the archive is interpolated into $STATE_FILE later, so it is validated
    # here, at the boundary, rather than trusting a published file to be well-behaved.
    assert_shell_safe_value "the package version" "$version"
    PKG_VERSION=$version
    # Editing a manifest and re-signing it defeats SHA256SUMS, so the second witness is the name the
    # operator downloaded: make-package.sh derives both from the same <Version>, and if they disagree
    # then the provenance and the application bytes come from different builds.
    local witness
    for witness in "$PKG_TOP" "${PACKAGE_FILE:-}"; do
        [[ -n $witness ]] || continue
        witness=$(basename -- "$witness")
        if [[ $witness =~ ^trustforge-([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            [[ ${BASH_REMATCH[1]} == "$version" ]] ||
                { bad "$witness is named for ${BASH_REMATCH[1]} but MANIFEST.json says $version."; return 1; }
        fi
    done
    local candidate
    for candidate in "$sha_short" "$lib_sha"; do
        if [[ $candidate != unknown && ! $candidate =~ ^[0-9a-f]{7,40}$ ]]; then
            bad "MANIFEST.json records a git SHA that is not hexadecimal: $candidate"
            return 1
        fi
    done
    PKG_GIT_SHA=$sha
    PKG_GIT_SHA_SHORT=$sha_short
    PKG_LIBRARY_SHA=$lib_sha
    ok "package manifest: version ${PKG_VERSION}, TrustForge ${PKG_GIT_SHA}, library ${PKG_LIBRARY_SHA}"
    return 0
}

validate_package_archive() {
    local archive=$1 dir=$2 errors_before=$fail rc=0
    check_package_listing "$archive" &&
        extract_package "$archive" "$dir" &&
        check_package_tree "$dir/$PKG_TOP" &&
        read_package_manifest "$dir/$PKG_TOP"
    rc=$?
    if [[ $rc -eq 0 && $fail -eq $errors_before ]]; then
        ok "release package $archive is acceptable"
    fi
    return $rc
}

# The --validate-package entry point: unpacks into a private temporary directory, judges it, and
# leaves nothing behind. It reports through ok/bad like the rest of preflight, plus one verdict line
# so a script wrapping this command has something unambiguous to read.
validate_package_entry() {
    local archive=$1 dir rc=0
    [[ -f $archive ]] || { printf 'FAIL: %s is not a regular file.\n' "$archive" >&2; return 1; }
    dir=$(mktemp -d "${TMPDIR:-/var/tmp}/trustforge-validate.XXXXXX") ||
        { printf 'FAIL: cannot create a temporary directory.\n' >&2; return 1; }
    if validate_package_archive "$archive" "$dir"; then
        printf 'PASS: %s is a valid TrustForge release package (version %s, git %s).\n' \
            "$archive" "$PKG_VERSION" "$PKG_GIT_SHA_SHORT"
    else
        printf 'FAIL: %s is not a valid TrustForge release package.\n' "$archive" >&2
        rc=1
    fi
    rm -rf "$dir"
    return $rc
}

extract_package() {
    local archive=$1 dir=$2
    install -d -m 0700 "$dir" || { bad "cannot create $dir"; return 1; }
    # --no-same-owner: an archive must not be able to place members as uid 0's own account or as any
    # other identity it names. The tree lands in a 0700 directory owned by whoever ran this script.
    tar -xz --no-same-owner -f "$archive" -C "$dir" || { bad "extracting $archive failed"; return 1; }
    return 0
}

select_install_mode() {
    if [[ -n $PACKAGE_FILE ]]; then
        INSTALL_MODE=package-file
        [[ -r $PACKAGE_FILE ]] || die "$PACKAGE_FILE is not readable."
    elif [[ -f $REPO_ROOT/MANIFEST.json && -e $REPO_ROOT/app/TrustForge.dll ]]; then
        if [[ -d $REPO_ROOT/TrustForge.Api ]]; then
            die "$REPO_ROOT holds both a release package (MANIFEST.json, app/) and a source checkout (TrustForge.Api/). Unpack the package into its own directory: which release to install would otherwise be a guess."
        fi
        INSTALL_MODE=package-extracted
        PKG_ROOT=$REPO_ROOT
        PKG_TOP=$(basename -- "$REPO_ROOT")
    else
        INSTALL_MODE=source
    fi

    if [[ $INSTALL_MODE != source ]]; then
        # Refused rather than ignored: an option that selects build inputs cannot mean anything when
        # nothing is compiled, and silently dropping it would let an operator believe they chose a
        # library revision that the package does not contain.
        [[ $SOURCE_DIR_GIVEN -eq 0 ]] ||
            die "--source-dir selects what to build. Nothing is built from a release package, so it does not apply here; drop it, or install from the checkout instead."
        [[ $LIBRARY_GIVEN -eq 0 ]] ||
            die "--technitium-library selects what to build. Nothing is built from a release package, whose library revision is recorded in MANIFEST.json instead."
    fi
    DEPLOY_DIR=$SCRIPT_DIR
    return 0
}

# The archive is unpacked into its own temporary directory rather than into $BUILD_ROOT, because this
# runs during preflight too: --check-only and --dry-run must stay non-mutating, and a throwaway under
# TMPDIR that the EXIT trap deletes is the one thing they can create without leaving a trace.
prepare_package_stage() {
    local root=$fail
    [[ $INSTALL_MODE == package-file ]] || return 0
    PKG_STAGE=$(mktemp -d "${TMPDIR:-/var/tmp}/trustforge-package.XXXXXX") ||
        die "cannot create a staging directory under ${TMPDIR:-/var/tmp}."
    # main() installs the matching cleanup; --check-only and --dry-run reach here before it does, so
    # the same trap is installed for them as well rather than leaving the scratch tree behind.
    trap 'cleanup_package_stage; rm -rf "$BUILD_ROOT"' EXIT
    log "validating and unpacking $PACKAGE_FILE"
    if ! validate_package_archive "$PACKAGE_FILE" "$PKG_STAGE"; then
        die "$PACKAGE_FILE is not acceptable as a release package; nothing was installed."
    fi
    [[ $fail -eq $root ]] || die "$PACKAGE_FILE failed package validation."
    PKG_ROOT=$PKG_STAGE/$PKG_TOP
    DEPLOY_DIR=$PKG_ROOT/deploy/bare-metal
    log "package ${PKG_VERSION} unpacked in $PKG_ROOT"
}

cleanup_package_stage() {
    [[ -n $PKG_STAGE && -d $PKG_STAGE ]] && rm -rf "$PKG_STAGE"
    return 0
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
    if [[ $INSTALL_MODE != source ]]; then
        require_package_inputs
        return 0
    fi
    [[ -f $SOURCE_ROOT/TrustForge.Api/TrustForge.Api.csproj ]] ||
        die "$SOURCE_ROOT has no TrustForge.Api project; pass --source-dir."
    [[ -f $DEPLOY_DIR/trustforge.service && -f $DEPLOY_DIR/trustforge.env.example ]] ||
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

# In package mode the assertion is about the application, not about a compiler: these are the files
# the unit, the DNS console and the ACME pipeline all reach for, and a package missing one of them is
# not a TrustForge release whatever its manifest claims.
require_package_inputs() {
    [[ -f $DEPLOY_DIR/trustforge.service ]] ||
        die "$DEPLOY_DIR/trustforge.service is missing; the package does not carry its unit file."
    [[ -f $DEPLOY_DIR/trustforge.env.example ]] ||
        die "$DEPLOY_DIR/trustforge.env.example is missing; the installer templates its configuration from that file."
    if [[ $INSTALL_MODE == package-extracted ]]; then
        local root=$fail
        check_package_tree "$PKG_ROOT" || true
        read_package_manifest "$PKG_ROOT" || true
        if ((fail > root)); then
            probe "re-download the release and unpack it into a fresh directory; do not patch a package in place."
            return 0
        fi
    fi
    ok "installing release ${PKG_VERSION} from a package (TrustForge ${PKG_GIT_SHA_SHORT}, library ${PKG_LIBRARY_SHA})"
    hint "no compiler runs on this host: the application bytes are the ones that were published."
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
    local proto label owner
    for proto in t u; do
        label=tcp
        [[ $proto == u ]] && label=udp
        if port_listening "$proto" "$DNS_PORT"; then
            owner=$(occupied_by "$proto" "$DNS_PORT")
            if [[ $FREE_PORT_53 -eq 1 && $owner == "systemd-resolve" ]]; then
                hint "port 53/$label is held by systemd-resolved (will be released via --free-port-53 before starting trustforge)"
            else
                bad "port 53/$label is taken by $owner"
            fi
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
    local clusters
    if [[ $SKIP_POSTGRES -eq 1 ]]; then
        ok "--skip-postgres: an external cluster is assumed"
        [[ -n $DB_PASSWORD_FILE ]] ||
            hint "--skip-postgres normally pairs with --db-password-file; without it a password is generated for the connection string you must already own."
        return 0
    fi
    clusters=$(pg_lsclusters -h 2>/dev/null || true)
    if command -v pg_lsclusters >/dev/null 2>&1 && [[ -n $clusters ]]; then
        bad "this host already has a PostgreSQL cluster:"
        probe "$(pg_lsclusters -h 2>/dev/null | head -3 | tr '\n' ' ')"
        probe "install into it with --skip-postgres plus your own role, or decommission it deliberately first."
        return 0
    fi
    ok "no existing PostgreSQL cluster; $PG_VERSION will come from PGDG"
}

check_resources_and_time() {
    local mem_kb avail_kb ntp
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

    ntp=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)
    if [[ $ntp == true ]]; then
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
    # api.nuget.org is only worth probing when something on this host is about to restore packages.
    # In package mode the bytes are already published, so demanding the feed would be a lie in the
    # preflight and an unnecessary failure for an air-gapped-ish mirror of dot.net plus PGDG.
    local urls=("$DOTNET_INSTALL_URL")
    if [[ $INSTALL_MODE == source ]]; then
        urls+=(https://api.nuget.org/v3/index.json)
    fi
    if [[ $SKIP_POSTGRES -eq 0 ]]; then
        urls+=("https://apt.postgresql.org/pub/repos/apt/dists/noble-pgdg/Release")
    fi
    local url
    for url in "${urls[@]}"; do
        if curl -fsS --max-time 20 -o /dev/null "$url"; then
            ok "reachable: $url"
        else
            bad "unreachable: $url. The install needs it from this host."
        fi
    done
    if [[ -n $OIDC_AUTHORITY && $WITH_LOCAL_OIDC -eq 0 ]]; then
        if curl -fsS --max-time 20 -o /dev/null "$OIDC_AUTHORITY/.well-known/openid-configuration"; then
            ok "OIDC discovery answers for $OIDC_AUTHORITY"
        elif [[ $CHECK_ONLY -eq 0 && $DRY_RUN -eq 0 && $ALLOW_UNREACHABLE_OIDC -eq 0 ]]; then
            bad "OIDC discovery failed for $OIDC_AUTHORITY (use a reachable issuer, --with-local-oidc, or --allow-unreachable-oidc)."
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
    # Step 5 is where the modes diverge, and --dry-run must not promise a compile that package mode
    # never performs.
    local build_line
    if [[ $INSTALL_MODE == source ]]; then
        build_line="  5  install the .NET SDK into $BUILD_ROOT/dotnet-sdk, build the three TechnitiumLibrary projects,
     publish TrustForge.Api there, then rm -rf $BUILD_ROOT (no SDK, no NuGet cache, no sources left)"
    else
        build_line="  5  verify $(basename -- "$PACKAGE_FILE" 2>/dev/null || echo "the unpacked package") against its own SHA256SUMS,
     unpack it into a private 0700 scratch directory, re-check the extracted tree, then rm -rf it;
     nothing here is compiled on this host"
    fi
    cat <<EOF

Ordered mutations that would follow:
  1  apt-get install ca-certificates curl gnupg git openssh-client openssl libicu74 dnsutils
  2  add the PGDG apt source (signed-by /etc/apt/keyrings/postgresql.gpg), install postgresql-$PG_VERSION,
     start postgresql@$PG_VERSION-$PG_CLUSTER
  3  fetch $MS_REPO_DEB for libmsquic; failure here only costs DoQ/DoH3
  4  install the ASP.NET Core $DOTNET_CHANNEL runtime into $RUNTIME_ROOT (permanent), link
     /usr/bin/dotnet only when absent
$build_line
  6  stage the release bytes as $APP_ROOT/app/<release-id>, flip $APP_ROOT/app/current atomically
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
    local icu
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update || die "apt-get update failed; no packages could be installed."
    apt-get -qq -y --no-install-recommends install \
        ca-certificates curl gnupg git openssh-client openssl iproute2 util-linux coreutils sed ||
        die "the base toolchain could not be installed."
    icu=$(ldconfig -p 2>/dev/null | grep -c libicu || true)
    if [[ $icu == 0 ]]; then
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
    local runtimes
    [[ -s $BUILD_ROOT/dotnet-install.sh ]] ||
        curl -fsSL --max-time 120 "$DOTNET_INSTALL_URL" -o "$BUILD_ROOT/dotnet-install.sh" ||
        die "could not fetch $DOTNET_INSTALL_URL"
    runtimes=$("$RUNTIME_ROOT/dotnet" --list-runtimes 2>/dev/null || true)
    if ! grep -q "Microsoft.AspNetCore.App $DOTNET_CHANNEL" <<<"$runtimes"; then
        log "installing the ASP.NET Core $DOTNET_CHANNEL runtime into $RUNTIME_ROOT"
        bash "$BUILD_ROOT/dotnet-install.sh" -c "$DOTNET_CHANNEL" --runtime aspnetcore --no-path \
            --install-dir "$RUNTIME_ROOT" >>"$INSTALL_LOG" 2>&1 ||
            die "the ASP.NET Core runtime install failed; see $INSTALL_LOG"
    fi
    [[ -e /usr/bin/dotnet ]] || ln -s "$RUNTIME_ROOT/dotnet" /usr/bin/dotnet
    ok "ASP.NET Core $DOTNET_CHANNEL runtime available"
}

stage_release_dir() {
    local src=$1 release_id=$2
    install -d -m 0755 "$APP_ROOT/app/$release_id"
    cp -a "$src/." "$APP_ROOT/app/$release_id/"
    # Renamed into place rather than repointed: a reader following 'current' mid-upgrade sees either
    # whole release, never a half-copied one.
    ln -sfn "$APP_ROOT/app/$release_id" "$APP_ROOT/app/.current.new"
    mv -T "$APP_ROOT/app/.current.new" "$APP_ROOT/app/current"
    chmod -R a-w "$APP_ROOT/app/$release_id"
    ok "release $release_id staged and 'current' flipped"
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

    stage_release_dir "$publish_dir" "$release_id"
}

stage_package_release() {
    local release_id=$1
    [[ -f $PKG_ROOT/app/TrustForge.dll ]] || die "$PKG_ROOT/app/TrustForge.dll is missing."
    stage_release_dir "$PKG_ROOT/app" "$release_id"
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
        install -m 0600 -o root -g root "$DEPLOY_DIR/trustforge.env.example" "$ENV_FILE"
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
    install -m 0644 -o root -g root "$DEPLOY_DIR/trustforge.service" "$UNIT_FILE"
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
    # NR==1 inside awk instead of head -1: head closes the pipe as soon as it has a line, and under
    # pipefail that turns a successful read into a failed assignment that aborts the script.
    ui_listener=$(ss -Hltn "sport = :$DNS_UI_PORT" 2>/dev/null | awk 'NR==1{print $4}' || true)
    ok "runtime sockets as intended: 53 tcp+udp, console ${ui_listener:-none}, API 127.0.0.1:$API_PORT"
}

write_state() {
    local release_id=$1
    local mode library_sha pkg_file extra='' src_root='' lib_dir=''

    # The package values come from a manifest inside a downloaded archive, so nothing reaches this
    # heredoc that read_package_manifest did not already restrict: one unescaped quote would corrupt
    # the file the upgrade and rollback procedures trust to say what is installed here.
    if [[ $INSTALL_MODE == source ]]; then
        mode=built-on-target
        src_root=$SOURCE_ROOT
        lib_dir=$TECH_LIBRARY
        library_sha=$(git -C "$TECH_LIBRARY" rev-parse HEAD 2>/dev/null || printf 'unknown')
    else
        mode=package
        library_sha=$PKG_LIBRARY_SHA
        assert_shell_safe_value "packageVersion" "$PKG_VERSION"
        assert_shell_safe_value "packageGitSha" "$PKG_GIT_SHA"
        assert_shell_safe_value "packageLibrarySha" "$PKG_LIBRARY_SHA"
        pkg_file=$(basename -- "${PACKAGE_FILE:-$PKG_TOP}")
        extra="  \"packageFile\": \"$pkg_file\",
  \"packageVersion\": \"$PKG_VERSION\",
  \"packageGitSha\": \"$PKG_GIT_SHA\",
  \"packageLibrarySha\": \"$PKG_LIBRARY_SHA\",
"
    fi

    cat >"$STATE_FILE" <<EOF
{
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "release": "$release_id",
  "installMode": "$mode",
  "sourceRoot": "$src_root",
  "technitiumLibrary": "$lib_dir",
  "libraryGitSha": "$library_sha",
$extra  "secretsDir": "$SECRETS_DIR",
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

free_port_53_stub() {
    [[ $FREE_PORT_53 -eq 1 ]] || return 0
    if ! port_listening t "$DNS_PORT" && ! port_listening u "$DNS_PORT"; then
        return 0
    fi
    log "releasing port 53 from systemd-resolved stub listener (--free-port-53)"
    install -d -m 0755 /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' >/etc/systemd/resolved.conf.d/10-trustforge.conf
    systemctl restart systemd-resolved
    if port_listening t "$DNS_PORT" || port_listening u "$DNS_PORT"; then
        die "port 53 is still occupied after disabling systemd-resolved DNSStubListener."
    fi
    ok "port 53 released from systemd-resolved"
}

switch_host_resolver_to_local() {
    [[ $FREE_PORT_53 -eq 1 ]] || return 0
    if [[ -L /etc/resolv.conf || -f /etc/resolv.conf ]]; then
        cp -L /etc/resolv.conf /etc/resolv.conf.pre-trustforge 2>/dev/null || true
    fi
    rm -f /etc/resolv.conf
    printf 'nameserver 127.0.0.1\n' >/etc/resolv.conf
    chmod 0644 /etc/resolv.conf
    ok "pointed /etc/resolv.conf at local TrustForge DNS (127.0.0.1)"
}

stage_support_files() {
    local root=$REPO_ROOT
    [[ $INSTALL_MODE == package-file ]] && root=$PKG_ROOT

    install -d -m 0755 -o root -g root \
        "$APP_ROOT/deploy/bare-metal" \
        "$APP_ROOT/deploy/bare-metal/keycloak" \
        "$APP_ROOT/remote-helper" \
        "$APP_ROOT/docs"

    local f
    for f in install.sh common.sh setup-step-ca.sh setup-oidc.sh setup-acme-dns.sh \
             install-target-helper.sh setup-nginx-tls.sh; do
        if [[ -f $DEPLOY_DIR/$f ]]; then
            install -m 0755 -o root -g root "$DEPLOY_DIR/$f" "$APP_ROOT/deploy/bare-metal/$f"
        fi
    done
    for f in trustforge.service trustforge.env.example; do
        if [[ -f $DEPLOY_DIR/$f ]]; then
            install -m 0644 -o root -g root "$DEPLOY_DIR/$f" "$APP_ROOT/deploy/bare-metal/$f"
        fi
    done

    local realm_src=""
    if [[ -f $DEPLOY_DIR/keycloak/trustforge-dev-realm.json ]]; then
        realm_src=$DEPLOY_DIR/keycloak/trustforge-dev-realm.json
    elif [[ -f $root/TrustForge.Api/keycloak/trustforge-dev-realm.json ]]; then
        realm_src=$root/TrustForge.Api/keycloak/trustforge-dev-realm.json
    fi
    if [[ -n $realm_src ]]; then
        install -m 0644 -o root -g root "$realm_src" "$APP_ROOT/deploy/bare-metal/keycloak/trustforge-dev-realm.json"
    fi

    if [[ -f $root/remote-helper/trustforge-certctl ]]; then
        install -m 0755 -o root -g root "$root/remote-helper/trustforge-certctl" "$APP_ROOT/remote-helper/trustforge-certctl"
    fi
    if [[ -f $root/remote-helper/README.md ]]; then
        install -m 0644 -o root -g root "$root/remote-helper/README.md" "$APP_ROOT/remote-helper/README.md"
    fi

    local doc_src=""
    if [[ -d $root/docs && -f $root/docs/BAREMETAL.md ]]; then
        doc_src=$root/docs
    else
        doc_src=$root
    fi
    for f in BAREMETAL.md BARE-METAL-GUIDE.md DEPLOYMENT.md OPERATIONS.md README.md SECURITY.md build.md CHANGELOG.md LICENSE; do
        if [[ -f $doc_src/$f ]]; then
            install -m 0644 -o root -g root "$doc_src/$f" "$APP_ROOT/docs/$f"
        elif [[ -f $root/docs/$f ]]; then
            install -m 0644 -o root -g root "$root/docs/$f" "$APP_ROOT/docs/$f"
        fi
    done
    if [[ -f $APP_ROOT/docs/BAREMETAL.md ]]; then
        ln -sfn "$APP_ROOT/docs/BAREMETAL.md" "$APP_ROOT/BAREMETAL.md"
    fi
    ok "staged operational scripts, remote-helper, and docs under $APP_ROOT"
}

run_post_install_stack() {
    local host_ip
    host_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)
    [[ -n $host_ip ]] || host_ip="127.0.0.1"

    if [[ $WITH_STEP_CA -eq 1 ]]; then
        local -a ca_args=(--ca-domain "$CA_DOMAIN")
        [[ $USE_APT_STEP_CA -eq 1 ]] && ca_args+=(--use-apt-step-ca)
        bash "$APP_ROOT/deploy/bare-metal/setup-step-ca.sh" "${ca_args[@]}"
    fi

    if [[ $WITH_ACME_DNS -eq 1 ]]; then
        local -a dns_args=(
            --zone "$SETUP_ZONE"
            --account-email "$ADMIN_EMAIL"
            --record "${CA_DOMAIN}=${host_ip}"
            --record "${API_DOMAIN}=${host_ip}"
        )
        [[ $WITH_LOCAL_OIDC -eq 1 ]] && dns_args+=(--record "${OIDC_DOMAIN}=${host_ip}")
        bash "$APP_ROOT/deploy/bare-metal/setup-acme-dns.sh" "${dns_args[@]}"
    fi

    if [[ $WITH_LOCAL_OIDC -eq 1 ]]; then
        bash "$APP_ROOT/deploy/bare-metal/setup-oidc.sh" \
            --domain "$OIDC_DOMAIN" \
            --issuer-url "$OIDC_AUTHORITY" \
            --audience "$OIDC_AUDIENCE" \
            --admin-email "$ADMIN_EMAIL"
    fi

    if [[ $WITH_SELF_TLS -eq 1 ]]; then
        bash "$APP_ROOT/deploy/bare-metal/install-target-helper.sh" \
            --local --control-plane-secret ssh-local.json \
            --helper-path "$APP_ROOT/remote-helper/trustforge-certctl"
        local -a nginx_args=(--api-domain "$API_DOMAIN")
        [[ $WITH_LOCAL_OIDC -eq 1 ]] && nginx_args+=(--oidc-domain "$OIDC_DOMAIN")
        bash "$APP_ROOT/deploy/bare-metal/setup-nginx-tls.sh" "${nginx_args[@]}"
    fi
}

main() {
    parse_args "$@"

    # Deliberately before require_root_and_systemd and before any $INSTALL_LOG exists: judging a
    # published asset is something an operator (or CI) must be able to do as an unprivileged user on
    # a host that will never run TrustForge, and it must change nothing.
    if [[ -n $VALIDATE_PACKAGE ]]; then
        validate_package_entry "$VALIDATE_PACKAGE"
        return $?
    fi

    [[ -n $API_DOMAIN ]] || API_DOMAIN="api.${SETUP_ZONE}"
    [[ -n $CA_DOMAIN ]] || CA_DOMAIN="ca.${SETUP_ZONE}"
    [[ -n $OIDC_DOMAIN ]] || OIDC_DOMAIN="id.${SETUP_ZONE}"
    [[ -n $ADMIN_EMAIL ]] || ADMIN_EMAIL="ops@${SETUP_ZONE}"

    if [[ $WITH_LOCAL_OIDC -eq 1 ]]; then
        [[ -n $OIDC_AUTHORITY ]] || OIDC_AUTHORITY="https://${OIDC_DOMAIN}/realms/trustforge-dev"
        [[ -n $OIDC_AUDIENCE ]] || OIDC_AUDIENCE="trustforge-api"
    fi

    select_install_mode
    if [[ $INSTALL_MODE == source ]]; then
        resolve_library_dir
    fi

    if [[ $CHECK_ONLY -eq 0 && $DRY_RUN -eq 0 ]]; then
        # Both values are required and neither is guessable, so they are asked for rather than
        # defaulted. The read failure is fatal rather than a retry: with no terminal (CI, cron, a
        # pipe) an empty reply would loop here forever instead of saying what to pass.
        while [[ -z $OIDC_AUTHORITY ]]; do
            printf 'HTTPS OIDC issuer URL: ' >/dev/tty ||
                die "no terminal to ask for the OIDC issuer on: pass --oidc-authority URL (or --with-local-oidc)."
            IFS= read -r OIDC_AUTHORITY </dev/tty || OIDC_AUTHORITY=
        done
        while [[ -z $OIDC_AUDIENCE ]]; do
            printf 'TrustForge API audience: ' >/dev/tty ||
                die "no terminal to ask for the API audience on: pass --oidc-audience NAME."
            IFS= read -r OIDC_AUDIENCE </dev/tty || OIDC_AUDIENCE=
        done
        [[ $OIDC_AUTHORITY == https://* ]] ||
            die "the OIDC authority must start with https:// (Program.cs:85-94 rejects anything else outside Development)."
        assert_shell_safe_value "the OIDC authority" "$OIDC_AUTHORITY"
        assert_shell_safe_value "the OIDC audience" "$OIDC_AUDIENCE"
    fi

    require_root_and_systemd
    # Judged and unpacked here, immediately before preflight, so that "this release is acceptable" is
    # a checked claim rather than an assumption; the scratch tree goes with the build tree on exit.
    prepare_package_stage
    run_preflight
    [[ $CHECK_ONLY -eq 1 ]] && { log "--check-only: stopping, nothing changed."; return 0; }
    [[ $DRY_RUN -eq 1 ]] && { print_plan; log "--dry-run: nothing changed."; return 0; }

    # create_directories() re-applies this later; it must happen before the first write to
    # $INSTALL_LOG, which lives under $APP_ROOT and is the redirect target of the build step.
    install -d -m 0755 "$APP_ROOT"
    install -d -m 0700 "$BUILD_ROOT"
    trap 'cleanup_package_stage; rm -rf "$BUILD_ROOT"' EXIT
    : >>"$INSTALL_LOG" || die "cannot write $INSTALL_LOG."

    record_existing_decisions
    reseed_dns_config

    local release_id
    if [[ $INSTALL_MODE == source ]]; then
        release_id="$(git -C "$SOURCE_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'local')-$(date +%Y%m%d%H%M%S)"
    else
        # The timestamp suffix is kept even though the version and SHA are known: re-installing the
        # same package would otherwise collide with the previous directory, which is chmod a-w.
        release_id="${PKG_VERSION}-${PKG_GIT_SHA_SHORT}-$(date +%Y%m%d%H%M%S)"
    fi

    log "installing TrustForge $release_id; build and service output append to $INSTALL_LOG"
    ensure_apt_prerequisites
    install_postgres_repo
    install_libmsquic
    install_dotnet_runtime
    if [[ $INSTALL_MODE == source ]]; then
        build_and_stage_release "$release_id"
    else
        stage_package_release "$release_id"
    fi
    stage_support_files
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
    free_port_53_stub
    install_unit
    verify_runtime
    switch_host_resolver_to_local
    write_state "$release_id"
    prune_releases

    run_post_install_stack

    log "TrustForge is running. DNS console 127.0.0.1:$DNS_UI_PORT, API 127.0.0.1:$API_PORT."
    if [[ $WITH_SELF_TLS -eq 1 ]]; then
        log "HTTPS API endpoint: https://${API_DOMAIN} (auto-renewing via TrustForge)."
    fi
    log "See $APP_ROOT/docs/BARE-METAL-GUIDE.md and BAREMETAL.md for operations and verification."
}

main "$@"
