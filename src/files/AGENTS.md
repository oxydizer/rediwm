# Files

Text, colour and theme rules shared with Images and PDF are in the root
`AGENTS.md` ("Shared UI"). Every test that launches Files sets
`REDIWM_FILES_DEVICES=0` and scratch `XDG_STATE_HOME`/`XDG_DATA_HOME`
(`TESTING.md`, "Common knobs").

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
  painting and damage. Thumbnails are drawn in `drawItemIcon` (grid 48, list
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
space, the displayed directory.

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
