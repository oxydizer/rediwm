# Files I/O Service Architecture

**Status:** In progress. The service core (`io_service.zig`) and the
coordinator thread (`io_coordinator.zig`) exist and are owned by the process
(`main.run`). Windows talk to it only through their `Handle` (S3 and S4 are
done); S5 and S6 remain.

This document says what the I/O service is, who owns what, and how windows and
jobs relate. How it runs concurrently (threads, locks, queues, shutdown) is in
[Threading and Ownership](files-io-threading-and-ownership.md). The Manager
roadmap is in [Files I/O Manager roadmap](files-io-manager.md).

## 1. Why the service exists

One owner of filesystem work gives us four things the per-window design cannot:

1. **Closing a window or tab never cancels or corrupts an operation.** Jobs
   belong to the service, not to the window that submitted them.
2. **One bounded worker capacity and one resource ledger.** Opening more
   windows does not multiply workers, and resources have one accountable owner.
3. **The UI thread does no I/O orchestration.** Scheduling, completion
   reconciliation and cleanup run off the event loop.
4. **Any window can show and control any job.** A transfer started in one
   window can be watched, paused or resolved from another.

## 2. Decision: an in-process service thread

The earlier design put the service in its own session process behind a Unix
socket with a durable journal, restart recovery and a shell client. That is
dropped for now. Files already runs all its windows in one process (multi-window
and tab tear-off), and a service thread delivers the four goals above. The
separate process adds only survival of a Files crash or exit and visibility to
the shell, at the cost of a wire protocol, supervision, a journal and
per-operation recovery rules. None of that is needed to fix the problem we have.

| | Now | Deferred |
| --- | --- | --- |
| Service location | A thread in the Files process | A separate session process |
| Window to service | Bounded in-memory queues and a job table | Unix socket protocol |
| Jobs outlive | Windows (the process drains headless) | A Files crash or exit |
| Persistence | None | Journal and restart reconciliation |
| Shell integration | None | Shell client |

