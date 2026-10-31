# Operational greeter readiness

The built-in greeter reports `ready` over its inherited DM connection only
after a frame containing its login UI has actually been presented on an
available output after its black startup veil has cleared, its session is active, its input backend has started, and
usable keyboard and pointer devices are registered. It also requires a login
account, a session choice and a connected DM. A submitted frame, backend start,
headless output, timeout or protocol-injected virtual keyboard cannot satisfy
this gate.

The DM acknowledges this with a distinct `ready` response, preserving any PAM
conversation already in progress. The main DM process then sends `READY=1` and
an operational status to `NOTIFY_SOCKET`, supporting pathname and abstract
Unix sockets. The greeter never receives that socket. Failed notification does
not publish success. Redinit's main-PID notification check remains intact.

The default seat policy is `keyboard-pointer`. For an intentionally
keyboard-only installation, an administrator can set the greeter command in
`/etc/rediwm/dm.conf` to:

```ini
greeter_command = /usr/bin/env REDIWM_GREETER_READY_INPUT=keyboard /usr/bin/rediwm --greeter
```

Use the actual installed binary path. Unknown policy values retain the
conservative keyboard-and-pointer requirement. Keep the policy fixed in every
before/after comparison. A touch-only greeter is not supported by this policy:
the current login field requires a keyboard, and this change adds no onscreen
keyboard. Devices arriving late re-evaluate readiness without polling.

For redinit's built-in interactive greeter, install the matching
`redinit/services/gentoo/rediwm-dm.d/readiness.toml` drop-in beside the imported
service and recompile the graph. Stage 8b must still provide logind, the active
seat, tmpfiles and required ZFS mounts; this drop-in does not implement those
dependencies. Autologin and custom greeters retain the existing simple-service
contract: do not install this drop-in for them. They do not satisfy the
operational-greeter measurement. The default systemd service is unchanged.

Validation commands after building Debug binaries:

```sh
zig build test-dm
python3 tests/dm.py
python3 tests/greeter.py
python3 tests/readiness_input.py
```

`readiness_input.py` runs private compositors and a fake DM, not PAM. It verifies
that a displayed headless greeter without input stays unready, then uses actual
nested Wayland keyboard and pointer events to select a session, enter a dummy
password and submit it. The DM tests separately exercise PAM with private test
stacks and verify notification sender credentials. Neither substitutes for a
physical/VM libinput, logind and real-PAM login acceptance check.

## Where the time goes

The gate above is not relaxed to go faster: the veil must still have cleared.
What the greeter avoids instead, none of which changes a desktop session:

* The reveal is `greeter_reveal_ms` (150 ms), not `session_reveal` (420 ms).
* It does not hold the reveal for the wallpaper decoder when the account's
  snapshot is what it shows.
* It compiles only the programs it draws with. It has no clients and no glass, so
  neither the external nor the blur program; it has no shader cache (it writes
  nothing to disk), so each would be a full compile on every start.
* It loads the cursor theme per output scale only, not also at scale 1.
* wlroots logs at info: debug is over a thousand lines, four `write`s each.

Measured from spawn to `ready` on ReleaseSafe builds, nested in a private headless
parent on an Intel render node (10 runs, warm page cache): 732 to 405 ms at scale 1,
741 to 427 ms at scale 1.5, and 872 to 400 ms when the wallpaper decoder is slower
than the hold. About 80 ms of the nested figure is frame-callback and
presentation-feedback lag, and it has no DRM, libinput or PAM cost, so it is not a
boot figure.

Costs left outside this code, read from the journal of a hybrid Intel/NVIDIA laptop
under systemd (cold boot / logout back to the greeter):

* The first atomic modeset blocks in the kernel for 1.24-1.34 s (five boots), against
  3-8 ms once the panel is already driven. wlroots' modesets are blocking.
* The secondary NVIDIA GPU: glvnd loading its EGL vendor, then a multi-GPU renderer,
  about 450 / 150 ms, even with nothing connected to it.
* `pam_systemd` waits for `user@UID.service`, which the greeter does not use: about
  400 / 130 ms. redinit masks it.
* libinput opening every device: about 200 ms, in both cases.

## Comparing builds

Only compare performance after the same readiness gate and input actions pass
on both builds. Capture the manager's notification timestamp, first presented
frame, and response to keyboard/pointer actions. Logging and diagnostic builds
can alter timings. No speed improvement is established by these tests.
