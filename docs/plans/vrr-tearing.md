# Plan: variable refresh rate and tearing for games

Status: 2026-11-17. D1–D5 decided (as proposed). P1 built (uncommitted);
P0 and P2–P4 not started.

Scope: adaptive sync (VRR: FreeSync, G-Sync Compatible, VESA Adaptive-Sync)
per DRM output, making the tearing support we already have reliable, and a
frame path that serves a fullscreen game on both. Out of scope: nested and
headless sessions (no VRR, and headless presents synchronously), HDR
(`hdr.md`), frame limiters (a client or MangoHud job), fifo-v1 and
commit-timing-v1 (not in installed wlroots 0.20; revisit when they land).

"VSync" itself is the client's choice: Vulkan FIFO, MAILBOX or IMMEDIATE, GL
swap interval. The compositor's part is to pace FIFO clients with frame
callbacks (it does), let VRR follow their frame rate, and honour the
tearing hint that IMMEDIATE sends.

## Where we are

**Tearing exists, as a global opt-in.**

* `[compositor] allow_tearing = false` (`config/default.zig:131`), with no
  Settings control.
* `extra_protocols.c` creates `wp_tearing_control_manager_v1`;
  `rediwm_protocols_tearing` reads a surface's hint.
* `Output.tearingAllowed` (`output/frame.zig:169`) allows it only for the
  keyboard-focused toplevel that is fullscreen, in the world, on this output,
  and has asked for `async`. It is never allowed while locked, during a polkit
  dialog or in the greeter.
* `commitFrameState` sets `state.tearing_page_flip`, tests the state and
  commits. `handleSurfaceCommit` → `queueTearing` renders from an idle
  callback as soon as the previous flip is done, so it does not wait for a
  frame event.
* **The gap: rejection is permanent.** One failed test or commit sets
  `output.tearing_rejected`, and nothing clears it until the compositor
  restarts. Atomic async flips may change only the primary plane's
  `FB_ID`, so any frame that also moves the hardware cursor, changes the
  colour transform (night light), or uses a buffer whose modifier the driver
  cannot flip asynchronously (i915 restricts these) fails. One cursor move
  in a game menu turns tearing off for the rest of the session, and nothing
  reports it.
* `late_render` already steps aside for tearing and VRR (`output/late.zig:33`).
* `tests/wlr_protocols.py` checks only that the global is advertised and
  takes a hint.

**Adaptive sync does not exist.** The bindings are there
(`wlr.Output.State.setAdaptiveSyncEnabled`, `adaptive_sync_supported`,
`adaptive_sync_status`), but nothing sets them. `OutputConfig` has no key for
it, `output_config.Patch` has no field, Settings → Display has no row, and
`output_management.zig` ignores a client's `adaptive_sync_enabled` (so
`wlr-randr --adaptive-sync on` does nothing).

**Direct scanout exists** (`scene_output.c:102`): one opaque surface covering
the whole output, unclipped, undimmed, at opacity 1, with matching colour
description. A fullscreen game is the case it was built for. The plan does not
change it, but it checks that games actually reach it (P0).

## Hardware facts (this machine)

* Laptop panel `eDP-1` is on the Intel GPU (card1) and reports
  `vrr_capable = 1` (`modetest -M i915 -c`). VRR can be tested locally.
* The NVIDIA GPU (card0) drives the HDMI/DP connectors, so an external
  G-Sync monitor goes through `nvidia-drm` (`modeset=Y`). Games on the
  laptop panel rendered on NVIDIA (PRIME offload) arrive as cross-GPU
  buffers that wlroots copies, so **they never scan out directly**. Tearing
  and VRR still work on the composited frame.
* Kernel 7.2, Xwayland 24.1.14. Xwayland has passed Present async flips on
  as `wp_tearing_control` hints since 23.2, so X11/Proton games go through the
  same path as native ones, provided `Toplevel.fromSurface` resolves the
  focused Xwayland surface (it should: `toplevel.surface()` covers X11).

## Design

### Adaptive sync: one mode per output

Per-output key `adaptive_sync = "off" | "auto" | "always"` in `[[output]]`
(see D1 for the default).

* **always**: requested on every enable and modeset. The desktop then runs
  at variable rate too. When nothing changes we commit nothing, so the panel
  falls to its minimum rate and returns to the maximum for an animation. Some
  panels flicker in brightness at that boundary, which is why this is not the
  default.
