//! File-list transfer accessories, matching and hover details.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const button = @import("ui").widgets.button;
const frame = @import("ui").widgets.dialog;
const header = @import("header.zig");
const draw = @import("app_draw.zig");
const Transfer = @import("torrents.zig").Transfer;

const ViewItem = @import("app_model.zig").ViewItem;
fn containsPath(root: []const u8, path: []const u8) bool {
    if (root.len == 0) return false;
    return std.mem.eql(u8, root, path) or (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/');
}
fn matchesPath(t: Transfer, path: []const u8) bool {
    return (t.source.len > 0 and std.mem.eql(u8, path, t.source)) or containsPath(t.storage, path) or
        (t.published and containsPath(t.destination, path));
}
pub fn torrentForItem(self: *App, index: usize) ?Transfer {
    if (self.chooser != null or self.transfer_view.active or self.history.archive_len > 0 or index >= self.items.items.len) return null;
    for (self.torrents.items()) |t| if (matchesPath(t, self.items.items[index].path)) return t;
    return null;
}
pub fn hasFolderTransfers(self: *App) bool {
    if (self.chooser != null or self.history.archive_len > 0 or self.transfer_view.active) return false;
    for (self.torrents.items()) |t| {
        if (std.mem.eql(u8, t.download_directory, self.history.current) or
            std.mem.eql(u8, std.fs.path.dirname(t.source) orelse "", self.history.current) or
            (t.published and std.mem.eql(u8, std.fs.path.dirname(t.destination) orelse "", self.history.current))) return true;
    }
    return false;
}

/// Unpublished payload stays private on disk; this is a transfer entry in
/// its destination folder. `missing` excludes it from filesystem operations.
pub fn appendTorrentRows(self: *App, mem: std.mem.Allocator, old: *const std.StringHashMap(ViewItem)) void {
    if (self.chooser != null or self.history.archive_len > 0 or self.isRecent() or self.changedOnly()) return;
    for (self.torrents.items()) |t| {
        if (t.published or t.storage.len == 0 or !std.mem.eql(u8, t.download_directory, self.history.current)) continue;
        if (!@import("ui").fold.contains(t.name, self.search.text.items, .{ .turkish = @import("i18n").isTurkish() })) continue;
        var represented = false;
        for (self.items.items) |item| if (matchesPath(t, item.path)) {
            represented = true;
            break;
        };
        if (represented) continue;
        const previous = old.get(t.storage);
        self.items.append(self.allocator, .{
            .name = mem.dupe(u8, t.name) catch continue,
            .path = mem.dupe(u8, t.storage) catch continue,
            .transfer_stub = true,
            .missing = true,
            .is_dir = true,
            .is_symlink = false,
            .is_broken = false,
            .bytes = t.total,
            .mtime = 0,
            .icon_name = "folder-download",
            .selected = if (previous) |p| p.selected else false,
            .selection_fill = if (previous) |p| p.selection_fill else .{},
            .selection_border = if (previous) |p| p.selection_border else .{},
        }) catch {};
    }
}

const InlineLayout = struct { area: header.Rect, ring: header.Rect, toggle: header.Rect };
fn inlineLayout(self: *App, index: usize) ?InlineLayout {
    if (self.torrentForItem(index) == null) return null;
    const row: i32 = @intCast(index / @as(usize, @intCast(self.columns())));
    const y: f64 = @floatFromInt(self.viewTop() + self.itemInset() + row * self.rowHeight() - self.scroll_y);
    const right: f64 = if (self.list_view) self.listColumn(0).x + self.listColumn(0).w - 4 else @as(f64, @floatFromInt(self.sidebarWidth() + 20 + (@as(i32, @intCast(index)) + 1 - row * self.columns()) * self.cellWidth() - 20)) - 8;
    const available = if (self.list_view) self.listColumn(0).w - 68 else @as(f64, @floatFromInt(self.cellWidth() - 36));
    if (available < 56) return null;
    const width: f64 = if (available >= 210) 156 else if (!self.list_view) @min(156, available) else 60;
    const top = if (self.list_view) y + (@as(f64, @floatFromInt(self.cardHeight())) - 28) / 2 else y + App.GridCard.detail_baseline - 20;
    return .{
        .area = .{ .x = right - width, .y = top, .w = width, .h = 28 },
        .ring = .{ .x = right - 58, .y = top + 2, .w = 24, .h = 24 },
        .toggle = .{ .x = right - 28, .y = top, .w = 28, .h = 28 },
    };
}
pub fn inlineTorrentWidth(self: *App, index: usize) f64 {
    return if (inlineLayout(self, index)) |layout| layout.area.w + 4 else 0;
}
fn inlineStatus(t: Transfer) []const u8 {
    if (t.@"error".len > 0) return tr("Error");
    if (t.pending) return if (t.metadata) tr("Choose files") else tr("Metadata…");
    if (t.paused) return if (t.finished) tr("Complete") else tr("Paused");
    return if (t.finished) tr("Seeding") else tr("Downloading");
}
pub fn renderInlineTorrent(self: *App, cr: *c.cairo_t, index: usize) void {
    const layout = inlineLayout(self, index) orelse return;
    const t = self.torrentForItem(index) orelse return;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, @floatFromInt(self.sidebarWidth()), @floatFromInt(self.viewTop()), @floatFromInt(self.w - self.sidebarWidth() - self.scrollbarGutter()), @floatFromInt(@max(0, self.contentBottom() - self.viewTop())));
    c.cairo_clip(cr);
    const color = if (t.@"error".len > 0) theme.global.danger else theme.shellPalette().accent;
    ui.drawProgressRing(cr, .{ .x = layout.ring.x, .y = layout.ring.y, .w = layout.ring.w, .h = layout.ring.h }, if (t.pending) 0 else @as(f64, @floatFromInt(t.progress)) / 1000000, color);
    if (layout.area.w > 64) {
        const label = inlineStatus(t);
        const width = layout.ring.x - layout.area.x - 6;
        const advance = @min(width, draw.measureText(cr, label, ui.statusSize(), false));
        draw.setSource(cr, theme.global.window_fg);
        draw.drawEllipsis(cr, label, layout.ring.x - 6 - advance, layout.area.y + 18, width, ui.statusSize(), false);
    }
    var layer = ui.Layer.begin(cr, .{ .x = @floatCast(layout.toggle.x), .y = @floatCast(layout.toggle.y), .w = 28, .h = 28 }) orelse return;
    defer layer.finish();
    const hover = self.dialog == null and self.menu == null and layout.toggle.contains(self.mouse_x, self.mouse_y);
    button.paint(&layer.renderer, layer.local(), .{ .variant = .ghost, .size = .sm, .icon = if (t.paused or t.pending) .play else .pause, .label = if (t.pending) tr("Choose files") else if (t.paused) tr("Resume") else tr("Pause") }, .{ .pointer = if (self.torrents.fd < 0) .disabled else if (hover) .hover else .idle });
}

