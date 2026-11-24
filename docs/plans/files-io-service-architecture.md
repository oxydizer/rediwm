# Files I/O Service Architecture

**Status:** Architecture and initial IPC contract agreed; implementation
pending.

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

The initial wire format is version 1 newline-delimited JSON (NDJSON),
following the framing convention used by RediWM compositor IPC.

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

The initial protocol uses version 1 NDJSON. Each message is one JSON object
terminated by a newline.

The implementation must support:

* An explicit protocol version.
* Request IDs and correlated responses.
* Maximum message size and bounded per-client buffers.
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

The agreed initial API consists of eight requests:

* `SubmitJob`
* `ListJobs`
* `GetJob`
* `Subscribe`
* `PauseJob`
* `ResumeJob`
* `CancelJob`
* `ResolveConflict`

`AcknowledgeJob` was considered during the initial architecture discussion
but is intentionally excluded from version 1. The initial service does not
require a separate acknowledgement command.

The initial request and response envelope, error model, job lifecycle and
event semantics are specified in the Initial IPC Contract below.

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

If a non-coalescible event cannot be queued because a client's output queue
is full, the service disconnects that client. It must not silently discard
the event or block job execution. The client reconnects and resynchronises
through event replay or a fresh snapshot.

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

The durable journal also stores submission idempotency records, including
the idempotency key, payload fingerprint and associated job ID. A successful
job submission and its idempotency record must be committed consistently.
This is part of the job journal, not a separate persistence system.

Idempotency records must survive service restarts and remain available at
least as long as their associated job records. If job-history pruning is
introduced, the service must retain sufficient idempotency information to
prevent unintended duplicate submissions during the applicable retention
period.

On restart:

1. Load the journal.
2. Identify jobs that were active when the service stopped.
3. Reconcile their known staging and destination state.
4. Mark jobs interrupted, failed or requiring attention as appropriate.
5. Expose the resulting state to reconnecting clients.

The service must not blindly replay destructive operations. A recorded
intent does not prove that the corresponding filesystem action did not
already happen.

Recovery decisions are operation-specific. The service must not infer retry
safety from generic job state or journal intent alone. Each supported
operation must define its recovery checkpoints, staging semantics,
publication semantics and reconciliation rules before automatic recovery
or retry is permitted for that operation.

If the service cannot establish a safe outcome, it marks the job
`Interrupted` and preserves the information needed for inspection or
subsequent recovery.

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

* Detailed command parameter schemas and event payload schemas not yet
  specified in the initial IPC contract.
* Service activation and keep-alive policy.
* Journal format and exact durability implementation.
* Operation-specific recovery rules before implementing each operation.
* Which additional operation types, if any, can eventually support safe
  automatic resume.

The initial framing, eight-command API, snapshot/subscription semantics,
connection lifecycle and backpressure behaviour are agreed in the Initial
IPC Contract below. Their implementation details remain to be tested.

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

# Initial IPC Contract

**Status:** Initial design agreed; implementation pending.

## 1. Scope and principles

The initial IPC contract defines communication between the RediWM Files application and the independent RediWM Files I/O service.

The initial implementation has one consumer: RediWM Files. The protocol is private to the RediWM session and is not intended to be a general-purpose public API.

The design follows these principles:

- The service owns all job state and lifecycle decisions.
- Clients submit commands and observe authoritative service state.
- Jobs are independent of client connections and application windows.
- IPC failures must not interrupt or stall job execution.
- All messages and resource consumption are bounded.
- The protocol should remain simple and extensible without introducing speculative functionality.

The service core must remain independent of the transport implementation.

## 2. Transport and wire format

The initial transport is a private Unix-domain stream socket located below `$XDG_RUNTIME_DIR`.

The initial wire format is newline-delimited JSON (NDJSON), following the general framing convention used by RediWM compositor IPC.

Each message consists of one JSON object terminated by a newline.

Requirements:

- Maximum message size must be enforced.
- Input and output buffers must be bounded.
- Partial reads and writes must be handled correctly.
- Multiple messages may arrive in a single read.
- A message may arrive across multiple reads.
- Malformed or oversized messages must be rejected safely.
- Socket operations must be nonblocking.
- The service must not perform blocking socket operations in its main coordination loop.

The protocol is versioned from its first implementation.

The initial protocol version is `1`.

## 3. Message envelopes

### 3.1 Request

Every client request uses a common envelope:

```json
{
  "version": 1,
  "id": "request-uuid",
  "command": "GetJob",
  "params": {
    "job_id": "job-uuid"
  }
}
```

Fields:

- `version`: protocol version.
- `id`: client-generated request identifier.
- `command`: command name.
- `params`: command-specific parameters.

Request IDs correlate responses with requests. They are distinct from job IDs.