* **auto**: on while the output shows a *game-like* window (below), off
  otherwise. KDE's "Automatic" and Hyprland's `vrr = 2` do the same.
* **off**: never.

A window counts as game-like when it is the keyboard-focused toplevel on this
output, in the world, not minimized or tab-hidden, and either fullscreen or
(D3) an undecorated window that exactly covers the output, the
"borderless windowed" mode many games default to. The same predicate replaces
the fullscreen test in `tearingAllowed`, so VRR, tearing and their reporting
agree on one rule. It moves to its own `output/game.zig` so both callers use
it.

**Applying.** A pure function `vrr.wanted(mode, supported, game_like,
locked, greeter)` → bool, tested in `vrr_tests.zig` like
`late_render_tests.zig`. The output re-evaluates it on focus change,
fullscreen enter/exit, workspace switch end, window move between outputs,
lock/unlock and config reload. It does **not** do this on every commit. When
the wanted state differs from `adaptive_sync_status`, it puts the change on
the next frame's state (`buildOutputState`), not on a separate commit, so it
rides a normal page flip.

* **Turning off is debounced** (about 500 ms). Alt-tabbing to a chat window
  and back should not toggle twice. Turning on is immediate.
* **A change that needs a modeset is not made automatically.** wlroots
  allows a modeset only when the state changes the mode or enablement, so a
  driver that cannot toggle `VRR_ENABLED` seamlessly fails `testState`. In
  that case `auto` marks the output as needing a modeset for VRR, keeps the
  current state, and Settings says so. `always` and `off` still work, because
  they are applied at a modeset anyway. P0 finds out which side i915 and
  nvidia-drm are on.
* An enabled request that comes back `.disabled` (unsupported panel, or a
  driver refusal) is remembered per mode, as night light's colour transform
  is, and logged once.

**Plumbing.**

* `OutputConfig.adaptive_sync` and its loader field.
* A `Patch.adaptive_sync` field, applied in `applyAndPersist` and persisted
  like `transform`.
* `output_management.zig`: when a client sets `adaptive_sync_enabled`,
  `diff` maps it to `always` or `off`, and the head reports the real
  status back.
* Hotplug and mode restore apply the saved mode.

### Tearing: per-frame fallback instead of a permanent flag

* Drop the sticky `tearing_rejected`. A failed async test makes **this
  frame** synchronous, nothing more. Count consecutive failures. After about
  30 in a row (a buffer the driver will never flip asynchronously), pause
  async attempts on that output for a few seconds with backoff, and log the
  reason once per pause. Late render's missed-deadline backoff works the
  same way. Each failed test costs an extra atomic test commit, which is why
  it should not repeat forever.
* Classify the cheap cases before testing. If the frame's state has a
  committed colour transform, a mode change, or a cursor plane change, go
  synchronous without spending a test. Getting the cursor information depends
  on what `wlr_output_state` exposes: check in P0.
* Optional, if P0 shows cursor moves are the common failure: while tearing
  is active, hold a cursor-only change for the next client commit. Games
  commit at hundreds of fps, so the delay is under a frame. A cursor still
  hidden gets its update within one refresh period, from the vblank timer.
* VRR and tearing combine. With both on, frames under the maximum refresh
  arrive whole at a variable rate, and only frames above it tear. That is
  what "G-Sync + uncapped" players expect. Nothing here makes one exclude
  the other (D4).

### Frame pacing under VRR

Most of the path is already right. A fullscreen client commit schedules a
frame, the frame event fires at once if no flip is pending, and the frame
callbacks go out after the flip, so a FIFO game runs at its own rate up to
the maximum refresh, and the panel follows. Three things to check and, if
needed, fix:

1. **Cursor-only commits.** A moving hardware cursor makes us commit at
   pointer rate. Under VRR each commit starts a refresh early, so a 40 fps
   game with a moving cursor stutters. Mutter throttles cursor updates
   under VRR. Here, while VRR is active on the output with a game-like
   window, a cursor-only change waits for the next content frame or at most
   one minimum-refresh period (the panel's lowest rate, from EDID through
   wlroots if exposed, else 1/48 s).
