#!/bin/sh
# One-command installer for RediWM:
#
#   curl -fsSL https://rediwm.redios.org/install.sh | sh
#
# Detects the distro and installs the prebuilt release for it: a tarball with
# the compositor, the apps and the exact wlroots they were tested with, made by
# scripts/make-release.sh. Only runtime libraries come from the package
# manager; nothing is compiled. The tarball's checksum is verified before
# anything is installed, then scripts/install-session.sh does the atomic
# root-install and the restart.
#
# --build compiles from source instead, and so does any system the release
# doesn't cover (other distros or CPUs, or a distro whose libraries don't match
# the release). That path installs build dependencies, bootstraps a pinned Zig
# from ziglang.org, gets the source (the current checkout if run from inside
# one, otherwise a clone) and hands off to scripts/install-session.sh.
# Arguments are forwarded (`curl ... | sh -s -- --dm`).
#
# This never replaces the login manager: RediWM is added as a session entry,
# and the optional rediwm-dm (--dm) is installed but never enabled.
#
# Environment: REDIWM_VERSION=<tag> picks a release other than the latest;
# REDIWM_RELEASE_URL=<dir url> reads a mirror or a local directory (file://).
set -eu

REPO_URL="${REDIWM_REPO_URL:-https://github.com/oxydizer/rediwm.git}"
# Empty means the repository's default branch (resolved when it is needed).
REPO_REF="${REDIWM_REF:-}"
SRC_DIR="${REDIWM_SRC_DIR:-$HOME/.local/share/rediwm/src}"
RELEASE_DIR="${REDIWM_RELEASE_DIR:-$HOME/.local/share/rediwm/release}"
if [ -n "${REDIWM_RELEASE_URL:-}" ]; then
    RELEASE_URL="$REDIWM_RELEASE_URL"
elif [ -n "${REDIWM_VERSION:-}" ]; then
    RELEASE_URL="${REPO_URL%.git}/releases/download/$REDIWM_VERSION"
else
    RELEASE_URL="${REPO_URL%.git}/releases/latest/download"
fi

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# Our own flags are consumed here; everything else goes to install-session.sh.
BUILD=no
DEPS_ONLY=no
n=$#
while [ "$n" -gt 0 ]; do
    arg=$1; shift; n=$((n - 1))
    case "$arg" in
        --build) BUILD=yes ;;
        # For scripts/release-build.sh: install what a release build needs.
        --build-deps-only) BUILD=yes; DEPS_ONLY=yes ;;
        *) set -- "$@" "$arg" ;;
    esac
done
# Running from a checkout means the user wants that checkout built.
if [ -f ./build.zig.zon ] && grep -q '\.name = \.rediwm,' ./build.zig.zon 2>/dev/null; then
    BUILD=yes
fi

# ---------------------------------------------------------------------------
# 1. Distro detection
# ---------------------------------------------------------------------------
[ -r /etc/os-release ] || die "cannot detect distro: /etc/os-release is missing"
. /etc/os-release

case " ${ID:-} ${ID_LIKE:-} " in
    *' arch '*)                FAMILY=arch ;;
    *' fedora '*)              FAMILY=fedora ;;
    *' debian '*|*' ubuntu '*) FAMILY=debian ;;
    *' opensuse'*|*' suse '*)  FAMILY=opensuse ;;
    *' gentoo '*)              FAMILY=gentoo ;;
    *) die "unsupported distro '${PRETTY_NAME:-${ID:-unknown}}' (supported: Arch, Fedora, openSUSE, Gentoo, Debian, Ubuntu). Install the packages listed in README.md's Requirements section by hand, then run scripts/install-session.sh directly." ;;
esac
log "Detected ${PRETTY_NAME:-$ID} -> $FAMILY"

# Releases are built per distro because the libraries differ in ways one binary
# can't span (libjpeg is libjpeg.so.8 on Arch and Ubuntu, .so.62 on Debian and
# Fedora, with a different struct layout). A derivative uses its parent's.
RELEASE_ID=""
for id in ${ID:-} ${ID_LIKE:-}; do
    case "$id" in arch|debian|ubuntu|fedora) RELEASE_ID=$id; break ;; esac
done