The service must validate the envelope, protocol version, command and parameters before processing a request.

### 3.2 Successful response

```json
{
  "version": 1,
  "id": "request-uuid",
  "result": {
    "job": {}
  }
}
```

### 3.3 Error response

```json
{
  "version": 1,
  "id": "request-uuid",
  "error": {
    "code": "INVALID_STATE",
    "message": "Job cannot be paused in its current state",
    "details": {
      "current_state": "completed"
    }
  }
}
```

Error fields:

- `code`: stable machine-readable error identifier.
- `message`: explanatory text intended for logs and user-facing presentation.
- `details`: optional structured information.

Clients must make decisions using error codes, not by parsing error messages.

## 4. Job identity

Job IDs are generated by the service.

The initial representation is a UUID, encoded as a canonical string.

Requirements:

- Job IDs must be globally unique within the service's persistent job history.
- Job IDs must not depend on client connections or Files windows.
- A job retains its ID across service restarts and recovery.
- Clients must not choose job IDs.

### 4.1 Submission idempotency

`SubmitJob` accepts an optional client-generated idempotency key.

The purpose is to prevent accidental duplicate submissions when a client loses its connection or response and retries a request.

Rules:

- Repeated submissions with the same key and identical payload return the original job.
- Reusing a key with a different payload returns `IDEMPOTENCY_CONFLICT`.

The idempotency key is not the job identity.

Idempotency records are stored in the durable job journal alongside job
records. The journal stores the key, payload fingerprint and associated job
ID. The job submission and its idempotency record must be committed
consistently so a crash cannot leave a successfully accepted job without
its corresponding deduplication record.

Idempotency records must survive service restarts and remain available at
least as long as their associated job records.

## 5. Job lifecycle

The initial job states are:

- `Queued`
- `Running`
- `Paused`
- `AwaitingInput`
- `Completed`
- `Failed`
- `Cancelled`
- `Interrupted`

### 5.1 State meanings

**Queued**

The job has been accepted and is waiting for execution or required resources.

**Running**

The job is actively executing.

**Paused**

The job has reached a safe pause point and is waiting for a resume request.

**AwaitingInput**

The job requires a user decision, such as resolving a filesystem conflict.
Execution has stopped at a safe checkpoint. No worker remains blocked
waiting for user input.

**Completed**

The operation has completed successfully.

**Failed**

The operation encountered an execution failure that prevented successful completion.

**Cancelled**

Cancellation has completed, workers have stopped modifying the filesystem, and required cleanup or reconciliation has finished.

**Interrupted**

The service cannot establish a safe continuation or definitive outcome following an interruption or recovery.

Completed, Failed, Cancelled and Interrupted are terminal states.

Terminal jobs remain queryable. Retention and cleanup are separate policies.

### 5.2 Command and state separation

Commands express client intent. State changes occur only after the service has performed the corresponding transition.

Examples:

- `PauseJob` requests a pause. The state becomes `Paused` only when the operation reaches a safe pause point.
- `ResumeJob` requests resumption. The job returns to `Queued` or progresses to `Running` as appropriate.
- `CancelJob` requests cancellation. The job becomes `Cancelled` only after cancellation and required cleanup have completed.
- `ResolveConflict` supplies a decision for a pending conflict.

A successful command response does not necessarily mean the requested state transition has completed.

The authoritative transition is communicated through job state and events.

### 5.3 Conflict-pending execution

When an operation encounters a conflict requiring user input:

1. The worker stops at a safe checkpoint and returns control to the Manager.
2. The Manager records the pending conflict and its associated conflict ID.
3. The Manager transitions the job to `AwaitingInput`.
4. The worker slot is released. No worker remains blocked waiting for a
   client or user decision.
5. The job retains the staging and operation state required to continue
   safely.
6. `ResolveConflict` validates the job, conflict ID and resolution.
7. A valid resolution is recorded by the Manager, and execution resumes
   through normal scheduling.

An unresolved conflict has no automatic timeout in version 1. The job
remains `AwaitingInput` until a valid resolution is supplied or the job is
cancelled.

If the client that originally submitted the job disconnects, the pending
conflict remains part of the service-owned job. Another connected client
can inspect and resolve it.

### 5.4 Client independence

Jobs must survive:

- Closing an individual Files window.
- Closing all Files windows.
- Files application crashes.
- Client disconnections.
- Shell restarts.

The service owns job lifetime independently of all clients.

## 6. Crash recovery

The service maintains a durable job journal separate from its in-memory resource ledger.

After restarting, the service reconciles interrupted jobs against the recorded state and observable filesystem state.

Recovery rules:

- If completion can be established, mark the job `Completed`.
- If it can be established that no work was committed and retry is demonstrably safe, return the job to `Queued`.
- If the outcome is ambiguous or the filesystem may contain partially committed results, mark the job `Interrupted` and preserve recovery information.

