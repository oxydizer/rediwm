# Files I/O service: handoff

State of the rediwm-files I/O migration as of 2026-11-26, for picking the work up
in a fresh context. Read this first, then the docs it points to.

## Where things are

* **Integration branch:** `feat/files-io-manager` on `oxydizer/rediwm`. Stage PRs
  target it; it goes to master later as a whole.
* **Open PR:** #69 `io/s3c` → `feat/files-io-manager`, "Files: archives through
  the service; no window Runtime (S3c, S4)" (commit `016d5b4`). Waiting for the
  user to test. **Do not merge until the user confirms.**
* **Merged this round:** #65 (S3b, JobRunner removed in `0a6e972`), #66 (a merge
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

## What PR #69 changed (for review or follow-up)

* Archives: a submit carries a purpose (`extract`, `member`, `export`);
  `io_coordinator_archives.zig` steps them (scan the staging for extract,
  close the publication barrier, hand member/export staging to the window via
  `archive_handoff`, delete staging on a worker). Window side:
  `app_archives.zig`.
* `StagingLease.deinit` (`clipboard.zig`) no longer deletes; it calls back into
  the service to dispose of the resource.
* Removed: the per-window Runtime and Manager, `app_transfer_rows.zig`,
  `app_transfer_tree.zig`, `transfer_tree.zig`, `TransferEntry` /
  `TransferManifest`, the legacy sidebar job row and tooltip, Escape-to-cancel,
  and every exemption in `io_thread_guard.zig`.
* Task code moved out of `io_coordinator.zig` into `io_coordinator_tasks.zig`
  (the line limit).
* Tests: `app_archives_tests.zig` (extract of 301 entries, extract conflict
  answered with Skip, member open and dispose, clipboard export, drag, Open
  With) on the `ServiceApp` harness from `app_transfers_tests.zig`.

**Ask the user to test:** extract into a folder with some of the files already
there (conflict dialog), double-click a file inside an archive, copy-paste a
folder out of an archive, drag a file out, Open With on a member, close a
window right after each, and `python3 tests/files_controls.py --archive-only`.

## Remaining work, in order

1. **Merge #69** once the user confirms.
2. **U16, the reaper** (last item of S3). `Client.destroy` → `worker.deinit`
   joins helper threads (listing worker, folder sizes, thumbnails, Trash
   totals) on the UI thread. Hand them to a reaper thread that joins them
   off the UI thread. Afterwards strike U16 in the threading doc and mark S3
   done in the architecture doc ("done when" in S3 lists it).
3. **S5, limits and validation:** per-pass command quotas, a time-based
   progress rate limit, capacity calibration, and a measured UI-latency check
   under heavy concurrent I/O (big copies, many small files, extraction, a
   stalled FUSE mount, two or more windows). Close any gap the measurement
   finds. The measurement needs the user's machine; build the harness here.
4. **S6, endpoint and single instance:** one private endpoint per Files
   process on its own thread; `open_window` (launching Files while one runs
   opens a window in it, headless included); `subscribe` and job control for
   the shell's tray panel. See the IPC contract doc.
5. **Backlog** (`files-io-backlog.md`), top first:
   1. Tabs as drop targets: needs titlebar-tabs protocol v3 in the compositor
      first (its own branch from master), then Files.
   2. The stalled re-copy to a USB drive: the likely cause (the conflict
      dialog closing at once) was fixed when JobRunner went. Ask the user to
      confirm; close the item if it no longer happens.
6. **Smaller:** split `src/files/app_pointer.zig` (931 lines, over the limit);
   perhaps a Replace answer in the file-conflict dialog; roadmap phases 1 and 3
   to 8 in `files-io-manager.md`.

## Working rules

* **Testing:** the user tests in their worktree `/home/anon/Projects/rediwm-io`
  (pull the PR branch, rebuild). Their main checkout must not be touched.
  Merge a PR only after they confirm (they may waive testing explicitly).
* **Build here:** only Files builds in the sandbox; the compositor does not.
  ```
  export PKG_CONFIG_PATH=/home/claude/wlp/root/usr/share/pkgconfig
  zig build test-files
  zig build files -Doptimize=ReleaseSafe
  ```
  Zig 0.17. The one expected test failure is dirsize "unreadable folder" (the
  sandbox runs as root). Last run on `io/s3c`: 512 passed, 4 skipped, that one
  failure.
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
