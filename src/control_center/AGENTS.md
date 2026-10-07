# Settings (`ControlCenter`)

Settings is an ordinary window with a compositor-drawn body (`Backend.shell`).

* The body paints into `scene_tree` at `render_scale` and presents with
  `presentOwned`.
* No wl_surface, so focus is "first in `world.toplevels`, activated, no seat
  focus, desktop unfocused" (`hasKeyboardFocus`). `World.focusSurface`
  deactivates a previous `.shell` window and calls `Desktop.yieldKeyboard`;
  `findFocusedToplevel` returns it.
* Compositor bindings run before it gets keys. Pointer coordinates come from
  `localPoint`.
* `close()` frees the content and `Toplevel.destroy`s the window (which may
  animate from a snapshot): clear `backend.shell.control_center` and the
  node's scene data first, and never close from inside a widget callback.
* Saving a theme slider rebuilds the page on release: `panel.rebuildTree`
  carries named sliders' state across (`src/ui/AGENTS.md`, "Sliders").