The boundary is designed so the move out of process stays possible without
touching the Manager or executors: commands are plain owned messages, state is a
table of copied records with ids and revisions, and nothing crosses it as a
pointer. See [Deferred](#12-deferred-out-of-process-service).

**Consequence:** the Files process outlives its last window while jobs are
active. It runs headless (no Wayland, no UI), finishes the accepted work and
then exits. See the shutdown section of the threading document.

## 3. Components and ownership

```text
Windows (UI thread)                     Coordinator thread                Workers
  Client + App + Handle                   Manager, Runtime, ledger,         2 discovery
        |                                 executors                         2 operation
        | commands (bounded)                      ^   |
        v                                         |   | dispatch / completions
  +------------- Service (one mutex) -------------+   v
  | window registry | command rings | job table | wake fds |
  +--------------------------------------------------------+
        ^
        | job table delta (by cursor) + wake
        +--- windows
```

| Owner | Owns | Must not |
| --- | --- | --- |
| Process (`main.run`) | Creating the Service and Coordinator before the first window and destroying them after the last one | Hand out Manager, Runtime or executor pointers |
| Service | Window registry, bounded command rings, the job table, the two wake descriptors | Know about Manager internals, hold a UI pointer, or do I/O |
| Coordinator | The only access to the Manager, Runtime, resource ledger and executors | Block on a worker, a filesystem call or a user decision |
| Workers | One bounded unit of filesystem work at a time, returned as an owned completion | Touch Manager state or UI objects |
| Window | Wayland and UI objects, tabs, navigation, selection, a `Handle`, local presentation state | Call Manager or Runtime, drain worker queues, or invent job state |

Workers are shared capacity, two discovery and two operation workers for the
whole process. They are not per window and not per job.

## 4. Windows and jobs

* Job ids are service-wide and never reused.
* A job records the window that submitted it (`origin_window_id`) as metadata.
  It is not a lifetime owner and not an authorization boundary.
* **Any window can view and control any job**: pause, resume, cancel, resolve a
  conflict. There is no origin check. This is one user in one process.
* A window registers with the Service when it is created and unregisters when
  it is destroyed. Unregistering drops that window's view state. It never
  cancels, retires or otherwise touches a job.
* Commands a window had already queued when it closed are still processed.
* Window ids are never reused, so a stale `Handle` copy fails cleanly.

## 5. Interface

### Commands (window to service)

Commands express intent and are admitted without blocking. A successful enqueue
does not mean the transition happened; the job table shows what happened.

| Command | Payload | Class |
| --- | --- | --- |
| `submit_job` | Owned `TransferRequest` (mode, destination, sources) | normal |
| `start_discovery`, `prioritize_discovery` | Job id and an owned discovery request | normal |
| `pause_job`, `resume_job`, `cancel_job` | Job id | control |
| `resolve_conflict` | Owned request: conflict id, action, optional rename path | control |
| `release_borrow` | Resource id of a borrow this window holds | control |
| `dispose_resource` | Resource id of a window-owned resource. Ownership moves back to its executor, which destroys it on a worker | control |
| `request` | Owned metadata or small-mutation request (threading §8). Reply goes to the window's reserved reply slot | normal |

There is no `retire_job` command. The service retires terminal jobs itself (§6).
A command whose omission could leak a resource must not exist: cleanup is the
service's duty, not a request a window may forget or fail to send.

Admission is bounded per window, with a separate allowance for control commands
and an aggregate cap. A full queue returns an explicit error. The UI shows a
notice for a user-initiated command and does not retry silently, and it never
assumes the command was accepted.

### State (service to window): the job table

The service keeps a bounded table of copied job records. Windows read it by
cursor. They do not receive a stream of events.

```text
JobRecord {
    id, origin_window_id, kind (copy, move, extract, ...),
    submit_tag,                  // chosen by the submitting window, echoed back
    label,                       // fixed-size display name, e.g. first source and item count
    state,                       // io_manager.JobState
    completed_bytes, total_bytes, rate_bytes_per_second,
    completed_items, total_items,    // files and directories, for "12 of 340"
    started_at, finished_at,         // wall clock, for elapsed time and history
    pending_conflict: ?ConflictId,   // set on the job at the head of the conflict queue
    offered_resource: ?ResourceId,   // e.g. finished extraction staging a window may borrow or take
    borrow_count,                    // borrows outstanding; non-zero blocks retirement
    error_code,                  // set when state is failed or completed_with_errors
    revision,                    // service sequence at the last change
    removed,                     // tombstone, see below
}
```

* Records hold no pointers and no slices, so a copy of one is always valid. The
  `submit_tag` lets a window recognise the job it just submitted. The `label`
  lets any window name a job it did not submit.
* A window keeps a `cursor`. `fetchChanges(cursor)` returns the records whose
  `revision` is greater than the cursor, in revision order, with a `more` flag.
* The state is level-triggered. If a window misses a wake, or reads late, the
  next fetch still returns the current record of every live job.
* A window registering late starts at cursor 0 and sees every live job.
* Capacity is fixed: `max_live_jobs = 64`, 16 outcome slots per window and a
  64-entry tombstone ring (threading §6). **A consumer never occupies
  live-table capacity.** Retirement depends only on the job.
* The origin window gets every outcome of its own jobs (the slot is reserved at
  submit). Other windows get a bounded tombstone ring and an explicit `resync`
  if they fall behind it. A window that stops reading can block only its own next
  submit (`WindowOutcomesFull`), never another window's and never retirement.
* A submit into a full live table is rejected with `TooManyJobs`.

## 6. Job lifecycle

States are the Manager's: `planning`, `queued`, `running`, `finalizing`,
`paused`, `waiting` (a conflict needs a decision), and the terminal states
`completed`, `completed_with_errors`, `failed`, `cancelled`.

* **Commands and states are separate.** `pause_job` leads to `paused` only at a
  safe pause point. `cancel_job` leads to `cancelled` only after workers have
  stopped and cleanup is done.
* **Retirement is automatic and depends only on the job.** A terminal job is
  retired when the executors are quiescent for it, the ledger holds no job-owned
  resource for it, and no window holds a borrow on its resources. Cursors play no
  part. The final record goes to the origin window's outcome slot and to the
  tombstone ring. A window that wants to keep a finished transfer on screen keeps
  its own copy of the record it saw.
* **Failure is contained.** A filesystem error fails the operation and the job
  that hit it. It does not stop other jobs.

### Conflicts

The Manager keeps one FIFO conflict queue, and only its head can be resolved.
That head is shown on its job record as `pending_conflict`. Any window may
resolve it.

When no window is registered (headless drain), no one can answer. The service
resolves every conflict as `cancel` for its job. This is deliberate: it can never
overwrite data unasked, and it can never leave the process waiting forever for an
answer nobody can give.

### Resource ownership

Every resource has exactly one **cleanup owner** at a time, recorded in the
ledger. The cleanup owner is the only party that may physically destroy it, and
it does so through a worker when destruction can block (threading §8). A
**borrow** is separate from ownership. It is permission to read a resource that
someone else owns, and it delays that owner's cleanup.

| Class | Ledger owner | Examples | Who destroys it | What closing a window does |
| --- | --- | --- | --- | --- |
| Executor-owned | `operation_executor`, `discovery_executor` | Archive staging before hand-off, discovery anchors and retained cursors, archive cancellation state | The executor, on the coordinator for bounded cleanup and on a worker otherwise | Nothing, even for jobs that window submitted |
| Held by an active operation | `operation_worker`, `discovery_worker` | In-flight discovery cursors, operation payloads and their descriptors | Nobody while the unit is in flight. The completion path transfers it back to the executor | Nothing. Cancellation does not free it either (threading §9) |
| Window-owned | `window(window_id)` (new owner variant) | Clipboard, drag, Open With and opened-member staging after hand-off | The owning window *decides* when, by `dispose_resource`. That moves ownership back to the executor, which destroys it on a worker | Every resource owned by that window is moved to its executor for disposal |
| Borrowed | Owner unchanged, plus a borrow `{resource, window_id}` | A window reading a finished extraction it has not taken | The owner, after the last borrow is dropped and the job is terminal | Its borrows are dropped. The owner then cleans up as usual |

Rules the ledger enforces:

* **Transfers are explicit and checked.** `transfer(handle, expected, new)` fails
  on a mismatch. A resource is never owned by two parties, and never by nobody
  while it still exists.
* **Window close touches only `window(W)` records and W's borrows.** The
  coordinator does this when it observes the slot in `closing`. It never calls
  `release` on an executor-owned or worker-held record on a window's behalf.
* **A window can release only what it holds.** `release_borrow` and
  `dispose_resource` check the holder, not the job's origin. This replaces the
  origin check in today's `releaseResource`, which is removed in S2. Any window may
  still *control* any job (§4).
* **Hand-off out of Files.** The clipboard, drag and Open With hand-offs change the
  owner from the executor to `window(W)`, instead of today's `transferOut`, which
  drops the record. That gives the resource an accountable owner for its whole
  life. It also means `StagingLease.deinit` stops deleting on the UI thread: the
  window disposes through the service.
* **Retirement.** Window-owned resources no longer count as job-owned, so they do
  not block retirement (unchanged meaning). Borrows do block it. Each window can
  hold at most 4 borrows, and close drops them, so a stalled window delays at most
  those jobs.
* **Commands in flight.** A `dispose_resource` still queued when its window closes
  is processed (§4). The close-time sweep skips records that already have a
  pending dispose, so nothing is disposed twice.

Since S4 no window touches archive staging: a `scan_staging` service task lists an
extraction's top level, the coordinator registers the publication roots, and
staging is deleted on a worker or handed to the window that asked for it
(`io_coordinator_archives.zig`).

## 7. Responsiveness

**UI responsiveness under heavy filesystem I/O is a hard requirement and an
acceptance criterion of every stage from S1 on.** The UI thread never performs a
potentially blocking filesystem operation, never waits on a worker, an executor, a
service response, a join or a lock, and only submits requests and consumes
asynchronous results. The coordinator performs no potentially blocking filesystem
operation either. The full rule set, the debug guard that enforces it, and the
audit of every current violation with the stage that removes it are in threading
§1, §3 and §13.

S5 does not make anything asynchronous for the first time. By the end of S4 the
exemption table is empty. S5 adds limits and measurement on top.

## 8. Failure semantics

| Event | Result |
| --- | --- |
| A window closes | Its jobs continue; its queued commands still run; its borrows are dropped and its window-owned resources are disposed by their executor |
| A window stops reading | Retirement and other windows are unaffected; it gets its own outcomes when it reads again; it may be refused new submits after 16 unread outcomes |
| All windows close | The process runs headless, finishes accepted work and exits |
| One job hits an error | That job reports it; other jobs continue |
| Queue full | Explicit rejection; nothing blocks, nothing is lost silently |
| Files exits abnormally | Jobs die with the process (the known limit of the in-process choice) |
| Coordinator thread bug | The process aborts. It is not caught and continued |

For the abnormal-exit case, operations must already be safe to interrupt at any
point: partial output never appears under a final name, and staging is under a
known directory so a later start can sweep it. These belong to Manager roadmap
phase 5. They do not need a journal.

## 9. Stages

Each stage is independently reviewable and ends with the full Files suite
green. Commit and push after each. **Every stage's acceptance includes the
responsiveness criterion:** the debug guard passes with no exemption added, the
exemptions listed for that stage are removed (threading §13), and the
hung-worker tests of threading §12 that cover that stage's paths pass.

**S0, done. Kept as is unless noted.**
* Owned command contract (`OwnedPayload`, `trySendOwned` ownership transfer). Kept.
* Bounded admission: per-window, control and aggregate caps. Kept.
* Coordinator thread; discovery and conflict handling. Kept. Its inline
  `stat`/`lstat`/`readlink` (C1) and its per-command `snapshotJobs` (C3) are revised
  in S1 and S2.
* Copy and move of files, symlinks and directories through the coordinator. Kept.
* Executor-owned resource release, including its refusal of worker-held and App-owned
  resources. Kept. Its inline `deleteRecursive` (C2) becomes a cleanup task in S2,
  and its origin check becomes a holder check in S2.
* Per-window `Handle` (`Client.io_handle`). Kept. Its close spin is fixed before S1.
* Per-window update rings, coalescing and the resync marker. **Replaced** in S1.
* Process-owned lifecycle in `main.run`. Kept.

**Before S1.**
* Merge these plan docs.
* Make `Handle.close` atomic and non-failing, and delete the `closeIoHandle` spin
  (U17). Make `registerWindow` lock-free. Update the contention test (threading §3).
* Debug builds: errorcheck mutex, and assert pthread return codes.
* Fix the capacity constants (threading §6) in `io_service.zig`.
* Add the debug UI-thread and coordinator-thread guard with the exemption table
  of threading §13, U1 to U16 and C1 to C3, so S1 is already measured against it.
* Add the hung-worker test fixture: a worker unit that parks on a gate the test
  controls.

**S1, job table. Done** (`1935a68`..`a2158cb` on `io/before-s1`): `io_job_table`,
the Service integration, `io_window_link` (outbox and reader), O(1) Manager
summaries, record publication, external consumer slots. Deviation: no dirty set
(threading §6).

**S1 as planned:**
* Replace the per-window update rings, coalescing and resync marker with the live
  table, outcome slots, tombstone ring and cursor fetch (§5, threading §6).
* UI-side `trySend` and `fetchChanges` stay fail-fast. Add the window outbox and
  `fetch_pending` (threading §3).
* Add the Manager's O(1) per-job summary and dirty set.
* Cursors belong to **consumers**, not only windows: a window, or an external
  subscriber (§13). The registry has `max_windows` window slots and
  `max_external_consumers` (4) external slots. Only windows have outcome slots;
  an external consumer sees final records through the tombstone ring and resync.
* A per-job rate history (§13) is kept beside the table, so a panel opened in the
  middle of a transfer can draw its speed graph from the start.

*Done when:* a late-joining window sees all live jobs; a window that never reads
loses none of its own outcomes or pending conflicts, does not delay retirement and
does not block other windows' submits; a lagging foreign window resyncs to exactly
the live set; and the coordinator no longer calls `snapshotJobs` on its loop (C3).

**S2, lifecycle and coordinator hygiene. Done** (`24cf07c`..`8d7b934` on `io/s2`),
except the last-window confirmation and headless notifications, which moved to S3:
both need windows that submit through the service and read the job table, which
starts in S3. The coordinator exemption list is empty.

**S2 as planned:**
* Draining shutdown (threading §10); headless drain after the last window.
* Closing the last window while ordinary jobs run asks first: keep them running
  in the background, or cancel them. Archive extractions are listed as being
  cancelled in either case (threading §10).
* While headless, each job's end (completed, failed, or cancelled because a
  conflict had no one to answer it) sends a desktop notification. Once the shell
  panel exists (S6), the notifications stay as a fallback for a shell without it.