2. **Compositor animations over a game** (OSD, notifications, the dock
   revealing) drive commits at the maximum rate while they run. That is fine:
   they are short and the game is composited behind them. They must not
   leave something ticking afterwards. The panel-tick edge-trigger rule
   already covers this; verify with the frame trace.
3. **`deferFrameDone` and the vblank timer** estimate the next vblank from
   `refresh` (the maximum). Under VRR that is the earliest possible next
   flip, which is the right pace for callback-only commits. No change
   expected; confirm in the trace.

### Reporting

* IPC `outputs`: an `adaptive_sync` object with `mode`, `supported`,
  `wanted` and `active` (the wlroots status), plus `needs_modeset`.
  Tearing gets `allowed` (the policy), `active` (the last flip was async)
  and `paused_reason`. A `direct_scanout` bool is added too. The policy
  fields work headless, which is what makes integration tests possible
  there.
* `ipc/stats.zig`: `async_flips`, `async_fallbacks`, `vrr_toggles`.
* Frame trace (`output/frame_trace.zig`): tag each committed frame as
  sync/async and scanout/composited, so a DRM run can show present intervals
  following the game.

### Settings → Display

* Per output: a **Variable refresh rate** select (Off / Automatic / Always),
  disabled and labelled "Not supported by this display" when
  `adaptive_sync_supported` is false. When `needs_modeset` is set it adds a
  note that Automatic needs the display to switch modes, so Always or Off is
  recommended. The new row goes through a new `row_*` slot constant and
  `layout.appendRow`, never a raw index.
* Global, below the outputs: an **Allow tearing in fullscreen games**
  toggle for `allow_tearing`, with one line explaining that games must ask
  for it (their "VSync off" or "Immediate" setting).

## Phases