# Installs packages with the distro's package manager. Returns non-zero on
# failure so a caller can fall back; the source build dies on it.
pkg_install() {
    case "$FAMILY" in
        arch)
            # Install only what is missing and never refresh the sync databases:
            # `-Sy pkg` is a partial upgrade, which breaks exact-version split
            # packages (e.g. a newer pipewire vs installed pipewire-pulse).
            # Upgrading the system is left to the user's `pacman -Syu`.
            missing=$(pacman -T "$@" || true)
            if [ -n "$missing" ]; then
                # shellcheck disable=SC2086 # word-split the package list
                $SUDO pacman -S --needed --noconfirm $missing || {
                    log "pacman could not install: $missing. If the package databases are stale, run 'sudo pacman -Syu' and re-run this script."
                    return 1
                }
            fi
            ;;
        debian)
            $SUDO apt-get update || return 1
            $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" || return 1
            ;;
        fedora) $SUDO dnf install -y "$@" || return 1 ;;
        opensuse) $SUDO zypper --non-interactive install "$@" || return 1 ;;
        gentoo) $SUDO emerge --ask=n --noreplace "$@" || return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 2. Prebuilt release
# ---------------------------------------------------------------------------
# Downloads, verifies and unpacks this distro's release into $RELEASE_DIR.
# Returns 1 (after saying why) when there is none to use. Written without
# relying on `set -e`, which doesn't apply inside a function used as a condition.
fetch_release() {
    [ -n "$RELEASE_ID" ] || { log "No prebuilt release for $FAMILY"; return 1; }
    [ "$(uname -m)" = x86_64 ] || { log "No prebuilt release for $(uname -m)"; return 1; }
    command -v curl >/dev/null 2>&1 || { log "curl is required to download the release"; return 1; }
    name="rediwm-$RELEASE_ID-$(uname -m).tar.gz"
    dl=$(mktemp -d) || return 1
    trap 'rm -rf -- "$dl"' EXIT HUP INT TERM
    if ! curl -fsSL --retry 3 "$RELEASE_URL/SHA256SUMS" -o "$dl/SHA256SUMS"; then
        log "Could not fetch $RELEASE_URL/SHA256SUMS"
        return 1
    fi
    sum=$(grep -F "  $name" "$dl/SHA256SUMS" | head -n 1)
    [ -n "$sum" ] || { log "The release has no $name"; return 1; }
    log "Downloading $name"
    if ! curl -fSL --retry 3 "$RELEASE_URL/$name" -o "$dl/$name"; then
        log "Could not download $RELEASE_URL/$name"
        return 1
    fi
    # A mismatch is corruption or tampering, not "no release": never fall back
    # silently.
    (cd "$dl" && echo "$sum" | sha256sum -c - >/dev/null 2>&1) \
        || die "checksum mismatch for $name; refusing to install it (use --build to compile instead)"
    mkdir -p "$dl/unpacked" && tar -C "$dl/unpacked" --strip-components=1 -xzf "$dl/$name" || die "could not unpack $name"
    [ -f "$dl/unpacked/DEPENDS" ] && [ -x "$dl/unpacked/zig-out/release-safe/bin/rediwm" ] \
        || die "$name is not a RediWM release"
    mkdir -p "$(dirname "$RELEASE_DIR")"
    rm -rf -- "$RELEASE_DIR"
    mv "$dl/unpacked" "$RELEASE_DIR" || die "could not move the release into $RELEASE_DIR"
    rm -rf -- "$dl"
    trap - EXIT HUP INT TERM
    log "Release $(cat "$RELEASE_DIR/VERSION") for $RELEASE_ID"
}