The service must never blindly replay an interrupted operation.

Recovery is operation-specific. Each supported operation must define its
recovery checkpoints, staging semantics, publication semantics and
reconciliation rules. The service must not infer that retry is safe from
generic job state or journal intent alone.

Automatic resume may be introduced later for individual operation types once their recovery semantics have been demonstrated to be safe.

## 7. Initial service API

The initial API consists of eight commands.

### 7.1 SubmitJob

Submits a new filesystem operation.

Parameters:

- Optional `idempotency_key`.
- `operation`: operation-specific payload.

The service generates and returns the job ID.

The initial implementation should support only the operations required by RediWM Files.

The first concrete operation schema is `copy`:

```json
{
  "type": "copy",
  "sources": [
    "/home/user/Documents/report.pdf",
    "/home/user/Pictures/photo.jpg"
  ],
  "destination": "/mnt/storage/backup"
}
```

The `sources` array contains one or more source paths. `destination` is the
destination directory.

The service must validate the payload structure and perform normal
filesystem validation when executing the operation. Client-supplied paths
must not be trusted merely because the request came through the private
socket.

The schema above establishes the initial wire shape. Detailed semantics
such as source identity revalidation, destination handling, symlink
behaviour, special files and conflict detection must be defined against the
existing copy implementation before the operation is enabled in the
service.

### 7.2 ListJobs

Lists jobs known to the service.

Optional parameters:

- State filter.
- Result limit.
- Pagination cursor.

The service returns a page of job records and an optional continuation cursor.

### 7.3 GetJob

Retrieves the latest authoritative state of one job.

Required parameter:

- `job_id`.

### 7.4 PauseJob

Requests that a job be paused.

Required parameter:

- `job_id`.

### 7.5 ResumeJob

Requests that a job resume.

Required parameter:

- `job_id`.

### 7.6 CancelJob

Requests cancellation of a job.

Required parameter:

- `job_id`.

### 7.7 ResolveConflict

Supplies a resolution for a pending conflict.

Required parameters:

- `job_id`.
- `conflict_id`.
- `resolution`.

Initial resolution values:

- `replace`
- `skip`
- `keep_both`
- `cancel_job`

The service validates the resolution and performs the corresponding operation.

### 7.8 Subscribe

Establishes an event subscription for the client.

Optional parameter:

- Last-seen event sequence.

The service provides an initial snapshot and subsequently delivers events.

The exact snapshot and event-stream ordering requirements are defined in Section 8.

## 8. Snapshots and event sequencing

The service is authoritative for all job state.

Clients receive snapshots and events and must not independently invent job state transitions.

### 8.1 Event sequence

The service maintains a monotonically increasing, service-wide event sequence.

Every meaningful state-changing event receives a sequence number.

Sequence numbers:

- Are shared across all jobs.
- Are shared across all connected clients.
- Establish event ordering.
- Must not be reused during the lifetime of the persistent service history.

Progress updates may be coalesced. The service does not need to persist or emit every intermediate progress increment.

Meaningful job state transitions must not be silently discarded.

### 8.2 Snapshot

A snapshot represents the service's authoritative state at a particular sequence number.

It includes:

- Relevant job records.
- The sequence number at which the snapshot was captured.

Example:

```json
{
  "jobs": [],
  "sequence": 142
}
```

The snapshot sequence establishes the baseline for subsequent event processing.

### 8.3 Initial subscription

Subscription establishment must be atomic from the client's perspective.

The service must ensure:

1. The subscription is registered.
2. A snapshot is captured at sequence N.
3. The snapshot includes sequence N.
4. All subsequent events after N are delivered in order.

No state change may fall between snapshot capture and event registration without being represented in either the snapshot or subsequent event stream.

### 8.4 Reconnection

Clients may reconnect after disconnection and provide their last successfully processed sequence number.

If the service retains a continuous event history after that sequence, it may replay subsequent events.

If continuity cannot be guaranteed, the service sends a fresh snapshot.

Clients must never assume that their local state remains authoritative after losing event continuity.

### 8.5 Progress events

Progress events may be coalesced to prevent excessive traffic and memory usage.

A newer progress update may supersede an older update for the same job.

State transitions and other meaningful events must remain recoverable through event replay or a fresh snapshot.

If a non-coalescible event, including a job state transition or conflict
request, cannot be queued because the connection's output capacity has been
reached, the service disconnects that client. It must not silently discard
the event or block job execution. The client must resynchronise after
reconnecting.

## 9. Connection lifecycle

### 9.1 Multiple clients

The service supports multiple simultaneous client connections.

Each Files window may maintain its own connection.

All clients observe the same service-owned jobs.

