#!/bin/sh
# Root-only install payload for install-session.sh. Not meant to be run directly.
set -eu
repo_dir=$1
release_dir=$2
install_dm=${3:-no}
# The build records its runtime prefix. Never relocate binaries configured for
# another prefix; DESTDIR is only a staging root and never enters generated files.
prefix=$(cat "$release_dir/install-prefix")
prefix=${prefix%/}
case "$prefix" in /*|'') ;; *) echo 'Invalid installation prefix' >&2; exit 1 ;; esac
case "$prefix" in *[!a-zA-Z0-9/_+.-]*) echo 'Invalid installation prefix' >&2; exit 1 ;; esac
dest=${DESTDIR:-}
case "$dest" in /*|'') ;; *) echo 'DESTDIR must be absolute' >&2; exit 1 ;; esac
bindir="$dest$prefix/bin"
datadir="$dest$prefix/share"
libdir="$dest$prefix/lib"
system_data="$dest/usr/share"
system_lib="$dest/usr/lib"
sysconf="$dest/etc"
# sudo keeps the caller's umask, and the build keeps it in file modes: a 077
# shell would install root-only copies the session user can't read (the bass
# plugin, wallpapers, cursors). Every copied tree is also normalized below.
umask 022
# Stage on the destination filesystem: rename never truncates a running executable.
install -d "${bindir}"
stage=$(mktemp -d "${bindir}/.rediwm-install.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT HUP INT TERM
# Every program the build installed, from its own list (build/install_paths.zig),
# never a glob of bin/: zig build leaves retired programs behind there.
programs=$(cat "$release_dir/programs")
for binary in $programs; do
    case "$binary" in
        rediwm|rediwm-*) case "$binary" in *[!a-z0-9-]*) echo "Invalid program name: $binary" >&2; exit 1 ;; esac ;;
        *) echo "Invalid program name: $binary" >&2; exit 1 ;;
    esac
    install -m755 "$release_dir/bin/$binary" "$stage/$binary"
done
install -Dm644 "$release_dir/share/applications/rediwm-theme.desktop" "${datadir}/applications/rediwm-theme.desktop"
install -Dm644 "$repo_dir/data/rediwm-theme.xml" "${datadir}/mime/packages/rediwm-theme.xml"
install -Dm644 "$release_dir/share/applications/rediwm-files.desktop" "${datadir}/applications/rediwm-files.desktop"
install -Dm644 "$release_dir/share/applications/rediwm-transfers.desktop" "${datadir}/applications/rediwm-transfers.desktop"
install -Dm644 "$release_dir/share/licenses/rediwm/libvterm-LICENSE" "${datadir}/licenses/rediwm/libvterm-LICENSE"
install -Dm644 "$release_dir/share/licenses/rediwm/libtorrent-LICENSE" "${datadir}/licenses/rediwm/libtorrent-LICENSE"
install -Dm644 "$release_dir/share/icons/hicolor/256x256/apps/redi-fm-icon.png" "${datadir}/icons/hicolor/256x256/apps/redi-fm-icon.png"
install -Dm644 "$release_dir/share/applications/rediwm-images.desktop" "${datadir}/applications/rediwm-images.desktop"
install -Dm644 "$release_dir/share/applications/rediwm-monitor.desktop" "${datadir}/applications/rediwm-monitor.desktop"
install -Dm644 "$release_dir/share/icons/hicolor/scalable/apps/rediwm-monitor.svg" "${datadir}/icons/hicolor/scalable/apps/rediwm-monitor.svg"
install -Dm644 "$release_dir/share/applications/rediwm-calculator.desktop" "${datadir}/applications/rediwm-calculator.desktop"
install -Dm644 "$release_dir/share/icons/hicolor/scalable/apps/rediwm-calculator.svg" "${datadir}/icons/hicolor/scalable/apps/rediwm-calculator.svg"
install -Dm644 "$release_dir/share/applications/rediwm-editor.desktop" "${datadir}/applications/rediwm-editor.desktop"
install -Dm644 "$release_dir/share/applications/rediwm-pdf.desktop" "${datadir}/applications/rediwm-pdf.desktop"
install -Dm644 "$release_dir/share/applications/rediwm-player.desktop" "${datadir}/applications/rediwm-player.desktop"
install -Dm644 "$release_dir/share/licenses/rediwm/miniaudio-LICENSE" "${datadir}/licenses/rediwm/miniaudio-LICENSE"
if [ -z "$dest" ] && command -v update-mime-database >/dev/null 2>&1; then update-mime-database "${datadir}/mime"; fi
if [ -z "$dest" ] && command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "${datadir}/applications"; fi
install -Dm644 "$repo_dir/data/rediwm-portals.conf" "${datadir}/xdg-desktop-portal/rediwm-portals.conf"
# xdg-desktop-portal reads backend descriptors only from its own datadir.
install -Dm644 "$repo_dir/data/rediwm.portal" "${system_data}/xdg-desktop-portal/portals/rediwm.portal"
install -Dm644 "$release_dir/share/polkit-1/actions/org.rediwm.accounts.policy" "${system_data}/polkit-1/actions/org.rediwm.accounts.policy"
install -Dm644 "$repo_dir/data/xdg-desktop-portal-wlr.ini" "${datadir}/xdg-desktop-portal-wlr/config"
install -Dm644 "$release_dir/share/wayland-sessions/rediwm-release-safe.desktop" "${system_data}/wayland-sessions/rediwm-release-safe.desktop"
# The bass boost's LADSPA plugin, and on Debian/Ubuntu builds the private
# wlroots 0.20 and dependencies found through the binaries' $ORIGIN/../lib/rediwm
# RUNPATH. Replaced as a whole right before the binaries so they stay in step.
if [ -d "$release_dir/lib/rediwm" ]; then
    install -d "$libdir"
    rm -rf "${libdir}/.rediwm-new"
    cp -R "$release_dir/lib/rediwm" "${libdir}/.rediwm-new"
    chmod -R u=rwX,go=rX "${libdir}/.rediwm-new"
    rm -rf "${libdir}/rediwm"
    mv -T "${libdir}/.rediwm-new" "${libdir}/rediwm"
fi
# Bundled Xcursor themes (aliases are symlinks); the compositor finds them
# through $ORIGIN/../share/icons, which it adds to XCURSOR_PATH.
for theme in "$release_dir"/share/icons/phinger-cursors-*/; do
    name=$(basename "$theme")
    rm -rf "${datadir}/icons/.$name-new"
    install -d "${datadir}/icons"
    cp -a "$theme" "${datadir}/icons/.$name-new"
    chmod -R u=rwX,go=rX "${datadir}/icons/.$name-new"
    rm -rf "${datadir}/icons/$name"
    mv -T "${datadir}/icons/.$name-new" "${datadir}/icons/$name"
