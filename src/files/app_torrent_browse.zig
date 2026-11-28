//! A torrent browsed like a folder: entering a `.torrent` file, or the row a
//! download keeps in its destination folder, lists the torrent's files as
//! ghosts. Each row has a checkbox: ticked means downloading, and a folder's
//! ticks everything inside it (or shows a dash while only part of it is).
//! An unticked file is faint, a ticked one fills with its progress, and a
//! finished one is a real file that opens. Unticking keeps what came.
//!
//! The location is the torrent file's path (or, for a download without one,
//! a magnet's, its destination folder plus the transfer id), with the folder
//! inside the torrent after it; `History.torrent` marks the prefix, as
//! `archive_len` does for archives. Nothing is read from disk: a torrent
//! file is looked into by the helper (`inspect`, which adds nothing), a
//! download's files come from its `files` replies. The first tick of a
//! torrent file adds it, downloading into the folder the file is in.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const checkbox = @import("ui").widgets.checkbox;
const header = @import("header.zig");
const torrents = @import("torrents.zig");
const tree = @import("torrent_tree.zig");
const ViewItem = @import("app_model.zig").ViewItem;
const draw = @import("app_draw.zig");
const mimeIcon = @import("worker_scan.zig").mimeIcon;

pub const Phase = enum {
    /// Waiting for the helper's look into the torrent file.
    inspecting,
    /// A magnet still fetching its file list.
    fetching,
    ready,
    failed,
};

pub const Browse = struct {
    allocator: std.mem.Allocator,
    /// Owned: the location prefix this browse is for.
    root: []u8,
    phase: Phase = .inspecting,
    id_buf: [64]u8 = undefined,
    id_len: u8 = 0,
    /// The file list and its strings.
    arena: std.heap.ArenaAllocator,
    files: []const torrents.Entry = &.{},
    name: []const u8 = "",
    /// The folder every file is in, which browsing starts inside.
    base: []const u8 = "",
    wanted: tree.Wanted = .empty,
    /// `files` requests on their way; replies to those asked before the
    /// last change of ticks carry the old ticks.
    inflight: u32 = 0,
    stale: u32 = 0,
    /// Ticks changed while the torrent file was being added.
    dirty: bool = false,
    /// An `add` is on its way.
    adding: bool = false,
    requested_at: i64 = 0,
    seen_reply: u64 = 0,
    seen_error: u64 = 0,
    seen_generation: u64 = 0,
    failure_buf: [256]u8 = undefined,
    failure_len: usize = 0,

    pub fn create(allocator: std.mem.Allocator, root: []const u8) !*Browse {
        const self = try allocator.create(Browse);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .root = try allocator.dupe(u8, root), .arena = .init(allocator) };
        return self;
    }

    pub fn destroy(self: *Browse) void {
        self.arena.deinit();
        self.allocator.free(self.root);
        self.allocator.destroy(self);
    }

    pub fn id(self: *const Browse) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    fn setId(self: *Browse, value: []const u8) void {
        const n: u8 = @intCast(@min(value.len, self.id_buf.len));
        @memcpy(self.id_buf[0..n], value[0..n]);
        self.id_len = n;
    }

    /// Takes a copy of `list`; with `ticks`, its wanted flags too.
    pub fn take(self: *Browse, list: torrents.Listing, ticks: bool) !void {
        var next: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer next.deinit();
        const mem = next.allocator();
        const files = try mem.alloc(torrents.Entry, list.files.len);
        for (list.files, files) |f, *copy| copy.* = .{ .index = f.index, .path = try mem.dupe(u8, f.path), .size = f.size, .done = f.done, .wanted = f.wanted };
        const name = try mem.dupe(u8, if (list.name.len > 0) list.name else self.name);
        self.arena.deinit();
        self.arena = next;
        self.files = files;
        self.name = name;
        self.base = tree.base(files);
        if (self.name.len == 0) self.name = self.base;
        if (ticks) {
            self.wanted = .empty;
            for (files) |f| if (f.wanted and f.index < tree.max_files) self.wanted.set(f.index);
        }
    }

    fn fail(self: *Browse, message: []const u8) void {
        const n = @min(message.len, self.failure_buf.len);
        @memcpy(self.failure_buf[0..n], message[0..n]);
        self.failure_len = n;
        self.phase = .failed;
    }

    pub fn failure(self: *const Browse) []const u8 {
        return self.failure_buf[0..self.failure_len];
    }
};

/// Whether the folder shown is inside a torrent.
pub fn active(self: *const App) bool {
    return self.history.torrent and self.history.archive_len > 0;
}

