# Source map

Where things live, to find code without reading whole directories. Rules are
in the root [AGENTS.md](../../AGENTS.md) and the `AGENTS.md` beside the code;
tests are in [TESTING.md](../../TESTING.md).

## Finding a function

A type split across files keeps its fields, `init`/`deinit` and one alias
line per method (`pub const paint = dock_paint.paint;`). When `self.paint()`
leads to such a line, the body is in the file that alias names, imported a few
lines above it. Group files are `host_*.zig` beside the host (`files/app_*.zig`)
or a lowercase directory named after a TitleCase host (`Dock.zig` → `dock/`).
`rg 'fn name\('` finds any body directly.

## Programs

| Binary | Root | Code |
|---|---|---|
| `rediwm` | `src/main.zig` | the compositor; everything below unless listed |
| `rediwm-msg` | `src/msg/main.zig` | `msg_parse` (arguments), `msg_request` (request line), `msg_reply` (output) |
| `rediwm-files` | `src/files_main.zig` | `files/`: `App` in `app.zig` + `app_*.zig`, its window in `Client.zig` + `client_*.zig`; `files/terminal/` (PTY drawer, `rediwm-files-terminal`, `files-bash.so`), `files/torrent/helper.cpp` + `helper_*.cpp` (`rediwm-transfers`) |
| `rediwm-images` | `src/images_main.zig` | `images/` (`app.zig` + `app_*.zig`) |
| `rediwm-editor` | `src/editor_main.zig` | `editor/` (`app.zig` + `app_*.zig`, window in `main.zig` + `client_*.zig`) |
| `rediwm-pdf` | `src/pdf_main.zig` | `pdf/` (sandboxed; window in `main.zig` + `client_*.zig`) |
| `rediwm-monitor` | `src/system_monitor_main.zig` | `system_monitor/` |
| `rediwm-calculator` | `src/calculator_main.zig` | `calculator/` |
| `rediwm-share-picker` | `src/share_picker_main.zig` | `share_picker/` |
| `rediwm-session` | `src/session_main.zig` | login supervisor (`session/supervisor.zig`, `publication.zig`) |
| `rediwm-dm` | `src/dm/main.zig` | display manager, runs as root (`dm/AGENTS.md`) |
| `rediwm-accounts-helper` | `src/accounts_helper/main.zig` | root account helper (`accounts_helper/AGENTS.md`) |
| `rediwm-theme` | `src/theme_main.zig` | theme archive helper (`theme_helper/`) |

`build.zig` holds the options, the shared modules, the compositor and
`rediwm-msg`; `build/` the rest: `apps.zig` (the programs above), `data.zig`
(installed data), `session.zig`, `tests.zig` (every `test*` step),
`protocols.zig` (generated Wayland bindings), `support.zig` (helpers) and
`context.zig` (what they share).

## Shared modules

No compositor imports (`build.zig` enforces the direction): `ui` (`src/ui/`:
widgets, layout, text, theme, animation), `config` (`src/config/`: parsing and
saving `config.toml`), `dbus`, `i18n`, `memory` and `protocol`
(`src/ipc/protocol.zig`, the IPC wire format shared with `rediwm-msg`). Also
`platform` (`src/platform/`, std only): child-process handles, directory
watching and the program's own path, the seam for other operating systems.

## Compositor

| Host | Methods | What |
|---|---|---|
| `Server.zig` | `server/` | startup and teardown, outputs, frames, wakeups, wallpaper |
| `World.zig` | `world/` | window list, focus, the camera, zoom, pan and pinch |
| `Toplevel.zig` | `toplevel/` | a window; `xdg.zig`, `xwayland_surface.zig` adapt the protocols |
| `Output.zig` | `output/` | one monitor: frames, layout, modes, panels, wallpaper |
| `Input.zig` | `input/` | seat, pointer, gestures, drags (`input/AGENTS.md`) |
| `Keyboard.zig` | `keyboard/` | `process.zig`: the key pipeline (lock, switcher, panels, bindings, clients); `shell.zig`: keys for compositor panels |
| `Taskbar.zig` | `taskbar/` | the taskbar; value types in `taskbar/types.zig` |
| `Dock.zig` | `dock/` | the dock ([dock notes](dock.md)) |

