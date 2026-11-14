//! Transfers UI: the sidebar, main-pane list and per-transfer dialog. The helper
//! owns session lifetime; closing this window only closes its subscription.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const button = @import("ui").widgets.button;
const checkbox = @import("ui").widgets.checkbox;
const frame = @import("ui").widgets.dialog;
const Transfer = @import("torrents.zig").Transfer;
const ops_mod = @import("ops.zig");
const Rect = ui.Rect;
const draw = @import("app_draw.zig");
const transferTip = @import("app_transfer_tip.zig");
const sidebar_controls = @import("app_sidebar_controls.zig");

pub const View = struct {
    active: bool = false,
    folder_scroll: i32 = 0,
    folder_scroll_x: f64 = 0,
    folder_search_visible: bool = false,
    row: ?usize = null,
    file_page: usize = 0,
    selected: [65]u8 = @splat(0),
    choices: [512]bool = @splat(true),
    ratio: i32 = 1,
    limit: i32 = 1048576,
    focus: usize = 0,
    last_click_row: ?usize = null,
    last_click_time: i64 = 0,
    pub fn id(self: *const View) []const u8 {
        return std.mem.sliceTo(&self.selected, 0);
    }
};
/// Transfers are hidden for now: no sidebar entry, no helper started, no
/// dialogs. Flip to bring the feature back; the rest of the code is intact.
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
pub fn openTransfers(self: *App) void {
    if (!enabled) return;
    if (self.chooser != null) return;
    self.startTorrents();
    self.closeDialog();
    self.cancelWheel();
    self.cancelDrag();
    self.menu = null;
    if (!self.transfer_view.active) {
        self.rememberView();
        self.transfer_view.folder_scroll = self.scroll_y;
        self.transfer_view.folder_scroll_x = self.scroll_x;
        self.transfer_view.folder_search_visible = self.search_visible;
    }
    self.transfer_view.active = true;
    self.scroll_y = 0;
    self.search_visible = false;
    self.focus = .file_view;
    self.updateTitle();
    self.invalidate();
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
pub fn confirmTorrent(self: *App) void {
    const dlg = self.dialog orelse return;
    const value = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
    if (value.len == 0) return;
    if (dlg.kind == .torrent_source) {
        const source = self.allocator.dupe(u8, value) catch return;
        defer self.allocator.free(source);
        self.torrentSource(source);
    } else if (self.torrents.send(.{ .op = "add", .source = dlg.target_path orelse "", .destination = value })) {
        self.transfer_view.selected[0] = 0;
        self.openTransfers();
    } else self.setStatusNotice(self.torrents.message(), true);
}
pub fn torrentSidebarHeight(self: *App) i32 {
    return if (enabled and self.chooser == null and self.torrents.items().len > 0) 52 else 0;
}
fn sidebarBox(self: *App) Rect {
    const card = self.sidebarLayout().cards[@intFromEnum(@import("app_model.zig").SidebarSection.transfers)];
    return .{
        .x = 12,
        .y = @floatFromInt(card.y + card.header_height),
        .w = @floatCast(@max(0, self.sidebarContentWidth() - 24)),
        .h = @floatFromInt(self.torrentSidebarHeight()),
    };
}
pub fn torrentSidebarHit(self: *App, x: f64, y: f64) bool {
    if (!enabled) return false;
    if (self.chooser != null or self.sidebarWidth() == 0 or y < @as(f64, @floatFromInt(self.contentTop())) or y >= @as(f64, @floatFromInt(self.h - self.sidebarFooter()))) return false;
    return contains(sidebarBox(self), @floatCast(x), @floatCast(y));
}
pub fn torrentSidebarHover(self: *App, x: f64, y: f64) usize {
    if (!self.torrentSidebarHit(x, y)) return 0;
    if (self.torrents.items().len > 0) {
        const area = sidebarBox(self);
        const t = self.torrents.items()[0];
        const remove_rect = sidebar_controls.buttonRect(area, 26, 2);
        if (sidebar_controls.contains(remove_rect, x, y)) {
            return std.math.maxInt(usize) - 2011;
        }
        if (!t.pending) {
            const pause_rect = sidebar_controls.buttonRect(area, 54, 2);
            if (sidebar_controls.contains(pause_rect, x, y)) {
                return std.math.maxInt(usize) - 2010;
            }
        }
    }
    return std.math.maxInt(usize) - 2001;
}
pub fn torrentSidebarClick(self: *App, x: f64, y: f64) bool {
    if (!self.torrentSidebarHit(x, y)) return false;
    if (self.torrents.items().len > 0) {
        const area = sidebarBox(self);
        const t = self.torrents.items()[0];
        const id = t.id;
        const remove_rect = sidebar_controls.buttonRect(area, 26, 2);
        if (sidebar_controls.contains(remove_rect, x, y)) {
            if (!self.torrents.send(.{ .op = "remove", .id = id })) {
                self.setStatusNotice(self.torrents.message(), true);
            } else {
                self.transfer_view.selected[0] = 0;
                self.transfer_view.row = null;
            }
            self.invalidate();
            return true;
        }
        if (!t.pending) {
            const pause_rect = sidebar_controls.buttonRect(area, 54, 2);
            if (sidebar_controls.contains(pause_rect, x, y)) {
                const op: []const u8 = if (t.paused) "resume" else "pause";
                if (!self.torrents.send(.{ .op = op, .id = id })) {
                    self.setStatusNotice(self.torrents.message(), true);
                }
                self.invalidate();
                return true;
            }
        }
    }
    self.openTransfers();
    return true;
}
pub fn renderTorrentSidebar(self: *App, cr: *c.cairo_t) void {
    if (!enabled) return;
    if (self.chooser != null) return;
    if (self.torrents.items().len == 0) return;
    const area = sidebarBox(self);
    draw.drawSidebarTransferSurface(cr, area);
    var label: []const u8 = tr("Transfers");
    var fraction: ?f64 = null;
    var pause_icon: ?sidebar_controls.Icon = null;
    if (self.torrents.items().len > 0) {
        const t = self.torrents.items()[0];
        label = t.name;
        if (!t.pending) {
            fraction = @as(f64, @floatFromInt(std.math.clamp(t.progress, 0, 1000000))) / 1000000.0;
        }
        if (!t.pending) pause_icon = if (t.paused) .play else .pause;
    }
    const palette = theme.shellPalette();
    draw.drawTransferProgressRow(
        cr,
        area,
        label,
        fraction,
        theme.global.sidebarForeground(),
        palette.accent,
        ui.statusSize(),
    );
    if (pause_icon) |icon| {
        const pause_rect = sidebar_controls.buttonRect(area, 54, 2);
        sidebar_controls.render(
            cr,
            pause_rect,
            icon,
            sidebar_controls.contains(pause_rect, self.mouse_x, self.mouse_y),
        );
    }
    if (self.torrents.items().len > 0) {
        const remove_rect = sidebar_controls.buttonRect(area, 26, 2);
        sidebar_controls.render(
            cr,
            remove_rect,
            .close,
            sidebar_controls.contains(remove_rect, self.mouse_x, self.mouse_y),
        );
    }
}
fn box(self: *App) Rect {
    const w: f32 = @min(720, @as(f32, @floatFromInt(self.w)) - 24);
    const h: f32 = @min(560, @as(f32, @floatFromInt(self.h)) - 24);
    return .{ .x = (@as(f32, @floatFromInt(self.w)) - w) / 2, .y = (@as(f32, @floatFromInt(self.h)) - h) / 2, .w = w, .h = h };
}
fn selected(self: *App) ?Transfer {
    for (self.torrents.items()) |t| if (std.mem.eql(u8, t.id, self.transfer_view.id())) return t;
    return null;
}
fn capacity(self: *App) usize {
    return @intFromFloat(@max(1, @floor((box(self).h - 280) / 58)));
}
const Control = struct { rect: Rect, label: []const u8, id: usize, checked: ?bool = null };
fn controls(self: *App, out: *[32]Control) []Control {
    const b = box(self);
    var n: usize = 0;
    out[n] = .{ .rect = frame.closeBox(b.w), .label = tr("Close"), .id = 1 };
    n += 1;
    const top: f32 = 60;
    if (selected(self)) |t| {
        self.transfer_view.file_page = @min(self.transfer_view.file_page, (t.files.len -| 1) / capacity(self));
        out[n] = .{ .rect = .{ .x = 16, .y = top, .w = 72, .h = 30 }, .label = tr("Back"), .id = 2 };
        n += 1;
        if (t.pending) {
            if (t.metadata and t.@"error".len == 0) {
                const begin = @min(self.transfer_view.file_page * capacity(self), t.files.len);
                const end = @min(begin + capacity(self), t.files.len);
                for (t.files[begin..end], 0..) |f, i| {
                    out[n] = .{ .rect = .{ .x = 18, .y = 140 + @as(f32, @floatFromInt(i)) * 58, .w = b.w - 36, .h = 32 }, .label = f.path, .id = 1000 + f.index, .checked = self.transfer_view.choices[f.index] };
                    n += 1;
                }
                out[n] = .{ .rect = .{ .x = 16, .y = b.h - 100, .w = 148, .h = 30 }, .label = switch (self.transfer_view.ratio) {
                    0 => tr("Seed: stop at finish"),
                    1 => tr("Seed: ratio 1"),
                    else => tr("Seed: ratio 2"),
                }, .id = 9 };
                n += 1;
                out[n] = .{ .rect = .{ .x = 172, .y = b.h - 100, .w = 150, .h = 30 }, .label = if (self.transfer_view.limit == 1048576) tr("Upload: 1 MiB/s") else tr("Upload: 128 KiB/s"), .id = 10 };
                n += 1;
                out[n] = .{ .rect = .{ .x = b.w - 140, .y = b.h - 58, .w = 124, .h = 32 }, .label = tr("Start download"), .id = 8 };
                n += 1;
            }
        } else {
            out[n] = .{ .rect = .{ .x = 16, .y = 148, .w = 120, .h = 32 }, .label = if (t.paused) tr("Resume") else tr("Pause"), .id = 6 };
            n += 1;
            out[n] = .{ .rect = .{ .x = 148, .y = 148, .w = 140, .h = 32 }, .label = tr("Show in folder"), .id = 7 };
            n += 1;
        }
        out[n] = .{ .rect = .{ .x = b.w - 180, .y = top, .w = 164, .h = 30 }, .label = tr("Remove · keep files"), .id = 11 };
        n += 1;
    }
    const count = if (selected(self)) |t| t.files.len else 0;
    if (count > capacity(self)) {
        out[n] = .{ .rect = .{ .x = 16, .y = b.h - 58, .w = 80, .h = 32 }, .label = tr("Previous"), .id = 12 };
        n += 1;
        out[n] = .{ .rect = .{ .x = 104, .y = b.h - 58, .w = 70, .h = 32 }, .label = tr("Next"), .id = 13 };
        n += 1;
    }
    return out[0..n];
}
fn activate(self: *App, id: usize) void {
    switch (id) {
        1 => self.closeDialog(),
        2 => {
            self.transfer_view.selected[0] = 0;
            self.closeDialog();
        },
        3 => self.torrentSource(null),
        4 => {
            _ = self.torrents.send(.{ .op = "pause_all" });
        },
        5 => {
            _ = self.torrents.send(.{ .op = "stop_seeding" });
        },
        6 => if (selected(self)) |t| {
            _ = self.torrents.send(.{ .op = if (t.paused) @as([]const u8, "resume") else "pause", .id = t.id });
        },
        7 => if (selected(self)) |t| {
            const path = self.allocator.dupe(u8, if (t.published) t.destination else t.storage) catch return;
            defer self.allocator.free(path);
            self.closeDialog();
            self.navigate(path);
        },
        8 => if (selected(self)) |t| {
            var indices: [512]usize = undefined;
            var n: usize = 0;
            for (t.files) |f| if (self.transfer_view.choices[f.index]) {
                indices[n] = f.index;
                n += 1;
            };
            _ = self.torrents.send(.{ .op = "start", .id = t.id, .files = indices[0..n], .ratio = self.transfer_view.ratio, .limit = self.transfer_view.limit });
        },
        9 => self.transfer_view.ratio = @mod(self.transfer_view.ratio + 1, 3),
        10 => self.transfer_view.limit = if (self.transfer_view.limit == 1048576) 131072 else 1048576,
        11 => if (selected(self)) |t| {
            _ = self.torrents.send(.{ .op = "remove", .id = t.id });
            self.transfer_view.selected[0] = 0;
            self.closeDialog();
        },
        25 => if (selectedTransferRow(self)) |row| {
            const entries = self.torrents.items();
            if (row < entries.len) {
                self.toggleTorrent(entries[row]);
            } else if (self.job_runner) |runner| {
                const progress = fileOperationProgress(self) orelse return;
                if (progress.state == .paused) {
                    runner.resumeJob();
                } else if (progress.state == .running) {
                    runner.pause();
                }
            }
        },
        26 => if (selectedTransferRow(self)) |row| {
            const entries = self.torrents.items();
            if (row < entries.len) {
                _ = self.torrents.send(.{ .op = "remove", .id = entries[row].id });
                self.transfer_view.selected[0] = 0;
                self.transfer_view.row = null;
            } else if (self.job_runner) |runner| {
                runner.cancel();
                self.transfer_view.row = null;
            }
        },
        27 => if (selectedTransferRow(self)) |row| {
            if (row < self.torrents.items().len) openTransfer(self, row);
        },
        12, 13 => {
            const page = &self.transfer_view.file_page;
            const count = if (selected(self)) |t| t.files.len else 0;
            if (id == 12) page.* -|= 1 else page.* = @min(page.* + 1, (count -| 1) / capacity(self));
        },
        else => {
            if (id >= 1000 and id < 1512) self.transfer_view.choices[id - 1000] = !self.transfer_view.choices[id - 1000] else if (id >= 100 and id - 100 < self.torrents.items().len) {
                const t = self.torrents.items()[id - 100];
                if (t.id.len > 64) return;
                @memcpy(self.transfer_view.selected[0..t.id.len], t.id);
                self.transfer_view.selected[t.id.len] = 0;
                self.transfer_view.choices = @splat(true);
                self.transfer_view.file_page = 0;
            }
        },
    }
    self.invalidate();
}
pub fn transfersClick(self: *App, x: f64, y: f64) void {
    const b = box(self);
    var storage: [32]Control = undefined;
    for (controls(self, &storage)) |control| if (contains(control.rect, @floatCast(x - b.x), @floatCast(y - b.y))) {
        activate(self, control.id);
        return;
    };
}
pub fn transfersKey(self: *App, sym: u32) void {
    if (sym == c.XKB_KEY_Escape) {
        self.closeDialog();
        return;
    }
    var storage: [32]Control = undefined;
    const list = controls(self, &storage);
    self.transfer_view.focus %= list.len;
    if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) self.transfer_view.focus = (self.transfer_view.focus + if (self.shift) list.len - 1 else @as(usize, 1)) % list.len;
    if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space) activate(self, list[self.transfer_view.focus].id);
    self.invalidate();
}
pub fn renderTransfers(self: *App, cr: *c.cairo_t) void {
    ui.setSource(cr, frame.backdropColor());
    c.cairo_paint(cr);
    const b = box(self);
    var layer = ui.Layer.begin(cr, b) orelse return;
    defer layer.finish();
    const r = &layer.renderer;
    var palette = theme.shellPalette();
    palette.fg = theme.global.window_fg;
    palette.button_font_size = ui.textSize();
    r.palette = palette;
    frame.paintWindowFrame(r, layer.local(), theme.global.app_toolbar);
    frame.paintWindowTitle(r, layer.local(), if (selected(self)) |t| t.name else tr("Transfer"), .folder, null);
    var storage: [32]Control = undefined;
    for (controls(self, &storage), 0..) |control, i| {
        const hover = contains(control.rect, @floatCast(self.mouse_x - b.x), @floatCast(self.mouse_y - b.y));
        if (control.checked) |checked| checkbox.paint(r, control.rect, control.label, .{ .checked = checked, .focused = self.transfer_view.focus == i }) else button.paint(r, control.rect, .{ .label = control.label, .variant = if (control.id == 1) .chrome else if (control.id >= 100) .ghost else .secondary, .icon = if (control.id == 1) .close else null, .alignment = if (control.id >= 100) .left else .center }, .{ .pointer = if (hover) .hover else .idle, .focused = self.transfer_view.focus == i });
    }
    const message = self.torrents.message();
    r.drawText(16, 104, b.w - 32, 26, .{ .content = if (message.len > 0) message else if (selected(self)) |t| t.status() else tr("Downloads continue after closing Files."), .font_size = ui.statusSize(), .color = if (message.len > 0) theme.global.danger else palette.fg });
    if (selected(self)) |t| {
        if (t.pending and t.metadata) {
            var bytes: i64 = 0;
            for (t.files) |f| if (self.transfer_view.choices[f.index]) {
                bytes +|= f.size;
            };
            var size_buf: [32]u8 = undefined;
            var label_buf: [2300]u8 = undefined;
            const label = i18n.fmt(&label_buf, tr("{size} selected · {path}"), .{ .size = draw.formatSize(bytes, &size_buf), .path = t.destination }) catch t.destination;
            r.drawText(16, b.h - 132, b.w - 32, 24, .{ .content = label, .font_size = ui.statusSize(), .color = palette.fg });
            const begin = @min(self.transfer_view.file_page * capacity(self), t.files.len);
            for (t.files[begin..@min(begin + capacity(self), t.files.len)], 0..) |f, i| {
                const size = draw.formatSize(f.size, &size_buf);
                r.drawText(46, 172 + @as(f32, @floatFromInt(i)) * 58, b.w - 62, 20, .{ .content = size, .font_size = ui.statusSize(), .color = palette.fg });
            }
        }
        if (!t.pending) {
            var buf: [160]u8 = undefined;
            const status = i18n.fmt(&buf, tr("{value}% · ↓ {rate} KiB/s · ↑ {rate3} KiB/s"), .{ .value = @divTrunc(t.progress, 10000), .rate = @divTrunc(t.download_rate, 1024), .rate3 = @divTrunc(t.upload_rate, 1024) }) catch "";
            r.drawText(16, 200, b.w - 32, 30, .{ .content = status, .font_size = ui.textSize(), .color = palette.fg });
            r.drawText(16, 244, b.w - 32, 30, .{ .content = t.destination, .font_size = ui.statusSize(), .color = palette.fg });
        }
    } else {
        r.drawText(16, 150, b.w - 32, 30, .{ .content = tr("This transfer is no longer available."), .font_size = ui.textSize(), .color = palette.fg });
    }
}

