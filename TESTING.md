# Testing

```sh
umask 077
zig build
zig build -Doptimize=ReleaseSafe --prefix zig-out/release-safe
zig build test
python3 tests/<name>.py
```

`zig build test-video-integration` runs the video suite with generated FFmpeg
clips and a paced null audio device. It checks VAAPI and shm pixels, software
fallback, frame steps, keyframe scrubbing, volume and mute, playback rate
and idle threads. It checks external SRT selection, multiline captions and
cue changes between video frames. It drives the real Files chooser and a Wayland
URI-list source, checks the fullscreen cursor and inspects the player’s idle inhibitor.
Use `WLR_RENDER_DRM_DEVICE` to select each GPU on a hybrid system.
`python3 tests/video.py` runs the silent subset with the installed player.

`python3 tests/fifo.py` checks commit-timing-v1 deadlines against presentation
feedback, ordered timed and untimed commits, timer destruction, and synchronized
subsurfaces. The video integration suite also compares the player's requested and
actual presentation times. Headless runs exercise the deadline fallback. Testing
the fixed-refresh prediction requires a physical DRM output with hardware vblank
timestamps.

The long-running Files archive benchmark is skipped by default. Run it with:

```sh
REDIWM_RUN_BENCHMARKS=1 zig build bench-files-archive
```

The Files I/O responsiveness measurement (S5) is opt-in the same way. It runs
the production I/O service under heavy copies and an extraction and reports the
UI thread's cost and each job's progress; its settings are at the top of
`src/files/io_bench_tests.zig`:

```sh
REDIWM_RUN_BENCHMARKS=1 REDIWM_IO_BENCH_DIR=/path/on/target/fs zig build bench-files-io
```

`zig build test-wlroots` checks the complete exported wlroots API against the
installed headers and tests embedded input-device lifecycles; it is included
in `zig build test`.

`zig build test-platform` runs the OS-specific parts (`src/platform/`: child
handles, file watching, own executable path) against real processes and
temporary directories.

`zig build test-login-manager` tests ConsoleKit2 session ownership, identity
rejection and private user-bus startup against independent private-bus peers.

`tools/freebsd-cross/check.sh [-Doptimize=ReleaseSafe | test]` cross-builds the
tree for FreeBSD on this host (Arch, `bwrap`); run it after touching OS
interfaces, C headers or `src/platform/`. It proves compilation only.

Run affected integration suites after building. Find suites and flags in
[tests/](tests/) and build targets in [build/tests.zig](build/tests.zig).
Compare failures with a clean HEAD worktree before calling them regressions.

`python3 tests/scrolling.py` exercises keyboard scrolling, layer
order, modal dialogs, and layout memory across a Canvas round trip and a
restart. Repeat with `REDIWM_TEST_SCALE=1.5` for fractional-scale geometry.
The `outputs` case uses two adjacent mixed-density displays to check that a
column and its popups draw and receive input on their own output. It also
checks surface enter and preferred scale, window transfers and monitor hotplug.
The `direction` case puts a portrait display beside a landscape one: rows
stacked down the portrait strip, arrow keys along and across it, the
`scroll_direction` setting from IPC and Settings, and a strip that moves to the
landscape display and back.
The `gestures` case swipes and two-finger scrolls a strip (1:1 motion, the
release snap and fling, the rubber band), steps columns with the wheel, resizes
columns and windows by dragging, and drops windows between and into columns,
including edge scrolling while dragging. `tests/scrolling_perf.py` adds the
same swipe to its reveal/pan comparison. The `polish` case checks the strip
overview (Super+A, Escape, picking a culled column), the position bar while
the strip moves, and neighbours gliding when a column opens or closes.
Run `python3 tests/scrolling.py x11` with GTK3 and Xwayland to check the first
click and its client-local coordinates on each side of the monitor edge. The
fixture also pauses its private Xwayland process to check queued clicks and
windows disappearing during a handoff.
Use `python3 tests/scrolling_perf.py` after a ReleaseSafe build to compare a
keyboard reveal and a canvas pan over the same windows and distance, and to
measure idle callbacks for culled and hidden windows.

