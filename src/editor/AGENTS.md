# Text editor

* **Never give Pango more than a few lines.** One layout of 1 MiB took 46 s
  (cost grows faster than the line count). `view.zig` lays out one *segment*
  at a time (`lines.zig`: a logical line, or a piece of one folded at `fold` =
  2 KiB, cut after a nearby space) in a content-keyed cache (`Layouts`), so
  edits need no invalidation. A scrollbar drag lays out a new piece per motion:
  16 KiB pieces stuttered at 16–38 ms, 2 KiB take about 5 ms. Pieces are a function of the line start alone,
  so walking up or down finds the same ones; keep `lines.zig`'s property test
  green when touching it.
* **Scroll is `Document.top` (a byte offset) plus `Tab.dy` pixels into that
  line**, never a pixel count from the file start (that needs every line's
  height). `Document.replace` shifts `top` and the line waypoints
  (`retarget`) so edits above the view don't move it. `Port.clamp` after any
  change; `locate` returns null for a position more than three viewports away,
  so jump (`jumpTo`) instead of walking.
* **Scrollbar units** are pixels (exact) up to `exact_limit` and bytes above
  it, because a drag in progress must not see its units shift as the height
  estimate improves. Line numbers come from sparse waypoints (`linesBefore`).
* **Large saves are written in place** (`Operation.startSave` `borrow`, above
  `copy_limit`) and `Document.locked` refuses edits meanwhile; smaller ones are
  copied. Anything that frees or reallocates the text during a save is a
  use-after-free. Loads read straight into one buffer sized from `fstat`, sniff
  the first 64 KiB for binary data and refuse files that won't fit in
  `MemAvailable` (`ensureMemory`).
* **Benchmark in ReleaseSafe.** Debug makes the vector scans ~50x slower and
  fakes a regression. Editing near the start of a huge file memmoves the tail
  (about 100 ms per keystroke at 2 GB); a gap buffer would fix it, but every
  `text.items` reader (segmenter, find, IME, clipboard) would need to learn it.
* A selected line break is not in the segment layout, so `paintLine` draws the
  highlight out to the margin itself (wrapped mode only, as Pango did).

## Drafts

* **Unsaved text survives closing, crashes and reboots.** `drafts.zig` owns
  the files (`$XDG_STATE_HOME/rediwm/editor-drafts/`: `session.json`, one
  `<name>.txt` per modified tab, `lock`; all 0600 in a 0700 directory, each
  replaced through a synced temporary name, strays swept after every write).
  `app_drafts.zig` decides what and when. A tab is kept when it is modified and
  not an empty untitled one; clean tabs are not restored. A restored tab has
  `doc.saved = null` and the file's `stamp` from before, so saving it still
  trips `FileChanged` if the file moved on.
* **Writes follow `app_drafts.signature`** (tabs, revisions, modified, paths,
  selected tab; not the cursor), debounced 1 s after the last change and at
  most 5 s into continuous typing, on a thread over copied text. No timer runs
  unless a change is unwritten: a tab switch with nothing to keep arms none.
  State that should trigger a write belongs in the signature. A failed write is
  retried after the usual delay, never in a loop.
* **Drafts are for a session that ends some other way.** Closing the window
  or a tab asks to save as usual (Discard deletes the draft). A SIGTERM/SIGHUP/
  SIGINT (they write through the eventfd the writer uses to wake the loop), a
  dying compositor or a crash leaves the drafts, and `deinit` writes last.
  Tabs over `text_limit` (8 MiB; 64 MiB together) are not kept.
* Tests that start the editor need a scratch `XDG_STATE_HOME`, or they restore
  and overwrite the real drafts.

## Tab strip

* Tabs share the strip left of the new-tab button, `tab_max` (176) down to
  `tab_min` (112) wide; beyond that it scrolls by pixels (`tab_scroll`), by
  wheel over the strip. `revealTab` brings the selected tab into view only when
  the selection, the tab count or the width changed, so typing never snaps a
  strip the user scrolled away. Go through `tabX`/`tabAt`/`tabCloseBox`; a tab
  at the edge is partly drawn (the strip is clipped), so hit tests must stay
  inside `tabRight()`. Names are ellipsized; the unsaved dot never is.
