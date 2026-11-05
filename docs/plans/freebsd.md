# FreeBSD support plan

Status: draft, 2026-11-05. The Linux-side preparation (P.1–P.4, P.6–P.10) is
done; P.5 and the P.9 review are open. The FreeBSD parts of `platform` are written and
the whole tree cross-compiles for `x86_64-freebsd` (Debug, ReleaseSafe, tests;
see Validation). The third outside build (fa55c2a, FreeBSD 15.1 VM without a DRM
render device) builds Debug and ReleaseSafe and passes the platform tests, but
the compositor stops at renderer initialisation, so only unit tests have run.
Decisions D1–D5 are made (see Decisions); D6 waits for phase 2.

Goal: run RediWM on FreeBSD: first the compositor in a seatd session on DRM,
then the shell features and apps, and last `rediwm-dm` and packaging. Linux
stays the primary platform; the port must not change Linux behaviour or cost.

## Where we stand

The graphics stack is portable. wlroots supports FreeBSD (libseat + seatd,
drm-kmod, libinput, libudev-devd), and Mesa, Xwayland, cairo, freetype,
harfbuzz, fontconfig, librsvg, gio, CUPS, libarchive, D-Bus, polkit,
xdg-desktop-portal, pulseaudio and OpenPAM are in ports. Zig 0.17 targets
`x86_64-freebsd`. Night light rides wlroots' DRM gamma and should port as is.

Our own code had no OS abstraction. It now lives in `src/platform/` (child
handles, file watching, own path, peer credentials, process attributes, wake
descriptors, rename and stat, seccomp filters, tool lookup, with C headers
beside it), with a FreeBSD half for each part except seccomp. About 15 files
still use `std.os.linux` outside it (the supervisor, the DM, the Files
folder-size walk, `Output.zig`, the seccomp policy tables). What is left is
the Linux-only interfaces below, sandboxes, services and the login manager.

A first outside build (FreeBSD 15.1-RELEASE amd64, AMD Navi 44 on drm-kmod,
Zig 0.17.1, wlroots 0.20 from ports `x11-toolkits/wlroots020`) built 72 of 114
steps. Every failure was a known item or a missing package and was fixed on the
Linux side (P.8–P.10; the transfers helper is off by default on FreeBSD).
The second build of the same tester (14 failed of 106 Debug steps) stopped at
the parts that P.4 and P.9 had deliberately made refuse to build off Linux,
plus what that exposed: `c.SIG_IGN` does not translate, glibc's socket-address
union, 16-bit `mode_t`, `landlock.h`, `pty.h`, `MADV_DONTDUMP`, `pam_start_confdir`,
`_NL_*` locale items, `CLOCK_BOOTTIME`, netlink uevents, `renameat2` and
`statx`, xattr calls, and the D-Bus control-message data offset (FreeBSD's
`cmsghdr` is 12 bytes, its data starts at 16). All are fixed except what the
next paragraph lists.
On 15.1 `sys/inotify.h`, `sys/timerfd.h`, `sys/eventfd.h` and `cr_pid` in
`sys/ucred.h` exist (header checks only). The platform tests now pass on 15.1, among them kqueue child
exits and reaping, watchers and the `cr_pid` of a unix-socket peer. Not known
yet: `memfd_create`, the transfers helper's C++ flags under clang and libc++,
whether the kqueue child handles behave in the Wayland loop (libepoll-shim),
and whether a DRM session or the headless GLES2 path works: wlroots'
renderer needs a DRM render node (`drmGetDevices2 failed`), which the qemu VM
lacks, so `rediwm-msg` and the Files lifecycle are untested. The second tester log also showed a Debug `rediwm-cursorgen` dying with
`Undefined symbol "environ"` while its ReleaseSafe build ran, so the build now
defaults to LLVM on FreeBSD; confirm it. Two tests failed at run time: the
D-Bus fd test (fixed, the offset above) and the images decoder test (probably
a gdk-pixbuf port without the PNM loader; the test now skips there).
The third run failed in five places, all tests: the system monitor's `/proc`
readers (no procfs; they skip until P.6), the battery event test (raw Linux
syscalls; now libc), the polkit helper's backpressure test (its fill loop
stopped at 64 KiB; longer now), the editor view tests (the VM had no monospace
font; they pass with DejaVu installed, so a FreeBSD test host needs a font
package) and Files collation, the only one still failing at dcbaec1. A probe showed
that `strxfrm_l` and `strcoll_l` agree on FreeBSD, so Files' frozen keys are
sound; its libc tables are what differ from glibc's: `de_DE.UTF-8` is a link
to `en_US.UTF-8`, which sorts `Élan` before `Apfel` and gives Cyrillic names
no usable primary weights (`Яблоко` before `Ель`), and `ru_RU.UTF-8` puts
Cyrillic first with `Ёж` before `Еж`. Files therefore orders names as `ls`
does there. The two glibc-order tests skip off Linux (they also skip on a Linux
machine without those locales, as here); an own collation would be a separate
project (D7).

