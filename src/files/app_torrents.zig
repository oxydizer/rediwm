//! Torrents in a window: the connection to the transfer helper, adding a
//! torrent or magnet, and a download's pause and resume. A download's files
//! are a folder (`app_torrent_browse.zig`); its progress is in the shell's
//! Transfers panel. The helper owns session lifetime; closing this window
//! only closes its subscription.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const Transfer = @import("torrents.zig").Transfer;
const draw = @import("app_draw.zig");

/// Torrents on or off as a whole: off, there is no sidebar entry, no helper
/// started, no dialogs, and a torrent file is a plain file.
pub const enabled = true;

pub fn startTorrents(self: *App) void {
    if (!enabled) return;
    if (self.chooser != null or self.torrents.fd >= 0 or self.torrents.retry_at != null) return;
    const runtime = self.environ.getPosix("XDG_RUNTIME_DIR") orelse return;
    if (self.torrents.connect(runtime)) return;
    var path: [4096]u8 = undefined;
    const executable = self.terminalHelper("rediwm-transfers", &path) catch return;
    var child = std.process.spawn(self.io, .{ .argv = &.{ executable, if (self.terminalScopes()) "--scope" else "--no-scope" } }) catch {
        self.torrents.fail(tr("Could not start Transfers"));
        return;
    };
    self.children.add(self.allocator, child.id.?) catch child.kill(self.io);
    self.torrents.attempts = 0;
    self.torrents.retry_at = draw.nowMs() + 100;
}
pub fn stepTorrents(self: *App) void {
    // The helper answers this window's own requests with errors only:
    // each one says why something it asked for did not happen.
    if (self.torrents.error_generation != self.torrent_errors_seen) {
        self.torrent_errors_seen = self.torrents.error_generation;
        self.setStatusNotice(self.torrents.message(), true);
    }
    const at = self.torrents.retry_at orelse return;
    if (draw.nowMs() < at) return;
    const runtime = self.environ.getPosix("XDG_RUNTIME_DIR") orelse return;
    if (self.torrents.connect(runtime)) {
        self.invalidate();
        return;
    }
    self.torrents.attempts += 1;
    if (self.torrents.attempts >= 40) {
        self.torrents.retry_at = null;
        self.torrents.fail(tr("Could not connect to Transfers"));
        self.invalidate();
    } else self.torrents.retry_at = draw.nowMs() + 100;
}
pub fn torrentSource(self: *App, source: ?[]const u8) void {
    if (!enabled) return;
    if (self.chooser != null) return;
    self.startTorrents();
    self.closeDialog();
    self.dialog = .{ .kind = if (source != null) .torrent_destination else .torrent_source, .title = if (source != null) tr("Download to folder") else tr("Torrent file or magnet link") };
    if (source) |s| {
        self.dialog.?.target_path = self.allocator.dupe(u8, s) catch {
            self.closeDialog();
            return;
        };
        const destination = if (self.isRecent() or self.history.archive_len > 0) self.home_dir else self.history.current;
        self.dialog.?.edit.text.appendSlice(self.allocator, destination) catch {};
    }
    self.dialog.?.edit.cursor = self.dialog.?.edit.text.items.len;
    self.dialog.?.edit.select_all = true;
    self.invalidate();
}
/// New Torrent…: a magnet link pasted here downloads into the folder shown.
pub fn newTorrent(self: *App) void {
    if (!enabled or self.chooser != null) return;
    if (self.isRecent() or self.history.archive_len > 0 or self.trashReadOnly()) return;
    self.startTorrents();
    self.closeDialog();
    self.dialog = .{ .kind = .torrent_source, .title = tr("New Torrent") };
    self.invalidate();
}
pub fn confirmTorrent(self: *App) void {
    const dlg = self.dialog orelse return;
    const value = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
    if (value.len == 0) return;
    if (dlg.kind == .torrent_source) {
        // A torrent file's path opens it as a folder instead.
        if (value[0] == '/' and std.ascii.endsWithIgnoreCase(value, ".torrent")) {
            const path = self.allocator.dupe(u8, value) catch return;
            defer self.allocator.free(path);
            self.closeDialog();
            self.browseTorrent(path);
            return;
        }
        if (!std.mem.startsWith(u8, value, "magnet:?"))
            return self.setStatusNotice(tr("Paste a magnet link (magnet:?…)"), true);
        // It shows up here as a folder that has not materialized yet.
        if (!self.torrents.send(.{ .op = "add", .source = value, .destination = self.history.current }))
            return self.setStatusNotice(self.torrents.message(), true);
        self.closeDialog();
        self.setStatusNotice(tr("Adding download…"), false);
    } else if (self.torrents.send(.{ .op = "add", .source = dlg.target_path orelse "", .destination = value })) {
        // It shows up there as a folder that has not materialized yet.
        const destination = self.allocator.dupe(u8, value) catch return;
        defer self.allocator.free(destination);
        self.closeDialog();
        self.navigate(destination);
    } else self.setStatusNotice(self.torrents.message(), true);
}
pub fn toggleTorrent(self: *App, t: Transfer) void {
    if (t.pending) {
        self.openTorrentDetails(t.id);
        return;
    }
    _ = self.torrents.send(.{ .op = if (t.paused) @as([]const u8, "resume") else "pause", .id = t.id });
    self.invalidate();
}

pub fn openTorrentDetails(self: *App, id: []const u8) void {
    // Its files, as a folder, are the details.
    _ = self.browseTransfer(id);
}
