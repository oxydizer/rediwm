# System Monitor

* `proc.zig`, `collector.zig`, `model.zig` and `actions.zig` have no compositor
  or UI dependencies. IPC reuses the stat reader but keeps its window-only,
  request-driven sampling contract.
* **`proc.zig` is the interface to the OS.** The record types and arithmetic
  are `proc_common.zig`; one backend reads them: `proc_linux.zig` (`/proc`, a
  `Process` holds the `/proc/<pid>` directory open) or `proc_freebsd.zig`
  (`kern.proc` sysctls; a `Process` holds the `kinfo_proc` taken at open, CPU is
  in microseconds). Never read
  `/proc` outside a backend; a new OS needs `Process`, `List`, `cpuTotals`,
  `memoryTotals` and `ticksPerSecond`. The Linux parsers are pure and tested
  everywhere through `proc_linux.zig`.
* A snapshot owns its arena. The worker publishes under its mutex through an
  eventfd; the UI takes ownership. A generation change cancels enumeration and
  publication, resets CPU baselines, and wakes the worker. Inactive workers
  block indefinitely. Never use NSS lookups here: a stalled account service
  would prevent joining the worker. Local passwd names fall back to numeric UIDs.
* Selections and confirmations own PID + start time, never row indices. Every
  action opens a pidfd first, checks the proc identity, UIDs and protected exe,
  verifies the pidfd's fdinfo identity and liveness, then signals that fd.
  Never fall back to `kill(pid)`. Tests signal only disposable fixtures.
* `App.ensureWidgets` runs after App has a stable address. Widget trees persist
  across snapshots so focus, presses and field strings survive. Callbacks set
  pending actions; modal tree changes happen after dispatch returns.
* Minimize suspension comes from xdg-shell v6, not keyboard focus. Restore
  respects Pause. The client uses released shm buffers and fractional-scale +
  viewporter; theme watches remain live while sampling is stopped.
* Tests: `zig build test-monitor`, `python3 tests/system_monitor.py`, and the
  latter with `REDIWM_TEST_SCALE=1.5`. User documentation: `docs/system-monitor.md`.
