#!/bin/sh
# Container-only payload; never invoke on a Steam Deck host.
set -eu
[ -f /run/.containerenv ] || [ -f /.dockerenv ] || { echo 'Run make-steamos-bundle.sh instead' >&2; exit 1; }
out=$1
prefix=/work/zig-out/steamos-wlroots
REDIWM_BUNDLE_WAYLAND=1 sh scripts/build-wlroots.sh "$prefix"
ZIG=$(sh scripts/zig-bootstrap.sh)
sh scripts/with-wlroots.sh "$prefix" "$ZIG" build -Doptimize=ReleaseSafe \
    -Dcpu=x86_64_v2 -Dtransfers=false -Dgit-integration=false \
    -Dwlroots-prefix="$prefix" --prefix zig-out/steamos
bundle=/work/zig-out/rediwm-steamos
mkdir -p "$bundle"
cp -a zig-out/steamos/bin zig-out/steamos/lib zig-out/steamos/share "$bundle/"
# Portable nested testing has no privileged helpers or system integration.
rm -f "$bundle/bin/rediwm-dm" "$bundle/bin/rediwm-accounts-helper" \
    "$bundle/bin/rediwm-session" "$bundle/bin/rediwm-restart"
rm -rf "$bundle/share/wayland-sessions" "$bundle/share/polkit-1" "$bundle/share/xdg-desktop-portal"
# These entries are visible only inside the nested session through XDG_DATA_DIRS.
# Resolve their commands through the launcher's private PATH after relocation.
for entry in "$bundle"/share/applications/*.desktop; do
    sed -i 's|=/usr/local/bin/|=|g' "$entry"
done
for exe in "$bundle"/bin/*; do
    patchelf --set-rpath '$ORIGIN/../lib/rediwm' "$exe"
done
cp packaging/steamos/run packaging/steamos/check-libs packaging/steamos/install "$bundle/"
chmod 755 "$bundle/run" "$bundle/check-libs" "$bundle/install"
cp packaging/steamos/README.txt "$bundle/README.txt"
pacman -Q > "$bundle/BUILD-PACKAGES.txt"
# Explicit bundle contract: the baseline alone cannot satisfy wlroots.
for lib in libwlroots-0.20.so libwayland-client.so.0 libwayland-server.so.0 libwayland-cursor.so.0; do
    test -f "$bundle/lib/rediwm/$lib"
done
"$bundle/check-libs" > "$bundle/LIBRARY-CHECK.txt"
(cd /work/zig-out && tar -czf "$out/rediwm-steamos-3.8-x86_64.tar.gz" rediwm-steamos)
(cd "$out" && sha256sum rediwm-steamos-3.8-x86_64.tar.gz > rediwm-steamos-3.8-x86_64.tar.gz.sha256)
