//! A snapshot of one file, owned independently of directory refreshes.
const std = @import("std");
const c = @import("c.zig").api;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const chrome = @import("ui").window_chrome;
const frame = @import("ui").widgets.dialog;
const button = @import("ui").widgets.button;
const checkbox = @import("ui").widgets.checkbox;
const icons = @import("../icon_cache.zig");
const icon_theme = @import("../icon_theme.zig");
const Rect = ui.Rect;
const centeredTextX = @import("ui").paint.centeredTextX;

extern fn g_content_type_guess(filename: [*:0]const u8, data: ?[*]const u8, size: usize, uncertain: ?*c_int) ?[*:0]u8;
extern fn g_content_type_get_description(content_type: [*:0]const u8) ?[*:0]u8;
extern fn g_free(memory: ?*anyopaque) void;

pub const Action = enum { none, close, open };
fn contentShift() f32 {
    return @max(0, @as(f32, @floatFromInt((chrome.Metrics{}).titlebarHeight())) - 49);
}

fn fullHeight() f32 {
    return 520 + contentShift();
}

pub const Geometry = struct {
    box: Rect,
    close: Rect,
    open: Rect,
    scroll: f32,

    pub fn init(w: i32, h: i32, offset: f32) Geometry {
        const width: f32 = @min(440, @as(f32, @floatFromInt(w)) - 24);
        const height: f32 = @min(fullHeight(), @as(f32, @floatFromInt(h)) - 16);
        const scroll = std.math.clamp(offset, 0, fullHeight() - height);
        return .{
            .box = .{ .x = (@as(f32, @floatFromInt(w)) - width) / 2, .y = (@as(f32, @floatFromInt(h)) - height) / 2, .w = width, .h = height },
            .close = frame.closeBox(width),
            .open = .{ .x = width - 48, .y = 67 + contentShift() - scroll, .w = 28, .h = 28 },
            .scroll = scroll,
        };
    }

    pub fn permission(self: Geometry, index: usize) Rect {
        const col: f32 = @floatFromInt(index % 3);
        const row: f32 = @floatFromInt(index / 3);
        const step = (self.box.w - 126) / 3;
        return .{ .x = 114 + (col + 0.5) * step - 9, .y = 386 + contentShift() + row * 34 - self.scroll, .w = 24, .h = 28 };
    }
};

