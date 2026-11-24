# Plan: rediwm-editor with several windows in one process

Why: tearing a tab off into a window and merging it into another window (see
`docs/plans/titlebar-tabs.md`, phase 6) needs two editor windows that belong to
one Wayland client, because `drop_on` only names strips of the same client and
the compositor places a torn-off window by client.

## Shape

Every window is a `Client` (as before) with its own registry bindings, seat
objects, surface and `App`. What changes is only that they share one
`wl_display` connection, so the compositor sees a single client.

* The seat reports every surface of the connection to every `wl_pointer`,
  `wl_keyboard` and `text_input` of it. Each `Client` keeps only its own:
  enter and leave are filtered by surface, motion/button/axis by `inside`, keys
  by `app.focused`. Keymap, modifiers and repeat info go to all (each window
  has its own xkb state).
* Each window has its own clipboard device and IME; the selection reaches all of them.
* `main.run` owns the loop: a list of windows, one poll over the display, the
  instance socket, the drafts wake-up and each window's own file descriptors.
  A window that closes is destroyed; the process ends with the last one.
* Window creation, one loop step and teardown live in `client_lifecycle.zig`.
* The first window owns the drafts, the instance socket's requests (they go to
  the focused window) and the activation token.

## Stages

1. **One window, new structure** (this change): no behaviour change. Gate: the
   editor builds, runs, edits, saves, restores drafts and quits as before.
2. **Drafts across windows**: the keeper snapshots the tabs of every window, not
   one `App`; ownership moves to the next window when the first closes.
3. **More than one window**: a New Window action (Ctrl+Shift+N and a menu row)
   opens a window with one empty tab; closing the last tab closes that window;
   quitting the last window quits the process. Tab ids are per `App`, so a tab
   that moves gets a fresh id in its new window.
4. **Tab gestures** (titlebar tabs phase 6c): `tear_off` creates a window holding
   the tab, `drop_on` moves it to the other window; `take`/`adopt` on `App` move
   the `Tab` with its document and undo history.

## Risks

* A second `wl_seat` binding per window is allowed, but the compositor sends
  pointer events to every pointer resource of the client: the filters above are
  what keeps a click from landing in two windows. Test by clicking in window
  B while window A is open.
* `roundtrip` during window creation runs the other windows' listeners
  re-entrantly; they only update state, so this should be safe.
* Drafts (stage 2) are the real risk: a snapshot that ignores another window's
  tabs would delete their drafts.

## As built

All four stages landed on `feat/editor-multiwindow`.

1. Windows are `Client`s on one shared `wl_display`; the seat, keyboard, pointer and text-input events of every surface reach every `Client`, which filters by surface. A closing window releases its seat, keyboard, pointer, `wm_base` and frame callback first, since their listeners point at it.
2. Drafts cover every window (`app_drafts.zig` keeps the list of `App`s). Tabs are keyed by pointer, not by their per-window id. The keeper moves to another window when its owner closes.
3. New Window (Ctrl+Shift+N, menu row): one empty tab. Closing a window's last tab closes only that window; the process ends with the last window. At most 24 windows.
4. The Editor opts in to detaching (`set_detachable`). Tear-off opens a window and moves the `Tab` (document and undo history) into it; dropping on another window's strip moves it there, and an emptied window closes. Moves are refused while a dialog or a close prompt names a tab. The compositor paints a ghost tab at the pointer during a drag-out (`tab_ghost.zig`).