pub const InlineHit = struct { index: usize, toggle: bool };
pub fn inlineTorrentHit(self: *App, x: f64, y: f64) ?InlineHit {
    if (self.dialog != null or self.menu != null or self.selection_band != null or self.drag_origin != null) return null;
    const index = self.itemAt(x, y) orelse return null;
    const layout = inlineLayout(self, index) orelse return null;
    if (layout.toggle.contains(x, y)) return .{ .index = index, .toggle = true };
    if (layout.ring.contains(x, y)) return .{ .index = index, .toggle = false };
    return null;
}
pub fn inlineTorrentClick(self: *App, x: f64, y: f64) bool {
    const hit = self.inlineTorrentHit(x, y) orelse return false;
    const t = self.torrentForItem(hit.index) orelse return false;
    self.last_click_index = null;
    self.last_click_time = 0;
    if (hit.toggle) self.toggleTorrent(t) else self.openTorrentDetails(t.id);
    return true;
}
pub fn renderTorrentTip(self: *App, cr: *c.cairo_t) void {
    const hover = self.hoverKey();
    if (hover == std.math.maxInt(usize) - 2001 or
        hover == std.math.maxInt(usize) - 2002) return;
    const hit = self.inlineTorrentHit(self.mouse_x, self.mouse_y) orelse return;
    if (hit.toggle) return;
    const t = self.torrentForItem(hit.index) orelse return;
    const layout = inlineLayout(self, hit.index) orelse return;
    const width: f32 = @min(360, @as(f32, @floatFromInt(self.w)) - 24);
    const height: f32 = 164;
    const x = std.math.clamp(@as(f32, @floatCast(layout.ring.x + layout.ring.w)) - width, 12, @max(12, @as(f32, @floatFromInt(self.w)) - width - 12));
    const below: f32 = @floatCast(layout.area.y + layout.area.h + 8);
    const bottom: f32 = @floatFromInt(self.contentBottom());
    const y = @max(@as(f32, @floatFromInt(self.contentTop())), if (below + height <= bottom) below else @as(f32, @floatCast(layout.area.y)) - height - 8);
    var layer = ui.Layer.begin(cr, .{ .x = x, .y = y, .w = width, .h = height }) orelse return;
    defer layer.finish();
    var palette = theme.shellPalette();
    palette.fg = theme.global.window_fg;
    layer.renderer.palette = palette;
    frame.paintFrame(&layer.renderer, layer.local());
    var progress_buf: [160]u8 = undefined;
    var rate_buf: [160]u8 = undefined;
    var peers_buf: [160]u8 = undefined;
    var known_buf: [96]u8 = undefined;
    var eta_buf: [96]u8 = undefined;
    const progress = if (t.pending) @as(i32, 0) else std.math.clamp(t.progress, 0, 1000000);
    const state = std.fmt.bufPrint(&progress_buf, "{s} · {d}.{d}%", .{ if (self.torrents.fd < 0) tr("Disconnected") else inlineStatus(t), @divTrunc(progress, 10000), @mod(@divTrunc(progress, 1000), 10) }) catch "";
    const rates = i18n.fmt(&rate_buf, tr("↓ {rate} KiB/s    ↑ {rate2} KiB/s"), .{ .rate = @divTrunc(t.download_rate, 1024), .rate2 = @divTrunc(t.upload_rate, 1024) }) catch "";
    const connected = i18n.fmt(&peers_buf, tr("Connected peers: {peers} · Seeds: {seeds}"), .{ .peers = t.peers, .seeds = t.seeds }) catch "";
    const known = i18n.fmt(&known_buf, tr("Known peers: {value}"), .{ .value = t.known_peers }) catch "";
    const eta = if (@import("torrents.zig").etaSeconds(t)) |seconds|
        if (seconds == 0) @as([]const u8, tr("ETA: Complete")) else if (seconds >= 3600) i18n.fmt(&eta_buf, tr("ETA: {value}h {value2}m"), .{ .value = @divTrunc(seconds, 3600), .value2 = @divTrunc(@mod(seconds, 3600), 60) }) catch "" else if (seconds >= 60) i18n.fmt(&eta_buf, tr("ETA: {value}m {value2}s"), .{ .value = @divTrunc(seconds, 60), .value2 = @mod(seconds, 60) }) catch "" else i18n.fmt(&eta_buf, tr("ETA: {value}s"), .{ .value = seconds }) catch ""
    else if (t.pending) tr("ETA: Choose files first") else if (t.paused) tr("ETA: Paused") else tr("ETA: Unknown · waiting for data");
    const labels = [_][]const u8{ t.name, state, rates, connected, known, eta };
    for (labels, 0..) |label, i| layer.renderer.drawText(14, 10 + @as(f32, @floatFromInt(i)) * 24, width - 28, 24, .{ .content = label, .font_size = if (i == 0) ui.textSize() else ui.statusSize(), .color = palette.fg });
}