* Automatic retirement (§6).
* Resource ownership classes (§6): the `window(id)` owner, borrows, close-time
  sweep, `release_borrow` and `dispose_resource`. These replace the origin checks in
  `resolve_conflict` and `release_resource`. Remove `retire_job`.
* Conflict auto-cancel with no window.
* Prepare tasks for `submit_job` and cleanup tasks for executor-owned resources
  (threading §8). This was in S5 and moved here (C1, C2).

*Done when:* an accepted cross-filesystem move finishes, including its detach
step, after the last window closes; a job whose origin window closed can have its
conflict resolved from another window; closing a window never releases an executor
or worker resource; and the coordinator exemption table is empty.

**S3, windows move onto the service** (the earlier stages 3 and 4, combined). **Done.**
* S3a. Delete, move to Trash, Empty Trash and Trash deletion as service jobs, and
  metadata and small mutations as requests (U4 to U12). No phase-2 dependency, so
  this can land first.
  *Jobs done:* deletion jobs are service jobs without a Manager job. Their ids
  are a range of their own (`1 << 62` up), their records are kept by the
  coordinator (`io_coordinator_deletions.zig`) and they retire as soon as they
  end. The window sends the submit through its outbox and learns the end from
  its outcome slot (`app_service.zig`); the main loop polls the service's update
  wake for every window. U4 to U6 are removed.
  *Requests done:* a `request` command carries an owned request
  (`io_requests.zig`); admission reserves one of the window's four reply slots,
  the coordinator hands it to a service task, and the reply lands in the slot.
  The window keeps a pending entry per tag (`app_requests.zig`) and finishes
  the action when the reply arrives, so dialogs, places, pins, the chooser,
  drops and the terminal never stat or resolve a user path themselves. U7 and
  U9 to U12 are removed; U8 keeps only the conflict rename, which goes with
  the Transfers UI in S3b.
