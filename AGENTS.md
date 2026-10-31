# Notes for agents working on RediWM

Details that are easy to get wrong; read the section for what you touch.
Tests: `TESTING.md`. Where code lives: [source map](docs/agent-notes/map.md).
Area notes are in an `AGENTS.md` beside the code; read
the one for the directory you work in: `src/files`, `src/editor`,
`src/desktop`, `src/input`, `src/control_center`, `src/ui`, `src/session`,
`src/dm`, `src/accounts_helper`, `src/printing`, `scripts`, `src/wlr`,
`src/platform`.

## Working rules

* Keep this file to cross-cutting rules and pointers; put detailed subsystem
  notes in the linked documents or the area’s `AGENTS.md`.
* Tool use is costly: no tight polling (wait 15–30 s between checks of long
  operations), batch checks, don't re-read unchanged files.
* Add tests only when really needed or asked; prefer extending existing ones.
* Keep files small enough to read whole. When a file you touch grows past
  ~800 lines or a function past ~150, split it by concern (below), moving
  code verbatim (C and C++ too). Tests go in a `*_tests.zig` beside the code
  once they outgrow a screen. Exempt: generated or table files
  (`ui/fold_data.zig`, `ipc/commands.zig`). `tools/split/` moves Zig
  declarations from a spec and checks C splits; read its README first.
* Before finishing: build Debug and `-Doptimize=ReleaseSafe`, run
  `zig build test` and the integration tests for what you touched. Some
  suites fail on HEAD: compare with a `git worktree` of HEAD before calling a
  failure a regression.

## Split files

Large types are spread over sibling files by concern. A TitleCase host keeps
its methods in a lowercase directory: `Toplevel.zig` (`toplevel/`),
`Input.zig` (`input/`), `Taskbar.zig` (`taskbar/`), `Server.zig` (`server/`),
`Output.zig` (`output/`), `World.zig` (`world/`), `Dock.zig` (`dock/`),
`Keyboard.zig` (`keyboard/`). Other hosts keep them beside them under a
prefix: `files/app.zig`, `pdf/app.zig`, `desktop/app.zig`, `images/app.zig`,
`editor/app.zig` (`app_*.zig`); `files/Client.zig` and the `Client` in
`editor/main.zig` and `pdf/main.zig` (`client_*.zig`);
`control_center/ControlCenter.zig` (`tree`, `keys`, `relayout`, `paint.zig`);
`start_menu/StartMenu.zig` (`menu_*.zig`); `session/lock.zig`, `power.zig`
(`lock_*`, `power_*.zig`); `systemd.zig` (`systemd/`); `network/manager.zig`,
`dbus/connection.zig`, `ipc/wait.zig`, `ui/input.zig` (`<name>_*.zig`).
Hosts keep the fields, `init`/`deinit` and one
`pub const name = group.name;` alias per method, so `self.name()` is unchanged;
the bodies are free functions taking the struct pointer. A new method goes in
its group file plus an alias line. `ipc/protocol_*.zig`, `ipc/handlers_*.zig`,
`config/loader_*.zig`, `control_center/sections/appearance_*.zig`,
`printers_*.zig` and `msg/msg_*.zig`, `ui/paint_*.zig`, `ui/text_*.zig`,
`ui/theme_*.zig`, `ui/anim_*.zig`, `chrome_paint.zig` re-export their public
declarations from the original file. `handleRequest`/`handleAction` dispatch
groups of tags to `handlers_*.zig`, each a `switch` with `else => unreachable`.
`build.zig` keeps the options and shared modules; programs, data, session
binaries and test steps are in `build/` and run in the order `build()` calls
them.
Tests that used to sit in the big file are in a `*tests.zig` file reached by a
`test { _ = @import(...); }` block: a file nothing imports contributes no tests.
State (`var`) stays in the file that uses it; an alias would copy it.