Also in `src/`: `Shell.zig` (xdg-shell and decorations), `Popup.zig`,
`LayerSurface.zig`, `Xwayland.zig` (+ `xwayland_*.zig`), `Switcher.zig`
(Alt+Tab), `workspaces.zig`, `snap.zig`, `auto_tiling.zig`, `window_tabs.zig`.

**Rendering** (read [rendering details](rendering.md) first): own scene nodes
`node.zig`/`node.c`, client surfaces `node_surface.c` (+ `node_subsurface_tree.c`,
`node_xdg_shell.c`); `projection.zig`/`.c` (geometry and damage; parts
`projection_props`, `_resolve`, `_present`, `_pass`, `_pick.c`);
`scene_output.zig`/`.c` (+ `_collect`, `_effects`, `_draw.c`), `scene_pass.c`
(+ `_draw`, `_backdrop.c`), `scene_damage.c`, `scene_outputs.zig`/`.c` (the
output pass); `glass.zig`/`.c`; `chrome.zig`
(+ `chrome_paint.zig`, `chrome_tabs.zig`) for window frames; `panel_buffer`,
`panel_paint` and `panel_present.zig` for compositor-drawn panels;
`camera.zig`, `geometry.zig`, `color.zig`.

## Compositor-drawn UI

* **Start menu** (`start_menu/`): `panel.zig` re-exports `StartMenu`
  (`StartMenu.zig` + `menu_*.zig`); the app catalog is `applications.zig`
  with `desktop_file.zig` and `scan.zig`; `launch.zig`, `search.zig`.
* **Settings** (`control_center/`, `AGENTS.md` there): the window is
  `ControlCenter.zig` (+ `tree`, `keys`, `relayout`, `paint.zig`); `panel.zig`
  has shared helpers; one `sections/*.zig` per page, the big ones split into
  `appearance_*.zig` and `printers_*.zig`.
* **Session** (`session/`, `AGENTS.md` there): `lock.zig` (+ `lock_account`,
  `lock_events`, `lock_input`, `lock_view.zig`), `greeter.zig`, `idle.zig`,
  `power.zig` (+ `power_*.zig`, logind), portals (`settings_portal.zig`,
  `file_chooser.zig`), services.
* The desktop icons (`desktop/`), `power_menu.zig`, `osd.zig`,
  `calendar.zig`, `battery_popup.zig`, `network/popup.zig`, `mini_map.zig`,
  `notifications/`, `tray.zig`, `polkit/` (authentication agent).

## Services and system clients

* **IPC** (`ipc/`): `server.zig` (socket and admission), `protocol*.zig`
  (wire format), `handlers.zig` (checks and dispatch) with
  `handlers_state`/`inspect` (queries) and `handlers_input`/`windows`/`frames`
  (actions), `wait.zig` (+ `wait_conditions.zig`, `wait_replies.zig`),
  `commands.zig` (the command table). The IPC is also the test harness.
* **D-Bus** (`dbus/`): `connection.zig` (+ `connection_calls.zig`,
  `connection_io.zig`), `wire.zig`.
* `network/manager.zig` (+ `manager_*.zig`, NetworkManager), `bluetooth.zig`,
  `audio/`, `printing/` (CUPS, `AGENTS.md` there), `systemd.zig`
  (+ `systemd/`), `brightness.zig`, `power_profiles.zig`.
* **Configuration**: `config/` reads and writes it (`loader.zig` +
  `loader_parse`/`fields`/`edit`/`compare.zig`); `config_runtime/` applies it
  to a running compositor.

## Tests

`zig build test` builds one test binary per root: `src/ui_tests.zig` (the
compositor's code), `ipc_tests.zig`, `files_tests.zig`, `editor_tests.zig`,
`images_tests.zig`, `pdf_tests.zig` and the shared modules. Other
`*_tests.zig` files sit beside their code and are reached through
`test { _ = @import(...); }` blocks; C fixtures are `src/*_test.c` (cases in
`*_test_*.c`); integration suites are `tests/*.py`. Splitting tools are in
`tools/split/`.

Power preferences: `config/power.zig` parses source profiles;
`session/power_policy.zig` owns shared battery state and source actions;
`control_center/sections/power.zig` owns Settings controls.
`platform/power_supply.zig` receives uevents, `platform/charge_limit.zig` handles
optional firmware thresholds. Server construction/destruction are in
`server/setup.zig` and `server/teardown.zig`.