### Interfaces still to port

| Linux interface | Where | FreeBSD |
| --- | --- | --- |
| pidfd (`platform.child` `Handle`, `Set`; `child.h`). **Zig side done** (`child_freebsd.zig`); `child.h` is Linux only and the terminal that uses it refuses to start | `session/child`, supervisor, dm, IPC, `Toplevel`, pickers, System Monitor, terminal engine | kqueue `EVFILT_PROC`/`NOTE_EXIT`, its fd joining the wl loop like a pidfd. Signals by pid, guarded by the unreaped zombie, which holds only for our own children: handles on other processes (`Toplevel` client pids, IPC peers, System Monitor) need another identity check (start time from `kern.proc`). `Handle.pid()` (fdinfo) has no counterpart. |
| `signalfd`, `epoll` | supervisor, dm, `child.Set` | kqueue `EVFILT_SIGNAL`, kqueue. |
| `inotify` (`platform.watch`) | 7 users | Native on 15 (**done**, libc); on 14.x kqueue `EVFILT_VNODE` has no names, so diff the directory. |
| `eventfd` (`platform.wake`) | 9 sites | Native (13+); the flag values differ (**done**). |
| `memfd_create`, `timerfd` | few | `sys/timerfd.h` on 15.1; confirm `memfd_create` in phase 0. |
| `prctl` (`platform.process`, `process.h`) | dm worker, lock, PAM worker, PDF, theme helper, supervisor subreaper | `procctl` (`PROC_PDEATHSIG_CTL`, `PROC_NO_NEW_PRIVS_CTL`, `PROC_TRACE_CTL`, `PROC_REAP_ACQUIRE`), `pthread_set_name_np` (**done**). |
| `SO_PEERCRED` (`platform.peer`, `peer.h`) | IPC (uid and pid, for sandbox allowances), `session_restart`, `files/torrents`, torrent helper, `bash.c` | `getsockopt(LOCAL_PEERCRED)` into `struct xucred` (**done**; a peer with `cr_pid` 0 is refused). Check at run time that `cr_pid` is filled for a unix-socket peer. `files/terminal/engine.c` authenticates each shell message with `SCM_CREDENTIALS`; FreeBSD's `SCM_CREDS` is sender-attached, so `bash.c` would send it too: decide when the port reaches the terminal. |
| `/proc/self/exe` (`platform.exe`, `self_exe.h`) | Zig sites, `bass.c`, torrent helper, dm re-exec | `KERN_PROC_PATHNAME` (**done**; the re-exec uses the path, not a descriptor kept from startup). |
| `statx`, `getdents64`, `dirent64` | Files folder sizes, IPC socket check, `session_restart` | `fstatat` behind `platform.fs.stat` (**done** for the IPC socket check and `session_restart`). The folder-size walk still reads with `getdents64`: it refuses on FreeBSD (`getdirentries` or `readdir`, to do). |
| `/proc/self/fd`, `fdinfo` | spawn paths; fd-as-path opens in `files/properties`, `pdf/print.c`, `pdf/sandbox.c`, `files/terminal/child.c` | `closefrom` for spawn paths; the path form needs `fdescfs` or `*at` calls on the fd, per site. |
| `/proc/<pid>/…`, `/proc/stat`, `/proc/meminfo` | system monitor, `ipc/processes.zig`, `placeholder_match` (parent chain), `session_restart` (exe), `detectSandbox` (`root/.flatpak-info`; no Flatpak on FreeBSD, expect "not sandboxed"), editor memory probe, supervisor teardown tree | Behind `system_monitor/proc.zig` (**interface done**, P.6), which the monitor, `ipc/processes.zig` and `placeholder_match` use; its FreeBSD backend is a stub that reports "unavailable" until phase 3 (`kern.proc` sysctls or libprocstat; `KERN_PROC_PATHNAME` takes a pid; procfs is optional on FreeBSD). The others stay: a failed read means "not sandboxed" (`detectSandbox`) or no memory check (editor), `session_restart` is a Linux install tool, the supervisor's walk is phase 2. |
| `pty.h`, `SCM_CREDENTIALS`, `/proc` walks | terminal engine | `libutil.h` is included and `util` linked, but `ft_start` refuses on FreeBSD: porting the shell channel's per-message check and the session teardown walk (`kern.proc` by session) needs a FreeBSD to test on. |
| `renameat2` | ~9 sites: Files ops, Editor, Images, screenshots, desktop watcher, theme helper, torrent helper | `link` + `unlink` for no-replace, behind `platform.fs.renameNoReplace` (**done** for the Zig sites; the theme helper's `RENAME_EXCHANGE` and the transfers helper stay Linux only). |
| `DRM_IOCTL_VERSION` | `Output.zig` | libdrm `drmGetVersion`; skipped on FreeBSD for now (only a hypervisor-GPU workaround). |
| netlink `KOBJECT_UEVENT` | printer hotplug (`printing/client.zig`) | devd's seqpacket socket, or rescans only (rescans only, **done**). |
| `gettid`; `fork`, `kill`, `wait4`, `poll` loops | `thumbs`; supervisor and dm | A `platform` wrapper; the loops are replaced in phases 2 and 4. |

### Sandboxes

The PDF sandbox (`pdf/sandbox.c` + `pdf/syscall_policy.zig`: raw BPF through
`platform/seccomp.zig`, + Landlock) and the theme helper
(`theme_helper/native.c` + `syscall_policy.zig`: the same builder, + Landlock)
have no FreeBSD counterpart short of a rewrite on **Capsicum** (`cap_enter`,
`cap_rights_limit` on pre-opened directory fds). The design fits, since both
already preload before the sandbox closes (`compose.preload`), but capability
mode forbids every path-based `open`, so fontconfig and late lookups need an
audit. Until then both helpers refuse to run on FreeBSD: sandboxing fails
closed (`rediwm_pdf_sandbox_enter` and the theme helper's `parser_sandbox`
return `ENOTSUP` there; the PDF viewer opens nothing and theme packs cannot be
imported).

### System services

| Feature | Linux | FreeBSD |
| --- | --- | --- |
| Power, suspend, lock-before-sleep inhibitor, logind `Lock`, polkit agent session | logind (`session/login_bus`, `power*`, `polkit/agent`) | ConsoleKit2 (`org.freedesktop.ConsoleKit`: PowerOff/Reboot/Suspend/Inhibit) as a third backend beside systemctl/loginctl in `power.zig`. |
| App scopes, activation environment | systemd1 | Already degrades ("no systemd user manager"). |
| Battery | `/sys/class/power_supply` + uevents | `hw.acpi.battery.*`, devd ACAD/CMBAT notifications. Keep "only on events and the minute tick". |
| Brightness | `brightnessctl` | `backlight(8)`. |
| Wi-Fi, Ethernet | NetworkManager | Absent. Hidden (D3). |
| Bluetooth | BlueZ | Absent. Hidden. |
| Files DEVICES | UDisks2 | `sysutils/bsdisks` implements a UDisks2 subset; qualify, hide what fails. |
| Power profiles | power-profiles-daemon | Absent (`powerd`). Hidden. |
| Accounts | `useradd`/`usermod`/`userdel`/`chpasswd`/`gpasswd`/`loginctl` | `pw(8)`; password through `pw usermod -h 0`. |
| Audio | libpulse; PipeWire for the bass DSP | pulseaudio or pipewire-pulse; the DSP is optional. |

### rediwm-dm

The most Linux-bound program: `pam_systemd` registration, Linux VT ioctls on
`/dev/tty0`/`/dev/ttyN` (FreeBSD: `/dev/ttyv*`, `sys/consio.h`, different
numbers), PDEATHSIG, signalfd, pidfd. On FreeBSD `XDG_RUNTIME_DIR` comes from
`pam_xdg` and device access from a running seatd. The DM is optional and never
enabled by the installer, so the port ships without it first (D2): start from
the console through seatd, or from greetd.

### Build and install

`scripts/install-session-root.sh` and `scripts/make-deb.sh` are Linux
installers (GNU `install -D`, systemd units, Debian/Arch PAM files); FreeBSD's
`install -D` means DESTDIR, so it gets its own `pkg` path in phase 4. The
transfers helper's `c++ -Werror … -D_GLIBCXX_ASSERTIONS` line is unchecked
under clang and libc++ until the helper is enabled there.

## Rules for the port

* **One platform module.** `src/platform/` (named module, no compositor
  imports) owns child watching, signal sources, file watching, process control
  and attributes, own-executable path, peer credentials, wake descriptors and
  process listing, with `linux_*.zig` and `freebsd_*.zig` parts chosen at
  comptime. Callers never test the OS themselves; `std.os.linux` is used only
  inside it. Parts not yet ported refuse to build for another OS.
* **One translate root, OS conditions inside.** `src/c/libc.h` lists the
  portable headers; those that exist on one OS only sit under `#ifdef
  __linux__` (later `__FreeBSD__`) at its end, so Zig code that needs a
  Linux-only name fails at its use, not at the translation.
* **Missing services hide, never fake.** A feature without a backend is absent
  from the taskbar and Settings, as on a Linux machine lacking it.
* **Fail closed.** No sandbox, no sandboxed app; no peer pid, no IPC allowance.
* **Keep wlroots' portable layers.** Session, backend, DRM, libinput and udev
  handling stay in wlroots. Any future replacement of them with our own code
  goes through `platform` with both implementations from day one.
* Security rules from the root `AGENTS.md` apply unchanged (greeter, lock, no
  test hooks in production, mlocked secrets).

## Phases

### P. Preparation on Linux (before any FreeBSD work)

Each step keeps behaviour and was checked with Debug, ReleaseSafe,
`zig build test` and the affected suites against HEAD.

Done:

1. `platform.child` (`Handle`, `Set`, `reap`, `killAndReap`) replaced the ad
   hoc pidfd sites; `Pid` and `Signal` are `std.posix` types.
2. `platform.watch.Watcher` for the 7 inotify users.
3. `platform.exe` and `self_exe.h` for the `/proc/self/exe` readers.
4. Plain calls use libc or `std.posix`; `platform.process`/`process.h` take the
   `prctl` calls and `platform.wake` the `eventfd` pairs. Left on
   `std.os.linux`: the supervisor and dm, the table's Linux-only calls, the
   two seccomp policy tables and `battery_tests`.
5. (filters) The PDF and theme helper syscall filters are built by
   `platform/seccomp.zig`, verdict for verdict identical to what they replaced.
6. (process list) `system_monitor/proc.zig` is the interface to the OS:
   `proc_common.zig` has the types and arithmetic, `proc_linux.zig` reads
   `/proc` (the old code, moved), `proc_freebsd.zig` reports "unavailable" (the
   monitor shows its status line, `get_processes` finds no samples). `Stat`
   carries the parent pid, so `placeholder_match` no longer opens `/proc`.
7. (paths) No fixed `/usr/bin` tool path in the shell; `pkexec` and
   `systemctl` use `platform.tool.system` on purpose (a user-writable `PATH`
   must not capture a password); `XDG_DATA_DIRS` and the CUPS socket default
   correctly. `-Dsysconfdir` (`/etc`; `/usr/local/etc` when targeting FreeBSD)
   and `-Drundir` (`/run`; `/var/run`) in `build/install_paths.zig` cover
   `rediwm/dm.conf` and `greeter.toml`, the `pam.d/rediwm` lock policy
   (`auth.c` gets `-DREDIWM_SYSCONFDIR`), CUPS's `client.conf` and the DM's
   marker directory; the polkit helper search list gained
   `/usr/local/lib/polkit-1` and `/usr/local/libexec`. Linux defaults are
   unchanged (checked with `strings`).
8. No GNU-only `install -t` or `cp -T` in the build.
9. `platform.peer` and `peer.h` replace five `SO_PEERCRED` sites.
10. Linux-only headers sit under `#ifdef __linux__` in `libc.h`; Zig's bundled
    FreeBSD headers translate it (see Validation). Code using the moved names
    (`dm/worker`, `session/lock`, `printing/client`, and four C files that
    include `sys/prctl.h`) now fails for FreeBSD at its use.

Open:

5. **One sandbox interface:** give the PDF sandbox and the theme helper one
   "restrict to these directories" entry point, which Capsicum later
   implements. Their Landlock code differs on purpose (PDF: read-only trees,
   ABI 3 required, fails closed; theme helper: optionally writable root and
   `/usr` executable, runs without Landlock on older kernels), so settle what
   it promises before moving either. Security work: needs its own review.
7. **Paths left:** the cupsd probe (`printing/platform.zig`) needs
   `/usr/local/sbin` and the accounts helper's candidate lists need `pw(8)`
   (phase 3). Kept on purpose: `/etc/xdg` (the XDG default, read by GLib and
   xdg-desktop-portal; set `XDG_CONFIG_DIRS` where a port differs) and
   `/etc/login.defs` (both readers fall back to the usual UID range, which fits
   FreeBSD's). Phase 2 decides `/run/polkit/agent-helper.socket`: it is
   systemd's helper socket, and the agent could start the setuid helper itself
   (`rediwm_polkit_spawn`). `/etc/pam.d` and `/run/rediwm-dm` are written by
   the Linux installers only; FreeBSD packaging is phase 4.
9. **Review** of the IPC allowance check that P.9 touched.

### 0. Spike (FreeBSD)

FreeBSD 15 VM with drm-kmod and seatd. Build wlroots 0.20 and dependencies,
run the headless backend, a nested session and a DRM session with an upstream
example compositor. Record which of the "native, confirm" interfaces exist on
the target release(s) (D1), and whether the integration tests' headless +
GLES2 path works there.

### 1. Compositor builds and runs

`src/platform/` has its FreeBSD parts and the tree cross-compiles; what
is left is to run it. `rediwm-session` and `rediwm-dm` are not built on
FreeBSD (`-Dlogin-session`, default off there) until phases 2 and 4. Hide NM,
BlueZ, PPD, UDisks, app scopes; PDF and theme helper refuse (done); the
System Monitor lists nothing (its backend is a stub); the Files folder-size
column stays empty and its terminal refuses. List the FreeBSD packages the build needs (the outside build stopped
on a missing `libtorrent-rasterbar`). Goal: `rediwm` and the apps start in a
seatd session and the headless integration suites run.

### 2. Real session

ConsoleKit2 power, suspend and inhibitor; lock follows ConsoleKit's `Lock`;
battery and brightness backends; peer credentials for IPC; `rediwm-session`
supervisor on kqueue. Goal: daily-usable session started from the console.

### 3. Parity

Capsicum sandboxes for PDF and the theme helper; system monitor collector on
libprocstat; accounts helper on `pw`; printer hotplug via devd; bsdisks
qualification for Files DEVICES.

### 4. Login manager and packaging

`rediwm-dm` on OpenPAM, `pam_xdg`, seatd and `vt(4)`; `install.sh` `pkg` path;
release tarball or a port (D6); FreeBSD in `make-release.sh` verification.

## Decisions

D1–D5 were made on 2026-11-05.

* **D1 Target release: 15.x only.** Native inotify and timerfd; 14.x would need
  kqueue vnode watching and more fallbacks. 15.1 has the headers (see above).
* **D2 DM in the first release: no.**
* **D3 Network: hide** the NetworkManager and BlueZ items. A wpa_supplicant
  control-socket backend may follow later.
* **D4 Sandboxed apps before Capsicum: refuse.** Matches fail closed, and is
  already implemented (the PDF viewer and the theme helper return `ENOTSUP`).
* **D5 Power backend: ConsoleKit2**, not our own polkit-gated helper calling
  `shutdown`/`acpiconf`.
* **D6 Distribution:** prebuilt tarball like the Linux releases, or a port in
  `x11-wm`. Decide after phase 2.
* **D7 Name collation:** accept FreeBSD libc's order (done, matches `ls`) or
  ship our own for Latin and Cyrillic. Recommend accept until a user asks.

## Validation

Each phase: Linux Debug and ReleaseSafe builds, `zig build test` and the
affected integration suites, compared against HEAD in a worktree; the same on
FreeBSD from phase 1, starting with the headless suites. `strings` a
ReleaseSafe `rediwm` on both after touching environment handling. Sandbox work
(P.5, phase 3) gets a dedicated escape test per helper: path opens, sockets
and exec are denied.

A FreeBSD translation of `src/c/libc.h` can be checked on Linux with Zig's
bundled FreeBSD headers. `zig translate-c` adds the host's `/usr/include`
whatever the target, so hide it, and give Zig private caches:

    bwrap --ro-bind / / --tmpfs /usr/include --tmpfs /usr/local/include \
      --bind SCRATCH SCRATCH --bind SCRATCH/zglobal ~/.cache/zig \
      --bind SCRATCH/zlocal ./.zig-cache --dev /dev --proc /proc \
      zig translate-c -target x86_64-freebsd -lc src/c/libc.h

On a root that still includes `linux/netlink.h` it fails with the outside
tester's error. It covers `libc.h` only: the roots that need cairo, libinput or
wlroots headers need FreeBSD's own, and Zig's headers may be older than 15.1.

The whole build can be cross-checked the same way, to catch the next layer of
errors before the tester does (Zig reports errors only in code it reaches, so
fixes expose more): `tools/freebsd-cross/check.sh` (see its README). A pass
means every unit compiled and the build reached the link; it cannot show
header-version differences, library versions or anything that runs. The only
errors it leaves are `undefined symbol`s from its empty libraries, so watch
that list for names libc itself would own (`xattr` was one).
