# Plan: scrolling layout

Decisions accepted 2026-11-26. Stages 0–3 provide horizontal keyboard scrolling
on multiple displays. Each workspace's windows, popups and surface feedback
follow its assigned output. Stage 4 adds per-display scroll direction: a
strip runs up and down on a portrait display. Stage 5 adds gestures and
dragging, and stage 6 the strip overview, the position bar and gliding
columns. All stages are done.

## Goal

A third desktop mode beside Canvas and Workspaces. Windows tile into columns on
an endless strip, each display shows a stretch of it, and focus moves along the
strip with the view following, as in niri, PaperWM and Hyprland 0.54's
scrolling layout. The strip scrolls sideways (columns) or up and down (rows).
The direction can be chosen per display and defaults to automatic. Nothing
overflows: a new window adds a column and leaves the others at their size.

## Can it reuse the canvas?

It can reuse the canvas pan, but not the canvas camera.

The canvas camera (`World.camera`; `camera.zig`: layout = O + zoom·(world − O
− C)) is one transform shared by every display, so a pan moves all monitors at
once. Each workspace needs its own offset. The canvas is not endless either: it
is a grid (`canvas_columns` × `canvas_rows`) that grows to keep windows
reachable (`world/camera.zig` `derivedBounds`).

Workspace mode pins that camera. `applyCamera` forces identity, and
`springPan`, `beginPan` and `panBy` return early. Much of the mode depends on
world = layout: tiles come from `usableBox`, `auto_tiling.dropAt` goes through
`Output.atLayout`, and the workspace slide and picks both
assume it. Keeping that invariant is what makes scrolling cheap, because it then
inherits everything tiling already has:

* per-display workspaces and focus memory, and ext-workspace-v1;
* `layout_undo` transactions and restart restore;
* Super-drag insertion with a preview;
* tab groups as one tile, and client size limits;
* glides;
* Settings and typed IPC.

What the canvas contributes is its feel and the code behind it:

* gesture routing: the two-finger pan over empty space (`input/axis.zig`),
  compositor swipes (`input/gestures.zig`), and Super and middle-button pan
  sessions (`input/pan.zig`);
* `camera.rubberBand` and the raw-then-rubber accumulation of
  `applyMotionRubber`, used along one axis;
* the `camera_pan` and `camera_reveal` curves, `VelocityTracker`, and
  `Anim.retargetWith`, so a release keeps its speed;
* the threshold in `camera.focusOffset` (35% shown counts as visible), for
  reveals;
* `holdingGlass`, which holds backdrops while the view moves.

## Where it lives

Scrolling is a workspace layout, offered as a desktop mode.

* `desktop_mode = "scrolling"` turns on the workspace machinery, as
  `workspaces` does, with scrolling as the default layout of every workspace.
  Switching between Workspaces and Scrolling stays inside workspace mode. It
  takes no canvas snapshot; it only reflows. `workspaces.setMode(bool)` becomes
  `setMode(DesktopMode)`.
* `Workspace.automatic: bool` becomes `layout: enum { floating, split,
  scrolling }`. This is the per-workspace layout choice that `tiling-gaps.md`
  item 3 already proposes. The mode is the global default, and any workspace
  can override it in Settings → Desktop. The override replaces today's
  "Automatic tiling / Floating" select, and is kept across mode switches and
  sessions.
* **Switching modes remembers the last layout.** `toggle_desktop_mode` returns
  to the tiled mode last used, and that mode comes back as it was left: the
  per-workspace layouts, split trees, columns with their widths, and each
  workspace's view. Today that only survives a restart, not a trip to Canvas
  and back (fix 7).
* **Floating windows** on a scrolling workspace stay put while the strip
  scrolls, and are always stacked above it, like niri's floating layer
  (fix 8). The one exception is a dialog with an owner on the strip: it moves
  with its owner, so it never ends up over an unrelated column.

## Layout model

A pure module, `scroll_layout.zig`, sits beside `auto_layout.zig` and shares its
`Member`, `Key` and `Box`. Its tests go in `scroll_layout_tests.zig`.

* **Strip:** an ordered list of columns, one strip per workspace. A column
  holds one or more members stacked across the strip, plus a width and
  per-member weights for the cross split. A tab group is one member, as in the
  split tree.
