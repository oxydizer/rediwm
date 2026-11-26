# Files I/O worker pools: size, lanes and stalls

**Status:** proposal (S5), for review. Nothing here is implemented yet.
Measurements come from `bench-files-io` (`src/files/io_bench_tests.zig`).

The I/O service started with two workers in every pool, one step on from
JobRunner's single worker. This document asks what the pools should be now: how
many there are, what work shares one, how many workers each has, and what
happens when a worker hangs.

## 1. Where things stand

| Pool | Workers | Runs | Touches |
| --- | --- | --- | --- |
| `io_service_tasks` | 2 | transfer prepares, window requests, staging scans, staging deletes | user paths, and Files' own staging |
| `io_deletion` | 2 | Delete, move to Trash, Empty Trash | user paths |
| discovery executor | 2 | directory walks of transfer sources | user paths |
| operation executor | 2 | copy, move, extract operations | user paths, staging |

All four are fixed-size `io_workers.Pool`s with a bounded queue. Neither executor
limits how many of its workers one job may hold.

## 2. What the measurement found

Three windows on the test's thread; a 512 MiB copy, a copy of 10 000 small
files and an extraction of 5 000 entries running together; a FUSE mount
(bindfs) whose daemon is stopped with SIGSTOP to play a dead network mount.
Sandbox numbers, two CPUs; the user's machine will differ in throughput, not in
what blocks.

**The UI thread is fine in every case.** Service calls cost 3–13 µs per UI
iteration at p50, 40–57 µs at p99, under 0.8 ms at worst. `ServiceBusy` refuses
up to 15 % of fetches, but the longest stretch a window went without a
successful fetch was 16–51 ms, a frame or three. Nothing on the UI side needs
changing.

**Gap 1: the task pool.** Two copies from the dead mount hang both task workers
in their prepare (it stats the sources). From then on nothing else that needs a
task runs, in any window: an extraction elsewhere stayed `waiting` for 30 s (its
staging scan is a task), and no request was answered (Properties, rename, new
folder, the chooser's checks, canonical paths for drops). One stalled prepare
already costs a healthy request up to 0.65 s when the other worker is busy.

**Gap 2: the executors.** One copy whose mount dies *while it runs* holds both
operation workers. For 30 s every other transfer in every window made no
progress: the big copy and the extraction stayed `queued`, the small-file copy
`running` at 0 bytes. Requests were unaffected. This is likely backlog item 2 (a
second, unrelated copy to a USB drive that never progressed).

**Also seen:** an extraction of 5 000 entries in 100 folders ends at
`completed_items` 5 100 of `total_items` 5 000: folders are counted as done but
not in the total. Backlog item, not a pool question.

## 3. What we want

1. **A hung filesystem stalls only work on that filesystem.** Work on other
   filesystems, and the service's own housekeeping, keeps going.
2. **Bounded threads.** A dead mount must not make the process spawn threads
   without limit, nor keep them after it recovers.
3. **Throughput where it helps,** without assuming more workers is faster: two
   copies on one spinning disk are slower than one after the other.
4. **No change to the coordinator's discipline** (threading §8): it still does
   no blocking calls; workers still read no Manager state.

## 4. Proposal

### 4.1 Lanes by what the work touches

* **Service lane** (1 worker): staging scans and staging deletes. Staging lives
  in Files' own private directory, never on a user mount, so this lane cannot be
  stalled by one. Extractions and cleanup no longer queue behind prepares.
* **User-path lanes:** prepares and requests (the task pool as it is, minus the
  staging work), deletion, discovery, operations.

Cheap, independent of the rest, and closes the extraction half of gap 1.

### 4.2 Stall domains

A **stall domain** is the filesystem a task waits on: `st_dev` where it is known
(discovery records it for every entry, so operations have it), otherwise the
mount that contains the path, from a mount table kept current by a watcher of
`/proc/self/mountinfo` (through `src/platform/`). A copy belongs to its source's
and its destination's domains.

A task that has run longer than `stall_after` (about 2 s) without reporting
progress marks its domain **suspect**. While a domain is suspect:

* at most one task per lane runs in it (the stuck one); further tasks for that
  domain wait in their lane's queue, in order, and never take a fresh worker;
* tasks for other domains are unaffected (4.3 gives them workers).

The domain is cleared when its stuck task returns. Cancelling a job whose task is
stuck in a suspect domain shows `cancel_requested` until the task returns, as
today.

### 4.3 Elastic user-path lanes

Each user-path lane has a **target** of runnable workers and a **hard cap** of
threads. A worker stuck past `stall_after` stops counting toward the target, so
the lane may start a replacement while it is under the cap. Extra workers exit
after being idle for a while (about 30 s), down to the target.

With 4.2, a dead mount costs at most one stuck worker per lane, so the cap is
reached only by several dead mounts at once. At the cap, new work waits; nothing
fails.

| Lane | Target | Cap |
| --- | --- | --- |
| tasks (prepares, requests) | 2 | 8 |
| deletion | 2 | 6 |
| discovery | 2 | 6 |
| operations | 2 (calibrated, 4.4) | 8 |
| service | 1 | 1 |

### 4.4 Per-job and per-device limits in the executors

* **Per job:** while more than one job is runnable, one job holds at most
  `target - 1` workers of an executor. A single job still gets them all.
* **Per device:** copies are limited per destination device (and source
  device), so two jobs onto one USB stick run one after the other instead of
  thrashing it. The limit starts at 1 for rotational or USB devices and at the
  lane target otherwise (from `/sys/block/*/queue/rotational` and the transport,
  through `src/platform/`), and is what phase 7 calibrates.

### 4.5 What stays

Bounded queues and their admission errors, the coordinator loop, the job table,
the ledger, and the rule that only the coordinator applies results.

## 5. Order of work

1. Service lane (4.1). Small, independent.
2. Per-job limit in the executors (first half of 4.4). Small; closes gap 2 for
   two jobs on different filesystems as long as the pool target is ≥ 2.
3. Stall detection and suspect domains (4.2), with the mount table.
4. Elastic lanes (4.3).
5. Per-device limits and their calibration (second half of 4.4, phase 7).

`bench-files-io` checks each step: `REDIWM_IO_BENCH_STALL_MODE=prepare` for gap
1, `running` for gap 2. Done when, with a dead mount, every other job finishes
and the probe's round trip stays at its unloaded value.

## 6. Open questions

* `stall_after`: 2 s is a guess. Too short marks a slow USB stick as dead; too
  long keeps healthy work waiting. "No progress" for an operation is no bytes
  moved; for a stat-only task it is simply elapsed time.
* Should requests get a lane of their own (they are small and a person waits on
  each), or is the elastic task lane with suspect domains enough?
* Per-device detection for network and FUSE filesystems, which have no block
  device: one domain per mount, limit as for SSDs?
* Is the deletion pool better folded into the operation executor once it has
  per-device limits?