C splits keep the public header and the file's lifecycle in the original
(`projection.c`, `scene_output.c`, `scene_pass.c`), with the parts
(`projection_*.c`, …) sharing a private `*_internal.h`: the structs, and small
per-item helpers as `static inline` (no LTO, so a file boundary must not cost
them inlining); other shared functions lose `static` and take the file's
prefix. `build/support.zig` lists the parts, and fixtures that `#include` a .c
include every part (`projection_test.c`); their cases are `*_test_*.c` files
included into the same unit. The transfers helper is `files/torrent/helper*.cpp`
around `helper.hpp`, all in `namespace helper`.

## Rendering and damage

Read [rendering details](docs/agent-notes/rendering.md) before changing
projection, the output pass, glass, window shapes, chrome, capture or retained
panel painting. The key rules:

* **Colours are premultiplied** in wlroots/Cairo buffers; theme colours are
  `col.Straight`. Use `col.createRect`/`setRect` and
  `Straight.argb()`/`Premul.argb()`. White border edges suggest a mix-up.
* **Resolve geometry, then present:** derive geometry only in `resolve`;
  `present` snaps edges once (`rediwm_edges_snap`), never origin plus size.
  New clip/opacity/placement rules belong on resolved items. Detach paint-list
  entries before freeing their heads.
* **Scene nodes are ours** (`node.zig`/`node.c`, wlr_scene's method names). A
  buffer or rect node keeps its pixels in a hidden wlr_scene *carrier* that the
  output pass reads; every setter keeps the two in step, and every change asks
  for a frame through the scene's hook. Client surfaces are own nodes too
  (`node_surface.c`, `node_subsurface_tree.c`, `node_xdg_shell.c`, ported from
  wlr_scene_surface/subsurface_tree/xdg_shell/drag_icon): a surface is a buffer node whose `surface` binding follows its
  wl_surface, an xdg surface a tree. The carrier's signals (`outputs_update`,
  `output_sample`, `frame_done`) are where the binding listens, so the projection
  raises them on the carrier. Hits come from `Projection.nodeAt` (a leaf node; a
  client surface has `buffer.surface`). A sync resolves only the top-level subtrees
  (groups) whose nodes changed, and nothing when no group and not the camera did:
  a change the node setters cannot see must call `Node.touch`, and a node whose
  geometry depends on another group's (a glass effect) is walked every sync. The
  `-Ddamage-audit` build logs any item the gate left stale.
* **The world has no second tree:** its source tree stays disabled. Pick with
  `rediwm_projection_node_at`, send callbacks through `Server.sendFrameDone`,
  and emit feedback/`output_sample` on source buffers. GLES may release
  `wlr_scene_buffer.buffer` after upload: persist raster sizes and treat a
  buffer, texture or single-pixel colour as content.
* **Commit through `Output.commitFrameState`** and build output state through
  `Server.buildOutputState`, including capture. Register new commit reasons
  in `commitIsRedundant`; skipped callbacks wait for `vblank_timer`.
* **Late rendering is opt-in** (`[compositor] late_render`; glue in
  `output/late.zig`, model in `late_render.zig`). Off, nothing in the frame path
  changes. On, a frame event that finds work and a trusted presentation
  timeline (vsync + hardware clock, a stream of frames, no VRR/tearing) is
  deferred: frame callbacks go out *then* so clients answer inside the wait,
  `late_timer` runs `runFrame`, which takes the plan and skips its own
  post-commit callbacks, and frame events meanwhile are ignored. Frames after
  idle always render at once. The deadline is `vblank - worst recent
  cost - margin`, cost = max(CPU to commit, build + GPU elapsed from
  `server.gpu_recent`); a missed vblank grows the margin, three in two seconds
  pause it with backoff. Headless presents synchronously and nested pipelines
  are deeper, so only `late_render_tests.zig` and a DRM run reach the engaged
  path (`tests/frame_latency.py`).
* **Window frames are shapes:** every ring pixel needs body content beneath
  it. Shadows, resize grabs, popups and other nodes outside the window need
  `setTreeUnclipped`. Capture the client alone with its shape supplied
  explicitly. Shaped programs are opt-in; without them windows are square.
