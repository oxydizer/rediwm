# Files I/O Manager roadmap

Status: in progress. The I/O Manager is replacing `JobRunner` as the sole
execution and coordination architecture for Files filesystem operations, and is
moving behind one process-owned I/O service.

## Architecture direction

The Manager, Runtime, resource ledger and executors are owned by one
coordinator thread in the Files process. Windows are clients of a service that
sits in front of it. They submit commands and read a table of job records, and
they never touch the Manager. Filesystem work therefore outlives windows, worker
capacity is shared, and the UI thread does no I/O orchestration.

The service is an in-process thread. An out-of-process service with its own
socket protocol and journal was considered and deferred until a concrete need
appears. See:

* [Service Architecture](files-io-service-architecture.md) for ownership, the
  command and job-table interface, job lifecycle and the migration stages S0
  to S5.
* [Threading and Ownership](files-io-threading-and-ownership.md) for threads,
  locking, wake protocol, the coordinator loop, shutdown and the required tests.
* [files-io-ipc-contract-deferred.md](files-io-ipc-contract-deferred.md) for
  the earlier out-of-process contract, kept for reference.

The phases below are the Manager's own correctness, safety and performance work.
They run alongside the service stages and are not blocked by them, except where
the table below says otherwise.

### How the phases and service stages fit

| Service stage | Relation to the phases |
| --- | --- |
| S1 job table, S2 lifecycle | Independent of the phases. S1 adds the Manager's O(1) per-job summary and dirty set, which also serves phase 6 |
| S3 windows move onto the service | **Needs phase 2.** The coordinator rejects mixed file and directory selections today, and `JobRunner` work is invisible to the service, so the fallback must go first |
| S4 archive lifecycle | Builds on phase 1. The archive publication cursor becomes service-owned |
| S5 responsiveness | Overlaps phase 5 (shutdown ordering, allocation failure) and phase 6 (measured scheduling) |

## Goal

Build one process-level I/O Manager that coordinates all Files jobs through a
shared, bounded worker pool. It must support concurrent jobs and independent
operations within a job, incremental directory discovery, cancellation,
pause/resume, conflict resolution, progress reporting and safe resource
retirement.

The architecture separates three responsibilities:

* **Manager:** coordinator-thread job and operation state, dependencies, scheduling,
  dispatch decisions and user-visible snapshots.
* **Executors:** bounded worker execution, operation continuations, discovery
  and filesystem-specific work. Workers are shared capacity, not owned by
  individual jobs.
* **Runtime:** process-level lifecycle coordination, cancellation, executor
  quiescence and safe job retirement.

Filesystem resources must have explicit ownership. A job must not release a
resource while a worker or another owner can still access it.

## Current baseline

Completed and verified:

* Manager-owned jobs and operations, with dependency-aware scheduling.
* Shared operation and discovery executors.
* Incremental directory discovery and dynamically added operations.
* Concurrent independent operations within one job.
* Pause prevents new dispatch while allowing active bounded work to return.
* Cancellation retains running operations until their completions return.
* Directory finalization waits for outstanding child work.
* Runtime coordinates executor quiescence and safe job retirement.
* Dynamic dependency capacity accounting and stress coverage.
* Manager-backed regular-file and symlink copy/move, directory copy/move,
  cross-filesystem detach, archive extraction and archive-member extraction.

The last verified concurrency milestone passed the full test suite:
449 Files tests passed, 4 skipped, and all 553 tests passed overall.

The I/O service core and coordinator thread exist (`io_service.zig`,
`io_coordinator.zig`): bounded command admission, owned payloads, wake
descriptors, copy and move of files, symlinks and directories, discovery,
conflict and resource-release commands, and per-job state and progress
publication. The process owns them. Windows do not use them yet: each still owns
its own Runtime until stage S3.

`JobRunner` is **not yet removed**. It remains the fallback for transfers the
Manager path does not accept, notably mixed selections and unsupported entry
types. Legacy progress, manifest and transfer UI paths also remain.

## Phase 1 — Per-job resource ledger

**Foundation in place** (`io_resource_ledger.zig`, owned by `io_runtime.Runtime`,
with executor-owned release). Remaining families move across as their
owners migrate; the archive publication cursor is stage S4.

Create `src/files/io_resource_ledger.zig` and make `io_runtime.Runtime` its
owner. The ledger records which resources remain owned by each job and
supports explicit ownership transfer and release.

### Design requirements