Integration dependencies: Python 3 + Pillow, C compiler, `wayland-scanner`,
wayland-protocols and GLES2; D-Bus suites also need PyGObject,
`dbus-run-session` and `busctl`. Check each suite for extra dependencies.

Run `python3 tests/single_pixel.py` at scales 1 and 1.5 for client alpha and
background blur. Repeat with `REDIWM_NO_GLASS=1` to check the capability event
and rendering with blur disabled. `python3 tests/night_light.py` uses wlsunset
or gammastep when installed to test gamma ownership, rejection and restoration
against simulated per-output gamma tables.

App checks include [calculator](tests/calculator.py), [RediTerm](tests/terminal.py),
[editor](tests/editor.py),
[editor visuals](tests/editor_visuals.py) and
[Files input methods](tests/files_ime.py). Run `python3 tests/text_input_v1.py`
for legacy fields, v3 coexistence, IME reconnect and lock isolation.

Application colors: `python3 tests/app_colors.py` checks snapshot exports and
opt-in following with a private bus, scratch HOME/XDG directories, and real
GTK3/GTK4/Qt5/Qt6 palette probes when installed. It keeps clients open across
theme changes, closes Settings, checks portal publication and compositor restart,
and verifies that disabling following stops exports. Qt probes that preload a
stand-in `libqt<N>_shim.so` check the Chromium colours, also after Dark mode is
switched in Settings. Repeat with
`REDIWM_TEST_SCALE=1.5`. Browser chrome still needs a visual check with isolated
profiles in GTK/Qt/System/Linux theme mode; never use the host browser profile.
For Brave, check the tab strip against the active tab, a context menu's
shortcuts and disabled items, and the print preview (Ctrl+P) with a dropdown
open, with Dark mode both off and on, under a real xdg-desktop-portal with the
rediwm and gtk backends. Brave's Qt mode reads Qt colours only at startup.

SSH keys: `zig build test-keys` and
`dbus-run-session -- python3 tests/keys_settings.py` (repeat with
`REDIWM_TEST_SCALE=1.5`). Fixtures generate OpenSSH and legacy RSA keys in a
scratch home, compare fingerprints with OpenSSH, verify passphrase changes,
and exercise the real Settings fields. They never use the host's keys or
agent. Requires OpenSSH, OpenSSL and `gio`; `GIO_USE_VFS=local` keeps Trash
within the fixture. `--helper-only` skips the compositor; `--bin-dir` selects
the helper and compositor builds together.

Firewall: `zig build test-firewall` (parsers, validation, nftables/pf
rendering), `python3 tests/firewall_helper.py` (the real helper as namespace
root in `unshare -rmn`, against real nftables in an empty network namespace;
config and run directories on tmpfs, nmcli/systemctl/ufw/firewall-cmd
hidden) and `python3 tests/firewall_settings.py` (Settings with a fake pkexec
and helper in a private mount namespace; needs a `/etc/subuid` range; repeat
with `REDIWM_TEST_SCALE=1.5`, `FIREWALL_TEST_SHOTS=<dir>` keeps screenshots).
Neither touches the host firewall. pf output is checked on FreeBSD with
`pfctl -nf`.

Keyboard layouts and input methods: `python3 tests/input_sources.py` starts
its own `dbus-run-session` with a fake Fcitx5 controller; it never reaches the
host's Fcitx. Layout labels need libxkbregistry.

## Isolation and harness

- Use a private headless compositor, temporary home/XDG directories and private
  D-Bus services (`DBUS_SYSTEM_BUS_ADDRESS` points to the fixture bus). Never
  touch host displays, buses, audio, power, printers or real credentials.
- Keep runtime directories private (`umask 077`); isolate `XDG_STATE_HOME`
  (layout autosave), `XDG_DATA_HOME` (recent files) and `XDG_CACHE_HOME`.
  Files suites set `REDIWM_FILES_DEVICES=0` to avoid host disks.
- Reuse [ipc_client.py](tests/ipc_client.py): `IPCClient`, `spawn_compositor`,
  `stop_process`. Custom launch environments need `REDIWM_IPC_AUTOMATION=1`.
  Prefer IPC state/events and `wait_for_frame` over pixels or sleeps; wait for
  `window_geometry_settled` before pointer input or geometry checks.