* **Axes:** the module works in main and cross coordinates, and the bridge maps
  them from the direction of the display showing the workspace. In the
  horizontal direction, columns sit side by side and scroll left and right. In
  the vertical direction, full-width rows are stacked, windows within a row
  sit side by side, and the strip scrolls up and down.
* **Width:** stored as a fraction of the viewport, so it survives a change of
  resolution, display or direction.
  * By default it comes from presets (⅓, ½, ⅔ and 1; new columns get ½).
  * Manual resizing is optional: a keyboard step or a drag sets any fraction
    (see Input). Cycling the width snaps back to the next preset above the
    current width.
  * A column widens to its largest member minimum. A member whose maximum is
    smaller is centred in its column.
  * Heights within a column are weights, also resizable by keyboard or drag.
* **Insertion:** a new window opens as a column of its own, right after the
  focused one, so nothing else resizes. It uses `Toplevel.auto_anchor`, as
  splitting does. A window moved to another workspace joins beside that
  workspace's focused window, as today.
* **Suspended members** (minimized, maximized or fullscreen) keep their place
  and take no width. When restored, they come back where they were.
* **No overflow:** the main axis is unbounded, so nothing floats for lack of
  space. If the members of a column cannot all fit across it, the newest one
  moves into a column of its own.
* **View:** each workspace keeps its own `view`, the strip coordinate at the
  viewport's leading edge, independent of other workspaces and displays. A
  member's layout rectangle is `usable.origin + strip_rect − view`.
  * The view is kept while the workspace is hidden, so switching back shows the
    strip where it was left.
  * When the viewport changes (another display, a new resolution, or a new
    direction), the view scales with the strip's length, so the same stretch
    stays in view, and then the focused column is revealed. The scaled view
    is not rounded, so moving back restores it.