Each connection maintains independent:

- Input buffer.
- Output queue.
- Subscription state.
- Connection lifecycle.

There is one service-owned Manager and one shared bounded worker-pool architecture, not one Manager or worker pool per connection.

### 9.2 Disconnection

A client disconnection must not modify or cancel jobs.

On disconnection, the service:

- Detects EOF or socket errors.
- Stops delivering events to the connection.
- Releases connection-specific resources.
- Preserves job state and execution.

Clients may reconnect at any time.

### 9.3 Backpressure

Each connection has bounded input and output buffering.

The service must prevent slow clients from causing unbounded memory consumption or blocking job execution.

Rules:

- Progress updates may be coalesced.
- Output queues have explicit capacity limits.
- Socket writes are nonblocking.
- Partial writes preserve unsent message data.
- A client that exceeds its output capacity is disconnected.
- Important events must not be silently dropped while maintaining a connection.
- After disconnection, the client must resynchronise through replay or a fresh snapshot.

Disconnecting a slow client is preferable to silently losing meaningful events or allowing unbounded queue growth.

### 9.4 Fairness

One client must not monopolise service processing.

The service should:

- Limit input processing per connection per event-loop iteration.
- Limit output processing per connection per event-loop iteration.
- Maintain independent connection queues.
- Continue processing job completions and other clients regardless of one client's activity.

## 10. Security and resource limits

The initial service is private to the user's session.

Requirements:

- Socket resides below `$XDG_RUNTIME_DIR`.
- Socket permissions restrict access to the owning user.
- All requests are validated, regardless of socket permissions.
- Simultaneous connections are bounded.
- Per-connection memory usage is bounded.
- Input message sizes are bounded.
- Output queue capacity is bounded.
- Malformed or oversized messages are rejected safely.

The initial implementation does not require a general-purpose authentication system for this private same-user Unix socket.

## 11. Error codes

The initial protocol defines the following machine-readable error codes:

- `INVALID_REQUEST`
- `UNSUPPORTED_VERSION`
- `UNKNOWN_COMMAND`
- `INVALID_ARGUMENT`
- `JOB_NOT_FOUND`
- `INVALID_STATE`
- `CONFLICT_NOT_FOUND`
- `IDEMPOTENCY_CONFLICT`
- `RESOURCE_LIMIT`
- `SERVICE_BUSY`
- `INTERNAL_ERROR`

Filesystem execution failures belong to the job's own error information.

They must not be confused with IPC request failures.

A failed request to pause a job, for example, does not mean the job itself has failed.

## 12. Explicit initial exclusions

The initial implementation does not include:

- Arbitrary job deletion.
- Arbitrary job modification.
- Worker or scheduler controls exposed over IPC.
- Internal resource-ledger inspection.
- General-purpose filesystem operations exposed as service commands.
- Notification acknowledgement or dismissal commands.
- The `AcknowledgeJob` command.
- A public SDK or general-purpose external API.
- D-Bus transport.

These exclusions are intentional scope controls, not permanent architectural restrictions.

New commands and capabilities may be introduced when concrete requirements justify them.

## 13. Implementation details to determine later

The contract defines behaviour and guarantees, but deliberately does not prescribe every implementation value.

The following remain engineering decisions:

- Maximum NDJSON message size.
- Input and output buffer capacities.
- Maximum simultaneous connections.
- Event-history retention capacity.
- Job-history retention policy.
- Exact progress-event coalescing strategy.
- Exact event payload schemas.
- Submission schemas for operation types not yet defined, and detailed
  execution semantics for the initial copy operation.
- Socket polling and scheduling details.

These values should be chosen based on implementation requirements, resource constraints and testing rather than arbitrary initial guesses.

## 14. Compatibility and evolution

Protocol versioning begins at version 1.

Future changes must preserve the distinction between:

- Transport framing.
- Message envelopes.
- Service commands.
- Job state.
- Event delivery.

New optional fields and commands may be introduced where backward compatibility permits.

Changes that alter established semantics or make existing clients incompatible require an explicit protocol-versioning decision.

The service core must remain independent of NDJSON and Unix-domain socket implementation details so that alternative transports can be introduced later if justified.

## 15. Guiding implementation principle

The initial service must be reliable, bounded and independently operable.

It should not become a general-purpose framework before RediWM Files has demonstrated a need for one.

The implementation should prioritise:

1. Correct job ownership and lifecycle.
2. Safe filesystem execution and recovery.
3. Reliable IPC and client reconnection.
4. Bounded resource consumption.
5. Clear failure isolation.
6. Straightforward future evolution.

**The contract is a starting point, not a claim that every edge case is already known.** Real implementation and testing will expose additional requirements. Those should be incorporated deliberately as the architecture evolves.
