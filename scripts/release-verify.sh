#!/bin/sh
# Installs a release tarball the way a user would, in a fresh container of the
# target distro, started by scripts/make-release.sh; not meant to be run
# directly.
#
#   release-verify.sh FAMILY OUTDIR
#
# Runs the real install.sh as an ordinary user against the tarball (served from
# a file:// release directory), so it exercises the download checksum, the
# runtime packages listed in DEPENDS, the unresolved-library check and the root
# install, then starts the installed compositor headless to prove it loads.
set -eu
family=$1
out=$2
src=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

case "$family" in
    arch) pacman -Syu --noconfirm sudo curl ;;
    debian|ubuntu)
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sudo curl ca-certificates ;;
    fedora) dnf install -y sudo curl util-linux ;;
    *) die "unknown family '$family'" ;;
esac

# The source tree is a private directory of the host user; the installer is
# run as someone else.
installer=/tmp/rediwm-install.sh
cp "$src/scripts/install.sh" "$installer"
chmod a+r "$installer"

# What a mirror serves: the tarball and its checksum, nothing else.
rel=$(mktemp -d)
cp "$out/rediwm-$family-x86_64.tar.gz" "$rel/"
(cd "$rel" && sha256sum rediwm-*.tar.gz > SHA256SUMS)
chmod -R a+rX "$rel"

useradd -m tester
echo 'tester ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/tester
chmod 440 /etc/sudoers.d/tester

log "Running install.sh as an ordinary user"
cd /
runuser -u tester -- env HOME=/home/tester REDIWM_RELEASE_URL="file://$rel" \
    sh "$installer" --prebuilt-only --no-restart

# Not cwd=$src: the installed copy, from outside any checkout.
log "Checking the installed files"
for bin in /usr/local/bin/rediwm /usr/local/bin/rediwm-*; do
    readelf -d "$bin" 2>/dev/null | grep -E 'RUNPATH|RPATH' | grep -q "/work/" && die "$bin carries a build path in its RUNPATH"
done
# Every program the release's build listed (build/install_paths.zig).
programs=$(tar -xzOf "$rel/rediwm-$family-x86_64.tar.gz" rediwm/zig-out/release-safe/programs) || die "the release has no program list"
for bin in $programs; do
    [ -x "/usr/local/bin/$bin" ] || die "/usr/local/bin/$bin is missing"
    ldd "/usr/local/bin/$bin" 2>&1 | grep -q 'not found' && die "$bin has unresolved libraries"
done
[ -f /usr/local/share/applications/rediwm-transfers.desktop ] || die "the torrent handler is missing"
[ -f /usr/local/share/applications/rediwm-calculator.desktop ] || die "the Calculator launcher is missing"
[ -f /usr/local/share/icons/hicolor/scalable/apps/rediwm-calculator.svg ] || die "the Calculator icon is missing"
[ -f /usr/share/wayland-sessions/rediwm-release-safe.desktop ] || die "the session entry is missing"
[ -d /usr/local/lib/rediwm ] || die "the bundled libraries are missing"
runuser -u tester -- test -r /usr/local/lib/rediwm/files-bash.so || die "the Files Bash integration is missing or unreadable"
runuser -u tester -- test -r /usr/local/share/licenses/rediwm/libvterm-LICENSE || die "the libvterm license is missing or unreadable"
runuser -u tester -- test -r /usr/local/share/licenses/rediwm/libtorrent-LICENSE || die "the libtorrent license is missing or unreadable"
for asset in theme.toml icons/folder.png icons/user-home.png icons/user-trash.png wallpapers/wallpaper-gold.png; do
    runuser -u tester -- test -r "/usr/local/share/rediwm/themes/gold/$asset" || die "Gold theme asset is missing or unreadable: $asset"
done

log "Starting the installed compositor headless"
xdg=$(mktemp -d)
chown tester "$xdg"
chmod 700 "$xdg"
log_file=/tmp/rediwm-verify.log
# make-release.sh passes the host's render node in; GLES2 needs one even for llvmpipe.
node=$(ls /dev/dri/renderD* 2>/dev/null | head -n 1) || true
[ -n "$node" ] || die "no DRM render node in the container"
runuser -u tester -- env HOME=/home/tester XDG_RUNTIME_DIR="$xdg" XDG_STATE_HOME="$xdg/state" \
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=gles2 WLR_RENDERER_ALLOW_SOFTWARE=1 WLR_RENDER_DRM_DEVICE="$node" REDIWM_SCALE=1 \
    /usr/local/bin/rediwm > "$log_file" 2>&1 &
pid=$!
up=no
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sleep 0.5
    kill -0 "$pid" 2>/dev/null || break
    ls "$xdg"/rediwm-*.sock >/dev/null 2>&1 && { up=yes; break; }
done
if [ "$up" != yes ]; then
    cat "$log_file" >&2
    die "the installed compositor did not come up"
fi
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
log "$family release OK"
