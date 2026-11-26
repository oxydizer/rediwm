//! The window's side of per-folder views (`folder_views.zig`): entering a
//! folder takes its remembered grid/list choice, sort and folders-first, or the
//! defaults; changing one of them while in the folder remembers it there. Only
//! what differs from the defaults is kept, so a folder put back to the default
//! follows later changes of the default again.

const App = @import("app.zig").App;
const Sort = @import("app_model.zig").Sort;
const View = @import("folder_views.zig").View;

const Resolved = struct { list: bool, sort: Sort, folders_first: bool };

fn defaults(self: *const App) Resolved {
    return .{
        .list = self.default_list_view,
        // Recent lists newest first unless told otherwise.
        .sort = if (self.isRecent()) .modified else self.default_sort,
        .folders_first = self.default_folders_first,
    };
}

fn resolve(self: *const App, view: View) Resolved {
    const base = defaults(self);
    return .{
        .list = view.list orelse base.list,
        .sort = if (view.sort) |s| @fromBackingInt(@as(u3, @intCast(s))) else base.sort,
        .folders_first = view.folders_first orelse base.folders_first,
    };
}

fn stored(self: *const App) View {
    const store = self.folder_views orelse return .{};
    return store.get(self.history.current);
}

/// What the window shows now, as the user chose it: a repository's forced list
/// view does not count.
fn current(self: *const App) Resolved {
    return .{
        .list = self.non_git_list_view orelse self.list_view,
        .sort = self.effectiveSort(),
        .folders_first = self.folders_first,
    };
}

/// Takes the current folder's view. Called while entering a folder, before its
/// listing arrives; the listing's `syncGitLayout` then forces a repository's
/// list view on top. A file chooser keeps its own list view.
pub fn applyFolderView(self: *App) void {
    if (self.folder_views) |store| self.folder_views_seen = store.generation;
    const view = resolve(self, stored(self));
    if (self.chooser == null) {
        self.non_git_list_view = null;
        self.list_view = view.list;
    }
    self.setSort(view.sort);
    self.folders_first = view.folders_first;
}

/// Remembers the current folder's view after the user changed part of it.
pub fn recordFolderView(self: *App) void {
    const store = self.folder_views orelse return;
    const base = defaults(self);
    const now = current(self);
    const view: View = .{
        // A chooser's list view is not a choice the folder should keep.
        .list = if (self.chooser != null) stored(self).list else if (now.list != base.list) now.list else null,
        .sort = if (now.sort != base.sort) @backingInt(now.sort) else null,
        .folders_first = if (now.folders_first != base.folders_first) now.folders_first else null,
    };
    store.set(self.history.current, view);
    self.folder_views_seen = store.generation;
}

pub fn folderViewIsDefault(self: *const App) bool {
    return stored(self).isEmpty();
}

/// Forgets the current folder's view; it follows the defaults again.
pub fn resetFolderView(self: *App) void {
    const store = self.folder_views orelse return;
    store.set(self.history.current, .{});
    refreshFolderView(self);
}

/// Another window changed a folder's view, or a default changed: shows the
/// current folder as it should look now.
pub fn syncFolderView(self: *App) void {
    const store = self.folder_views orelse return;
    if (store.generation == self.folder_views_seen) return;
    self.folder_views_seen = store.generation;
    const want = resolve(self, stored(self));
    const now = current(self);
    if (want.list == now.list and want.sort == now.sort and want.folders_first == now.folders_first) return;
    refreshFolderView(self);
}

/// The default folders-first setting changed (Control Center).
pub fn setDefaultFoldersFirst(self: *App, on: bool) void {
    if (self.default_folders_first == on) return;
    const before = current(self);
    self.default_folders_first = on;
    if (resolve(self, stored(self)).folders_first != before.folders_first) refreshFolderView(self);
}

fn refreshFolderView(self: *App) void {
    applyFolderView(self);
    self.syncGitLayout();
    self.last_click_index = null;
    self.rebuildView();
    self.clampScroll();
    if (self.focused_index) |idx| self.revealIndex(idx);
    self.invalidate();
}
