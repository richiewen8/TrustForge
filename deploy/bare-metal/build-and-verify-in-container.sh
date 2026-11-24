#!/usr/bin/env bash
# Build the release assets the way CI does, and check them, without a target host.
#
# It exists because BAREMETAL.md used to ask an operator to paste two docker commands by hand, and
# because a maintainer on a laptop has the same question CI has: does the archive this commit produces
# actually validate, and does the installer still refuse the places it must refuse?
#
# Proven here: the publish bytes come out of the repository's own Dockerfile build stage; the packager
# assembles the release assets and their checksums verify; install.sh --validate-package accepts the
# archive and refuses hostile ones; every script passes shellcheck -S style; the unit file parses under
# systemd-analyze; the installer refuses a container as root and refuses a non-root caller.
#
# NOT proven here: that TrustForge installed and ran on a machine. No service was started and no
# migration was applied. BAREMETAL.md's "On-target checklist" is still the only installation evidence.
#
# Requires docker with a running daemon, and a TechnitiumLibrary checkout next to this repository
# (the Dockerfile's build context is that parent directory) unless --skip-build is given.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
# pwd -W is the Git Bash builtin that prints D:/... instead of /d/...; docker.exe on Windows cannot
# mount or read the POSIX form. On Linux the builtin does not exist and the plain pwd is correct.
PARENT=$(cd -- "$REPO_ROOT/.." && { pwd -W 2>/dev/null || pwd; })
# The -f argument needs the same treatment as the mount source: MSYS_NO_PATHCONV is exported below, so
# a POSIX /d/... reaches docker.exe unconverted and the build fails on a path that looks like "\d:".
REPO_WIN=$(cd -- "$REPO_ROOT" && { pwd -W 2>/dev/null || pwd; })

IMAGE=tf-build:local
LIBRARY_DIR=$PARENT/TechnitiumLibrary
DIST=$REPO_ROOT/deploy/bare-metal/dist
SKIP_BUILD=0
# Resolved only when this script actually builds: the packager takes the base digest from its
# environment, and a value from a build someone else ran would be a claim about bytes not measured here.
base_digest=

usage() {
    cat <<EOF
Usage: build-and-verify-in-container.sh [OPTION]...

Build the image's build stage, extract /out/publish, package the release assets into
deploy/bare-metal/dist (git-ignored), and run every check that does not need real hardware.

Options:
  --library-dir DIR   TechnitiumLibrary checkout to build against. Default: this repository's sibling.
  --image NAME        Tag for the build-stage image. Default: tf-build:local.
  --skip-build        Reuse an existing --image instead of building; the corresponding-source archive
                      is skipped too when no library checkout is present.
  -h, --help          This text.
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --library-dir) [[ -d ${2:-} ]] || { printf 'no such library dir: %s\n' "${2:-}" >&2; exit 2; }
                       LIBRARY_DIR=$(cd -- "$2" && pwd); shift 2 ;;
        --image)       IMAGE=${2:?--image needs a name}; shift 2 ;;
        --skip-build)  SKIP_BUILD=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage >&2; printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# Git Bash rewrites /work into a Windows path inside -v arguments, and the daemon rejects the result.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
export DEBIAN_FRONTEND=noninteractive

[[ -f $REPO_ROOT/Dockerfile ]] || { printf 'no Dockerfile at %s\n' "$REPO_ROOT" >&2; exit 1; }
[[ -f $REPO_ROOT/deploy/release/make-package.sh ]] || { printf 'no deploy/release/make-package.sh\n' >&2; exit 1; }
command -v docker >/dev/null || { printf 'docker is not on PATH\n' >&2; exit 1; }
docker info >/dev/null 2>&1 || { printf 'no reachable docker daemon\n' >&2; exit 1; }

version=$(awk -F'[<>]' '/<Version>/{print $3; exit}' "$REPO_ROOT/TrustForge.Api/TrustForge.Api.csproj")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    { printf 'TrustForge.Api/TrustForge.Api.csproj declares no usable <Version> (got %s)\n' "${version:-empty}" >&2; exit 1; }

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
uidgid=$(id -u):$(id -g)

