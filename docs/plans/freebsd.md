# FreeBSD support plan

Status: draft, 2026-10-30. Preparation steps P.1–P.3 are done (Linux only,
`src/platform/`); nothing else is implemented. Decisions D1–D6 are open.

Run RediWM on FreeBSD: first the compositor in a seatd session on DRM, then
the shell features and apps, and last `rediwm-dm` and packaging. Linux stays
the primary platform; the port must not change Linux behaviour or cost.

## Where we stand

The graphics stack is portable. wlroots supports FreeBSD, and its session,
DRM, libinput and udev layers (libseat + seatd, drm-kmod, libinput over
evdev, libudev-devd) are exactly what makes a compositor port cheap. Mesa
EGL/GLES, Xwayland, cairo, freetype, harfbuzz, fontconfig, librsvg, gio,
CUPS, libarchive, libtorrent, D-Bus, polkit, xdg-desktop-portal and
pulseaudio are in ports; OpenPAM covers `pam_appl.h`. Zig 0.17 targets
`x86_64-freebsd`. Night light rides wlroots' DRM gamma and should port as is.

Our own code is the problem: it has no OS abstraction at all (no
`builtin.os.tag` test anywhere). The Linux assumptions sit at four levels.

### 1. Compile barrier

`src/c/libc.h` includes `linux/netlink.h`, `sys/prctl.h` and `sys/eventfd.h`
(`sys/inotify.h` left with P.2), so the `c` module, and with it every artifact, fails to
translate. About 47 Zig files call `std.os.linux.*` directly.

| Linux interface | Users | FreeBSD |
| --- | --- | --- |
| `eventfd` | ~38 files | Native (13+). Swap `linux.EFD` for `c.EFD_*`. |
| `memfd_create`, `timerfd` | few | Native on current releases (confirm in phase 0). |
| `pidfd_open`, `pidfd_send_signal`, `waitid(P_PIDFD)` | `platform/child.zig` (`Handle`, `Set`) and `platform/child.h`, used by `session/child.zig`, the supervisor, dm worker and daemon, IPC, `Toplevel`, the pickers, System Monitor and the terminal engine | No equivalent for an existing pid. kqueue `EVFILT_PROC`/`NOTE_EXIT`; the kqueue fd joins the wl event loop like a pidfd. Signals by pid, guarded by the still-unreaped zombie, which only holds for our own children: handles on other processes (`Toplevel` client pids, `Handle.peer` for IPC, System Monitor) become a bare pid with a reuse race, so those callers need another identity check (start time from `kern.proc`). `Handle.pid()` reads `fdinfo` and has no counterpart. `Pid`/`Signal` are `std.os.linux` types today; switch them to `std.posix` before the FreeBSD part. |
| `signalfd`, `epoll` | supervisor, dm daemon/worker, `platform.child.Set` | kqueue `EVFILT_SIGNAL`, kqueue. |
| `inotify` | `platform/watch.zig` (`Watcher`); all 7 users (config, desktop, Files worker ×2, printing, start menu, system monitor settings) call it | Native in 15.0 (confirm); otherwise kqueue `EVFILT_VNODE`, which has no names: diff the directory to synthesize them. |
| `prctl` | dm worker, lock, PAM worker, PDF print/sandbox, theme helper | `procctl(PROC_PDEATHSIG_CTL / PROC_NO_NEW_PRIVS_CTL / PROC_TRACE_CTL)`, `pthread_set_name_np`. |
| `statx`, `getdents64` | Files dirsize/properties, supervisor, session restart, IPC | `fstatat`, `getdirentries` or `std.Io.Dir`. |
| raw `linux.fork/execve/wait4/exit_group/close/read` | many | libc. Note the `-errno` vs `errno` convention change. |
| `SO_PEERCRED` | IPC peer checks (4 files) | `getpeereid` / `LOCAL_PEERCRED`. Security-relevant: sandbox allowances need the peer pid; confirm `cr_pid`. |
| `/proc/self/exe` | `platform/exe.zig` and `platform/self_exe.h` (Zig sites, `bass.c`, torrent helper; dm re-execs through `exe.execSelf`) | `sysctl KERN_PROC_PATHNAME` / `std.process.executablePath`; `fexecve` on a descriptor opened at startup for the re-exec. |
| `/proc/self/fd`, `fdinfo` | spawn paths | `closefrom`/`close_range`. |
| `/proc/<pid>/stat`, `/proc/stat`, `/proc/meminfo`, task children | system monitor, `ipc/processes.zig` | libprocstat / `kern.proc` sysctls behind a collector backend. |
| `pty.h` | terminal engine | `libutil.h` (`openpty`/`forkpty`), link `util`. |
| `renameat2` | torrent helper | Emulate no-replace with `link` + `unlink`. |
| `DRM_IOCTL_VERSION` via `linux.IOCTL` | `Output.zig:206` | Different ioctl encoding: use libdrm `drmGetVersion`. |
| netlink `KOBJECT_UEVENT` | printer hotplug | devd's seqpacket socket, or rescans only. |

