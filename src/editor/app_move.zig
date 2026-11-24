//! Moving a tab, with its document and undo history, from one window to
//! another. Both windows are `App`s in the same process.

const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Tab = app_mod.Tab;
const a = std.heap.c_allocator;

/// Whether this window can give a tab away or take one: nothing waiting on an
/// answer that names a tab.
pub fn movable(self: *App) bool {
    return self.operation == null and self.close_tab == null;
}

/// Removes the tab with `id` without freeing it. The selection stays on the
/// same tab where it can. A window left with no tabs is closed.
pub fn take(self: *App, id: usize) ?*Tab {
    const i = self.findTab(id) orelse return null;
    const selected_id = self.tabs.items[self.selected].id;
    const tab = self.tabs.orderedRemove(i);
    if (self.tabs.items.len == 0) {
        self.selected = 0;
        self.closed = true;
        return tab;
    }
    self.selected = self.findTab(selected_id) orelse @min(i, self.tabs.items.len - 1);
    self.changed();
    return tab;
}

/// Puts a tab taken from another window at `index` (the end if beyond it) and
/// selects it. The tab gets this window's next id: ids are per window.
pub fn adopt(self: *App, tab: *Tab, index: usize) !void {
    const at = @min(index, self.tabs.items.len);
    try self.tabs.insert(a, at, tab);
    tab.id = self.next_id;
    self.next_id += 1;
    // Measurements belong to the window's size and scale.
    tab.measure = .{};
    self.selected = at;
    self.changed();
}

/// A window that starts with one empty tab swaps it for the one it was made
/// for.
pub fn replaceBlank(self: *App, tab: *Tab) !void {
    const blank = self.tabs.items.len == 1 and self.tabs.items[0].path == null and
        self.tabs.items[0].doc.text.items.len == 0 and !self.tabs.items[0].doc.modified();
    try adopt(self, tab, self.tabs.items.len);
    if (blank) self.tabs.orderedRemove(0).deinit();
    self.selected = self.tabs.items.len - 1;
    self.changed();
}