* S3b. Prerequisite: the Coordinator accepts mixed file and directory selections
  (done in phase 2a), so JobRunner's fallback can go. **Done:** JobRunner, its
  tests and benchmarks are deleted. This is roadmap phase 2. Then the App submits transfers through its
  `Handle` (U1, U2), and the Transfers UI renders from job records through the
  source-agnostic presentation layer of §13, which torrent rows use too.
* S3b also: closing the last window while service jobs run asks first (keep them
  running in the background, or cancel them), and jobs that end while headless send
  a desktop notification. Moved here from S2.
* S3b also: **job views**, for what job records cannot carry. Records hold job
  totals. Ghost rows, per-item progress rings, the Transfers tree and browsing
  inside a running transfer need per-entry state, which today the window reads
  straight from its own Manager. With the Manager on the coordinator, a window
  *subscribes* to what it shows and the coordinator pushes it (§14).
* S3c. `Client.io_runtime` and `App.io_runtime` are removed (U3). This is when the
  per-window Runtime stops existing. **Done together with S4**: archives were the
  Runtime's last users. The helper threads that remain (listing worker,
  folder sizes, thumbnails, Trash totals) go to a reaper (U16). **Done**:
  `reaper.zig`.

*Done when:* no production code outside the coordinator touches `io_runtime`,
`io_manager` or an executor, `JobRunner` is gone, and U1 to U12 and U16 are
removed.

