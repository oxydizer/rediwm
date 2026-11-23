# Plan: tabs in the titlebar

Status: draft, 2026-11-22. Nothing is built or compiled; this was written from a
read of master (`deefb71`) in a sandbox without Zig 0.17, so every file and line
reference below is from reading, not from a build. The decisions are proposals
except the three marked *chosen*.

Scope: a tab strip drawn in the window titlebar, fed by the app, shared by every
`rediwm-*` program. First user is `rediwm-editor`; `rediwm-files` follows once its
per-folder state is split out of `App`. Out of scope: dragging a tab out into a
new window (needs `xdg-toplevel-drag`), tabs for third-party apps (their window
groups in `window_tabs.zig` keep working as they do), pinned tabs.

Branch: `feat/titlebar-tabs`, cut from master, independent of the Files
branches. Phases 1-4 touch no file under `src/files`, so the branch can land
first; Files adopts the shared client helper afterwards (phase 5) on whatever
branch Files work has landed on by then.

## Decisions

* **Chosen: the compositor paints the strip, the app publishes it.** The titlebar
  is server-side for `rediwm-*` apps, so the compositor owns those pixels. An app
  that painted its own strip would have to self-decorate and duplicate the frame,
  the window controls, the shape rule ("every ring pixel needs body content
  beneath it") and the theme knobs (`chrome_height`, `chrome_control_gap`,
  `chrome_round_buttons`, ...). A small private protocol avoids all of that.
* **Chosen: first pass is the mechanism plus the Editor.** Files needs a per-tab
  view split first (see "Files, later").
* **Chosen: the Editor's menu button takes the leading slot** (where the mockup
  shows the app icon).
* **The toolkit owns behaviour, each surface keeps its painter.** Model,
  geometry, hit testing, overflow and drag-reorder move into `ui`. The compositor
  keeps its Renderer painter. A Cairo painter for the self-decorated fallback is a
  later step, the same split the scrollbar uses (`Look` shared; `paint` /
  `cairo.drawScrollbar` per surface).
* **Full state on every commit, not deltas.** A strip is at most 128 tabs of short
  strings; resending it removes a whole class of drift bugs. The compositor
  already diffs by hash (`chrome_tabs.hash` / `layoutHash`) and repaints only
  changed titles.

## What the code says

* `chrome_tabs.zig` (151 lines) already has the model (`Tab`, `Strip`, `Hit`),
  `geometry`, `hit`, `hash`/`layoutHash` and the painter. Its only compositor
  imports are `chrome` (which just re-exports `window_chrome`'s `Metrics` and
  `controlRectScaled`), `icon_service`, `taskbar/chip_style` and
  `window_tabs.Notice`. The model, geometry, hit and hash code can move to `ui`
  almost verbatim; the painter stays.
* The strip's only producer is `toplevel/tabs.zig` (`tabStrip`, `fillTabs`),
  which reads compositor window groups (`window_tabs.members`). Its consumers:
  `toplevel/chrome_actions.zig:23` (click), `input/motion.zig:457` (hover),
  `input/buttons.zig:445` (resize-edge exclusion), `input/axis.zig:97` (wheel)
  and `toplevel/chrome_sync.zig:161` (allocation, gated on `tab_group != 0`).
* `window_tabs.enabled` returns false for any app id starting `rediwm-`, so a
  published strip and a compositor window group can never both apply to a window.
* `chrome.zig:506` and `:551` draw the app icon only when `tabs.len == 0`: today a
  strip replaces the icon. The mockup shows both.
* Tab ids are `u64` in `chrome_tabs.Tab` (window ids today). The Editor's
  `Tab.id` is a `usize` counter (`next_id`), unique for the process.
* The Editor draws its own strip in `top = 40` px of content
  (`editor/app_paint.zig:225-248`, geometry in `app_controls.zig:111-169`, press
  handling in `app_input.zig:113-129`), with `tab_max/min` 176/112 px against the
  compositor's 170/85. Under SSD it reserves 80 px on the right for `+` and the
  menu; under CSD (`has_titlebar`, set in `client_window.zig:204,221`) the menu
  lives in the fallback header (`client_render.zig:109`).
* Editor drafts store unsaved tabs "in order" (`editor/drafts.zig` header), so a
  reorder must rewrite that order.
* `KdeDecoration.zig` is a short, complete model for a Zig-implemented custom
  global with per-surface resources; the new global follows its shape.
* No rediwm-private protocol exists for chrome; `build/protocols.zig` lists
  standard, wlr and a few custom XMLs under `protocol/`.

## Protocol: `rediwm_titlebar_tabs_v1`