### 2. Sandboxes

The PDF sandbox (`pdf/sandbox.c` + `pdf/syscall_policy.zig`: raw BPF through
`platform/seccomp.zig`, + Landlock) and the theme helper
(`theme_helper/native.c`: raw BPF + Landlock) have no FreeBSD counterpart
short of a rewrite on **Capsicum** (`cap_enter`, `cap_rights_limit` on
pre-opened directory fds). The design fits, since both already preload before
the sandbox closes (`compose.preload`), but capability mode forbids every
path-based `open`, so fontconfig and late lookups need an audit. Until then
both helpers refuse to run on FreeBSD: sandboxing fails closed.

### 3. System services

| Feature | Linux | FreeBSD |
| --- | --- | --- |
| Power, suspend, lock-before-sleep inhibitor, logind `Lock`, polkit agent session | logind (`session/login_bus`, `power*`, `polkit/agent`) | ConsoleKit2 (`org.freedesktop.ConsoleKit`: PowerOff/Reboot/Suspend/Inhibit) as a third backend beside systemctl/loginctl in `power.zig`. |
| App scopes, activation environment | systemd1 | Already degrades ("no systemd user manager"). |
| Battery | `/sys/class/power_supply` + uevents | `hw.acpi.battery.*`, devd ACAD/CMBAT notifications. Keep "only on events and the minute tick". |
| Brightness | `brightnessctl` | `backlight(8)` (or own code, see preparation). |
| Wi-Fi, Ethernet | NetworkManager | Absent. Hidden (D3). |
| Bluetooth | BlueZ | Absent. Hidden. |
| Files DEVICES | UDisks2 | `sysutils/bsdisks` implements a UDisks2 subset; qualify, hide what fails. |
| Power profiles | power-profiles-daemon | Absent (`powerd`). Hidden. |
| Accounts | `useradd`/`usermod`/`userdel`/`chpasswd`/`gpasswd`/`loginctl` | `pw(8)`; password through `pw usermod -h 0`. |
| Sounds, terminals, `pkexec`, polkit socket | `/usr/bin/...`, `/run/polkit/...` | Ports live under `/usr/local`; search `PATH` instead of fixed paths. |
| Audio | libpulse; PipeWire for the bass DSP | pulseaudio or pipewire-pulse; the DSP is optional. |

### 4. rediwm-dm

The most Linux-bound program: `pam_systemd` registration, Linux VT ioctls on
`/dev/tty0`/`/dev/ttyN` (FreeBSD: `/dev/ttyv*`, `sys/consio.h`, different
numbers), PDEATHSIG, signalfd, pidfd. On FreeBSD `XDG_RUNTIME_DIR` comes from
`pam_xdg` and device access from a running seatd. The DM is optional and never
enabled by the installer, so the port ships without it first (D2): start from
the console through seatd, or from greetd.

## Rules for the port

* **One platform module.** `src/platform/` (named module, no compositor
  imports) owns child watching, signal sources, file watching, process
  control, own-executable path, peer credentials and process listing, with
  `linux_*.zig` and `freebsd_*.zig` parts chosen at comptime. Callers never
  test the OS themselves; `std.os.linux` is used only inside it.
* **Translate roots per OS.** `src/c/libc.h` keeps portable headers;
  Linux-only ones move to a root only Linux builds translate.
* **Missing services hide, never fake.** A feature without a backend is
  absent from the taskbar and Settings, as on a Linux machine lacking it.
* **Fail closed.** No sandbox, no sandboxed app; no peer pid, no IPC
  allowance.
* **Keep wlroots' portable layers.** Session, backend, DRM, libinput and udev
  handling stay in wlroots. Any future replacement of them with our own code
  goes through `platform` with both implementations from day one.
* Security rules from the root `AGENTS.md` apply unchanged (greeter, lock,
  no test hooks in production, mlocked secrets).

## Phases

### P. Preparation on Linux (before any FreeBSD work)