fn contains(r: Rect, x: f32, y: f32) bool {
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
}

pub fn transfersHover(self: *App) usize {
    const b = box(self);
    var storage: [32]Control = undefined;
    for (controls(self, &storage)) |control| if (contains(control.rect, @floatCast(self.mouse_x - b.x), @floatCast(self.mouse_y - b.y))) return std.math.maxInt(usize) - control.id;
    return std.math.maxInt(usize) - 2000;
}

pub fn leaveTransfers(self: *App) void {
    if (!self.transfer_view.active) return;
    self.cancelWheel();
    self.transfer_view.active = false;
    self.syncGitLayout();
    self.scroll_y = self.transfer_view.folder_scroll;
    self.scroll_x = self.transfer_view.folder_scroll_x;
    self.search_visible = self.transfer_view.folder_search_visible;
    self.clampScroll();
    self.updateTitle();
    self.invalidate();
}

const header = @import("header.zig");
const field = @import("ui").widgets.field;
const Icon = @import("ui").layout.IconId;
const ToolbarControl = struct { rect: Rect, label: []const u8, id: usize, icon: ?Icon = null, enabled: bool = true };

fn selectedTransferRow(self: *App) ?usize {
    const row = self.transfer_view.row orelse return null;
    const count = self.torrents.items().len + @as(usize, @intFromBool(fileOperationProgress(self) != null));
    return if (row < count) row else null;
}

