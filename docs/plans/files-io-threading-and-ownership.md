
# Files I/O Threading and Ownership Model

**Status:** Design agreed; implementation pending.

This document records the agreed execution-thread and responsibility split for the Files I/O service. It supplements [Files I/O Service Architecture](files-io-service-architecture.md) and its Initial IPC Contract.

## 1. Goal

Keep the RediWM Files UI responsive under heavy, concurrent filesystem activity.

The UI event-loop thread must remain focused on presentation and user interaction. Filesystem orchestration, completion reconciliation, resource lifecycle management and other potentially expensive I/O service work must not run on that thread.

This is a responsiveness requirement, not merely a preference about code organization.

## 2. Agreed architecture

The service uses a dedicated I/O service thread. The service thread owns the process-level I/O Runtime and coordinates the existing bounded worker pools.

The initial design does not replace the worker pools or create a worker pool per window. Existing discovery and operation workers remain shared service resources. The dedicated service thread is an orchestration and ownership boundary, not a substitute for filesystem workers.

The high-level flow is:

```text
Files UI windows
  |  bounded commands
  v
I/O service thread
  |  Manager, Runtime, scheduling, reconciliation
  v
Existing bounded worker pools
  |  filesystem work and completions
  v
I/O service thread
  |  snapshots and sequenced updates
  v
Files UI windows
```

The service core remains independent of GTK, Wayland surfaces and window state.

## 3. Service-thread ownership

The service thread exclusively owns and accesses:

- The authoritative `io_manager.Manager`.
- The process-level `io_runtime.Runtime`.
- The shared discovery and operation executors and their worker-pool coordination.
- The process-level resource ledger and retirement bookkeeping.
- Job and operation lifecycle transitions.
- Scheduling, dispatch preparation and completion reconciliation.
- Cancellation, pause/resume coordination and safe retirement.
- Collision detection and conflict registration/resolution.
- Archive staging, publication barriers, extraction lifecycle and cleanup.
- Service-side filesystem resource ownership and hand-offs.
- Service-wide event sequencing and publication of job snapshots/updates.

Manager and Runtime pointers are not exposed to UI windows. Their mutable state is not concurrently accessed by UI threads.

Workers continue to execute bounded work units and return owned completions. They do not directly mutate Manager state or access UI objects.

## 4. UI-thread ownership

The Files UI thread exclusively owns:

- GTK and Wayland objects, surfaces and interaction state.
- Windows, tabs, navigation, selection and browsing presentation.
- Rendering and view-model updates.
- User interaction and UI-specific notices.
- Opening an extracted archive member in a viewer/editor.
- Clipboard and drag-and-drop integration that requires UI or platform objects.

A window submits requests to the service and consumes service snapshots or updates. It does not directly call Manager or Runtime methods, drain worker completion queues, dispatch work, or perform service-owned cleanup.

The UI thread must not block waiting for a filesystem operation or for the service to finish processing a command. Command submission and update delivery are asynchronous.

## 5. Communication boundary

Windows and the service communicate through bounded message queues. The queue abstraction is an internal thread boundary; it does not replace or redefine the separately specified Unix-domain socket IPC contract.

Commands sent from a window express intent. The service validates and processes them, then publishes authoritative state. A successful enqueue or command response does not imply that the requested job transition has completed.

Service-to-window data consists of immutable snapshots and sequenced updates. Windows may maintain local presentation projections, but may not invent authoritative job state.

The communication design must provide:

- Bounded command and update queues.
- Explicit handling of queue saturation.
- No blocking UI-thread send or receive.
- Fair processing so one window cannot monopolise service work.
- Coalescing of replaceable progress updates.
- Preservation of non-coalescible lifecycle and user-actionable events.
- Sequence-based gap detection and snapshot resynchronisation.
- Safe handling of window closure and client disconnection.

If a UI consumer cannot keep up, replaceable progress may be coalesced. Important state transitions and conflict requests must not be silently discarded. The consumer must be able to detect lost continuity and obtain a fresh snapshot.

## 6. Responsiveness and bounded work

Moving orchestration off the UI thread is the primary guarantee. The service thread must also avoid becoming an unbounded bottleneck.

- Service command processing and per-client delivery must be bounded and fair.
- Worker queues remain bounded and apply backpressure.
- Progress publication should be coalesced rather than generating unbounded updates.
- Completion reconciliation should be measured and split into bounded units where necessary.
- Potentially expensive filesystem preparation, metadata access, directory opening, archive staging and cleanup must not migrate back to the UI thread.
- Expensive service-side preparation or publication work may be moved to worker tasks when measurements and ownership requirements justify it.
- Worker counts and queue capacities remain shared service configuration; tuning them is a separate measured decision.

The service thread may perform Manager state transitions and bounded in-memory coordination. It must not wait synchronously for a worker, filesystem operation, UI response or user decision.

### Cancellation without blocking

Cancellation is an asynchronous service state transition, not a synchronous
worker-control operation.

- A cancellation command records cancellation intent in service-owned state
  and signals the affected in-flight work through a cancellation token or
  equivalent thread-safe mechanism.
- Workers observe cancellation at defined safe checkpoints within their
  bounded work units. They do not mutate Manager state or release
  service-owned resources.
- A worker that observes cancellation returns an owned completion describing
  the work performed and any resources or partial output that remain.
- The service reconciles every dispatched unit and performs the required
  cleanup before releasing its resource leases or declaring the job
  `Cancelled`.
- Work that cannot be interrupted safely, including an in-progress
  uninterruptible filesystem call, may delay cancellation. It must not block
  the service loop or prevent unrelated jobs and commands from progressing.
