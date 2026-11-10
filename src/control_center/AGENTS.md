# Settings (`ControlCenter`)

Settings is an ordinary window with a compositor-drawn body (`Backend.shell`).
`ControlCenter.zig` holds its state and lifecycle; `tree.zig`, `keys.zig`,
`relayout.zig` and `paint.zig` its methods; `panel.zig` the shared widget
helpers (and `panel.ControlCenter`); `sections/` one file per page.

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
* **The Services client (`systemd.zig`) is live only while its page is on screen**
  (`show` from `services.build`, `hide` from `selectPage`/`detachSettings`) or
  while an IPC query holds a 15 s `lease`. Live means the signal matches,
  `Subscribe` and a load; dark means `Unsubscribe`, matches removed and the data
  dropped. Never `RefUnit` or `LoadUnit`: systemd loads the unit *and its whole
  dependency closure*, then asks polkit on every call (about 49 ms of PID 1 plus
  polkitd each, denied when non-interactive, so nothing is ever pinned), and the
  load/collect churn is broadcast to every subscriber and fed back into the
  refresh. An unloaded unit is only its unit-file state; nothing is asked of it.
  A load is ListUnits (its state fields are the rows), ListUnitFiles, then `Get`
  of Transient, TriggeredBy and Type for each *loaded* unit, once (cached;
  `refresh`/daemon reload re-read). Signals apply the values they carry; anything
  else only sets `dirty`, and one reload runs after `settle_ms`. systemd
  broadcasts thousands of UnitNew/UnitRemoved a second under bulk loads, so no
  signal may cost a call of its own and none may restart a load. The fake in
  `control_center.py` emits no such floods; a pass-through proxy that decodes bus
  messages shows the real traffic without root (`BecomeMonitor` and
  `Debug.Stats` need it).
* Saving a theme slider rebuilds the page on release: `ControlCenter.rebuildTree` (`relayout.zig`)
  carries named sliders' state across (`src/ui/AGENTS.md`, "Sliders").
* A rebuild of Appearance costs milliseconds (preset, wallpaper and icon-theme
  scans) plus a full repaint: background wakes refresh only pages that show
  their state (audio: General and Audio), and wallpaper thumbnails go straight
  into their tile (`stripWake`). The nav highlights damage the rows they cross,
  not the list.
* **Printers owns its worker only while the page is selected.** `printers.build`
  starts it lazily; `selectPage` and destruction call `hide`. Socket requests
  have an absolute deadline and are interrupted through the worker eventfd
  before joining. USB uevents coalesce into a rescan; no idle timer queries
  CUPS. State snapshots cross under a mutex; widget strings must be copied
  into the section arena before the next snapshot replaces them. An older
  automatic refresh must not clear a newer user action's busy state.
  Only own jobs are cancellable, rechecked outside the callback; CUPS remains
  the authority. Reports omit identities and arbitrary status messages.
  USB libusb queues do not require a usblp node. Read `docs/plans/printers.md`
  for the unqualified hardware and distribution-policy acceptance gates.
  Discovered backend URIs must match the current administration catalog exactly;
  arbitrary typed vendor/file backends are not allowed. PPD settings use
  `PrinterAddOption` or direct PPD editing after clearing stale IPP defaults,
  followed by readback. Direct CUPS authentication uses the shared secret widget
  over locked storage, clears it on submit/cancel/hide, and never stores passwords
  in the section arena. Hiding also cancels any native authentication wait.

* **The Appearance flame-effect toggles are independent** though `window_minimize`
  and `window_resize` follow `window_move` in the file. `Config.setEnabled` pins
  a following binding to what it showed before the change and `setting_save.saveEffect`
  writes it (with its `preset`) so a reload reads back what was running; the handler
  then calls `window_move.configure` (a reload's diff cannot, the live config
  already changed). Off by default: nothing is written until a toggle is touched.

* Global search uses `search_index.zig` destinations (widget names or `@` plus
  visible label text), without building hidden sections. Add an index entry
  with new settings. Typing navigates to the highest-ranked match; the sidebar
  contains only matching pages, and selecting one reveals its best match while
  keeping the query. Clearing search keeps the current page and scroll position.
  Use `showingPage`, rather than `page`, in background callbacks: an empty
  search covers the selected page. The search field owns its text across rebuilds;
  navigation is deferred until widget dispatch has finished.

* `sections/users_helper.zig` owns the account helper request and authorization
  lifetime; `users.zig` owns the account UI.

* **Keys & Certificates** (`sections/keys*.zig`) owns a `keys/client.zig` only
  while selected. The unprivileged sibling `rediwm-keys` reads key files; the
  compositor receives metadata and public keys only. The client's single
  in-flight request has an absolute deadline and owns a child process group;
  hide/close/lock cancels it, and idle has no worker or timer. Copy snapshots
  into the section arena before retaining widget strings. Secret fields use
  locked storage and requests are encoded with the secure allocator, wiped on
  submit, cancellation, page changes and lock. Never put a passphrase in tool
  argv, environment, a section arena or logs. See `docs/plans/keys-certificates.md`
  for the currently supported SSH formats and the later agent/certificate phases.

## Network page

* **The page is `sections/network*.zig`:** `network.zig` (section state, the
  overview, Ethernet and Wi-Fi cards, airplane mode), `network_details.zig`
  (the address rows), `network_editor.zig` (the connection settings editor),
  `network_vpn.zig`, `network_proxy.zig`, `network_fields.zig` (text fields that
  keep their text across a rebuild: capture before the arena resets, never read
  a captured widget afterwards), `network_ui.zig` (small builders).
* **Writes go through `network/manager_profile.zig`:** read the settings with
  `GetSettings`, replace only the keys the editor owns, `Update` with the
  interactive flag. An `Update` without a secret keeps the stored one (verified),
  so never add secret handling. The Unlock gate is `manager_access.zig`; proxy
  is per user and ungated.
* **`i18n.tr` text is not a `std.fmt` format**: use `i18n.fmt` with named
  placeholders. `panel.translatedLabels` runs at call time, never in a
  file-level `const`.
* **Tests never touch the host:** `tests/nm_fake.py` is a fake NetworkManager
  and polkit on the session bus; the proxy test sets `GSETTINGS_BACKEND=keyfile`
  with a scratch `XDG_CONFIG_HOME`; nothing may write `/dev/rfkill`.