**S4, archive lifecycle.** **Done** (with S3c): archive submits carry a purpose
(extract, member, export); the coordinator steps them (`io_coordinator_archives.zig`),
and a window takes member and export staging with an `archive_handoff` request
(`app_archives.zig`).
* Staging, publication barrier and cancellation move to the service.
* The publication cursor becomes service-owned (U13). Staging discard runs on a
  worker (U14).
* UI hand-offs become `window(id)`-owned resources disposed through the service.
  `StagingLease.deinit` no longer deletes (U15).
* The publication-barrier and ledger invariants are preserved as they are.

*Done when:* the UI exemption table is empty.

**S5, limits and validation.** Nothing becomes asynchronous here for the first
time.
* Per-pass command quotas. **Done**: `command_quota` (16) commands per pass,
  taken by `Service.receiveCommands`; when the quota is hit the next pass starts
  without waiting.
* Time-based progress rate limit. **Done** (already in place): job records and
  job views publish progress at most every 50 ms, deletions every 250 ms, state
  changes at once.
* Calibrate capacities (live table, outcome slots, tombstones, queues) with phase 7.
* A measured check that the UI thread stays responsive under heavy concurrent I/O:
  event-loop iteration latency under concurrent large copies, many-small-file
  copies, archive extraction and a stalled FUSE mount, across two or more windows.
  **Harness done:** `bench-files-io` (`io_bench_tests.zig`). The UI thread
  stays responsive; two gaps are in the worker pools: a dead mount stalls the
  service task pool (requests, extraction scans) and, while a copy runs, every
  other transfer. See [worker pools](files-io-worker-pools.md).