- Select `WLR_RENDER_DRM_DEVICE` on multi-GPU machines; without hardware use
  Mesa llvmpipe (`WLR_RENDERER_ALLOW_SOFTWARE=1`). Use output screenshots for
  pixels: GLES2 can release CPU buffers after upload.
- Repeat UI checks at `REDIWM_TEST_SCALE=1.5`; supporting suites also accept
  `REDIWM_TEST_OUTPUTS=2`. Check script-specific arguments. Fractional GLES2
  pixels may differ by one level.
- `zig build -Ddamage-audit=true` checks missed damage and stale resolve groups;
  keep logs with `REDIWM_TEST_LOG_DIR`. It disrupts timing-sensitive tests.
- Update IPC expectations explicitly in `src/ipc_serializers.jsonl` and
  `tests/msg_v1.json`; never derive expected results from the implementation.

## Languages and locale correctness

Run `zig build i18n-check`, `zig build i18n-lint`, `zig build test-i18n` and
`python3 tests/i18n.py`. Follow [translation review](po/README.md); generate
private locales with `localedef` + `LOCPATH`, never change host locales.

## Further checks

Measure performance with ReleaseSafe and identical renderer/scale/input settings;
see [scene_baseline.py](tests/scene_baseline.py), [motion_perf.py](tests/motion_perf.py)
and [startup_perf.py](tests/startup_perf.py). Stats requests enable timers and
add overhead; keep CPU comparisons free of them. `frame_time_ms` is the commit
interval; CPU and GPU work overlap, so do not add their timings.

Measure frame scheduling (frame event, render start, commit, presentation, age
of the content shown) with a `-Dframe-trace=true` build and
[frame_latency.py](tests/frame_latency.py), which runs an isolated session or
analyses a traced compositor's log. The option compiles the trace in; normal
builds contain none of it. Headless presents synchronously, so only the cost
columns mean anything there; presentation latency needs DRM (a spare VT) and
the `present flags` line showing vsync with a hardware clock.

Audit memory retention with [memory_retention.py](tests/memory_retention.py):

```sh
python3 tests/memory_retention.py --app files --cycles 50 --out /tmp/files-retention.json
python3 tests/memory_retention.py --app control-center --cycles 50 --out /tmp/settings-retention.json
```

