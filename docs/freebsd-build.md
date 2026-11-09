# Building RediWM on FreeBSD

Experimental: FreeBSD 15.x only (D1 in [the plan](plans/freebsd.md)), amd64.
The tree builds and the unit tests pass; the compositor needs a DRM render
node to start, so a VM without a GPU stops at renderer initialisation. Which
features work is in the plan.

## Packages

These are the packages' names. Each was checked against the FreeBSD 15.1
`latest` catalogue on 2026-11-06 and exists. To check again (`pkg search -e`
compares the name with its version, so it finds nothing here; `pkg rquery`
compares the name alone):

    for p in wayland wayland-protocols wlroots020 libxkbcommon cups pixman \
        freetype2 harfbuzz fontconfig cairo pango librsvg2-rust gdk-pixbuf2 \
        glib webp libarchive libinput libudev-devd png jpeg-turbo pulseaudio \
        pipewire libxcb poppler-glib readline libglvnd mesa-dri libdrm \
        pkgconf python3 py312-pillow seatd dbus xwayland dejavu; do
        [ -n "$(pkg rquery -x '%n' "^$p\$")" ] && echo "ok $p" || echo "MISSING $p"
    done

What each is for:

* **Toolchain:** Zig 0.17, `pkgconf`, a C and C++ compiler (base clang),
  `python3` and `py312-pillow` for the integration tests (they import PIL;
  without it every one of them fails on its first line).
* **Graphics stack:** `wlroots020` (0.20 exactly; it pulls in most of this
  stack, but list it all), `wayland` (client, server, cursor and
  `wayland-scanner`), `wayland-protocols`, `libxkbcommon`, `pixman`,
  `libglvnd` and `mesa-dri` (EGL, GLESv2), `libxcb`.
* **Drawing and files:** `cairo`, `pango`, `freetype2`, `harfbuzz`,
  `fontconfig`, `librsvg2-rust`, `gdk-pixbuf2`, `glib` (gio and gobject),
  `png`, `jpeg-turbo`, `webp`, `libarchive`, `poppler-glib` (the PDF viewer),
  `readline` (the Files terminal's shell hook).
* **Services the compositor talks to:** `cups`, `pulseaudio` (libpulse),
  `pipewire` (the bass boost; it is linked, not optional). PAM is the base
  system's OpenPAM, `libutil` and `libm` are base too.
* **To run a session:** `seatd` (running, the user in its group), `dbus`,
  `xwayland`, a GPU driver (`drm-kmod` and its firmware package) and a
  monospace font for the editor tests (`dejavu`). The login stack is probed
  with `tools/freebsd-probe/login-probe.sh`.
* **Only with `-Dtransfers`** (off on FreeBSD): `libtorrent-rasterbar2`,
  `json-glib`.

## Build

    zig build                              # Debug (LLVM backend by default)
    zig build -Doptimize=ReleaseSafe
    zig build test

Off by default on FreeBSD: the transfers helper (`-Dtransfers`) and
`rediwm-session` (`-Dlogin-session`) and `rediwm-dm` (`-Ddisplay-manager`). The install prefix is
`/usr/local`, configuration `/usr/local/etc` and run state `/var/run`
(`-Dinstall-prefix`, `-Dsysconfdir`, `-Drundir`).

## Tests

`zig build test` runs the unit tests and the other `test-*` steps single
areas. On FreeBSD 15.1 without a GPU (2026-11-06) these pass: `test`,
`test-monitor`, `test-platform`, `test-polkit`, `test-dbus` (its part that
drives the bus with `busctl`, systemd's tool, skips), `test-files`,
`test-i18n`, `test-wlroots`, `test-lock`, `test-editor`, `test-images`,
`test-pdf`, `test-lifecycle`, `test-node`, `test-projection`, `test-glass`,
`test-gpu-timing` and `test-switcher-preview`. Skips on FreeBSD are on
purpose: the German and Russian name-order tests (libc's order differs from
glibc's) and the folder-size test that counts `/proc/self/fd`.

Everything that starts the compositor needs a DRM render node
(`/dev/dri/renderD128`, `WLR_RENDER_DRM_DEVICE` pointing at it) and fails
without one with `No rediwm-*.sock found`: `test-power`,
`test-power-profiles`, `test-tray`, `test-notifications`, `test-file-chooser`,
`test-settings-portal`, `test-app-activation`, `test-layout-autosave`,
`test-printers`, `test-files-terminal` and the `tests/*.py` suites. The
Python tests import PIL (`py312-pillow`), and some compile C clients with
plain `cc`: export `CPATH=/usr/local/include LIBRARY_PATH=/usr/local/lib`.
A qemu guest has a render node only with a virtio GPU:
`-device virtio-vga-gl -display sdl,gl=on`, and `virtio_gpu_drm` in
`kld_list`. With that, the headless compositor runs GLES2 on
`/dev/dri/renderD128` (Mesa's virgl driver).

Run the suites one at a time, each in its own scratch `HOME` and `XDG_*`
directories, and do not wrap them in `timeout(1)`: on FreeBSD it can keep
waiting after its child has exited, so a suite that passed reports a timeout.
A loop that polls `kill -0` and kills at a limit works. Tools some suites
need besides the packages above: `squashfs-tools` (`files_associations`),
`xdpyinfo` (`xwayland*`), `wlr-randr`, `py312-libtorrent-rasterbar`
(`files_torrents`). Several suites are Linux only: `system_monitor` (a seccomp
guard and `/proc`), `motion_perf` and `editor_visuals` (`/proc`),
`battery_*` and `pdf_sandbox` (Linux hook libraries), `steamos_bundle`,
and those that need `rediwm-dm`. The supervisor's portable tests are listed below;
its logind-specific bus fixture and pidfd-based readiness fixture remain Linux only.


## Console session candidate

The ConsoleKit2 backend and kqueue supervisor compile, but have not yet had
native runtime qualification. Build the supervisor without the display manager:

    zig build -Dlogin-session=true -Ddisplay-manager=false
    zig build test-platform test-monitor test-login-manager
    python3 tests/rediwm_session.py
    python3 tests/session_services.py zig-out/bin/rediwm-session

Enable dbus, ConsoleKit2, seatd and polkit; configure `pam_xdg` for the console
login and join the seatd socket's group. From a real `/dev/ttyv*` console login,
with a private `XDG_RUNTIME_DIR`, start using the installed path:

    export LIBSEAT_BACKEND=seatd
    exec /usr/local/bin/rediwm-session

The supervisor creates its own ConsoleKit2 session, exports its cookie only to
its children, and closes it at logout. It reuses a responding inherited user
bus or starts a private one. The session bus survives compositor restarts.
The legacy polkit helper socket may be absent: the existing fallback checks
root ownership and setuid permissions before launching polkit's helper.

Before enabling the supervisor by default, run the crash/locked-crash and
adopted-child tests above on FreeBSD, and qualify VT switching, console input
isolation, polkit prompts, suspend inhibitors, resume and clean logout on DRM.
`tests/session_bus.py` specifically exercises the logind backend on Linux;
`test-login-manager` exercises ConsoleKit2 with an independent private bus on
either OS. Power/battery/brightness hardware qualification is still separate.
