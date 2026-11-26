# Files I/O: copy performance

The copy path's own costs, apart from scheduling and pools
(`files-io-worker-pools.md`). Started from findings of an investigation done
before the I/O service work (with another assistant, on the JobRunner code),
checked against the current code on 2026-11-26.

Four performance dimensions, measured separately: large-file throughput,
small-file throughput, bounded memory, UI responsiveness. A change to one is
measured against all four with `bench-files-io` (see its settings at the top of
`src/files/io_bench_tests.zig`).

## 1. Findings carried over

* **64 KiB is a sound buffered baseline.** Bigger buffers helped large files a
  little (256 KiB best in some runs, 1 MiB the same); mixed work barely.
* **Adaptive buffer candidates:** up to 64 KiB → 16 KiB; to 1 MiB → 64 KiB; to
  64 MiB → 256 KiB; above → 1 MiB, capped at the file size.
* **Small files are bound by per-file overhead, not the copy.** 2 048 files of
  4 KiB: buffered 56.65 MiB/s, `copy_file_range` 56.25 MiB/s. About 20 600 path
  allocations (1.57 MB) per run; traversal, path handling, metadata lookups and
  opens, manifest updates, mutexes, progress and repeated traversal per file.

## 2. Where the current code stands

* **Buffers:** the adaptive sizes above are what `io_copy.bufferedBufferSize`
  uses. The buffer lives in the operation's continuation, allocated per file on
  the heap and freed with it; the old 1 MiB stack buffer is gone. Not done: one
  buffer per job, reused across its files (small next to the rest).
* **Bounded work and fairness:** in place (S1–S5 and the worker-pool steps).
  The coordinator does no filesystem work (`io_thread_guard`); 16 commands per
  pass; progress written at most every 50 ms per job; jobs round-robin, at most
  2 operations per job; discovery in batches of 64; bounded queues and pools
  with stall handling. UI cost under load: 3–13 µs per pass at p50, under 1 ms
  at worst.
* **Per-file syncs (new finding):** every new file was synced three times (the
  file, its folder, the folder again after the rename that publishes it). That,
  not the buffer, was most of the small-file cost.

## 3. Done

* **Sync once per copy job** (user's choice, 2026-11-26). A copy job defers its
  syncs (`Manager.setDeferredSync`): new files are written and published without
  `fsync`; the job's finalizer (now present in every copy job, folders or not)
  syncs the destination's filesystem once (`syncfs`, `platform.fs.syncFilesystem`)
  before the job completes. A replacement (overwriting a file) still syncs per
  file, so an overwrite never leaves a broken file; a move keeps per-file syncs,
  since its source is removed right after. A sync failure fails the job.
  Measured in the sandbox, 10 000 files of 4 KiB beside a 512 MiB copy and an
  extraction: 6.4–12.4 s before, 3.2–4.9 s after.
* Found on the way: a finalizer that existed when its job was queued went into
  the ready queue at once, so it could run before the copies. It is now queued
  only once everything else is done.

## 4. Next

1. **Measure on real disks** (the user's NVMe, SATA SSD and USB hard disk): the
   bench with the folder on each, before and after the sync change.
2. **Per-file round trips.** A file is several units, each a round trip between
   a worker and the coordinator (open, copy, flush/publish). Count them per file
   (`profile_enabled` metrics) and merge what can be merged.
3. **Bounded units by size and time, not one 64 KiB chunk.** A large file now
   takes one round trip per 64 KiB (8 192 for 512 MiB). Let a unit copy until
   ~1 MiB or ~10 ms, whichever comes first, still yielding for fairness,
   cancellation and progress.
4. **One reusable buffer per job** for the buffered fallback: allocated when
   first needed, grown to the largest file's size class, capped at 1 MiB,
   released with the job; keep a fixed-64 KiB mode for comparison.
   `copy_file_range` and reflink paths unchanged.
5. **Per-file allocations** in discovery and planning (path joins per entry),
   against the 20 600 allocations measured before.
