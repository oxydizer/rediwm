//! Folder tabs. The active tab's folder lives in the `App` as always (`history`,
//! `sort_mode`, the listing); a tab only keeps what it needs to be brought back:
//! its `History` (current folder, back and forward stacks, and the scroll and
//! selection each entry remembers) and its sort. Switching parks the active
//! folder in its tab, takes the other tab's, and lists it again. No second
//! listing, worker or watcher exists: only the active tab owns `items`.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const app_mod = @import("app.zig");
const App = app_mod.App;
const history_mod = @import("history.zig");
const Sort = @import("app_model.zig").Sort;
const recent = @import("recent.zig");

/// The most tabs the strip carries (the protocol's limit).
pub const max_tabs = 128;

pub const FolderTab = struct {
    id: usize,
    /// Null for the active tab: its history is `App.history`.
    history: ?history_mod.History = null,
    sort: Sort = .name,
};

/// The first tab exists as soon as anything asks about tabs.
pub fn ensureTabs(self: *App) void {
    if (self.tabs.items.len > 0) return;
    const tab = self.allocator.create(FolderTab) catch return;
    tab.* = .{ .id = self.tab_next_id };
    self.tab_next_id += 1;
    self.tabs.append(self.allocator, tab) catch {
        self.allocator.destroy(tab);
        return;
    };
    self.tab_selected = 0;
}

pub fn deinitTabs(self: *App) void {
    for (self.tabs.items) |tab| {
        if (tab.history) |*history| history.deinit();
        self.allocator.destroy(tab);
    }
    self.tabs.deinit(self.allocator);
}

fn folderName(self: *const App, path: []const u8) []const u8 {
    if (recent.isLocation(path)) return tr("Recent");
    if (self.trash_dir) |trash| if (std.mem.eql(u8, path, trash)) return tr("Trash");
    if (std.mem.eql(u8, path, "/")) return "/";
    return std.fs.path.basename(path);
}

/// The icon-theme name of tab `i`'s folder icon.
pub fn tabIcon(self: *const App, i: usize) []const u8 {
    const tab = self.tabs.items[i];
    const path = if (tab.history) |history| history.current else self.history.current;
    if (recent.isLocation(path)) return "document-open-recent";
    if (self.trash_dir) |trash| if (std.mem.eql(u8, path, trash)) return "user-trash";
    if (std.mem.eql(u8, path, self.home_dir)) return "user-home";
    return "folder";
}

/// What tab `i` is called: its folder's name.
pub fn tabTitle(self: *const App, i: usize) []const u8 {
    const tab = self.tabs.items[i];
    if (tab.history) |history| return folderName(self, history.current);
    if (self.transfer_view.active) return tr("Transfers");
    return folderName(self, self.history.current);
}

pub fn findTab(self: *const App, id: usize) ?usize {
    for (self.tabs.items, 0..) |tab, i| if (tab.id == id) return i;
    return null;
}

/// Parks the active folder in its tab.
fn park(self: *App) void {
    const tab = self.tabs.items[self.tab_selected];
    self.rememberView();
    tab.history = self.history;
    tab.sort = self.sort_mode;
}

/// Takes tab `i`'s folder as the active one and lists it.
fn activate(self: *App, i: usize) void {
    const tab = self.tabs.items[i];
    self.history = tab.history.?;
    tab.history = null;
    self.sort_mode = tab.sort;
    self.tab_selected = i;
    self.applyHistoryNav(self.history.current);
}

pub fn switchTab(self: *App, i: usize) void {
    ensureTabs(self);
    if (i >= self.tabs.items.len or i == self.tab_selected) return;
    park(self);
    activate(self, i);
}

/// Steps to the next (or previous) tab, wrapping.
pub fn stepTabs(self: *App, forward: bool) void {
    ensureTabs(self);
    const n = self.tabs.items.len;
    if (n < 2) return;
    switchTab(self, if (forward) (self.tab_selected + 1) % n else (self.tab_selected + n - 1) % n);
}

/// A tab beside the active one, showing the same folder. An archive's inside
/// cannot be reopened that way, so a tab made there starts at home.
pub fn newTab(self: *App) void {
    const start = if (self.history.archive_len > 0 or recent.isLocation(self.history.current)) self.home_dir else self.history.current;
    openTab(self, start, true);
}

/// A tab on `path`, beside the active one; `activate` switches to it, else it
/// opens in the background like a browser's middle click.
pub fn openTab(self: *App, path: []const u8, activate_it: bool) void {
    ensureTabs(self);
    if (self.tabs.items.len >= max_tabs or self.chooser != null) return;
    var history = history_mod.History.init(self.allocator, path) catch return;
    const tab = self.allocator.create(FolderTab) catch {
        history.deinit();
        return;
    };
    tab.* = .{ .id = self.tab_next_id, .history = history, .sort = self.sort_mode };
    const at = self.tab_selected + 1;
    self.tabs.insert(self.allocator, at, tab) catch {
        history.deinit();
        self.allocator.destroy(tab);
        return;
    };
    self.tab_next_id += 1;
    // `at` is after the active tab, so the selection index has not moved.
    if (activate_it) switchTab(self, at) else self.invalidate();
}

/// Closes tab `i`; the last tab closes the window.
pub fn closeTab(self: *App, i: usize) void {
    ensureTabs(self);
    if (i >= self.tabs.items.len) return;
    if (self.tabs.items.len == 1) {
        self.closed = true;
        return;
    }
    const tab = self.tabs.items[i];
    if (i != self.tab_selected) {
        if (tab.history) |*history| history.deinit();
        self.allocator.destroy(tab);
        _ = self.tabs.orderedRemove(i);
        if (i < self.tab_selected) self.tab_selected -= 1;
        self.invalidate();
        return;
    }
    // The active tab goes: its neighbour takes over.
    const next = if (i + 1 < self.tabs.items.len) i + 1 else i - 1;
    self.history.deinit();
    self.allocator.destroy(tab);
    _ = self.tabs.orderedRemove(i);
    const at = if (next > i) next - 1 else next;
    const heir = self.tabs.items[at];
    self.history = heir.history.?;
    heir.history = null;
    self.sort_mode = heir.sort;
    self.tab_selected = at;
    self.applyHistoryNav(self.history.current);
}

/// Moves tab `from` so it ends at `to`; the active tab stays active.
pub fn moveTab(self: *App, from: usize, to: usize) void {
    ensureTabs(self);
    if (from >= self.tabs.items.len or self.tabs.items.len == 0) return;
    const target = @min(to, self.tabs.items.len - 1);
    if (from == target) return;
    const active = self.tabs.items[self.tab_selected];
    const tab = self.tabs.orderedRemove(from);
    self.tabs.insertAssumeCapacity(target, tab);
    for (self.tabs.items, 0..) |t, i| if (t == active) {
        self.tab_selected = i;
    };
    self.invalidate();
}
