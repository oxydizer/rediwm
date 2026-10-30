# Files

Text, colour and theme rules shared with Images and PDF are in the root
`AGENTS.md` ("Shared UI"). Every test that launches Files sets
`REDIWM_FILES_DEVICES=0` and scratch `XDG_STATE_HOME`/`XDG_DATA_HOME`
(`TESTING.md`, "Common knobs").

## Where `App` lives

`app.zig` holds the `App` fields, `init`/`deinit` and one `pub const name =
app_x.name;` alias per method, so `self.name()` works everywhere. The bodies
are free functions taking `self: *App` in `app_*.zig`, grouped by concern:
`app_hover`, `app_listing` (navigation, sync, sorting), `app_dialogs`,
`app_fileops`, `app_chooser`, `app_layout` (geometry), `app_folder_size`,
`app_places` (sidebar rows, pins, devices), `app_sidebar_paint`,
`app_git_sidebar`, `app_scroll`, `app_opening`, `app_pointer`,
`app_keyboard`, `app_menu`, `app_paint`, `app_items`. Shared enums and
records are in `app_model.zig`, drawing helpers in `app_draw.zig`, tests in
`app_tests.zig` (with `app_*_tests.zig` by area). A new method goes in its
group file plus an alias line in `App`; a file that calls a sibling's
non-method helper imports it directly.

The window is `Client.zig` (Wayland globals, seat, buffers), re-exported by
`main.zig`, with its handlers in `client_window`, `client_input`,
`client_dnd`, `client_clipboard` and `client_render.zig`.

## Terminal drawer

`app_terminal.zig` owns the per-window controller; `terminal/` owns libvterm,
the PTY, shell integration, cells and text-input-v3. Support and limits are in
`docs/files-terminal.md`; `zig build test-files-terminal` runs isolated PTY
and headless fixtures. The pinned library is compiled only into Files/tests.

* Poll slots 19–21 are PTY, integration socket and pidfd. Parsing/writes have a
  64 KiB budget per loop; POLLOUT is enabled only with queued work. Hidden
  sessions drain without terminal damage or blink timers.
* Following is a Bash Readline editing safepoint, never text sent through the
  PTY. Keep its inherited socket private/CLOEXEC, check kernel credentials,
  bound packets and coalesce requests/status under backpressure. A prompt,
  title, foreground PID or quiet output alone never authorizes a directory
  change. Unsupported and nested shells keep pending following suspended.
* Spawn the fresh helper with `posix_spawn`, so PTY setup and scope placement
  never run in a forked multithreaded Files child. Close asks only when
  `ft_active` finds a foreground job or another session member (an idle shell
  is just hung up); bound asynchronous cleanup and retain the session leader until
  session members have been signaled through pidfds and it can be reaped.
* Cell metrics use the exact shared mono advance. Paint non-ASCII/wide cells
  separately so fallback shaping cannot move later cells. Preserve the
  caller's Cairo damage clip. The test encoder drain exists only with FT_TEST.

## File types and associations

* **Types come from `src/mime_db.zig`, not GIO.** It reads shared-mime-info
  (`globs2`, `aliases`, `subclasses`, `icons`, `generic-icons`, the per-type XML
  comments) from `$XDG_DATA_HOME` and `$XDG_DATA_DIRS`, by file name only.
  Files, Properties, the chooser filters, Recent and the Editor share it. It
  was checked against `g_content_type_*` over every glob of the installed
  database: literal names beat suffix globs, which beat wildcard patterns
  regardless of weight, and a `cs` glob repeated without the flag stays
  case sensitive. Re-run that comparison before changing the matching order.
  Returned strings live for the process (a changed `globs2` is picked up at
  most every 5 s by swapping in a new copy; the old one is retired, not freed).
* **Applications and defaults stay on GIO** (`associations.zig`: default app,
  Open With, `mimeapps.list`, launching), so `xdg-open`, browsers and portals
  agree with Files. Only the content type is ours; GIO calls take it as a
  C string through `TypeZ`.

* **AppImages:** `appimage.zig` reads type-2 metadata through bounded,
  timed `unsquashfs` calls on the directory worker; never run AppRun or the
  AppImage to inspect it. Publish only the rewritten launcher and icon in
  XDG data, preserving existing MIME defaults. Registration keeps the image
  in place, uses its canonical absolute path and drops bundled TryExec,
  working-directory, desktop-action and D-Bus activation references.

