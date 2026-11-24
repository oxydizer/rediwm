# Files I/O Service Architecture

**Status:** Architecture direction agreed; protocol details remain under
design.

This document defines the intended process boundary and ownership model for
RediWM Files filesystem operations. It is a design contract, not a claim that
the service or its IPC implementation already exists.

## 1. Goals

The I/O architecture must provide:

* Filesystem operations continue when every Files window is closed.
* Closing or crashing the Files UI does not terminate active operations.
* Restarting the RediWM shell does not interrupt filesystem operations.
* A filesystem operation failure cannot take down the shell or Files UI.
* All Files windows share one process-level Manager, Runtime, resource
  ledger and bounded worker capacity.
* Service internals remain independent of the IPC transport and UI.
* Service restart recovery is conservative: interrupted work is reconciled,
  never blindly replayed.

The initial service has one consumer: RediWM Files. It should have clean
internal boundaries that permit future consumers, but we will not build a
general-purpose file-operation platform or public SDK without a real need.

## 2. Process boundaries

The architecture consists of three independently failing processes.

### RediWM Shell

The shell provides system-level presentation:

* A file-operation activity indicator.
* Notifications for completion, failure and attention-required states.
* An entry point to the operation overview.
* Controls forwarded to the service, such as pause, resume and cancel.

The shell does not execute filesystem operations, own operation workers,
or understand operation-specific implementation details such as recursive
copy, archive extraction or rollback.

A service failure must not compromise shell operation.

### RediWM Files

Files owns the user interface:

* Windows, tabs, navigation, selection and browsing.
* Submission of filesystem jobs.
* Per-window and per-job progress presentation.
* Inspection and control of jobs through the service.

Files does not own the process-level I/O Runtime or worker pools. Individual
windows must not create independent Managers, Runtimes or worker capacity.

Closing a window, closing all windows, or restarting Files must not cancel
jobs owned by the service.

### `rediwm-files-io`

This is a standalone, session-managed process. It owns:

* One process-level I/O Manager.
* One Runtime and resource ledger.
* Shared, bounded operation and discovery executors.
* Job and operation lifecycle.
* Filesystem operation execution and resource ownership.
* Service-wide job identity and event sequencing.
* The durable job journal and restart reconciliation.

The service has no dependency on Wayland surfaces, Files windows, shell
objects or UI state.

## 3. Ownership model

There is one authoritative Manager and one authoritative Runtime per service
process.

The Manager remains responsible for main-thread state transitions,
dependency scheduling, dispatch decisions and user-visible job snapshots.

Workers perform bounded filesystem work and return completions. They do not
directly mutate Manager state. The service accepts completions and performs
state transitions on its owning thread.

The Runtime coordinates cancellation, executor quiescence and safe job
retirement. The resource ledger records resources still owned by each job;
it does not replace resource-specific cleanup logic.

The existing resource-ledger work remains useful. Its ownership boundary
moves to the service rather than being duplicated per Files window.

Worker capacity is shared across all jobs. Opening more Files windows must
not multiply the number of operation or discovery workers.

## 4. IPC boundary

The initial transport is a private Unix-domain socket, local to the logged-in
user session.

The service core must not depend on the socket implementation. IPC is an
adapter that validates requests, invokes core operations and serializes
results and events.

The socket belongs in a private directory below `$XDG_RUNTIME_DIR`, with
appropriate directory and socket permissions. The service must validate
client identity and enforce bounded input and output.

D-Bus is not the initial transport. It remains a possible future adapter if
a concrete integration need justifies its additional API and operational
complexity. The service core must not need to change if another transport is
introduced.

### Existing codebase precedents

The implementation should learn from, but not blindly copy, existing RediWM
code:

* `src/ipc/server.zig` — Unix socket lifecycle, multiple clients, buffering,
  nonblocking I/O and client handling.
* `src/ipc/protocol.zig` and its parsing/stringifying modules — request
  envelopes, validation, request IDs and response serialization.
* `src/ipc/events.zig` — event sequencing and subscription concepts.
* `src/dm/proto.zig` — bounded length-prefixed framing and framing tests.

The compositor IPC server is tied to compositor state and its event loop.
The DM protocol has useful framing ideas but is not a ready-made
multi-client asynchronous service transport. Reuse concepts, not their
entire implementations.

### Wire protocol

The framing format remains an open decision:

* Newline-delimited JSON.
* Length-prefixed JSON.

Whichever format is selected must support:

* An explicit protocol version.
* Request IDs and correlated responses.
* Bounded frame sizes and bounded per-client buffers.
* Partial reads and writes.
* Multiple requests and asynchronous events.
* Malformed, truncated and oversized input handling.
* Backpressure and slow-client handling.
* Independent protocol and transport tests.

Do not send file contents, directory listings or archive payloads through
the control protocol. It carries job requests, snapshots, state changes and
control messages only.

## 5. Initial service contract

The initial API should remain focused on the requirements of Files.

Candidate requests:

* `SubmitJob`
* `ListJobs`
* `GetJob`
* `Subscribe`
* `PauseJob`
* `ResumeJob`
* `CancelJob`
* `ResolveConflict`
* `AcknowledgeJob`

The exact request and response schemas are to be designed before the
transport implementation.

Job IDs are service-wide, not window-local. A job remains addressable after
the window that submitted it has closed.

A disconnected client does not cancel a job. A client can reconnect and
retrieve current job state.

## 6. Snapshots and events