* Restore owned GL state, especially `GL_ARRAY_BUFFER`, before wlroots draws.
  Draw borders with their bodies; blend NONE only in the opaque, ring-free core.
* **Glass belongs to the output pass.** Attribute changes through projection
  damage events; only painted leaves emit them. Input-only nodes must not
  invalidate glass. Retained blurs and holds are per effect and output.
* **Damage follows each buffer's history:** never write a busy shm buffer.
  Use `markDirty`/`markPaintDirty`, damage old and new move bounds, publish at
  the real raster scale, and report owned-buffer damage via
  `Projection.damageBuffer` or `presentOwned`. Cache keys include visual state,
  text, geometry and Cairo transforms. Round globally before group offsets.
* Fractional buffer size differs from snapped scene size; bilinear chrome and
  panel buffers must not be rerasterized for device-grid phase changes.
* **Idle makes no wakeups:** deadline-only timers, eventfd worker wakes,
  `text.applySize`, and title-span/chip repainting. Measure per-thread context
  switches. Nested sessions never set buffer scale: judge at `REDIWM_SCALE=1`
  using IPC screenshots/buffer dumps, not host `grim`.
* Client-buffer damage needs ignorable long-held locks for in-place updates.
  Only nonzero v4 attach offsets remap; don't resend unchanged buffer scales;
  prefer compositor v5.

## Windows and focus

* **Unmapped ≠ destroyed.** `frame_tree` stays disabled until `handleMapped`;
  `focusSurface`/`minimize`/`restore` need `in_world`; `destroyNow` asserts
  `backend_gone` (or a compositor-owned backend).
* **Dock geometry:** reserve space only without auto-hide; use
  `dockAreaBox` for the dock and taskbar popups, `usableBox` for windows.
  Read [dock details](docs/agent-notes/dock.md) before changing the dock,
  its painting, layout/reservation, OSD clearance, hover or auto-hide.
* **Tiles are compositor-owned geometry** like maximize (`snap.zig`,
  `forcedGeometry()`). `Toplevel.layout()` reads the `maximized` field, not
  `isMaximized()` (xdg acks later). Leaving a layout without moving goes
  through `leaveLayout()`.
* **Tiles glide and workspaces slide.** `setAutoTile(rect, animate)` eases
  like snapping (`auto_tiling.Manager.quiet` for non-user reflows). A switch
  keeps the leaving workspace's frames shown but inert
  (`rediwm_projection_set_tree_inert`) until `tickSwitch` settles; anything
  that stops showing a window mid-slide calls `finishSwitch`. Input follows
  what is drawn and `chrome_box` sizes are animated: tests
  `wait_for("window_geometry_settled")` before pointer input or geometry
  snapshots.
* **`Backend.shell` windows** (Settings) paint into `scene_tree` and present
  with `presentOwned`. No wl_surface: focused = first in `world.toplevels`,
  activated, no seat focus (`hasKeyboardFocus`). Never close one from a
  widget callback; details in `src/control_center/AGENTS.md`.
* **Desktop keyboard focus is shell focus:** taking it clears seat focus; a
  surface gaining seat focus, or a `.shell` window, takes it back.
