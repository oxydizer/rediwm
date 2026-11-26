# Files I/O service: handoff

State of the rediwm-files I/O migration as of 2026-11-26 (after #71), for picking the work up
in a fresh context. Read this first, then the docs it points to.

## Where things are

* **Integration branch:** `feat/files-io-manager` on `oxydizer/rediwm`. Stage PRs
  target it; it goes to master later as a whole.
* **Open PR:** #71 `io/s5` → `feat/files-io-manager`: the command quota,
  `bench-files-io`, and the agreed worker-pools design. **The user approved
  merging it**; merge, then start building the design.
* **Merged this round:** #70 (U16, the reaper; S3 done), #69 (S3c, S4: archives through the service, with the
  toolbar Copy inside archives), #65 (S3b, JobRunner removed in `0a6e972`), #66 (a merge
  leaves identical files alone; "Apply to all" in the conflict dialog).

## Design docs (source of truth)

* `docs/plans/files-io-service-architecture.md`: the stages S1 to S6 and their
  "done when" conditions.
* `docs/plans/files-io-threading-and-ownership.md`: threads, ownership, the
  exemption table (U1 to U17, C1 to C3). Struck-through rows are done.
* `docs/plans/files-io-manager.md`: the Manager (job model, ledger, publication
  barrier).
* `docs/plans/files-io-ipc-contract-deferred.md`: the external endpoint contract
  (S6).
* `docs/plans/files-io-backlog.md`: FIFO backlog of things seen in testing.
* `src/files/AGENTS.md`: module map and repo rules for Files.

## Architecture in one paragraph

One coordinator thread per Files process (`io_coordinator*.zig`) owns the
Runtime, the Manager and the executors. Each window holds a `Handle` and talks
to it only through an outbox of commands and requests (`io_requests.zig`,
`io_service_commands.zig`); the coordinator answers with job records, reply
slots and job views. Blocking work the coordinator must not do itself runs as
service tasks on workers (`io_service_tasks.zig`). Resources (staging folders
and the like) sit in a ledger with an owner (`operation_executor`,
`operation_worker`, `window`); `handResourceToWindow` gives one to a window and
the window returns it with `dispose_resource`, after which a worker deletes it.
The window side lives in `app_service.zig`, `app_transfers.zig`,
`app_archives.zig`, `app_requests.zig` and `app_jobs_card.zig`. Windows no
longer have a Runtime, a Manager or an executor of their own.

## What S5 has so far (#71)

* `io_service.command_quota` (16): `Service.receiveCommands` takes up to that
  many per coordinator pass under one lock (round-robin, control first); a full
  batch skips the wait. Test in `io_service_tests.zig`.
* The progress rate limit was already there (50 ms records and views, 250 ms
  deletions).
* `bench-files-io` (`src/files/io_bench_tests.zig`, step in `build/tests.zig`,
  documented in `TESTING.md`). Findings in `files-io-worker-pools.md` §2: the UI
  thread is fine; a dead mount stalls the task pool (two stalled prepares) and,
  mid-copy, every other transfer (one job holds both operation workers).
* `files-io-worker-pools.md`: the agreed design. Decisions (its §6):
  `suspect_after` 10 s (internal, reroutes work), `report_after` 30 s
  ("Waiting for <mount>…"), no "dead" state; one stall domain per `st_dev`,
  device limit from the block device behind it, else the lane target; the
  deletion pool stays its own lane on one shared filesystem table; requests
  before prepares in the task lane, no request pool.

## Remaining work, in order

