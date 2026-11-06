# FreeBSD support plan

Status: 2026-11-06, FreeBSD 15.1 only (D1). The tree builds there and the
compositor and apps run headless on GLES2 over a virtio GPU. What is left is
the login and session stack, the Linux-only interfaces, sandboxes, a few
FreeBSD-only test failures and packaging. D1–D5 are decided, D6 waits for
phase 2, D7–D9 are recommendations.

Goal: run RediWM on FreeBSD: the compositor in a seatd session on DRM, then the
shell features and apps, last `rediwm-dm` and packaging. Linux stays the
primary platform; the port must not change Linux behaviour or cost.

## Done

* **Code:** `src/platform/` owns the OS calls (child handles, file and
  directory watching, own path, peer credentials, process attributes, wake
  descriptors, rename and stat, `kern.proc` process list, tool lookup), each
  with a FreeBSD half except seccomp. The Linux-side preparation (P.1–P.4,
  P.6–P.10) is finished. The IPC allowance check refuses a connector that has
  exited or cannot be seen.
* **On 15.1** (HyprBSD VM, Zig 0.17.1): Debug builds in 2.5 minutes,
  ReleaseSafe in 6.7. `zig build test` passes, and so do `test-monitor` (the
  `kern.proc` backend and kqueue End/Force), `test-platform`, `test-files`,
  `test-dbus`, `test-polkit` and the other no-GPU steps. With a render node
  the Python suites mostly pass (`ipc_automation`, `lock_screen`, `greeter`,
  `files_browser`, `images_viewer`, `editor`, `launch_placeholder`,
  `focus_zoom`, `window_snapping`, most appearance, undo, window-rule and
  protocol suites). Kqueue child handles work in the Wayland loop.
* **Found by running there and fixed:** synthetic input stamped with clock id
  1 (`CLOCK_VIRTUAL` on FreeBSD); Files' `rm --interactive=never`; a Control
  Center crash on a zoomed camera (also on Linux); tests naming `/bin/true`,
  using GCC-16-only C, `SO_PEERCRED`, `setsid --ctty`, `busctl`; `test-polkit`
  not building on Linux at HEAD.
* **Tools:** `tools/freebsd-cross/check.sh` cross-builds the tree from Linux;
  `tools/freebsd-probe/login-probe.sh` reports the login stack;
  `docs/freebsd-build.md` has the package list (checked against the 15.1
  catalogue), build commands and how to run the tests.

## Still failing or unknown on FreeBSD

* Pixel-comparison suites `start_menu`, `zoom_osd`, `screenshot_tool` and `dock`
  pass on Linux and fail on the VM (virgl against the host's renderer is the
  suspect; not looked into). `theme_packs` fails because the parser sandbox
  refuses (D4). `system_monitor.py` is Linux only (seccomp guard, `/proc`) and
  needs a FreeBSD variant; `motion_perf`, `editor_visuals`, `battery_*`,
  `pdf_sandbox` and `steamos_bundle` are Linux only too. The other failures
  also fail on Linux at HEAD.
* Not tried: a DRM session on real or virtual hardware, a nested session under
  Hyprland, `rediwm-msg` outside the tests, `memfd_create`, the transfers
  helper's C++ flags under clang and libc++.
* Name order follows FreeBSD's libc (`de_DE` is a link to `en_US`, Cyrillic has
  no usable weights); the German and Russian order tests skip off Linux (D7).

## Interfaces still to port