fn toolbarControls(self: *App) [10]ToolbarControl {
    const width: f32 = @floatFromInt(self.w);
    const y: f32 = if (self.w < 500) 110 else 64;
    const gap: f32 = 8;
    const scale = @min(1, @max(0, (width - 64) / 424));
    const add_w = 112 * scale;
    const pause_w = 92 * scale;
    const stop_w = 116 * scale;
    const details_w = 80 * scale;

    const entries = self.torrents.items();
    const row = selectedTransferRow(self);
    const file_op = fileOperationProgress(self);
    const selected_file_op = row != null and file_op != null and row.? == entries.len;
    const selected_torrent = if (row) |index| (if (index < entries.len) entries[index] else null) else null;

    const can_pause = if (selected_file_op) blk: {
        const progress = file_op.?;
        break :blk (progress.kind == .copy or progress.kind == .move) and
            (progress.state == .running or progress.state == .paused);
    } else if (selected_torrent) |t| !t.pending else false;
    const pause_label = if (selected_file_op)
        (if (file_op.?.state == .paused) tr("Resume") else tr("Pause"))
    else if (selected_torrent) |t|
        (if (t.paused) tr("Resume") else tr("Pause"))
    else
        tr("Pause");

    const cancel_label = if (selected_file_op) tr("Cancel") else tr("Remove");
    const can_cancel = selected_file_op or selected_torrent != null;
    const can_details = selected_torrent != null;

    const pause_x = 12 + add_w + gap;
    const cancel_x = pause_x + pause_w + gap;
    const details_x = cancel_x + stop_w + gap;

    return .{
        .{ .rect = .{ .x = 12, .y = 12, .w = 30, .h = 32 }, .label = tr("Back"), .id = 20, .icon = .chevron_left },
        .{ .rect = .{ .x = 44, .y = 12, .w = 30, .h = 32 }, .label = tr("Forward"), .id = 21, .icon = .chevron_right, .enabled = false },
        .{ .rect = .{ .x = 76, .y = 12, .w = 30, .h = 32 }, .label = tr("Up"), .id = 20, .icon = .chevron_up },
        .{ .rect = .{ .x = width - 78, .y = 12, .w = 30, .h = 32 }, .label = tr("Refresh"), .id = 22, .icon = .refresh },
        .{ .rect = .{ .x = 12, .y = y, .w = add_w, .h = 36 }, .label = tr("Add torrent…"), .id = 3 },
        .{ .rect = .{ .x = pause_x, .y = y, .w = pause_w, .h = 36 }, .label = pause_label, .id = 25, .enabled = can_pause },
        .{ .rect = .{ .x = cancel_x, .y = y, .w = stop_w, .h = 36 }, .label = cancel_label, .id = 26, .enabled = can_cancel },
        .{ .rect = .{ .x = details_x, .y = y, .w = details_w, .h = 36 }, .label = tr("Details"), .id = 27, .enabled = can_details },
        .{ .rect = .{ .x = width - 88, .y = 64, .w = 34, .h = 36 }, .label = tr("Grid"), .id = 23, .icon = .view_grid, .enabled = false },
        .{ .rect = .{ .x = width - 52, .y = 64, .w = 34, .h = 36 }, .label = tr("List"), .id = 24, .icon = .view_list },
    };
}

