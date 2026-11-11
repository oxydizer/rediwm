#!/bin/sh
# Build as the login user, install atomically, then restart their installed session.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release_dir="$repo_dir/zig-out/release-safe"

# Wrap each step as the user that should run it, without ever escalating to
# root more than once: if we're already root (invoked as `sudo ./install-session.sh`),
# de-escalate for the build/restart steps and run the install step directly;
# otherwise run the build/restart steps directly and escalate once for install.
if [ "$(id -u)" -eq 0 ]; then
    if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = root ]; then
        echo 'Run this script as your desktop user; it uses sudo only for installation.' >&2
        exit 1
    fi
    as_user() { sudo -H -u "$SUDO_USER" -- "$@"; }
    as_root() { "$@"; }
else
    as_user() { "$@"; }
    as_root() { sudo -- "$@"; }
fi

restart=yes
dm_flag=no
# --prebuilt: install.sh unpacked a release, whose zig-out/release-safe is
# already built (scripts/make-release.sh), so there is nothing to compile.
prebuilt=no
prefix=${REDIWM_INSTALL_PREFIX:-/usr/local}
for arg in "$@"; do
    case "$arg" in
        --no-restart) restart=no ;;
        --dm) dm_flag=yes ;;
        --prebuilt) prebuilt=yes ;;
        --prefix=*) prefix=${arg#--prefix=} ;;
        *) echo "Usage: $0 [--no-restart] [--dm] [--prebuilt] [--prefix=/usr/local]" >&2; exit 1 ;;
    esac
done

if [ "$restart" = yes ]; then
    echo "This update restarts RediWM and closes connected applications. Save your work first."
fi
if [ "$prebuilt" = no ]; then
    # Reserve 2 CPU cores for system responsiveness unless overridden by ZIG_JOBS
    if [ -z "${ZIG_JOBS:-}" ]; then
        cpu_cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
        if [ "$cpu_cores" -gt 2 ]; then
            ZIG_JOBS=$((cpu_cores - 2))
        else
            ZIG_JOBS=1
        fi
    fi
    cd "$repo_dir"
    # Set by install.sh when it built the private wlroots (see scripts/build-wlroots.sh).
    if [ -n "${REDIWM_WLROOTS_PREFIX:-}" ]; then
        as_user sh scripts/with-wlroots.sh "$REDIWM_WLROOTS_PREFIX" zig build -Doptimize=ReleaseSafe -j"$ZIG_JOBS" --prefix "$release_dir" -Dinstall-prefix="$prefix" -Dwlroots-prefix="$REDIWM_WLROOTS_PREFIX"
    else
        as_user zig build -Doptimize=ReleaseSafe -j"$ZIG_JOBS" --prefix "$release_dir" -Dinstall-prefix="$prefix"
    fi
fi
built_prefix=$(cat "$release_dir/install-prefix")
if [ "${built_prefix%/}" != "${prefix%/}" ]; then
    echo "Build targets $built_prefix, not $prefix. Rebuild with --prefix=$prefix (prebuilt releases cannot be relocated)." >&2
    exit 1
fi
# The build lists the programs it installed (build/install_paths.zig); a stale
# file left in bin/ by an older build is not on it.
if [ ! -f "$release_dir/programs" ]; then
    echo "$release_dir has no program list. Rebuild it with this checkout." >&2
    exit 1
fi
grep -qx rediwm "$release_dir/programs" || { echo "$release_dir/programs does not list rediwm" >&2; exit 1; }
for binary in $(cat "$release_dir/programs"); do
    test -x "$release_dir/bin/$binary" || { echo "$release_dir/bin/$binary is missing" >&2; exit 1; }
done
as_root sh "$repo_dir/scripts/install-session-root.sh" "$repo_dir" "$release_dir" "$dm_flag"
if [ "$restart" = no ]; then
    echo 'Installed ReleaseSafe. Running session left as-is.'
else
    as_user "$release_dir/bin/rediwm-restart"
fi
