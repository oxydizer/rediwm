# Lock internals

Cross-cutting lock rules (greeter, crash handling, IPC refusal, client
ext-session-lock) are in the root `AGENTS.md`.

* Login-service calls go through `login_manager.zig`; its backend owns method
  signatures, service names, signal descriptors and login identity checks.
  `power_*` retains policy and owner generations: pin session/inhibitor calls
  to that owner, ignore stale replies, and follow only this session's `Lock`.
  The recording transport tests live in `login_manager/tests.zig`; private-bus
  coverage is `tests/power.py`, `polkit.py` and `session_bus.py`.
  FreeBSD selects ConsoleKit2. Its session cookie and connection belong to
  the supervisor, survive compositor restarts and close on rejection/exit.
  Failed verification exports no login identity or inherited cookie. Its
  noninstalled private-bus fixture is `tests/consolekit.py` (`test-login-manager`).
* The supervisor's process and signal calls go through `platform.login_*`;
  descendant enumeration goes through `system_monitor/proc.zig`. Recheck
  FreeBSD start stamps after opening handles. `user_bus.zig` starts a missing
  user bus before the supervisor snapshots preexisting children, and stops it
  only after the session. `private_publication.zig` updates that bus without
  systemd's shared-manager lease.

* Login appearance is a flattened snapshot in
  `/var/lib/rediwm-appearance/<uid>/`, provisioned by the DM and written by
  that account's real desktop session. `login_appearance.zig` reads only
  bounded regular files with matching ownership and no symlinks. Never load
  a user's config or discover packs in the greeter. Account changes reset
  the palette and wallpaper before loading the next snapshot.

* **Idle inhibitors** come from two places: idle-inhibit-v1 surfaces count
  only while visible (re-checked on map, move, minimize, camera and output
  changes); `org.freedesktop.ScreenSaver` (`screensaver_service.zig`, on the
  notifications bus connection, so never in the greeter) counts regardless of
  visibility until UnInhibit or its sender leaves the bus. Chromium makes its
  surface inhibitor only on a window with pointer or keyboard focus and never
  retries, so the bus path is what keeps videos awake.

* `Lock.covered()` releases the lock-before-sleep inhibitor; the builtin lock
  also sets `Output.lock_commit_pending`.

* **The lock never polls.** Its one timer redraws the clock at the next minute
  boundary; the PAM worker (`auth.c`) signals an eventfd that `Lock.authReady`
  watches only while an attempt runs. Don't add a periodic tick (a 100 ms one
  cost ~10 wakeups/s for as long as the session stayed locked).
* **Lock volume/brightness** (`lock_controls.zig`): sliders at the bottom
  centre of the built-in lock, the pointer/touch way to what the hardware keys
  already do behind it. Never in the greeter (no audio, no external tools) and
  hidden under an ext-session-lock client's surface. They are their own small
  raster (`View.controls_node`), so a drag never re-rasters the clock, avatar
  and field. A row exists only while its backend reports
  (`Lock.controlsChanged` from the audio wake and the brightness helper's
  result); a drag shows its own value until release. Only the row selected by
  pointer use or hardware feedback is painted; both pointer regions retain
  their positions. Hardware volume/brightness OSDs use `Lock.showControl`
  rather than drawing another overlay. Backend reports alone don't reveal
  controls. The clock timer also handles their idle timeout; no polling.