Clients need an initial snapshot and subsequent incremental updates.

The service maintains a monotonically increasing event sequence. A
snapshot includes the sequence at which it was produced. Events carry their
sequence so clients can detect gaps and request a fresh snapshot.

Subscription setup must avoid a race between retrieving a snapshot and
receiving subsequent events. This can be achieved through an atomic
snapshot-and-subscribe operation or an equivalent replay mechanism.

Progress updates may be coalesced when necessary. Terminal state changes,
conflict requests and other user-actionable events must not be silently
lost.

Client queues and event buffering must be bounded. A slow or disconnected
client must not be allowed to consume unbounded service memory.

## 7. Failure semantics

Transport failures and job failures are different.

A client disconnect is not a job failure. A malformed request is a request
failure, not a service-wide failure. A filesystem error should normally
affect only the job and operation that encountered it.

The intended isolation guarantees are:

| Failure | Expected result |
| --- | --- |
| Files window closes | Jobs continue in the service |
| All Files windows close | Jobs continue in the service |
| Files crashes or restarts | Jobs continue; Files reconnects |
| Shell crashes or restarts | Jobs continue; shell reconnects |
| One job encounters an error | That job reports the error |
| One client disconnects | Other clients and jobs continue |
| Service crashes | Shell and Files remain operational |
| Service restarts | Interrupted jobs are reconciled |

The service must contain worker failures and allocation or filesystem errors
within appropriate job boundaries wherever possible.

Service-process isolation does not by itself guarantee recovery from a
service crash. Recovery is addressed separately below.

## 8. Persistence and restart recovery

The existing resource ledger is an in-memory ownership and teardown
mechanism. It is not a durable journal.

A separate durable job journal should record enough information to identify
jobs and determine their state after a service restart. Its design must
account for the filesystem state that may have been left behind by an
interrupted operation.

On restart:

1. Load the journal.
2. Identify jobs that were active when the service stopped.
3. Reconcile their known staging and destination state.
4. Mark jobs interrupted, failed or requiring attention as appropriate.
5. Expose the resulting state to reconnecting clients.

The service must not blindly replay destructive operations. A recorded
intent does not prove that the corresponding filesystem action did not
already happen.

Safe automatic resume may be added later for individual operation types
once their checkpoints, idempotency and recovery rules are explicitly
defined and tested.

## 9. Startup and supervision

The service belongs to the logged-in RediWM user session. It must not be a
child of the Files process or depend on a Files window remaining open.

Startup and supervision are separate concerns:

* Activation starts the service when a client first needs it.
* Supervision keeps the service alive and can restart it after failure.

The session integration should support independent service lifetime and
restart without coupling service health to shell or Files health.

The exact activation and keep-alive policy remains open. In all cases,
active jobs must keep the service alive when its clients disconnect.

## 10. Security and resource limits

The initial service is local to the user session, not a network service.

It must:

* Restrict access to the private runtime socket.
* Validate peer identity where supported.
* Validate all requests and reject unsupported protocol versions.
* Bound request sizes, client counts, queues and worker capacity.
* Avoid trusting client-supplied filesystem paths or operation metadata
  without normal filesystem validation.
* Treat client disconnects and malformed messages as normal failure cases.

The service must not let one client or one job exhaust resources needed by
other jobs.

## 11. Implementation sequence

The migration should proceed in independently reviewable stages.

1. **Finalize the service contract.** Define job identity, lifecycle,
   request/response schemas, event semantics, error handling and framing.
2. **Extract the service core.** Move process-level Manager and Runtime
   ownership out of Files windows. Keep the core independent of IPC and UI.
3. **Create the headless service executable.** It owns one Manager, Runtime,
   resource ledger and shared bounded worker capacity.
4. **Implement the private IPC adapter.** Add client connections, protocol
   validation, snapshots, events, reconnection and transport tests.
5. **Move Files onto the service.** Replace per-window Runtime ownership
   with a client adapter. Ensure tab and window lifecycle cannot destroy
   service-owned jobs.
6. **Add the shell client.** Present global activity and notifications and
   forward user controls without embedding operation logic in the shell.
7. **Add durable recovery.** Journal job state and reconcile interrupted
   operations after service restart.

The existing Files I/O Manager roadmap remains relevant to Manager
correctness, resource ownership, scheduling, testing and performance.
However, its remaining implementation phases must be evaluated against this
process boundary. The service extraction is a prerequisite to treating the
Manager as the single process-level execution architecture.

## 12. Open decisions

The following decisions must be settled before their implementation begins:

* Newline-delimited JSON versus length-prefixed JSON framing.
* Exact request, response and event schemas.
* Atomic snapshot/subscription or event replay strategy.
* Service activation and keep-alive policy.
* Journal format, durability guarantees and reconciliation rules.
* Which operation types, if any, can eventually support safe automatic
  resume.

These decisions should be made from concrete requirements and failure
semantics, not by prematurely building a general-purpose framework.

## 13. Constraints

* Keep the service core transport-independent.
* Keep the initial IPC private and Files-focused.
* Do not introduce D-Bus merely for hypothetical future consumers.
* Do not duplicate Managers, Runtimes, ledgers or worker pools per window.
* Do not move filesystem operation execution into the shell.
* Do not promise automatic recovery until an operation has proven recovery
  semantics.
* Keep each migration stage focused, tested and independently reviewable.
* Commit and push after each meaningful unit of work is completed and
  verified.
