# Platform module

The one place the OS shows: child handles (`child.zig`), directory watching
(`watch.zig`), the program's own path (`exe.zig`), who is on the other end of a
unix socket (`peer.zig`), process attributes such as no core dumps and no new
privileges (`process.zig`), descriptors that wake a poll loop (`wake.zig`),
where the system's helper programs live (`tool.zig`), seccomp-BPF filters
(`seccomp.zig`, for the PDF viewer and the theme helper), and
`child.h`/`self_exe.h`/`peer.h`/`process.h` for C and C++. Std only, no compositor imports. Linux
today; the FreeBSD port (`docs/plans/freebsd.md`) adds `freebsd_*.zig` parts
without changing callers.

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
  `null` means refuse. `peer.h` needs `_GNU_SOURCE` (glibc hides `SO_PEERCRED`
  without it) and, like `peer.zig`, refuses to build for another OS until the
  port.
* Nothing here arms a timer or starts a thread; a caller retrying a failed
  `add` owns that clock.

Still direct Linux calls (later steps of the plan): the supervisor's and the
DM's event loops and process calls (`signalfd`, `epoll`, `poll`, `fork`,
`kill`, `wait4`), `statx` and `getdents64` in Files and the IPC socket check,
`/proc` walks, and the terminal's per-message `SCM_CREDENTIALS` check
(`files/terminal/engine.c`). Everything else outside this directory calls libc
or `std.posix`.
