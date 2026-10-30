# Rendering implementation notes

Read when changing projection, the output pass, glass, window shapes,
chrome, capture, or retained panel painting. General rules remain in
[AGENTS.md](../../AGENTS.md); test commands are in [TESTING.md](../../TESTING.md).

* **Colours are premultiplied** in wlroots rects; theme colours are
  `col.Straight`. Create/recolour rects only via `col.createRect`/`setRect`,
  pack pixels with `Straight.argb()`/`Premul.argb()`. Symptom of a mix-up:
  white border edges.
* **Window frames are shapes** (`docs/plans/scene-graph-stage4.md`).
  `Toplevel.applyShape` gives `frame_tree` one rounded clip carrying the ring
  colour (× window opacity); the pass composites the ring over the body, so
  something must be drawn under every ring pixel: the titlebar `ChromeBuffer`
  (a plain band) on top and the three `frame_fills` rects beside and below the
  client. The footer is `frame_border`. `shadow_tree`, the resize-grab tree and
  every xdg popup carry `setTreeUnclipped` (a new node that hangs outside the
  window needs it too). The shadow is analytic (`setTreeShadow` on
  `shadow_tree`, the CPU formula's smoothstep); its leaf `shadow_node` has no
  buffer and carries footprint, opacity and input only, so the projection
  damages that footprint itself. CSD windows have no shape and keep the
  `border_rects` outline. A theme's `window_shape` makes the clip a polygon
  (`ui/window_shape.zig`, anchored points resolved against the live frame in
  `Toplevel.shapePolygon`): `radii` is then unused, `rediwm_clip.inset` is how
  far in the largest rectangle wholly inside it lies (the opaque cover, the
  plain core and the damage rim all use it), and the shader's `sdpoly` walks
  the same edges as `rediwm_sd_polygon`; keep the two, and `window_shape.sdPolygon`,
  in step. Anything that mirrors `rediwm_pass_shape` in Zig must mirror it whole.
  The polygon distance is compiled only into two extra programs (`POLY`,
  `shaped_poly[_external]`, `rediwm_scene_renderer_enable_polygons`), built on the
  first `chrome.polygonsReady()` from layout code (never inside a pass); a polygon
  draw before that fails the pass, so draw and capture code reads `chrome.polygons`.
  The taskbar uses the same clip on its tree (`Taskbar.applyClip`) with its raster
  outer edge left hard (`taskbar/shape.zig` `paintPolygon`: row spans, a distance
  only near an edge).
  A changed clip damages its rim itself
  (`projection_resolve.c`); a point the shape cuts away is declined by the pick
  (`pick_world`), so the pick falls to what is below. Window capture draws the client alone and is
  handed the shape explicitly. The ring is one `max(1, round(border * scale))`.
  Without the shaped programs (`chrome.shapes` false) windows are square, with
  no ring or shadow.
* **Buffer size ≠ scene size** at fractional scale (`round(len*s)` vs
  `round((off+len)*s)-round(off*s)`). Chrome/panel buffers filter bilinearly:
  never re-raster per device-grid phase (`ChromeBuffer.create` costs 2–8 ms).
* **Nested sessions never set buffer scale:** judge sharpness at
  `REDIWM_SCALE=1`, and debug visuals with IPC screenshots/buffer dumps, not
  host `grim`. Brief vanishing after a startup scale mismatch is not a bug.
* **GLES can NULL `wlr_scene_buffer.buffer`** after upload (the texture
  stays): persist raster sizes.
* **Owned buffer destructors call `base.finish()` before freeing or pooling.**
  wlroots 0.20 delegates the destroy event and addon cleanup to the producer.
  Skipping it leaves consumers attached to freed storage (or the old incarnation
  of a pooled buffer). This applies to chrome, images, taskbar, panels and desktop
  tiles; `zig build test-lifecycle` checks finalization after the last lock.
* **Glass is drawn by the output pass** (stage 5, `docs/plans/scene-graph-stage5.md`).
  `glass.c` only registers effects: a bufferless node just below its target, to
  which resolve gives the target's box. When an effect re-blurs, `scene_output_draw.c`
  redirects the pass (`rediwm_scene_pass_begin_backdrop`) and draws the items
  below it into an image a quarter of the logical size of its padded extent
  (target + 3 sigma), blurs that and composites it through the shape (shaped
  program mode 3), keeping one blur per effect and output. A kept blur is
  re-taken only when a damage event from a leaf painted *below* the effect, or
  damage no event explains, meets that extent, or the region or sigma changed.
  Only leaves that put pixels on screen have damage events (an input-only node
  must not, or it reads as a change below glass), and the software cursor's
  damage counts as explained. Damage a new kind of change through the
  projection's events or it counts as below (safe, slower). Collect keeps items an
  effect reads even where surfaces above hide them (`reads`). Holds (a dragged
  titlebar at ≥ 0.98 opacity, camera motion) carry the blur and re-take it once
  released. Per output, so mixed scales stay idle (`glass_hold.py`); attribution
  is checked by `glass_reblur.py`.
* **Owned GL beside wlroots:** wlroots draws with client-side vertex arrays, so
  any GL work of ours must put `GL_ARRAY_BUFFER` (and the rest of the state it
  touched) back before a wlroots pass runs, as `scene_pass_leave()` does; a quad
  VBO left bound makes wlroots draw half a rectangle. A border is drawn in the
  same pass as its body, never over it (`docs/plans/scene-graph-stage1.md`).
* **Commit only via `Output.commitFrameState`**, never
  `wlr_output_commit_state`. `commitIsRedundant` skips commits with no damage,
  colour change, attach-render lock or cursor change; register anything new
  there. Skipped frames get callbacks from `vblank_timer`, never immediately.
  A client commit with nothing new (no attach, no damage, no remap) changes no
  node and schedules no frame: its callbacks go through the scene's
  `frame_callbacks` hook (`Output.frameCallbacksWanted`), which arms the timer
  at idle unless a frame is coming anyway. Keep it that way: a setter or listener
  that reports a change on every commit brings back a whole frame per commit.
  Build output state through `Server.buildOutputState`, including capture: the
  owned GLES2 pass is the only presenter (the session requires GLES2) and keeps
  one swapchain damage history. It reads graph geometry and the buffers,
  textures and wait points of the source nodes
  (`docs/plans/scene-graph-stage3.md`, `scene-graph-stage6.md`).
* **Shapes in the owned pass** (`scene_pass.h`): a window's rounded clip, ring
  and shadow are `rediwm_scene_pass_add_*_shaped` calls, device pixels, snapped by
  the caller. The programs cost the driver about 430 KiB (a GL program costs
  130-150 KiB whatever its size), so `enable_shapes` builds them on request, never
  with the renderer; before it a shaped draw fails the pass. Blend NONE is only
  valid inside `rediwm_clip_opaque`, minus the ring (`scene_output_draw.c` draws a
  clipped item's ring-free core plain and the rest through the shape). The
  distance ramp is not area coverage (up to 18 of 208 levels at one pixel of a
  curved edge): that is expected.
* **Idle makes no wakeups:** timers only for real deadlines, workers signal an
  eventfd, `text.applySize` instead of re-sizing faces, title changes repaint
  only their span and taskbar chip. Measure with per-thread context switches.
* **Damage:** each reusable shm buffer tracks damage since its own last paint;
  never write a busy one. `panel_paint.Background` keeps the last full image
  (`paintIncremental` repairs; a buffer from `PanelBuffer.createRetained`
  carries a stamp, so only what it missed is copied in, and only the damage
  back out — pass null when drawing over the retained image); widget setters `markDirty`/`markPaintDirty`,
  moves damage old and new bounds; convert publish damage at the real raster
  scale. Compositor-owned world buffers send full damage unless reported
  (`Projection.damageBuffer` after `setBuffer`, or `presentOwned`). Cache keys
  include visual state, text, geometry and Cairo transform; round globally
  before subtracting projection group origins.
* **Projection is resolve, then present** (`projection_resolve.c`,
  `projection_present.c`, `scene_graph.h`; `projection.c` has the overview).
  `resolve` turns the source tree into typed items (kind, unrounded
  layout-space edges, composed scale, content) listed in paint order per group
  and shows nothing; `present` rounds once (`rediwm_edges_snap`, edges not
  origin+size) and turns what changed into damage events and screen damage.
  Geometry is derived only in `resolve`: a new rule (clip, opacity, fractional
  placement) is a field on the item, not a computation in `present_leaf`. A leaf
  or group leaves its `paint` list before the head is freed (`detach`,
  `destroy_group`). Buffer identity and damage are read from the source node by
  `present`, textures, single-pixel colours, wait points and opaque regions by
  the pass. A tree's rounded clip (`rediwm_projection_set_tree_clip`) is a field
  on each item (`item.clip`), resolved after the tree's own zoom and scale; an
  xdg popup lives under its parent's tree and must carry
  `rediwm_projection_set_tree_unclipped`.
* **The world has no second tree** (`docs/plans/scene-graph-stage6.md`). The
  source tree is disabled, so wlroots computes no outputs, frame callbacks,
  damage or picks for it; the graph does, with wlroots' own rules on our data.
  *Feedback* (`rediwm_projection_feedback_*`, called by the pass's `collect`):
  per build, the pixels of each client surface that nothing above hides, over
  every output; an output is active when it shows more than a tenth of that, the
  primary one shows most (the later wins a tie); `outputs_update` and
  `output_enter/leave` go out on the *source* buffer, again when an active
  output's scale, transform or subpixel changed. Frame callbacks of the world
  come from `Server.sendFrameDone`, never `wlr_scene_output_send_frame_done`
  alone; the pass emits `output_sample` on the source buffer. A layer-shell
  surface below the world (background, bottom) is no longer occluded by windows
  in wlroots' eyes: it keeps frame callbacks while covered. *Damage*: every
  change reaches `p->pending` through `damage_box` and goes to the outputs once,
  at the end of each sync. A change of what a leaf itself shows is cut to what
  was visible of it at the last build (`l->visible`); a move, restyle or removal
  damages the old box (cut) and the new one; a restack damages what moved
  (`damage_restacked`), shadow footprints included; a destroyed node applies at
  once, because a capture can build before the next sync. A new kind of change
  that moves no leaf has to damage itself there (clip rims and shadows do).
  *Picks*: `rediwm_projection_node_at` (graph for the world, wlroots for the
  layout trees), never `wlr_scene_node_at` on the root. GLES2 lets go of a
  plain buffer once uploaded, so "has content" is a buffer, a texture or a
  single-pixel colour (`present_leaf`, `collect`).
* **The veil** (`rediwm_scene_output_set_veil`, driven by `reveal.zig`) is
  black drawn over every entry and under the software cursor: the session's
  fade in from black and the greeter's fade out. It exists only on DRM and
  nested outputs. A change damages the whole output and counts as explained
  damage, so glass does not re-blur for it; scan-out waits until it is 0.
* **Client buffers:** `wlr_client_buffer_apply_damage` works in place only
  without extra locks, so mark long-held locks ignorable. v4
  `attach(buffer, 0, 0)` still sets OFFSET; only nonzero dx/dy remaps. Don't
  resend unchanged `set_buffer_scale`; prefer compositor v5.
