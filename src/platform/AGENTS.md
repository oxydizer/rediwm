# Platform module

The one place the OS shows: child handles (`child.zig`), directory watching
(`watch.zig`), the program's own path (`exe.zig`), where the system's helper
programs live (`tool.zig`), seccomp-BPF filters
(`seccomp.zig`, for the PDF viewer and the theme helper), and
`child.h`/`self_exe.h` for C and C++. Std only, no compositor imports. Linux
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
* Nothing here arms a timer or starts a thread; a caller retrying a failed
  `add` owns that clock.

Still direct Linux calls (later steps of the plan's phase P): `signalfd`/`epoll`
in the supervisor and DM daemon, `kill`/`wait4`, `/proc` walks, `SO_PEERCRED`.