* **Input** details are in `src/input/AGENTS.md`. Cross-cutting: every client
  motion path calls `clientMotion` then `sync`; Escape cancels drags through
  `Input.cancelDrag` (wlroots doesn't); compositor drop targets
  (`desktop_drop.Target`) end the grab before negotiating;
  `wlr_data_source_send` closes its fd.
* **Internal dock drags** use `dock_drag.zig`, not wl_data_device. Pins act
  on release; Escape cancels through `Input.cancelDrag` before shell panels
  handle it. Read [dock details](docs/agent-notes/dock.md) for start-menu
  pinning, reordering and pin storage.

## Xwayland

* X11 renders at N = `ceil(max output scale)`. `Xwayland.create` runs before
  outputs exist; `refreshScale` recomputes N after `Output.create`. Reproduce
  ordering bugs with per-output config scale, not `REDIWM_SCALE`. Scale
  changes wait for a restart once X11 surfaces exist.
* Units: `clientSurfaceGeometry()` X units; `clientGeometry()`,
  `requestSize()`, `commitPosition()` world units (`ceil(surface/N)`);
  `applySizeClip()` surface units; `surfaceScale()` = N.
  Content trees use `rediwm_projection_set_tree_scale(1/N)`; X11 chrome
  density is 0.75.
* Clamp stale off-screen geometry of new X11 windows in
  `handleRequestConfigure` (except `open_rules`/`forcedGeometry()`).
* Keep `scene.restack_xwayland_surfaces = false`; `Toplevel.raise` syncs scene
  and X11 stacking and never raises an owner above its transients. Compositor
  hit tests can't prove X11 routing.

## Security, lock and login

* **Greeter** (`rediwm --greeter`) never unlocks (only `rediwm-dm` decides),
  writes nothing under `$HOME` (it disables the GLES2 shader cache), and runs no Xwayland, autostart, IPC,
  notifications, tray, portal, polkit, services, audio, desktop or
  external-tool globals: skip anything new that owns a bus name, spawns or
  writes (`tests/greeter.py`). Secrets stay in mlocked, wiped buffers.
* **A crash never unlocks.** `Lock.announce` reports state on
  `REDIWM_SESSION_FD` first thing in `engage`; `rediwm-session` queues `lock`
  for a compositor that died locked, and `main.zig` locks before the backend
  starts. Lock-before-sleep holds a logind delay inhibitor until
  `Lock.covered()`. Only `REDIWM_LOGIN_SESSION`'s logind `Lock` is followed;
  `Unlock` is ignored on purpose. The lock never polls.
* **Only rediwm-dm and the accounts helper run as root** (see their
  `AGENTS.md`); never the compositor.
* **No test hooks in production:** `REDIWM_*_PREVIEW` only in `test` blocks,
  `REDIWM_TEST_*` only in noninstalled fixtures; only `polkit_test_service`
  reads `REDIWM_POLKIT_HELPER_SOCKET` (it decides where passwords go).
  `strings` a ReleaseSafe `rediwm` after touching env handling.
* **App scopes:** every user-app launch calls `app_scope.place` (own scope in
  app.slice, since systemd-oomd kills whole cgroups); workers hand pids to the
  main thread first. Off nested/headless unless `REDIWM_APP_SCOPES=1`; never
  in the greeter.
* **IPC** fails with `SessionLocked` while `locker != null` (subscriptions
  re-check). Synthetic input and pixel reads need `[ipc] automation`. Socket
  only in a private directory, umask 0177. Sandboxed callers need an explicit
  `[[sandbox_allow]]` `ipc` allowance, fail closed and are re-checked on
  reload. `scroll` is natural by default (negative dy pages down).
* **Security context** (`global_filter.zig`) hides privileged globals from
  `wp_security_context_v1` clients (guess-binds are protocol errors) unless
  `[[sandbox_allow]]` grants the group; nested contexts are fatal.
* **Protocols:** a client ext-session-lock is a `Lock` with
  `origin = .client`, so `locker` guards apply and its death keeps the session
  locked. Screencopy policy is `guardScreencopy`; foreign-toplevel sync sits
  beside every `onWindowChanged`/`onWindowMoved`; output management goes
  through `Output.applyAndPersist`; only a client `on` clears
  `Output.power_off`.
* **Explicit sync:** the pass emits `output_sample` on the source buffer, which
  carries the wait points; other GPU reads use `ReadFence`, CPU reads check
  `AcquireWait.ready`.

## Shared UI

* Widget callbacks carry `owner` + `id`: a stable host pointer that outlives
  the tree, never a global. Finish state updates before calling back, reset
  the dispatcher on rebuild, defer host destruction until dispatch returns.
* `ui/widgets/` owns every control's look (fields, buttons, dialogs,
  checkboxes, toggles, scrollbars, sliders, battery badge): never hand-draw or
  hand-hit-test one (`src/ui/AGENTS.md`).