fn current(self: *App) ?*Browse {
    if (!active(self)) return null;
    const b = self.torrent_browse orelse return null;
    return if (std.mem.eql(u8, b.root, self.history.current[0..self.history.archive_len])) b else null;
}

/// The folder shown, relative to the torrent's top.
fn folder(self: *const App) []const u8 {
    const rest = self.history.current[self.history.archive_len..];
    return std.mem.trimStart(u8, rest, "/");
}

/// Enters the torrent file at `path`.
pub fn browseTorrent(self: *App, path: []const u8) void {
    self.startTorrents();
    self.rememberView();
    self.history.navigateTorrent(path) catch return;
    self.worker.recordOpened(path);
    self.applyHistoryNav(self.history.current);
}

/// The location of a download: its torrent file, else a name in its
/// destination folder that only this browse knows.
fn rootOf(t: torrents.Transfer, buf: []u8) ?[]const u8 {
    if (t.source.len > 0 and t.source[0] == '/') return t.source;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ t.download_directory, t.id }) catch null;
}

/// Enters download `id`'s files.
pub fn browseTransfer(self: *App, transfer_id: []const u8) bool {
    for (self.torrents.items()) |t| if (std.mem.eql(u8, t.id, transfer_id)) {
        var buf: [4200]u8 = undefined;
        const root = rootOf(t, &buf) orelse return false;
        self.rememberView();
        self.history.navigateTorrent(root) catch return false;
        self.applyHistoryNav(self.history.current);
        return true;
    };
    return false;
}

/// A window opened for a download shows it once its connection lists it.
pub fn stepPending(self: *App) void {
    const id = self.browse_pending orelse return;
    if (self.torrents.snapshot == null) return;
    self.browse_pending = null;
    defer self.allocator.free(id);
    if (!browseTransfer(self, id)) self.setStatusNotice(tr("This download is no longer available"), true);
}

/// The download this browse is (once added), from the latest snapshot.
fn transfer(self: *App, b: *const Browse) ?torrents.Transfer {
    for (self.torrents.items()) |t| {
        if (b.id_len > 0 and std.mem.eql(u8, t.id, b.id())) return t;
        var buf: [4200]u8 = undefined;
        if (rootOf(t, &buf)) |root| if (std.mem.eql(u8, root, b.root)) return t;
    }
    return null;
}

/// `applyHistoryNav` entered a torrent location: keeps the browse when it
/// is the same torrent, else starts one.
pub fn enter(self: *App) void {
    if (current(self) != null) return request(self);
    if (self.torrent_browse) |old| old.destroy();
    self.torrent_browse = Browse.create(self.allocator, self.history.current[0..self.history.archive_len]) catch null;
    const b = self.torrent_browse orelse return;
    b.seen_reply = self.torrents.reply_generation;
    b.seen_error = self.torrents.error_generation;
    if (transfer(self, b)) |t| {
        b.setId(t.id);
        // The files come with the first reply.
        b.phase = if (t.metadata) .inspecting else .fetching;
        b.name = b.arena.allocator().dupe(u8, t.name) catch "";
        self.updateTitle();
    } else if (!self.torrents.send(.{ .op = "inspect", .source = b.root })) {
        // Not connected yet: `step` asks once it is.
        b.requested_at = 0;
    } else b.requested_at = draw.nowMs();
    request(self);
}

/// Leaving the torrent: the browse goes with it.
pub fn leave(self: *App) void {
    if (active(self)) return;
    if (self.torrent_browse) |b| b.destroy();
    self.torrent_browse = null;
}

/// Asks for the download's files: once on entering, then as snapshots come.
fn request(self: *App) void {
    const b = current(self) orelse return;
    const t = transfer(self, b) orelse return;
    if (!t.metadata) return;
    if (self.torrents.send(.{ .op = "files", .id = t.id })) {
        b.inflight += 1;
        b.requested_at = draw.nowMs();
    }
}