* **Reveal on focus** follows `scroll_center`: `never`, `on_overflow` or
  `always` (niri's names). The default, `on_overflow`, scrolls the least amount
  that shows the whole column, and centres a column wider than the view.
* **View limits:** the view stays within [0, extent − viewport] and is
  rubber-banded past either end during a gesture. A strip shorter than its
  viewport starts at the leading edge.
* **Operations:**
  * insert and remove;
  * move a column, or move within a column;
  * consume into a neighbour column, or expel from one;
  * set, step or cycle the width, and set member weights;
  * find a neighbour in strip order;
  * reveal;
  * transpose, when the direction changes;
  * `clone` and `eql`, for undo;
  * serialise.

## Presentation: the view moves windows

World = layout stays true, so a scrolled window really sits at its strip
position, even far off-screen. Picks, popups, damage and X11 therefore have no
second transform to agree with.

* **Keyboard reveals** re-place the workspace's members through
  `setAutoTile(rect, animate)`. Real positions move at once and the frames
  glide (`setPositionAnimated`), so input follows what is drawn and no new
  animation code is needed. A reveal must move windows without resizing them
  (fix 1).
* **Gesture scrolls** drive `view` 1:1 and apply it once per output frame,
  because pointer events arrive faster than frames. This is the same rule as
  `camera_event_pending` and `syncPresentationForInput`. Frames are placed
  without a glide. On release, the view snaps to the nearest column edge,
  keeping the release velocity.
* **Off-screen columns are culled.** A column wholly outside its viewport is
  not drawn and takes no input. Its frame callbacks are throttled (fix 4). The
  column still belongs to the visible workspace for focus, Alt+Tab, the taskbar
  and foreign-toplevel, and focusing it reveals it first. This needs a
  draw-only flag beside `workspaces.visible`, read where `applyVisualTransform`
  enables the frame. `visible` itself means membership and stays unchanged.
* **Cost:** a scroll moves every frame on the strip on every output frame.
  That is about what a canvas pan costs, since a camera change resolves every
  group too. Measure it against a canvas pan with the same windows in the
  benchmark at the end of the stage.

## Several displays: a home output for each window

Take a horizontal strip on display A with display B to its right: A's next
columns would show on B, on top of B's own workspace (fix 2). Before Stage 3,
the workspace slide avoided that overlap by picking the other axis or
cross-fading (`tiling-gaps.md` item 6).

Stage 3 added `rediwm_projection_set_tree_output(tree, output)`. A top-level group
with a home output is collected, drawn, damaged and picked only on that output.
Its surfaces enter only that output (through the carrier's `outputs_update`), so
a window half scrolled past A never takes B's scale.

* A's framebuffer edge cuts the overhang. That needs no shader change, and no
  combined rectangular and rounded clip, which the shaped pass cannot express.
* Popups inherit the home output.
* The change touches `projection_pick.c`, `scene_output_collect.c`, damage
  routing and the carrier binding, with fixture cases in `projection_test_*.c`.
* The same flag lets the workspace slide always go sideways, whatever the
  arrangement of displays. That closes the "slide on several displays" entry in
  `tiling-gaps.md` item 6.

The horizontal strip now works across several displays, including adjacent
outputs of different scales.

## Input

Workspace bindings carry over. In a scrolling workspace they act in strip
order. `focusDirection` scores frame centres among visible windows today, so it
cannot reach a culled column.

| Binding | Split workspace | Scrolling workspace |
|---|---|---|
| Super+Left/Right | focus left/right | focus the column to the left/right; the view follows |
| Super+Up/Down | focus up/down | focus within the column |
| Super+Shift+arrows | swap | move the column, or move within the column |
| Super+Ctrl+Left/Right | resize the split | narrower/wider by 32 px, a manual width (the step `resize_split` uses) |
| Super+Ctrl+Up/Down | resize the split | member height within the column |
| Super+w | — | `cycle_column_width`, through the presets |
| Super+[ / Super+] | — | `consume_left` / `consume_right` |
| Super+j (`toggle_split`) | rotate the split | — |

On a display with a vertical strip, Up/Down and Left/Right swap roles.

New actions, also available as IPC `tiling_action`s:

* `consume_left` and `consume_right`: join the neighbour column, or, at the
  end of the strip, leave into a column of one (niri's consume-or-expel).
* `cycle_column_width`.

Super+[, Super+] and Super+w are in the workspace preset
(`config/workspace_defaults.zig`). Both tiled modes inherit it through
`applyWorkspaceKeybinds`, including for existing configurations with custom
Canvas bindings. Entries in `[keybinds.workspace]` override individual keys.

Pointer and touchpad (stage 5):

* **Three-finger swipe along the strip** pans it 1:1, with rubber band and
  snap. `compositorOwnsSwipe` takes the swipe in a scrolling workspace whatever
  is under the pointer. A swipe across the strip is the workspace swipe of
  `tiling-gaps.md` item 5, which comes later.
* **Two-finger scroll** stays with clients, except over empty strip, as on the
  canvas.
* Both follow the shortcut-inhibit and lock rules of the other gestures
  (`src/input/AGENTS.md`).
* **Wheel:** Super+wheel still cycles workspaces, in either direction.
  Super+Shift+wheel and Super+horizontal wheel step through columns (or rows),
  as in niri.
* **Manual resizing by drag:** the tiling resize drag (`tiling_grab` `.resize`)
  sets a column's width when it crosses the strip and a member's weight when it
  runs along it, live, as split drags are today.
* **Super-drag insertion** (`tiling_grab`): `dropAt` gains drop targets in the
  gaps between columns (a new column) and on the halves of a column (join above
  or below). Dragging near the viewport edge scrolls the strip.

## What else has to keep working

* **Persistence:** the workspace JSON gains `layout`, the columns (width
  fraction, and members with weights), `view`, and the last tiled mode (`mode`,
  for fix 7). `workspace_layout.parse` rejects unknown fields and any version
  other than 2. Make the format version 3 and keep reading version 2, mapping
  `automatic` to `split` or `floating`.
* **Undo:** `layout_undo` snapshots trees with `clone` and compares them with
  `eql`, so strips join the snapshot, manual widths included. The view is not
  undone, because navigating is not an edit.
* **IPC:**
  * `WorkspaceData` gains `layout`, `columns`, `view` and the display's
    resolved direction.
  * `set_workspace_layout` takes a layout instead of `automatic: bool`.
* **Maximize and fullscreen** work as now: the member is suspended and its
  column keeps its place. Fullscreen and maximized windows are not strip
  members, so they stack above floating windows as they do today.
* **Modal dialogs:** focusing a dialog whose owner is culled reveals the owner,
  and the dialog moves with its owner.
* **Toplevel capture** of a culled window behaves as it does for a window on a
  hidden workspace.
* **Xwayland:** off-screen X11 windows get clamped root positions (`clampPos`).
  A gesture scroll configures X11 windows on every frame, as a canvas pan
  already does. X11 stacking follows the scene order through
  `syncXwaylandStack`, so the floating layer of fix 8 applies to X11 too.
* **Reduced motion:** reveals jump; gestures stay 1:1.
* **Greeter:** unchanged, since it has no workspace mode.

## Problems found, and their fixes

Reading the code turned up eight things that would go wrong. Each one is fixed
in the stage named, and that stage's tests check the fix.

### 1. Every scroll would resize every app (stage 2)

Tiles are placed through `setAutoTile`, which calls `requestSize` on any
change. `xdg_toplevel.setSize` always schedules a configure, even when the size
is the same. So a keyboard scroll would send a configure to every xdg client on
the strip, and a swipe would send one per frame.

**Fix:** when the new target differs from `auto_target` only in position,
`setAutoTile` moves the frame (`setPosition` or `setPositionAnimated`) and skips
`requestSize` and `animateChromeSize`. X11 still hears about the move through
`commitPosition`, as it does when the canvas pans. Split tiles that only shift
benefit too.

**Check:** `tests/scrolling.py` scrolls a strip and asserts that a client whose
size did not change received no configure. If the test client cannot count
configures yet, it learns to.

### 2. Windows would spill onto the next monitor (stage 3)

Columns scrolled past the edge of one display are drawn on the display next to
it, and can be clicked there.

**Fix:** the home output described above.

**Check:**

* Projection fixture cases: a group with a home output is not collected,
  damaged or picked on another output, and its surface enters only its home
  output.
* A two-output case in `tests/scrolling.py`: a column scrolled past the shared
  edge does not appear in the other output's IPC screenshot, and a click there
  does not reach it.

### 3. Code that works out a window's display from its position (stages 2 and 3)

Scrolled windows sit off-screen or straddle displays, so any lookup of "the
output under this window" can answer wrong. Callers of `Output.atLayout` that
pass window coordinates:

| Where | Today | Fix |
|---|---|---|
| maximize and fullscreen (`toplevel/layout.zig`, before `setMaximizedOn` and `setFullscreenOn`) | output under the window's centre | `currentOutput()`, which prefers workspace membership (stage 2) |
| grab release (`input/grabs.zig`, before `workspaces.placed`) | output under the window's centre | strip members never take this path; their drops go through `dropAt`. Floating windows keep it, since where the user dropped them is the intent (stage 2) |
| `Popup.windowConstraintBox` | output under the root surface's origin | the window's home output (stage 3) |
| text-input popups (`input/text_input.zig`) | output under the text cursor | the focused window's home output (stage 3) |

Already safe: `currentOutput` (it checks `outputFor` first) and
`auto_place.Carry`, which skips workspace mode.

**Check:** on two outputs, `tests/scrolling.py` maximizes and fullscreens a
window that is partly scrolled off, and opens a popup in it. Each must land on
the window's own display.

### 4. Off-screen windows and frame pacing (stage 2)

A culled window must neither keep repainting at full rate nor stall.

**Fix:** culled windows take the path a hidden workspace's windows take:
throttled frame callbacks, and fifo's 20 Hz release for hidden surfaces. Coming
back costs one stale frame, as after a workspace switch.

**Check:**

* Idle wakeups with culled windows stay at the hidden-workspace rate.
* A fifo-paced client culled for a few seconds keeps making progress.

### 5. The taskbar's glass would re-blur on every frame of a scroll (stages 2 and 5)

`holdingGlass` only knows about camera motion. Windows moving under a glass
panel damage its backdrop, at about 0.35 ms per effect per frame.

**Fix:** `holdingGlass` also holds while a strip moves, and refreshes on the
frame where it settles. Reveal glides get this in stage 2, gestures in stage 5.

**Check:** the cost benchmark counts re-blurs per scroll.

### 6. Tests would race the scroll (stage 2)

Input follows what is drawn, and a reveal glides. A test that clicks right after
a scroll would hit the wrong place.

**Fix:**

* `wait_for("window_geometry_settled")` also waits for a strip that is still
  gliding or snapping.
* `WorkspaceData.view` lets tests assert where the strip rests.
* Culled windows report their real off-screen geometry, so tests can check
  positions.

**Check:** `tests/scrolling.py` uses the settle wait before every click and
snapshot, and passes repeatedly.

### 7. Switching to Canvas and back forgets the tiled layout (stage 0, strips in stage 2)

Leaving workspace mode frees the split trees and workspace slots
(`workspaces.setMode`: `tiler.deinit()`, `slots = @splat(.{})`) and cancels a
pending restore. The autosave reads the workspace file only at startup
(`session/layout_autosave.zig`). Coming back in the same session therefore
starts a fresh layout. There is also nowhere to record which tiled mode to
return to while in Canvas.

**Fix:**

* Leaving a tiled mode keeps a snapshot of the slots, per-workspace layouts,
  trees and strips (with widths and views), keyed by `Toplevel.id`. Entering a
  tiled mode re-applies it to the windows that still exist. Windows opened in
  the meantime join as new ones; closed windows drop out.
* Across restarts, the existing restore does the same by window identity.
* The last tiled mode is recorded in the workspace save (`mode`). It is session
  state, not a setting, so no new config key. `toggle_desktop_mode` reads it
  and writes `desktop_mode` as it does today.
* Plain Workspaces mode gets the same memory.

**Check:** an integration case tiles and resizes, switches to Canvas, opens and
closes a window there, switches back, and compares the layout over IPC.

### 8. Focusing a tile would cover the floating windows (stage 2)

`Toplevel.raise` puts the focused window at the top of the stack, so clicking a
tile would bury every floating window behind it.

**Fix:** in a scrolling workspace, raising a strip member places it just below
the workspace's lowest floating window, not at the top. Floating windows keep
their own order above the strip. X11 stacking follows through
`syncXwaylandStack`, and an owner is still never raised above its transients.

**Check:** `tests/scrolling.py` focuses tiles under a floating window and
asserts the stacking order over IPC.

## Settings and configuration

```toml
[compositor]
desktop_mode = "scrolling"                     # canvas | workspaces | scrolling
scroll_column_widths = [0.333, 0.5, 0.667, 1.0]
scroll_column_width = 0.5                      # new columns
scroll_center = "on_overflow"                  # never | on_overflow | always

[[outputs]]
name = "eDP-1"
scroll_direction = "auto"                      # auto | horizontal | vertical
```

* **Direction is per display.** `scroll_direction` lives in `[[outputs]]`
  (`config/output_config.zig`, saved by `config/output_save.zig` like
  `adaptive_sync`). It defaults to `auto`, which scrolls along the longer side
  of the display's usable box after its transform: sideways on a landscape
  panel, up and down on a portrait or rotated one.
* A workspace takes the direction of the display that shows it. When it moves
  to a display with the other direction, or the setting changes, its strip is
  transposed: columns become rows, widths are kept as fractions, and the view
  is recomputed around the focused column.
* `window_gap` is shared with the split layout.

Settings → Display (`control_center/sections/display.zig`): each display gets
a "Scrolling direction" row (Automatic / Horizontal / Vertical), next to
adaptive sync. It is shown only while some workspace scrolls (the Scrolling
mode, or a workspace set to Scrolling), so Canvas users never see it.

Settings → Desktop:

* The mode select gains "Scrolling". `modeChanged` currently stops at index 1.
* When Scrolling is chosen, the page shows the new-column width and centring.
* The per-workspace select becomes "Automatic tiling / Scrolling / Floating".

Elsewhere:

* The taskbar `desktop_mode` item gets a third icon (`desktop_scroll`), and its
  menu (in the working tree) a third entry.
* `toggle_desktop_mode` (Super+Shift+W) switches between Canvas and the last
  tiled mode (fix 7).
* New strings go through `i18n.tr` for the shipped languages.

## Stages

Sizes as in `tiling-gaps.md`: S is a day, M a few days, L a week or more.

0. **Groundwork (M).**
   * `Workspace.layout` replaces `automatic`, across persistence (v3), IPC, the
     Settings select and undo.
   * `DesktopMode.scrolling` is plumbed through config, Settings, the taskbar
     item and menu, `toggle_desktop_mode` and the binding set.
   * Mode switches remember the tiled layout and the last tiled mode (fix 7,
     split trees).

   Scrolling workspaces still lay out as split, so existing users see no change
   except that Canvas and back now keeps their layout.
1. **Strip model (M).** `scroll_layout.zig` and its tests, preset and manual
   widths and transposition included. Nothing calls it yet.
2. **Bridge and keyboard (M–L).**
   * The `auto_tiling` reflow dispatches on the layout.
   * A view per workspace, revealed on focus and kept while hidden.
   * The strip-order actions and their keys, including keyboard width steps
     and preset cycling.
   * Culling, with throttled frame callbacks (fix 4).
   * Re-placement that moves windows without configuring them (fix 1).
   * Maximize, fullscreen and grab release follow membership (fix 3).
   * Floating windows above the strip (fix 8).
   * Glass held during reveals (fix 5).
   * Settle waits and `view` over IPC (fix 6).
   * Persistence, undo and mode-switch memory of strips (fix 7).
   * `tests/scrolling.py`.

   Horizontal direction and one display only.
3. **Home output (M).**
   * The projection flag and its fixture cases (fix 2).
   * Popups and text-input popups follow the home output (fix 3).
   * Scrolling across several displays, with moves of a scrolling workspace
     between displays tested like `tests/output_reconnect.py`.
   * Slides that always go sideways.
4. **Direction per display (S–M).**
   * Vertical strips and transposition.
   * `scroll_direction` in `[[outputs]]` with `auto` resolved from the usable
     box and transform.
   * The Settings → Display row.
   * A workspace moved between displays of different directions.
5. **Gestures and drag (M).**
   * Swipe and wheel scrolling with rubber band and snap, applied once per
     frame.
   * Manual width and height by drag.
   * Glass held during gestures (fix 5).
   * Insertion between columns.
   * Edge scrolling while dragging.
6. **Polish (optional).**
   * A strip overview: the display zooms out over its whole strip (per-window
     tree zoom) and a click jumps there. The existing overview is canvas-only.
   * A thin position indicator while scrolling, like the canvas mini-map.
   * Motion when a column opens or closes.

Each stage ends with Debug and ReleaseSafe builds, `zig build test`, and the
workspace integration suites (`workspaces`, `window_tabs`, `layout_autosave`,
`desktop_selection`) compared against HEAD. Stages 2, 3 and 5 also run the cost
benchmark: a scroll against a canvas pan with the same windows, re-blurs per
scroll, and idle wakeups unchanged.

## Stage 2 verification (2026-11-26)

Debug, ReleaseSafe and `zig build test` passed. The scrolling integration
passed at scales 1 and 1.5, including restart in reverse client launch order.
The workspace and desktop-selection suites passed. Two other comparison
suites failed at the same assertions on clean HEAD (`86593f90`).
`window_tabs.py` could not Tab to the Appearance checkbox, and
`layout_autosave.py` expected periodic Canvas autosave, which is disabled.

In one headless GLES2 ReleaseSafe run, `tests/scrolling_perf.py` moved the
same three windows 636 px eight times in each mode.

| Mean measurement | Keyboard strip reveal | Canvas pan |
| --- | ---: | ---: |
| CPU time per frame | 0.686 ms | 0.934 ms |
| GPU time per frame | 0.432 ms | 0.494 ms |
| Output commits per move | 19.0 | 10.875 |
| Re-blurs per move | 4.0 | 5.0 |

The two animations have different durations. In separate eight-second idle
samples, both a culled client and a client on a hidden workspace received
zero frame callbacks, and the output made zero commits.

## Stage 3 verification (2026-11-26)

`zig build test-projection` covers picking, occlusion, damage and surface
feedback on adjacent and overlapping outputs, including output removal and
reuse of an output index. `python3 tests/scrolling.py outputs` checks actual
pixels, clicks, preferred scale, popup positioning and repositioning, IME
candidates, workspace slides, dialog transfers and monitor unplug/replug.

`python3 tests/scrolling.py x11` checks where GTK receives the first click in
both directions across a shared edge. It also checks ordered press/release
pairs while the private X server is paused, cancellation for a hidden target,
and delivery to a native client while Xwayland remains stalled. A native event
waiting on the X server starts a single 100 ms deadline. On expiry, the
compositor discards undelivered X input and dispatches the live native events.

The final Debug and ReleaseSafe builds, `zig build test`, workspace suite and
FreeBSD compile check passed. The window-tabs and Canvas autosave suites still
stop at the two HEAD assertions recorded under Stage 2.

The ReleaseSafe benchmark repeated the 636 px motion eight times on headless
GLES2 with three windows.

| Mean measurement | Keyboard strip reveal | Canvas pan |
| --- | ---: | ---: |
| CPU time per frame | 0.742 ms | 1.128 ms |
| GPU time per frame | 0.440 ms | 0.483 ms |
| Output commits per move | 19.0 | 10.75 |
| Re-blurs per move | 4.0 | 5.75 |

Both eight-second idle samples recorded zero frame callbacks and zero output
commits. Compositor thread context switches averaged 1.62/s with a culled
column and 0.62/s on a hidden workspace.

## Stage 4 verification (2026-11-26)

`[[outputs]] scroll_direction` is parsed, saved by `output_save`, set by IPC
`set_output_config` and `rediwm-msg output-config --scroll-direction`, and
reported by `outputs` as the setting and the resolved direction. `auto`
resolves from the usable box, which is in layout units and so already
rotated. On a vertical strip the arrow keys swap roles for focus, moves and
resizing, so each arrow still points where the window goes. When a strip's
viewport length changes (a new direction, display or resolution) its view
scales with it, unrounded so that moving back restores it, and then the
focused column is revealed.

Unit tests cover the resolution, the arrow mapping, and a transposed strip
keeping the same stretch in view and returning to its view.
`python3 tests/scrolling.py direction` puts a portrait output beside a
landscape one. It checks rows stacked down the portrait strip, culling above
the view, Up/Down along and Left/Right across the strip, consume, moves and
both resize steps. It then turns the strip sideways and back through IPC
(columns kept, setting saved), sets the landscape display to Vertical through
Settings → Displays, and unplugs the portrait display so its strip runs
sideways on the landscape one, then comes back with the same columns and view.
`display_arrangement.py` checks that Canvas shows no direction row.

Debug, ReleaseSafe and `zig build test` passed. The new row took
`display.zig` past 800 lines, so its arrangement card moved verbatim into
`display_arrangement.zig`.

All five scrolling cases passed at scales 1 and 1.5. The workspace,
desktop-selection and display-arrangement suites passed. `window_tabs.py` and
`layout_autosave.py` stopped at the two HEAD assertions recorded under Stage 2,
and `control_center.py` at its known Settings resize assertion (line 287),
before its Displays step. No OS calls changed, so the FreeBSD check was not
rerun. Stage 4 has no cost benchmark.

## Stage 5 verification (2026-11-26)

`scroll_motion.zig` holds each workspace's hand-moved view: a three-finger
swipe (taken whatever is under the pointer, unless a client inhibits
shortcuts) or two fingers over empty strip move it 1:1 with `pan_speed`,
rubber-banded past either end, and the world's frame tick places the windows
once per output frame. A release projects the view 0.3 s along its speed,
snaps to the nearest column edge (`Strip.snapView`; centred columns with
`always`), keeps focus if its column still shows or focuses the snapped
column, and settles on the `camera_pan` curve (a jump with reduced motion).
While fingers are down or a release settles, reflows keep the view and a
reveal leaves it alone; a key press during the settle takes over from where
it is. A finger scroll that sends nothing for 400 ms ends itself, since its
stop event can go elsewhere, and a lock ends any gesture. Super+Shift+wheel
and Super+horizontal wheel step columns.

The tiling resize drag on a strip sets the column width along it and the
member height across it, live, with an owned strip snapshot for Escape and
one undo step; from the leading edge the view moves so the trailing edge
stays put. Super-drag drops (`Strip.dropAt`) land in a column of their own
near a column's leading or trailing fifth (24 to 120 px), or join the column
above or below the member under the pointer; a drop that changes nothing, or
a join that would overflow the column, shows no preview. Holding a drag
within a twelfth of the display's length of either end scrolls the strip at
up to 1600 px/s.

`python3 tests/scrolling.py gestures` covers the swipe (1:1 motion, windows
following at the next frame, snap and focus, fling, rubber band, no configure
for a window whose focus did not change), two fingers over a gap and over a
window, the wheel steps, trailing- and leading-edge width drags with Escape
and undo, height drags, both drop kinds and edge scrolling. IPC `scroll`
gained `finger: true` for it.

The ReleaseSafe benchmark moved the same three windows 636 px eight times in
each mode on headless GLES2:

| Mean measurement | Keyboard reveal | Swipe | Canvas pan |
| --- | ---: | ---: | ---: |
| CPU time per frame | 1.047 ms | 0.677 ms | 1.43 ms |
| GPU time per frame | 0.399 ms | 0.358 ms | 0.462 ms |
| Output commits per move | 18.4 | 12.75 | 10.6 |
| Re-blurs per move | 4.0 | 2.5 | 5.125 |

Idle samples still recorded zero frame callbacks and zero output commits for
a culled client and one on a hidden workspace.

## Stage 6 verification (2026-11-26)

* **Strip overview:** Super+A (now also in the workspace preset) on a
  scrolling workspace is a mode of the existing overview. Its cards are the
  workspace's windows at their places on the strip, scaled to fit the whole
  strip along the display (at most 0.9) and centred across it, so culled
  columns show too. Hover magnification, the outline, arrows and Enter work
  as on the canvas; a pick jumps the strip to the window and the zoom back
  carries it there; Escape leaves view and focus alone.
* **Position bar** (`strip_indicator.zig`): a 4 px track and accent thumb
  along the far edge of the display across the strip, drawn inert, shown
  while the strip moves and longer than the screen. It follows
  `mini_map_enabled`, stays `mini_map_hide_ms` after the strip settles
  (a timer, no frames), then fades over 220 ms.
* **Open and close motion:** neighbours already glided on a reflow, except a
  window still in its open animation's tail jumped: the move-only placement
  refused to glide while `map_motion` was active. It now glides like a split
  tile that was already placed.

`python3 tests/scrolling.py polish` checks the overview (all four columns in
one row, Escape, clicking a culled column), the bar while a swipe is held and
its fade, and a neighbour gliding when a column opens and closes.

Debug, ReleaseSafe and `zig build test` passed after both stages. All seven
`tests/scrolling.py` cases passed at scales 1 and 1.5, as did `scrolling.py
x11`, the workspace, desktop-selection, canvas overview and display
arrangement suites. `window_tabs.py` and `layout_autosave.py` stopped at the
HEAD assertions recorded under Stage 2.

## Decisions (accepted 2026-11-26)

* **D1: strip offset.** Independent per workspace on each display. Each
  workspace keeps its own view, also while hidden; the canvas camera stays
  pinned in workspace mode. Rejected: scrolling through the shared camera,
  which scrolls every monitor at once.
* **D2: desktop mode.** Both a global default and a per-workspace override:
  `desktop_mode = "scrolling"` sets the default, and each workspace can choose
  split, scrolling or floating.
* **D3: mode switching.** Remember the last layout. Super+Shift+W switches
  between Canvas and the last tiled mode, and that mode comes back as it was
  left (fix 7).
* **D4: mouse wheel.** niri's mapping, the same in either direction:
  Super+wheel cycles workspaces; Super+Shift+wheel and the horizontal wheel
  step through columns or rows.
* **D5: a strip shorter than its viewport** starts at the leading edge, as in
  niri.
* **D6: column widths.** Presets plus optional manual resizing. Super+w cycles
  the presets; Super+Ctrl+arrows and the resize drag set any width or height.
  Super+[ and Super+] consume and expel.
* **D7: floating windows** stay stationary above the scrolling strip (fix 8).
  A dialog with an owner on the strip moves with its owner.
* **D8: scroll direction.** Selectable per display, with `auto` as the default
  (the display's longer side).