The XML is `protocol/rediwm-titlebar-tabs-v1.xml`, added in `build/protocols.zig`
with `addCustomProtocol` and `generate("rediwm_titlebar_tabs_manager_v1", 1)`.
The factory request takes a `wl_surface`, not an `xdg_toplevel`, like the KDE
decoration manager: the compositor resolves the toplevel from the surface and
`attach` adopts a strip created before the shell role exists.

Landed first (phase 2): `add_tab(id, title, icon_name, flags)`,
`set_selected`, `commit` and the events `select`, `close`, `new_tab`. Still to
add with the leading slot and drag (phase 2c): `set_leading_button(enabled)` (shows the app icon),
`leading_activated(x, y, width, height)` and `move(id, index)`. The protocol is
unreleased, so these are added to version 1.

Semantics:

* `commit` replaces the shown strip atomically from the pending list. An empty
  list removes the strip and the titlebar returns to its title row. A non-empty
  list needs `set_selected` naming one of its ids, else `unknown_selected`.
* Bounds, checked on the compositor: at most `window_tabs.max_tabs` (128) tabs;
  titles and icon names are cut at 256 / 128 bytes and must be valid UTF-8
  (invalid ones are replaced, not fatal); ids unique per commit.
* `icon_name` is accepted and ignored for now: every tab shows the app's own
  icon, as the compositor's strip does today. Per-tab icons resolve through
  `icon_service` later.
* The compositor never changes the selected tab on its own. A click sends
  `select`; the strip updates when the app commits. One frame of latency, no
  divergence. Hover and the drag preview are local to the compositor.
* `move` is sent once, on release, with the final index. During the drag the
  compositor paints the moved tab under the pointer and shifts its neighbours.
* The resource is bound to one `wl_surface`; destroying it or the surface removes the strip.
* Only `modified` and `attention` exist in v1. The compositor shows `modified`
  as a bullet in front of the title (`\u2022 name`), so truncation never hides
  it.

## Toolkit: `ui/widgets/title_tabs.zig`

