# RediWM

<div align="center">

<img width="690" height="519" alt="Screenshot-1791166153-291331984-4" src="https://github.com/user-attachments/assets/7ba5668a-649f-4bae-ac2c-ec08f6826b14" />

### A Wayland compositor with its own desktop shell, built in Zig

<!-- badges go here -->

</div>   

RediWM is a [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) compositor
that draws its whole shell itself: taskbar, start menu, settings, lock and login
screens, notifications and OSDs, all in one process, benchmarked against
[labwc](https://labwc.github.io/) to stay as lean.

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
curl -fsSL https://raw.githubusercontent.com/oxydizer/rediwm/HEAD/scripts/install.sh | sh    # add `-s -- --dm` for rediwm-dm
```

`scripts/install.sh` installs the prebuilt release for your distro (Arch,
Debian, Ubuntu and Fedora on x86_64, and their derivatives): the compositor,
the apps and the exact wlroots 0.20 they were tested with, including the
[window-title patch](patches/wlroots/README.md). Installing never replaces your login manager. SDDM, GDM and the
like keep working, and RediWM only appears as a session in their picker. The
`rediwm-dm` login manager is installed only with `--dm`, and even then it is
not enabled (see below).

## Building and running

Requirements: Zig 0.16, wlroots 0.20 (`scripts/install.sh --build` builds it
into a private prefix on Debian/Ubuntu, and `REDIWM_PRIVATE_WLROOTS=1` does so
on Arch and Fedora), and the development files for Wayland,
wayland-protocols, xkbcommon, pixman, FreeType, HarfBuzz, Fontconfig,
librsvg/GdkPixbuf, PangoCairo, libinput, PAM, libpulse, libpipewire-0.3, Poppler GLib,
libseccomp, libjpeg and libpng. Optional:
Xwayland, `foot`, `brightnessctl`, `gio`/`xdg-open`, `git` (Files repository status).

Runtime portals: `xdg-desktop-portal`, `xdg-desktop-portal-wlr` for screen
sharing, and `xdg-desktop-portal-gtk` for fallback portals. `scripts/install.sh`
installs all three.

```sh
zig build run -- foot                     # nested in your current Wayland session
zig build -Doptimize=ReleaseSafe          # for daily use and measurements
sh scripts/install-session.sh             # install and restart the running session
sh scripts/install-session.sh --no-restart --dm   # install only, plus rediwm-dm
```

Run from a checkout, `scripts/install.sh` builds that checkout (dependencies,
then `install-session.sh` with the arguments you give it).

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

All bindings live in `[keybinds]` (`"noop"` disables one).

- Alt+drag moves windows, Alt+right-drag resizes. **Super+Alt+mouse** or a
  middle-button drag pans the desktop; **Super+Alt+scroll** zooms it, and
  **Alt+scroll** over a window zooms just that window. Ordinary desktop zoom scales all
  windows together around the pointer, up to 100%, without changing their
  world positions. Desktop icons stay fixed by default; the taskbar stays fixed.
  The shared volume/brightness OSD also shows the desktop zoom percentage.
- **Window switching zoom** in Settings → Appearance controls Alt+Tab,
  directional focus and taskbar activation. **Boost window** (the default)
  temporarily brings the selected floating window to 100% on-screen size
  while preserving desktop zoom, its position and its saved window zoom.
  Switching away restores its original scale. **Keep zoom** only pans;
  **Focus camera** zooms the desktop to the selected window's depth, fading
  windows that would grow beyond full size. In that mode, desktop zoom also
  steps through the depths of open windows above 100%. Configure this with
  `[compositor] focus_zoom = "boost"`, `"keep"`, or `"camera"`.
  Window reveals ease over 320 ms, and titlebar scrolling uses the same
  eased window zoom as Alt+scroll. Animation speed and reduced motion apply
  to these transitions; `[animations.camera_reveal]` can override the pan.
- **Window tabs** in Settings → Appearance lets you enable tabs per app using
  RediWM chrome (XDG, KDE or X11 decorations). Open an app once to list it.
  **+** opens another window as a tab in that frame; ordinary launches stay
  separate. Each tab has a close button, and the outer close button closes
  the group while respecting app confirmation dialogs. Disabling tabs restores
  separate windows. App IDs are saved in `[compositor] window_tab_apps`.
  Arrow buttons and scrolling over the strip switch tabs; Alt+scroll still
  zooms the window. Apps need a desktop entry with a usable launch command;
  launches that only activate an existing window do not create a tab.
- **Settings** (start menu cog) is a regular window covering display modes,
  scale and night light, input, audio, appearance, shortcuts and the desktop
  canvas. Changes are saved to the config with its comments intact.
- The lock screen covers every output; Escape clears the field and never
  unlocks. It engages before the system sleeps, and sleep waits until it is
  on screen (`[compositor] lock_on_suspend`, on by default), and on
  `loginctl lock-session`. RediWM doesn't lock on idle itself: run
  `swayidle -w timeout 300 'swaylock -f'` from `[[autostart]]`.
- Desktop icons run a `.desktop` launcher only if it is installed, owned by
  root, executable, or an exact copy of an installed entry. Any other
  launcher shows as the file it is until you choose **Allow Launching** from
  its menu.
- `rediwm-dm` runs the greeter as an unprivileged user on its own VT. After
  installing, disable your current display manager, `sudo systemctl enable
  rediwm-dm` and reboot; options live in `/etc/rediwm/dm.conf`.
- In `rediwm-files`, **Space** opens images, PDFs and text files. **Text Editor**
  (`rediwm-editor [FILE ...]`) opens text files in tabs in one window per display.
  Use **Ctrl+N** for a new tab, **Ctrl+O** to open, **Ctrl+S** to save,
  **Ctrl+Shift+S** for the existing Save As dialog, **Ctrl+Page Up/Down** to
  switch tabs, **Ctrl+W** to close a tab, and **Ctrl+F** / **F3** to find text.
  It supports UTF-8 files up to 16 MiB, preserves BOM and line endings, and
  prompts before discarding changes. Files, Images and Text Editor also run
  on other Wayland compositors.
- Games get pointer lock and relative motion. VMs and remote desktops can
  capture shortcuts; **Super+Escape** takes them back.
- The desktop renders before autostart; session environment publication and
  audio connection do not block frames or input. Xwayland starts on the first
  X11 connection, including with native scaling.
- X11 limits of wlroots 0.20: X11→Wayland drag-and-drop
  doesn't start, and X11 pointer input on a second output doesn't arrive.

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

The `.toml` files use a **line-based TOML subset**, including standalone theme
files.  

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
