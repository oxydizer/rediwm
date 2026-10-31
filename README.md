# RediWM
<div align="center">
<img width="1085" height="233" alt="redi-logo" src="https://github.com/user-attachments/assets/4e80c572-bd30-4800-bcf3-acb95299358d" />

### A Wayland compositor with its own desktop shell, built in Zig

</div>   

RediWM is a single process [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) compositor
that draws its whole shell itself: taskbar, start menu, settings, lock and login
screens, notifications and OSDs, all in one process, benchmarked against
[labwc](https://labwc.github.io/) to stay as lean (< 200mb idle ram usage, <1% CPU usage)

|  |  |
| :---: | :---: |
| <img width="100%" alt="Screenshot 1" src="https://github.com/user-attachments/assets/b4cbd48c-ccab-452e-8457-2d1b8c096def" /> | <img width="100%" alt="Screenshot 2" src="https://github.com/user-attachments/assets/10f9becc-bcd9-4089-872b-4a03d1dba818" /> |
| <img width="100%" alt="Screenshot 3" src="https://github.com/user-attachments/assets/a0ccd5f3-7476-4171-80c5-5f74a751e6b7" /> | <img width="100%" alt="Screenshot 4" src="https://github.com/user-attachments/assets/dd0cdae7-4c4d-401c-9624-80895897d0de" /> |

## Features

- **One process:** no waybar, greeter, launcher or notification
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

## Installing

**Arch and derivatives (including Artix and CachyOS), Debian, Ubuntu and Fedora:**
install the prebuilt release with:

```sh
curl -fsSL https://rediwm.redios.org/install.sh | sh    # add `-s -- --dm` for rediwm-dm
```

**NixOS (x86_64):** use the [flake and NixOS module](docs/nix.md), rather than
the shell installer above.

To build just the Nix package, without configuring a login session:

```sh
nix build github:oxydizer/rediwm
``` 

## Building and running

Requirements: Zig 0.17, wlroots 0.20, and the development files for Wayland,
wayland-protocols, xkbcommon, pixman, FreeType, HarfBuzz, Fontconfig,
librsvg/GdkPixbuf, PangoCairo, libinput, PAM, libpulse, libpipewire-0.3, Poppler GLib,
libarchive, libjpeg, libpng, libwebp and GNU Readline.

```sh
zig build run -- foot                     # nested in your current Wayland session
zig build -Doptimize=ReleaseSafe          # for daily use and measurements
sh scripts/install-session.sh             # install and restart the running session
sh scripts/install-session.sh --no-restart --dm   # install only, plus rediwm-dm
```
 
For custom prefixes and distribution packages, see
[Installation layouts and packaging](docs/installation.md).

## Using it

| Keys | Action |
| --- | --- |
| Super+Space | centered app launcher |
| Super+T / E / B | terminal / Files / browser |
| Super+Q, Super+F, Super+M | close, fullscreen, maximize |
| Super+arrows | slide to the neighbouring desktop |
| Super+Ctrl+arrows | focus the window in that direction |
| Alt+Tab | window switcher |
| Super+1…5, Super+=/-/0 | window zoom |
| Super+Shift+=/-/0 | desktop zoom |
| Super+L | lock |
| Ctrl+Shift+S, Print | region / full-screen screenshot |
| Super+Z | undo the last window move or resize |
| Super+Shift+E | quit |

Canvas bindings live in `[keybinds]`; `"noop"` disables one.
 
## Configuration

`$XDG_CONFIG_HOME/rediwm/config.toml` (`REDIWM_CONFIG` overrides) is written with
commented defaults on first run and reloads on save; a parse error keeps the
previous config. 
Sections: 
`[theme]`
`[input]`
`[input_method]`
`[compositor]`
`[region]`
`[idle]`
`[night_light]`
`[notifications]`
`[desktop]`
`[polkit]`
`[ipc]`
and more


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

Bundled third-party assets keep their own licenses: the fonts under
`assets/fonts` (SIL OFL 1.1) and the cursors under `assets/cursors` (CC BY-SA 4.0).