1. **Merge #71** (approved).
2. **S5, the worker pools**, in the order of `files-io-worker-pools.md` §5,
   one PR per step from `feat/files-io-manager`:
   1. Staging lane (4.1): done in #73 (2 workers; staging is on the destination mount, not private).
   2. Per-job limit (4.4, first half): done in #74 (3 operation and discovery workers, at most 2 operation workers per job, even alone).
   3. Split in three: 3a request priority (4.6, #75); 3b stall detection and
      reporting with the mount table (4.2, #76); 3c suspect-domain holds (4.2,
      #77; the deletion lane is not covered yet).
   4. Elastic user-path lanes (4.3): done in #79.
   5. Per-device limits (4.4): done in #80, off by default (21 % slower on
      the user's USB HDD).
   Check each with the bench: `STALL_MODE=prepare` for the task-pool gap,
   `running` for the executor gap; done when every other job finishes and the
   probe stays at its unloaded value.
   Run the bench: `REDIWM_RUN_BENCHMARKS=1 REDIWM_IO_BENCH_DIR=<dir> zig build
   bench-files-io`; for a dead mount add `REDIWM_IO_BENCH_STALL=<folder on a
   FUSE mount>`, `REDIWM_IO_BENCH_STALL_PID=<its daemon>` and
   `REDIWM_IO_BENCH_STALL_MODE=prepare|running`, and
   `REDIWM_IO_BENCH_LIMIT_S=30` so a stalled run reports instead of waiting.
   bindfs works in the sandbox: `bindfs <src> <mnt>`, `pgrep -f bindfs` for the
   pid; `kill -CONT` it if a run is killed, or the mount stays hung.
3. **S6, endpoint and single instance:** one private endpoint per Files
   process on its own thread; `open_window` (launching Files while one runs
   opens a window in it, headless included); `subscribe` and job control for
   the shell's tray panel. See the IPC contract doc.
4. **Backlog** (`files-io-backlog.md`), top first:
   1. Tabs as drop targets: needs titlebar-tabs protocol v3 in the compositor
      first (its own branch from master), then Files.
   2. (Closed: the stalled re-copy to a USB drive was the conflict dialog not
      showing, fixed with JobRunner's removal.)
   3. An extraction counts folders as done but not in its total (5 100 of
      5 000).
5. **Smaller:** split `src/files/app_pointer.zig` (931 lines) and `worker.zig` (860),
   both over the limit;
   perhaps a Replace answer in the file-conflict dialog; roadmap phases 1 and 3
   to 8 in `files-io-manager.md`.

## Working rules

* **Testing:** the user tests in their worktree `/home/anon/Projects/rediwm-io`
  (pull the PR branch, rebuild). Their main checkout must not be touched.
  Merge a PR only after they confirm (they may waive testing explicitly).
* **Build here:** only Files builds in the sandbox; the compositor does not.
  A fresh workspace needs setting up first (codeberg, leonerd.org.uk,
  ziglang.org and gitlab.freedesktop.org are blocked; PyPI, apt, the Ubuntu
  archive and `git clone` from GitHub work):
  ```
  pip install --break-system-packages ziglang==0.17.1   # link its zig into PATH
  apt-get install pkg-config libcairo2-dev libglib2.0-dev libwayland-dev \
    libxkbcommon-dev libarchive-dev libjpeg-dev libpng-dev libwebp-dev \
    libgdk-pixbuf-2.0-dev librsvg2-dev libpango1.0-dev libpoppler-glib-dev \
    libpulse-dev libpipewire-0.3-dev libinput-dev libudev-dev libdrm-dev \
    libegl-dev libgles-dev libpixman-1-dev libcups2-dev libpam0g-dev \
    libreadline-dev libxcb1-dev libtorrent-rasterbar-dev libjson-glib-dev \
    wayland-protocols shared-mime-info g++
  # wayland-protocols 1.49 (Ubuntu pool, .deb) into /home/claude/wlp/root;
  # set prefix= in its .pc to that root.
  # Zig packages in /home/claude/zigpkgs/<hash>/: zig-wayland v0.7.0
  # (git clone from github.com/ifreund), libvterm 0.3.3 (the Ubuntu pool's
  # libvterm_0.3.3.orig.tar.gz, extracted). Then build with --system:
  export PKG_CONFIG_PATH=/home/claude/wlp/root/usr/share/pkgconfig
  zig build --system /home/claude/zigpkgs test-files
  zig build --system /home/claude/zigpkgs files -Doptimize=ReleaseSafe
  ```
  Zig 0.17. The one expected test failure is dirsize "unreadable folder" (the
  sandbox runs as root). Last run on `io/s5`: 518 passed, 5 skipped (the bench is
  one), that one failure. A wrapper with both settings is handy:
  `/home/claude/zb.sh` runs `zig build --system /home/claude/zigpkgs "$@"` with
  `PKG_CONFIG_PATH` set.
* **Code rules:** files at or under about 800 lines; App methods go in
  `app_*.zig` with an alias in `app.zig`; no test hooks in production code;
  the UI thread does no blocking I/O (`io_thread_guard.zig` has no exemptions
  left, keep it that way).
* **Git and GitHub:** branch per stage from `feat/files-io-manager`
  (`io/<name>`); push with `git -c push.negotiate=true push`; open and merge
  PRs with `gh api repos/oxydizer/rediwm/pulls` and
  `PUT repos/oxydizer/rediwm/pulls/N/merge`. The proxy sometimes resets a
  connection: retry once.
* **Attribution:** commit messages end with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and a
  `Claude-Session:` line for the current session; PR descriptions end with
  `🤖 Generated with [Claude Code](https://claude.com/claude-code)` and the
  session URL.
* **Debugging service jobs:** the window and coordinator log each step of a
  conflict (`Files job N waits on conflict M`, `Files window asks about
  conflict M`, `Files shows conflict`, `Files conflict dialog N closed`).
  Have the user run with `2>&1 | tee files.log`.