* Close any gap found by the measurement: the plan in
  [worker pools](files-io-worker-pools.md), under review.

**S6, external endpoint and single instance** (§13). Needs S3, so that every
window renders from the job table.
* One private endpoint owned by the Files process, served by its own endpoint
  thread.
* `open_window`: launching Files while a Files process runs, headless or not,
  opens a window in that process instead of starting another one.
* `subscribe` and job control for the shell's tray icon and panel.

*Done when:* launching Files during a headless drain opens a window that shows the
running transfers, and a test client subscribed to the endpoint sees every job
from submission to its final record, pauses and resumes one, and recovers through
resync after it stops reading.

## 10. Constraints

* No Manager, Runtime, executor or ledger pointer is reachable from window code.
* No Runtime, Manager or worker pool per window.
* Jobs never depend on a window staying open.
* Do not weaken the Manager state machine, the resource ledger or the archive
  publication barrier to fit the service.
* One `max_windows` constant, defined in `io_service.zig`, used by `main.zig` too.

## 11. Non-goals

* A general file-operation platform or a public SDK.
* A wire protocol, a journal or restart recovery before a trigger in §12 is reached.
* Automatic retry or resume of interrupted operations.

## 12. Deferred: out-of-process service

Revisit only when one of these is a concrete requirement:

* Jobs must survive a Files crash or exit. The headless drain does not cover
  this.
* The shell must show or control file activity while **no** Files process is
  running. Showing and controlling it while one runs, headless included, is the
  S6 endpoint (§13), not a trigger.
* A second program needs to submit jobs.

