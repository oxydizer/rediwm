# Testing

```sh
umask 077
zig build
zig build -Doptimize=ReleaseSafe --prefix zig-out/release-safe
zig build test
python3 tests/<name>.py
```

`zig build test-wlroots` checks the complete exported wlroots API against the
installed headers and tests embedded input-device lifecycles; it is included
in `zig build test`.

`zig build test-platform` runs the OS-specific parts (`src/platform/`: child
handles, file watching, own executable path) against real processes and
temporary directories.

Run affected integration suites after building. Find suites and flags in
[tests/](tests/) and build targets in [build/tests.zig](build/tests.zig).
Compare failures with a clean HEAD worktree before calling them regressions.
Integration dependencies: Python 3 + Pillow, C compiler, `wayland-scanner`,
wayland-protocols and GLES2; D-Bus suites also need PyGObject,
`dbus-run-session` and `busctl`. Check each suite for extra dependencies.
App checks include [calculator](tests/calculator.py), [editor](tests/editor.py)
and [editor visuals](tests/editor_visuals.py).

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
`tests/hardware_keys.py`, `tests/greeter.py`, and `tests/i18n.py`. On hardware,
qualify lid close/open, external-monitor removal with the lid closed, suspend
and resume after unplugging, keyboard lighting and firmware charging-limit
readback. Keep real power actions out of automated tests.
