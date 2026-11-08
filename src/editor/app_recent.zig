//! Open Recent: the freedesktop recent-file history Files also uses
//! (`files/recent.zig`), read when the menu opens and added to after a file is
//! loaded or saved. The submenu hangs beside the "Open Recent" row.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("../files/c.zig").api;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const menu = @import("ui").context_menu;
const history = @import("../files/recent.zig");
const draw = @import("../files/app_draw.zig");
const formats = @import("formats.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const a = std.heap.c_allocator;

/// Files listed in the submenu.
pub const shown = 10;
/// Candidates examined (text files that still exist) before giving up.
const scan_limit = 80;
pub const width: f64 = 340;

fn newer(_: void, x: history.Entry, y: history.Entry) bool {
    return x.opened > y.opened;
}

fn clearList(self: *App) void {
    for (self.recent.items) |path| a.free(path);
    self.recent.clearRetainingCapacity();
}

pub fn deinitRecent(self: *App) void {
    clearList(self);
    self.recent.deinit(a);
}

/// Rereads the history, newest first, keeping only text files that exist.
pub fn refreshRecent(self: *App) void {
    clearList(self);
    const entries = history.read(a, self.io, self.environ) catch return;
    defer {
        for (entries) |entry| a.free(entry.path);
        a.free(entries);
    }
    std.mem.sort(history.Entry, entries, {}, newer);
    var scanned: usize = 0;
    for (entries) |entry| {
        if (self.recent.items.len >= shown or scanned >= scan_limit) break;
        scanned += 1;
        if (!formats.candidate(entry.path)) continue;
        var st: c.struct_stat = undefined;
        if (c.stat(entry.path.ptr, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG) continue;
        const owned = a.dupeSentinel(u8, entry.path, 0) catch return;
        self.recent.append(a, owned) catch {
            a.free(owned);
            return;
        };
    }
}

const Record = struct {
    path: [:0]u8,
    io: std.Io,
    environ: std.process.Environ,
};

fn recordWork(job: *Record) void {
    defer {
        a.free(job.path);
        a.destroy(job);
    }
    history.recordBy(a, job.io, job.environ, job.path, "RediWM Editor", "rediwm-editor %f") catch {};
}

/// Adds `path` to the shared history. The file is rewritten on a short-lived
/// thread, so a large history never stalls typing.
pub fn recordRecent(self: *App, path: []const u8) void {
    const owned = a.dupeSentinel(u8, path, 0) catch return;
    var absolute = owned;
    if (!std.fs.path.isAbsolute(path)) {
        // A path given on the command line is relative to where we started.
        defer a.free(owned);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = c.realpath(owned.ptr, &buffer) orelse return;
        absolute = a.dupeSentinel(u8, std.mem.span(resolved), 0) catch return;
    }
    const job = a.create(Record) catch {
        a.free(absolute);
        return;
    };
    job.* = .{ .path = absolute, .io = self.io, .environ = self.environ };
    const thread = std.Thread.spawn(.{}, recordWork, .{job}) catch {
        a.free(job.path);
        a.destroy(job);
        return;
    };
    thread.detach();
}

/// Rows of the submenu: each recent file, then Clear Recent.
pub fn rowCount(self: *const App) usize {
    return self.recent.items.len + 1;
}

pub fn enabled(self: *const App) bool {
    return self.recent.items.len > 0;
}

pub fn box(self: *const App) menu.Rect {
    const main = self.menuBox();
    const height: f64 = @floatFromInt(rowCount(self) * menu.row_height + 2 * menu.padding + menu.separator_space);
    const window_w: f64 = @floatFromInt(self.w);
    const window_h: f64 = @floatFromInt(self.h);
    const w = @min(width, @max(menu.width, window_w - 12));
    // Beside the menu, on the side that has room, overlapping its edge so the
    // pointer never crosses a gap.
    const left = main.x + 4 - w;
    const x = if (left >= 6) left else @min(main.x + main.w - 4, @max(6, window_w - w - 6));
    const row = self.menuRow(app_mod.recent_row);
    return .{
        .x = x,
        .y = std.math.clamp(row.y - menu.padding, 6, @max(6, window_h - height - 6)),
        .w = w,
        .h = height,
    };
}

pub fn rowBox(self: *const App, i: usize) menu.Rect {
    const b = box(self);
    const separator: f64 = if (i >= self.recent.items.len) menu.separator_space else 0;
    return .{
        .x = b.x + menu.padding,
        .y = b.y + @as(f64, @floatFromInt(menu.padding + i * menu.row_height)) + separator,
        .w = b.w - 2 * menu.padding,
        .h = menu.row_height,
    };
}

pub fn hit(self: *const App, x: f64, y: f64) ?usize {
    if (!self.sub_open) return null;
    for (0..rowCount(self)) |i| if (rowBox(self, i).contains(x, y)) return i;
    return null;
}

pub fn contains(self: *const App, x: f64, y: f64) bool {
    return self.sub_open and box(self).contains(x, y);
}

/// Opens (or, for the last row, clears) the chosen entry.
pub fn activate(self: *App, i: usize) void {
    if (i < self.recent.items.len) {
        const path = a.dupe(u8, self.recent.items[i]) catch return;
        defer a.free(path);
        self.dismissMenu();
        self.open(path);
    } else {
        self.dismissMenu();
        self.clearRecent();
    }
}

/// Forgets the text files in the shared history (the kind Open Recent lists),
/// which also takes them out of Files' Recent view; other kinds stay.
pub fn clearRecent(self: *App) void {
    clearList(self);
    self.sub_open = false;
    self.dirty = true;
    const job = a.create(Forget) catch return;
    job.* = .{ .io = self.io, .environ = self.environ };
    const thread = std.Thread.spawn(.{}, forgetWork, .{job}) catch {
        a.destroy(job);
        return;
    };
    thread.detach();
}

const Forget = struct { io: std.Io, environ: std.process.Environ };

fn forgetWork(job: *Forget) void {
    defer a.destroy(job);
    history.forgetWhere(a, job.io, job.environ, &formats.candidate) catch {};
}

fn homeRelative(buffer: []u8, home: ?[]const u8, dir: []const u8) []const u8 {
    if (home) |h| if (h.len > 1 and std.mem.startsWith(u8, dir, h) and (dir.len == h.len or dir[h.len] == '/')) {
        return std.fmt.bufPrint(buffer, "~{s}", .{dir[h.len..]}) catch dir;
    };
    return dir;
}

pub fn paint(self: *App, cr: *c.cairo_t) void {
    const b = box(self);
    menu.frame(cr, b, true);
    const fg = theme.global.app_fg orelse theme.global.window_fg;
    const text_size = ui.textSize();
    const metrics = ui.fontMetrics(cr, text_size);
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    for (self.recent.items, 0..) |path, i| {
        const r = rowBox(self, i);
        menu.row(cr, r, .{ .label = "", .icon = .edit, .selected = self.sub_selected == i }, true);
        const base = std.fs.path.basename(path);
        const name = if (std.unicode.utf8ValidateSlice(base)) base else tr("Text file");
        const baseline = r.y + (r.h + metrics.ascent - metrics.descent) / 2;
        const room = r.w - 36 - 12;
        const dir = homeRelative(&scratch, self.environ.getPosix("HOME"), std.fs.path.dirname(path) orelse "");
        const dir_ok = std.unicode.utf8ValidateSlice(dir);
        const name_room = if (dir_ok and dir.len > 0) @min(ui.measureText(cr, name, text_size, false), room * 0.6) else room;
        ui.setSource(cr, fg);
        draw.drawEllipsis(cr, name, r.x + 36, baseline, name_room, text_size, false);
        if (dir_ok and dir.len > 0) {
            var dim = fg;
            dim[3] *= 0.4;
            ui.setSource(cr, dim);
            const dir_room = room - name_room - 10;
            if (dir_room > 24) {
                const w = @min(ui.measureText(cr, dir, ui.statusSize(), false), dir_room);
                draw.drawEllipsis(cr, dir, r.x + r.w - 12 - w, r.y + (r.h + metrics.ascent - metrics.descent) / 2, dir_room, ui.statusSize(), false);
            }
        }
    }
    menu.row(cr, rowBox(self, self.recent.items.len), .{
        .label = tr("Clear Recent"),
        .icon = .close,
        .selected = self.sub_selected == self.recent.items.len,
        .separator = true,
    }, true);
}
