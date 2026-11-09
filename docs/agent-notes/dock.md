# Dock implementation notes

Read when changing `src/Dock.zig` (its methods are in `src/dock/`: reveal,
items, paint, pointer, pins), `src/dock_drag.zig`, or their output,
taskbar, OSD and input integration. General rules remain in
[AGENTS.md](../../AGENTS.md); integration coverage is in `tests/dock.py`.

* **The dock repaints cells, not itself** (`dock/paint.zig`). It keeps its last
  raster and, when only some items' looks changed (hover zoom, pills), clears
  and repaints just their `itemCell`s (each item at the largest hover zoom, across
  the dock's thickness) under a clip, publishing that damage alone. Dock-wide
  state (theme, scale, count, drop slot, hover zoom, active-app highlight, the
  background `Dock.background` makes of `dock_opacity`) is `base_key` and
  repaints all. Draw nothing outside an item's cell without keying it in
  `base_key`, or it goes stale. `tests/dock.py` compares an animated dock with a
  whole repaint. The icon tooltip waits `tooltip_delay_ms` on its own one-shot
  timer, re-armed only when the hovered icon changes. Icons use `drawImageSmooth` (area average): `drawImageCover`
  samples the nearest pixel and shows stair-steps at the dock's fractional
  downscale.

* Apps with multiple dock-eligible windows show a circular count in the icon's
  upper-right corner (including minimized windows, capped at `99+`). The count
  is part of the item key and stays inside the icon's bounds during hover zoom.
  Clicking opens the compact window picker in `taskbar/window_menu.zig`, sharing
  the context menu's input routing, inward placement and auto-hide hold. It owns
  window IDs and title copies; detaching any listed window dismisses it through
  `Menu.references`. Each row has a shared chrome close button; close dismisses
  the picker before requesting the window close, without activating the window.
  Keyboard and wheel navigation reach rows beyond the output.
  A shortcut opens it during its press: the menu input path must still balance
  that press's `active_buttons` on release (pins open after their release).

* Hover zoom keeps the screen-edge side fixed and grows toward the desktop.
  Its spring (`dock_hover`) is underdamped: `zoomRange` gives the overshoot
  headroom that rasters, icon size and cells are sized for, so never clamp a
  look to `dock_hover_zoom` itself.
  `rasterBox` pads the painted buffer for overflow; `glass_anchor` keeps the
  background's extent. Input uses tree-local coordinates and `input_root`
  covers the expanded icons. Item cells span the expanded raster's thickness.

* **The dock reserves space only when it doesn't auto-hide.** `Output.usableBox`
  is `dockAreaBox` (output less the taskbar) less `Dock.reservedStrip`, a pure
  function of config and that box (`Dock.fits`), so it never flips with a lock
  or fullscreen window. The dock and the taskbar's popups/menus are placed in
  `dockAreaBox`, never `usableBox`. A setting that changes the strip calls
  `applyTaskbarPosition` (`Dock.reserves` before/after). The OSD keeps clear
  of `Dock.footprint` (the resting dock, auto-hiding or not) on the bottom
  edge. Auto-hide fades and slides the node (`reveal`, opacity + position, no
  repaint; the glass opacity follows it too) and parks it (no rebuilds, no
  frames) once away; reveal/hide wait on one `wl` timer
  (`Dock.pointerAt` from `Input.processCursorMotion`, `retime`).

* **Compositor-internal drags** (`dock_drag.zig`: start menu app -> dock pin,
  and a pinned dock icon -> another place among the pins) are not wl_data_device
  ones: a press arms, motion past a threshold starts, and starting rebuilds the
  menu so its release is no click. A pinned icon acts on release (`Dock.clickPin`)
  so a drag can start from it. Closing the menu or Escape (`cancelDrag`; for a
  dock icon `keyboard/process.zig` takes it ahead of every shell panel, for a menu app
  before the menu's own Escape) abandons it. A dock
  holds resolved pins as copies (`pin_arena`); `config_index` maps a slot back
  into `dock_pinned_apps`, which also lists apps no longer installed.

* **Files dropped on the dock's Trash item** (`trash_drop.zig`, field
  `Input.trash_drop`) are trashed with no question, as the desktop Trash icon
  does. It is a `desktop_drop.Target` too, so only a text/uri-list source that
  allows *move* can drop (a copy-only drag is refused: nothing the user meant
  to copy is deleted). `Dock.trashAt` picks the item; the motion `.dock` branch
  must use the grab-aware `pointerNotifyClearFocus` while `seat.drag` is set,
  or the drag stays focused on the last client and a release drops there. The
  URI list is read on the event loop (nonblocking fd, 5 s deadline timer, 256 KiB
  cap), then `gio trash -- <paths>` runs and the drag is finished (`dnd_finish`)
  when it exits; a failure cancels the drag and posts a notification. An
  auto-hiding dock reveals for a file drag (`draggingFiles` in `input/motion.zig`).
  Covered by `tests/dock_trash_drop.py`.

* **Themed tiles** (`dock_item_bg`, `_border`, `_hover_border`, `_bevel`) replace
  the ghost hover button with a resting tile per item, outlined while hovered,
  pressed or the highlighted active app; `dock_bevel` cuts the dock's own
  corners (the glass rounds deep enough to stay inside the cut). `dock_icon_grey`
  draws icons from a desaturated copy except while lit. All of it is theme
  state (`base_key`); lit-ness comes from the button state already in each
  item's key.