If it happens, the agreed contract is kept in
[files-io-ipc-contract-deferred.md](files-io-ipc-contract-deferred.md). The
in-process boundary was shaped to make this a transport swap, not a rewrite:
owned command messages in, a revisioned table of copied records out. The things
that would still need real design are the journal and per-operation recovery
rules. A recorded intent does not prove the filesystem action did not already
happen, so recovery cannot be generic. Do that work per operation when it is
needed, not before.

## 13. External endpoint: the shell panel and single instance

The service is the backend for the shell's file-activity tray icon and panel:
all active jobs, with pause, resume and cancel, and transfer-speed graphs. It is
also how a second launch of Files finds the running process. Both use one
endpoint, built in S6.

Because the Files process stays alive while it has jobs (headless drain, S2), the
shell can always reach the jobs it has to show while a Files process is running.
This needs no separate service process, no journal and no restart recovery: the
in-process decision of §2 stands.

**Transport.** A private Unix stream socket, `files-io.sock` in the Files runtime
directory. Like `files-transfers.sock`, it is deliberately outside
`rediwm-*.sock` compositor discovery. The directory is private, the socket is
created with umask 0177, and both ends check peer credentials (same uid). The
message envelopes, `subscribe` snapshot and sequence semantics, backpressure and
error codes follow the deferred contract
([files-io-ipc-contract-deferred.md](files-io-ipc-contract-deferred.md) §2, §3,
§7, §8, §9, §10). Its journal, recovery and idempotency sections (§4.1, §6) do
not apply.

**Threading.** An endpoint thread owns the listening socket and the client
connections, all non-blocking. It is a consumer of the Service like a window:
it holds an external consumer slot per subscriber, reads by cursor and queues
control commands through the Service's rings. It never runs on the UI thread or
the coordinator, and it never touches the Manager.

**Subscribers map onto the job table.** `subscribe` is a fetch from cursor 0
(the snapshot), then deltas by cursor. Each client has a bounded output buffer.
A client that stops reading stops advancing its cursor, and it can block nothing
but itself (threading §6). If it falls behind the tombstone ring, it gets the same
`resync` a window gets. A client that has not read for a long time is
disconnected, and reconnecting starts from a new snapshot.

**Controls.** `pause_job`, `resume_job` and `cancel_job` from the shell are
ordinary control commands. A pending conflict is shown in the panel with an
action that opens a Files window on it (`open_window` with the job id). The
conflict dialog stays in Files.

**Speed graphs.** The service keeps a fixed rate history per live job (one
sample per second, 120 samples), beside the job table rather than inside every
record. A record copy therefore stays small, and a panel opened mid-transfer
can still draw the graph from the start. The history goes with the job when it
retires.

**Single instance.** `open_window(path?, job?)` asks the running process to open a
window. A Files launch first tries the endpoint. If the endpoint answers, the new
process hands over its arguments and exits; otherwise it becomes the instance.
A headless process reconnects to the compositor for the new window.

### One Transfers panel for file operations and torrents

The shell shows **one** Transfers tray icon and panel, for Files jobs and torrents
together. Long term, torrents should feel like file management: a torrent opens
like a folder, its files are chosen there, and they appear with the same ghost
rows and progress rings as a copy in progress.

* **Two sources, one view model.** Torrents belong to the torrent helper, which
  outlives Files (`docs/files-torrents.md`), so they cannot come from this
  service. The shell subscribes to both `files-io.sock` (while a Files process
  runs) and `files-transfers.sock` (while the helper runs), and merges them into
  one panel model: a source-qualified id, kind (copy, move, extract, delete,
  trash, torrent), label, state, bytes done and total, items, rates (download and
  upload for torrents), the controls the item supports, and its speed history.
  Neither source learns about the other.
* **Speed history for torrents too.** The torrent helper keeps the same per-item
  history (1 Hz, 120 samples) and includes it in its snapshot, so the panel draws
  both kinds the same way.
