# Notes for agents working on RediWM

Details that are easy to get wrong. Read the relevant section before touching
rendering, Xwayland, damage, input, locking or protocol code. Tests: `TESTING.md`.

**Tool use is costly.** Don't poll processes, logs or CI in tight loops: wait
15–30 s between checks of long operations, batch checks, don't re-read
unchanged files, stop once you can proceed.

**Don't add tests unless they are really needed or asked for** (Python or Zig).
The suite is already large and slow to maintain. Prefer running the existing
tests for what you touched; extend an existing test over writing a new one, and
add a new file only for a regression that nothing current can cover.

**Before you finish:** build Debug and `-Doptimize=ReleaseSafe`, run
`zig build test` and the integration tests for what you touched. Some suites
fail on unmodified builds: compare against a `git worktree` of HEAD before
calling a failure a regression.

## Rendering

1. **wlroots colours are premultiplied.** `wlr_scene_rect_*` and
   `wlr_render_rect_options.color` take premultiplied `float[4]`. Theme colours
   are `col.Straight` (`src/color.zig`); create/recolour rects only through
   `col.createRect`/`col.setRect`; pack CPU pixels with `Straight.argb()` /
   `Premul.argb()`. Symptom of getting it wrong: white border edges.
2. **Borders have two render paths.** `chrome.ChromeBuffer` rasterizes curved
   corners; straight edges are `SceneRect`s from `Toplevel.syncBorders`, inset
   by `ceil(frame_radius)`. Change both together. `side_fills` back the border
   beside the client with `window_bg` (between title/footer bands, included in
   opacity).
   * Chrome is two bands (title, footer skirt below the client, since wlroots
     0.20 can't mask the client). Check `frame.band`, not just `py`. Skirt
     height ≥ `ceil(frame_radius)`; `footerHeight()` sizes and positions it.
   * The skirt takes the client's edge colour: `probeClientEdge` samples the
     last row of the buffer source box (median per channel; wl_shm is
     premultiplied). Resample only on sampled-row damage or a mapping change;
     pointer reuse proves nothing. `readFormat` is memoized per texture (it
     binds GL; per-commit calls cost ~20% idle CPU). `Color.argb` rounds.
3. **Buffer size ≠ scene destination size** at fractional scale
   (`round(len*scale)` vs `round((off+len)*scale)-round(off*scale)`). Titlebar
   and panel buffers use bilinear filtering; never re-raster per device-grid
   phase (`ChromeBuffer.create` costs 2–8 ms).
4. **Nested sessions lie about scale:** the Wayland backend never sets buffer
   scale. Judge sharpness with `REDIWM_SCALE=1`. A mismatched startup scale can
   make objects beyond the first size vanish briefly: not a bug.
5. **Visual debugging:** prefer IPC screenshots/buffer dumps over host `grim`
   (which shows host scaling and covering windows).
6. **Scene buffers may drop CPU storage:** after GLES upload
   `wlr_scene_buffer.buffer` may be NULL with a valid texture. Persist raster
   sizes separately. Test with `REDIWM_TEST_RENDERER=gles2`.
7. **Glass:** client textures are `wlr_client_buffer_get(buffer)->texture`;
   track source-surface damage per effect (output damage misses content under
   foreground windows). Empty commits and buffer rotation don't invalidate
   blur. During drags titlebar blur may be held at ≥ 0.98 opacity; every path
   ending a move must schedule a frame.
8. **Output commits** go through `Output.commitFrameState` (gamma, test state),
   never `wlr_output_commit_state`. `commitIsRedundant` skips commits with no
   damage, colour change, attach-render lock or cursor change; anything new
   that needs a commit without scene damage must be added there. Skipped frames
   get callbacks from `vblank_timer`, never immediately.
9. **Idle makes no wakeups.** Timers only for known deadlines; worker results
   signal an eventfd. `text.applySize` activates prepared `FT_Size`s (don't
   re-size faces). Title-only changes repaint only the title span and taskbar
   chip. Measure idle CPU with per-thread context switches, not jiffies.

## Damage and retained pixels

* Each reusable shm buffer tracks damage since its own last paint; never write
  a busy buffer. Don't resend unchanged `set_buffer_scale`; prefer compositor v5.
* `panel_paint.Background` keeps the last complete image; `paintIncremental`
  repairs recycled buffers and rasterizes dirty widgets. Widget setters call
  `markDirty`/`markPaintDirty`; moved widgets damage old and new bounds.
  Convert publish damage at the real raster scale.
* Compositor-owned buffers in the world reach their projected view with full
  damage unless reported: `Projection.damageBuffer` after `setBuffer`, or
  `Projection.presentOwned` (in-place texture update).
* Cache keys include visual state, text, geometry and Cairo transform. Round
  globally before subtracting projection group origins.
* `wlr_client_buffer_apply_damage` updates shm in place only without extra
  locks: anything holding a client buffer across commits marks its lock
  ignorable. v4 `attach(buffer, 0, 0)` still sets OFFSET; only nonzero dx/dy
  is a remap.

## Windows

* **Unmapped ≠ destroyed.** `frame_tree` starts disabled; only `handleMapped`
  enables it. `focusSurface`/`minimize`/`restore` require `in_world`.
  `destroyNow` asserts `backend_gone` (or a compositor-owned backend).
* **Tiles are compositor-owned geometry** like maximize (`snap.zig`,
  `tile`/`tile_target`/`tile_restore`, included in `forcedGeometry()`).
  `Toplevel.layout()` reads the `maximized` field, not `isMaximized()` (xdg
  acks a commit later). Leaving a layout without moving goes through
  `leaveLayout()`.
* **Compositor-drawn windows (`Backend.shell`)**: Settings is an ordinary
  window whose body `ControlCenter` paints into `scene_tree` at `render_scale`
  and presents with `presentOwned`. No wl_surface, so focus is "first in
  `world.toplevels`, activated, no seat focus, desktop unfocused"
  (`hasKeyboardFocus`); `World.focusSurface` deactivates a previous `.shell`
  window and calls `Desktop.yieldKeyboard`; `findFocusedToplevel` returns it.
  Compositor bindings run before it gets keys. Pointer coordinates come from
  `localPoint`. `close()` frees the content and `Toplevel.destroy`s the window
  (which may animate from a snapshot), so clear `backend.shell.control_center`
  and the node's scene data first; never close from inside a widget callback.

## Xwayland

* With native scaling X11 renders at N = `ceil(max output scale)`.
  `Xwayland.create` runs before outputs exist; `refreshScale` (after
  `Output.create`) recomputes N. Reproduce ordering bugs with per-output config
  scale, not `REDIWM_SCALE`. Scale changes after X11 surfaces exist wait for a
  restart. `xwayland_scale` 0 = automatic.
* Units: `surfaceScale()` = N; `clientSurfaceGeometry()` is X units;
  `clientGeometry()` world units (`ceil(surface/N)`); `requestSize()`/
  `commitPosition()` take world units; `applySizeClip()` and `probeClientEdge()`
  surface units. Content trees use `rediwm_projection_set_tree_scale(1/N)`.
  X11 chrome density is 0.75.
* Clamp stale off-screen geometry of new X11 windows in
  `handleRequestConfigure` (except `open_rules`/`forcedGeometry()`).
* Keep `scene.restack_xwayland_surfaces = false`; `Toplevel.raise` keeps scene
  and X11 stacking in sync. Activation must not raise an owner above its
  transients. Compositor hit tests can't prove X11 routing.

## Input

* **Text input/IME** (`input/text_input.zig`): `syncFocus` is the only enter
  path. IM grabs replace client delivery only; bindings, hardware keys and
  shell/lock UI win. An IM's own virtual keyboard bypasses its grab.
  Lock/auth reject virtual input. `GetTextInput` never returns text.
* **Layouts:** layout-zero fallback is for binding lookup only; text uses the
  active XKB state.
* **Shell key repeat:** one `shell_repeat` per keyboard; a new shell target
  needs a `ShellTarget` case and a freeable panel calls `forgetShellTarget`.
  Return, Escape, Tab and modifier chords never repeat.
* **Pointer constraints** (`input/pointer_constraints.zig`): every client
  motion path calls `clientMotion` then `sync`. Active only with pointer and
  keyboard focus; new compositor input modes go in `motionReachesClient` or
  `candidate`. `sendDeactivated` destroys oneshots synchronously: clear
  `active` first.
* **Shortcuts inhibit** gates only switcher, screenshot shortcuts and final
  dispatch; hardware keys, VT switching and open panels still win.
* **Drag-and-drop:** wlroots does not cancel a drag on Escape; `Keyboard`
  calls `Input.cancelDrag` (destroys the source, then `pointerEndGrab`).
  `input/drag_dodge.zig` slides a file manager aside through
  `Toplevel.setDodge`, a presentation-only offset added in
  `applyVisualTransform`: never fold it into `x`/`y`/`move_x` (it would grow the
  canvas, reach IPC and saved layouts, and outlive the drag). Anything that
  stops showing a window must `clearDodge` it (`detachInput` does).
* **Touch/tablet** use their own protocol only when
  `directInputReachesClients()`; otherwise they emulate the pointer (send your
  own `pointerNotifyFrame`). Touchscreens map to `output_name` or the built-in
  panel. A closed lid hides built-in panels only while another display is on;
  undocked, logind owns the lid.

## Desktop (`[desktop] enabled`)

* `desktop/App` and its worker never depend on the compositor; the worker is a
  thread that never calls the host. Tests set `REDIWM_DESKTOP_DIR`.
* One retained canvas published as 240-logical-px tiles; only damaged tiles
  get new buffers. Rasterize the selection band once per paint; repair clips
  snap outward to device pixels. Labels/icons are rasterized at exact scale.
* Desktop keyboard focus is shell focus: taking it clears seat focus; any
  surface gaining seat focus (or a `.shell` window) takes it back.
* Drops: `desktop_drop.Target` ends the grab first, then negotiates with the
  source. `wlr_data_source_send` closes its fd.
* A `.desktop` file runs only if `Worker.trustedLauncher` accepts it
  (installed or linked into the menus, root-owned, executable, or an exact
  copy of the installed entry); otherwise it is an `untrusted` plain file whose
  own Name/Icon are never shown. Allow Launching is `chmod u+x`.

## Security, lock and login

* **Greeter** (`rediwm --greeter`) is a lock that never unlocks; only
  `rediwm-dm` decides. It writes nothing under `$HOME` and runs no Xwayland,
  autostart, IPC, notifications, tray, portal, polkit, services, audio,
  desktop or external-tool globals; anything new that owns a bus name, spawns
  or writes must be skipped there (`tests/greeter.py`). Secrets stay in
  mlocked, wiped buffers.
* **rediwm-dm** never blocks; workers own one PAM handle each. Signal masks
  survive exec (clear them). `PR_SET_PDEATHSIG` is cleared by `setuid`. The
  greeter is untrusted input. Never format JSON with `{s}`. Only daemon and
  workers are root; don't sandbox `rediwm-dm.service` (users inherit it).
  `--test`, `--confdir`, `--data-dir` and `--marker` are refused as root.
* **A crash never unlocks.** `Lock.announce` reports `locked`/`unlocked` on
  `REDIWM_SESSION_FD` (first thing in `engage`); `rediwm-session` queues `lock`
  before restarting a compositor that crashed while locked, and `main.zig`
  takes it and locks before the backend starts. Lock-before-sleep holds a
  logind delay inhibitor until `Lock.covered()` (the builtin lock sets
  `Output.lock_commit_pending` too). logind `Lock` is followed for
  `REDIWM_LOGIN_SESSION` only; `Unlock` is ignored on purpose.
* **The lock never polls.** Its one timer redraws the clock at the next minute
  boundary; the PAM worker (`session/auth.c`) signals an eventfd that
  `Lock.authReady` watches only while an attempt runs. Don't add a periodic
  tick (a 100 ms one cost ~10 wakeups/s for as long as the session stayed locked).
* **Lock volume/brightness** (`session/lock_controls.zig`): sliders at the
  bottom centre of the built-in lock, the pointer/touch way to what the
  hardware keys already do behind it. Never in the greeter (no audio, no
  external tools) and hidden under an ext-session-lock client's surface. They
  are their own small raster (`View.controls_node`), so a drag never re-rasters
  the clock, avatar and field. A row exists only while its backend reports
  (`Lock.controlsChanged` from the audio wake and the brightness helper's
  result); a drag shows its own value until release. Events only, no timer.
* **Production reads no test-hook environment.** `REDIWM_*_PREVIEW` lives only
  in `test` blocks and `REDIWM_TEST_*` only in noninstalled fixtures. The polkit
  helper socket comes from `[polkit] helper_socket`; `REDIWM_POLKIT_HELPER_SOCKET`
  is read by `polkit_test_service` alone, because it decides where the user's
  password is sent. `strings` a ReleaseSafe `rediwm` for these names after
  touching env handling.
* **App scopes** (`session/app_scope.zig`): every user-app launch path calls
  `app_scope.place(server, pid, id)` after spawning, moving it into its own
  `app-rediwm-<id>-<pid>.scope` in app.slice (systemd-oomd kills whole
  cgroups; a shared session scope dies with a runaway app). Worker threads
  hand pids to the main thread first (desktop: `Worker.takeStarted`). Off in
  nested/headless sessions unless `REDIWM_APP_SCOPES=1`; never in the greeter.
* **Account management** runs through the root-owned
  `rediwm-accounts-helper` under `pkexec`; the compositor never runs as root.
  The helper treats stdin JSON and `PKEXEC_UID` as untrusted, validates every
  operation, passes argv arrays to absolute system tools, and never accepts
  passwords in argv. Its authorization-only request changes no system state.
  Keep the helper, policy and client out of greeter mode.
* **IPC** refuses everything with `SessionLocked` while `locker != null`
  (event subscriptions re-check). Synthetic input and pixel reads need
  `[ipc] automation` (read once at startup). Socket only in a private
  directory, umask 0177. Sandboxed callers (checked via `SO_PEERPIDFD` and
  `.flatpak-info`) need an explicit `[[sandbox_allow]]` `ipc` allowance, fail
  closed, and are re-checked on reload.
* **Security context** (`src/global_filter.zig`): privileged globals are
  hidden from `wp_security_context_v1` clients and guess-binds are protocol
  errors, unless `[[sandbox_allow]]` grants the group. Nested contexts are fatal.
* **External protocols** (`tests/wlr_protocols.py`): a client
  ext-session-lock is a `Lock` with `origin = .client`, so every `locker`
  guard applies; client death keeps the session locked. Screencopy policy runs
  in `guardScreencopy` (disconnects during lock/polkit). Foreign-toplevel
  sync sits next to every `onWindowChanged`/`onWindowMoved`. Output
  management applies through `Output.applyAndPersist`. Output power `off`
  sets `Output.power_off`; only a client `on` clears it.
* **Explicit sync** (linux-drm-syncobj): projection moves `output_sample` to
  the view and copies wait points; other GPU reads use `ReadFence`; CPU reads
  check `AcquireWait.ready`. `REDIWM_NO_EXPLICIT_SYNC=1` withholds it.

## Build and platform gotchas

* `ui`, `dbus` and `config` are named build modules rooted in their own
  directories. Keep dependencies one-way: no compositor imports in them.
  Configuration parsing/persistence lives in `config/`; applying settings,
  watching for reloads and launching actions live in `config_runtime/`.
  Shared raster support (`text`, `anim`, `sdf`, icons) belongs to `ui/`.
  `memory` owns the process allocator; executables own its shutdown.
* ReleaseSafe's `_FORTIFY_SOURCE` breaks translate-c on `bits/fcntl2.h`: use
  `std.os.linux` or `@cUndef("_FORTIFY_SOURCE")`. Never `@cInclude`
  glib/gobject/gio/librsvg; hand-declare the ABI.
* No runtime `parseColor()` in comptime defaults.
* **Raw syscalls:** `std.os.linux.*` return `-errno` in `usize` (use
  `std.os.linux.errno`); `std.posix.system.*` are libc (`std.posix.errno`).
* zig-wlroots types referencing `ext.*`/`wp.*` need the protocol in
  `build.zig`'s scanner. Some fields declared non-null can be NULL
  (`ForeignToplevelHandleV1.event.Fullscreen.output`,
  `ScreencopyFrameV1.buffer`): read through `*const ?*T`. `wlr.Pointer` is
  8 bytes short of the C struct (no trailing `data`): embed it through an
  extern wrapper (`input/virtual.zig`), or `wlr_pointer_init` overwrites the
  next field.
* **Debug builds use `DebugAllocator`** for `main.gpa` (optimized builds use
  libc). Freed memory reads `0xaa…` (glibc `MALLOC_PERTURB_` gives `0xa5…`);
  leaks print at exit into the compositor log. Free process-lifetime caches in
  `main.start`'s defers, or allocate state that must outlive shutdown (worker
  threads still reading it) from `std.heap.c_allocator`. Never mix: memory
  from `gpa` must go back to `gpa`.
