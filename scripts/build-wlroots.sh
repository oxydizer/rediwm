#!/bin/sh
# Builds the pinned, patched wlroots 0.20 into a private prefix: for releases
# (scripts/make-release.sh builds every one this way, so they all carry the same
# wlroots) and for source builds on distros that don't package it (Debian 13 and
# Ubuntu 24.04–26.04 top out at wlroots 0.17–0.19):
#
#   scripts/build-wlroots.sh [PREFIX]
#   zig build -Dwlroots-prefix=PREFIX ...
#
# wlroots 0.20 also needs newer wayland, wayland-protocols, libdrm,
# xkbcommon, pixman and libdisplay-info than some of those releases ship.
# Meson falls back to the pinned release tarballs below only for the ones the
# system can't satisfy, so a newer distro builds just wlroots.
#
# Everything is shared, not static: Mesa's libEGL/libgbm link libwayland-server
# and libdrm themselves, and a static copy inside rediwm would leave two copies
# of each in one process. With shared libraries the loader finds ours first by
# RUNPATH and Mesa reuses them by soname. PREFIX/runtime holds just those
# libraries, one file per soname, for build.zig to install into lib/rediwm.
# Each gets RUNPATH=$ORIGIN: the executable's RUNPATH only covers its own
# direct dependencies, so without it libwlroots would load the system's older
# libdrm or miss libdisplay-info entirely.
#
# Idempotent: skips the build when PREFIX was made by this exact recipe.
set -eu

WLROOTS_VERSION=0.20.2
WLROOTS_SHA256=972c7ac44b17828f4702bfae7cd8347346a3fb5b2c1076cfa2c3fcedac5ec343

