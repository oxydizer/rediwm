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

**Start:** run with `2>&1 | tee files.log` and read the `Files job N waits on
conflict M`, `Files window asks about conflict M` and `Files shows conflict`
lines. No "waits" line: the coordinator never saw a conflict (look at the
Manager and the job's state). "Waits" without "asks": the window never asked.
"Asks" without "shows": the request or reply went missing.
