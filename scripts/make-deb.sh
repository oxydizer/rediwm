#!/bin/sh
# Builds a .deb from an existing ReleaseSafe tree (zig-out/release-safe, see
# scripts/install-session.sh and scripts/release-build.sh). The layout mirrors
# scripts/install-session-root.sh, which installs under /usr/local because the
# binaries, the session entry and rediwm-restart expect it. It does not enable
# rediwm-dm or touch /etc/pam.d.
#
#   scripts/make-deb.sh [OUTDIR]
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rel="$repo/zig-out/release-safe"
out=${1:-$repo/zig-out}
version=$(grep -o '\.version = "[^"]*"' "$repo/build.zig.zon" | cut -d'"' -f2)
arch=$(dpkg --print-architecture)
bins="rediwm rediwm-msg rediwm-theme rediwm-files rediwm-files-terminal rediwm-transfers rediwm-images rediwm-monitor rediwm-calculator rediwm-editor rediwm-pdf rediwm-share-picker rediwm-session rediwm-dm rediwm-accounts-helper rediwm-restart"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ -x "$rel/bin/rediwm" ] || die "$rel is missing: build ReleaseSafe first"
command -v dpkg-deb >/dev/null || die "dpkg-deb is required"

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
L="$root/usr/local"
install -d "$L/bin" "$L/lib" "$L/share" "$root/usr/share" "$root/DEBIAN"

for b in $bins; do install -m755 "$rel/bin/$b" "$L/bin/$b"; done
# The private wlroots 0.20 and the LADSPA/bash plugins, found through $ORIGIN/../lib/rediwm.
cp -a "$rel/lib/rediwm" "$L/lib/rediwm"

# System-wide data: portal backend, polkit action, session entry.
install -d "$root/usr/share/polkit-1/actions" "$root/usr/share/wayland-sessions" "$root/usr/share/xdg-desktop-portal/portals"
cp "$rel/share/polkit-1/actions/org.rediwm.accounts.policy" "$root/usr/share/polkit-1/actions/"
cp "$rel/share/wayland-sessions/rediwm-release-safe.desktop" "$root/usr/share/wayland-sessions/"
install -m644 "$repo/data/rediwm.portal" "$root/usr/share/xdg-desktop-portal/portals/rediwm.portal"
# Everything else lives under /usr/local/share, as the binaries expect.
(cd "$rel/share" && tar -cf - --exclude=./polkit-1 --exclude=./wayland-sessions --exclude=./xdg-desktop-portal/portals .) | (cd "$L/share" && tar -xf -)
install -Dm644 "$repo/data/xdg-desktop-portal-wlr.ini" "$L/share/xdg-desktop-portal-wlr/config"
install -Dm644 "$repo/data/rediwm-theme.xml" "$L/share/mime/packages/rediwm-theme.xml"
rm -rf "$L/share/mime/mime.cache" "$L/share/mime/application" "$L/share/mime/aliases" "$L/share/mime/generic-icons" \
    "$L/share/mime/globs" "$L/share/mime/globs2" "$L/share/mime/icons" "$L/share/mime/magic" "$L/share/mime/subclasses" \
    "$L/share/mime/treemagic" "$L/share/mime/types" "$L/share/mime/version" "$L/share/mime/XMLnamespaces" "$L/share/mime/image" 2>/dev/null || true
install -Dm644 "$repo/LICENSE-MIT" "$root/usr/share/doc/rediwm/copyright"
install -Dm644 "$repo/LICENSE-APACHE" "$root/usr/share/doc/rediwm/LICENSE-APACHE"
# The dm files are shipped as examples only: nothing enables the display manager.
install -d "$root/usr/share/doc/rediwm/examples"
cp -r "$repo/data/pam" "$repo/data/rediwm-dm.conf" "$repo/data/rediwm-dm.service" "$repo/data/rediwm-dm.sysusers" "$repo/data/rediwm-dm.tmpfiles" "$root/usr/share/doc/rediwm/examples/"

find "$root" -type d -exec chmod 755 {} +
find "$root/usr" -type f ! -perm -u+x -exec chmod 644 {} +

# Dependencies: the packages owning every system library the ELF files need,
# except the ones bundled in lib/rediwm.
bundled=$(ls "$L/lib/rediwm")
deps=$(
    find "$L/bin" "$L/lib/rediwm" -type f | while read -r f; do
        readelf -d "$f" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'
    done | sort -u | while read -r lib; do
        echo "$bundled" | grep -qx "$lib" && continue
        path=$(ldconfig -p | awk -v l="$lib" '$1 == l && $NF !~ /x32|i386|i686|lib32/ { print $NF; exit }')
        [ -n "$path" ] || continue
        # C locale: dpkg -S prints diversion notes in the user's language.
        LC_ALL=C dpkg -S "$(realpath "$path")" 2>/dev/null | grep -v '^diversion' | head -1 | cut -d: -f1
    done | sort -u | paste -sd, - | sed 's/,/, /g'
)
size=$(du -sk "$root/usr" | cut -f1)

cat > "$root/DEBIAN/control" <<EOF
Package: rediwm
Version: $version
Section: x11
Priority: optional
Architecture: $arch
Maintainer: Local build <noreply@localhost>
Installed-Size: $size
Depends: $deps
Recommends: xwayland, foot, polkitd
Description: RediWM Wayland compositor with its own desktop shell
 Single-process wlroots compositor with taskbar, start menu, settings,
 lock screen, notifications, file manager and image viewer. Installed under
 /usr/local, as upstream's installer does. rediwm-dm is installed but never
 enabled.
EOF

cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-mime-database >/dev/null 2>&1; then update-mime-database /usr/local/share/mime || true; fi
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database /usr/local/share/applications || true; fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q -t /usr/local/share/icons/hicolor 2>/dev/null || true; fi
exit 0
EOF
cat > "$root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
case "$1" in
    remove|purge)
        if command -v update-mime-database >/dev/null 2>&1 && [ -d /usr/local/share/mime/packages ]; then update-mime-database /usr/local/share/mime || true; fi
        if command -v update-desktop-database >/dev/null 2>&1 && [ -d /usr/local/share/applications ]; then update-desktop-database /usr/local/share/applications || true; fi
        ;;
esac
exit 0
EOF
chmod 755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

mkdir -p "$out"
deb="$out/rediwm_${version}_${arch}.deb"
dpkg-deb --root-owner-group -Zxz -b "$root" "$deb" >&2
echo "$deb"
