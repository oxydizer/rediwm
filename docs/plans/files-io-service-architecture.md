# Files I/O Service Architecture

**Status:** In progress. The service core (`io_service.zig`) and the
coordinator thread (`io_coordinator.zig`) exist and are owned by the process
(`main.run`). Windows still own their own Runtime; moving them onto the service
is stage S3 below.

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
| `release_lease` | Job id and resource id, for a hand-off lease the window holds | control |

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
    pending_conflict: ?ConflictId,   // set on the job at the head of the conflict queue
    lease: ?{ resource_id, holder_window_id },
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
  next fetch still returns the current record. **Nothing needs resynchronising,
  because nothing is a lost event.**
* A removed job leaves a tombstone until every registered window's cursor has
  passed it, then the slot is reused.
* A window registering late starts at cursor 0 and sees every live job.
* The table has a fixed capacity (`max_jobs`). Terminal jobs retire
  automatically (§6), so only live jobs and fresh tombstones occupy it. A
  submit into a full table is rejected with `TooManyJobs`.

## 6. Job lifecycle

States are the Manager's: `planning`, `queued`, `running`, `finalizing`,
`paused`, `waiting` (a conflict needs a decision), and the terminal states
`completed`, `completed_with_errors`, `failed`, `cancelled`.

* **Commands and states are separate.** `pause_job` leads to `paused` only at a
  safe pause point. `cancel_job` leads to `cancelled` only after workers have
  stopped and cleanup is done.
* **Retirement is automatic.** A terminal job is retired when the executors are
  quiescent for it, the ledger holds nothing it owns, and every registered
  window's cursor has passed its terminal revision (or no window is registered).
  A window that wants to keep a finished transfer on screen keeps its own copy
  of the record it saw.
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

### Leases

When the service has prepared something a window will use (an extracted archive
member, a staging directory), the job record carries a `lease` naming the
resource and the window that holds it.

* The window uses the content and then sends `release_lease`.
* If the holder window unregisters first, the **service releases the lease**.
  Closing a window never leaks staging.
* Clipboard, drag and Open With hand-offs keep their existing meaning: once a
  resource is transferred to its external owner it stops being job-owned and
  does not block retirement.
* Today the archive publication cursor is registered as App-owned in the
  ledger. Stage S4 makes it service-owned. Until then that one resource stays
  with the App.

## 7. Responsiveness

The requirement is that the UI event loop never orchestrates I/O, drains worker
completions or waits on the filesystem, and that the coordinator does not become
the bottleneck. The rules that make this true (what may run on the coordinator
thread, how progress is rate-limited, bounded processing per pass) are in the
threading document.

## 8. Failure semantics

| Event | Result |
| --- | --- |
| A window closes | Its jobs continue; its queued commands still run; its leases are released |
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
green. Commit and push after each.

**S0, done.**
* The Service primitives (bounded queues, wake descriptors, owned payloads).
* The Coordinator thread.
* Copy and move of files, symlinks and directories.
* Discovery, conflict and resource-release commands.
* Per-job state and progress publication, owned snapshots.
* Process-owned lifecycle in `main.run`.
* A `Handle` per window (`Client.io_handle`).

**S1, job table.** Replace the per-window update rings, coalescing and resync
marker with the job table and cursor fetch (§5). Window-side calls take the
mutex blocking, since critical sections are bounded (threading §3). Add the
Manager's O(1) per-job summary and dirty set so the coordinator stops copying
every job on every wake. *Done when:* a late-joining window sees all live jobs; a
window that never reads cannot lose a terminal state or a conflict; and the
coordinator no longer calls `snapshotJobs` on its loop.

**S2, lifecycle.**
* Draining shutdown (threading §9).
* Headless drain after the last window.
* Automatic retirement (§6).
* Lease reclaim on window close.
* Conflict auto-cancel with no window.
* Remove the origin checks from `resolve_conflict` and `release_resource`.
* Remove `retire_job`.

*Done when:* an accepted cross-filesystem move finishes, including its detach
step, after the last window closes. And a job whose origin window closed can have
its conflict resolved from another window.

**S3, windows move onto the service** (the earlier stages 3 and 4, combined).
* Prerequisite: the Coordinator accepts mixed file and directory selections
  (today it rejects them with `MixedTransferSourceKinds`), so JobRunner's
  fallback can go. This is roadmap phase 2.
* Then the App submits through its `Handle`.
* The Transfers UI renders from job records.
* `Client.io_runtime` and `App.io_runtime` are removed. This is when the per-window Runtime
  stops existing.

*Done when:* no production code outside the coordinator touches `io_runtime`,
`io_manager` or an executor, and `JobRunner` is gone.

**S4, archive lifecycle.**
* Staging, publication barrier and cancellation move to the service.
* The UI hand-off is a lease.
* The publication cursor becomes service-owned.
* The publication-barrier and ledger invariants are preserved as they are.

**S5, responsiveness hardening.**
* Submit-time validation moves to discovery workers (threading §8).
* Per-pass command quotas.
* Time-based progress rate limit.
* A measured check that the UI thread stays responsive under heavy concurrent
  I/O.

Moving S5's submit validation earlier is fine if a hung-mount case shows up
before then.

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
* The shell must show or control file activity while Files is not running.
* A second program needs to submit jobs.

If it happens, the agreed contract is kept in
[files-io-ipc-contract-deferred.md](files-io-ipc-contract-deferred.md). The
in-process boundary was shaped to make this a transport swap, not a rewrite:
owned command messages in, a revisioned table of copied records out. The things
that would still need real design are the journal and per-operation recovery
rules. A recorded intent does not prove the filesystem action did not already
happen, so recovery cannot be generic. Do that work per operation when it is
needed, not before.