The default binary is `zig-out/release-safe/bin/rediwm`; apps come from the same
directory. Each run uses one private compositor, five warm-up cycles, then
repeatedly opens and closes the same app. It waits for client exit, close
animation teardown and frame barriers before recording PSS, private clean +
dirty memory, swap, scene-node counts, FDs and DRM fdinfo counters. JSON includes
every cycle, growth and slope, baseline/final smaps, binary hash and shutdown
logs. `--scale 1.5`, `--close-mode kill`, `--no-animations` and `--no-glass`
exercise other paths; `--settle` controls the post-close delay (default 1 s).
Scene counts must return to the warmed baseline. Optional
`--max-private-growth-kib` (last five samples' median minus baseline) and
`--max-pss-slope-kib` set machine-specific memory gates. Compare identical builds,
renderer, scale and workload settings: allocator/driver caches can retain a
bounded high-water mark, and PSS varies with other processes sharing pages.
DRM counters are per client (duplicate FDs removed); shared objects can still
appear in multiple clients, and PSS alone cannot establish GPU retention.
Restarting an app measures retention in the compositor, not leaks within a
long-lived app process. Use Debug separately to check shutdown leak reports.

Hardware, login, browser/OBS sharing and toolkit IME checks remain manual. See
[rendering](docs/agent-notes/rendering.md), [tiling qualification](docs/plans/optional-tiling-qualification.md)
and [printer qualification](docs/plans/printers-qualification.md).

Pointer settings: `python3 tests/input_persistence.py` drives the real Settings,
reload, hotplug and restart paths with a noninstalled libinput fixture. Repeat
with `REDIWM_TEST_SCALE=1.5`; set `WLR_RENDER_DRM_DEVICE` on multi-GPU hosts as
above. No host input devices are configured. For manual hardware qualification,
select a touchpad and external mouse in Settings, give them opposite natural
scrolling and different speeds, and verify both in a client. Check tapping,
tap-drag and disable-while-typing on supported hardware. Unplug the selected
mouse with the selector open, reconnect, reload configuration and restart the
compositor; verify each device's values and behavior again. A device identified
by physical path follows its port; see [configuration](README.md#configuration)
for identity limitations.
Check the type icon and friendly name (including a trackball, if available).
An edited control should switch from Default to Custom. Reset one device and
verify that it returns to Default immediately while the others remain unchanged;
then change a global default and check that the reset device inherits it after
reload, reconnection and restart.

Power policy: `python3 tests/power_settings.py` uses private PowerProfiles and
logind services, fake sysfs events, and a fake brightnessctl. Repeat with
`REDIWM_TEST_SCALE=1.5`. Also run `tests/idle.py`, `tests/power.py`,
`tests/power_profiles.py`, `tests/battery_popup.py`, `tests/control_center.py`,
`tests/hardware_keys.py`, `tests/keyboard_backlight.py` (Linux),
`tests/greeter.py`, and `tests/i18n.py`. On hardware,
qualify lid close/open, external-monitor removal with the lid closed, suspend
and resume after unplugging, keyboard lighting and firmware charging-limit
readback. Keep real power actions out of automated tests.

Canvas overview: `python3 tests/overview.py` checks the rendered 2×2 and
2+3 grids, live minimized previews, restoration, pointer and keyboard selection,
hover and wheel magnification of a preview,
consumed input, client teardown, config reload and reduced motion in a private headless session. Repeat with
`REDIWM_TEST_SCALE=1.5 REDIWM_TEST_OUTPUTS=2`. Also run `focus_zoom.py`,
`desktop_zoom.py`, `keyboard_shortcuts.py`, `shortcuts_inhibit.py`,
`pointer_constraints.py` and `switcher_ime.py` after changing its input routing.

## Video player DRM benchmark

`tests/video_bench.py --live-output` briefly opens fullscreen windows on the
named physical output in a running RediWM session. The default four paired
rounds take about 4½ minutes. Use a quiet machine on AC. The harness holds
RediWM's temporary screensaver inhibitor during the run and releases it on
exit, including on interruption. It requires Linux, FFmpeg, mpv with
`dmabuf-wayland`, Python with PyGObject, a readable Intel package-0 RAPL
counter, and the selected GPU's per-client DRM video-engine counters.

```sh
zig build -Doptimize=ReleaseSafe --prefix zig-out/release-safe
ffmpeg -hide_banner -loglevel error -nostdin -f lavfi \
  -i testsrc2=size=1920x1080:rate=60:duration=40 -vf scale=out_color_matrix=bt709 \
  -an -c:v libx264 -threads 6 -preset veryfast -crf 20 -g 120 -bf 3 \
  -pix_fmt yuv420p -color_range tv -colorspace bt709 -color_primaries bt709 \
  -color_trc bt709 /tmp/phase2-1080p60.mp4
python3 tests/video_bench.py --live-output eDP-1 --render-node /dev/dri/renderD128 \
  --clip /tmp/phase2-1080p60.mp4 --json /tmp/video-drm.json
```

Use the actual connector and render node. Each player gets the same clip,
window geometry and settling period. The sampler reads process CPU, per-thread
paused context switches, decode-engine time and package energy at the edges
of each interval. It checks fullscreen ownership, output state, VAAPI and
media progress. Native progress uses packet DTS at the demuxer's read head.
mpv exposes its media clock. `--state paused` repeats just the idle samples.
`--headless` in place of `--live-output NAME` exercises the harness in a
private compositor. Physical measurements and raw samples are in the
[player plan](docs/plans/video-player.md#phase-2-measurements).

## HDR qualification

Run `zig build test-hdr` with a GLES2 render node. Select it with
`WLR_RENDER_DRM_DEVICE` on a multi-GPU machine. The fixture checks linear
composition, absolute PQ values at several desktop white levels, the SDR
capture shoulder and 10-bit targets where available. On drivers that import
linear NV12 or P010 it also checks BT.601, BT.709 and BT.2020 in both ranges.
Record any skipped formats with the driver and device.

Run `python3 tests/hdr_content.py` and `python3 tests/hdr_linear.py` at
`REDIWM_TEST_SCALE=1` and `1.5`. The former attaches a five-bar buffer once,
changes its Wayland description on successive commits, and compares the raw
and SDR IPC samples with independent transfer functions and gamut matrices.
Add `--mpv` to the content test for a real gpu-next Wayland Vulkan client
with a lossless HDR pattern (requires FFmpeg and mpv). The raw IPC reply
reports the signal code in eight bits per channel. The linear test checks
retained damage, capture protocols and a mixed-output desktop. Run
`python3 tests/hdr_linear.py --ten-bit-capture` on a GPU that offers 10-bit
shm readback to exercise the recorder protocols with a 10-bit swapchain.
On a headless or nested output the final signal is SDR.

For idle cost, use identical ReleaseSafe builds, one render node, and a quiet
machine on AC. Run `python3 tests/hdr_idle.py --baseline /path/to/phase5/rediwm`.
It alternates the baseline and candidate in fresh 1280×720 sessions and reports
CPU as a percentage of one core, thread switches per second, process
memory and DRM memory by client. The default is three 15-second samples per
build and setting. GPU buffers can also be mapped into the process, so compare
DRM residency and PSS separately.

The 2026-11-24 reference run used Intel i915 and one headless GLES2
output at scale 1. Each row shows the median of three 15-second idle runs
with no recorder or video playing. Phase 5 is commit `bc268ec`.

| Build | HDR setting | CPU, % of one core | Thread switches/s | PSS, MiB | Private, MiB | i915 resident, MiB |
|---|---|---:|---:|---:|---:|---:|
| Phase 5 | off | 0.039 | 2.00 | 64.87 | 55.33 | 20.66 |
| Phase 5 | on | 0.027 | 0.87 | 70.38 | 60.51 | 30.21 |
| Phases 4 + 6 | off | 0.031 | 0.80 | 65.59 | 55.28 | 20.66 |
| Phases 4 + 6 | on | 0.046 | 1.07 | 71.02 | 60.15 | 30.21 |

### On a physical HDR10 display

Use a dedicated DRM session with IPC automation enabled for the probes. Record
GPU, driver, kernel, connector, mode, refresh, EDID luminance and monitor
picture mode alongside the results.

1. Record the EDID with `edid-decode` and the connector properties and plane
   formats with `drm_info`. Enable HDR in Settings. Confirm `hdr_supported`
   and `hdr_active` in `rediwm-msg outputs`, 10-bit output, PQ metadata,
   BT.2020 signalling and the monitor's HDR indicator. Toggle off and on,
   change mode, and check the SDR return and any `hdr_refused` log.
2. With a normal output transform, neutral night light and the pointer clear
   of the bars, run `python3 tests/hdr_content.py --live-output DP-1` using
   the actual connector name. The probe opens a temporary fullscreen client.
   Run it with HDR off and on. If the display caps white, supply the logged
   value with `--effective-white NITS`. Repeat at another SDR white level.
   The PQ bars keep their absolute codes while SDR white follows the setting.
   Compare the monitor with a known HDR reference still or a colorimeter.
3. Play HDR10 video in mpv, enable HDR in a Proton game using its Wayland
   driver, and play HDR video in a browser. Check dark detail, saturated
   colours, highlights and SDR UI. Move each client across an HDR/SDR pair,
   including a window straddling the seam. Change HDR while it stays mapped.
   Compare fullscreen direct scanout with a composited frame and repeat
   with night light on. Check the software cursor and gamma-client refusal.
   For a game with washed-out colors, record its Proton version and the
   window's `id` and `backend` from `rediwm-msg --json windows`. With the
   game's HDR mode enabled, run `rediwm-msg --json window-debug <id>` and
   inspect `surface_colors` for the game-sized buffer, including subsurfaces.
   HDR10 reports `st2084_pq` and `bt2020`. Null values identify an untagged
   surface that RediWM treats as SDR. Record `rediwm-msg --json outputs`
   alongside this to distinguish the game submission from the monitor signal.
4. Check a screenshot, grim, window and monitor portal shares, and a recording
   in OBS or wf-recorder. Compare SDR highlights and skin tones on an SDR
   display. Lock and unlock during a share, then unplug and reconnect the
   HDR monitor. Check capture denial while locked, correct preferred colours
   after reconnect, and SDR output in the greeter.