* Keep filesystem resource ownership out of `io_manager.Manager`.
* Runtime decides when teardown is safe; the ledger records what is still
  owned.
* Keep resource-specific destruction in the modules that understand each
  resource. Avoid a generic destructor framework that duplicates their
  knowledge.
* Support registration, transfer, release, per-job release and empty-state
  verification.
* Make cleanup failures observable rather than silently treating failed
  cleanup as successful.
* Resources transferred to an external owner cease to be job-owned. Such
  leases must not prevent job retirement.

### Ownership families to cover

* Discovery root anchors and retained cursors.
* In-flight discovery cursors, which remain worker-owned until completion.
* Operation payloads and continuations, including retained file descriptors.
* Archive cancellation state and staging directories.
* Archive publication cursors and staging ownership across the Runtime/App
  boundary.
* Any other resource family found during the ownership audit.

### Teardown contract

1. Request cancellation and prevent new work from being dispatched.
2. Wait until discovery and operation workers are quiescent for the job.
3. Release resources that remain owned by the job.
4. Verify that the job's ledger contains no outstanding owned resources.
5. Retire the corresponding Manager job.

Never close or free a resource that an in-flight worker may still access.
Preserve explicit handoff semantics for clipboard, drag and Open With staging
leases: once transferred, those resources belong to their receiving owner.

### Validation

* Focused ledger tests for registration, transfer, release, duplicate or
  invalid handles, and empty-state verification.
* Tests for multiple resource families owned by one job.
* Tests proving transferred resources no longer count as job-owned.
* Tests proving teardown cannot release worker-owned resources before
  quiescence.
* Allocation and cleanup-failure coverage where practical.

Migrate resource families incrementally. Do not attempt a wholesale rewrite
of all existing cleanup paths in one change.

## Phase 2 — Remove JobRunner completely

Once the ledger foundation is established, finish migrating the remaining
user-facing transfer functionality to the I/O Manager. There must be no
production transfer fallback to `JobRunner`.

This phase is the prerequisite for service stage S3. Mixed selections are the
first item, since the coordinator rejects them today.

### Remaining migration work

* Inventory every transfer type and entry type accepted by `JobRunner`.
* Add Manager operation support for any missing cases, including mixed
  selections and currently unsupported entry types where the old path
  provides meaningful behaviour.
* Preserve conflict handling, skip/rename/merge behaviour where applicable,
  cancellation, pause/resume and progress semantics.
* Make transfer progress and destination-tree UI consume Manager snapshots
  exclusively.
* Remove the legacy transfer-manifest projection and dual Manager/JobRunner
  UI paths.
* Remove the fallback from `App.executeTransfer`.
* Remove JobRunner construction, destruction, polling, wake-FD handling and
  keyboard/sidebar controls from the App.
* Remove the obsolete JobRunner implementation and tests after equivalent
  Manager coverage exists.

Archive extraction and archive-member extraction already use the Manager;
do not migrate them a second time.

### Completion criteria

* Every supported Files copy/move transfer uses the I/O Manager.
* No production App code constructs, polls or calls `JobRunner`.
* No JobRunner-specific progress or manifest path remains in the transfer UI.
* The old implementation can be deleted without losing supported behaviour.
* Full Files tests and build pass after removal.

## Phase 3 — Deterministic Manager simulation

Build a deterministic simulation harness for the Manager state machine.
The Manager is single-threaded state owned by the coordinator, so its transitions can be exercised
without relying on real worker timing or filesystem scheduling.

The fake executor should provide scripted and seeded-random completions,
including:

* normal completion and yield;
* wait and conflict;
* failure;
* cancellation;
* stale or duplicate completion tokens;
* delayed completion and varied completion ordering.

Generate many job shapes and interleavings. After each transition, assert
invariants such as:

* every operation reaches a valid terminal or explicitly waiting state;
* dependency rules are respected;
* counters match the actual operation states;
* no operation is dispatched twice concurrently;
* pause and cancellation gates are respected;
* every job eventually reaches a valid terminal state when the executor
  supplies all outstanding completions;
* resource-ledger ownership remains consistent with job and executor state.

Use fixed seeds for reproducibility and print the seed and operation history
when a simulation fails.

## Phase 4 — Syscall fault injection

Introduce a thin, testable syscall boundary for filesystem operations where
fault injection materially improves confidence. Keep production calls direct
and lightweight; do not create an abstraction for syscalls that do not need
testing.

Exercise failures and interruptions including:

