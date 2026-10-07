# Shared widget internals

The rules every caller follows (callback owners, one look per control, app
text and colours, secrets) are in the root `AGENTS.md` ("Shared UI").

* **The scrollbar** (`widgets/scrollbar.zig`, Files' look): a track-less thumb
  centred in a `gutter(scrollbar_width)` strip, thin at rest, widening and
  tinting to the accent on hover/drag, holding a faint tint after a scroll.
  `Geometry.compute` gives the thumb for any axis and unit (pixels, or items
  for a strip that scrolls by item), `press` the grab-or-page decision, `Drag`
  the pointer-to-offset map, `look` + `paint` (Renderer) /
  `cairo.drawScrollbar` (Cairo) the pixels, and `Appearance.step` the
  feedback. It is edge-triggered on what is drawn: the app's loop sleeps until
  `deadline` and runs frames only while `active` (`barTimeout` in PDF/Editor,
  `animationTimeout` in Images, `pollTimeout` in Files). Paint-only popups pass
  `.{}` for the rest look. The gutter belongs to the bar: layouts keep content
  out of it and a press in it never reaches content. Never change
  `Appearance.width` per call site: it is every bar's width.
* **Scroll containers** (`.scroll_container`) give widget trees all of the
  above: hosts call `scroll_container.stepBars` beside `stepGlides` and carry
  `ScrollState.bar` across rebuilds. It scrolls along its `direction`, which
  defaults to `.row` (sideways, bar along the bottom edge), so set it
  explicitly. Rebuilt trees carry the offset over themselves (the wallpaper
  strip copies it from its old widget). Appearance's wallpaper strip owns a
  `wallpaper_strip.Strip` (decode worker + eventfd) that outlives rebuilds and
  restarts only when the image list changes; thumbnail slices stay valid until
  then.
* **Sliders reuse the scrollbar's feedback** (`SliderData.feel` is a
  `scrollbar.Appearance`): hover and drag tint and thicken the track, a change
  holds the faint tint. `stepBars` steps sliders too (`slider.stepFeedback`);
  `Dispatcher.setHovered`/`pointerLeave` keep `hovered` in step. A value
  readout is `slider.valuePill` (a `.text` with `pill`), found from its slider
  by `findPill` (first pill under the slider's parent) and lit by drag only.
  Saving a theme slider rebuilds Settings the moment the button is released,
  so `panel.rebuildTree` carries named sliders' state across on the same page
  (`slider.capture`/`restore` + `input.adoptHover`); an unnamed slider starts
  fresh.
* **The battery badge** (`widgets/battery.zig`: frame, glyph, percentage,
  charging bolt) is the taskbar's artwork. `sample` is the pixel math (per
  device pixel, badge-local units); the taskbar's per-pixel raster calls it and
  `paint` draws it into any `Renderer`, so the two cannot drift. The caller
  owns the data (hide it when there is no battery) and the connection
  shimmer's clock (`Spec.shimmer`).