prefix=${1:-${REDIWM_WLROOTS_PREFIX:-$HOME/.local/share/rediwm/wlroots-$WLROOTS_VERSION}}
case "$prefix" in /*) ;; *) prefix="$(pwd)/$prefix" ;; esac

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in meson ninja pkg-config curl sha256sum readelf patchelf ldd patch; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required to build wlroots"
done

patch_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../patches/wlroots" && pwd)
recipe=$(cat "$0" "$patch_dir"/*.patch | sha256sum | cut -d' ' -f1)
if [ -f "$prefix/.rediwm-recipe" ] && [ "$(cat "$prefix/.rediwm-recipe")" = "$recipe" ]; then
    log "wlroots $WLROOTS_VERSION already built in $prefix"
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

log "Downloading wlroots $WLROOTS_VERSION"
curl -fsSL --retry 3 --retry-all-errors -o "$work/wlroots.tar.gz" \
    "https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/$WLROOTS_VERSION/wlroots-$WLROOTS_VERSION.tar.gz"
echo "$WLROOTS_SHA256  $work/wlroots.tar.gz" | sha256sum -c - >/dev/null || die "wlroots tarball checksum mismatch"
tar -C "$work" -xzf "$work/wlroots.tar.gz"
src="$work/wlroots-$WLROOTS_VERSION"
for fix in "$patch_dir"/*.patch; do
    log "Applying $(basename "$fix")"
    patch -d "$src" -p1 < "$fix"
done

# wlroots' own wraps track each dependency's git HEAD. Replace them with
# checksummed release tarballs; seatd and libliftoff get no wrap because every
# supported distro's libseat is new enough and libliftoff is disabled.
rm -f "$src"/subprojects/*.wrap
# Prefetched with curl into meson's package cache: meson's own downloader
# gives up on transient gitlab.freedesktop.org failures that curl retries.
mkdir -p "$src/subprojects/packagecache"
wrap() { # name directory url sha256
    curl -fsSL --retry 3 --retry-all-errors -o "$src/subprojects/packagecache/$(basename "$3")" "$3"
    cat > "$src/subprojects/$1.wrap" <<EOF
[wrap-file]
directory = $2
source_url = $3
source_filename = $(basename "$3")
source_hash = $4
EOF
}
wrap wayland wayland-1.24.0 \
    https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.24.0/downloads/wayland-1.24.0.tar.xz \
    82892487a01ad67b334eca83b54317a7c86a03a89cfadacfef5211f11a5d0536
wrap wayland-protocols wayland-protocols-1.47 \
    https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.47/downloads/wayland-protocols-1.47.tar.xz \
    5fd4349bcbc9bab9a46f8cf77d1f434296a7a052c87440a094f63fcf62a58e20
wrap libdrm libdrm-2.4.131 \
    https://dri.freedesktop.org/libdrm/libdrm-2.4.131.tar.xz \
    45ba9983b51c896406a3d654de81d313b953b76e6391e2797073d543c5f617d5
wrap libxkbcommon libxkbcommon-xkbcommon-1.13.1 \
    https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-1.13.1.tar.gz \
    aeb951964c2f7ecc08174cb5517962d157595e9e3f38fc4a130b91dc2f9fec18
wrap pixman pixman-0.46.4 \
    https://cairographics.org/releases/pixman-0.46.4.tar.gz \
    d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c
wrap libdisplay-info libdisplay-info-0.3.0 \
    https://gitlab.freedesktop.org/emersion/libdisplay-info/-/releases/0.3.0/downloads/libdisplay-info-0.3.0.tar.xz \
    6ae77cd937f9cf7d1321d35c116062c4911e8447010a6a713ac4286f7a9d5987

# The Vulkan renderer is unused by rediwm and would only add build
# dependencies; the x11 backend stays because rediwm links wlr_backend_is_x11. A bundled xkbcommon must still read the system's keymap
# data, not an empty copy under PREFIX. wlroots' werror default reaches the
# subprojects too, where newer compilers' warnings aren't ours to fix.
# nopromote keeps libdisplay-info's optional test-only v4l-utils wrap from
# being cloned and installed alongside it.
# render/pixman asks for pixman >= 0.46 without a fallback, while the top-level
# lookup settles for 0.43, so an in-between system pixman must be bypassed.
force_fallback=""
pkg-config --atleast-version=0.46.0 pixman-1 2>/dev/null || force_fallback="--force-fallback-for=pixman"
log "Configuring wlroots (bundling only the dependencies this system lacks)"
meson setup "$work/build" "$src" $force_fallback \
    --prefix "$prefix" --libdir lib --buildtype release --wrap-mode nopromote -Dwerror=false \
    -Dexamples=false -Dbackends=drm,libinput,x11 -Drenderers=gles2 \
    -Dxwayland=enabled -Dsession=enabled -Dcolor-management=enabled -Dlibliftoff=disabled \
    -Dwayland:tests=false -Dwayland:documentation=false -Dwayland:dtd_validation=false \
    -Dlibdrm:intel=disabled -Dlibdrm:radeon=disabled -Dlibdrm:amdgpu=disabled \
    -Dlibdrm:nouveau=disabled -Dlibdrm:vmwgfx=disabled -Dlibdrm:cairo-tests=disabled \
    -Dlibdrm:man-pages=disabled -Dlibdrm:valgrind=disabled -Dlibdrm:tests=false \
    -Dlibxkbcommon:xkb-config-root=/usr/share/X11/xkb -Dlibxkbcommon:x-locale-root=/usr/share/X11/locale \
    -Dlibxkbcommon:enable-tools=false -Dlibxkbcommon:enable-x11=false -Dlibxkbcommon:enable-docs=false \
    -Dlibxkbcommon:enable-xkbregistry=false -Dlibxkbcommon:enable-bash-completion=false \
    -Dpixman:tests=disabled -Dpixman:demos=disabled -Dpixman:gtk=disabled -Dpixman:libpng=disabled

log "Building wlroots"
ninja -C "$work/build"
# Stage, then swap in: a failed build never leaves a half-populated PREFIX.
DESTDIR="$work/stage" meson install -C "$work/build" --quiet

staged="$work/stage$prefix"
mkdir -p "$staged/runtime"
find "$staged/lib" -maxdepth 1 -type f -name 'lib*.so*' | while read -r lib; do
    soname=$(readelf -d "$lib" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
    [ -n "$soname" ] && cp "$lib" "$staged/runtime/$soname"
done
for lib in "$staged"/runtime/*; do
    patchelf --set-rpath '$ORIGIN' "$lib"
done
# Every bundled library libwlroots needs must resolve from the bundle.
resolved=$(env -u LD_LIBRARY_PATH ldd "$staged/runtime/libwlroots-0.20.so")
for lib in "$staged"/runtime/*; do
    name=$(basename "$lib")
    echo "$resolved" | grep -q "^[[:space:]]*$name => " || continue
    echo "$resolved" | grep -q "^[[:space:]]*$name => $staged/runtime/$name " ||
        die "libwlroots resolves $name outside the bundle: $(echo "$resolved" | grep "$name")"
done
echo "$recipe" > "$staged/.rediwm-recipe"

rm -rf -- "$prefix"
mkdir -p "$(dirname "$prefix")"
mv "$staged" "$prefix"
log "wlroots $WLROOTS_VERSION installed in $prefix"
log "Bundled runtime libraries: $(ls "$prefix/runtime" | tr '\n' ' ')"