* Cairo `ARGB32` is premultiplied `0xAARRGGBB` like RediWM buffers.
  `png.zig` supports only 8-bpc non-interlaced truecolour(+alpha).
* `/sys/class/power_supply/*/uevent` reads can be expensive: read on uevents
  and the minute tick only.

## Releases and install

* **`scripts/install.sh` installs a prebuilt per-distro tarball** (`--build`
  compiles; running from a checkout implies `--build`). It must stay
  self-contained up to the download, since `curl | sh` has no repo yet.
  `scripts/make-release.sh` builds each tarball in a clean podman/docker
  container of its distro and installs it with the real `install.sh` in a
  fresh one; run it before publishing and read the verify step's output.
* **One tarball per distro, not per architecture-and-glibc.** Package ABIs
  differ (libjpeg is `.so.8` on Arch/Ubuntu, `.so.62` on Debian/Fedora with a
  different struct layout). A derivative uses its parent's tarball; if its
  libraries don't match, `unresolved_libs` (missing libs or too-new
  glibc symbol versions) or a failed package install falls back to a source
  build. A checksum mismatch never falls back: it dies.
* **`DEPENDS` is generated from the built binaries' `NEEDED` libraries**
  (`release-build.sh`), never hand-kept; only the extras (Xwayland, portals,
  Python, Mesa drivers) are listed by hand. Libraries bundled in `lib/rediwm`
  are excluded, and which ones get bundled depends on what the build
  container has installed, so never install the distro's own wlroots there.