/// Once a loop: takes replies, errors and snapshots in.
pub fn step(self: *App) void {
    const b = current(self) orelse return;
    const client = &self.torrents;
    if (client.error_generation != b.seen_error) {
        b.seen_error = client.error_generation;
        if (b.phase == .inspecting) {
            b.fail(client.message());
            self.rebuildView();
        } else if (b.adding) {
            // `stepTorrents` shows why.
            b.adding = false;
            b.dirty = false;
            self.invalidate();
        }
    }
    if (client.reply_generation != b.seen_reply) {
        b.seen_reply = client.reply_generation;
        if (client.reply) |reply| takeReply(self, b, reply.value);
    }
    const t = transfer(self, b) orelse {
        // Not connected when entering: look now.
        if (b.phase == .inspecting and b.requested_at == 0 and client.fd >= 0 and client.send(.{ .op = "inspect", .source = b.root }))
            b.requested_at = draw.nowMs();
        return;
    };
    if (b.id_len == 0) b.setId(t.id);
    // A magnet's name comes with its metadata.
    if (t.metadata and t.name.len > 0 and !std.mem.eql(u8, b.name, t.name)) {
        b.name = b.arena.allocator().dupe(u8, t.name) catch b.name;
        self.updateTitle();
    }
    if (b.adding) {
        b.adding = false;
        if (b.dirty) select(self, b);
    }
    if (!t.metadata) {
        if (b.phase != .fetching) {
            b.phase = .fetching;
            self.rebuildView();
        }
        return;
    }
    if (client.generation != b.seen_generation) {
        b.seen_generation = client.generation;
        // Snapshots come every second while it runs; a reply a second.
        if (b.inflight == 0 or draw.nowMs() - b.requested_at > 5000) {
            // Lost replies are not coming: neither are their old ticks.
            b.inflight = 0;
            b.stale = 0;
            request(self);
        }
    }
}

fn takeReply(self: *App, b: *Browse, reply: torrents.Snapshot) void {
    if (reply.inspect) |list| {
        if (b.phase != .inspecting or !std.mem.eql(u8, list.source, b.root)) return;
        b.take(list, false) catch return;
        b.setId(list.id);
        b.phase = .ready;
        self.updateTitle();
        // Added already, under another path: its ticks come with `files`.
        request(self);
        self.rebuildView();
        return;
    }
    const list = reply.detail orelse return;
    if (b.id_len == 0 or !std.mem.eql(u8, list.id, b.id())) return;
    b.inflight -|= 1;
    const ticks = b.stale == 0 and !b.dirty;
    b.stale -|= 1;
    const shape = sameShape(b.files, list.files);
    b.take(list, ticks) catch return;
    b.phase = if (list.metadata) .ready else .fetching;
    if (shape) refreshRows(self, b) else self.rebuildView();
}

fn sameShape(a: []const torrents.Entry, b: []const torrents.Entry) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.index != y.index or !std.mem.eql(u8, x.path, y.path)) return false;
    return true;
}

fn fillItem(item: *ViewItem, row: tree.Child) void {
    item.is_dir = row.is_dir;
    item.bytes = row.size;
    item.missing = !row.finished;
    item.transfer_ghost = !row.finished;
    if (row.is_dir) {
        item.transfer_state = null;
        item.transfer_bytes = null;
        item.transfer_total_bytes = null;
        item.transfer_progress = if (row.check != .none and !row.finished and row.wanted_size > 0)
            @as(f64, @floatFromInt(row.wanted_done)) / @as(f64, @floatFromInt(row.wanted_size))
        else
            null;
    } else {
        const ticked = row.check == .all;
        item.transfer_state = if (row.finished) .completed else if (ticked) .copying else .pending;
        item.transfer_bytes = if (ticked) @intCast(@max(0, row.done)) else null;
        item.transfer_total_bytes = if (ticked and !row.finished) @intCast(@max(0, row.size)) else null;
        item.transfer_progress = null;
    }
}

/// Progress only: the rows keep their places, selection and scrolling.
fn refreshRows(self: *App, b: *Browse) void {
    const rows = tree.children(self.allocator, b.files, b.base, folder(self), &b.wanted) catch return;
    defer self.allocator.free(rows);
    var matched: usize = 0;
    for (self.items.items) |*item| {
        for (rows) |row| if (row.is_dir == item.is_dir and std.mem.eql(u8, row.name, item.name)) {
            fillItem(item, row);
            matched += 1;
            break;
        };
    }
    const filtered = self.search.text.items.len > 0 or self.folders_only;
    if (matched != self.items.items.len or (!filtered and rows.len != matched)) return self.rebuildView();
    self.invalidate();
}

