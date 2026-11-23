#!/usr/bin/env bash
# Assembles the GitHub Release assets for TrustForge from an already published application folder.
#
#   make-package.sh --app-dir DIR [--library-dir DIR] [--out DIR] [--tag v0.1.0]
#                   [--expect-library-ref dns-server-v15.6.2] [--skip-source]
#
# Nothing is compiled here. Compilation lives in Dockerfile:2-12; CI runs that same build stage
# (--target build) and docker-cps its /out/publish into --app-dir, so "the package equals the bytes
# the container runs" holds by construction rather than by a later comparison. Reproduce locally with
# deploy/bare-metal/build-and-verify-in-container.sh.
#
# Framework-dependent by decision: no RuntimeIdentifier exists anywhere in this repository, so the
# target host must still install the ASP.NET Core 10 shared runtime (install_dotnet_runtime in
# install.sh). That is also why the asset is named -linux and not -linux-x64: RID-less publish output
# is architecture-neutral IL, and calling it x64 would be a false claim about the artifact.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

VERSION=
TAG=
APP_DIR=
LIB_DIR=
OUT_DIR=
EXPECT_LIB_REF=
SKIP_SOURCE=0
STAGE_ROOT=

GIT_SHA=unknown
GIT_SHA_SHORT=unknown
GIT_DIRTY=unknown
LIB_NAME=unknown
LIB_SHA=unknown
LIB_REF=unknown
ENGINE_VERSION=unknown
RELEASE_ID=unknown
REPO_ROOT_NAME=unknown
SDK_VERSION=unknown
BUILD_HOST=unknown
BUILD_TIMESTAMP=unknown
BASE_IMAGE_DIGEST=unknown
EPOCH=0
TAR_FLAGS=()

DOC_FILES=(BAREMETAL.md DEPLOYMENT.md OPERATIONS.md README.md SECURITY.md build.md CHANGELOG.md LICENSE)

# Each of these is emitted by dotnet publish of this repository, so a missing one means --app-dir
# came from something other than the current build and the package would be a guess. www/ and
# dohwww/ are the DNS console's static files (DnsServerCore.csproj:116-282); the TechnitiumLibrary
# DLLs are the HintPath references that make the library SHA part of provenance at all.
APP_ANCHORS=(
    TrustForge.dll TrustForge.runtimeconfig.json TrustForge.deps.json
    DnsServerCore.dll TrustForge.Core.dll TrustForge.Persistence.dll
    TechnitiumLibrary.dll TechnitiumLibrary.ByteTree.dll TechnitiumLibrary.IO.dll
    TechnitiumLibrary.Net.dll TechnitiumLibrary.Security.OTP.dll
    Renci.SshNet.dll Certes.dll
    www/index.html dohwww/index.html named.root root-anchors.xml
)

log() { printf '  %s\n' "$*"; }
hint() { printf '  NOTE  %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: make-package.sh --app-dir DIR [OPTION]...

Assemble the five release assets: trustforge-<version>-linux.tar.gz (app/, deploy/bare-metal/, docs/,
README.md, MANIFEST.json, SHA256SUMS inside), its detached .sha256, the same MANIFEST.json as a
standalone asset, the GPLv3 corresponding-source archive, and its detached .sha256. Nothing compiled.

Options:
  --app-dir DIR          Framework-dependent publish output, i.e. the Dockerfile build stage's
                         /out/publish. Required; must contain TrustForge.dll.
  --library-dir DIR      TechnitiumLibrary checkout, used for the corresponding-source archive and
                         the SHA recorded in MANIFEST.json. Default: this repository's sibling.
  --out DIR              Asset output directory. Default: deploy/bare-metal/dist (git-ignored).
  --tag NAME             Release tag being packaged. Must equal v<version>, which is also what stops
                         an inherited upstream v15.x tag from ever producing a TrustForge release.
  --expect-library-ref R Abort unless the library checkout is exactly ref R. CI passes the pin here.
  --skip-source          Skip the corresponding-source archive. A distributed binary without it does
                         not satisfy GPLv3, so this is for a local dry assembly only.
  -h, --help             This text.
EOF
}

