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

* **Fewer round trips per file** (PR #83). A unit is a round trip between a
  worker and the coordinator. A small file took two (open and copy, then
  flush); in a copy job that syncs at its end it now takes one, since
  publishing is a rename without a sync. Replacements and moves still flush
  in a unit of their own.
* **Units bounded by size and time.** A unit copies 64 KiB chunks until 1 MiB
  or 2 ms, whichever comes first, instead of one chunk: a 256 MiB file went
  from 4 097 units to under a thousand. Jobs take turns by unit, so the time bound
  is what keeps the share fair: at 10 ms an extraction beside the copies ran
  about 20 % slower; at 2 ms it ran as before. Medians of four sandbox runs,
  base → this change: large copies 3.65 → 3.0 s, small files 4.9 → 4.3 s,
  extraction 6.9 → 7.1 s (within noise).

* **Measured on the user's disks** (2026-11-26, before #82 → after #83).
  SATA SSD (home, btrfs): small files 104.6 → 3.1 s, extraction 57.1 → 48.5 s, large
  copies 0.02 → 0.62 s (reflinks either way; the 0.62 s is the job's one
  `syncfs`, which also waits for the other jobs' writes on that filesystem).
  USB hard disk: large 53.2 → 36.5 s, small 74.0 → 45.3 s, extraction
  63.7 → 51.5 s. UI cost per frame unchanged, under 0.11 ms.
* **Extraction, folders and links sync once too** (PR #84). An extraction
  publishes its staged entries as copies, which were not in a deferred job,
  so every entry was synced three times: about 10 ms an entry on btrfs. An
  extraction job now defers its syncs like a copy job; and in any deferred
  job a new folder or symlink no longer syncs its parent
  (`io_directory`/`io_symlink.makeDeferredInput`). Sandbox: extraction
  6.9 → about 4 s. On the user's disks, before → after #84: extraction on
  the NVMe 80.3 → 0.95 s, on the SATA SSD 48.0 → 0.88 s, on the USB hard
  disk 54.9 → 14.2 s; the copies beside it gained too (USB small files
  48.6 → 20.7 s), since the extraction's syncs no longer held the disk.

* **One buffer per worker thread** (PR #91). The read/write fallback (used
  when `copy_file_range` refuses: between filesystem types, so a btrfs to
  exFAT/NTFS USB copy among others) allocated a buffer per file, carried in
  its continuation and freed with it. A unit reads and writes within itself,
  so the buffer now belongs to the worker thread (`io_copy.threadBuffer`):
  grown to the largest size class asked for, at most 1 MiB, freed when the
  thread leaves (`PoolWorkItem.threadExit`). Continuations are the 36-byte
  header alone. Measured with `bench-files-copy` (new: `io_copy.execute`
  alone, tmpfs to ext4, best of 3): 400 files of 1 MiB copy in 0.21–0.33 s
  instead of 0.38–0.58 s, their read/write time 160–175 ms instead of 421 ms;
  10 000 files of 4 KiB and 2 of 256 MiB unchanged. A 1 MiB buffer for every
  file was no faster than the size classes, which stay (less memory per
  thread).
* **Per-file allocations: not worth changing.** A 4 KiB file costs about
  174 µs on this path, 6 µs of it reading and writing; the rest is about a
  dozen metadata calls (opens, the staging file, the publishing rename,
  times). The few small allocations per file are well under 1 % of that.

## 4. Next

1. **USB hard disk:** it was on a USB 2.0 port (in the keyboard). On USB 3
   (5 Gbit/s, `usb-storage`, no UAS): large copies 12.1 s, small files 12.1 s,
   extraction 8.3 s, against 25.3, 20.7 and 14.2 s on USB 2.0. About
   100 MB/s of mixed traffic on one hard disk: likely the disk now. A plain
   `cp` and `sync` of the same files would confirm it.
2. **Fair turns by time, not by unit**, if the bound above proves too tight on
   real disks: let the round-robin account for a job's worker time.
3. **Per-file metadata calls**, if small files on real disks still need it:
   the parent folder is opened by path for every file, and a clone and a
   `copy_file_range` are tried on every file even after they failed for the
   same pair of filesystems. Each is a call or two per file; measure first.
