# Files I/O Threading and Ownership

**Status:** The command rings, wake descriptors and coordinator loop exist. The
job table (S1), draining shutdown and worker-side prepare and cleanup tasks (S2)
described here are not built yet. Where this document and the code differ, this
document is the target and the code is the current state.

It supplements [Service Architecture](files-io-service-architecture.md), which
says what the service is and who owns what. This document says how it runs.

## 1. The invariant (hard requirement, every stage)

The Files UI stays responsive under heavy filesystem I/O. This is a hard
requirement and an acceptance criterion of **every** stage from S1 on. It is not
an S5 optimisation.

On the UI event-loop thread:

1. No potentially blocking filesystem operation: no `stat`, `lstat`, `statx`,
   `access`, `realpath`, `readlink`, `open` of a user path, directory read,
   `mkdir`, `rename`, `unlink`, `chmod`, recursive delete, archive work, and no
   spawning a child process and waiting for it.
2. No blocking wait for a worker, an executor, a service response, a thread join
   or a lock. "Wait" includes spinning on a retryable error.
3. Filesystem preparation, metadata inspection, enumeration, reads, writes,
   mutations, recursive deletion and archive operations run on the I/O service's
   workers. The UI submits a request and later consumes an asynchronous result.
4. Heavy I/O cannot starve UI event processing or stop another window from
   responding: per-pass work on both sides is bounded (§5, §6).
5. Progress may be coalesced. Terminal states, failures and conflicts are never
   lost (§6).
6. Window teardown and shutdown do not stall the UI thread (§10, §11).

On the coordinator thread, rule 1 holds as well. The coordinator also never waits
on a worker or a user decision (§8).

**Enforcement.** S1 adds a debug-build guard. The UI thread marks itself at
startup, and the filesystem helpers used by Files (`ops`, `trash`, `archive`,
`io_discovery.Cursor`, `properties`, the chooser checks, and the process-spawn
wrappers in `ops`) assert that they are not running on a marked thread. Every
call site that is still known to violate the rule is listed by name in one
exemption table (§13), next to the stage that removes it. **A stage may remove
exemptions, never add one.** The table must be empty at the end of S4. The
coordinator thread gets the same guard with its own exemption table. That table
is empty at the end of S2.

Deterministic tests prove the rule. Wall-clock latency checks do not, because
they are flaky. The tests park a worker on a gate that never opens, simulating a
hung mount, and assert that every UI-side call returns without waiting and that
the coordinator still processes cancellation and other jobs (§12). S5 adds the
measured latency check on top.

## 2. Threads

| Thread | Does | Never does |
| --- | --- | --- |
| UI thread (one event loop for all windows) | Wayland, rendering, input, submitting commands, reading the job table | Manager or Runtime access, worker queue draining, filesystem scans for jobs |
| Coordinator (one) | Owns the Manager, Runtime, ledger and executors; applies commands and completions; dispatches work; updates the job table | Blocking syscalls, waiting for workers, UI calls |
| Endpoint (one, from S6) | The external socket: shell subscribers and `open_window` (architecture §13). A consumer of the Service like a window | Blocking socket calls, Manager access, UI calls |
| Discovery workers (2), operation workers (2) | One bounded unit of filesystem work, returned as an owned completion | Touching the Manager, the ledger's job state, or any window |

The worker counts and queue capacities are shared process configuration. Changing
them is a separate, measured decision (roadmap phase 7).

## 3. Locking

There is **one mutex**, inside the Service. It guards the command rings, the job
table, the tombstone ring and the per-window outcome slots. The window slot
*lifecycle state* is an atomic. It is not under the mutex (see below). There is no
other lock between the UI and the coordinator, so there is no lock ordering to get
wrong.

Critical sections are bounded and tiny. Inside the lock there is no allocation (all
storage is fixed arrays), no syscall other than the non-blocking eventfd write, no
callback, no call to another locking Service method, and no wait. One critical
section copies at most the caller's `out` buffer, or one dirty batch on the
coordinator side.

### The two sides lock differently

