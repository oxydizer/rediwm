# Text editor

* **Never give Pango more than a few lines.** One layout of 1 MiB took 46 s
  (cost grows faster than the line count). `view.zig` lays out one *segment*
  at a time (`lines.zig`: a logical line, or a piece of one folded at `fold` =
  16 KiB, cut after a nearby space) in a content-keyed cache (`Layouts`), so
  edits need no invalidation. Pieces are a function of the line start alone,
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