parse_args() {
    [[ $# -gt 0 ]] || { usage >&2; die "make-package.sh needs at least --app-dir"; }
    while [[ $# -gt 0 ]]; do
        case $1 in
            --app-dir)
                [[ $# -ge 2 ]] || die "--app-dir needs a directory"
                APP_DIR=$(cd -- "$2" 2>/dev/null && pwd) || die "no such app dir: $2"
                shift ;;
            --library-dir)
                [[ $# -ge 2 ]] || die "--library-dir needs a directory"
                LIB_DIR=$(cd -- "$2" 2>/dev/null && pwd) || die "no such library dir: $2"
                shift ;;
            --out) [[ $# -ge 2 ]] || die "--out needs a directory"; OUT_DIR=$2; shift ;;
            --tag) [[ $# -ge 2 ]] || die "--tag needs a value"; TAG=$2; shift ;;
            --expect-library-ref)
                [[ $# -ge 2 ]] || die "--expect-library-ref needs a value"
                EXPECT_LIB_REF=$2; shift ;;
            --skip-source) SKIP_SOURCE=1 ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; die "unknown option: $1" ;;
        esac
        shift
    done
    [[ -n $APP_DIR ]] || { usage >&2; die "--app-dir is required"; }
    [[ -n $OUT_DIR ]] || OUT_DIR=$REPO_ROOT/deploy/bare-metal/dist
    if [[ -n $TAG && ! $TAG =~ ^[A-Za-z0-9._-]+$ ]]; then
        die "refusing a tag with characters that are unsafe in a shell heredoc or a JSON string: $TAG"
    fi
}

resolve_version() {
    local csproj=$REPO_ROOT/TrustForge.Api/TrustForge.Api.csproj declared
    [[ -f $csproj ]] || die "no $csproj, so the product version cannot be read."
    declared=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$csproj" | head -1)
    [[ -n $declared ]] || die "no <Version> in TrustForge.Api/TrustForge.Api.csproj: that element is
this repository's only version source of truth and this script must not invent a version."
    [[ $declared =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "<Version>$declared</Version> is not a numeric triple, and the asset names embed it raw."
    VERSION=$declared
    if [[ -n $TAG && $TAG != "v$VERSION" ]]; then
        die "refusing to package for tag $TAG while TrustForge.Api declares $VERSION."
    fi
    log "version $VERSION"
}

require_app_dir() {
    local missing=0 name rc
    [[ -d $APP_DIR ]] || die "no such app dir: $APP_DIR"
    for name in "${APP_ANCHORS[@]}"; do
        if [[ ! -e $APP_DIR/$name ]]; then
            bad "missing $APP_DIR/$name"
            missing=1
        fi
    done
    [[ $missing -eq 0 ]] || die "the app folder is not a complete TrustForge publish output."

    rc=$APP_DIR/TrustForge.runtimeconfig.json
    grep -q 'Microsoft.AspNetCore.App' "$rc" ||
        die "runtimeconfig.json does not reference Microsoft.AspNetCore.App, so this is not the
framework-dependent shape install.sh stages and runs."
    grep -Eq '"version"[[:space:]]*:[[:space:]]*"10(\.|[0-9])' "$rc" ||
        die "runtimeconfig.json does not require ASP.NET Core 10, so the shared runtime the
installer fetches would not match the build."
    log "app folder carries every anchor and is framework-dependent on ASP.NET Core 10"
}

collect_provenance() {
    if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        GIT_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD)
        GIT_SHA_SHORT=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
        GIT_DIRTY=false
        if [[ -n $(git -C "$REPO_ROOT" status --porcelain 2>/dev/null) ]]; then
            GIT_DIRTY=true
            hint "the working tree is dirty; this package does not correspond to a committed state."
        fi
        RELEASE_ID="${VERSION}-${GIT_SHA_SHORT}-$(date +%Y%m%d%H%M%S)"
    else
        hint "$REPO_ROOT is not a git checkout, so MANIFEST provenance will read unknown."
    fi
    REPO_ROOT_NAME=$(basename -- "$REPO_ROOT")

    if [[ -z $LIB_DIR ]]; then
        LIB_DIR=$(cd -- "$REPO_ROOT/.." && pwd)/TechnitiumLibrary
    fi
    if [[ -d $LIB_DIR ]]; then
        LIB_NAME=$(git -C "$LIB_DIR" config --get remote.origin.url 2>/dev/null || printf 'unknown')
        LIB_SHA=$(git -C "$LIB_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')
        LIB_REF=$(git -C "$LIB_DIR" describe --tags --exact-match 2>/dev/null || printf 'unknown')
    fi
    if [[ -n $EXPECT_LIB_REF && $LIB_REF != "$EXPECT_LIB_REF" ]]; then
        die "the library checkout is at ref '$LIB_REF' but $EXPECT_LIB_REF was required. Packaging
against an unpinned library yields a binary that nobody can map back to source."
    fi

    ENGINE_VERSION=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' \
        "$REPO_ROOT/DnsServerCore/DnsServerCore.csproj" | head -1)
    [[ -n $ENGINE_VERSION ]] || ENGINE_VERSION=unknown
    if [[ $LIB_REF =~ ^dns-server-v(.+)$ && ${BASH_REMATCH[1]} != "$ENGINE_VERSION" ]]; then
        die "library checkout is $LIB_REF while DnsServerCore declares $ENGINE_VERSION: the vendored
engine and the library it compiles against have drifted, and that drift must be resolved in the
build, not papered over in a release."
    fi

    if [[ $SKIP_SOURCE -eq 0 ]]; then
        if [[ ! -d $LIB_DIR || $LIB_SHA == unknown ]]; then
            die "no usable TechnitiumLibrary checkout at $LIB_DIR, and both projects are GPLv3: a
distributed binary must ship its corresponding source. Pass --library-dir, or --skip-source for a
local dry assembly only."
        fi
        [[ $GIT_SHA != unknown ]] ||
            die "--skip-source was not passed but $REPO_ROOT is not a git checkout, so the source
archive cannot be produced."
    fi

    SDK_VERSION=$(dotnet --version 2>/dev/null || printf 'not-installed')
    # Read, do not source: /etc/os-release is data, and sourcing a file whose contents a previous
    # stage of this pipeline could have influenced is not a habit worth keeping in a packager.
    BUILD_HOST=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null | head -1)
    [[ -n $BUILD_HOST ]] || BUILD_HOST=unknown
    BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    BASE_IMAGE_DIGEST=${BASE_IMAGE_DIGEST:-unknown}
    EPOCH=${SOURCE_DATE_EPOCH:-$(date +%s)}
    [[ $EPOCH =~ ^[0-9]+$ ]] || EPOCH=$(date +%s)
    log "library ${LIB_NAME}@${LIB_SHA} (ref ${LIB_REF}), engine ${ENGINE_VERSION}, sdk ${SDK_VERSION}"
}

top_name() { printf 'trustforge-%s-linux' "$VERSION"; }
pkg_name() { printf 'trustforge-%s-linux.tar.gz' "$VERSION"; }
manifest_name() { printf 'trustforge-%s-linux-manifest.json' "$VERSION"; }
src_top_name() { printf 'trustforge-%s-source' "$VERSION"; }
src_name() { printf 'trustforge-%s-source.tar.gz' "$VERSION"; }

# GNU tar only. bsdtar rejects --sort, and the CI image and a developer's box are not promised to
# agree, so probe instead of assuming. Zeroing mtime and ownership makes two runs over the same
# bytes comparable; that is a checking convenience, not a claim of full reproducibility.
detect_tar_flags() {
    TAR_FLAGS=(--format=gnu --owner=0 --group=0 --numeric-owner "--mtime=@$EPOCH")
    if tar --help 2>&1 | grep -q -- '--sort'; then
        TAR_FLAGS+=(--sort=name)
    else
        hint "this tar has no --sort, so archive member order is filesystem dependent"
    fi
}

stage_tree() {
    local stage=$1 top f
    top=$(top_name)
    install -d -m 0755 "$stage/$top" "$stage/$top/app"
    cp -a "$APP_DIR/." "$stage/$top/app/"
    # Normalise rather than inherit. A Windows bind mount reports every file as 0777 because NTFS has
    # no POSIX bits, a docker cp reports the image's bits, and a developer's umask reports something
    # else again; only 0644/0755 is a statement that is true on every one of those hosts. Nothing in
    # the app tree is executed by name (the unit runs dotnet TrustForge.dll), and install.sh makes the
    # staged release read-only anyway, so no file here needs an execute bit.
    find "$stage/$top/app" -type d -exec chmod 0755 {} +
    find "$stage/$top/app" -type f -exec chmod 0644 {} +

    install -d -m 0755 "$stage/$top/deploy/bare-metal" "$stage/$top/docs"
    for f in install.sh trustforge.service trustforge.env.example; do
        [[ -f $REPO_ROOT/deploy/bare-metal/$f ]] ||
            die "missing deploy/bare-metal/$f: the installer needs its own unit and env template,
which it resolves relative to the package root."
        cp -p "$REPO_ROOT/deploy/bare-metal/$f" "$stage/$top/deploy/bare-metal/$f"
    done
    # BAREMETAL.md tells people to run ./install.sh, and core.filemode=false on the author's Windows
    # box means a 100644 index entry stays invisible here. Setting the mode in the packager as well
    # as in the index means a published release is installable even if the index regresses.
    chmod 0755 "$stage/$top/deploy/bare-metal/install.sh"
    chmod 0644 "$stage/$top/deploy/bare-metal/trustforge.service"
    chmod 0644 "$stage/$top/deploy/bare-metal/trustforge.env.example"

    for f in "${DOC_FILES[@]}"; do
        [[ -f $REPO_ROOT/$f ]] ||
            die "docs/$f is listed in DOC_FILES but does not exist in the repository."
        cp -p "$REPO_ROOT/$f" "$stage/$top/docs/$f"
        chmod 0644 "$stage/$top/docs/$f"
    done
    log "staged app/, deploy/bare-metal/ and docs/ under $top/"
}

stage_readme() {
    local stage=$1 top
    top=$(top_name)
    cat >"$stage/$top/README.md" <<EOF
# TrustForge $VERSION

To install on Ubuntu 24.04 with systemd, from a machine with no source checkout:

    sha256sum -c $(pkg_name).sha256
    tar -xzf $(pkg_name)
    cd $top
    sudo bash deploy/bare-metal/install.sh

The application is framework-dependent, so this is not an offline install: the installer fetches the
ASP.NET Core 10 shared runtime from dot.net. Read docs/BAREMETAL.md before the first run. Port 53, an
OIDC issuer, PostgreSQL 17 and the settings that are frozen at first boot are preconditions; the
installer detects them and will not reconfigure your host on your behalf.
EOF
    chmod 0644 "$stage/$top/README.md"
}

contains_crlf() {
    grep -rlqI -e $'\r' "$@" 2>/dev/null
}

# Guards run against the staged tree because at this point the bytes are still ours to inspect, not
# something a root shell is about to unpack from the internet. guard_archive then repeats the parts
# that only an archive listing can show.
guard_stage() {
    local stage=$1 top hits token n
    top=$(top_name)
    # Named tokens, not a count of lines matching __TF_: the file's own header comment mentions the
    # sentinel convention, so a count would be off by one and would not say which value went missing.
    for token in __TF_DB_PASSWORD__ __TF_OIDC_AUTHORITY__ __TF_OIDC_AUDIENCE__; do
        n=$(grep -c -- "$token" "$stage/$top/deploy/bare-metal/trustforge.env.example" || true)
        [[ -n $n ]] || n=0
        if [[ $n -ne 1 ]]; then
            die "trustforge.env.example must contain the $token sentinel exactly once; found $n. An
example whose real values were templated into it would install a machine pointed at a database it
cannot reach, and the release would ship that mistake to every host."
        fi
    done
    # Scoped to the files something parses, not the documentation: a Windows checkout legitimately
    # has CRLF in *.md (text is auto-normalised there), which is cosmetic, while CRLF in the unit is
    # rejected by systemd outright and CRLF in the env template appends a carriage return to every
    # value including the database password. .gitattributes pins the three of them to eol=lf; this
    # is where that pin gets enforced rather than merely asserted.
    if contains_crlf "$stage/$top/deploy"; then
        die "CRLF in a shipped script, unit, or env template: systemd rejects a CRLF unit outright,
and every value in trustforge.env gains a carriage return."
    fi
    # Patterns that can carry a secret, plus the expanded env file the installer generates. Neither
    # repository tracks such files today; this exists so that cannot change silently in a release.
    hits=$(find "$stage" \( -name '*.env' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' \
        -o -name '*.pfx' -o -name 'id_rsa' -o -name 'id_ed25519' -o -name '*.credential' \
        -o -path '*/secrets/*' -o -name 'appsettings.Production*' \) -print | head -20 || true)
    if [[ -n $hits ]]; then
        die "refusing to package files that can carry a secret: $hits"
    fi
    if [[ -n $(find "$stage/$top" -type l -print | head -1) ]]; then
        die "the staged tree contains a symlink; publish output has none."
    fi
    log "guards: sentinels intact, no CRLF, no secret-bearing files, no symlinks"
}

write_manifest() {
    local stage=$1 top
    top=$(top_name)
    cat >"$stage/$top/MANIFEST.json" <<EOF
{
  "product": "trustforge",
  "packageFormat": "1",
  "version": "$VERSION",
  "tag": "${TAG:-unknown}",
  "gitSha": "$GIT_SHA",
  "gitShaShort": "$GIT_SHA_SHORT",
  "gitDirty": "$GIT_DIRTY",
  "releaseId": "$RELEASE_ID",
  "libraryRepo": "$LIB_NAME",
  "libraryRef": "$LIB_REF",
  "libraryGitSha": "$LIB_SHA",
  "dnsServerVersion": "$ENGINE_VERSION",
  "publishMode": "framework-dependent",
  "requiredRuntime": "Microsoft.AspNetCore.App 10.0",
  "sdkVersion": "$SDK_VERSION",
  "baseImageDigest": "$BASE_IMAGE_DIGEST",
  "buildHost": "$BUILD_HOST",
  "buildTimestamp": "$BUILD_TIMESTAMP",
  "installCommand": "sudo bash deploy/bare-metal/install.sh",
  "checksums": "SHA256SUMS",
  "license": "GPL-3.0"
}
EOF
    chmod 0644 "$stage/$top/MANIFEST.json"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
            "$stage/$top/MANIFEST.json" ||
            die "MANIFEST.json is not parseable JSON. install.sh reads it with sed and validates
every value it interpolates, but a release asset that no parser accepts is a defect regardless."
    else
        hint "no python3 here, so MANIFEST.json was written but not parsed back."
    fi
}

write_sums() {
    local stage=$1 top
    top=$(top_name)
    # Members only, paths relative to the package root, in sha256sum -c format. SHA256SUMS cannot
    # hash itself, and the tarball's checksum is a separate asset for the same reason. It is built
    # in a temporary name and moved into place so the walk can never read the file it is writing.
    ( cd "$stage/$top" &&
        find . -type f ! -name '*SHA256SUMS*' -exec sha256sum {} + |
        sed 's|  \./|  |' | LC_ALL=C sort >SHA256SUMS.tmp )
    mv "$stage/$top/SHA256SUMS.tmp" "$stage/$top/SHA256SUMS"
    [[ -s $stage/$top/SHA256SUMS ]] || die "SHA256SUMS came out empty."
    if ! ( cd "$stage/$top" && sha256sum -c --quiet SHA256SUMS ); then
        die "SHA256SUMS does not verify against the staged tree it ships with."
    fi
    chmod 0644 "$stage/$top/SHA256SUMS"
    log "SHA256SUMS covers $(wc -l <"$stage/$top/SHA256SUMS") members and verifies"
}

guard_archive() {
    local tarball=$1 top names offenders bad_modes verbose
    top=$(top_name)
    # Every listing is captured into a variable first and then matched with a here-string. Under
    # set -o pipefail, piping straight into grep -q is wrong twice over: grep closes the pipe on the
    # first match so tar dies of SIGPIPE and the pipeline reports failure even when the file is fine,
    # and the same inversion makes the checks that must fire silently report success.
    names=$(tar -tzf "$tarball")
    verbose=$(tar -tvzf "$tarball")
    [[ -n $names ]] || die "$tarball contains no members."
    if grep -qE '(^/|(^|/)\.\.(/|$)|[[:space:]])' <<<"$names"; then
        die "archive member names contain a leading '/', a '..' component, or whitespace. The
installer parses this listing as root before it extracts anything, and none of the three is worth
the ambiguity."
    fi
    offenders=$(grep -v "^$top/" <<<"$names" || true)
    if [[ -n $offenders ]]; then
        head -5 <<<"$offenders" >&2
        die "archive has members outside the single top-level directory $top/."
    fi
    if grep -qE '(^|/)(\.git|bin|obj|node_modules)(/|$)' <<<"$names"; then
        die "archive carries a build or VCS directory."
    fi
    if grep -qE '\.(env|pem|key|p12|pfx|credential)$|(^|/)secrets(/|$)' <<<"$names"; then
        die "archive carries a file that can hold a secret."
    fi
    # tar -tv fields: mode, owner, size, date, time, name. Mode is 10 characters: type, then
    # r/w/x, r/w/x, r/w/x, where a setuid bit replaces the owner x, setgid the group x, and sticky
    # the other x. Anything that is not a regular file or a directory is rejected outright: a
    # symlink member combined with the cp -a in install.sh is an arbitrary path write as root.
    bad_modes=$(awk '
        { m = $1; n = $NF;
          if (m !~ /^[-d]/)            print "special member: " m " " n;
          else if (substr(m, 4, 1) ~ /[sS]/) print "setuid: " m " " n;
          else if (substr(m, 7, 1) ~ /[sS]/) print "setgid: " m " " n;
          else if (substr(m, 10, 1) ~ /[tT]/) print "sticky: " m " " n;
          else if (substr(m, 6, 1) ~ /[wW]/)  print "group-writable: " m " " n;
          else if (substr(m, 9, 1) ~ /[wW]/)  print "world-writable: " m " " n;
        }' <<<"$verbose")
    if [[ -n $bad_modes ]]; then
        head -20 <<<"$bad_modes" >&2
        die "archive members carry unsafe modes or types."
    fi
    grep -q '^\-rwxr-xr-x .*deploy/bare-metal/install\.sh$' <<<"$verbose" ||
        die "install.sh is not mode 0755 inside the archive, so ./install.sh would not run."
    log "archive listing: one top dir, no traversal, no special members, no unsafe modes, install.sh executable"
}

make_package_archive() {
    local stage=$STAGE_ROOT/pkg top
    top=$(top_name)
    rm -rf "$stage"
    install -d -m 0700 "$stage"
    stage_tree "$stage"
    stage_readme "$stage"
    guard_stage "$stage"
    write_manifest "$stage"
    write_sums "$stage"
    tar "${TAR_FLAGS[@]}" -cf - -C "$stage" "$top" | gzip -n9 >"$OUT_DIR/$(pkg_name)"
    guard_archive "$OUT_DIR/$(pkg_name)"
    # The manifest ships both inside the archive and as a standalone asset: reading where a binary
    # came from should not require downloading the binary first.
    cp "$stage/$top/MANIFEST.json" "$OUT_DIR/$(manifest_name)"
    rm -rf "$stage"
    ( cd "$OUT_DIR" && sha256sum "$(pkg_name)" >"$(pkg_name).sha256" )
    chmod 0644 "$OUT_DIR/$(pkg_name).sha256" "$OUT_DIR/$(manifest_name)"
    log "$(pkg_name) is $(du -h "$OUT_DIR/$(pkg_name)" | cut -f1)"
}

# GPLv3 corresponding source: this repository at the packaged commit plus the exact library revision
# that produced the DLLs inside app/. Neither tree is rewritten - git archive emits tracked bytes,
# so gitignored paths (deploy/bare-metal/*.env, dist/) are absent by construction.
make_source_archive() {
    local stage=$STAGE_ROOT/src top
    top=$(src_top_name)
    rm -rf "$stage"
    install -d -m 0700 "$stage"
    install -d -m 0755 "$stage/$top/TrustForge" "$stage/$top/TechnitiumLibrary"
    git -C "$REPO_ROOT" archive --format=tar HEAD | tar -x -f - -C "$stage/$top/TrustForge"
    git -C "$LIB_DIR" archive --format=tar "$LIB_SHA" | tar -x -f - -C "$stage/$top/TechnitiumLibrary"
    cat >"$stage/$top/SOURCE.md" <<EOF
# TrustForge $VERSION corresponding source

Two components, both GPLv3, as the binary asset was built:

| Component | Source | Revision |
| --- | --- | --- |
| TrustForge | $REPO_ROOT_NAME | $GIT_SHA |
| TechnitiumLibrary | $LIB_NAME | $LIB_SHA |

Build inputs and the directory layout the build expects: build.md. Packaging: deploy/release/make-package.sh.
EOF
    chmod 0644 "$stage/$top/SOURCE.md"
    [[ -s $stage/$top/TrustForge/TrustForge.Api/TrustForge.Api.csproj ]] ||
        die "the corresponding-source archive does not contain the application project."
    [[ -s $stage/$top/TechnitiumLibrary/TechnitiumLibrary.Net/TechnitiumLibrary.Net.csproj ]] ||
        die "the corresponding-source archive does not contain the library it was built against."
    if find "$stage/$top" \( -name '*.env' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' \
        -o -name '*.pfx' -o -path '*/secrets/*' \) -print | grep -q .; then
        die "the source archive carries a file that can hold a secret. Neither repository tracks one
today; if that changed, fix the ignore rule rather than relaxing this gate."
    fi
    tar "${TAR_FLAGS[@]}" -cf - -C "$stage" "$top" | gzip -n9 >"$OUT_DIR/$(src_name)"
    rm -rf "$stage"
    ( cd "$OUT_DIR" && sha256sum "$(src_name)" >"$(src_name).sha256" )
    chmod 0644 "$OUT_DIR/$(src_name).sha256"
    log "$(src_name) is $(du -h "$OUT_DIR/$(src_name)" | cut -f1)"
}

cleanup() {
    [[ -n $STAGE_ROOT && -d $STAGE_ROOT ]] && rm -rf "$STAGE_ROOT"
    return 0
}

main() {
    parse_args "$@"
    resolve_version
    require_app_dir
    collect_provenance
    detect_tar_flags
    STAGE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/trustforge-package.XXXXXX")
    trap cleanup EXIT
    install -d -m 0755 "$OUT_DIR"
    make_package_archive
    if [[ $SKIP_SOURCE -eq 0 ]]; then
        make_source_archive
    else
        hint "--skip-source: no corresponding-source archive, so this output is not distributable."
    fi
    local a found=0
    for a in "$OUT_DIR"/trustforge-*; do
        [[ -f $a ]] || continue
        found=1
        log "$(basename -- "$a")"
    done
    [[ $found -eq 1 ]] || hint "no trustforge-* assets in $OUT_DIR; that is a bug."
}

main "$@"