/// The rows of the folder shown, for `rebuildView`.
pub fn appendRows(self: *App, mem: std.mem.Allocator, old: *const std.StringHashMap(ViewItem)) void {
    const b = current(self) orelse return;
    if (b.phase != .ready) return;
    const rows = tree.children(self.allocator, b.files, b.base, folder(self), &b.wanted) catch return;
    defer self.allocator.free(rows);
    for (rows) |row| {
        if (self.folders_only and !row.is_dir) continue;
        if (!@import("ui").fold.contains(row.name, self.search.text.items, .{ .turkish = i18n.isTurkish() })) continue;
        const path = std.fs.path.join(mem, &.{ self.history.current, row.name }) catch continue;
        const previous = old.get(path);
        var item: ViewItem = .{
            .name = mem.dupe(u8, row.name) catch continue,
            .path = path,
            .is_dir = row.is_dir,
            .is_symlink = false,
            .is_broken = false,
            .bytes = row.size,
            .mtime = 0,
            .icon_name = mimeIcon(row.name, row.is_dir, false, false),
            .selected = if (previous) |p| p.selected else false,
            .selection_fill = if (previous) |p| p.selection_fill else .{},
            .selection_border = if (previous) |p| p.selection_border else .{},
        };
        fillItem(&item, row);
        self.items.append(self.allocator, item) catch continue;
    }
}

/// What the empty view says instead of "This folder is empty".
pub fn emptyText(self: *App) ?[]const u8 {
    const b = current(self) orelse return null;
    return switch (b.phase) {
        .inspecting => tr("Reading torrent…"),
        .fetching => tr("Fetching file list…"),
        .failed => b.failure(),
        .ready => null,
    };
}

/// The breadcrumb of the torrent itself: its name.
pub fn crumbLabel(self: *App, fallback: []const u8) []const u8 {
    const b = current(self) orelse return fallback;
    return if (b.name.len > 0) b.name else fallback;
}

/// The status bar: what is ticked, of how much, and where it goes.
pub fn statusText(self: *App, buf: []u8) ?[]const u8 {
    const b = current(self) orelse return null;
    if (b.phase != .ready) return emptyText(self);
    const totals = tree.totals(b.files, &b.wanted);
    var size_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    var done_buf: [32]u8 = undefined;
    const t = transfer(self, b);
    const into = if (t) |x| x.download_directory else std.fs.path.dirname(b.root) orelse "/";
    if (totals.ticked == 0) return i18n.fmt(buf, i18n.trn("{count} file · {size} · tick files to download them into {path}", "{count} files · {size} · tick files to download them into {path}", totals.files), .{
        .count = totals.files,
        .size = draw.formatSize(totals.size, &total_buf),
        .path = into,
    }) catch null;
    return i18n.fmt(buf, i18n.trn("{count} of {total} file ticked · {done} of {size} · into {path}", "{count} of {total} files ticked · {done} of {size} · into {path}", totals.files), .{
        .count = totals.ticked,
        .total = totals.files,
        .done = draw.formatSize(totals.wanted_done, &done_buf),
        .size = draw.formatSize(totals.wanted_size, &size_buf),
        .path = into,
    }) catch null;
}

/// Row `index`'s path inside the torrent, relative to its top.
fn member(self: *App, index: usize) ?[]const u8 {
    if (index >= self.items.items.len) return null;
    const path = self.items.items[index].path;
    const top = self.history.archive_len;
    if (path.len <= top + 1) return null;
    return path[top + 1 ..];
}

/// Space: ticks every selected row, or unticks them when all are ticked.
pub fn toggleSelected(self: *App) bool {
    const b = current(self) orelse return false;
    if (b.phase != .ready) return false;
    var all = true;
    var any = false;
    for (self.items.items, 0..) |item, i| {
        if (!item.selected) continue;
        const m = member(self, i) orelse continue;
        any = true;
        all = all and tree.check(b.files, b.base, m, &b.wanted) == .all;
    }
    if (!any) {
        const index = self.focused_index orelse return true;
        return toggleItem(self, index);
    }
    for (self.items.items, 0..) |item, i| {
        if (!item.selected) continue;
        _ = tree.set(b.files, b.base, member(self, i) orelse continue, !all, &b.wanted);
    }
    changed(self, b);
    return true;
}

/// A click on row `index`'s checkbox.
pub fn toggleItem(self: *App, index: usize) bool {
    const b = current(self) orelse return false;
    if (b.phase != .ready) return false;
    const m = member(self, index) orelse return false;
    if (!tree.toggle(b.files, b.base, m, &b.wanted)) return false;
    changed(self, b);
    return true;
}

fn changed(self: *App, b: *Browse) void {
    if (transfer(self, b) != null) select(self, b) else if (b.adding) {
        b.dirty = true;
    } else add(self, b);
    refreshRows(self, b);
}

fn chosen(b: *const Browse, out: *[tree.max_files]usize) []usize {
    var n: usize = 0;
    for (b.files) |f| if (f.index < tree.max_files and b.wanted.isSet(f.index)) {
        out[n] = f.index;
        n += 1;
    };
    return out[0..n];
}

