# Files sidebar bookmarks

Home, Trash, and Recent stay above the separator with their current row
presentation and navigation. The rest of Places becomes an ordered list of
default and custom bookmarks. The Places header starts locked in each window.

## Source audit

- [Pin storage](../../src/files/pins.zig) keeps custom pins in order in
  `$XDG_STATE_HOME/rediwm/files-places`, one absolute path per line. The
  [Places actions](../../src/files/app_places.zig) reload that file before
  changing pins and refresh it on focus gain. Built-in rows have a fixed order
  and a separate removal bitmask in [preferences](../../src/files/preferences.zig).
- [Sidebar geometry and painting](../../src/files/app_sidebar_paint.zig)
  share the Places card layout and draw an accent insertion line for pin drops.
  Built-in destinations currently resolve to `$HOME/<name>`. The
  [icon theme code](../../src/icon_theme.zig) already reads `user-dirs.dirs`
  for special-directory icons.
- [Wayland drop handling](../../src/files/client_dnd.zig) negotiates copy and
  move, captures the destination before reading the offer, and uses the
  [I/O request path](../../src/files/app_requests.zig) to validate transfers.
  [Folder context-menu paste](../../src/files/app_menu.zig) already sends a
  destination through [clipboard handling](../../src/files/client_clipboard.zig)
  for both local and external file clipboards.

## Interaction and implementation

1. **Persist one bookmark order.** Extend `pins.zig` to store default and
   custom bookmarks with optional display labels in the existing state file.
   Continue reading legacy path-only files. Seed XDG user directory defaults,
   honor the legacy removal bitmask during migration, and append existing
   custom pins in their saved order. Preserve localized default labels and
   themed icons. Use `app_requests.zig` and `io_requests.zig` for worker-side
   storage and target checks. Serialize bookmark updates across windows and
   identify items by stable identity when applying delayed results.
2. **Add the padlock and two drag behaviors.** Update `app.zig`,
   `app_places.zig`, `app_sidebar_paint.zig`, `app_buttons.zig`, and
   `app_pointer.zig`. Give the lock its own hit area beside the header's
   accordion control. While unlocked, a sidebar-row drag reorders bookmarks
   within Places, and a file drag inserts bookmarks at the indicated gap.
   Reuse the accent insertion line for both. While locked, a file drag
   highlights a directory target and routes through the existing copy and
   move negotiation in `client_dnd.zig`. Preserve Ctrl behavior and the
   dedicated Trash drop action.
3. **Add bookmark menu actions.** Update `app_menu.zig` and `app_model.zig`
   for edit mode, rename, remove, and Paste into Folder. Reuse the text dialog
   and editor in `app_dialogs.zig` and `app_keyboard.zig`. Rename and remove
   edit bookmark records only. File bookmarks remain openable.
4. **Reuse folder transfers.** Route Paste into Folder through the existing
   folder-paste request in `client_clipboard.zig`. For locked drops and paste,
   use the existing validation, conflict handling, and transfer jobs. Report
   unavailable or unwritable directory targets through existing Files feedback.
5. **Verify persistence and interaction.** Extend pin, sidebar, menu, and
   paste tests plus [the Files drag integration](../../tests/files_drag.py).
   Cover migration, restart, reorder, rename, removal preserving the target,
   locked copy and move, modifier changes, paste, and unavailable destinations.
   Manually check both modes and run the focused Files integrations,
   `zig build`, `zig build -Doptimize=ReleaseSafe`, `zig build test`, and
   `git diff --check`.

Use the dedicated `~/Projects/rediwm-files-bookmarks` worktree on
`feat/files-bookmarks`. Its master base includes the sidebar icon changes
from #120 and the text field rendering changes from #121.
