#!/bin/sh
# Builds RediWM's release tarballs, one per distro, each in a clean container
# of that distro so the binaries link its libraries. Run on the maintainer's
# machine; users never do (scripts/install.sh downloads the result).
#
#   scripts/make-release.sh [--out DIR] [--src DIR] [--no-verify] [FAMILY...]
#
# FAMILY is arch, debian, ubuntu or fedora (default: all). The source is a
# fresh `git archive HEAD`, so a release is exactly one commit and local edits
# never leak in; --src DIR builds that directory instead. DIR (default
# ./release) ends up holding rediwm-FAMILY-x86_64.tar.gz for each family built,
# plus SHA256SUMS over every tarball in it. Each tarball is then installed by
# the real install.sh in a fresh container (--no-verify skips that).
#
# Upload the tarballs and SHA256SUMS to a GitHub release (a tag named v<version>
# from build.zig.zon); install.sh reads releases/latest/download/. Tests are
# not run here: run `zig build test` and the integration tests first.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/release"
src=""
verify=yes
families=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out) out=$2; shift ;;
        --src) src=$2; shift ;;
        --no-verify) verify=no ;;
        arch|debian|ubuntu|fedora) families="$families $1" ;;
        *) echo "Usage: $0 [--out DIR] [--src DIR] [--no-verify] [arch|debian|ubuntu|fedora ...]" >&2; exit 1 ;;
    esac
    shift
done
[ -n "$families" ] || families="arch debian ubuntu fedora"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

engine=${REDIWM_CONTAINER_ENGINE:-}
if [ -z "$engine" ]; then
    for e in podman docker; do command -v "$e" >/dev/null 2>&1 && { engine=$e; break; }; done
fi
[ -n "$engine" ] || die "podman or docker is required"

image_for() {
    case "$1" in
        arch) echo docker.io/library/archlinux:latest ;;
        debian) echo docker.io/library/debian:13 ;;
        ubuntu) echo docker.io/library/ubuntu:24.04 ;;
        fedora) echo docker.io/library/fedora:latest ;;
    esac
}

mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/rediwm-release.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
# Downloaded once and shared by every container: the Zig toolchain and Zig's
# package cache (zig-wlroots and friends).
cache="${REDIWM_RELEASE_CACHE:-$HOME/.cache/rediwm-release}"
mkdir -p "$cache/zig" "$cache/zig-global"

if [ -z "$src" ]; then
    git -C "$here" rev-parse --verify HEAD >/dev/null 2>&1 || die "not a git checkout; pass --src DIR"
    revision=$(git -C "$here" rev-parse --short HEAD)
    log "Exporting HEAD ($revision)"
    mkdir "$work/src"
    git -C "$here" archive HEAD | tar -x -C "$work/src"
    src="$work/src"
else
    src=$(CDPATH= cd -- "$src" && pwd)
    revision=${REDIWM_REVISION:-unknown}
fi

# Each build writes into its tree (zig-out), so each family gets its own copy.
# Rootless podman maps root in the container to this user, so what it writes to
# a bind mount is already ours; docker's root-owned files are handed back.
run() { # family script args...
    family=$1; shift
    rc=0
    "$engine" run --rm \
        -v "$work/$family:/work" -v "$out:/out" \
        -v "$cache/zig:/cache/zig" -v "$cache/zig-global:/cache/zig-global" \
        -e REDIWM_ZIG_DIR=/cache/zig -e ZIG_GLOBAL_CACHE_DIR=/cache/zig-global \
        -e REDIWM_REVISION="$revision" -e ZIG_JOBS="${ZIG_JOBS:-}" \
        -e OWNER="$([ "$engine" = docker ] && echo "$(id -u):$(id -g)")" \
        "$(image_for "$family")" sh -c '"$@"; rc=$?; [ -z "$OWNER" ] || chown -R "$OWNER" /work /out /cache; exit $rc' sh "$@" || rc=$?
    return $rc
}

for family in $families; do
    log "== $family =="
    mkdir "$work/$family"
    cp -a "$src/." "$work/$family/"
    run "$family" sh /work/scripts/release-build.sh "$family" /out
    if [ "$verify" = yes ]; then
        log "Verifying $family in a fresh container"
        run "$family" sh /work/scripts/release-verify.sh "$family" /out
    fi
    rm -rf -- "$work/$family"
done

(cd "$out" && sha256sum rediwm-*-x86_64.tar.gz > SHA256SUMS)
log "Done. Upload these to the release:"
(cd "$out" && ls -l rediwm-*-x86_64.tar.gz SHA256SUMS >&2)
