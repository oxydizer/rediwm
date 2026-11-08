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

## Line glide

* **Edits that move lines glide instead of snapping** (`reflow.zig`): Enter
  pushes the lines below down and carries the rest of its line onto a new one,
  Backspace/Delete/undo joining or removing lines pulls them up, and a word
  that now wraps shifts what follows. Layout, hit tests and the scrollbar
  never see it: rows stay at rest and `paintLine` only gets an `Offset`
  (`dx`, `dy`, `alpha`) for the row that starts at one byte offset. Plain
  typing and cursor movement produce no offsets, so they cost one loop over
  the visible rows.
* **The edit span, not a diff, finds the same line again.** `Document.replace`
  merges every edit since `takeChange` into `Change` (`lo`, `suffix`, lengths):
  a row starting before `lo` keeps its start, a row at or after `hi()` started
  `new_len - old_len` bytes earlier. `stepReflow` runs before `stepCaret` in
  each loop pass, takes the change and plans; `render` ends with `remember`,
  which stores the visible rows at *rest*. Where a row was drawn is its rest
  place plus the move still in flight at `now`, so an edit during a glide
  continues from the screen, not from the old target.
* **All or nothing.** A line the edit made that has text (paste), a vertical
  move over `max_glide` (120 px, the caret's jump rule), another tab, rebuilt
  layouts (resize, font, wrap), a change the remembered rows don't describe,
  or `caret_motion_ms = 0`/reduced motion snap every row. Lines that are
  empty (Enter at a line's end or start) are fine. The rest of a split line
  starts where the text before the break ends and fades in, so it doesn't
  overprint the line above while it crosses it.
* **The caret rides its line** (`Caret.Shift`): its box is the rest position
  plus the offset of the row holding the cursor, solid while any line moves,
  so the two never drift apart; a join leaves the cursor's row at rest and
  the caret snaps as before.
* **Frames are paced by the display.** The duration is 1.5 x `caret_motion_ms`
  (one setting for both). `reflow_dirty` asks for a full repaint (damage is
  not just the caret) and, unlike `caret_dirty`, waits for the frame callback;
  one last frame is drawn at rest when it ends. Nothing runs when idle.
  `tests/editor_visuals.py` samples a frame mid-glide (screenshots show the
  frame at request time, so sample ~100 ms after the key); unit tests are in
  `reflow.zig`.

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

## Open Recent

* **The history is Files' (`files/recent.zig`, `recently-used.xbel`), not an
  editor file.** `app_recent.zig` rereads it each time the menu opens (text
  files that still exist, newest 10) and `recordRecent` adds to it after a
  load or save, on a short-lived thread (it rewrites the whole file, which
  GLib loads and saves). GLib drops a bookmark with no application entry, so
  tests that seed the file need one. The editor links glib for this.
* **The submenu is drawn by the editor beside the menu** (`menu_selected` stays
  on the Open Recent row, `sub_selected` is its own highlight; keyboard focus is
  in the submenu whenever `sub_selected` is set). It overlaps the menu's edge so
  the pointer never crosses a gap. Menu rows are indexed by `Action`: the test
  helper `menu_action` in `tests/editor.py` mirrors the row and separator order.