pub fn renderTransferToolbar(self: *App, cr: *c.cairo_t) void {
    for (toolbarControls(self), 0..) |control, i| {
        var layer = ui.Layer.begin(cr, control.rect) orelse continue;
        defer layer.finish();
        button.paint(&layer.renderer, layer.local(), .{
            .label = control.label,
            .icon = control.icon,
            .icon_scale = 0.56,
            .variant = if (control.icon != null) .ghost else .secondary,
        }, .{
            .pointer = if (!control.enabled) .disabled else if (contains(control.rect, @floatCast(self.mouse_x), @floatCast(self.mouse_y))) .hover else .idle,
            .selected = control.id == 24,
            .focused = self.transfer_view.focus == i + 1,
        });
    }
    const r = header.field(self.w);
    var layer = ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse return;
    defer layer.finish();
    const area = field.paintFrame(&layer.renderer, layer.local(), .{}, .{});
    layer.renderer.drawText(area.text.x + 4, area.text.y, @max(0, area.text.w - 8), area.text.h, .{ .content = tr("Transfers"), .font_size = ui.textSize(), .color = theme.global.window_fg });
}

fn transferAt(self: *App, x: f64, y: f64) ?usize {
    if (x < @as(f64, @floatFromInt(self.sidebarWidth() + 20)) or x >= @as(f64, @floatFromInt(self.w - 20 - self.scrollbarGutter())) or
        y < @as(f64, @floatFromInt(self.viewTop())) or y >= @as(f64, @floatFromInt(self.contentBottom()))) return null;
    const offset = y - @as(f64, @floatFromInt(self.viewTop() + self.itemInset() - self.scroll_y));
    if (offset < 0) return null;
    const row: usize = @intFromFloat(@floor(offset / @as(f64, @floatFromInt(self.rowHeight()))));
    if (@mod(offset, @as(f64, @floatFromInt(self.rowHeight()))) >= @as(f64, @floatFromInt(self.cardHeight()))) return null;
    const count = self.torrents.items().len + @as(usize, @intFromBool(fileOperationProgress(self) != null));
    return if (row < count) row else null;
}