* **One tray icon.** When the shell panel is present, the helper's own
  StatusNotifierItem is not shown. It stays for other desktops. How the helper
  tells the two cases apart is decided in S6.

### Files side: one presentation layer for ghosts and progress rings

Folder rows show work in progress in two separate ways today: copy and move
ghosts (`transfer_ghost`, from the window's own Runtime) and unpublished torrent
payload (`transfer_stub`, from the torrent subscription in `app_torrent_rows`).
When S3 makes the Transfers UI render from job records, it does that through one
**source-agnostic presentation layer**: a path maps to a ghost or stub and its
progress, fed by job records and by the torrent snapshot alike. Opening a torrent
as a folder, with file selection driven by the helper's existing file
priorities, then reuses that layer. That feature itself is Files and helper work
on top of the layer, not a service stage.

**Limits.** At most `max_external_consumers` subscribers (4). Request sizes,
paths and output buffers are bounded. A shell that crashes or restarts
resubscribes and gets a new snapshot.


## 14. Job views: per-entry state for what a window shows

A job record says how a job is doing. A window also shows *which* items are
moving: ghost rows in the destination folder, a ring per item, the Transfers
tree, and a running transfer opened like a folder. That is per-entry state of
the job's tree, which lives in the Manager on the coordinator thread. Windows
never read the Manager (§4), so the coordinator pushes it.

**Subscribe to a folder.** Ghosts show the future state of the filesystem,
so they belong to a folder, not to the window that started a job: any window
showing a folder that jobs write into shows their ghosts, and a ghost folder
can be entered to see its ghost files. A window sends `watch_view` with a view
slot (0 to 3), the folder's path and a window of rows (offset, at most 512).
Each pass the coordinator finds the jobs writing into that folder: those whose
destination is the folder (their roots land there) or an ancestor of it (the
folder is inside their tree, found by name). The **view snapshot** lists their
entries there, each with its job and entry id, name, kind, state (pending,
running, done, failed, skipped, cancelled) and bytes done and total, plus the
count in all. `unwatch_view` drops it; closing the window drops all of its views
(the close sweep, §6). A snapshot carries the watch's generation, so a window
ignores one for a folder it has left.

**Interest is priority.** Watching a folder inside a job's tree asks the
coordinator to discover that folder first, as navigating into it did. Hovering
a ghost file sends `prioritize_entry` (copy it next); hovering a ghost folder
sends `promote_subtree`. Both name the job and entry from the snapshot row.

**When it is written.** With the record of its job: at once on structural
change (a level gained or lost entries, an entry changed state), and at most
every 50 ms for progress. A paused job or one waiting on a conflict writes
nothing. Only watched levels are serialised, so the cost per pass is bounded
by the subscribed rows, never by the size of the job.

**Delivery.** A snapshot is an owned buffer, like a reply (§8): the coordinator
builds it off the Service mutex, then swaps it into the window's view slot
under the mutex and signals the update wake. Latest wins: a snapshot the window
has not taken yet is freed when a newer one replaces it, so a slow window holds
at most one per slot and never blocks the coordinator. The window takes it with
`Handle.takeView` (fail fast, `ServiceBusy` retried next turn).

**Directory progress is incremental.** A folder's bytes done and total are the
sums over its subtree. The Manager keeps them per directory entry and updates
them on each progress report and each discovered entry, walking up the parent
chain (O(depth)). The window no longer aggregates a projected copy of the whole
tree on every rebuild, which today costs O(entries) on the UI thread.

**What stays with records.** Job state, totals, rate history, the pending
conflict id and the offered resource stay in the job table. Conflict details
for the dialog (names, kinds, sizes and dates of both sides) are a request the
coordinator answers from memory, since they are needed once per conflict.

**Limits.** 4 view slots per window (ghosts use slot 0), 512 rows per
snapshot, names bounded by the filesystem's 255 bytes. A folder resolves
against at most 8 jobs at once. Memory per window is bounded by four snapshots in
flight and four held.
