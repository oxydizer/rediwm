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
for arg in "$@"; do
    case "$arg" in
        --no-restart) restart=no ;;
        --dm) dm_flag=yes ;;
        --prebuilt) prebuilt=yes ;;
        *) echo "Usage: $0 [--no-restart] [--dm] [--prebuilt]" >&2; exit 1 ;;
    esac
done

if [ "$restart" = yes ]; then
    echo "This update restarts RediWM and closes connected applications. Save your work first."
fi
command -v python3 >/dev/null
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
    wlroots_flag=${REDIWM_WLROOTS_PREFIX:+-Dwlroots-prefix=$REDIWM_WLROOTS_PREFIX}
    as_user zig build -Doptimize=ReleaseSafe -j"$ZIG_JOBS" --prefix "$release_dir" $wlroots_flag
fi
for binary in rediwm rediwm-msg rediwm-files rediwm-images rediwm-editor rediwm-pdf rediwm-share-picker rediwm-dm rediwm-accounts-helper; do
    test -x "$release_dir/bin/$binary"
done
as_root sh "$repo_dir/scripts/install-session-root.sh" "$repo_dir" "$release_dir" "$dm_flag"
if [ "$restart" = no ]; then
    echo 'Installed ReleaseSafe. Running session left as-is.'
else
    as_user python3 "$repo_dir/scripts/restart-session.py"
fi
