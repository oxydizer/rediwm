# Files I/O Threading and Ownership

**Status:** The command rings, wake descriptors and coordinator loop exist. The
job table (S1), draining shutdown (S2) and worker-side submit validation (S5)
described here are not built yet. Where this document and the code differ, this
document is the target and the code is the current state.

It supplements [Service Architecture](files-io-service-architecture.md), which
says what the service is and who owns what. This document says how it runs.

## 1. The invariant

**No Files UI event-loop thread performs I/O service orchestration, drains
worker completions, or blocks on filesystem work. The coordinator thread never
waits on a worker, a filesystem call or a user decision.**

This is a responsiveness requirement, not a code-organisation preference.

## 2. Threads

| Thread | Does | Never does |
| --- | --- | --- |
| UI thread (one event loop for all windows) | Wayland, rendering, input, submitting commands, reading the job table | Manager or Runtime access, worker queue draining, filesystem scans for jobs |
| Coordinator (one) | Owns the Manager, Runtime, ledger and executors; applies commands and completions; dispatches work; updates the job table | Blocking syscalls, waiting for workers, UI calls |
| Discovery workers (2), operation workers (2) | One bounded unit of filesystem work, returned as an owned completion | Touching the Manager, the ledger's job state, or any window |

The worker counts and queue capacities are shared process configuration. Changing
them is a separate, measured decision (roadmap phase 7).

## 3. Locking

There is **one mutex**, inside the Service. It guards the window registry, the
command rings and the job table. There is no other lock between the UI and the
coordinator, so there is no lock ordering to get wrong.

Critical sections are bounded and tiny. Inside the lock there is no allocation (all
storage is fixed arrays), no syscall other than the non-blocking eventfd write, no
callback and no wait. The most the lock covers is a copy of at most `max_jobs`
records. Because of that, **both sides take the mutex blocking**. The earlier
`trylock`/`ServiceBusy` scheme is removed: it made `register`, `close` and the update
read spuriously fail, and a failed read after the wake was drained lost the wakeup.

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
* Admission of `submit_job` also reserves a job-table slot, so a submit that is
  accepted always has a record to appear in. A full table returns `TooManyJobs`
  synchronously.
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
  per-command reply channel: the window learns what happened from the job table.

A submit that fails validation does not reply with an error. It produces a job
record that goes straight to `failed` with an `error_code`. The window correlates it
with the `submit_tag` it chose when it submitted. That keeps one feedback path.

## 6. Job table

The table is the only service-to-window channel for state.

* **Fixed storage.** `max_jobs` records of plain copied values, with no pointers and
  no slices. Text such as the job label is a fixed-size buffer.
* **Writer.** Only the coordinator writes, under the lock. It bumps a service-wide
  sequence and stamps the changed record with it as `revision`, then signals the
  update wake.
* **Reader.** `fetchChanges(window, cursor, out) -> {count, next_cursor, more}`
  copies out records with `revision > cursor`, oldest first, and records the
  window's cursor in its slot. A window loops until `more` is false. A window can
  bound its work per event-loop pass by passing a small `out` buffer.
* **Removal.** Retiring a job sets `removed` and a new revision. The tombstone stays
  until the lowest cursor across registered windows has passed it, then the slot is
  reused. With no windows registered the tombstone is dropped at once.
* **Why there is no resync.** The table is state, not a stream of events. A window
  that reads late, or never, still gets the current record when it does read. The
  update rings, the coalescing rule and the `resync_required` marker of the first
  implementation are removed, and with them the failure mode where an overflow
  wiped a terminal state or a conflict notification.
* **Fairness.** Each window processes a bounded number of records per event-loop
  iteration (its `out` buffer), so a large backlog in one window cannot monopolise
  the loop.

### What the coordinator publishes, and how often

* A **state change** is published immediately.
* **Progress** is rate-limited at the source: at most one update per job per
  `progress_interval` (about 50 ms), with the final value always published. The
  event-loop wake is rate-limited naturally.
* The coordinator does not rebuild the table from a full snapshot. The Manager keeps
  an O(1) per-job summary (state, aggregate bytes, rate, head conflict) and a **dirty
  set** of jobs changed since the last publication. Each pass visits the dirty set
  only. `snapshotJobs` stays available for tests and diagnostics, and it is not
  called in the loop. The cost of a pass is proportional to what changed, not to the
  total number of operations.

## 7. The coordinator loop

```text
loop:
    drain command wake
    handle up to command_quota commands          (round-robin, control first)
    apply finished prepare tasks                 (section 8)
    pump executors: drain wake, reconcile completions, dispatch ready work
    housekeeping:
        auto-cancel conflicts if no window is registered
        release leases whose holder window is gone
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

Rules for any worker task, whether prepare, metadata, publication or cleanup:

* The coordinator first captures the inputs into an immutable, independently owned
  payload.
* The worker never reads Manager-owned state, keeps no pointer into a Manager
  collection and performs no lifecycle transition.
* The result comes back through the normal completion path. Only the coordinator
  applies it. Every dispatched unit is accounted for exactly once, in the ledger.

Until S5 lands, the inline validation in `submitTransfer` is acceptable. The risk is
a hung mount stalling the service, and S5 removes it.

## 9. Cancellation

Cancellation is an asynchronous state transition, not a synchronous worker control.

* `cancel_job` records the intent in coordinator-owned state and signals in-flight
  work through a thread-safe cancellation token.
* Workers check at defined safe points inside their bounded units. They do not
  mutate the Manager or release service-owned resources. A worker that sees
  cancellation returns an owned completion describing what it did and what partial
  output or resources remain.
* The coordinator reconciles every dispatched unit, performs the cleanup, releases
  the job's leases and only then marks the job `cancelled`.
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

1. Release remaining service-owned resources.
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
connection while it finishes a copy.

## 11. Window lifecycle contract

* **Register before the first command.** `registerWindow` fails only on
  `TooManyWindows`, `ServiceDraining` or exhaustion of the 64-bit window id.
* **Close always completes.** `Handle.close()` takes the lock blocking, so it cannot
  fail and there is nothing to retry. It marks the slot closing. The slot is
  recycled once its queued commands have been processed. Closing slots count toward
  `max_windows` until then, so the limit applies to open plus closing windows.
* Closing releases the window's leases, as in the architecture document §6.
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
| Orphans | A lease held by a window that closes is released by the service, and the ledger ends empty |
| Conflicts | With no window registered, a pending conflict cancels its job and the next job's conflict is not blocked |
| Retirement | A terminal job is retired only after every window's cursor passed it |
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