pub const State = struct {
    placement: frame.Placement = .{},
    allocator: std.mem.Allocator,
    path: [:0]u8,
    fd: c_int,
    stat: c.struct_stat,
    created: ?i64 = null,
    description: []const u8,
    owner: []const u8,
    group: []const u8,
    preview: ?icons.Entry = null,
    focus: usize = 0, // Close, Open, then the nine permission cells.
    scroll: f32 = 0,
    message: []const u8 = "",
    changed: bool = false,
    keyboard_focus: bool = false,

    pub fn geometry(self: *const State, w: i32, h: i32) Geometry {
        var g = Geometry.init(w, h, self.scroll);
        g.box = self.placement.box(g.box, w, h);
        return g;
    }

    pub fn pointerButton(self: *State, w: i32, h: i32, x: f64, y: f64, pressed: bool) bool {
        return self.placement.button(Geometry.init(w, h, self.scroll).box, w, h, x, y, pressed);
    }

    pub fn motion(self: *State, w: i32, h: i32, x: f64, y: f64) bool {
        return self.placement.motion(Geometry.init(w, h, self.scroll).box, w, h, x, y);
    }

    pub fn init(a: std.mem.Allocator, path: []const u8, preview: ?icons.Entry) !State {
        const owned = try a.dupeZ(u8, path);
        errdefer a.free(owned);
        // O_PATH pins the inode without reading a file, opening a device or
        // blocking on a FIFO. A symlink describes the link itself.
        const fd = c.open(owned, c.O_PATH | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) return error.StatFailed;
        errdefer _ = c.close(fd);
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0) return error.StatFailed;
        const description = try describe(a, owned, st.st_mode);
        errdefer a.free(description);
        const owner = if (c.getpwuid(st.st_uid)) |pw| try a.dupe(u8, std.mem.span(pw.*.pw_name)) else try std.fmt.allocPrint(a, "{d}", .{st.st_uid});
        errdefer a.free(owner);
        const group = if (c.getgrgid(st.st_gid)) |gr| try a.dupe(u8, std.mem.span(gr.*.gr_name)) else try std.fmt.allocPrint(a, "{d}", .{st.st_gid});
        errdefer a.free(group);
        var result: State = .{ .allocator = a, .path = owned, .fd = fd, .stat = st, .description = description, .owner = owner, .group = group };
        var sx: c.struct_statx = undefined;
        if (c.statx(fd, "", c.AT_EMPTY_PATH | c.AT_SYMLINK_NOFOLLOW, c.STATX_BTIME, &sx) == 0 and sx.stx_mask & c.STATX_BTIME != 0) result.created = sx.stx_btime.tv_sec;
        if (preview) |im| result.preview = .{ .pixels = try a.dupe(u32, im.pixels), .size = im.size };
        return result;
    }

    pub fn deinit(self: *State) void {
        _ = c.close(self.fd);
        self.allocator.free(self.path);
        self.allocator.free(self.description);
        self.allocator.free(self.owner);
        self.allocator.free(self.group);
        if (self.preview) |im| self.allocator.free(im.pixels);
    }

    pub fn isDirectory(self: *const State) bool {
        return self.stat.st_mode & c.S_IFMT == c.S_IFDIR;
    }

    fn editable(self: *const State) bool {
        return self.stat.st_mode & c.S_IFMT != c.S_IFLNK and (c.geteuid() == 0 or c.geteuid() == self.stat.st_uid);
    }

    fn toggle(self: *State, index: usize) void {
        if (!self.editable()) return;
        // Read current bits and operate on the pinned inode even if its name
        // was replaced while this dialog was open. Preserve special bits.
        if (c.fstat(self.fd, &self.stat) != 0) {
            self.message = "Could not read permissions";
            return;
        }
        var buf: [64]u8 = undefined;
        const pinned = std.fmt.bufPrintZ(&buf, "/proc/self/fd/{d}", .{self.fd}) catch unreachable;
        if (c.chmod(pinned, (self.stat.st_mode & 0o7777) ^ permissionBit(index)) != 0) {
            self.message = "Could not change permissions";
            return;
        }
        self.changed = true;
        self.message = "Permissions updated";
        _ = c.fstat(self.fd, &self.stat);
    }

    pub fn hit(self: *const State, w: i32, h: i32, x: f64, y: f64) usize {
        const g = self.geometry(w, h);
        const px: f32 = @floatCast(x - g.box.x);
        const py: f32 = @floatCast(y - g.box.y);
        if (contains(g.close, px, py)) return 1;
        if (py < 49 + contentShift() or py >= g.box.h - 8) return 0;
        if (contains(g.open, px, py)) return 2;
        for (0..9) |i| if (contains(g.permission(i), px, py)) return 3 + i;
        return 0;
    }

    pub fn click(self: *State, w: i32, h: i32, x: f64, y: f64) Action {
        const target = self.hit(w, h, x, y);
        if (target == 0) return .none;
        self.keyboard_focus = false;
        self.focus = target - 1;
        return self.activate();
    }

    fn activate(self: *State) Action {
        switch (self.focus) {
            0 => return .close,
            1 => return .open,
            else => self.toggle(self.focus - 2),
        }
        return .none;
    }

    pub fn key(self: *State, sym: u32, shift: bool, w: i32, h: i32) Action {
        if (sym == c.XKB_KEY_Escape) return .close;
        if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) {
            self.keyboard_focus = true;
            const count: usize = if (self.editable()) 11 else 2;
            self.focus = (self.focus + @as(usize, if (shift or sym == c.XKB_KEY_ISO_Left_Tab) count - 1 else 1)) % count;
            if (self.focus == 1) self.scroll = 0 else if (self.focus >= 2) {
                const g = self.geometry(w, h);
                const cell = g.permission(self.focus - 2);
                self.scroll = std.math.clamp(g.scroll + @max(0, cell.y + cell.h - (g.box.h - 12)) + @min(0, cell.y - (52 + contentShift())), 0, fullHeight() - g.box.h);
            }
        } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space) return self.activate() else if (sym == c.XKB_KEY_Down or sym == c.XKB_KEY_Page_Down) self.wheel(70, w, h) else if (sym == c.XKB_KEY_Up or sym == c.XKB_KEY_Page_Up) self.wheel(-70, w, h);
        return .none;
    }

    pub fn wheel(self: *State, delta: f64, w: i32, h: i32) void {
        self.scroll = Geometry.init(w, h, self.scroll + @as(f32, @floatCast(delta))).scroll;
    }

    pub fn draw(self: *State, cr: *c.cairo_t, w: i32, h: i32, mx: f64, my: f64, cfg: icon_theme.Config, io: std.Io) void {
        const g = self.geometry(w, h);
        self.scroll = g.scroll;
        @import("ui").cairo.setSource(cr, frame.backdropColor());
        c.cairo_paint(cr);
        var layer = ui.Layer.begin(cr, g.box) orelse return;
        defer layer.finish();
        const r = &layer.renderer;
        var palette = theme.shellPalette();
        palette.fg = theme.global.window_fg;
        palette.font_size = ui.textSize();
        palette.button_font_size = ui.textSize();
        r.palette = palette;
        frame.paintWindowFrame(r, layer.local(), theme.global.app_toolbar);
        const metrics: chrome.Metrics = .{};
        const icon = icons.get(cfg, io, "text-x-generic", @intFromFloat(@as(f32, @floatFromInt(metrics.iconSize())) * ui.scaleOf(cr)));
        frame.paintWindowTitle(r, layer.local(), "Properties", .view_list, if (icon) |im| .{ .pixels = im.pixels, .width = @intCast(im.size), .height = @intCast(im.size) } else null);
        const hover = self.hit(w, h, mx, my);
        button.paint(r, g.close, .{ .icon = .close, .variant = .chrome, .label = "Close" }, .{ .focused = self.keyboard_focus and self.focus == 0, .pointer = if (hover == 1) .hover else .idle });
        r.clip = .{ .x = 12, .y = 49 + contentShift(), .w = g.box.w - 24, .h = g.box.h - 59 - contentShift() };
        const s = g.scroll - contentShift();
        r.fillRect(24, 66 - s, 64, 64, .{ .color = theme.global.app_toolbar, .radius = 9, .border_width = 1, .border_color = theme.global.app_item_border });
        const preview = self.preview orelse icons.get(cfg, io, if (self.isDirectory()) "folder" else "text-x-generic", @intFromFloat(44 * ui.scaleOf(cr)));
        if (preview) |im| r.drawImageCover(34, 76 - s, 44, 44, 0, .{ .pixels = im.pixels, .width = @intCast(im.size), .height = @intCast(im.size) }) else r.drawIcon(34, 76 - s, 44, 44, .{ .id = .view_list, .color = palette.fg });
        r.drawText(108, 68 - s, g.box.w - 162, 26, .{ .content = std.fs.path.basename(self.path), .font_size = ui.textSize(), .weight = 600, .color = palette.fg });
        r.drawText(108, 99 - s, g.box.w - 132, 24, .{ .content = self.description, .font_size = ui.textSize(), .color = palette.fg });
        var accent_palette = palette;
        accent_palette.fg = palette.accent;
        r.palette = accent_palette;
        button.paint(r, g.open, .{ .icon = .open, .variant = .ghost, .label = "Open" }, .{ .focused = self.keyboard_focus and self.focus == 1, .pointer = if (hover == 2) .hover else .idle });
        r.palette = palette;
        r.fillRect(24, 146 - s, g.box.w - 48, 1, .{ .color = theme.global.app_divider });
        var size_buf: [128]u8 = undefined;
        var short_buf: [32]u8 = undefined;
        const size = if (self.isDirectory()) "—" else std.fmt.bufPrint(&size_buf, "{s} ({d} bytes)", .{ @import("app.zig").formatSize(self.stat.st_size, &short_buf), self.stat.st_size }) catch "—";
        var created_buf: [64]u8 = undefined;
        var modified_buf: [64]u8 = undefined;
        const values = [_][]const u8{ size, date(self.created, &created_buf), date(self.stat.st_mtim.tv_sec, &modified_buf), std.fs.path.dirname(self.path) orelse "/", self.owner, self.group };
        const labels = [_][]const u8{ "Size", "Created", "Modified", "Location", "Owner", "Group" };
        for (labels, values, 0..) |label, value, i| {
            const y = 157 + @as(f32, @floatFromInt(i)) * 26 - s;
            r.drawText(24, y, 120, 24, .{ .content = label, .font_size = ui.textSize(), .color = palette.fg });
            r.drawText(162, y, g.box.w - 186, 24, .{ .content = value, .font_size = ui.textSize(), .color = palette.fg });
        }
        r.fillRect(24, 322 - s, g.box.w - 48, 1, .{ .color = theme.global.app_divider });
        r.drawText(24, 334 - s, 160, 28, .{ .content = "Permissions", .font_size = ui.headingSize(), .weight = 600, .color = palette.fg });
        var mode_buf: [8]u8 = undefined;
        const mode = std.fmt.bufPrint(&mode_buf, "{o:0>3}", .{self.stat.st_mode & 0o7777}) catch "";
        var tint = palette.accent;
        tint[3] *= 0.2;
        r.fillRect(g.box.w - 86, 334 - s, 62, 28, .{ .color = tint, .radius = 8 });
        r.drawText(centeredTextX(g.box.w - 86, 62, mode, ui.textSize()), 334 - s, 62, 28, .{ .content = mode, .font_size = ui.textSize(), .weight = 600, .color = palette.fg });
        for ([_][]const u8{ "Owner", "Group", "Others" }, 0..) |label, i| {
            const cell = g.permission(i);
            r.drawText(centeredTextX(cell.x - 30, 78, label, ui.headingSize()), 365 - s, 78, 22, .{ .content = label, .font_size = ui.headingSize(), .color = palette.fg });
        }
        for ([_][]const u8{ "Read", "Write", "Execute" }, 0..) |label, row| {
            r.drawText(24, 386 + @as(f32, @floatFromInt(row)) * 34 - s, 90, 28, .{ .content = label, .font_size = ui.textSize(), .color = palette.fg });
        }
        for (0..9) |i| checkbox.paint(r, g.permission(i), "", .{ .checked = self.stat.st_mode & permissionBit(i) != 0, .focused = (self.keyboard_focus and self.focus == i + 2) or hover == i + 3, .disabled = !self.editable() });
        const message = if (self.message.len > 0) self.message else if (self.stat.st_mode & c.S_IFMT == c.S_IFLNK) "Link permissions cannot be changed" else if (!self.editable()) "Only the owner can change permissions" else "";
        r.drawText(24, 488 - s, g.box.w - 48, 20, .{ .content = message, .font_size = ui.statusSize(), .color = palette.fg });
        const strip = scrollbar.gutter(theme.global.scrollbar_width);
        if (scrollbar.Geometry.compute(.vertical, .{ .x = g.box.w - strip, .y = 54 + contentShift(), .w = strip, .h = g.box.h - 68 - contentShift() }, g.box.h - 58 - contentShift(), 520 - 58, g.scroll)) |bar|
            scrollbar.paint(r, scrollbar.look(bar, .{}, theme.global.scrollbar_width, palette));
    }
};

fn permissionBit(index: usize) c.mode_t {
    return @as(c.mode_t, 1) << @as(u5, @intCast(8 - (index % 3) * 3 - index / 3));
}

fn date(timestamp: ?i64, buf: []u8) []const u8 {
    return @import("settings.zig").dateTime(timestamp orelse return "Unavailable", buf);
}

fn describe(a: std.mem.Allocator, path: [:0]const u8, mode: c.mode_t) ![]const u8 {
    const simple: ?[]const u8 = switch (mode & c.S_IFMT) {
        c.S_IFDIR => "Folder",
        c.S_IFLNK => "Symbolic link",
        c.S_IFIFO => "Named pipe",
        c.S_IFSOCK => "Socket",
        c.S_IFCHR, c.S_IFBLK => "Device",
        else => null,
    };
    if (simple) |label| return a.dupe(u8, label);
    const kind = g_content_type_guess(path, null, 0, null) orelse return a.dupe(u8, "File");
    defer g_free(kind);
    const description = g_content_type_get_description(kind) orelse return a.dupe(u8, "File");
    defer g_free(description);
    return a.dupe(u8, std.mem.span(description));
}

fn contains(rect: Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h;
}