* App clients (Files, Images, PDF) draw through `ui/cairo.zig` with theme
  tokens (`app_*`, `shellPalette().accent`) and shell icons. Text is
  the effective `window_fg` (placeholder at half alpha) at `text_size`,
  `heading_size` or `status_size`, never hardcoded sizes. Load the theme with
  `files/settings.zig` before the first frame (PDF: before its sandbox).
  That loader resolves `Theme.forApp()` so `app_fg`, menu and field overrides
  can differ from compositor chrome; sidebar text uses `sidebarForeground()`.
* Secrets live in `secret_input.Input` over caller-owned mlocked storage;
  hand-laid secret fields draw the caret with `CaretOverlay`.
* **Dead keys:** `xkb_state_key_get_utf8` returns nothing for them, so any
  code turning xkb presses into text feeds `ui.compose.Compose` first (shared
  lazy table from the user's language: ´+c is ç in `pt_BR`, ć elsewhere):
  `Keyboard.composeShell` for compositor fields, `deliverKey` in app clients.
  Reset on focus loss or Ctrl/Alt, no repeat for a consumed key
  (`willConsume`/`consumed`), `compose.preload` before a sandbox closes the
  filesystem (PDF). `tests/dead_keys.py`.

## Build and platform

* `ui`, `dbus` and `config` are named modules with one-way dependencies (no
  compositor imports). Parsing/persistence is `config/`, applying and reloads
  `config_runtime/`, shared raster code (`text`, `anim`, `sdf`, icons) `ui/`.
  `memory` owns the process allocator; executables own its shutdown.
* **OS calls go through `src/platform/`**: use it, not `pidfd_*`, `inotify_*`
  or `/proc/self/exe` (C and C++: its `child.h`, `self_exe.h`).
* Zig 0.17 has no `@cImport`: the build translates header roots in `src/c/`
  into modules (`support.cHeaders`): `c` (libc), `c_gfx` (libc, cairo,
  freetype, harfbuzz, fontconfig, xkbcommon), `c_pulse`, `c_libinput`,
  `c_png`, `c_archive`. Add a header to its root; a module links nothing, so
  artifacts link their libraries. The roots undefine `_FORTIFY_SOURCE`
  (fortified wrappers break translate-c in ReleaseSafe) and define
  `_GNU_SOURCE`, so socket calls take `.{ .__sockaddr__ = @ptrCast(&addr) }`.
  Never translate glib/gobject/gio/librsvg; hand-declare the ABI. No runtime
  `parseColor()` in comptime defaults.
* `std.os.linux.*` return `-errno` in `usize` (`std.os.linux.errno`);
  `std.posix.system.*` are libc (`std.posix.errno`).
* **wlroots bindings** live in `src/wlr/`, backed by one translation of
  the installed headers (`src/wlr/c.h`, module `wlr_c`); read `src/wlr/AGENTS.md` before extending them.
  `ext.*`/`wp.*` Wayland types need their protocol in `build/protocols.zig`.
  Nullable outputs/buffers are represented explicitly. Full layout checks
  protect embedded input devices, so no extra Pointer padding is needed.
  `zig build test-wlroots` validates every exported binding and C input-device
  initialization; it also runs as part of `zig build test`.
* Debug `main.gpa` is `DebugAllocator`: freed memory reads `0xaa…` (glibc
  `MALLOC_PERTURB_`: `0xa5…`), leaks print at exit in the compositor log. Free
  process-lifetime caches in `main.start`'s defers; state workers read during
  shutdown comes from `std.heap.c_allocator`. Never mix allocators.
* Cairo `ARGB32` is premultiplied `0xAARRGGBB`, like our buffers. `png.zig`
  reads only 8-bpc non-interlaced truecolour(+alpha). Read
  `/sys/class/power_supply/*/uevent` only on uevents and the minute tick.