Pure, no compositor imports, with tests in `ui/title_tabs_tests.zig` (reached
from the module's `test` block):

* `Tab`, `Strip`, `Hit`, `key` from `chrome_tabs.zig`. `Tab.id` stays `u64`,
  `flags` replaces `attention`, `title` and `icon_name` are slices owned by the
  caller. `Notice` stays in the compositor: the strip takes an optional `busy`
  label instead.
* `geometry(width, density, strip, leading)`: as today, with a leading slot
  (icon or button, `22 * density` wide plus gap) before the first tab.
* `hit`, `hash`, `layoutHash` unchanged in meaning.
* `Drag`: a state machine (`press` -> pending until 4 * density px -> dragging ->
  `release` returns the insertion index). It takes the geometry, so it is
  testable without a window.
* Hover/close-button rule as one function: close button on the active and the
  hovered tab, never both a close button and a modified dot on one tab.

`chrome_tabs.zig` keeps `paint` and the compositor's `Strip` adapter.

## Compositor

* `src/titlebar_tabs.zig`: the global and per-toplevel resource (shape of
  `KdeDecoration.zig`). `Toplevel` gains `titlebar_tabs: ?*TitlebarTabs`, cleared
  on toplevel and resource destruction.
* `toplevel/tabs.zig`: `tabStrip` picks the published strip when present;
  `tabAt` drops its `tab_group == 0` gate for it. `stepTab` and the wheel
  (`input/axis.zig:97`) send `select` for the neighbouring id instead of focusing
  a window.
* `toplevel/chrome_actions.zig`: `handleChromeClick` dispatches `.tab`, `.close`,
  `.plus` and `.previous/.next` by source: window group as today, otherwise
  `select`, `close`, `new_tab`, `select`. A press on a tab starts `Drag` instead of
  acting on press for published strips, so a click is decided on release.
  Middle click on a tab sends `close`.
* `input/motion.zig` and `input/buttons.zig`: feed the drag from pointer motion
  and release; the resize-edge exclusion already uses `tabAt`, so it holds.
* `toplevel/chrome_sync.zig:161`: allocate tab storage when either source has
  tabs; a published strip is copied to a per-resource buffer first so the
  immutable-buffer rule in `chrome.zig` is respected.
* `chrome.zig`: draw the icon (or leave the leading slot to the button) with a
  strip present; `chrome_tabs.geometry` starts after it.
* Leading slot: a ghost `button.paint` button. The compositor cannot know
  whether the app's popup is open, so v1 has no selected state for it.
* IPC: add published tabs and the leading button as nodes under the window's
  `window/<id>` entry in `ipc/handlers_widgets.zig` (which already builds that
  node), so the integration suites can click them.

## Editor (`src/editor`)

* New `app_tabs_publish.zig`: builds the pending list from `App.tabs` (id =
  `Tab.id`, title = `tab.name()`, `modified` = `tab.doc.modified()`), commits
  when a hash of (ids, titles, flags, selected) changes. Called from the loop in
  `main.zig` beside the `title_changed` handling.
* Events: `select` -> `findTab`, `selected = i`, `changed()`. `close` -> select
  then `closeSelected()` (keeps the unsaved-work prompt). `new_tab` ->
  `act(.new)`. `move` -> reorder `App.tabs` keeping `selected` on the same tab,
  then rewrite the draft order. `leading_activated` -> `toggleMenu` with a
  left-anchored variant (it takes the right edge today).
* When the compositor offers the protocol and the window is SSD: `top` stops being
  a constant (`app.zig:35`) and becomes 0 (`viewTop`, `tabRight`, the find-bar
  offset in `app_paint.zig:161`, the press test `py < top` in `app_input.zig:113`,
  `ime.sync`), the in-content strip and its `tab_scroll`, `revealTab` and
  `scrollTabs` are skipped, and `Hover` loses `.close/.new/.menu`.
* Self-decorated fallback (no global, `force_csd`, or a client-side decoration
  mode) keeps today's strip unchanged. Replacing it with the toolkit widget in
  `renderTitlebar` is a follow-up and the first step toward Files.
* Shared client helper: `ui/client_tabs.zig` (bind, double-buffered commit, event
  vtable `select/close/new/move/leading`) so Files adds no protocol code.

## Look: differences from the mockup

* Icon, then tabs, then `+`, then the window controls: needs the leading slot.
* The mockup shows a close button only on the active tab; the compositor paints
  one on every tab today. The rule above (active and hovered) matches the mockup.
* The active tab has an accent top bar in the mockup; the compositor's tab uses
  the taskbar chip look. Decide whether the strip keeps the chip look (matches
  the taskbar) or gets a dedicated tab look (matches the mockup); it is a
  `chip_style.look` call either way.
* Tab width: one constant pair for everything (the compositor's 170/85 scaled by
  density) instead of the Editor's 176/112 px.

## Files, later

`App` holds every piece of per-folder state directly (`items`, `history`,
`loading`, `active_request_id`, selection, scroll, `sort_mode`, `list_view`,
column widths, ...). Tabs need a per-tab view. Proposal: each tab keeps only
path, history, sort, scroll and selection and re-lists on activation; only the
active tab owns `items` and the worker request. That avoids N watchers, N
workers and N thumbnail caches. Tab title is the folder name; `icon_name` is the
folder icon. This touches `files/app.zig` and the retained-hover paths that other
branches are changing, so it should start from whichever branch those land on.

## Phases and gates

1. **Hoist** model/geometry/hit/hash/`Drag` into `ui/widgets/title_tabs.zig`, add
   its tests. Gate: the existing `chrome_tests.zig` tab raster test
   (`"tab title updates preserve neighbouring pixels and match a full raster"`)
   and the window-tabs integration suites pass unchanged; compositor output is
   byte-identical.
2. **Protocol and compositor**: XML, `titlebar_tabs.zig`, strip source, click,
   hover, wheel, drag, IPC exposure. Gate: a headless test client publishes a
   strip and drives select/close/new/move through the IPC harness.
3. **Editor** on the helper. Gate: `zig build test` (editor roots), editor
   integration suites, a drafts-order test for `move`, manual SSD and
   `REDIWM_EDITOR_FORCE_CSD` runs.
4. **CSD fallback via the toolkit** (Cairo painter, chip look moved to `ui`).
5. **Files** per-tab view, then publish through the same helper.

Before finishing each phase: Debug and `-Doptimize=ReleaseSafe` builds, `zig build
test`, and the integration tests for what was touched (root `AGENTS.md`).

## Risks and open questions

* Latency: select and close round-trip through the app. At one commit per
  change this should be under a frame, but a busy app (large file save) delays
  the highlight. If it shows, the compositor can highlight optimistically until
  the next commit.
* Trust: any client may bind the global, but a strip is only ever drawn in that
  client's own titlebar, like its title. Bounds above cover memory.
* Third-party apps (browsers) could use the same protocol later; v1 is kept
  small enough for that.
* Open: keep the chip look or add a tab look; whether `modified` should also tint
  the tab; whether double-click on empty strip space should still maximize (it
  does today, since only tabs and buttons count as controls).

## Phase 2c notes

* Drag state lives on `Toplevel.tab_drag`; `Input.tab_drag` only records which
  window is pressed. A press decides nothing: release selects (no travel) or
  sends `move` (travel past 4 px). A drag never also selects.
* After release the dragged tab snaps back until the app commits the new
  order (one frame of flicker; an optimistic preview can come later if latency
  shows).
* Middle click on a published tab sends `close`.
* IPC exposure of published tabs is deferred.
