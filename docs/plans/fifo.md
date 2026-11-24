# fifo-v1 in RediWM

Status: implemented on `feat/fifo-v1` (2026-11-24, uncommitted). Headless,
Debug and ReleaseSafe verified, including Mesa's Vulkan WSI. A DRM run on real
hardware is still open (see the end).

## Why ourselves

`wp_fifo_v1` (wayland-protocols staging) lets a content update wait until the
surface's previous update has been on screen for one refresh. Mesa's Vulkan
WSI uses it for `VK_PRESENT_MODE_FIFO_KHR`. SDL3 uses it for vsync, and it no
longer requires commit-timing-v1 alongside it. wlroots 0.20.2 has no
implementation. The upstream one, wlroots MR !4463 (sway PR #8371), was still
open on 2026-11-12, and its glue code hooks into wlr_scene, which RediWM has
replaced. The pieces it needs are public in 0.20 and already bound in
`src/wlr/compositor.zig`: `wlr_surface_synced`, `events.client_commit` and
`wlr_surface_lock_pending`/`unlock_cached`.

Mesa 26.2 with fifo-v1 offered requests **no frame callbacks at all**: barriers
are its only pacing. That decides two things. Hidden surfaces must still be
throttled (D2), and the barrier must clear at real refresh boundaries.

## Decisions (accepted 2026-11-24)

* **D1:** hidden surfaces are released at 20 Hz (`Fifo.hidden_period_ns`).
* **D2:** hidden surfaces are throttled, not ignored.
* **D3:** no early latch for updates that may tear. A torn flip is not a
  latch, so a FIFO surface on a tearing output falls back to the late release.
* **Release point** (review): barriers clear on a dedicated per-output
  latch, not on frame callbacks. `Output.latch_seq` is bumped by
  `output/frame.zig` on a successful non-tearing buffer commit
  (`commitFrameState`) and on the `vblank_timer` refresh after a skipped
  commit (`handleVblank`). Late render sends frame callbacks before it
  renders, so callbacks would release an update a refresh early. Fallbacks
  are separate and counted: `hidden` (no pacing output, 20 Hz) and `late`
  (shown, but no latch within two refreshes + 1 ms, so the client keeps
  making progress).

## How it works (`src/fifo.zig`)

* **State.** The double-buffered `set_barrier`/`wait_barrier` bits are a
  `wlr_surface_synced` state. The bookkeeping, `Fifo.Barriers`, works in
  wlroots' per-surface state sequence numbers (they start at 1 and carry into
  `current`). It tracks the latest committed `set_barrier` (`last_set`), the
  latest applied one (`applied`/`armed`) and the latest cleared one
  (`cleared`). It has no wlroots calls and is unit tested in
  `fifo_tests.zig`.
* **Hold.** On `client_commit`, an update with `wait_barrier` is held when
  the latest earlier `set_barrier` has not cleared, *even if that barrier has
  not been applied yet* (it may still sit behind an explicit-sync acquire
  point). The upstream MR checks only the applied barrier, so there the two
  updates land in the same refresh. A held update is locked with
  `wlr_surface_lock_pending`, so wlroots keeps every later commit cached
  behind it, in order. Waits from a synchronized subsurface, directly or
  through a parent (wlroots' `subsurface_is_synchronized` walk), are ignored.
  Their `set_barrier` still counts.
* **Apply.** On `commit`, an applied `set_barrier` arms the barrier and
  records its pacing output and that output's `latch_seq`. It then calls
  `Output.frameCallbacksWanted`, so an update that changed nothing still gets
  a latch from the skipped-commit vblank.
* **Latch.** `Manager.latched(output, seq)` clears the armed barriers of the
  surfaces this output paces, unless the barrier was applied at this same
  generation. This is bookkeeping only. The unlocks run from an idle callback,
  because unlocking applies client state synchronously and a latch happens
  inside the output frame.
* **Occlusion.** The pacing output is `rediwm_surface_frame_pacing_output`
  (`node_surface.c`). It comes from the occlusion-aware projection feedback,
  so a surface that is covered, minimized, on another workspace, unmapped or
  on an output that is off has none. One deadline timer serves both
  fallbacks. It is armed only while some surface has an update held behind an
  applied barrier, and disarmed once nothing is held: no idle wakeups.
* **Teardown.** Destroying the fifo unlocks its held updates (the spec says
  earlier state changes are unaffected). On surface destroy, held updates are
  dropped *without* unlocking. wlroots 0.20.2 emits `destroy`, then finishes
  addons, then frees cached states (`surface_handle_resource_destroy`).
  Unlocking there, as the MR's addon destroy does, applies state to a surface
  whose role is gone.
* **Counters.** `rediwm-msg perf` → `fifo: {held, latched, hidden, late}`.

The global is unprivileged (not in `global_filter.zig`), not created in the
greeter, and created after the extra protocols in `server/setup.zig`.
Teardown destroys it after the clients.

## Tests

* `zig build test`: `fifo_tests.zig` covers barriers across two commits,
  release up to the next barrier only, a barrier queued behind another lock,
  the synchronized-subsurface exemption, and sequence wrap.
* `python3 tests/fifo.py` (headless GLES2; the fixture is `tests/fifo_client.c`):
  * Control: 6 commits without fifo collapse into one refresh (5 discarded).
  * 8 back-to-back fifo commits are presented on 8 refreshes (≈16.5 ms apart),
    all cleared by latches.
  * A barrier-only (empty) update is latched by the skipped-commit vblank,
    with no `late` fallback.
  * Synchronized subsurface: exempt (collapses). Desynchronized: paced.
  * Minimized, and covered by an opaque window: 10 held updates released in
    0.52 s (20 Hz) with no `late` releases; pacing resumes after.
  * Explicit sync (GBM dmabuf + drm syncobj): commit 1 sets a barrier but its
    acquire point is unmaterialized; commit 2 waits. Signalling the point
    applies 1, and 2 still reaches a later refresh.
  * Destroying the fifo with updates held lets the last one show. Destroying
    the surface with updates held is survived.
  * Protocol errors: `already_exists`, `surface_destroyed`; a fifo can be made
    again after its destroy.
  * vkcube (Mesa WSI, FIFO): binds fifo-v1, sends 0 frame-callback requests,
    57–58 presents/s shown at 60 Hz, 20.0/s minimized, back to 57–58/s restored.
* Mutation checks. The upstream "applied barrier only" hold rule fails the
  explicit-sync case (`es1` discarded). Dropping the subsurface exemption
  fails the sync-subsurface case. Unlocking on surface destroy (the MR's
  behaviour) did **not** fail anything here: the held states applied to the
  dying surface without a crash or a log line. We still drop them, since the
  role is gone by then.
* Also passing: `wlr_protocols.py` (global listed, advertised once),
  `presentation_time.py`, `explicit_sync.py`, `greeter.py`.

## Open

* DRM run on the laptop: vkcube and an SDL3 game windowed and fullscreen.
  Check pacing at the panel's rate, `fifo.late` staying 0, late render on
  (`[compositor] late_render`), VRR once P2 lands, and the async-flip path
  where the driver allows it.
* Proton/Wine through the Wine Wayland driver (Vulkan via DXVK → Mesa WSI).
