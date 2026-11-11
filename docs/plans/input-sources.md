# Input sources plan

A taskbar indicator for the active keyboard layout or input method (`EN`,
`DE`, `JA`, `あ`), click to switch, and Settings → Input → **Input Sources** to
add, remove and reorder layouts. Works with plain XKB and with Fcitx5. Drafted
and decided 2026-11-11; built the same day (see Status).

## Decisions

* **D1, labels are language codes:** xkbregistry's `brief`, uppercased (`EN DE
  JA RU`); a region is dropped (`zh_CN` → ZH); repeats get subscripts (EN₁,
  EN₂). `xkb_labels` overrides by position. Fcitx methods use Fcitx's own label
  (Mozc `あ`), else their language code.
* **D2, clicking opens a list** (the taskbar window menu in its sources mode);
  scrolling over the item steps through the sources.
* **D3, Fcitx5 is read and switched, never written.** Its methods come from its
  current group; `fcitx5-configtool` stays their editor.
* **D4, at most four layouts** (XKB/X11/Xwayland). Settings stops at four; a
  hand-written list is cut to four with a warning in the log.
* **D5, shortcut:** `input_source_next`/`input_source_prev`, default
  `super+shift+space` (added to existing configs like the other always-kept
  bindings), plus XKB's own `grp:` switch keys as a Settings choice.
* **D6, the active source is global;** per-window memory is left for later.
* **D7, storage stays in the existing lists** (`xkb_layout`, `xkb_variant`) plus
  an optional parallel `xkb_labels`, written in one save. With Fcitx entries
  out of the config (D3), a separate `[[input_source]]` table would have bought
  nothing over them and needed a migration.

## How it works

* `input_sources.zig` (`Manager` on `Server`): the layouts from the config,
  then Fcitx's methods; `activeIndex`, `select`, `cycle`, `cycleLayouts` (lock).
  `announce` tells the taskbars, the open menu, the lock, IPC and Settings once
  per real change.
* **Active layout:** one group for every keyboard with the config keymap.
  Switching sets it on all of them (the keyboard in use last); a keyboard that
  switches itself moves it and the rest follow from an idle callback. A reload
  or reorder keeps the active layout by identity.
* **Labels and names:** `input_sources/registry.zig` reads evdev.xml through a
  dlopen'd libxkbregistry (about 11 ms) on a worker, only once there are two
  layouts or Settings asks; without the library labels fall back to the layout
  code and Settings to a short built-in list.
* **Fcitx5** (`input_sources/fcitx.zig`): `org.fcitx.Fcitx5` `/controller`
  `org.fcitx.Fcitx.Controller1`: `CurrentInputMethodGroup`,
  `InputMethodGroupInfo`, `AvailableInputMethods`, `CurrentInputMethod`,
  `SetCurrentIM`, `Deactivate`, signal `InputMethodGroupsChanged`.
  Controller1 has no signal for the current method, so any signal from Fcitx's
  unique name (its tray item updates on every change) re-asks
  `CurrentInputMethod`, one call at a time. NameOwnerChanged follows Fcitx
  starting and leaving. Choosing a layout calls `Deactivate`; choosing a method
  `SetCurrentIM`. Started after the first frame, never in the greeter.
* **Taskbar:** `taskbar_items.Item.input_source` (tray kind `input_source`),
  automatic by default via `Presence.input_sources`; older lists gain it before
  Volume.
* **Lock:** a layout button bottom left (never in the greeter) and the shortcut
  cycle layouts only; the label is copied into `Lock` so painting needs no
  server.
* **Settings:** an Input Sources card before the keyboard repeat rows: layout
  rows with Move up/down and Remove (no drag), an inline search over the
  registry to add, Fcitx's methods read-only with "Configure in Fcitx…", "Also
  switch with" (`grp:` options) and "Show in taskbar".
* **IPC:** `get_input_sources`, `switch_input_source`, event
  `InputSourceChanged`; `rediwm-msg input-sources`, `switch-input-source`.

## Status

Built 2026-11-11, uncommitted. Not yet checked against a real Fcitx5 (none is
installed on the development machine): the Controller1 names above are from
Fcitx5's D-Bus module, and two things need a run with Fcitx5 + Mozc in a nested
session: that Fcitx's tray item (or some other object) really signals on each
method change, and that under input-method-v2 Fcitx forwards keys with the
compositor's current group rather than its own `keyboard-*` layout. Also open:
translations of the new strings, IBus, more than four layouts (keymap swap),
per-window memory, the greeter, and the FreeBSD cross-build check.

## Tests

* Unit: `config/input_sources.zig` (split, join, cap, validation),
  `taskbar_items.zig` (migration, automatic item), `input_sources/labels.zig`,
  `registry.zig` (skipped without the library), `fcitx.zig` (group parsing),
  `sections/input_sources.zig` (`grp:` editing, search), `lock_tests.zig`
  (layout button), IPC parsing and serializer fixtures.
* `python3 tests/input_sources.py` (wraps itself in `dbus-run-session`): labels,
  the automatic item, the menu, Super+Shift+Space, IPC, scrolling, the CLI; a
  fake Fcitx (list, switch, external change, group change, leaving, no
  config writes); Settings add/reorder/remove/visibility.
* Also run: `layout_ipc.py`, `msg.py`, `taskbar_sections.py`, `hotspots.py`,
  `input_protocols.py`, `control_center.py`, `greeter.py`, `zig build test-lock`.