# Prints what keeps the release's binaries from loading on this system: shared
# libraries that are missing, and symbol versions too new for the installed
# glibc or libstdc++ (the release is built on a recent distro). Its bundled
# libraries resolve through their RUNPATH.
unresolved_libs() {
    for bin in "$RELEASE_DIR"/zig-out/release-safe/bin/*; do
        ldd "$bin" 2>&1 | sed -n "s/^[[:space:]]*\(.*\) => not found.*/\1/p; s/.*: version \`\(.*\)' not found.*/\1/p"
    done | sort -u | tr '\n' ' '
}

if [ "$BUILD" = no ] && fetch_release; then
    log "Installing runtime dependencies (needs sudo)..."
    # shellcheck disable=SC2046 # word-split the package list
    if pkg_install $(grep -v '^#' "$RELEASE_DIR/DEPENDS"); then
        missing=$(unresolved_libs)
        if [ -z "$missing" ]; then
            log "Handing off to the release's install-session.sh"
            exec sh "$RELEASE_DIR/scripts/install-session.sh" --prebuilt "$@"
        fi
        log "The prebuilt release can't load here: $missing"
    else
        log "This system doesn't have the packages the prebuilt release needs"
    fi
    log "Falling back to building from source"
fi

# ---------------------------------------------------------------------------
# 3. Source build: build dependencies
# ---------------------------------------------------------------------------
# Debian and Ubuntu don't package wlroots 0.20 (verified 2026-09-23: Debian 13
# has 0.18, Ubuntu 26.04 has 0.19), so there scripts/build-wlroots.sh builds it,
# plus whichever of its dependencies are too old, into a private prefix. A
# release is always built that way, on every distro, so it carries the exact
# wlroots (and patches) the compositor was tested with. REDIWM_PRIVATE_WLROOTS=1
# does the same for a source build elsewhere.
WLROOTS_PREFIX=""
PRIVATE_WLROOTS=no
if [ "$FAMILY" = debian ] || [ "$DEPS_ONLY" = yes ] || [ "${REDIWM_PRIVATE_WLROOTS:-}" = 1 ]; then
    PRIVATE_WLROOTS=yes
fi

log "Installing dependencies (needs sudo)..."
# Match rediwm-portals.conf: wlr provides ScreenCast; gtk handles fallback portals.
case "$FAMILY" in
    arch)
        deps="wayland wayland-protocols pixman libxkbcommon \
            freetype2 harfbuzz fontconfig librsvg cairo pango libinput poppler-glib libseccomp \
            libarchive libpng libjpeg-turbo libpulse pipewire pam mesa pkgconf git python \
            xorg-xwayland xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk"
        if [ "$PRIVATE_WLROOTS" = no ]; then
            deps="wlroots0.20 $deps"
        else
            # What scripts/build-wlroots.sh needs: wlroots's backends, bundling
            # wayland/libdrm/xkbcommon/pixman/libdisplay-info only if the
            # system's are too old. Not the system wlroots: the build must use
            # the private one.
            deps="$deps base-devel meson ninja patchelf libdrm libglvnd \
                seatd lcms2 hwdata libxcb xcb-util-wm xcb-util-renderutil xcb-util-errors \
                curl"
        fi
        ;;
    debian)
        deps="build-essential meson ninja-build pkg-config git curl ca-certificates xz-utils python3 \
            bison libexpat1-dev libffi-dev hwdata patchelf \
            libwayland-dev wayland-protocols libdrm-dev libxkbcommon-dev xkb-data libpixman-1-dev \
            libdisplay-info-dev libegl-dev libgles-dev libgbm-dev libinput-dev libseat-dev libudev-dev liblcms2-dev \
            libxcb1-dev libxcb-composite0-dev libxcb-ewmh-dev libxcb-icccm4-dev libxcb-render0-dev \
            libxcb-res0-dev libxcb-xfixes0-dev libxcb-dri3-dev libxcb-present-dev \
            libxcb-render-util0-dev libxcb-shm0-dev libxcb-xinput-dev xwayland \
            libfreetype-dev libharfbuzz-dev libfontconfig-dev librsvg2-dev libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev \
            libglib2.0-dev libarchive-dev libpng-dev libjpeg-dev libpulse-dev libpipewire-0.3-dev libpam0g-dev libpoppler-glib-dev libseccomp-dev \
            xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk"
        ;;
    fedora)
        deps="wayland-devel wayland-protocols-devel pixman-devel libxkbcommon-devel \
            freetype-devel harfbuzz-devel fontconfig-devel librsvg2-devel cairo-devel pango-devel libinput-devel \
            libarchive-devel libpng-devel libjpeg-turbo-devel pulseaudio-libs-devel pipewire-devel pam-devel poppler-glib-devel libseccomp-devel \
            mesa-libEGL-devel mesa-libGLES-devel glibc-devel \
            pkgconf-pkg-config git python3 \
            xorg-x11-server-Xwayland \
            xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk"
        if [ "$PRIVATE_WLROOTS" = no ]; then
            deps="wlroots-devel $deps"
        else
            deps="$deps gcc meson ninja-build patchelf patch binutils curl \
                libdrm-devel mesa-libgbm-devel libseat-devel systemd-devel lcms2-devel hwdata-devel \
                libxcb-devel xcb-util-wm-devel xcb-util-renderutil-devel xcb-util-errors-devel \
                expat-devel libffi-devel xorg-x11-server-Xwayland-devel"
        fi
        ;;
    opensuse)
        deps="wlroots-devel wayland-devel wayland-protocols-devel libpixman-1-0-devel libxkbcommon-devel \
            freetype2-devel harfbuzz-devel fontconfig-devel librsvg-devel cairo-devel pango-devel libinput-devel \
            libarchive-devel libpng16-devel libjpeg8-devel libpulse-devel pipewire-devel pam-devel libpoppler-glib-devel libseccomp-devel \
            Mesa-libEGL-devel Mesa-libGLESv2-devel glibc-devel \
            pkg-config git python3 \
            xwayland \
            xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk"
        ;;
    gentoo)
        deps="gui-libs/wlroots dev-libs/wayland dev-libs/wayland-protocols x11-libs/pixman x11-libs/libxkbcommon \
            media-libs/freetype media-libs/harfbuzz media-libs/fontconfig gnome-base/librsvg x11-libs/cairo x11-libs/pango dev-libs/libinput \
            app-arch/libarchive media-libs/libpng media-libs/libjpeg-turbo media-libs/libpulse media-video/pipewire sys-libs/pam \
            media-libs/mesa \
            virtual/pkgconfig dev-vcs/git dev-lang/python \
            x11-base/xwayland \
            sys-apps/xdg-desktop-portal gui-libs/xdg-desktop-portal-wlr sys-apps/xdg-desktop-portal-gtk"
        ;;
esac
if [ "$PRIVATE_WLROOTS" = yes ] && [ "$FAMILY" != arch ] && [ "$FAMILY" != debian ] && [ "$FAMILY" != fedora ]; then
    die "building the private wlroots isn't supported on $FAMILY yet; unset REDIWM_PRIVATE_WLROOTS to use the system wlroots 0.20"
fi
# shellcheck disable=SC2086 # word-split the package list
pkg_install $deps || die "could not install the build dependencies"
[ "$DEPS_ONLY" = no ] || exit 0

# ---------------------------------------------------------------------------
# 4. Get the source
# ---------------------------------------------------------------------------
default_ref() {
    ref=$(git ls-remote --symref "$REPO_URL" HEAD | sed -n 's|^ref: refs/heads/\(.*\)[[:space:]]HEAD$|\1|p')
    [ -n "$ref" ] || die "could not find the default branch of $REPO_URL; set REDIWM_REF"
    echo "$ref"
}

if [ -f ./build.zig.zon ] && grep -q '\.name = \.rediwm,' ./build.zig.zon 2>/dev/null; then
    SRC_DIR=$(pwd)
    log "Running from an existing checkout at $SRC_DIR"
elif [ -d "$SRC_DIR/.git" ]; then
    [ -n "$REPO_REF" ] || REPO_REF=$(default_ref)
    log "Updating existing checkout at $SRC_DIR"
    git -C "$SRC_DIR" fetch --depth 1 origin "$REPO_REF"
    git -C "$SRC_DIR" checkout "$REPO_REF"
    git -C "$SRC_DIR" reset --hard "origin/$REPO_REF"
elif [ -e "$SRC_DIR" ]; then
    die "$SRC_DIR exists but isn't a git checkout; move it aside or set REDIWM_SRC_DIR and re-run"
else
    [ -n "$REPO_REF" ] || REPO_REF=$(default_ref)
    log "Cloning $REPO_URL ($REPO_REF) into $SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --branch "$REPO_REF" --depth 1 "$REPO_URL" "$SRC_DIR"
fi

if [ "$PRIVATE_WLROOTS" = yes ]; then
    WLROOTS_PREFIX="${REDIWM_WLROOTS_PREFIX:-$HOME/.local/share/rediwm/wlroots}"
    log "Building wlroots 0.20 into $WLROOTS_PREFIX"
    sh "$SRC_DIR/scripts/build-wlroots.sh" "$WLROOTS_PREFIX"
fi

# ---------------------------------------------------------------------------
# 5. Pinned Zig toolchain
# ---------------------------------------------------------------------------
ZIG_BIN=$(sh "$SRC_DIR/scripts/zig-bootstrap.sh")

# ---------------------------------------------------------------------------
# 6. Build + install via the project's own script
# ---------------------------------------------------------------------------
export PATH="$(dirname "$ZIG_BIN"):$PATH"
export REDIWM_WLROOTS_PREFIX="$WLROOTS_PREFIX"
cd "$SRC_DIR"
log "Handing off to scripts/install-session.sh"
exec sh scripts/install-session.sh "$@"
