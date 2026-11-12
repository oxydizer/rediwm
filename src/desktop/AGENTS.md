# Desktop icons (`[desktop] enabled`)

Desktop keyboard focus and compositor drop targets are in the root
`AGENTS.md` ("Windows and focus", "Input").

* `App` (`app.zig`) and its worker (`watcher.zig`) never depend on the
  compositor; the worker is a thread that never calls the host. Tests set
  `REDIWM_DESKTOP_DIR`.
* One retained canvas published as 240-logical-px tiles (`embedded.zig`); only
  damaged tiles get new buffers. Rasterize the selection band once per paint;
  repair clips snap outward to device pixels. Labels/icons are rasterized at
  exact scale.
  Selection colours come from `Theme.desktopSelectionColor`,
  `desktopSelectionBorder` and `desktopSelectedColor`: explicit desktop tokens
  win, otherwise they follow the shell accent, including on live reload.
  Call `Desktop.themeChanged` so cache invalidation also schedules its paint;
  an unrelated output frame alone does not pass the desktop's pending gate.
* **The grid fills the output.** Columns count from the right (saved cells
  keep their meaning) and share the whole width: cells are at least 96px and
  stretch by a few pixels so the first and last column sit the same distance
  from the edges whatever the output width (`grid.zig`). Drawing keeps the
  icon and label at their designed size, centred in the cell (`ox` in
  `iconPattern`), so nothing outside `grid.zig` may assume a 96px cell or
  derive x from a column. The column count is deliberately unchanged
  (`reserve`): changing it moves every saved position.
* A `.desktop` file runs only if `Worker.trustedLauncher` (`watcher.zig`)
  accepts it (installed or linked into the menus, root-owned, executable, or
  an exact copy of the installed entry); otherwise it is an `untrusted` plain
  file whose own Name/Icon are never shown. Allow Launching is `chmod u+x`.
* Launches go through `app_scope.place` like every other user app: the worker
  hands pids over with `Worker.takeStarted`.
* The Trash icon's Properties is Files' window, not a desktop popup:
  `files/trash_properties.zig`, held in `App.trash_card` (`edit ==
  .trash_properties`) and routed like the delete dialog (paint, `promptRect`,
  pointer, keys; `closeTrashCard` on every way out). Its count runs on its own
  thread (`files/trash_totals.zig`) and writes the worker's `wake_main`; `tick`
  polls it. Other Properties still use the small popup. Open reuses
  `openSelected`, so the Trash icon must stay selected under the window.