* `EINTR`, short reads and short writes;
* `ENOSPC` and permission failures;
* open, stat, rename, unlink and directory-finalization failures;
* fsync and publication failures;
* cross-filesystem copy/detach failures;
* rollback and cleanup failures.

Verify both the resulting filesystem state and resource-ledger state after
each injected failure.

## Phase 5 — Filesystem safety and lifecycle hardening

Revalidate the findings from the earlier architecture audit against the
current code before implementing each item. Do not assume an audit finding
remains unfixed without checking.

Candidate areas:

* Discovery cancellation and descriptor cleanup, including in-flight cursors.
* Shutdown cancellation ordering, especially archive extraction and queued
  work.
* Source identity revalidation before detach or deletion.
* Preventing partially copied files from appearing under their final names.
* Preserving directory mode and timestamps after child creation.
* Ownership validation before symlink discard.
* Allocation-failure handling while dispatching, completing and draining
  work.
* Double-close paths, swallowed cleanup errors and stale temporary names.
* Source growth/shrinkage and unsupported special files.
* Bind-mount and directory traversal loops.
* Safety on abnormal exit: partial output never under a final name, and staging
  under a known directory that a later start can sweep. This replaces the need
  for a journal while the service is in-process.
* Blocking metadata calls off the coordinator thread (service stage S5).

Prefer focused regression tests for each confirmed issue.

## Phase 6 — Scheduler and scaling improvements

Measure before changing scheduling policy. Preserve FIFO and priority
semantics while removing avoidable work from hot paths.

Candidate improvements from the audit:

* Replace ready-queue scan/shift behaviour with per-priority FIFO queues and
  head indices if profiling confirms quadratic costs.
* Avoid rescanning an entire tree to find work affected by each completion.
* Retire and free completed jobs when no UI or external owner needs them.
* Improve conflict lookup if its current linear path is measurable.
* Avoid repeated full-tree scans during selected archive-member extraction.
* Review operation unit size and dispatch overhead for workloads containing
  many small files.

Keep bounded concurrency and fairness. Do not assume that more workers
always improve throughput; evaluate independent jobs and independent
operations within one job separately.

## Phase 7 — Production-path benchmarks and calibration

Benchmark the production `io_operation_executor.Runtime` and
`io_manager.Manager`, not a synthetic worker pool.

Provide explicit opt-in build targets such as `bench-files-io` and
`calibrate-files-io`. Normal `zig build` must not run benchmarks.

Cover:

* many small files;
* a few large files;
* deep directory trees;
* mixed files and directories;
* multiple independent jobs;
* multiple independent operations within one job.

Use warmups and repeated runs. Record elapsed time, throughput, operation
counts and failures. Run on the target filesystem; never silently substitute
`/tmp` for the requested calibration location.

Use measurements to choose safe defaults for worker count, queue capacity
and operation unit size. Validate persisted or configured values and retain
a safe fallback.

The existing `bench-files-copy` JobRunner benchmark is legacy and must not
be used as a proxy for production I/O Manager performance. Retire it after
the replacement benchmark is useful.

## Phase 8 — Module boundaries and maintainability

Keep the resource ledger in its own module. Do not make the Manager own
resource cleanup merely to reduce line count.

After the ledger and migration work stabilise, split oversized Manager code
along real responsibilities where this reduces coupling:

* ready queues and scheduler policy;
* conflict queue and resolution;
* discovery scheduling;
* archive publication barriers;
* snapshots and UI-facing projections.

Move tests with the responsibilities they exercise where practical. Preserve
the public API unless a concrete caller benefit justifies changing it.

## Working rules

* Work phases in order, interleaved with the service stages as the table above
  says. The ledger foundation comes first and is in place.
* Keep each implementation unit focused, tested and independently
  reviewable.
* Commit and push after each meaningful unit is completed and verified.
* Do not expand scope without a concrete correctness, maintainability or
  measured performance reason.
* Re-run the relevant focused tests and the full Files suite at integration
  milestones.
* Update this roadmap as phases are completed and newly discovered work is
  added.

## Non-goals

* Keeping `JobRunner` as a permanent compatibility or fallback layer.
* Making the Manager responsible for filesystem resource destruction.
* Introducing a generic resource framework beyond the ownership and teardown
  needs demonstrated by Files.
* Optimising scheduling based only on theoretical complexity without
  measurement.
* Running benchmarks as part of the normal build.
* Building an out-of-process service, wire protocol or journal before a trigger
  in the architecture document is reached.
