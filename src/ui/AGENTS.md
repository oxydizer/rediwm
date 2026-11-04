# Shared widget internals

The rules every caller follows (callback owners, one look per control, app
text and colours, secrets) are in the root `AGENTS.md` ("Shared UI").

* **The scrollbar** (`widgets/scrollbar.zig`, Files' look): a thumb (track-less
  unless `scrollbar_track_relief` cuts a groove; flat at `scrollbar_glow = 0`)
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
  Hover fades in a pale reflection of `border_glow` along the thumb's edge;
  dragging and the scroll hold brighten it. `Appearance.illumination` shares
  the existing frame/deadline scheduling (no idle animation). Cairo uses the
  shared raster for the lit thumb, preserving its fractional device position.
* **Text fields with child accessories** reserve text/caret room with
  `field.trailing = .accessory`. Place a shared button in the field's children
  (Settings search uses a ghost clear button), so normal pointer and keyboard
  dispatch handles it inside the field frame.
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
* **Switches slide** (`widgets/toggle.zig`): `ToggleData.knob` eases the
  knob (and the track's off/on colour) over `slide_ms`, and `paint` takes the
  position (`Options.position`; null rests at `on`, which hand-laid panels such
  as the network popup still use). `scroll_container.stepBars` calls
  `toggle.step`, which retargets when `on` changed, repaints only on a changed
  position and snaps when animations are off or reduced; a switch no frame has
  seen starts at rest. A page rebuild that follows a click happens before the
  first frame moves the knob, so `ControlCenter.rebuildTree` carries named
  switches' knobs across with `toggle.capture`/`restore` (by name hash: arena
  names don't outlive the rebuild). A host that builds `.toggle` widgets must
  call `stepBars` or its switches never leave their first position.
* **Dropdowns survive unrelated page updates.** On a rebuild of the same page,
  use `select.capture`/`restore` and restore input focus to the returned widget.
  The saved state owns its bounded name copy: the old tree's arena can be freed.
  Changed options, disabled choices, owner/id, or backend selection invalidate
  the saved menu; restoration never replaces the new backend value. Settings
  does this beside its slider and switch capture, so a live Services update
  cannot discard an in-progress Notify choice.
* **The battery badge** (`widgets/battery.zig`: frame, glyph, percentage,
  charging bolt) is the taskbar's artwork. `sample` is the pixel math (per
  device pixel, badge-local units); the taskbar's per-pixel raster calls it and
  `paint` draws it into any `Renderer`, so the two cannot drift. The caller
  owns the data (hide it when there is no battery) and the connection
  shimmer's clock (`Spec.shimmer`).
* **Relief on hand-shaded controls.** A control drawn through `fillRect` opts in
  with `RectStyle.relief` and a theme key. One that lights its own pixels (the
  shaded toggle and slider) paints first, then calls `Renderer.paintShapeRelief`
  with `ReliefLimits`: a groove passes `.outside` (the knob), a knob passes
  `.within` (its track or the control's box), so shadows never cross the thumb
  or leave the damage bounds. `Renderer.reliefActive` tells it whether to drop
  the hand-made rim or cast shadow the relief replaces; flat keys must leave
  its pixels byte-identical.