**P0 facts (on the laptop's VT; nothing committed).** Record each in this
plan.

* Does i915 toggle `VRR_ENABLED` on eDP-1 without a modeset? Test with a
  scratch build that flips it in `buildOutputState` and checks `testState`;
  read the property back with `modetest -p`.
* Does an async flip pass on i915 for our composited swapchain buffer, and
  for a scanned-out client buffer (`vkcube --present_mode 0` on Intel)?
* What fails while the cursor moves? Can `wlr_output_state` tell us a frame
  carries a cursor change?
* Is a Proton or Xwayland game (`vblank_mode=0 glxgears` fullscreen, a Steam
  title) recognised by `tearingAllowed`, and does it get its hint through?
* Does a fullscreen native game reach direct scanout (`Direct scan-out
  enabled` in the debug log), and on NVIDIA offload confirm that it doesn't?
* If an external VRR monitor is at hand: run the same checks on
  nvidia-drm.

**P1 tearing that stays on.**

* Per-frame fallback with backoff, the pre-test classification, the
  `output/game.zig` predicate (with D3), the IPC/stats fields and the
  Settings toggle.
* Tests: `tests/wlr_protocols.py` grows a case in which a fullscreen fixture
  with the async hint makes IPC report `allowed = true`, and unfocusing or
  leaving fullscreen makes it false. A unit test checks that the fallback
  counter pauses and resumes.

**P2 adaptive sync.**

* Config key, Patch, `applyAndPersist`, output-management mapping,
  `vrr.zig` policy + `vrr_tests.zig`, application on the frame state,
  debounce, modeset detection, and the Settings row.
* Tests: unit tests for the policy and debounce. A headless integration case
  checks that `wanted` follows fullscreen in `auto` while `supported` stays
  false, and that `wlr-randr`-style output management persists the mode.

**P3 pacing under VRR.**

* Cursor throttle, the frame-trace tags, then a DRM run: vkcube at a
  45 fps cap fullscreen on eDP-1 with `auto`, with the trace showing ~22 ms
  present intervals and `active = true`; idle desktop back at fixed rate after
  the debounce. Add the run as a mode of `tests/frame_latency.py` (DRM only,
  like late render's engaged path).

**P4 docs.** Add a short section to `docs/agent-notes/rendering.md`
(predicate, fallback, where VRR is applied), add the config keys to
`config/default.zig`, and check translations for the new Settings
strings.

Each phase ends with the usual gates: Debug and ReleaseSafe builds, `zig
build test`, `tests/wlr_protocols.py`, `tests/greeter.py` (the greeter must
never toggle VRR or tear), and the display Settings suite. Compare failures
with a HEAD worktree.

## Decisions (taken 2026-11-17, all as proposed)

* **D1 Default mode:** `auto` where VRR is supported, falling back to `off`
  on a driver P0 shows needs a modeset to toggle.
* **D2 Per-app overrides:** none in P1; a `tearing` window rule only if a real
  game needs it.
* **D3 Borderless windowed counts as fullscreen:** yes, an undecorated window
  the client placed (not maximized or tiled) whose frame is exactly the
  output (`output/game.zig`).
* **D4 VRR + tearing together:** yes, no exclusion option.
* **D5 Cursor throttle under VRR:** P3, only if measured stutter.

## P1 as built

* `output/tearing_policy.zig`: the backoff model and its tests (30 refusals
  in a row pause attempts 2 s, doubling to 30 s; a success resets).
* `output/tearing.zig`: `wanted` (policy), `allowed` (minus a pause),
  `frameCanTear` (skips the test commit when the frame changes mode, scale,
  transform, adaptive sync, format, colour transform, image description or
  the hardware cursor), `refused`/`committed`, and the idle `queue` moved from
  `frame.zig`. `Output.tearing_rejected` is gone.
* `output/game.zig`: the game-window predicate (D3).
* IPC: `outputs` gains `tearing_allowed`, `tearing_active`, `tearing_paused`,
  `direct_scanout`; performance stats gain `tearing_async_flips` and
  `tearing_refused_flips`.
* Settings → Displays: an "Allow tearing in games" card; search entry.
* `tests/wlr_protocols.py` checks `tearing_allowed` follows the hint on the
  focused fullscreen window.
* Not verified on DRM yet: that needs P0's run on the VT (does i915 take the
  composited buffer asynchronously, how often the cursor check fires).

## P0 findings (2026-11-21, eDP-1 on i915, kernel 7.2)

* A fullscreen `vkcube --present_mode 0 --gpu_number 0` (Mesa) is recognised
  and sends the async hint, but every asynchronous flip was refused (90
  refused, 0 taken). Cause: the primary plane's `IN_FORMATS_ASYNC` allows
  XR24/AR24 only as LINEAR, X_TILED, Y_TILED and Y_TILED_GEN12_RC_CCS, while
  GBM picked Y_TILED_GEN12_RC_CCS_CC from `IN_FORMATS` for our swapchain.
  wlroots 0.20 does not read `IN_FORMATS_ASYNC`.
* Fix (`scene_output_async.c`): while `tearing.wanted`, the output swapchain
  is rebuilt from its own modifiers intersected with the plane's
  `IN_FORMATS_ASYNC` (read with libdrm on wlroots' non-master fd), and
  rebuilt with the defaults when no game wants to tear. The session log says
  "tearing buffers use N of M modifiers (asynchronous flip test passed)".
* Windowed vkcube on NVIDIA (PRIME) was never a game window: fullscreen it to
  test. Whether NVIDIA's Vulkan WSI sends the async hint is still unknown.
* Retest with the async swapchain (buffers now Y_TILED_GEN12_RC_CCS): still
  every flip refused. Kernel debug (`drm.debug=0x14`) names the remaining
  cause: `intel_atomic_check: [PLANE:cursor A] async flip not supported`.
  i915 refuses an atomic async commit that contains any non-primary plane,
  and wlroots 0.20.2 (`backend/drm/atomic.c`, `atomic_connector_add`) writes
  the cursor plane's properties into every commit, visible or disabled
  (`plane_disable` still sets FB_ID/CRTC_ID). A software cursor (KWin's
  workaround) therefore does not help here. The `No prop can be changed
  during async flip` lines for FB_ID, FB_DAMAGE_CLIPS and IN_FENCE_FD are
  informational: the core allows those three on the primary plane.
  Upstream: i915 issue 13834; a 2025 i915 patch would allow no-op planes.
* Decision (2026-11-21): keep the async swapchain, and stop tearing on an
  output whose driver refuses the first whole run of 30 flips without ever
  taking one (`Backoff.gaveUp`): attempts stop for the session, the tearing
  buffers are released and IPC reports `tearing_paused`. No driver list, so a
  fixed kernel needs no change here. Revisit with a DRM run once the i915 fix
  lands (or wlroots stops writing an unchanged cursor plane in async commits).
