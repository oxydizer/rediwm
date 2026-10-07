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
* A `.desktop` file runs only if `Worker.trustedLauncher` (`watcher.zig`)
  accepts it (installed or linked into the menus, root-owned, executable, or
  an exact copy of the installed entry); otherwise it is an `untrusted` plain
  file whose own Name/Icon are never shown. Allow Launching is `chmod u+x`.
* Launches go through `app_scope.place` like every other user app: the worker
  hands pids over with `Worker.takeStarted`.
