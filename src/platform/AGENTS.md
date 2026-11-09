# Platform module

The one place the OS shows: child handles (`child.zig`), directory watching
(`watch.zig`), the program's own path (`exe.zig`), who is on the other end of a
unix socket (`peer.zig`), process attributes such as no core dumps and no new
privileges (`process.zig`), descriptors that wake a poll loop (`wake.zig`),
where the system's helper programs live (`tool.zig`), radio kill switches for
airplane mode (`rfkill.zig`: Linux only, other systems report no radios), seccomp-BPF filters
(`seccomp.zig`, for the PDF viewer and the theme helper), and
`child.h`/`self_exe.h`/`peer.h`/`process.h` for C and C++, and `fs.zig`
(rename without replacing, stat), and `dirwalk.zig` (reading a directory and
examining its entries, for the Files folder-size walk). Std only, no compositor imports. Linux and
FreeBSD: a part is one file with a `switch (builtin.os.tag)` per function
(`peer`, `process`, `wake`, `watch`, `exe`, `fs`), or a facade over
`child_linux.zig` and `child_freebsd.zig`. A part not ported to another OS
fails to compile there (`std.os.linux` would issue Linux syscall numbers on
any target). FreeBSD notes are in `docs/plans/freebsd.md`.

* `login_io.zig` owns the supervisor's libc I/O; `login_process.zig` owns
  signal delivery, fork/exec and adopted-child reaping. `Signals` preserves
  the old mask for the child. FreeBSD kqueue notifications do not consume
  blocked POSIX signals: `next` consumes them with `sigtimedwait` before the
  old mask is restored. Keep the compositor's status for the main loop.

* **A `Handle` is not a pid.** Hold it for as long as you may signal; a bare
  `kill(pid)` is only safe while you have not reaped the child. `pid()` is
  null once reaped, but an unreaped zombie keeps its pid: check `exited()` too.
* **`Child` reaps, `Child.observe` does not.** Use `observe` when another owner
  (`session/services.zig`) collects the status; two reapers race.
* **Watch directories, not files**, so atomic replacement is seen. Adding a
  watched directory again returns the same `Watch` and queues nothing: add the
  new watches before removing the old. `isChange()` is "something happened or
  events were lost"; `lost()` means re-add the watch. Prefer `written` and
  `moved_to` over `modified` (often half-written).
* `drain` returning `error.Broken` means stop using the watcher. Callbacks may
  add watches, not call `drain`. Event names are valid only in the callback.
* **Seccomp filters are built, not linked** (no libseccomp): `Builder` takes a
  caller-owned buffer, so a program can be built after the filesystem is closed
  and nothing allocates. Rules match in order; `ruleArg` compares all 64 bits
  and falls through on a mismatch. The header kills a foreign arch and an x32
  number, but not -1 (a tracer's skip number: it gets the default action, as
  libseccomp did; under an allow-by-default policy such as the theme helper's
  it reaches the kernel, which answers ENOSYS). Use `seccomp.number("name")` (null where an architecture
  dropped the call) and keep optional legacy names in a separate list from
  required ones, so a typo is a compile error and not a silent hole. Load with
  `install` only after `PR_SET_NO_NEW_PRIVS`, single-threaded; it goes through
  libc `syscall()` so `tests/pdf_sandbox_hook.c` can fail it. `linux.AUDIT.ARCH`
  does not compile in Zig 0.17: use `seccomp.audit_arch`. A policy change is
  checked by evaluating both programs over all numbers and argument samples
  (`seccomp.evaluate`), not by trusting a read.
* **Programs that run as root or get a secret** (`pkexec`, `systemctl`) are
  found with `tool.system`, which searches only the root-owned system
  directories. Everything else is looked up on `PATH` (`config.app_theme.executable`)
  or spawned by bare name, which `std.process.spawn` resolves on the process's
  `PATH`; never write `/usr/bin/<tool>`, ports live in `/usr/local`.
* **`peer.of` names the socket's creator,** as of `connect` or `socketpair`; it
  says nothing about who writes later (a forked child shares the descriptor).
  `null` means refuse. `peer.h` needs `_GNU_SOURCE` on Linux (glibc hides
  `SO_PEERCRED` without it). FreeBSD reads `LOCAL_PEERCRED`; a kernel that
  leaves `cr_pid` 0 gives no answer, so the peer is refused.
* **FreeBSD handles are kqueues** (`child_freebsd.zig`): readable once the
  process exited and never drained, so `exited()` is a `poll`. `signal` refuses
  after the exit event instead of trusting the pid; `peer` has no counterpart
  and `pid()` cannot tell a reused number after a reap. `alive()` is false for
  an unreaped zombie there, true on Linux.
* **`fs.renameNoReplace` is atomic only on Linux.** FreeBSD hard-links and
  unlinks (a failure leaves both names) and checks-then-renames a directory.
* **`dirwalk.Reader` names are valid until the next call.** The Linux reader
  fills the caller's buffer (the walk keeps one per depth); FreeBSD's ignores
  it and opens its own `DIR` on a copy of the descriptor. `mount_root` is a
  Linux answer; FreeBSD's walk stops at a different device only.
* Nothing here arms a timer or starts a thread; a caller retrying a failed
  `add` owns that clock.

Still direct Linux calls (later steps of the plan): the DM's event loop and
process calls (`signalfd`, `epoll`, `poll`, `fork`, `kill`, `wait4`; it is not
built on FreeBSD), the
terminal's per-message `SCM_CREDENTIALS` check (`files/terminal/engine.c`, which
refuses to start a terminal on other systems), the DRM driver ioctl in
`Output.zig` and the two seccomp policy tables. Everything else outside this
directory calls libc or `std.posix`.