Refactors that are worth doing for Linux alone and shrink the port. Each
lands separately, keeps behaviour, and is checked with the usual Debug,
ReleaseSafe, `zig build test` and affected integration suites.

1. **Child watching** (done): the ad hoc pidfd sites and `child_set.zig` are
   now `platform.child` (`Handle`, `Set`, `reap`) with `session/child.zig` as
   the Wayland-loop adapter and `platform/child.h` for the terminal engine.
   The port reimplements that module, not ten call sites. Left for P.4: plain
   `kill`/`wait4`, the supervisor's `signalfd`/`epoll`, and the `/proc` walks.
2. **File watching** (done): `platform.watch.Watcher` for the 7 inotify users,
   with event parsing in one place and `sys/inotify.h` out of `libc.h`.
3. **Own executable** (done): `platform.exe` and `self_exe.h` for the 11
   `/proc/self/exe` readers.
4. **Raw syscalls to libc** where libc has the call (fork, execve, wait4,
   close, read, getuid, …), keeping `std.os.linux` for what has no libc form.
5. **One sandbox interface:** (half done) the PDF sandbox no longer uses
   libseccomp: `platform/seccomp.zig` builds and loads the filter and
   `pdf/syscall_policy.zig` holds its allow-list, checked verdict for verdict
   against the libseccomp program it replaced. Left: move the theme helper's
   C filter onto the same builder and give both one "restrict to these
   directories" entry point, which Capsicum later implements.
6. **Process listing:** keep `/proc` parsing behind the system monitor's
   collector interface (shared with `ipc/processes.zig`).
7. **Paths:** replace fixed `/usr/bin/…` tool paths with `PATH` lookup.

Steps 1–3 and 7 are small; 4 is mechanical but broad; 5 is security work and
needs its own review.

### 0. Spike (FreeBSD)

FreeBSD 15 VM with drm-kmod and seatd. Build wlroots 0.20 and dependencies,
run the headless backend, a nested session and a DRM session with an
upstream example compositor. Record which of the "native, confirm" interfaces
above exist on the target release(s) (D1), and whether the integration tests'
headless + GLES2 path works there.

### 1. Compositor builds and runs

Split `src/platform/` into Linux and FreeBSD parts (`exe.path` can use
`std.process.executablePath`, which already reads `kern.proc.pathname`);
split the translate roots; build conditions for `util`, `pam`, and for
`platform/seccomp.zig`, which is Linux-only code now that nothing links
libseccomp. Hide NM, BlueZ, PPD, UDisks, app scopes; PDF and theme helper
refuse. Goal: `rediwm` and the apps start in a seatd session and the headless
integration suites run.

### 2. Real session

ConsoleKit2 power, suspend and inhibitor; lock follows ConsoleKit's `Lock`;
battery and brightness backends; peer credentials for IPC; `rediwm-session`
supervisor on kqueue. Goal: daily-usable session started from the console.

### 3. Parity

Capsicum sandboxes for PDF and the theme helper; system monitor collector on
libprocstat; accounts helper on `pw`; printer hotplug via devd; bsdisks
qualification for Files DEVICES.

### 4. Login manager and packaging

`rediwm-dm` on OpenPAM, `pam_xdg`, seatd and `vt(4)`; `install.sh` `pkg`
path; release tarball or a port (D6); FreeBSD in `make-release.sh`
verification.

## Decisions

* **D1 Target release:** 15.x only (native inotify, timerfd) or 14.x too
  (kqueue vnode watching, more fallbacks). Recommend 15.x only.
* **D2 DM in the first release:** recommend no.
* **D3 Network:** hide, or a wpa_supplicant control-socket backend later.
  Recommend hide.
* **D4 Sandboxed apps before Capsicum:** refuse (recommended, matches fail
  closed) or allow with a warning.
* **D5 Power backend:** ConsoleKit2, or our own polkit-gated helper calling
  `shutdown`/`acpiconf`. Recommend ConsoleKit2.
* **D6 Distribution:** prebuilt tarball like the Linux releases, or a port
  in `x11-wm`. Decide after phase 2.

## Validation

Each phase: Linux Debug and ReleaseSafe builds, `zig build test` and the
affected integration suites, compared against HEAD in a worktree; the same on
FreeBSD from phase 1, starting with the headless suites. `strings` a
ReleaseSafe `rediwm` on both after touching environment handling. Sandbox
work (P5, phase 3) gets a dedicated escape test per helper: path opens,
sockets and exec are denied.