if [[ $SKIP_BUILD -eq 0 ]]; then
    step "build the application in the Dockerfile's own build stage"
    [[ -d $LIBRARY_DIR/TechnitiumLibrary.ByteTree ]] ||
        { printf 'no TechnitiumLibrary checkout at %s.\nThe Dockerfile build context is that directory'"'"'s parent, so the sibling is required: pass
--library-dir, or --skip-build with an image you have already built.\n' "$LIBRARY_DIR" >&2; exit 1; }
    # The .dockerignore sits next to the Dockerfile but must be at the context root, which is the
    # parent. Without it bin/, obj/ and .git/ travel into the build and a stale HintPath DLL can be
    # compiled in.
    ignored=$PARENT/.dockerignore
    created_ignore=0
    if [[ ! -e $ignored ]]; then
        cp "$REPO_ROOT/Dockerfile.dockerignore" "$ignored"
        created_ignore=1
    fi
    trap '[[ $created_ignore -eq 1 ]] && rm -f "$ignored" || true' EXIT
    docker build -f "$REPO_WIN/Dockerfile" --target build -t "$IMAGE" "$PARENT"
    trap - EXIT
    # BuildKit keeps the stage's base out of the image store, so the digest has to come from the registry
    # rather than from anything the build left behind. Not being able to read it is not an error here:
    # the packager records an empty value as unknown instead of guessing.
    base_image=$(awk '/^FROM .* AS build/{print $2; exit}' "$REPO_ROOT/Dockerfile")
    base_digest=$(docker buildx imagetools inspect "$base_image" --format '{{json .Manifest.Digest}}' \
        2>/dev/null | tr -d '"') || base_digest=
    [[ $base_digest == sha256:* ]] || base_digest=
    printf '  base image %s = %s\n' "$base_image" "${base_digest:-unresolved}"
fi

step "extract the publish output the image runs"
rm -rf "$DIST"
install -d -m 0755 "$DIST/publish"
cid=$(docker create "$IMAGE" true)
# Relative destination: docker.exe resolves ./ against the inherited working directory, which works on
# both platforms, where an MSYS /d/... path passed from Git Bash does not.
(cd "$DIST/publish" && docker cp "$cid:/out/publish/." ./)
docker rm -v "$cid" >/dev/null
dllcount=$(find "$DIST/publish" -maxdepth 1 -name 'TrustForge.dll' -print)
[[ -n $dllcount ]] || { printf 'no TrustForge.dll in %s\n' "$DIST/publish" >&2; exit 1; }
printf 'publish tree: %s files\n' "$(find "$DIST/publish" -type f | wc -l)"

step "package, validate, lint and refuse inside ubuntu:24.04"
# One container for all of it: the checks share apt-installed git, shellcheck and systemd, and they
# have to run on the same distribution the installer supports rather than on whatever the laptop has.
#
# The gate is written to a file and run by path rather than piped into `bash -`: apt-get reads its
# stdin, and a piped script whose body is eaten mid-way by a subprocess exits 0 while having checked
# nothing. Inside dist/ (git-ignored, and a directory, so the packager's stray-file guard ignores it).
gate_dir=$DIST/gate
rm -rf "$gate_dir"
install -d -m 0755 "$gate_dir"
# The library goes in at a fixed path so the gate need not know where the laptop keeps it, and read
# only because nothing in here should be writing to a build input.
library_mount=()
library_in=
if [[ -d $LIBRARY_DIR/TechnitiumLibrary.ByteTree ]]; then
    library_mount=(-v "$LIBRARY_DIR:/library:ro")
    library_in=/library
fi
cat >"$gate_dir/gate.sh" <<'CONTAINER'
set -uo pipefail
cd "/work/$TF_REPO"
version=$TF_VERSION
dist="/work/$TF_REPO/deploy/bare-metal/dist"
pkg=$dist/trustforge-$version-linux.tar.gz
top=trustforge-$version-linux
fail=0
say() { printf '  %s\n' "$*"; }
has_cr() { grep -q "$(printf '\r')" "$1" 2>/dev/null; }
say "gate started in $(uname -sr) as $(id -un)"
apt-get update -qq >/dev/null </dev/null
apt-get install -y -qq git shellcheck systemd >/dev/null </dev/null

say "shellcheck -S style and bash -n on every repository script"
for s in deploy/bare-metal/install.sh deploy/release/make-package.sh \
         deploy/bare-metal/build-and-verify-in-container.sh; do
    if bash -n "$s" && shellcheck -S style "$s"; then
        say "clean: $s"
    else
        printf '  FAILED  lint: %s\n' "$s"; fail=$((fail + 1))
    fi
done

say "make-package.sh"
if [ -n "${TF_LIBRARY:-}" ]; then
    source_args=(--library-dir "$TF_LIBRARY")
else
    source_args=(--skip-source)
    say "no library checkout in the container: the corresponding-source archive is skipped"
fi
if bash deploy/release/make-package.sh --app-dir "$dist/publish" --out "$dist" \
        --tag "v$version" "${source_args[@]}"; then
    say "assets written"
else
    printf '  FAILED  the packager refused the tree it was handed\n'; fail=$((fail + 1))
fi

# The same assertion CI makes, so a passthrough that silently stopped working is caught locally too.
if [ -n "${BASE_IMAGE_DIGEST:-}" ]; then
    say "the manifest carries the base digest this build resolved"
    recorded=$(awk -F'"' '/"baseImageDigest"/{print $4; exit}' \
        "$dist/trustforge-$version-linux-manifest.json")
    if [ "$recorded" = "$BASE_IMAGE_DIGEST" ]; then
        say "MANIFEST.json: $recorded"
    else
        printf '  FAILED  MANIFEST records %s, this build resolved %s\n' \
            "${recorded:-<absent>}" "$BASE_IMAGE_DIGEST"
        fail=$((fail + 1))
    fi
fi

say "install.sh --validate-package on the archive the packager just wrote"
if bash deploy/bare-metal/install.sh --validate-package "$pkg"; then
    say "accepted"
else
    printf '  FAILED  --validate-package rejected the published archive\n'; fail=$((fail + 1))
fi

say "the packaged installer is byte-identical to the repository's"
rm -rf /tmp/unpacked; install -d -m 0755 /tmp/unpacked
tar -xz --no-same-owner -f "$pkg" -C /tmp/unpacked
if diff -q deploy/bare-metal/install.sh "/tmp/unpacked/$top/deploy/bare-metal/install.sh"; then
    [ -x "/tmp/unpacked/$top/deploy/bare-metal/install.sh" ] &&
        say "identical, and executable" ||
        { printf '  FAILED  the packaged installer lost its exec bit\n'; fail=$((fail + 1)); }
else
    printf '  FAILED  the packaged installer differs from the one in this checkout\n'; fail=$((fail + 1))
fi

say "hostile archives must be refused"
w=/tmp/hostile; rm -rf "$w"; install -d -m 0755 "$w"
fresh() { rm -rf "$w/v"; install -d -m 0755 "$w/v"; tar -xzf "$pkg" -C "$w/v"; }
expect_refusal() { # name, archive
    local name=$1 archive=$2
    if bash deploy/bare-metal/install.sh --validate-package "$archive" >"/tmp/$name.log" 2>&1; then
        printf '  FAILED  %s was accepted as a release package\n' "$name"; fail=$((fail + 1))
    else
        printf '  refused %s: %s\n' "$name" "$(grep -m1 '^  FAIL  ' "/tmp/$name.log" | sed 's/^  FAIL  //')"
    fi
}
# A symlink member plus cp -a during staging is an arbitrary write as root.
fresh; ln -sfn /etc/shadow "$w/v/$top/app/evil-link"
tar -czf "$w/symlink.tar.gz" -C "$w/v" "$top"
expect_refusal symlink-member "$w/symlink.tar.gz"
# An absolute member name escapes the staging directory whatever extraction flags are used.
fresh; tar -czf "$w/absolute.tar.gz" -P -C "$w/v/$top" . /etc/hostname 2>/dev/null
expect_refusal absolute-member "$w/absolute.tar.gz"
# Someone else's expanded runtime file carries their real database password onto this host.
fresh; printf 'DB_PASSWORD=hunter2\n' >"$w/v/$top/deploy/bare-metal/trustforge.env"
tar -czf "$w/env.tar.gz" -C "$w/v" "$top"
expect_refusal env-member "$w/env.tar.gz"
# The defect that made a published release uninstallable once.
fresh; chmod 0644 "$w/v/$top/deploy/bare-metal/install.sh"
tar -czf "$w/noexec.tar.gz" -C "$w/v" "$top"
expect_refusal install-sh-without-exec-bit "$w/noexec.tar.gz"
# Bytes that no longer match the archive's own record of them.
fresh; printf 'x' >>"$w/v/$top/app/TrustForge.deps.json"
tar -czf "$w/tampered.tar.gz" -C "$w/v" "$top"
expect_refusal tampered-payload "$w/tampered.tar.gz"

say "systemd-analyze verify on the unit file (staged paths, fake dotnet)"
install -d -m 0755 /opt/dotnet /opt/trustforge/app/current /etc/trustforge
printf '#!/bin/sh\nexit 0\n' >/opt/dotnet/dotnet
chmod 0755 /opt/dotnet/dotnet
: >/opt/trustforge/app/current/TrustForge.dll
: >/etc/trustforge/trustforge.env
if systemd-analyze verify deploy/bare-metal/trustforge.service >/tmp/unit.log 2>&1; then
    say "verifies; output: $(wc -l </tmp/unit.log | tr -d ' ') line(s)"
else
    printf '  FAILED  systemd-analyze verify:\n'; sed 's/^/    /' /tmp/unit.log; fail=$((fail + 1))
fi
sed 's/^/    unit: /' /tmp/unit.log

say "the release body is LF-clean"
if [ -f docs/release-notes/v"$version".md ]; then
    if has_cr docs/release-notes/v"$version".md; then
        printf '  FAILED  docs/release-notes/v%s.md contains CR\n' "$version"; fail=$((fail + 1))
    else
        say "docs/release-notes/v$version.md: no CR"
    fi
else
    say "docs/release-notes/v$version.md not written yet"
fi

chown -R "$TF_UIDGID" "$dist" 2>/dev/null || true
printf '  container failures: %s\n' "$fail"
[ "$fail" -eq 0 ]
CONTAINER

docker run --rm -e TF_UIDGID="$uidgid" -e TF_VERSION="$version" -e TF_REPO="$(basename -- "$REPO_ROOT")" \
    "${library_mount[@]}" -e TF_LIBRARY="$library_in" -e BASE_IMAGE_DIGEST="$base_digest" \
    -v "$PARENT":/work \
    --entrypoint bash ubuntu:24.04 "/work/$(basename -- "$REPO_ROOT")/deploy/bare-metal/dist/gate/gate.sh"

# A green container run is not evidence that anything was checked; the assets are the evidence.
step "the assets the container wrote"
expected=("trustforge-$version-linux.tar.gz" "trustforge-$version-linux.tar.gz.sha256"
          "trustforge-$version-linux-manifest.json")
[[ -n $library_in ]] &&
    expected+=("trustforge-$version-source.tar.gz" "trustforge-$version-source.tar.gz.sha256")
for a in "${expected[@]}"; do
    [[ -f $DIST/$a ]] || { printf 'the container produced no %s\n' "$a" >&2; exit 1; }
    printf '  %s\n' "$a"
done
(cd "$DIST" && sha256sum -c "trustforge-$version-linux.tar.gz.sha256")
if [[ -f $DIST/trustforge-$version-source.tar.gz.sha256 ]]; then
    (cd "$DIST" && sha256sum -c "trustforge-$version-source.tar.gz.sha256")
fi
rm -rf "$gate_dir"

step "the installer must refuse a container it is asked to install onto"
docker run --rm -e TF_REPO="$(basename -- "$REPO_ROOT")" -v "$PARENT":/w:ro --entrypoint bash \
    ubuntu:24.04 -c '
    out=$(bash "/w/$TF_REPO/deploy/bare-metal/install.sh" --check-only 2>&1); rc=$?
    printf "  as root:  rc=%s  %s\n" "$rc" "$(printf "%s\n" "$out" | tail -1)"
    [ $rc -ne 0 ] || { echo "  FAILED  the installer ran inside a container"; exit 1; }
    printf "%s\n" "$out" | grep -qiE "not systemd|inside a container|container cgroup" ||
        { echo "  FAILED  refused for an unexpected reason"; exit 1; }'

step "the installer must refuse a caller that is not root"
docker run --rm -u 1000:1000 -e TF_REPO="$(basename -- "$REPO_ROOT")" -v "$PARENT":/w:ro \
    --entrypoint bash ubuntu:24.04 -c '
    out=$(bash "/w/$TF_REPO/deploy/bare-metal/install.sh" --check-only 2>&1); rc=$?
    printf "  as uid 1000:  rc=%s  %s\n" "$rc" "$(printf "%s\n" "$out" | tail -1)"
    [ $rc -ne 0 ] || { echo "  FAILED  the installer ran as an unprivileged user"; exit 1; }
    printf "%s\n" "$out" | grep -qi "run as root" ||
        { echo "  FAILED  refused for an unexpected reason"; exit 1; }'

step "assets in deploy/bare-metal/dist"
find "$DIST" -maxdepth 1 -type f -printf '  %f  %s bytes\n' | sort
printf '\nNot proven by any of the above: that the unit activates, that migrations run, that port 53 is\n'
printf 'bound with CAP_NET_BIND_SERVICE, that 5000 and 5380 are loopback-only, or that PostgreSQL 17 is\n'
printf 'provisioned. That is BAREMETAL.md'"'"'s "On-target checklist", on real hardware.\n'