| Side | Acquisition | Why |
| --- | --- | --- |
| Coordinator | Blocking `lock` | Every UI critical section is bounded and does no I/O. If the UI is preempted while it holds the lock, the coordinator loses at most a scheduler quantum, and the coordinator is not latency-critical at that scale |
| UI thread: `trySend`, `trySendOwned`, `fetchChanges` | `trylock`, fail fast with `ServiceBusy` | A bounded critical section can still be held by a *preempted* coordinator. Under heavy I/O the box is busy: archive decompression and copy fallbacks are CPU-bound. A blocking UI lock would then wait a scheduler quantum or more. That is exactly the stall rule 2 of §1 forbids |
| UI thread: `registerWindow`, `Handle.close` | No mutex. An atomic slot state machine | Registration and close must not fail spuriously, and must not wait. Today `closeIoHandle` spins on `ServiceBusy`, which is a busy-wait on the UI thread and violates rule 2. This replaces it |

The fail-fast behaviour and its test ("window operations fail fast under mutex
contention and remain retryable") are **kept** for send and fetch. The test changes
in one assertion: `close` now succeeds while the mutex is held, and the slot is
recycled after the mutex is released.

**Retrying without waiting.** `ServiceBusy` is a transient result, not an error the
user sees.

* Send. The caller keeps ownership of the payload (unchanged contract). The window
  puts the command in a small window-local outbox (4 entries, FIFO). Each
  event-loop iteration retries the outbox before it sends anything new, so command
  order is preserved. Only a full outbox produces a user notice.
* Fetch. The window sets `fetch_pending`. While any window has `fetch_pending`, the
  event loop polls with a 1 ms timeout instead of blocking. The wake counter was
  already drained, so this flag is what stops a failed fetch from losing the
  wakeup. The failure the earlier blocking proposal tried to fix is fixed here
  without a blocking lock.
* Neither path loops or spins inside one iteration.

**Slot state machine.** `free → claimed → active → closing → free`, an atomic per
slot. Window ids come from an atomic counter and are never reused.

* `registerWindow`: CAS `free → claimed`, write the id, store `active`
  (release). This fails only with `TooManyWindows`, `ServiceDraining` or id
  exhaustion.
* `Handle.close`: CAS `active → closing`, then signal the command wake. It cannot
  fail and does not wait.
* The coordinator, under the mutex, recycles a `closing` slot once its rings are
  empty: it resets the rings and outcome slots, then stores `free` (release).
  Enqueue, which runs under the mutex, accepts only `active` slots, so a push can
  never race a reset.

**Same-thread reacquisition.** The mutex is a default, non-recursive pthread mutex.
Relocking it from the thread that holds it is a deadlock with `lock`, and with
`trylock` it is a permanent `ServiceBusy` (and with today's close spin, a hang). The
structure rules this out: no Service method calls a locking method, and nothing
runs under the lock except code in `io_service.zig`. Debug builds initialise the
mutex as `PTHREAD_MUTEX_ERRORCHECK` and assert on every return code, which today are
discarded with `_ =`. An accidental relock then panics instead of hanging.

**Shutdown.** `beginDrain` and `Service.deinit` take the lock blocking. They run on
the main thread only after every window is destroyed and the compositor is
disconnected (§10). At that point no UI exists to stall.

The Manager, Runtime and ledger are coordinator-private and are not behind this
mutex. The coordinator computes what it wants to publish first, then takes the lock
only to write it.

## 4. Wake descriptors

Two process-wide non-blocking eventfds, both owned by the Service:

* `command_wake_fd`: signalled when a command is admitted or when drain begins.
  Polled by the coordinator.
* `update_wake_fd`: signalled when any job record changes. Polled by the UI event
  loop, once for all windows.

Rules:

* The consumer drains the wake counter **first**, then reads the state. A change
  that lands in between leaves the counter non-zero, so the worst case is one
  spurious pass.
* A wake only says that something may have changed. The job table is
  level-triggered, so any number of signals collapse into one read. A late or missed
  signal cannot lose information.
* A saturated counter is already readable, so a write that would block is skipped.

## 5. Commands: admission and processing

* Each window has a bounded ring for normal commands and a separate small ring for
  control commands, plus an aggregate cap on normal commands. Control commands never
  wait behind normal ones.
* Admission never blocks. A full ring returns an error (`WindowQueueFull`,
  `AggregateQueueFull`, `ControlQueueFull`). The UI shows a notice for a
  user-initiated command. It does not retry silently, and it never assumes success.
* Admission of `submit_job` also reserves a live job-table slot and one outcome
  slot of the submitting window (§6), so a submit that is accepted always has a
  record to appear in and an outcome that cannot be lost. A full table returns
  `TooManyJobs` and a window with no free outcome slot returns
  `WindowOutcomesFull`, both synchronously. Metadata and small-mutation requests
  (§8) reserve a reply slot the same way.
* Payloads are heap-owned with the allocator carried along. A successful enqueue
  moves ownership into the ring and clears the caller's pointer. A failed enqueue
  leaves it with the caller. The coordinator frees the payload after handling.
* A window closing does not drop its queued commands. They are processed, and the
  slot is recycled when its rings are empty.
* **The coordinator takes at most `command_quota` commands per loop pass**, then
  moves on to completions and dispatch. A busy producer cannot starve them. Within a
  pass, windows are served round-robin and control commands first within a window.
* Commands are idempotent in effect. Cancelling twice, or pausing a finished job, is
  harmless. A command that cannot apply changes nothing and is logged. There is no
  per-command reply channel: the window learns what happened from the job table. A cancel that has been applied but is still waiting for running work shows as
  `cancel_requested` in the job's record.

A submit that fails validation does not reply with an error. It produces a job
record that goes straight to `failed` with an `error_code`. The window correlates it
with the `submit_tag` it chose when it submitted. That keeps one feedback path.

## 6. Job table

The table is the only service-to-window channel for state.

### Storage and capacity

All three stores are fixed arrays of plain copied records, with no pointers and no
slices. Text such as the job label is a fixed-size buffer. One record is about
200 bytes.

| Store | Capacity | Holds | Occupied by |
| --- | --- | --- | --- |
| Live table | `max_live_jobs = 64` | Every job from admission until it retires | Only job-side state (below). **Never by a consumer** |
| Outcome slots | `outcome_slots_per_window = 16` per window slot | The final record of each job that window submitted | Reserved at submit, freed when that window has fetched the outcome or closes |
| Tombstone ring | `tombstone_capacity = 64` | Final records of retired jobs, for every other window | FIFO. The oldest entry is overwritten, which is never blocked |

The totals: 64 live jobs, about 13 KiB; 16 × 16 outcome slots, about 51 KiB; 64
tombstones, about 13 KiB. These are starting values. Phase 7 calibrates them. All
three live in `io_service.zig` next to `max_windows`. `max_live_jobs` must be at
least `aggregate_command_capacity`, so a queued submit always has a slot to reserve.

### Writer, reader

* **Writer.** Only the coordinator writes, under the lock. It bumps a service-wide
  sequence and stamps the changed record with it as `revision`, then signals the
  update wake.
* **Reader.** `fetchChanges(window, cursor, out) -> {count, next_cursor, more,
  resync}` copies out, oldest first: the window's own unread outcomes, then live
  records and tombstones with `revision > cursor`. It records the window's cursor in
  its slot. A window loops until `more` is false, at most one `out` buffer per
  event-loop iteration. If `more` is still true, the next iteration polls with a
  zero timeout.

### Retirement, and why a stalled consumer cannot block it

The first version of this plan kept a tombstone until every registered window's
cursor had passed it. That let one window that stopped reading block retirement for
every job, fill the table and turn every submit into `TooManyJobs`. That rule is
**removed**.

* **Retirement depends only on the job.** A terminal job retires when its executors
  are quiescent for it, the ledger holds no job-owned resource for it, and no window
  holds a borrow on its resources (architecture §6). Windows and cursors play no
  part.
* **On retirement** the coordinator writes the final record into the origin
  window's reserved outcome slot, if that window is still registered, and into the
  tombstone ring. The live slot is free at once.
* **Origin window: lossless.** The outcome slot was reserved at admission, so it
  cannot be full. It is freed only when that window's fetch has returned it. A
  window that never reads keeps at most 16 outcomes, and it can only block **its
  own** next submit (`WindowOutcomesFull`). Other windows and the live table are
  unaffected.
* **Other windows: lossless while they keep up, an explicit resync when they do
  not.** A window whose cursor is older than the oldest tombstone gets
  `resync = true`. It marks its whole view stale, fetches from cursor 0 (every live
  record plus the ring), and drops any job not reported by the time `more` is false.
  A record that changes during the sweep gets a newer revision and is reported
  later in the same sweep, so the sweep is consistent without a snapshot. A
  foreign job's final record can then be missing from that window's view. It is
  never missing silently, and it is never a pending conflict or a failure of a job
  that window submitted.
* **Conflicts are never lost.** A job waiting on a conflict is not terminal, so it
  is in the live table and in every sweep. With no window registered it is
  auto-cancelled (architecture §6).
* **Capacity recovery.** Live-table capacity is recovered by retirement alone.
  Retirement never waits on a consumer and never drops authoritative state, which
  is the Manager's. The table is a projection of it. Outcome-slot capacity is
  recovered by that window's own fetch or by its close.
* **Headless.** With no window registered there are no outcome slots, and
  tombstones are overwritten as the ring fills.

**How a window falls behind.** All windows share one event loop and one update wake,
and every registered window fetches on every update wake, whether or not it is
visible or has a frame callback pending. A window therefore lags only if its Client
is not being stepped (a bug), or if the whole UI thread stalls, in which case all
windows lag alike. Resync covers both. Overflowing the tombstone ring takes 64
retirements between two fetches of one window.

### Fairness

Each window processes at most one `out` buffer of records per event-loop
iteration, so a large backlog in one window cannot monopolise the loop.

### What was removed

The update rings, the coalescing rule and the `resync_required` marker of the
first implementation are removed. Resync survives only as the bounded,
consumer-side recovery above. It no longer comes from an overflow that wiped a
terminal state or a conflict notification.

### What the coordinator publishes, and how often

* A **state change** is published immediately.
* **Progress** is rate-limited at the source: at most one update per job per
  `progress_interval` (about 50 ms), with the final value always published. The
  event-loop wake is rate-limited naturally.
* The coordinator does not rebuild the table from a full snapshot. Each job keeps
  running totals (planned and completed bytes, items, job-level throughput), updated
  where operation progress and state change, and `Manager.jobSummary` reads them
  without visiting any operation. Each pass compares every live job's summary with
  the record it last wrote. Live jobs are bounded by the table (64), so that walk is
  cheap; the cost that mattered, walking operations, is gone. A per-job dirty set was
  planned here and dropped: at this bound it would add a way to miss an update
  without lowering the cost. `snapshotJobs` stays for tests and diagnostics and is not
  called by the coordinator.
* A job is sampled for its speed history only while it is `running` or `finalizing`,
  so a paused job, or one waiting on a conflict, causes no wakeups.

## 7. The coordinator loop

```text
loop:
    drain command wake
    handle up to command_quota commands          (round-robin, control first)
    apply finished prepare, cleanup and request tasks   (section 8)
    pump executors: drain wake, reconcile completions, dispatch ready work
    housekeeping:
        auto-cancel conflicts if no window is registered
        for windows now closing: drop their borrows, hand window-owned
            resources to their executor for disposal
        retire terminal jobs that are ready        (try every candidate)
    publish dirty jobs to the job table          (rate-limited progress)
    if draining and idle: break
    if more commands are pending or the quota was hit: continue
    wait on: command wake, discovery wake, operation wake,
             timeout = next progress-publish deadline, or none
```

The poll checks `revents`. An error or invalid descriptor is a bug and is reported,
not spun on. Retirement tries every candidate each pass. One that is not ready does
not block the others.

## 8. Blocking-call discipline

The coordinator may change Manager state and do bounded in-memory work. It does not
call `stat`, `lstat`, `readlink`, `open`, read a directory, or resolve a path. Any of
those can block indefinitely on a hung network or FUSE mount, and the same thread
handles cancellation and completions for every window.

Service tasks run on a small pool owned by the coordinator (`io_service_tasks`, two
workers), not on the discovery pool: a prepare stalled by a hung mount then holds
neither a discovery worker of another job nor the coordinator.

So `submit_job` is three steps:

1. **Accept.** The coordinator creates the job in `planning`, moves the owned request
   into a **prepare task** and dispatches it to the discovery pool. This is bounded
   and does no I/O.
2. **Prepare (worker).** The worker validates paths, classifies each source
   (regular file, symlink, directory), reads symlink targets, checks the mount-point
   and overlap rules for moves, checks that the destination is not inside a source,
   and compares device and inode identity. It returns an owned plan. If it fails,
   the plan carries the error.
3. **Apply.** The coordinator validates the plan against the job (still `planning`,
   not cancelled) and applies it through the Manager, or fails the job with the
   `error_code`. A plan for a cancelled job is discarded together with the planning
   job.

**Cleanup is a worker task too.** Physical destruction that can block (recursive
deletion of staging, `close` of a regular file opened for writing, which can flush
on NFS) is never done inline on the coordinator. The owning executor transfers the
resource to a worker in the ledger (`operation_executor → operation_worker`),
dispatches a cleanup unit and releases the resource when the completion returns.
Closing a directory or `O_PATH` descriptor is bounded and may stay inline. Today
`io_operation_executor.Runtime.releaseResource` and `discardArchiveStaging` call
`ops.deleteRecursive` inline. That is a coordinator exemption until S2 (§13).

**Metadata and small mutations.** Properties, rename, new folder or file,
permission toggles, unique-name generation, chooser path checks, pin kind checks,
terminal and drop path canonicalisation, and Trash restore are not jobs. They go
through the service as **requests**: an owned payload in, a reply in the window's
reserved reply slot (4 per window), dispatched to the discovery pool. The UI shows
the result when the reply arrives. Until it arrives, the dialog shows its pending
state and keeps accepting input. Delete, move to Trash and Empty Trash are **jobs**
(kinds `delete`, `trash`, `empty_trash`), because they can be long and want
progress and cancellation. Their child-process wait (`rm`, `gio`) runs on an
operation worker.

Rules for any worker task, whether prepare, metadata, publication or cleanup:

* The coordinator first captures the inputs into an immutable, independently owned
  payload.
* The worker never reads Manager-owned state, keeps no pointer into a Manager
  collection and performs no lifecycle transition.
* The result comes back through the normal completion path. Only the coordinator
  applies it. Every dispatched unit is accounted for exactly once, in the ledger.

Prepare tasks land in **S2**, not S5. The inline validation in
`Coordinator.submitTransfer` (`stat`, `lstat`, `readlink` on user paths) is a
coordinator exemption only until then, and nothing in production submits through
the coordinator before S3, so it never reaches users. Moving it to S5 would have
meant shipping S3 with a coordinator that a hung mount can stall for every window.

## 9. Cancellation

Cancellation is an asynchronous state transition, not a synchronous worker control.

* `cancel_job` records the intent in coordinator-owned state and signals in-flight
  work through a thread-safe cancellation token.
* Workers check at defined safe points inside their bounded units. They do not
  mutate the Manager or release service-owned resources. A worker that sees
  cancellation returns an owned completion describing what it did and what partial
  output or resources remain.
* The coordinator reconciles every dispatched unit, schedules the cleanup
  (on a worker where it can block), and only then marks the job `cancelled`.
* Work that cannot be interrupted safely (an in-progress uninterruptible syscall)
  may delay cancellation. It must not stall the coordinator loop or any unrelated
  job.
* Queued work that has not started may be withdrawn if the pool contract allows. It
  is still accounted for exactly once.
* Archive extraction keeps its cooperative cancellation and staging cleanup.

## 10. Shutdown: the draining state machine

```text
running --beginDrain--> draining --idle--> stopped
```

The process owner calls `beginDrain` when the last window is gone, or when the
process is asked to quit. **Accepted ordinary filesystem operations finish.** They
are not abandoned half done.

In `draining` the coordinator keeps running its normal loop. It does not break after
one pass.

* New `submit_job` is refused (`ServiceDraining`).
* Archive extractions are cancelled cooperatively, and their staging is cleaned.
* Jobs waiting on a conflict are cancelled, since no window can answer.
* Running and queued ordinary jobs run to completion. Terminal jobs retire as usual.
* The coordinator reports **idle** when no job is non-terminal, both executors are
  quiescent and no accepted command is left in any ring.

At idle, still on the coordinator thread:

1. Release remaining service-owned resources. Destruction that can block runs
   as cleanup tasks on the workers, before the pools are stopped (§8).
2. Verify the ledger is empty. A non-empty ledger is logged with the leaking
   resource kinds and is a failed assertion in debug builds.
3. Stop and join the worker pools. Joining belongs here, after the work has been
   accounted for. It is never done while ordinary commands or completions are being
   processed.
4. Free the Manager and Runtime, then the thread exits.

**Abort.** A second quit request, or an explicit abort, cancels every job, including
ordinary ones, and waits for reconciliation. If a worker is stuck in an
uninterruptible call, the owner may exit after a timeout and logs the jobs it
abandoned. This is the one case where an operation is left half done, and it is a
last resort that must be visible in the log.

**Process-owner order.** `main.run` creates the Service and Coordinator before the
Wayland display and the first window. On the way out it destroys the windows, then
disconnects from the compositor, then calls `beginDrain` and waits for the
coordinator thread. A headless process has no business holding a compositor
connection while it finishes a copy. This join is the only blocking wait on the
main thread, and it happens after the UI is gone.

**Window teardown while other windows live.** Destroying one window must not wait
on anything. `Handle.close` is atomic (§3). Today `Client.destroy` joins the
window's Runtime worker pools (`io_runtime.deinit`), the `JobRunner` thread
(`App.deinit`) and its listing worker (`worker.deinit`), all on the UI thread. A
worker stuck on a hung mount therefore freezes every window. The first two go away
with the per-window Runtime and `JobRunner` in S3. Per-window helper threads that
remain (listing worker, folder-size, thumbnails, Trash totals) are signalled to stop
and handed to a process-owned reaper that joins them off the UI thread. That reaper
lands with S3, since S3 is when window teardown is rewritten.

## 11. Window lifecycle contract

* **Register before the first command.** `registerWindow` fails only on
  `TooManyWindows`, `ServiceDraining` or exhaustion of the 64-bit window id. It
  takes no lock (§3).
* **Close always completes, immediately.** `Handle.close()` is an atomic
  `active → closing` transition plus a wake. It cannot fail, takes no lock and
  never waits, so there is nothing to retry and nothing to spin on. The slot is
  recycled by the coordinator once its queued commands have been processed. Closing
  slots count toward `max_windows` until then, so the limit applies to open plus
  closing windows.
* Closing affects only what that window holds: its borrows are dropped and its
  window-owned resources are handed to their executor for disposal (architecture
  §6). It never releases an executor-owned or worker-held resource, and never
  touches a job.
* A stale `Handle` copy fails on its window id, because ids are never reused.
* All `Handle`s must be closed before `Service.deinit`. This is asserted.
* The `Handle` is a non-owning capability. It exposes `trySend`, `trySendOwned`,
  `fetchChanges` and `close`, and nothing else. It cannot reach the Manager.

## 12. Required tests

The existing queue tests stay: bounded admission, aggregate bounds, reserved control
capacity, round-robin draining, payload ownership transfer on success and on failure,
and acceptance after window closure. The update-ring and resync tests are replaced by
the table tests below.

| Area | Test |
| --- | --- |
| Job table | A late-registered window sees every live job |
| Job table | A window that never reads still sees a terminal state and a pending conflict when it does |
| Job table | A tombstone is retained until the lowest cursor passes it, then reused |
| Job table | Interleaved progress from several jobs cannot overflow or lose a lifecycle change |
| Wake | Drain-then-read never misses a change made between the drain and the read |
| Orphans | A job whose origin window closed has its conflict resolved from another window |
| Orphans | A borrow held by a window that closes is dropped, its window-owned resources are disposed by their executor on a worker, and the ledger ends empty |
| Conflicts | With no window registered, a pending conflict cancels its job and the next job's conflict is not blocked |
| Retirement | A window that never fetches does not delay retirement of any job, and other windows can still submit |
| Retirement | A window that never fetches gets every outcome of its own jobs when it finally fetches, and is refused only its own submits once its 16 slots are full |
| Retirement | A foreign window that falls more than `tombstone_capacity` retirements behind gets `resync`, and the sweep ends with exactly the live set |
| Locking | Contention: `trySend` and `fetchChanges` return `ServiceBusy` without waiting, keep payload ownership, and succeed on retry. `close` and `registerWindow` succeed while the mutex is held |
| Locking | A failed fetch after the wake was drained is retried on the next iteration through `fetch_pending`. No wakeup is lost |
| Locking | Debug build: relocking the Service mutex from its holder panics (errorcheck) instead of hanging |
| Responsiveness | With a worker parked on a gate that never opens (simulated hung mount): every UI-side call returns, `cancel_job` of another job is applied, and other jobs' completions are reconciled |
| Responsiveness | Debug guard: a filesystem helper called on the UI thread or the coordinator thread outside the exemption table aborts the test |
| Teardown | Destroying a window while its listing worker is parked on a gate returns at once. The reaper joins later |
| Ownership | Closing a window never releases an executor-owned or worker-held resource, even for a job that window submitted |
| Ownership | Closing a window with a borrow on archive staging drops the borrow, and the executor deletes the staging on a worker afterwards |
| Ownership | A window-owned staging lease (clipboard, drag, Open With) is disposed by an operation worker, never by the UI thread |
| Shutdown | After the last window closes, an accepted cross-filesystem move finishes, including its detach step |
| Shutdown | Draining cancels an archive extraction and leaves no staging behind |
| Shutdown | Abort cancels ordinary jobs and reports any it had to abandon |
| Admission | A flood of `submit_job` cannot delay completion reconciliation beyond `command_quota` per pass |
| Admission | `submit_job` into a full table returns `TooManyJobs` and leaks no payload |
| Submit | An invalid source produces a `failed` record carrying the window's `submit_tag` |
| Prepare | A prepare task that blocks does not delay `cancel_job` or other jobs' completions |
| Prepare | A plan arriving for a cancelled job is discarded with its planning job |
| Cost | A pass with one changed job in a table of many does work proportional to one job |
| Lifecycle | Opening and closing windows repeatedly does not exhaust slots |

Measure UI responsiveness under concurrent heavy I/O as well as throughput. A
service that is fast but makes the event loop stall has failed the requirement in §1.

## 13. Audit: blocking work reachable from the event loop and the coordinator

Audited at `ca9e828` (feat/files-io-manager). This table is the debug guard's
exemption list (`src/files/io_thread_guard.zig`, `Exemption`). An entry is deleted
when its stage lands. No stage may add one; an entry the guard itself uncovers in
existing code (C4) is recorded, never a new violation.

### UI thread

| # | Call site | Blocking work | Removed in |
| --- | --- | --- | --- |
| U1 | `app_fileops.startManagerFileCopy`, `startManagerFileMove`, `startManagerDirectoryTransfer` | `lstat`, `readlink` per source, `stat` of the destination and of source parents | S3: App submits through `Handle`, prepare runs on a worker (S2) |
| U2 | `App.executeTransfer` fallback to `JobRunner`; `app_listing` polling | JobRunner start and polling on the UI thread | S3 (needs phase 2) |
| U3 | `app_io.stepOperations`, `stepDiscovery`, `processDetachedIoJobs` | Per-window Runtime: draining completions, reconciliation, dispatch on the UI thread | S3 |
| U4 | `app_fileops.executeDeletion` → `ops.deleteItems`, `ops.trashItems`, `ops.emptyTrash` | Spawns `rm -r` / `gio trash` and **waits for it** | S3, as `delete`, `trash`, `empty_trash` jobs. No phase-2 dependency, so it can land first in S3 |
| U5 | `app_fileops.deleteFromTrash` → `trash.deleteMany` → `ops.deleteRecursive` | Recursive delete | S3 (`delete` job) |
| U6 | `app_fileops.executeDeletion` → `trash.sweepOrphans` | `opendir`, `readdir`, `unlink` over `Trash/info` | S3 (cleanup step of `empty_trash`) |
| U7 | `app_trash.restoreSelected`/`restoreAll` → `trash.restoreMany` | `lstat`, `rename`, `rmdir`, metadata rewrite | S3 (request) |
| U8 | `app_dialogs`: `ops.createFolder`, `ops.createFile`, `ops.renameItem`, `ops.generateUniqueName` | `mkdir`, `open`, `renameat2`, `lstat` loop | S3 (requests) |
| U9 | `app_dialogs` → `properties.State.init`; `app_pointer` → `properties.togglePathPermission` | `open(O_PATH)`, `statx`; `chmod` | S3 (requests) |
| U10 | `app_chooser.collectChooser` | `stat`, `lstat`, `access` on confirm | S3 (request) |
| U11 | `app_places` → `createDirPath`, `pins.kindOf` | `mkdir -p`, `stat` | S3 (requests) |
| U12 | `app_terminal` (`realpath`, `stat`); `client_dnd.canonicalPath` (`realpath`) | Path resolution on user paths | S3 (requests) |
| U13 | `app_io.openArchivePublicationCursor`, `stepArchivePublications` (`Cursor.open`, `nextBatch`) | `openat`, `getdents` on staging | S4 (publication cursor becomes service-owned) |
| U14 | `app_io` → `executor.discardArchiveStaging` | `deleteRecursive` of staging | S4 |
| U15 | `clipboard.StagingLease.deinit` (clipboard replace, `App.deinit`, extraction cleanup, `client_clipboard`) | `deleteRecursive` of a transferred-out staging lease | S4: disposal handed to an operation worker |
| U16 | `Client.destroy` → `io_runtime.deinit`, `App.deinit` → `JobRunner.deinit`, `worker.deinit` | Thread joins on the UI thread | S3 (Runtime and JobRunner removed; reaper for the rest) |
| U17 | `client_lifecycle.closeIoHandle` | Busy-wait on `ServiceBusy` | **Before S1** (atomic close, §3) |

`app_audio` checks the existence of a socket with `access` in the runtime
directory. That is tmpfs and not a user path, so it is not an exemption. It is
listed here so the guard's allowlist states it explicitly.

### Coordinator thread

| # | Call site | Blocking work | Removed in |
| --- | --- | --- | --- |
| ~~C1~~ | `Coordinator.submitTransfer` and its file and directory helpers | `stat`, `lstat`, `readlink` on user paths | **Removed in S2**: `io_transfer_plan.prepare` runs as a service task |
| ~~C2~~ | `Coordinator.releaseResource` → `io_operation_executor.Runtime.releaseResource` | `ops.deleteRecursive` of archive staging | **Removed in S2**: `takeStagingForCleanup`, a `delete_tree` service task, `finishStagingCleanup` |
| C3 | `releaseResource`, `resolveConflict`, the publish loop | `snapshotJobs` allocation and copy per command or pass. Not I/O, but O(all jobs) | S1 (dirty set) |
| ~~C4~~ | `io_discovery_executor.Executor.dispatchReady` → `getOrOpenAnchor`, `Anchor.openCursorForEntry` | Opened root anchors and directory cursors inline before handing them to a worker. Found by the guard | **Removed in S2**: dispatch builds the path from the tree in memory; the worker opens the root anchor (if needed) and the cursor. The coordinator exemption list is now empty |

### Not yet covered: application state files

Places pins (`pins.save`), Recent, history and settings read and write small
files under `$XDG_STATE_HOME` and `$XDG_CONFIG_HOME` on the UI thread. They are
not user-selected paths, but a home directory on NFS makes them blocking. They
are outside the guard for now. Whether they move to a worker is a separate
decision, recorded here so it is not forgotten.

### Off the UI thread already, outside the service

The listing worker, folder size (`dirsize`), thumbnails and Trash totals run on
their own threads. They meet the responsiveness invariant, but they are not on
the service's workers. Moving them is **not** in S1 to S5. Their only UI-thread
cost is the join at teardown (U16), which the reaper removes. If they should move
onto the service, that is a separate decision.
