# Getting Started

## Install

`scripts/install.sh` installs the prebuilt release for your distro (Arch,
Debian, Ubuntu and Fedora on x86_64, and their derivatives). It brings the exact
wlroots 0.20 RediWM was tested with, installs the runtime libraries through your
package manager, checks the download's checksum and adds a **RediWM** session
entry. Nothing is compiled. Pass `--build` to compile from source instead; that
is also the fallback for other distros and CPUs, or if the release's libraries
don't match yours. `REDIWM_VERSION=<tag>` installs a specific release.

```sh
curl -fsSL https://rediwm.redios.org/install.sh | sh -s -- --dm   # --dm also installs rediwm-dm
```

Installing never replaces your login manager. SDDM, GDM and friends keep
working. `rediwm-dm` is only installed with `--dm`, and even then it isn't
enabled.

Optional: `foot`, `brightnessctl`, `gio`/`xdg-open`, `git` (for Files repo
status), `paplay` (event sounds). For screen sharing you want
`xdg-desktop-portal`, `xdg-desktop-portal-wlr` and `xdg-desktop-portal-gtk`;
the installer adds all three.

## Build and run

Building needs Zig 0.16 and wlroots 0.20 (`scripts/install.sh --build` builds it
into a private prefix on Debian/Ubuntu; `REDIWM_PRIVATE_WLROOTS=1` does the same
on Arch and Fedora), plus dev files for Wayland, wayland-protocols, xkbcommon,
pixman, FreeType, HarfBuzz, Fontconfig, librsvg/GdkPixbuf, PangoCairo, libinput,
PAM, libpulse, libpipewire-0.3, Poppler GLib, libseccomp, libjpeg and libpng.

```sh
zig build run -- foot                     # nested in your current Wayland session
zig build -Doptimize=ReleaseSafe          # for daily use and measurements
sh scripts/install-session.sh             # install and restart the running session
sh scripts/install-session.sh --no-restart --dm   # install only, plus rediwm-dm
```

From a checkout, `scripts/install.sh` does deps, build, then
`install-session.sh` with whatever args you pass.

Installing adds a **RediWM** entry to `/usr/share/wayland-sessions`.

## Nested sessions

Running inside another Wayland session is handy for hacking, but:

- It's never sharper than the host. Use `REDIWM_SCALE=1` to judge layout.
- The Wayland backend never sets buffer scale, so don't judge sharpness there.

## Crashes and recovery

`rediwm-session` restarts the compositor after a crash, at most 5 times a
minute. If the session was locked when it crashed, it comes back locked. Logs
go to `$XDG_STATE_HOME/rediwm/session.log`.

Stuck? Switch VTs with **Ctrl+Alt+F1..F12** (works while locked), or:

```sh
pkill -u "$(id -u)" -x rediwm
```

Restarting over IPC (`restart_shell`) disconnects every app.