## Git

`git.zig` never runs a repository's own programs: a folder's `.git` arrives
with archives and USB sticks. Every command uses `safe_options` and `cleanEnv`
(no fsmonitor, hooks, pager, transports or lazy fetches); `trustedRepository`
refuses repositories whose own (local, worktree or included) configuration
names filter or Git LFS commands, and `status` ignores submodules (their
configuration is not checked).

## Thumbnails

* **Decoding avoids GdkPixbuf for JPEG and PNG.** Current gdk-pixbuf routes
  them through sandboxed glycin loader processes and ignores scaled decode (a
  12 MP JPEG costs ~150 ms). `thumb_codec.c` decodes JPEG at 1/2–1/8 inside
  libjpeg's DCT and streams PNG rows into an area-averaging downscaler, so no
  full raster exists. Whatever it reports unsupported (WebP, GIF, SVG,
  interlaced PNG, CMYK JPEG) falls back to `images/decode.zig` (`loadWith`
  with a box), which the viewer's `loader.zig` also re-exports. Re-measure
  before "simplifying" this.
* **`thumbs.zig` alone owns the raster cache**: 2 nice'd workers, the queue
  replaced on every `request` (scrolling cancels queued work), results handed
  over under the mutex and an eventfd, LRU by bytes and entry count. Workers
  never touch Cairo or Wayland. Keys are path plus the mtime and size the
  *listing* reported; a stale file is dropped without an entry and retried
  after the next rescan. Failures are remembered per file state. No timers:
  idle stays at zero wakeups.
* **App side:** `stepThumbs` re-requests only when the visible rows or
  `view_revision` change; `drainThumbs` damages just the arrived icons through
  `addDamage`. `itemIconRect` is the single source of icon geometry for
  painting and damage. Thumbnails are drawn in `drawItemIcon` (grid 54, list
  24, drag icon 32) from a bilinear-filtered 128 px raster.
* **Shared freedesktop cache** (`$XDG_CACHE_HOME/thumbnails/normal|large`):
  the name is the MD5 of the GLib-escaped `file://` URI, validated by
  `Thumb::MTime` (and `Thumb::Size` when present) against the *target's* stat.
  Entries are written after the UI has its pixels, via tmp file + rename, mode
  0600, only when the original is bigger than 128 px. Tests set a scratch
  `XDG_CACHE_HOME`. `REDIWM_FILES_THUMBNAILS=0` turns thumbnails off.

## Devices