fn select(self: *App, b: *Browse) void {
    var buf: [tree.max_files]usize = undefined;
    b.dirty = false;
    if (!self.torrents.send(.{ .op = "select", .id = b.id(), .files = chosen(b, &buf) }))
        return self.setStatusNotice(self.torrents.message(), true);
    b.stale = b.inflight;
    request(self);
}

/// The first tick of a torrent file: add it, downloading what is ticked
/// into the folder it is in.
fn add(self: *App, b: *Browse) void {
    var buf: [tree.max_files]usize = undefined;
    const files = chosen(b, &buf);
    if (files.len == 0) return;
    const destination = std.fs.path.dirname(b.root) orelse return;
    if (!self.torrents.send(.{ .op = "add", .source = b.root, .destination = destination, .files = files }))
        return self.setStatusNotice(self.torrents.message(), true);
    b.adding = true;
    self.setStatusNotice(tr("Starting download…"), false);
}

/// Opens row `index`: a folder of the torrent, or a file that has arrived.
/// Whether the row was the torrent's.
pub fn activate(self: *App, index: usize) bool {
    const b = current(self) orelse return false;
    if (index >= self.items.items.len) return true;
    const item = self.items.items[index];
    if (item.is_dir) {
        self.navigate(item.path);
        return true;
    }
    const m = member(self, index) orelse return true;
    const t = transfer(self, b) orelse {
        self.setStatusNotice(tr("Tick the file to download it"), false);
        return true;
    };
    if (item.missing) {
        self.setStatusNotice(if (tree.check(b.files, b.base, m, &b.wanted) == .all) tr("Still downloading") else tr("Tick the file to download it"), false);
        return true;
    }
    const path = if (b.base.len > 0)
        std.fs.path.join(self.allocator, &.{ t.storage, b.base, m }) catch return true
    else
        std.fs.path.join(self.allocator, &.{ t.storage, m }) catch return true;
    defer self.allocator.free(path);
    _ = self.openFile(path);
    return true;
}

// Checkboxes: in front of the icon in a list, at a card's top right corner.

/// How far a list row's icon and name move right for the checkbox.
pub fn listInset(self: *const App) f64 {
    return if (active(self) and self.list_view) 28 else 0;
}

/// What a grid card's name gives up for the checkbox in its corner.
pub fn gridCheckRoom(self: *const App) f64 {
    return if (active(self) and !self.list_view) checkbox.box_size + 8 else 0;
}

pub fn checkRect(self: *App, index: usize) ?header.Rect {
    if (!active(self) or index >= self.items.items.len) return null;
    const icon = self.itemIconRect(@intCast(index));
    const size: f64 = checkbox.box_size;
    if (self.list_view) return .{ .x = icon.x - 26, .y = icon.y + (icon.h - size) / 2, .w = size, .h = size };
    const cols = self.columns();
    const col: i32 = @intCast(@mod(@as(i32, @intCast(index)), cols));
    const right: f64 = @as(f64, @floatFromInt(self.sidebarWidth() + self.itemLeftInset() + (col + 1) * self.cellWidth() - 20)) - self.horizontalOffset();
    return .{ .x = right - size - 8, .y = icon.y, .w = size, .h = size };
}

pub fn checkHit(self: *App, x: f64, y: f64) ?usize {
    if (!active(self) or self.dialog != null or self.menu != null) return null;
    const index = self.itemAt(x, y) orelse return null;
    const r = checkRect(self, index) orelse return null;
    // A little slack around the square.
    return if (x >= r.x - 4 and x < r.x + r.w + 4 and y >= r.y - 4 and y < r.y + r.h + 4) index else null;
}

pub fn renderCheck(self: *App, cr: *c.cairo_t, index: usize) void {
    const b = current(self) orelse return;
    const r = checkRect(self, index) orelse return;
    const m = member(self, index) orelse return;
    const state = tree.check(b.files, b.base, m, &b.wanted);
    var layer = ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse return;
    defer layer.finish();
    var palette = theme.shellPalette();
    palette.fg = theme.global.window_fg;
    layer.renderer.palette = palette;
    checkbox.paint(&layer.renderer, layer.local(), "", .{
        .checked = state == .all,
        .mixed = state == .some,
    });
}

pub fn checkClick(self: *App, x: f64, y: f64) bool {
    const index = checkHit(self, x, y) orelse return false;
    self.last_click_index = null;
    self.last_click_time = 0;
    return toggleItem(self, index);
}
