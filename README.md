# RediWM

<div align="center">

<img width="690" height="519" alt="Screenshot-1791166153-291331984-4" src="https://github.com/user-attachments/assets/7ba5668a-649f-4bae-ac2c-ec08f6826b14" />

### A Wayland compositor with its own desktop shell, built in Zig

</div>   

RediWM is a single process [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) compositor
that draws its whole shell itself: taskbar, start menu, settings, lock and login
screens, notifications and OSDs, all in one process, benchmarked against
[labwc](https://labwc.github.io/) to stay as lean (192mb idle ram usage, <1% CPU usage)

https://github.com/user-attachments/assets/60bc1190-694c-4fb7-b2bc-d90e5e9faa90

## Features

- **One process, not a stack:** no waybar, greeter, launcher or notification
  daemon to wire up.
- **Pan-and-zoom desktop:** a canvas several screens wide; zoom the desktop or
  single windows.
- **Lock and login screens** with PAM, plus `rediwm-dm`, a small display manager.
- **Notification daemon** with actions, images and do-not-disturb rules.
- **Sharp X11 apps on HiDPI** through Xwayland native scaling.
- **GPU glass** behind shell surfaces, re-blurred only when needed.
- **Works with wlroots tools:** wlr-randr, kanshi, swaylock, swayidle, grim,
  wf-recorder, wayvnc, docks.
- **JSON IPC** (`rediwm-msg`), desktop icons, a file manager and an image viewer.
- **Crash-resilient:** bounded restarts and layout autosave.

## Installing

```sh
curl -fsSL https://rediwm.redios.org/install.sh | sh    # add `-s -- --dm` for rediwm-dm
```

`scripts/install.sh` installs the prebuilt release for your distro (Arch,
Debian, Ubuntu and Fedora).
Installing never replaces your login manager

## Building and running

Requirements: Zig 0.16, wlroots 0.20, and the development files for Wayland,
wayland-protocols, xkbcommon, pixman, FreeType, HarfBuzz, Fontconfig,
librsvg/GdkPixbuf, PangoCairo, libinput, PAM, libpulse, libpipewire-0.3, Poppler GLib,
libseccomp, libjpeg and libpng. Optional:
Xwayland, `foot`, `brightnessctl`, `gio`/`xdg-open`, `git` (optional).

Run from a checkout, `scripts/install.sh` builds that checkout (dependencies,
then `install-session.sh` with the arguments you give it).

```sh
zig build run -- foot                     # nested in your current Wayland session
zig build -Doptimize=ReleaseSafe          # for daily use and measurements
sh scripts/install-session.sh             # install and restart the running session
sh scripts/install-session.sh --no-restart --dm   # install only, plus rediwm-dm
```

### Releasing

`scripts/make-release.sh` builds each distro's tarball (`rediwm-<distro>-x86_64.tar.gz`)
in a clean container of that distro, with `scripts/build-wlroots.sh`'s pinned.

`rediwm-pdf FILE` opens one PDF in a sandboxed viewer process. It requires
Landlock ABI 3 or newer and a compositor with `security-context-v1` (including
RediWM); it refuses to parse a document if isolation cannot be established.
 
## Using it

| Keys | Action |
| --- | --- |
| Super+Space | start menu |
| Super+T / E / B | terminal / Files / browser |
| Super+Q, Super+F, Super+M | close, fullscreen, maximize |
| Super+Shift+arrows | tile halves and quarters |
| Super+arrows | slide to the neighbouring desktop |
| Super+Ctrl+arrows | focus the window in that direction |
| Alt+Tab | window switcher |
| Super+1…5, Super+=/-/0 | window zoom |
| Super+Shift+=/-/0 | desktop zoom |
| Super+L | lock |
| Ctrl+Shift+S, Print | region / full-screen screenshot |
| Super+Z | undo the last window move or resize |
| Super+Shift+E | quit |

All bindings live in `[keybinds]`; `"noop"` disables one.

- **Mouse:** Alt+drag moves windows, Alt+right-drag resizes. Super+Alt+drag (or middle-drag) pans the desktop, Super+Alt+scroll zooms it, and Alt+scroll zooms a single window.
- **Zoom on window switch:** `[compositor] focus_zoom` (also in Settings → Appearance) controls what Alt+Tab, directional focus and taskbar activation do. `"boost"` (default) shows the window at 100% until you switch away, `"keep"` only pans, and `"camera"` zooms the desktop to the window's depth.
- **Window tabs:** enable per app in Settings → Appearance (saved in `[compositor] window_tab_apps`). **+** opens a new window as a tab. The app needs a desktop entry with a launch command.
- **Lock screen:** covers every output and engages before suspend (`[compositor] lock_on_suspend`) and on `loginctl lock-session`. There's no idle lock; add `swayidle -w timeout 300 'swaylock -f'` to `[[autostart]]`.
- **Desktop icons:** a `.desktop` launcher only runs if it's installed, root-owned, executable, or an exact copy of an installed entry. Otherwise, choose **Allow Launching** from its menu.
- **`rediwm-dm`:** disable your current display manager, run `sudo systemctl enable rediwm-dm`, and reboot. Options are in `/etc/rediwm/dm.conf`.
- **Text editor:** `rediwm-editor [FILE ...]` opens UTF-8 files in tabs, from tiny notes to logs of hundreds of megabytes (up to 4 GiB, if they fit in free memory). Ctrl+N new, Ctrl+O open, Ctrl+S save, Ctrl+Shift+S save as, Ctrl+W close tab, Ctrl+PgUp/PgDn switch tabs, Ctrl+F or F3 find. In `rediwm-files`, Space previews images, PDFs and text.
- **Games and VMs:** games get pointer lock and relative motion. If a VM or remote desktop grabs your shortcuts, Super+Escape takes them back.
- **Known issues (wlroots 0.20):** X11→Wayland drag-and-drop doesn't start, and X11 pointer input on a second output doesn't arrive.

## Protocols

Beyond xdg-shell, layer-shell and Xwayland:

| Area | Protocols | Works with |
| --- | --- | --- |
| Displays | `wlr-output-management-v1`, `xdg-output-v1` | wlr-randr, kanshi, nwg-displays |
| Window lists | `wlr-foreign-toplevel-management-v1`, `ext-foreign-toplevel-list-v1` | docks, waybar, rofi/fuzzel, wlrctl |
| Capture | `wlr-screencopy-v1`, `ext-image-copy-capture-v1` | grim, wf-recorder, OBS, xdg-desktop-portal-wlr |
| Locking and idle | `ext-session-lock-v1`, `ext-idle-notify-v1`, `idle-inhibit-v1` | swaylock, gtklock, swayidle |
| Remote input | `virtual-pointer-v1`, `virtual-keyboard-v1` | wayvnc, KDE Connect, wtype |
| Clipboard | `wlr-data-control-v1`, `ext-data-control-v1`, primary selection | wl-clipboard |
| Input | `text-input-v3`, `input-method-v2`, `relative-pointer-v1`, `pointer-constraints-v1`, `keyboard-shortcuts-inhibit-v1`, `pointer-gestures-v1`, `cursor-shape-v1` | fcitx5, IBus, games, virt-manager |
| Workspace | `ext-workspace-v1` | one active Canvas workspace shared by all outputs |
| Window metadata | `xdg-toplevel-tag-v1`, `content-type-v1`, `xdg-activation-v1` | window rules, content hints, authorized activation |
| Colour | `color-management-v1`, `color-representation-v1` | renderer-supported colour spaces and pixel representations |
| Presentation | `tearing-control-v1`, `drm-lease-v1` | opt-in fullscreen tearing, DRM-connected VR headsets |
| Rendering | `fractional-scale-v1`, `viewporter`, `single-pixel-buffer-v1`, `linux-dmabuf-v1`, `linux-drm-syncobj-v1`, `presentation-time` | |
 
 
## Configuration

`$XDG_CONFIG_HOME/rediwm/config.toml` (`REDIWM_CONFIG` overrides) is written with
commented defaults on first run and reloads on save; a parse error keeps the
previous config. Sections: `[theme]`, `[input]`, `[input_method]`,
`[compositor]`, `[region]`, `[idle]`, `[night_light]`, `[notifications]`, `[desktop]`,
`[polkit]`, `[ipc]`, `[keybinds]`, `[[outputs]]`, `[[autostart]]`,
`[[window_rules]]`, `[[notification_rules]]` and `[[sandbox_allow]]`.

Window rules match by globs; for each property the last matching rule wins:

```toml
[[window_rules]]
app_id = ["firefox", "chromium"]
title = "*Picture-in-Picture*"
opacity = 0.9
skip_taskbar = true
focus = false
```

Matchers: `app_id`, `title`, `x11_class`, `x11_instance`, `backend`, `dialog`
and `exclude_*`. Properties: `output`, `x`, `y`, `center`, `width`, `height`,
`maximized`, `fullscreen`, `focus`, `depth`, `opacity`, `decorations`,
`skip_taskbar`.

## IPC

The socket is `$XDG_RUNTIME_DIR/rediwm-<WAYLAND_DISPLAY>.sock` (or
`REDIWM_SOCKET`), in a private directory only. `rediwm-msg` wraps it
(`rediwm-msg outputs`, `output-config DP-1 --scale 1.5`, `notifications`, …);
`src/ipc/protocol.zig` is the reference. Synthetic input and pixel reads need
`[ipc] automation = true` (or `REDIWM_IPC_AUTOMATION=1`), and everything is
refused while locked.

IPC v1 is UTF-8 JSON, one request and one response per newline. Every request
uses this envelope (command names are case-sensitive snake_case):

```json
{"version":1,"id":1,"command":"windows"}
{"version":1,"id":2,"command":"move_cursor","params":{"x":100,"y":200}}
```

Settings and desktop inspection also work without opening Settings:

| Query/action | Parameters and behavior |
| --- | --- |
| `get_services` | System services, raw systemd state, activation times (`activation_us`) and total `boot_us`. First requests may report `loading`/`analyzing`; unavailable times are null. |
| `set_service_mode` | `service`, `mode`: `on`, `disabled`, or `on-demand`. Changes boot policy without starting/stopping the unit. `on-demand` requires an existing activation trigger and disables boot enablement; it does not create or enable a socket/timer. `deferred` returns `UnsupportedServiceMode`. Static/masked units are read-only. |
| `get_sounds` | Configured theme and registered events, including enabled/available flags and resolved files. |
| `play_sound` | `event`: a name from `get_sounds`. Queues an enabled, available event using `/usr/bin/paplay`; returns an accepted playback PID, not a playback-completion guarantee. |
| `get_wallpaper` | Configured selection, resolved and displayed paths, dimensions, loading and failure/fallback status. |
| `set_wallpaper` | `path`: wallpaper name or file path; `""` restores the bundled default. Decode is asynchronous; inspect `get_wallpaper` for completion/fallback. |
| `get_theme` | Effective theme `tokens`, theme file path (null for inline configuration), and dark-mode preference. Colors are straight RGBA arrays in 0–1; null optional tokens use the UI's automatic defaults. |
| `set_accent_color` | `color`: `#RRGGBB` or `#RRGGBBAA`; updates live shell decorations and widgets. |
| `get_processes` | Window-owning app processes grouped by PID, with window IDs, RSS bytes and CPU sampled for approximately 200 ms on a worker. 100% means one logical CPU; this excludes background processes and app child-process aggregation. Missing/exited processes have null usage. No idle sampling. |
| `set_night_light` | Optional `enabled` and `temperature` (1700–10000 K); at least one required. Enabling follows the configured schedule. |
 

## More

- [SECURITY.md](SECURITY.md): security boundaries and decisions.
- [TESTING.md](TESTING.md): unit and headless integration tests.
- [D-Bus transport](src/dbus/README.md) and [polkit agent](src/polkit/README.md).
- Fonts: Manrope and JetBrains Mono (OFL); cursors:
  [phinger-cursors](https://github.com/phisch/phinger-cursors) (CC BY-SA 4.0).

## License

RediWM's own code is dual-licensed under either of

- [Apache License, Version 2.0](LICENSE-APACHE)
- [MIT license](LICENSE-MIT)

at your option. Unless you explicitly state otherwise, any contribution
intentionally submitted for inclusion in RediWM by you, as defined in the
Apache-2.0 license, shall be dual-licensed as above, without any additional
terms or conditions.

Bundled third-party assets keep their own licenses: the fonts under
`assets/fonts` (SIL OFL 1.1) and the cursors under `assets/cursors` (CC BY-SA 4.0).
