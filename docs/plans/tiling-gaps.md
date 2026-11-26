# Plan: closing the tiling gap to Hyprland

Status: draft, 2026-10-12. The first two gaps (where new windows go, and
motion) are done, uncommitted; everything below them is a proposal. Nothing in
it is decided.

Scope: what RediWM's workspace mode (`docs/plans/optional-tiling.md`) still
lacks next to Hyprland and the other tiling compositors, in the order a user
coming from them would notice, with a sketch of how each fits the code.
Canvas mode is out of scope.

## Where we are

Workspace mode has one automatic layout: a recursive binary split
(`auto_layout.zig`, pure) bridged to windows by `auto_tiling.zig`, with
per-workspace automatic/floating, keyboard focus/swap/split resize/rotation,
Super-drag insertion with a preview and Escape, tab groups as one tile, client
size limits respected (overflow floats), multi-window undo, restart restore,
32 workspaces with `ext-workspace-v1`, per-app floating rules, a Settings page
and typed IPC.

Done in this round:

1. **New windows split the focused tile**, as in Hyprland's dwindle and in
   i3/Sway. `workspaces.mapped` records the window that had focus on the
   workspace (`Toplevel.auto_anchor`); `Tree.sync` splits that leaf along its
   longer side, and falls back to the previous rule (beside the member admitted
   before) when the anchor has no tile. A window moved to another workspace
   joins beside that workspace's focused window.
2. **Motion.** Reflows glide: `setAutoTile` reuses the animated move and frame
   resize that canvas snapping uses (`window_move`/`window_resize` curves).
   Entering the mode, output changes and restored layouts stay instant
   (`Manager.quiet`), as do live split drags, hidden workspaces and a window's
   first tile while it opens. A settled frame animation now gives way to the
   size the client actually took once it has answered the configure
   (`size_wait`), so a client that cannot fit a tile is no longer clipped to
   it. During a workspace switch the higher number arrives from the right,
   clipped to its output even on adjacent displays, at the `desktop_switch_ms`
   speed canvas desktop switches use. The leaving workspace's windows stay
   drawn but inert (`rediwm_projection_set_tree_inert`) until they are off
   screen, so hidden workspaces still take no input. Reduced motion uses a
   cross-fade. Input follows what is
   drawn, so a click during a glide or slide lands where the window is shown.

## Remaining gaps

Ordered by how soon a Hyprland or Sway user would miss each. Sizes are rough:
S is a day, M a few days, L a week or more.

### 3. One layout only (M to L)

Hyprland 0.54 (Feb 2026) ships dwindle, master, scrolling and monocle, chosen
per workspace; 0.55 (May 2026) adds layouts written in its Lua config. Sway has
split/tabbed/stacking per container; niri is built around scrolling columns.

Proposal, in this order:

* **Per-workspace layout choice.** `Workspace.automatic: bool` becomes
  `layout: enum { floating, split, master, monocle }` (persisted in the v2
  workspace JSON, which needs a version bump or an additive field; shown in
  Settings → Desktop beside today's automatic/floating choice; an IPC setter
  and a `cycle_layout` action).
* **Monocle (S–M).** Every member gets the usable box and only the focused one
  is shown. Tab groups already do "one shown, the rest hidden but kept"
  (`tab_hidden`, `window_tabs.visible`); monocle can reuse that visibility rule
  without forming a group, so Alt+Tab, the taskbar and focus cycling work
  unchanged.
* **Master/stack (M).** A second pure module beside `auto_layout.zig` with the
  same `Member`/`Box` types: one master column (count and ratio adjustable),
  the rest stacked. Insertion order is `workspace_order`, so it is
  deterministic. Swap, focus and resize actions map onto it (swap with master,
  grow master).
* **Scrolling (L), later.** Columns on a strip wider than the output. The
  camera machinery from canvas mode (pan animation, `camera_pan` curve) is the
  natural base, but workspace mode fixes the camera today, and picks, popups and
  glass holds all assume that. Worth a plan of its own.
* User-defined layouts are not planned; RediWM has no scripting runtime.

### 4. Missing tools (S each, except the scratchpad)

* **Scratchpad / special workspace (M).** A workspace that is not on any
  output and toggles over the current one (Hyprland's `special`, Sway's
  scratchpad). Workspace slots are fixed at 32 and owned by outputs; a 33rd
  slot that `visible()` treats as shown over the focused output, floating only,
  is the smallest change. Super+S (left free by the preset on purpose).
* **Pin (S).** A floating window shown on every workspace of its output:
  `visible()` returns true for pinned windows regardless of `workspace_id`;
  workspace transfers skip them. Super+P is also free.
* **Pseudotile (S).** Hyprland keeps a window's preferred size centred in its
  tile. RediWM already leaves a bounded client's unused space in its tile
  (top-left, not centred); a per-window flag that sets `max_width/height` to the
  window's floating size, plus centring in `Node.place`, gives the same result
  through the existing constraint path.