* **Releases are always built with the pinned, patched wlroots** from
  `build-wlroots.sh`, whose recipe hash includes the script itself (editing
  even a comment rebuilds everyone's private prefix). `rediwm`'s RUNPATH picks
  up the build prefix when linking it; `release-build.sh` scrubs that with
  patchelf and `release-verify.sh` rejects any `/work/` path.
* **CPU is `-Dcpu=x86_64_v2`.** Zig defaults to the build machine's CPU, which
  would put illegal instructions into every user's binary. Releases are
  x86_64 only; other CPUs build from source.
* Checksums come from the same GitHub release as the tarballs, so they catch
  corruption, not a compromised release. Signing is not done yet.

## Files Git

* `files/git.zig` never runs a repository's own programs: a folder's `.git`
  arrives with archives and USB sticks. Every command uses `safe_options` and
  `cleanEnv` (no fsmonitor, hooks, pager, transports or lazy fetches);
  `trustedRepository` refuses repositories whose own (local, worktree or
  included) configuration names filter or Git LFS commands, and `status`
  ignores submodules (their configuration is not checked).

## Files thumbnails

* **Decoding avoids GdkPixbuf for JPEG and PNG.** On current systems gdk-pixbuf
  routes them through sandboxed glycin loader processes and ignores scaled
  decode (a 12 MP JPEG costs ~150 ms). `files/thumb_codec.c` decodes JPEG at
  1/2–1/8 inside libjpeg's DCT and streams PNG rows into an area-averaging
  downscaler, so no full raster exists. Anything it reports unsupported
  (WebP, GIF, SVG, interlaced PNG, CMYK JPEG) falls back to
  `images/decode.zig` (`loadWith` with a box), which is also what the viewer's
  `loader.zig` re-exports. Re-measure before "simplifying" this.
* **`files/thumbs.zig` is the only owner of the raster cache**: 2 nice'd
  workers, queue replaced on every `request` (scrolling cancels queued work),
  results handed over under the mutex and an eventfd, LRU by bytes and entry
  count. Workers never touch Cairo or Wayland. Keys are path plus the
  mtime and size the *listing* reported; a stale file is dropped without an
  entry and retried after the next rescan. Failures are remembered per file
  state. Idle must stay at zero wakeups: no timers.
* **App side:** `stepThumbs` re-requests only when the visible rows or
  `view_revision` change; `drainThumbs` damages just the arrived icons
  through `addDamage`. `itemIconRect` is the single source of icon geometry
  for painting and damage: change them together. Thumbnails are drawn in
  `drawItemIcon` (grid 48, list 24, drag icon 32) with a bilinear-filtered
  128 px raster.
* **Shared freedesktop cache** (`$XDG_CACHE_HOME/thumbnails/normal|large`):
  name is the MD5 of the GLib-escaped `file://` URI, validated by
  `Thumb::MTime` (and `Thumb::Size` when present) against the *target's* stat.
  Entries are written after the UI has its pixels, via tmp file + rename, mode
  0600, only when the original is bigger than 128 px. Tests set a scratch
  `XDG_CACHE_HOME`. `REDIWM_FILES_THUMBNAILS=0` turns thumbnails off.

## Files devices

* **Transport vs policy.** `files/volumes.c` is a GLib thread holding a GDBus
  object-manager client for UDisks2 on the system bus (not `src/dbus`: that is
  tied to the compositor's `wl.EventLoop`). It only publishes raw records and
  runs Mount/Unmount with interactive polkit authorization. What to list, the
  label and the stick/drive icon are `volumes.zig`'s `shown`/`kindOf`.
  `HintIgnore` hides EFI partitions; `HintSystem` volumes mounted outside
  `/run/media`, `/media`, `/mnt` (`/`, `/home`, `/boot`) are hidden by the
  mount rule, because UDisks2 does not ignore them. Loop devices are
  `HintSystem` too, so only that rule decides them.
* **Lifetime.** The thread is never joined: `vol_stop` posts a quit and the
  thread frees its own state, so shutdown cannot block on a bus that does not
  answer. Do not use the monitor or its wake fd after `stop`. Publishing is
  coalesced (40 ms one-shot per burst of signals) and only on a real change;
  idle makes no wakeups.
* **Ejecting is unmounting.** A device stays listed, dimmed, while attached;
  power-off would make SSDs vanish. Eject first leaves the volume if the view
  is inside it, and is refused while a file operation runs. One mount/eject at
  a time (`device_op`); a mount opens the volume only if `navigation_count`
  is unchanged.
* **Sidebar rows.** DEVICES sits below File System, so hover-glide row indices
  stay in order: devices are `places.len + k`, hover keys 600+k (row) and
  700+k (eject button). `placeY` for those indices and `deviceBlock()` move the
  Git card and scroll extent; change them together.
* **Tests.** The device list talks to the host's real system bus, so every test
  that launches Files sets `REDIWM_FILES_DEVICES=0` (or a dead
  `DBUS_SYSTEM_BUS_ADDRESS`). To try it for real without touching disks:
  `truncate -s 64M x.img && mkfs.ext4 -L X x.img && udisksctl loop-setup -f x.img`
  (polkit allows it for an active session), then `udisksctl loop-delete -b`.
  Never click an unmounted internal partition in a real session: mounting it
  raises an admin prompt.

## Files pins

* **Pins are PLACES rows the user drops in.** `files/pins.zig` owns the list
  (`$XDG_STATE_HOME/rediwm/files-places`, one absolute path per line). The file
  is the truth: `pinDropped`/`removePin` re-read it before changing (a second
  window must not overwrite the first's pins) and the keyboard `enter` event
  calls `refreshPins`. Tests need a scratch `XDG_STATE_HOME`.
* **Row indices are in drawn order** (the hover glide needs that): built-ins
  0..`pin_base`-1, pins, File System (`systemIndex()`), devices
  (`deviceBase()`). Never use `places.len` as a row index; go through
  `rowKind`. Hover keys: 300+i built-in (File System is 300+`pin_base`), 600+k
  device, 700+k eject, 800+j pin. `pinRowY` positions pins and the drop line;
  `placeY` for File System and everything below it follows the pin count.
* **Files drops** (`main.zig` `dragOver`/`dragDropped`) accept `text/uri-list`:
  PLACES pins with *copy* only; the content area transfers to the hovered folder
  or, on empty space, the displayed directory. Files sources advertise
  `application/x-rediwm-file-transfer`: the receiving job owns moves and the
  source never deletes on `dnd_finished`. Ctrl at drag start offers copy only;
  other sources copy. After `drop` the offer leaves `drag_offer` (a `leave`
  would destroy it) and is read through a nonblocking pipe (`drop_receiving`,
  poll slot 15). Snapshot the destination before reading. Drops use the normal
  conflict/progress jobs without touching cut-clipboard state; reject a folder
  dropped into itself/descendants, including through symlinks. Pins take their
  gap from `pin_drop`. Ctrl-click deselection waits for release so Ctrl-drag
  preserves the selection.
* **Pins are not built-ins:** a built-in place's path is refused ("Already in
  Places"), a hidden built-in can be dropped back as a pin, a missing target
  stays listed dimmed, a file pin opens like a double click (a chooser browses
  its folder).

## Shared UI

* Widget callbacks carry `owner` and `id`; pass a stable host or section
  pointer instead of a global current instance. The owner must outlive the
  widget tree. Finish widget state updates before calling back; reset the
  dispatcher when rebuilding, and defer host destruction until dispatch returns.
* One look per control: `ui/widgets/field.zig`, `button.zig`, `avatar.zig`,
  `dialog.zig`, `checkbox.zig`, `toggle.zig` own stateless painters used by widget trees and
  hand-laid screens alike. Don't hand-draw fields or buttons.
* **The battery badge** (`ui/widgets/battery.zig`: frame, glyph, percentage,
  charging bolt) is the taskbar's artwork, shared. `sample` is the pixel math
  (per device pixel, badge-local units); the taskbar's per-pixel raster calls
  it and `paint` draws it into any `Renderer`, so the two cannot drift. The
  caller owns the data (hide it when there is no battery) and the connection
  shimmer's clock (`Spec.shimmer`). Don't redraw the glyph elsewhere.
* **One scrollbar** (`ui/widgets/scrollbar.zig`, Files' look): a track-less
  thumb centred in a `gutter(scrollbar_width)` strip, thin at rest, widening
  and tinting to the accent on hover/drag, holding a faint tint after a
  scroll. Never hand-draw or hand-hit-test one. `Geometry.compute` gives the
  thumb for any axis and unit (pixels, or items for a strip that scrolls by
  item), `press` the grab-or-page decision, `Drag` the pointer-to-offset map,
  `look` + `paint` (Renderer) / `cairo.drawScrollbar` (Cairo) the pixels, and
  `Appearance.step` the feedback: edge-triggered on what is drawn, and the
  app's loop sleeps until `deadline` and runs frames only while `active`
  (`barTimeout` in PDF/Editor, `animationTimeout` in Images, `pollTimeout` in
  Files). Paint-only popups pass `.{}` for the rest look. The gutter is the
  bar's: layouts keep content out of it and a press in it never reaches
  content. Widget trees get all of this from `.scroll_container`: hosts call
  `scroll_container.stepBars` beside `stepGlides` and carry `ScrollState.bar`
  across rebuilds.
* **Sliders reuse the scrollbar's feedback** (`SliderData.feel` is a
  `scrollbar.Appearance`): hover and drag tint and thicken the track, a change
  holds the faint tint. `stepBars` steps sliders too (`slider.stepFeedback`);
  `Dispatcher.setHovered`/`pointerLeave` keep `hovered` in step. A value
  readout is `slider.valuePill` (a `.text` with `pill`), found from its slider
  by `findPill` (first pill under the slider's parent), lit by drag only. A
  theme slider's save rebuilds Settings the moment the button is released, so
  `panel.rebuildTree` carries named sliders' state across (`slider.capture`/
  `restore` + `input.adoptHover`) on the same page; an unnamed slider starts
  fresh. Never change `Appearance.width` per call site: it is every bar's width.
* Cairo clients use `ui/cairo.zig` (`drawText`, `setSource`, `Layer`); toolbar
  glyphs are shell icons, not Cairo paths. Colours come from theme tokens:
  app surfaces are `app_*`, red accents `shellPalette().accent`. Files, Images
  and PDF text is `window_fg` only (no `text_secondary`/`window_dim` blue-grey;
  a placeholder is `window_fg` at half alpha) at `text_size`, with
  `heading_size` for column/section headings and `status_size` for status
  lines. Don't hardcode sizes there; window chrome keeps its own. Clients read the theme with
  `files/settings.zig` (`loadTheme` before the first frame, PDF before its
  sandbox; Files' worker follows edits).
* A `.scroll_container` scrolls along its `direction`: `.row` is sideways with
  the bar along the bottom edge, so set `.direction` explicitly (it defaults to
  `.row`). Rebuilt trees carry the offset over themselves (the wallpaper strip
  copies it from its old widget). Appearance's wallpaper strip owns a
  `wallpaper_strip.Strip` (decode worker + eventfd) that outlives rebuilds and
  is restarted only when the image list changes; thumbnail slices stay valid
  until then. IPC `scroll` follows `invert_scroll` (default natural: negative
  dy moves a page down).
* Secrets live in `secret_input.Input` over caller-owned (mlocked) storage.
  Hand-laid secret fields draw the caret through `CaretOverlay`.
