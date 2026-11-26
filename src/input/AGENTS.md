# Input

* **Per-device pointer settings:** `Pointer` owns its stable identity and a
  monotonic live token. Settings resolves the token on every callback; no UI
  state may retain a device pointer. `persistentId` rejects missing/ambiguous
  identities. Hotplug and reload both call `applyPointerDevice`, resolving
  `[[input_device]]` overrides over `[input]` defaults. Do not reapply bare
  global pointer values later. Identity collisions reset those peers to
  defaults and stay ambiguous for their remaining connection lifetimes.
  `tests/input_persistence.py` uses a noninstalled backend fixture; physical
  touchpad/mouse scroll feel and libinput DWT pairing still need manual checks.

* **Text input/IME** (`text_input.zig`, `text_input_v1.zig`): `syncFocus` is the only enter path.
  A v1 field names its seat and surface in `activate`. Its setters work
  without `commit_state`; when supplied, its serial belongs on v1 edits.
  The v2 method's done serial independently rejects stale replies.
  IM grabs replace client delivery only (bindings, hardware keys and
  shell/lock UI win); an IM's own virtual keyboard bypasses its grab.
  While an overlay owns new input, modifier updates and the release of keys
  the grab already received still reach it, and the IM's virtual keyboard
  never counts as a physical modifier source (it only echoes forwarded
  state). Lock/auth reject virtual input. IPC `GetTextInput` never returns
  text. Candidate popups follow the client's committed cursor rectangle:
  wlroots' `active_features` only snapshots the enabling commit, so a
  rectangle sent later (Chromium's order) needs `cursor_rectangle_seen`.
* **Layouts:** layout-zero fallback is for binding lookup only; text uses the
  active XKB state.
* **Input sources** (`input_sources.zig`, `input_sources/`): the config's
  layouts (XKB groups, at most four) plus Fcitx5's methods, read and switched
  over D-Bus, never written. The active group is global: switching sets it on
  every keyboard with the config keymap; a keyboard that switches itself (a
  `grp:` toggle, `layouts.observe`) moves it and the others follow from an
  idle callback, never inside their own modifiers signal. Fcitx has no
  current-method signal: any signal from its unique name re-asks
  `CurrentInputMethod`. The lock types with layouts only (`cycleLayouts`).
  `tests/input_sources.py` uses a fake Fcitx on a private session bus.
* **Shell key repeat:** one `shell_repeat` per keyboard; a new shell target
  needs a `ShellTarget` case, a freeable panel calls `forgetShellTarget`.
  Return, Escape, Tab and modifier chords never repeat.
* **Pointer constraints** (`pointer_constraints.zig`): every client motion
  path calls `clientMotion` then `sync`. Active only with pointer and keyboard
  focus; new compositor input modes go in `motionReachesClient` or
  `candidate`. `sendDeactivated` destroys oneshots synchronously: clear
  `active` first.
* **Pointer warp** (`pointer_warp.zig`, wp_pointer_warp_v1; Wine's
  SetCursorPos): honoured only while the target's surface tree has pointer
  focus and `motionReachesClient`, with a seat serial for that client, inside
  the surface; never through a lock, only within a confinement. It skips
  `clientMotion` on purpose (a warp is no relative delta) but runs
  `processCursorMotion`, the frame and `sync` like `warpCursor`.
* **The switcher owns the pointer** while it is up: opening it clears pointer
  focus and shows the arrow (a client's hidden or text cursor would otherwise
  stay, since no motion reaches it), unless a press or grab is in progress.
  User-driven ends go through `Switcher.close`, which refreshes pointer
  focus without changing keyboard focus. Forced teardowns call `cancel` alone.
* **Shortcuts inhibit** gates only the switcher, screenshot shortcuts and
  final dispatch; hardware keys, VT switching, System Monitor and open panels
  still win. System Monitor dismisses transient input owners and revokes the
  focused client's inhibitor; lock/auth and shortcut capture keep priority.
* **Drag dodge** (`drag_dodge.zig`) slides a file manager aside through
  `Toplevel.setDodge`, a presentation-only offset added in
  `applyVisualTransform`. Never fold it into `x`/`y`/`move_x` (it would grow
  the canvas, reach IPC and saved layouts, and outlive the drag). Anything
  that stops showing a window must `clearDodge` it (`detachInput` does).
* **Strip gestures** (`scroll_motion.zig`): on a scrolling workspace a
  three-finger swipe (whatever is under the pointer, unless shortcuts are
  inhibited) and two fingers over empty strip move its view; the world's frame
  tick places the windows. While fingers are down a reveal leaves the view
  alone, so every path that ends a gesture must reach `scroll_motion.end`; a
  finger scroll that goes quiet for 400 ms ends itself, since its stop event
  can be routed elsewhere. Super+Shift+wheel and Super+horizontal wheel step
  columns; plain Super+wheel still cycles workspaces.
* **Touch/tablet** use their own protocol only when
  `directInputReachesClients()`; otherwise they emulate the pointer (send your
  own `pointerNotifyFrame`). Touchscreens map to `output_name` or the built-in
  panel.
* **Wheel debounce** (`wheel_debounce.zig`) runs in `cursorAxis`, before
  `processAxis`, on detented `.wheel` events only. IPC `scroll` and
  automation sequences (`virtual.zig`) enter `processAxis` as `.continuous`
  and never reach it, so cover it with unit tests.
* **Lid:** native power policy takes logind’s lid inhibitor and owns lid actions.
  Docked panels leave the layout; undocked panels blank without removing the
  last output. Never also request undocked sleep without the inhibitor.
