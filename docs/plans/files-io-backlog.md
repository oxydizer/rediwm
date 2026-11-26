# Files I/O backlog

Work set aside for later, oldest first. Take items from the top; add new ones at
the bottom. Each says what was seen, what is known and where to start.

## 1. Tabs as drop targets (UI polish)

**Seen:** a folder dragged from the Videos tab onto the tab of a portable drive
(another tab of the same window) does nothing. Expected: it is copied into that
tab's folder.

**Plan:** the compositor draws the tabs, so it does not tell the client today
that a drag is over one. Titlebar tabs protocol v3: while a drag is over a tab,
the compositor routes the drag to the window's surface and says which tab is
under it, and the tab shows as a target. Files drops into that tab's folder
through the same service path as any drop; resting the drag on a tab for about
0.7 s switches to it, so a subfolder can be the target (spring-loading).
Compositor and protocol on a branch of their own from master (titlebar tabs land
independently); Files adapts afterwards.

## 2. A copy into a folder already partly copied does not progress

**Closed (user, 2026-11-26):** the conflict dialog was not shown; fixed with
the removal of JobRunner. Not the executor gap the bench found
(worker-pools §2), which #74 fixed separately. Kept below for the record.

**Seen (nested session, `io/s3b` at a151ff9):** a folder copied once to a USB
drive (4 files there), then copied again into the same place. No Merge prompt
appeared and the job stayed at 0%. A second copy of another folder, with no
conflict, did not progress either. The progress ring shows on the destination
folder.

**Known:**
* `app_transfers_tests.zig` "copying a folder again into the same place asks,
  and Merge finishes it" does the same on one filesystem and passes.
* Fixed since: a hovered file not yet ready stalled every job (`a151ff9`).
  The run above may predate it; check first.
* Differences from the test: a cross-filesystem destination (USB drive), two
  windows, jobs from earlier in the session, hovering.

* Later run: clicking the Transfers panel showed the conflict dialog for a
  moment, again on every click. So the dialog does open; something closes it
  at once. A click outside a conflict dialog used to answer Cancel; it no
  longer does (`app_pointer.zig`). Every close of a service conflict dialog is
  now logged (`Files conflict dialog N closed`, `Files closes conflict N: no
  job waits on it any more`, `Files answers conflict N: ...`).

* **Cause of the closing dialog found and fixed in S3b.** The user's log showed
  "shows conflict 1" then "conflict dialog 1 closed" on every click, with no
  answer in between. The JobRunner poll in `App.sync` closed any conflict
  dialog unless the runner itself was waiting on a conflict; the runner was
  idle, so every tick after the dialog opened closed it. The poll went with
  JobRunner. Check again whether the job progresses once Merge can be
  answered: the 0% may simply have been the job waiting on its conflict.

**Start:** run with `2>&1 | tee files.log` and read the `Files job N waits on
conflict M`, `Files window asks about conflict M` and `Files shows conflict`
lines. No "waits" line: the coordinator never saw a conflict (look at the
Manager and the job's state). "Waits" without "asks": the window never asked.
"Asks" without "shows": the request or reply went missing.

## 3. An extraction counts more items done than it has

**Seen (`bench-files-io`, `io/s5`):** extracting a zip of 5 000 entries in 100
folders ends with `completed_items` 5 100 and `total_items` 5 000.

**Known:** the 100 extra are the folders: they are counted when created but not
in the planned total. A progress bar clamps, so nothing shows wrong today, but an
"n of m" label would. Start from where the extraction's operations report items
(`io_coordinator_archives.zig`, the archive operation in the operation executor).