fn fileOperationProgress(self: *App) ?ops_mod.ProgressInfo {
    const runner = self.job_runner orelse return null;
    const progress = runner.pollProgress();
    return if (progress.state == .running or
        progress.state == .paused or
        progress.state == .waiting_conflict) progress else null;
}

fn fileOperationFraction(progress: ops_mod.ProgressInfo) f64 {
    if (!progress.total_bytes_known) return 0;
    if (progress.total_bytes > 0) {
        return @min(
            1.0,
            @as(f64, @floatFromInt(progress.transferred_bytes)) /
                @as(f64, @floatFromInt(progress.total_bytes)),
        );
    }
    if (progress.total_items == 0) return 0;
    return @min(
        1.0,
        @as(f64, @floatFromInt(progress.processed_items)) /
            @as(f64, @floatFromInt(progress.total_items)),
    );
}

pub fn fileOperationRowRect(self: *App, index: usize) header.Rect {
    const y: f64 = @floatFromInt(
        self.viewTop() + self.itemInset() +
            @as(i32, @intCast(index)) * self.rowHeight() - self.scroll_y,
    );
    return .{
        .x = @floatFromInt(self.sidebarWidth() + 20),
        .y = y,
        .w = @floatFromInt(@max(0, self.cellWidth() - 20)),
        .h = @floatFromInt(self.cardHeight()),
    };
}