- Queued work that has not started may be withdrawn when the worker-pool
  contract permits it. The service must still account for every dispatched
  unit exactly once.

The service must not wait for an individual worker, synchronously join a
pool, or wait for pool quiescence while processing ordinary commands or
completions. During shutdown it continues coordinating cancellation and
completion reconciliation. Worker joins belong to final teardown, after
outstanding work has been accounted for and the pools have stopped accepting
work.

### Service command admission and fairness

Service ingress is bounded independently of the per-window update queues.

- Each window has a bounded command allowance, and the service enforces a
  bounded aggregate command capacity.
- The service processes commands fairly across windows, using bounded
  per-window work quotas so a busy producer cannot monopolise the service
  thread.
- Capacity limits and per-iteration processing quotas must be explicit
  implementation constants, covered by saturation and fairness tests.
- A full command queue produces an explicit non-blocking rejection. The UI
  must not wait for capacity or assume that a rejected command was accepted.
- Cancellation and other control commands must not be starved by ordinary
  submissions. Their admission path must have reserved capacity or an
  equivalent bounded priority mechanism.

No command queue may grow without limit, and queue saturation must never
cause the service thread to block waiting for a producer or consumer.

### Worker preparation ownership

If measurements justify moving preparation work to workers, the service
thread first captures the required inputs into an immutable, independently
owned task payload.

Workers may inspect and transform that payload and perform the filesystem
work assigned to them. They must not read or mutate Manager-owned state,
retain pointers into Manager collections, or perform lifecycle transitions.
They return owned results through the normal completion path; only the
service thread validates and applies those results to authoritative state.

This rule applies to preparation, metadata access, publication and cleanup
tasks as well as the primary operation workers.

### Bounded UI update delivery

Each UI consumer processes a bounded number of messages or a bounded amount
of delivery work per event-loop iteration. A large backlog for one window
must not monopolise the process event loop or delay other windows.

The service publishes fairly across consumers. Replaceable progress updates
may be coalesced by job, while non-coalescible lifecycle and user-actionable
events retain their ordering guarantees.

If a consumer's bounded queue cannot preserve continuity, the service marks
that consumer as requiring resynchronisation rather than blocking or
silently discarding authoritative state transitions. The consumer obtains
a fresh snapshot and resumes from its sequence position.


## 7. Archive lifecycle split

Archive handling currently crosses service and App responsibilities. It must be separated deliberately.

Service-owned responsibilities include:

- Archive extraction and staging work.
- Staging resource leases and ledger accounting.
- Cancellation and cleanup of staging data.
- Publication registration and barrier state.
- Validation that publication work has drained.
- Completion and retirement of archive-related jobs.
- Preparing an owned hand-off when extracted content is ready for a UI consumer.

UI-owned responsibilities include:

- Deciding whether the relevant window is still in the navigation context that requested the extraction.
- Opening an extracted member in a viewer or editor.
- Clipboard and drag integration that requires UI/platform facilities.
- Accepting or declining a prepared hand-off.

The service must not call GTK/Wayland or retain pointers to an App or window. A UI hand-off must use an explicit owned payload or lease with defined transfer and cleanup semantics. Closing the requesting window must not leak staging resources or prevent the service from cleaning them up.

This split must preserve the existing publication-barrier and resource-ledger invariants. It is not permission to simplify away those guarantees.

## 8. Window and job lifetime

Jobs belong to the service, not to the window that submitted them.

The originating window identifier, where retained, is metadata for origin/context and is not a lifetime owner or an authorization to destroy the job.

A window may hold a presentation reference to a job. Closing that window releases its local subscription and presentation state only. It must not implicitly cancel, retire or destroy the job.

Another window may inspect and manage the same service-owned job. The service remains responsible for job lifetime, resource quiescence and retirement.

## 9. Shutdown and failure

The service thread owns orderly Runtime shutdown:

1. Stop accepting new commands.
2. Apply the service's defined shutdown policy to active jobs.
3. Request cancellation where required by that policy.
4. Continue processing worker completions and cleanup until all dispatched
   work has been accounted for and workers have stopped accessing
   service-owned state.
5. Stop and join worker pools during final teardown.
6. Release service-owned staging and other resources.
7. Verify the resource ledger is empty and deinitialize Manager/Runtime.
8. Close communication queues and notify or disconnect clients as appropriate.

UI shutdown only releases that window's subscriptions, queues and UI-owned state. It must not tear down the shared service Runtime.

The exact process supervision and durable crash-recovery behaviour remain governed by the parent service architecture and IPC contract.

## 10. Migration constraints

The transition must be incremental and reviewable.

- Preserve the existing Manager state-machine and resource-ledger correctness.
- Do not expose Manager or Runtime pointers across the thread boundary.
- Audit every executor callback and archive hand-off before moving ownership.
- Separate service-side filesystem/lifecycle actions from UI/platform actions.
- Preserve origin-window metadata without making it job ownership.
- Keep existing worker pools shared; do not multiply them per window.
- Add tests for queue saturation, ordering, shutdown, window closure, multiple consumers and archive lease transfer.
- Measure UI responsiveness under concurrent heavy I/O, not only operation throughput.

No implementation detail should be changed solely to fit the new thread model if it weakens an established lifecycle or recovery invariant.

## 11. Core invariant

**No Files UI event-loop thread performs I/O service orchestration, drains worker completions, or blocks on filesystem work.**

The service thread owns authoritative I/O state and lifecycle. Workers perform bounded filesystem work. UI threads present state and handle user/platform interaction. Communication between these responsibilities is asynchronous, bounded and explicit.
