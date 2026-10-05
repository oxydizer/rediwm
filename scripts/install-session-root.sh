#!/bin/sh
# Root-only install payload for install-session.sh. Not meant to be run directly.
set -eu
repo_dir=$1
release_dir=$2
install_dm=${3:-no}
# sudo keeps the caller's umask, and the build keeps it in file modes: a 077
# shell would install root-only copies the session user can't read (the bass
# plugin, wallpapers, cursors). Every copied tree is also normalized below.
umask 022
# Stage on the destination filesystem: rename never truncates a running executable.
install -d /usr/local/bin
stage=$(mktemp -d /usr/local/bin/.rediwm-install.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT HUP INT TERM
for binary in rediwm rediwm-msg rediwm-files rediwm-images rediwm-editor rediwm-pdf rediwm-share-picker rediwm-session rediwm-dm rediwm-accounts-helper; do
    install -m755 "$release_dir/bin/$binary" "$stage/$binary"
done
install -Dm644 "$repo_dir/data/rediwm-files.desktop" /usr/local/share/applications/rediwm-files.desktop
install -Dm644 "$repo_dir/data/rediwm-images.desktop" /usr/local/share/applications/rediwm-images.desktop
install -Dm644 "$repo_dir/data/rediwm-editor.desktop" /usr/local/share/applications/rediwm-editor.desktop
install -Dm644 "$repo_dir/data/rediwm-pdf.desktop" /usr/local/share/applications/rediwm-pdf.desktop
install -Dm644 "$repo_dir/data/rediwm-portals.conf" /usr/local/share/xdg-desktop-portal/rediwm-portals.conf
# xdg-desktop-portal reads backend descriptors only from its own datadir.
install -Dm644 "$repo_dir/data/rediwm.portal" /usr/share/xdg-desktop-portal/portals/rediwm.portal
install -Dm644 "$repo_dir/data/org.rediwm.accounts.policy" /usr/share/polkit-1/actions/org.rediwm.accounts.policy
install -Dm644 "$repo_dir/data/xdg-desktop-portal-wlr.ini" /usr/local/share/xdg-desktop-portal-wlr/config
install -Dm644 "$repo_dir/data/rediwm-release-safe.desktop" /usr/share/wayland-sessions/rediwm-release-safe.desktop
# The bass boost's LADSPA plugin, and on Debian/Ubuntu builds the private
# wlroots 0.20 and dependencies found through the binaries' $ORIGIN/../lib/rediwm
# RUNPATH. Replaced as a whole right before the binaries so they stay in step.
if [ -d "$release_dir/lib/rediwm" ]; then
    rm -rf /usr/local/lib/.rediwm-new
    cp -R "$release_dir/lib/rediwm" /usr/local/lib/.rediwm-new
    chmod -R u=rwX,go=rX /usr/local/lib/.rediwm-new
    rm -rf /usr/local/lib/rediwm
    mv -T /usr/local/lib/.rediwm-new /usr/local/lib/rediwm
fi
# Bundled Xcursor themes (aliases are symlinks); the compositor finds them
# through $ORIGIN/../share/icons, which it adds to XCURSOR_PATH.
for theme in "$release_dir"/share/icons/*/; do
    name=$(basename "$theme")
    rm -rf "/usr/local/share/icons/.$name-new"
    install -d /usr/local/share/icons
    cp -a "$theme" "/usr/local/share/icons/.$name-new"
    chmod -R u=rwX,go=rX "/usr/local/share/icons/.$name-new"
    rm -rf "/usr/local/share/icons/$name"
    mv -T "/usr/local/share/icons/.$name-new" "/usr/local/share/icons/$name"
done
# Bundled wallpapers, found through $ORIGIN/../share/rediwm/wallpapers.
rm -rf /usr/local/share/rediwm/.wallpapers-new
install -d /usr/local/share/rediwm
cp -R "$release_dir/share/rediwm/wallpapers" /usr/local/share/rediwm/.wallpapers-new
chmod -R u=rwX,go=rX /usr/local/share/rediwm/.wallpapers-new
rm -rf /usr/local/share/rediwm/wallpapers
mv -T /usr/local/share/rediwm/.wallpapers-new /usr/local/share/rediwm/wallpapers
for binary in rediwm rediwm-msg rediwm-files rediwm-images rediwm-editor rediwm-pdf rediwm-share-picker rediwm-session rediwm-dm rediwm-accounts-helper; do
    mv -fT "$stage/$binary" "/usr/local/bin/$binary"
done
# The compositor draws the desktop itself; the old client is retired.
rm -f /usr/local/bin/rediwm-desktop

if [ "$install_dm" = yes ]; then
    install -Dm644 "$repo_dir/data/rediwm-dm.service" /usr/lib/systemd/system/rediwm-dm.service
    install -Dm644 "$repo_dir/data/rediwm-dm.sysusers" /usr/lib/sysusers.d/rediwm-dm.conf
    install -Dm644 "$repo_dir/data/rediwm-dm.tmpfiles" /usr/lib/tmpfiles.d/rediwm-dm.conf

    if [ -f /etc/pam.d/system-local-login ]; then
        install -Dm644 "$repo_dir/data/pam/rediwm-greeter" /etc/pam.d/rediwm-greeter
        install -Dm644 "$repo_dir/data/pam/arch/rediwm-dm" /etc/pam.d/rediwm-dm
        install -Dm644 "$repo_dir/data/pam/arch/rediwm-dm-autologin" /etc/pam.d/rediwm-dm-autologin
    else
        install -Dm644 "$repo_dir/data/pam/rediwm-greeter" /etc/pam.d/rediwm-greeter
        install -Dm644 "$repo_dir/data/pam/debian/rediwm-dm" /etc/pam.d/rediwm-dm
        install -Dm644 "$repo_dir/data/pam/debian/rediwm-dm-autologin" /etc/pam.d/rediwm-dm-autologin
    fi

    if [ ! -f /etc/rediwm/dm.conf ]; then
        install -d /etc/rediwm
        install -m644 "$repo_dir/data/rediwm-dm.conf" /etc/rediwm/dm.conf
    fi

    # Only our own configs: a bare call would apply every sysusers/tmpfiles
    # entry on the system.
    if command -v systemd-sysusers >/dev/null 2>&1; then
        systemd-sysusers /usr/lib/sysusers.d/rediwm-dm.conf
    fi
    if command -v systemd-tmpfiles >/dev/null 2>&1; then
        systemd-tmpfiles --create /usr/lib/tmpfiles.d/rediwm-dm.conf
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
    fi
fi