fn renderFileOperationRow(
    self: *App,
    cr: *c.cairo_t,
    index: usize,
    progress: ops_mod.ProgressInfo,
) void {
    const row = fileOperationRowRect(self, index);
    const y = row.y;
    const hover = if (self.dialog == null) transferAt(self, self.mouse_x, self.mouse_y) else null;
    if (self.transfer_view.row == index or hover == index) {
        ui.drawItemHighlight(cr, .{
            .x = row.x,
            .y = row.y,
            .w = row.w,
            .h = row.h,
        }, self.transfer_view.row == index, 1, 1);
    }

    const operation = switch (progress.kind) {
        .copy => tr("Copy"),
        .move => tr("Move"),
        .extract => tr("Extract"),
        .open_archive_member => tr("Open"),
    };
    const state = switch (progress.state) {
        .paused => tr("Paused"),
        .waiting_conflict => tr("Waiting for decision"),
        .running => if (progress.measuring) tr("Measuring…") else tr("Working…"),
        else => tr("Working…"),
    };
    const current = if (progress.current_name.len > 0)
        progress.current_name
    else
        tr("Preparing…");

    var transferred_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    var bytes_buf: [80]u8 = undefined;
    const transferred: i64 = @intCast(@min(
        progress.transferred_bytes,
        @as(u64, std.math.maxInt(i64)),
    ));
    const total: i64 = @intCast(@min(
        progress.total_bytes,
        @as(u64, std.math.maxInt(i64)),
    ));
    const bytes_label = if (progress.total_bytes_known)
        std.fmt.bufPrint(
            &bytes_buf,
            "{s} / {s}",
            .{
                draw.formatSize(transferred, &transferred_buf),
                draw.formatSize(total, &total_buf),
            },
        ) catch ""
    else
        tr("Measuring…");

    const fraction = fileOperationFraction(progress);
    var percent_buf: [16]u8 = undefined;
    const percent_label = if (progress.total_bytes_known)
        std.fmt.bufPrint(&percent_buf, "{d}%", .{@as(u32, @intFromFloat(fraction * 100))}) catch ""
    else
        "—";

    if (ui.Layer.begin(cr, .{
        .x = @floatCast(row.x + 12),
        .y = @floatCast(y + 5),
        .w = 24,
        .h = 24,
    })) |value| {
        var layer = value;
        layer.renderer.drawIcon(0, 0, 24, 24, .{
            .id = .folder,
            .color = theme.shellPalette().accent,
        });
        layer.finish();
    }

    const name_column = self.listColumn(0);
    const status_column = self.listColumn(1);
    const progress_column = self.listColumn(2);
    const first_baseline = y + 15;
    const second_baseline = y + 29;

    draw.setSource(cr, theme.global.window_fg);
    draw.drawEllipsis(
        cr,
        operation,
        name_column.x + 44,
        first_baseline,
        @max(0, name_column.w - 50),
        ui.textSize(),
        true,
    );
    draw.drawEllipsis(
        cr,
        current,
        name_column.x + 44,
        second_baseline,
        @max(0, name_column.w - 50),
        ui.statusSize(),
        false,
    );
    draw.drawEllipsis(
        cr,
        state,
        status_column.x + 4,
        first_baseline,
        @max(0, status_column.w - 8),
        ui.textSize(),
        false,
    );
    draw.drawEllipsis(
        cr,
        bytes_label,
        status_column.x + 4,
        second_baseline,
        @max(0, status_column.w - 8),
        ui.statusSize(),
        false,
    );
    draw.drawEllipsis(
        cr,
        percent_label,
        progress_column.x + 4,
        first_baseline,
        @max(0, progress_column.w - 8),
        ui.statusSize(),
        false,
    );

    const bar_x = progress_column.x + 4;
    const bar_y = y + 24;
    const bar_width = @max(0, progress_column.w - 8);
    if (bar_width > 0) {
        draw.setSource(cr, theme.global.app_divider);
        c.cairo_rectangle(cr, bar_x, bar_y, bar_width, 4);
        c.cairo_fill(cr);

        if (fraction > 0) {
            draw.setSource(cr, theme.shellPalette().accent);
            c.cairo_rectangle(cr, bar_x, bar_y, bar_width * fraction, 4);
            c.cairo_fill(cr);
        }
    }
}

