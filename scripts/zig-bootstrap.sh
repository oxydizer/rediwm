#!/bin/sh
# Prints the path of a Zig toolchain that satisfies build.zig.zon's
# minimum_zig_version, bootstrapping one from ziglang.org when the system has
# none:
#
#   ZIG=$(sh scripts/zig-bootstrap.sh)
#
# Zig is pre-1.0 and moves fast enough that distro versions routinely mismatch
# what a given commit needs, so this pins and downloads directly (like rustup
# does for Rust). Everything but the final path goes to stderr.
set -eu

ZIG_ROOT="${REDIWM_ZIG_DIR:-$HOME/.local/share/rediwm/zig}"
zon="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/build.zig.zon"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# True if $1 >= $2 as a dotted version string (GNU sort -V handles the compare).
version_ge() { [ "$1" = "$2" ] || [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

ZIG_PIN=$(grep -o 'minimum_zig_version = "[^"]*"' "$zon" | cut -d'"' -f2)
[ -n "$ZIG_PIN" ] || die "could not read minimum_zig_version from $zon"

zig_acceptable() {
    command -v "$1" >/dev/null 2>&1 || return 1
    v=$("$1" version 2>/dev/null) || return 1
    version_ge "$v" "$ZIG_PIN"
}

if zig_acceptable zig; then
    log "Using system zig ($(zig version))"
    command -v zig
    exit 0
elif zig_acceptable "$ZIG_ROOT/zig-$ZIG_PIN/zig"; then
    log "Using previously bootstrapped zig $ZIG_PIN"
    echo "$ZIG_ROOT/zig-$ZIG_PIN/zig"
    exit 0
fi

log "No zig >= $ZIG_PIN on PATH; bootstrapping $ZIG_PIN from ziglang.org"
case "$(uname -m)" in
    x86_64|aarch64) zig_arch=$(uname -m) ;;
    *) die "unsupported CPU architecture $(uname -m) for automatic zig bootstrap; install zig $ZIG_PIN manually, put it on PATH, and re-run" ;;
esac
target="$zig_arch-linux"
mkdir -p "$ZIG_ROOT"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if command -v python3 >/dev/null 2>&1; then
    curl -fsSL https://ziglang.org/download/index.json -o "$tmp/index.json" >&2
    tarball=$(python3 -c "import json;print(json.load(open('$tmp/index.json'))['$ZIG_PIN']['$target']['tarball'])")
    shasum=$(python3 -c "import json;print(json.load(open('$tmp/index.json'))['$ZIG_PIN']['$target']['shasum'])")
else
    log "python3 not found; guessing the tarball URL and skipping checksum verification"
    tarball="https://ziglang.org/download/$ZIG_PIN/zig-$target-$ZIG_PIN.tar.xz"
    shasum=""
fi
log "Downloading $tarball"
curl -fsSL "$tarball" -o "$tmp/zig.tar.xz" >&2
if [ -n "$shasum" ]; then
    echo "$shasum  $tmp/zig.tar.xz" | sha256sum -c - >&2 || die "zig tarball checksum mismatch — aborting"
fi
tar -C "$tmp" -xf "$tmp/zig.tar.xz"
extracted=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'zig-*')
[ -n "$extracted" ] || die "could not find extracted zig directory in the downloaded tarball"
rm -rf "$ZIG_ROOT/zig-$ZIG_PIN"
mv "$extracted" "$ZIG_ROOT/zig-$ZIG_PIN"
zig_acceptable "$ZIG_ROOT/zig-$ZIG_PIN/zig" || die "bootstrapped zig failed its own version check"
log "Bootstrapped zig -> $ZIG_ROOT/zig-$ZIG_PIN/zig"
echo "$ZIG_ROOT/zig-$ZIG_PIN/zig"