done
# Bundled wallpapers, found through $ORIGIN/../share/rediwm/wallpapers.
rm -rf "${datadir}/rediwm/.wallpapers-new"
install -d "${datadir}/rediwm"
cp -R "$release_dir/share/rediwm/wallpapers" "${datadir}/rediwm/.wallpapers-new"
chmod -R u=rwX,go=rX "${datadir}/rediwm/.wallpapers-new"
rm -rf "${datadir}/rediwm/wallpapers"
mv -T "${datadir}/rediwm/.wallpapers-new" "${datadir}/rediwm/wallpapers"
# Packs carry artwork as well as the palettes embedded in the executables.
# Replace bundled packs individually, preserving any other installed packs.
for pack in "$release_dir"/share/rediwm/themes/*/; do
    [ -d "$pack" ] || continue
    name=$(basename "$pack")
    install -d "${datadir}/rediwm/themes"
    rm -rf "${datadir}/rediwm/themes/.$name-new"
    cp -R "$pack" "${datadir}/rediwm/themes/.$name-new"
    chmod -R u=rwX,go=rX "${datadir}/rediwm/themes/.$name-new"
    rm -rf "${datadir}/rediwm/themes/$name"
    mv -T "${datadir}/rediwm/themes/.$name-new" "${datadir}/rediwm/themes/$name"
done
for binary in $programs; do
    mv -fT "$stage/$binary" "${bindir}/$binary"
done
# The compositor draws the desktop itself; the old client is retired.
rm -f "${bindir}/rediwm-desktop"

if [ "$install_dm" = yes ]; then
    install -Dm644 "$release_dir/share/rediwm/rediwm-dm.service" "${system_lib}/systemd/system/rediwm-dm.service"
    install -Dm644 "$repo_dir/data/rediwm-dm.sysusers" "${system_lib}/sysusers.d/rediwm-dm.conf"
    install -Dm644 "$repo_dir/data/rediwm-dm.tmpfiles" "${system_lib}/tmpfiles.d/rediwm-dm.conf"

    pam_profile=${REDIWM_PAM_PROFILE:-}
    if [ -z "$pam_profile" ]; then
        if [ -f /etc/pam.d/system-local-login ]; then pam_profile=arch; else pam_profile=debian; fi
    fi
    case "$pam_profile" in arch|debian) ;; *) echo 'REDIWM_PAM_PROFILE must be arch or debian' >&2; exit 1 ;; esac
    if [ "$pam_profile" = arch ]; then
        install -Dm644 "$repo_dir/data/pam/rediwm-greeter" "${sysconf}/pam.d/rediwm-greeter"
        install -Dm644 "$repo_dir/data/pam/arch/rediwm-dm" "${sysconf}/pam.d/rediwm-dm"
        install -Dm644 "$repo_dir/data/pam/arch/rediwm-dm-autologin" "${sysconf}/pam.d/rediwm-dm-autologin"
    else
        install -Dm644 "$repo_dir/data/pam/rediwm-greeter" "${sysconf}/pam.d/rediwm-greeter"
        install -Dm644 "$repo_dir/data/pam/debian/rediwm-dm" "${sysconf}/pam.d/rediwm-dm"
        install -Dm644 "$repo_dir/data/pam/debian/rediwm-dm-autologin" "${sysconf}/pam.d/rediwm-dm-autologin"
    fi

    if [ ! -f "${sysconf}/rediwm/dm.conf" ]; then
        install -d "${sysconf}/rediwm"
        install -m644 "$release_dir/share/rediwm/rediwm-dm.conf" "${sysconf}/rediwm/dm.conf"
    fi

    # Only our own configs: a bare call would apply every sysusers/tmpfiles
    # entry on the system.
    if [ -z "$dest" ] && command -v systemd-sysusers >/dev/null 2>&1; then
        systemd-sysusers "${system_lib}/sysusers.d/rediwm-dm.conf"
    fi
    if [ -z "$dest" ] && command -v systemd-tmpfiles >/dev/null 2>&1; then
        systemd-tmpfiles --create "${system_lib}/tmpfiles.d/rediwm-dm.conf"
    fi
    if [ -z "$dest" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
    fi
fi