* **Open on workspace N (S).** A `workspace` window-rule property beside
  `output` (`config/window_rules.zig`), applied in `workspaces.mapped` before
  the output's workspace is taken. Today only `output` and `floating` exist.
* **Monitor actions (S).** `focus_output left/right`, `move_to_output
  left/right` (with follow) and `move_workspace_to_output`. IPC already moves a
  window to an output (`move_window_to` with `output`, `Toplevel.moveToOutput`);
  the keybinding actions and a workspace-level move are missing.

### 5. Configuration depth (S each)

* **Inner and outer gaps.** One `window_gap` is both today
  (`Tree.arrange`); Hyprland has `gaps_in`/`gaps_out`. Split it into two
  settings, keeping `window_gap` as the default for both.
* **Smart gaps / no border when alone.** No gaps and no outline when a
  workspace has one tile.
* **Focus outline.** Fixed at 1 logical px in `workspace_active_border`;
  add a width and an inactive colour. Gradients are not worth the shaped-pass
  cost.
* **Binding modes (submaps).** A `[keybinds.workspace.resize]`-style table
  entered by an action and left by Escape; the shortcut resolver already
  switches tables per mode, so a third level is a resolver change plus Settings
  display.
* **Touchpad swipe between workspaces (M).** Three/four-finger horizontal
  swipes currently go to clients (`zwp_pointer_gestures_v1`). A compositor
  swipe that drives the new slide offset with the finger and settles with a
  spring (the `Anim.retargetWith` velocity path) would match Hyprland and
  niri. Needs the shortcut-inhibit and lock rules the other gestures follow
  (`src/input/AGENTS.md`).

### 6. Animation polish (S each)

Follow-ups to item 2:

* **Tile open/close.** New tiles take their first rectangle at once while the
  open animation plays; Hyprland's "popin" grows the window from its tile. A
  scale-from-tile variant of `window_open` would read better.
* **Split side under the cursor.** Hyprland's dwindle puts the new window on
  the side of the focused tile nearest the pointer; RediWM always uses the
  right/bottom half. Cheap to add as an option.
* **Frame resize cost.** Easing frames used to re-raster their titlebar for
  every device pixel of width change (`ChromeBuffer.create`). They now stretch
  the last raster within 12% of its width and raster exactly at rest
  (`Toplevel.stretchesTitlebar`, which canvas snaps and maximize share).
  Measured on a ReleaseSafe build, headless GLES2, 1280×720 logical at 1.5×,
  four tiles whose root split rotates (every tile moves and resizes), 12
  reflows: instant tiling costs ~14 ms CPU per reflow; the glide cost ~115 ms
  with ~68 titlebar rasters and 6.0 ms average frames (p95 9 ms) before the
  stretch, and ~68 ms with ~20 rasters and 3.1 ms average frames (p95 8 ms)
  after. The p95 comes from all tiles crossing the 12% step on the same frame;
  staggering them, or splitting the titlebar into a stretchable band and a
  fixed control strip, would flatten it. Worth re-measuring on a 2560×1600
  panel with six or more tiles.

### 7. Extensibility (not planned)

Hyprland has plugins, a large dispatcher set and, since 0.55, Lua
configuration with a layout API. RediWM's typed IPC with lock and sandbox
checks covers automation; a plugin ABI or a scripting runtime is out of scope.
What is worth matching is coverage: every new action above should be an IPC
`tiling_action`/workspace action as well as a binding.

### 8. Maturity

Workspace mode is still opt-in, and the qualification record
(`docs/plans/optional-tiling-qualification.md`) has physical multi-display
checks pending. Making it a peer of canvas mode needs that checklist done
first, independent of features.

### Not planned

Sway's arbitrary-arity containers, stacking layout, marks and focus
parent/child. The binary tree plus tab groups covers what those are mostly used
for, and the tree's undo, persistence and drag insertion all assume two
children per split.

## Suggested order

1. Monitor actions, workspace window rule, inner/outer and smart gaps (all S,
   independent).
2. Per-workspace layout choice with monocle.
3. Scratchpad and pin.
4. Master/stack.
5. Touchpad workspace swipe.
6. Scrolling, as its own plan.

## Sources

Hyprland facts are from release coverage, not hands-on use:

* Hyprland 0.54, per-workspace layouts, scrolling and monocle in core:
  https://hypr.land/news/update54,
  https://linuxiac.com/hyprland-0-54-brings-per-workspace-layouts/
* Hyprland 0.55, Lua configuration and user-defined layouts:
  https://phoronix.com/news/hyprland-0.55-wayland-comp
* Hyprland 0.56 (July 2026), not checked against the official changelog:
  https://www.linuxcompatible.org/story/hyprland-056-ships-with-expanded-lua-scripting-motion-blur-and-zero-breaking-changes/