pub fn renderTransferList(self: *App, cr: *c.cairo_t) void {
    const entries = self.torrents.items();
    const file_op = fileOperationProgress(self);
    const row_count = entries.len + @as(usize, @intFromBool(file_op != null));
    if (row_count == 0) {
        draw.setSource(cr, theme.global.window_fg);
        draw.drawEllipsis(cr, if (self.torrents.retry_at != null) tr("Connecting…") else tr("No transfers yet. Add a .torrent file or magnet link."), @floatFromInt(self.sidebarWidth() + 24), @floatFromInt(self.viewTop() + 36), @floatFromInt(@max(0, self.w - self.sidebarWidth() - 48)), ui.textSize(), false);
        return;
    }
    const hover = if (self.dialog == null) transferAt(self, self.mouse_x, self.mouse_y) else null;
    const first = @min(row_count, @as(usize, @intCast(@divTrunc(self.scroll_y, self.rowHeight()))));
    const last = @min(row_count, @as(usize, @intCast(@divTrunc(self.scroll_y + @max(0, self.contentBottom() - self.viewTop()), self.rowHeight()) + 1)));
    const torrent_first = @min(first, entries.len);
    const torrent_last = @min(last, entries.len);
    for (entries[torrent_first..torrent_last], torrent_first..) |t, i| {
        const y: f64 = @floatFromInt(self.viewTop() + self.itemInset() + @as(i32, @intCast(i)) * self.rowHeight() - self.scroll_y);
        const row: header.Rect = .{ .x = @floatFromInt(self.sidebarWidth() + 20), .y = y, .w = @floatFromInt(@max(0, self.cellWidth() - 20)), .h = @floatFromInt(self.cardHeight()) };
        if (self.transfer_view.row == i or hover == i) ui.drawItemHighlight(cr, .{ .x = row.x, .y = row.y, .w = row.w, .h = row.h }, self.transfer_view.row == i, 1, 1);
        var progress_buf: [32]u8 = undefined;
        var download_buf: [48]u8 = undefined;
        var upload_buf: [48]u8 = undefined;
        const progress = std.fmt.bufPrint(&progress_buf, "{d}%", .{@divTrunc(t.progress, 10000)}) catch "";
        const download = i18n.fmt(&download_buf, tr("{rate} KiB/s"), .{ .rate = @divTrunc(t.download_rate, 1024) }) catch "";
        const upload = i18n.fmt(&upload_buf, tr("{rate} KiB/s"), .{ .rate = @divTrunc(t.upload_rate, 1024) }) catch "";
        const labels = [_][]const u8{ t.name, t.status(), progress, download, upload };
        if (ui.Layer.begin(cr, .{ .x = @floatCast(row.x + 12), .y = @floatCast(y + if (self.compactList()) @as(f64, 3) else 6), .w = 24, .h = 24 })) |value| {
            var layer = value;
            layer.renderer.drawIcon(0, 0, 24, 24, .{ .id = .folder, .color = theme.shellPalette().accent });
            layer.finish();
        }
        for (labels, 0..) |label, col| {
            const column = self.listColumn(col);
            const inset: f64 = if (col == 0) 44 else 4;
            draw.setSource(cr, if (col == 1 and t.@"error".len > 0) theme.global.danger else theme.global.window_fg);
            draw.drawEllipsis(cr, label, column.x + inset, y + self.listBaseline(), @max(0, column.w - inset - 4), ui.textSize(), false);
        }
    }
    if (file_op) |progress| {
        if (first <= entries.len and entries.len < last) {
            renderFileOperationRow(self, cr, entries.len, progress);
        }
    }
}

fn openTransfer(self: *App, row: usize) void {
    self.transfer_view.row = row;
    activate(self, 100 + row);
    self.transfer_view.focus = 0;
    self.dialog = .{ .kind = .transfers, .title = tr("Transfer") };
    self.invalidate();
}

pub fn transferPaneClick(self: *App, x: f64, y: f64, mouse_button: u32) bool {
    if (y < @as(f64, @floatFromInt(self.contentTop()))) {
        if (mouse_button == 0x110) for (toolbarControls(self)) |control| {
            if (control.enabled and contains(control.rect, @floatCast(x), @floatCast(y))) {
                if (control.id == 20) self.leaveTransfers() else if (control.id == 22) {
                    self.startTorrents();
                    self.invalidate();
                } else if (control.id != 24) activate(self, control.id);
                break;
            }
        };
        return true;
    }
    if (x < @as(f64, @floatFromInt(self.sidebarWidth())) or y >= @as(f64, @floatFromInt(self.contentBottom()))) return false;
    if (x >= @as(f64, @floatFromInt(self.w - self.scrollbarGutter()))) return false;
    if (mouse_button == 0x110) {
        self.focus = .file_view;
        if (transferAt(self, x, y)) |row| {
            const now = draw.nowMs();
            const double_click = self.transfer_view.last_click_row == row and
                now - self.transfer_view.last_click_time < 400;

            self.transfer_view.row = row;
            if (row < self.torrents.items().len) {
                activate(self, 100 + row);
            } else {
                self.transfer_view.selected[0] = 0;
            }

            if (double_click and row < self.torrents.items().len) {
                openTransfer(self, row);
                self.transfer_view.last_click_row = null;
                self.transfer_view.last_click_time = 0;
            } else {
                self.transfer_view.last_click_row = row;
                self.transfer_view.last_click_time = now;
            }
            self.invalidate();
        }
    }
    return true;
}