| Linux interface | Where | FreeBSD |
| --- | --- | --- |
| pidfd in `child.h` (the C side) | terminal engine, supervisor, dm | kqueue `EVFILT_PROC`/`NOTE_EXIT` like the Zig side. Handles on other processes (client pids, IPC peers, monitor) need an identity check (start time from `kern.proc`; the monitor's actions already do); `Handle.pid()` (fdinfo) has no counterpart. |
| `signalfd`, `epoll` | supervisor, dm | kqueue `EVFILT_SIGNAL`, kqueue. |
| `/proc/self/fd`, `fdinfo` | spawn paths; fd-as-path opens in `files/properties`, `pdf/print.c`, `pdf/sandbox.c`, `files/terminal/child.c` | `closefrom` for spawn paths; the path form needs `fdescfs` or `*at` calls, per site. |
| `pty.h`, `SCM_CREDENTIALS`, `/proc` walks | Files terminal engine | `ft_start` refuses on FreeBSD. Port the per-message check (`SCM_CREDS` is sender-attached, so `bash.c` would send it) and the session teardown walk (`kern.proc` by session); needs a FreeBSD to test on. |
| `/proc/<pid>` leftovers | `detectSandbox` (no Flatpak: "not sandboxed"), editor memory probe, `session_restart` (Linux install tool), supervisor teardown tree | A failed read means "not sandboxed" or no check; the supervisor's walk is phase 2. |
| `DRM_IOCTL_VERSION` | `Output.zig` | `drmGetVersion`; skipped on FreeBSD (a hypervisor-GPU workaround only). |
| netlink `KOBJECT_UEVENT` | printer hotplug | devd's seqpacket socket; rescans only today. |
| `gettid`; `fork`/`kill`/`wait4`/`poll` loops | `thumbs`; supervisor and dm | A `platform` wrapper; the loops are replaced in phases 2 and 4. |
| `RENAME_EXCHANGE`, `renameat2` | theme helper, transfers helper | Linux only. |

Done and not repeated: the Zig side of pidfd, inotify, eventfd, `prctl`,
`SO_PEERCRED`, `/proc/self/exe`, `statx`/`getdents` (Files folder sizes),
`renameat2` at the Zig sites, the process list. Its limits: no swap figures,
`ki_comm` names are 19 characters, and the exe path is read by pid.

## Sandboxes

The PDF sandbox and the theme helper use raw BPF through `platform/seccomp.zig`
plus Landlock; FreeBSD needs a rewrite on **Capsicum** (`cap_enter`,
`cap_rights_limit` on pre-opened directory fds). Both already preload before
the sandbox closes, but capability mode forbids every path-based `open`, so
fontconfig and late lookups need an audit. Until then both refuse to run
(`ENOTSUP`): the PDF viewer opens nothing and theme packs cannot be imported
(D4). FreeBSD recognises no sandboxed IPC peer, so a Capsicum child must never
be handed the IPC socket. Unchecked: whether a Flatpak app with `--allow=devel`
can overmount `/.flatpak-info` in its own mount namespace.

## System services

| Feature | Linux | FreeBSD |
| --- | --- | --- |
| Power, suspend, lock-before-sleep inhibitor, `Lock`, polkit agent session | logind (`session/login_bus`, `power*`, `polkit/agent`) | ConsoleKit2 behind the login-manager interface (P.11, D5). |
| Battery | `/sys/class/power_supply` + uevents | `hw.acpi.battery.*`, devd ACAD/CMBAT; keep "only on events and the minute tick". |
| Brightness | `brightnessctl` | `backlight(8)`. |
| Files DEVICES | UDisks2 | `sysutils/bsdisks` implements a subset; qualify, hide what fails. |
| Accounts | `useradd`, `usermod`, `chpasswd`, `gpasswd`, `loginctl` | `pw(8)`; password through `pw usermod -h 0`. |
| Wi-Fi, Ethernet, Bluetooth, power profiles, app scopes | NetworkManager, BlueZ, PPD, systemd1 | Absent and hidden (D3). |

## rediwm-dm

The most Linux-bound program: `pam_systemd` registration, Linux VT ioctls on
`/dev/tty0`/`ttyN` (FreeBSD: `/dev/ttyv*`, `sys/consio.h`), PDEATHSIG,
signalfd, pidfd. On FreeBSD `XDG_RUNTIME_DIR` comes from `pam_xdg` and device
access from a running seatd. It is optional and the port ships without it first
(D2).

## Login and seat

**Seat** is wlroots': libseat with seatd, the user in its group, drm-kmod,
libinput on libudev-devd. To check on real hardware: VT switching under
`vt(4)`, and typing in the compositor must not also reach the console tty.

**Login identity** is ours. `REDIWM_LOGIN_SESSION`, set by `rediwm-session`
after logind confirms the login (`login_bus.zig`: Type=wayland, Class=user,
Desktop=rediwm, not remote, same uid), gates the polkit agent, the activation
environment, following `Lock` and keeping `LockedHint`, and the Files terminal.
Left to do:

* One login-manager interface (P.11): logind implementation (today's code,
  moved) and a ConsoleKit2 one: session of a pid, `Lock` signal,
  `SetLockedHint`, sleep and lid inhibitors with `PrepareForSleep`, capability
  probes, power calls. Today logind's names are constants in `power.zig`
  imported by `power_*`, and `login_bus.zig` and `polkit/agent.zig` spell them
  out.
* A ConsoleKit2 check (D8): local, our uid, Type=wayland, not remote, from a
  session `rediwm-session` opens itself. No Desktop property, and a session
  without a display device is never active, so "active" cannot be required.

**Session environment.** `XDG_RUNTIME_DIR` comes from `pam_xdg` (HyprBSD puts
it in `/etc/pam.d/system`, which `login` and the DM include and `sshd` does
not). Socket paths must fit `sun_path`'s 103 characters. Nothing starts the
session bus: `rediwm-session` starts `dbus-daemon --session` when nothing
listens, or the start script wraps it in `dbus-run-session`. `dbus`, `seatd`,
ConsoleKit2 and polkitd must be enabled.

**Supervisor.** `rediwm-session` is Linux only (pidfd, signalfd, subreaper,
`std.os.linux`) and not built on FreeBSD. "A crash never unlocks" relies on it
restarting the compositor locked, so its port (phase 2) comes before FreeBSD
claims a lock. Until then, `exec` the session from the login shell (D9).

**What the probe showed** (HyprBSD VM, ConsoleKit2 2.0.0, seatd 0.9.3, polkit
128, over ssh and under `ck-launch-session`):

* No PAM stack opens a ConsoleKit2 session (no `pam_ck_connector`), so a
  console login has none (inferred, not run on a console). `ck-launch-session`
  or D-Bus `OpenSessionWithParameters` (allowed to users) creates one;
  `GetSessionForUnixProcess` and `GetCurrentSession` then find it from a
  descendant.
* `OpenSessionWithParameters` honours `session-type` (`wayland`, `tty`) and
  `remote-host-name`, ignores unknown names, and `is-local=false` did not
  change `IsLocal`. A session without a display device gets its own seat, is
  never active and has VT 0. Any process of the user can open one of any type,
  so the identity is a same-uid assertion where logind's is made by PAM.
* Manager has `GetSessionForCookie`, `OpenSession`, `CloseSession`, `Inhibit`,
  `ListInhibitors`, `PrepareForSleep`/`PrepareForShutdown` and the power calls
  with `Can…`. Session has type, class, uid, `IsLocal`, `IsActive`,
  remote host, `GetXDGRuntimeDir`, `GetVTNr`, `SetLockedHint`, `SetIdleHint`,
  `Lock`/`Unlock` signals, `TakeControl`, `TakeDevice`; no Desktop and no
  locked-hint getter.
* seatd runs as `seatd -g video`, socket `/var/run/seatd.sock` (root:video,
  0770); clients use `LIBSEAT_BACKEND=seatd`.
* polkit answers `auth_admin` for the ssh shell and the session's shell alike;
  whether it needs an active or ConsoleKit2-owned session is not settled.
* The VM's own `/usr/local/libexec/hyprbsd/session` is a working template:
  checks `XDG_RUNTIME_DIR`, `/dev/dri/card*` and the `video` group, runs under
  `ck-launch-session`, finds its id with `GetSessionForCookie`, then
  `exec dbus-run-session -- start-hyprland`.

## Build and install

`scripts/install-session-root.sh` and `scripts/make-deb.sh` are Linux
installers (GNU `install -D`, systemd units, Debian/Arch PAM files); FreeBSD's
`install -D` means DESTDIR, so it gets its own `pkg` path in phase 4.

## Rules for the port

* **One platform module.** `src/platform/` (no compositor imports) owns the OS
  calls, with `linux_*.zig` and `freebsd_*.zig` parts chosen at comptime.
  Callers never test the OS; `std.os.linux` is used only inside it. Parts not
  ported refuse to build for another OS.
* **One translate root.** `src/c/libc.h` lists the portable headers; one-OS
  headers sit under `#ifdef __linux__` or `__FreeBSD__` at its end.
* **Missing services hide, never fake.** A feature without a backend is absent
  from the taskbar and Settings.
* **Fail closed.** No sandbox, no sandboxed app; no peer pid, no IPC allowance.
* **Keep wlroots' portable layers** (session, backend, DRM, libinput, udev).
* Security rules from the root `AGENTS.md` apply unchanged.

## Remaining work

### P. Linux-side preparation (open)

5. **One sandbox interface:** give the PDF sandbox and the theme helper one
   "restrict to these directories" entry point, which Capsicum later
   implements. Their Landlock code differs on purpose (PDF: read-only trees,
   ABI 3 required, fails closed; theme helper: optionally writable root and
   `/usr` executable, runs without Landlock on older kernels), so settle what
   it promises first. Security work: needs its own review.
7. **Paths left:** the cupsd probe (`printing/platform.zig`) needs
   `/usr/local/sbin`; the accounts helper's candidate lists need `pw(8)`
   (phase 3). Phase 2 decides `/run/polkit/agent-helper.socket` (systemd's
   helper socket; the agent could start the setuid helper itself via
   `rediwm_polkit_spawn`). `/etc/pam.d` and `/run/rediwm-dm` are written by the
   Linux installers only. Kept on purpose: `/etc/xdg`, `/etc/login.defs`.
11. **Login-manager interface:** move the logind calls of `login_bus`,
    `polkit/agent` and `power_*` behind one interface, the logind implementation
    unchanged and a recording fake for tests (`tests/power.py`, `polkit.py`,
    `rediwm_session.py`, `session_bus.py` as the check). The ConsoleKit2
    implementation is phase 2.

### 1. Compositor runs (finish)

Headless works. Left: a DRM session on the VM's virtio GPU or real hardware, a
nested session under Hyprland, the four pixel suites above, `memfd_create`,
the transfers helper if wanted. `rediwm-session` and `rediwm-dm` stay off
(`-Dlogin-session`, default off there) until phases 2 and 4. Goal: `rediwm`
and the apps start in a seatd session.

### 2. Real session

The ConsoleKit2 login-manager implementation (`rediwm-session` opens the
session; identity, power, suspend, inhibitor; lock follows `Lock`); `pam_xdg`
and the session bus; battery and brightness backends; `rediwm-session`
supervisor on kqueue. Goal: a daily-usable session started from the console.

### 3. Parity

Capsicum sandboxes for the PDF viewer and theme helper; the System Monitor's
swap figures and long command names (`vm.swap_info`, `KERN_PROC_ARGS`);
accounts helper on `pw`; printer hotplug via devd; bsdisks for Files DEVICES;
the Files terminal.

### 4. Login manager and packaging

`rediwm-dm` on OpenPAM, `pam_xdg`, seatd and `vt(4)`; `install.sh` `pkg` path;
release tarball or a port (D6); FreeBSD in `make-release.sh` verification.

## Decisions

* **D1 Target release: 15.x only** (D1–D5 made 2026-11-05). Native inotify and
  timerfd; 14.x would need kqueue vnode watching.
* **D2 DM in the first release: no.**
* **D3 Network: hide** the NetworkManager and BlueZ items; a wpa_supplicant
  backend may follow.
* **D4 Sandboxed apps before Capsicum: refuse** (implemented: `ENOTSUP`).
* **D5 Power backend: ConsoleKit2**, not our own polkit-gated helper.
* **D6 Distribution:** prebuilt tarball like Linux, or a port in `x11-wm`.
  Decide after phase 2.
* **D7 Name collation:** accept FreeBSD libc's order (done) or ship our own for
  Latin and Cyrillic. Recommend accept until a user asks.
* **D8 Login check on FreeBSD:** `rediwm-session` opens the ConsoleKit2 session
  itself (Type=wayland), so the logind check's shape stays minus Desktop and a
  console login needs no relaxation. It proves a process of this user
  registered a session, not that PAM did. Recommended.
* **D9 First start path:** `rediwm-session` from a console login (profile or a
  small start script), not greetd; the lock's crash guarantee rests on it.
  Recommended.

## Validation

Each phase: Linux Debug and ReleaseSafe builds, `zig build test` and the
affected suites against HEAD in a worktree; the same on FreeBSD (see
`docs/freebsd-build.md` for the VM setup, the watchdog runner and the tools the
suites need). `tools/freebsd-cross/check.sh` after touching OS interfaces, C
headers or `src/platform/`: it proves compilation only, and the `undefined
symbol`s it leaves should be checked for names libc owns. `strings` a
ReleaseSafe `rediwm` on both after touching environment handling. Sandbox work
(P.5, phase 3) gets a dedicated escape test per helper: path opens, sockets and
exec are denied.