* **Transport vs policy.** `volumes.c` is a GLib thread holding a GDBus
  object-manager client for UDisks2 on the system bus (not `src/dbus`, which
  is tied to the compositor's `wl.EventLoop`). It only publishes raw records
  and runs Mount/Unmount with interactive polkit authorization. What to list,
  the label and the stick/drive icon are `volumes.zig`'s `shown`/`kindOf`.
  `HintIgnore` hides EFI partitions; `HintSystem` volumes mounted outside
  `/run/media`, `/media` and `/mnt` (`/`, `/home`, `/boot`) are hidden by the
  mount rule, because UDisks2 does not ignore them. Loop devices are
  `HintSystem` too, so only that rule decides them.
* **Lifetime.** The thread is never joined: `vol_stop` posts a quit and the
  thread frees its own state, so shutdown cannot block on a bus that does not
  answer. Don't use the monitor or its wake fd after `stop`. Publishing is
  coalesced (one 40 ms one-shot per burst of signals) and happens only on a
  real change.
* **Ejecting is unmounting.** A device stays listed, dimmed, while attached;
  power-off would make SSDs vanish. Eject first leaves the volume if the view
  is inside it, and is refused while a file operation runs. One mount/eject at
  a time (`device_op`); a mount opens the volume only if `navigation_count` is
  unchanged.
* **Trying it for real** without touching disks:
  `truncate -s 64M x.img && mkfs.ext4 -L X x.img && udisksctl loop-setup -f x.img`
  (polkit allows it for an active session), then `udisksctl loop-delete -b`.
  Never click an unmounted internal partition in a real session: mounting it
  raises an admin prompt.

## Sidebar rows

Rows are indexed in drawn order, which the hover glide relies on: built-ins
`0..pin_base` (`places`; Recent hides when unavailable, and those from
`places_start` on can be unpinned through `unpinned_places`), then pins, then
devices from `deviceBase()`. Go through `rowKind`; never use `places.len` as a
row index. Hover keys: 300+i built-in, 800+j pin, 600+k device, 700+k eject.
`pinRowY` positions pins and the drop line; `placeY` for devices,
`deviceBlock()` and `gitCard` follow the pin and device counts: change them
together.

## Pins

* **Pins are PLACES rows the user drops in.** `pins.zig` owns the list
  (`$XDG_STATE_HOME/rediwm/files-places`, one absolute path per line). The
  file is the truth: `pinDropped`/`removePin` re-read it before changing (a
  second window must not overwrite the first's pins) and the keyboard `enter`
  event calls `refreshPins`.
* **Pins are not built-ins:** a visible built-in place's path is refused
  ("Already in Places"), a hidden built-in can be dropped back as a pin, a
  missing target stays listed dimmed, and a file pin opens like a double click
  (a chooser browses its folder).

## Drops

`main.zig` `dragOver`/`dragDropped` accept `text/uri-list`: PLACES pins with
*copy* only; the content area transfers to the hovered folder or, on empty
space, the displayed directory. The live terminal body accepts *copy* only
and inserts shell-quoted absolute paths without Enter. Snapshot its editor
revision so a delayed receive cannot type after focus/session changes;
control bytes are refused because terminal paste would alter them.

* Files sources advertise `application/x-rediwm-file-transfer`: the receiving
  job owns moves and the source never deletes on `dnd_finished`. Ctrl at drag
  start offers copy only; other sources copy.
* After `drop` the offer leaves `drag_offer` (a `leave` would destroy it) and
  is read through a nonblocking pipe (`drop_receiving`, poll slot 15).
  Snapshot the destination before reading.
* Drops use the normal conflict/progress jobs without touching cut-clipboard
  state; reject a folder dropped into itself or a descendant, including
  through symlinks. Pins take their gap from `pin_drop`.
* Ctrl-click deselection waits for release so Ctrl-drag keeps the selection.

## BitTorrent transfers

`app_torrents.zig` owns the sidebar, main-pane list, toolbar and detail dialog;
`app_torrent_rows.zig` owns folder-row matching, controls and hover details; `torrents.zig` is a bounded,
nonblocking SOCK_SEQPACKET subscriber (poll slot 22). `torrent/helper.cpp`
owns libtorrent, persistent resume data, StatusNotifierItem and its D-Bus menu;
its parts are `helper_transfers`, `helper_peers` and `helper_tray.cpp`, sharing
`helper.hpp` (everything in `namespace helper`; new state shared between parts
is an `inline` variable there, state of one part stays `static` in it).
The helper survives Files closing; no torrent state belongs to a window.
See `docs/files-torrents.md` for dependencies, storage and lifecycle.

* The socket is `files-transfers.sock`, deliberately outside `rediwm-*.sock`
  compositor discovery. Both ends check peer credentials; runtime/state are
  private. Use the system C++ compiler to match libtorrent's distro ABI.
* Folder accessories match full source/storage/published paths, never basenames.
  Destination entries for unpublished payload have `transfer_stub` and `missing`:
  activate transfer details, exclude them from filesystem operations and chooser
  results. Rebuild their rows only for structural changes; progress/rate updates
  repaint without resetting selection or scrolling. ETA uses remaining selected
  bytes and payload rate; no estimate while paused or stalled.
* File priorities apply asynchronously: keep payload paused/upload-only until
  `file_prio_alert` confirms the requested priorities, then save and resume.
  Treat duplicate v1/v2 aliases as errors in libtorrent too, not just by UI ID.
* Payload starts in a private staging directory. Metadata alone never starts
  payload downloading. Pause before publication, rename the whole directory
  with RENAME_NOREPLACE, then update the engine's storage path. Never use
  libtorrent's racy `fail_if_exist` move mode or delete payload on removal.
* Idle releases the engine after pending resume writes drain. UI subscribers
  can remain attached without torrent worker timers. Last subscriber leaving
  exits a stopped helper; active downloads/seeding keep it alive.
* `zig build test-files-torrents` uses a private bus, temporary state and a
  noninstalled loopback network shim. Never fetch public torrents in tests.