pub fn transferPaneHover(self: *App) usize {
    for (toolbarControls(self), 0..) |control, i| if (control.enabled and contains(control.rect, @floatCast(self.mouse_x), @floatCast(self.mouse_y))) return std.math.maxInt(usize) - 2100 - i;
    if (transferAt(self, self.mouse_x, self.mouse_y)) |row| return std.math.maxInt(usize) - 2200 - row;
    return std.math.maxInt(usize) - 2300;
}

pub fn transferPaneKey(self: *App, sym: u32) void {
    if (sym == c.XKB_KEY_Escape or (self.alt and (sym == c.XKB_KEY_Left or sym == c.XKB_KEY_Up))) {
        self.leaveTransfers();
        return;
    }
    if (self.ctrl and (sym == c.XKB_KEY_o or sym == c.XKB_KEY_O)) {
        self.torrentSource(null);
        return;
    }
    const list = toolbarControls(self);
    if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) {
        var index = self.transfer_view.focus;
        for (0..list.len + 1) |_| {
            index = (index + if (self.shift) list.len else @as(usize, 1)) % (list.len + 1);
            if (index == 0 or list[index - 1].enabled) break;
        }
        self.transfer_view.focus = index;
    } else if (sym == c.XKB_KEY_Up or sym == c.XKB_KEY_Down or sym == c.XKB_KEY_Home or sym == c.XKB_KEY_End or sym == c.XKB_KEY_Page_Up or sym == c.XKB_KEY_Page_Down) {
        const count = self.torrents.items().len + @as(usize, @intFromBool(fileOperationProgress(self) != null));
        if (count > 0) {
            const row = @min(self.transfer_view.row orelse 0, count - 1);
            const page: usize = @intCast(@max(1, @divTrunc(self.contentBottom() - self.viewTop(), self.rowHeight())));
            self.transfer_view.row = switch (sym) {
                c.XKB_KEY_Home => 0,
                c.XKB_KEY_End => count - 1,
                c.XKB_KEY_Up => row -| 1,
                c.XKB_KEY_Page_Up => row -| page,
                c.XKB_KEY_Page_Down => @min(count - 1, row + page),
                else => if (self.transfer_view.row == null) 0 else @min(count - 1, row + 1),
            };
            self.transfer_view.focus = 0;
            const selected_row = self.transfer_view.row.?;
            if (selected_row < self.torrents.items().len) {
                activate(self, 100 + selected_row);
            } else {
                self.transfer_view.selected[0] = 0;
            }
            const row_top = @as(i32, @intCast(selected_row)) * self.rowHeight();
            const visible_height = @max(1, self.contentBottom() - self.viewTop());
            if (row_top < self.scroll_y) {
                self.scroll_y = row_top;
            } else if (row_top + self.rowHeight() > self.scroll_y + visible_height) {
                self.scroll_y = row_top + self.rowHeight() - visible_height;
            }
        }
    } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space) {
        const index = self.transfer_view.focus;
        if (index > 0 and index <= list.len) {
            const control = list[index - 1];
            _ = self.transferPaneClick(control.rect.x + 1, control.rect.y + 1, 0x110);
        } else if (self.transfer_view.row) |row| {
            if (row < self.torrents.items().len) {
                openTransfer(self, row);
            } else {
                activate(self, 25);
            }
        }
    }
    self.invalidate();
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
    for (self.torrents.items(), 0..) |t, index| if (std.mem.eql(u8, t.id, id)) {
        self.closeDialog();
        openTransfer(self, index);
        return;
    };
}
pub fn renderTorrentSidebarTip(self: *App, cr: *c.cairo_t) void {
    if (self.hoverKey() != std.math.maxInt(usize) - 2001) return;
    if (self.torrents.items().len == 0) return;
    const t = self.torrents.items()[0];

    var download_buf: [96]u8 = undefined;
    var upload_buf: [96]u8 = undefined;
    var download_size_buf: [32]u8 = undefined;
    var upload_size_buf: [32]u8 = undefined;
    const download = i18n.fmt(&download_buf, tr("Download: {rate}/s"), .{
        .rate = draw.formatSize(t.download_rate, &download_size_buf),
    }) catch "";
    const upload = i18n.fmt(&upload_buf, tr("Upload: {rate}/s"), .{
        .rate = draw.formatSize(t.upload_rate, &upload_size_buf),
    }) catch "";
    const details = [_][]const u8{ download, upload };
    transferTip.render(cr, self.w, self.h, self.mouse_x, self.mouse_y, t.name, &details);
}
