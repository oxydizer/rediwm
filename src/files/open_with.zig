//! Files' modal application picker. Geometry is shared by painting and input.
const std = @import("std");
const associations = @import("associations.zig");
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

pub const Action = enum { none, cancel, open };
const Focus = enum { list, more, remember, cancel, open };
const row_height: f32 = 28;

pub const Geometry = struct {
    box: Rect,
    list: Rect,
    more: Rect,
    remember: Rect,
    cancel: Rect,
    open: Rect,
    close: Rect,
    rows: usize,

    pub fn init(w: i32, h: i32, count: usize) Geometry {
        const width: f32 = @min(480, @as(f32, @floatFromInt(w)) - 24);
        const header: f32 = @floatFromInt((chrome.Metrics{}).titlebarHeight());
        const height: f32 = @min(@min(400, header + 176 + @as(f32, @floatFromInt(@max(1, count))) * row_height), @as(f32, @floatFromInt(h)) - 16);
        const compact = height < header + 220;
        const list_y = header + @as(f32, if (compact) 30 else 52);
        const rows: usize = @intFromFloat(@max(1, @floor((height - @as(f32, if (compact) 104 else 124) - list_y) / row_height)));
        return .{
            .box = .{ .x = (@as(f32, @floatFromInt(w)) - width) / 2, .y = (@as(f32, @floatFromInt(h)) - height) / 2, .w = width, .h = height },
            .list = .{ .x = 16, .y = list_y, .w = width - 32, .h = @as(f32, @floatFromInt(rows)) * row_height },
            .more = .{ .x = 16, .y = height - @as(f32, if (compact) 92 else 104), .w = width - 32, .h = 24 },
            .remember = .{ .x = 16, .y = height - @as(f32, if (compact) 64 else 76), .w = width - 32, .h = 24 },
            .cancel = .{ .x = width - 188, .y = height - @as(f32, if (compact) 36 else 44), .w = 80, .h = 28 },
            .open = .{ .x = width - 100, .y = height - @as(f32, if (compact) 36 else 44), .w = 84, .h = 28 },
            .close = frame.closeBox(width),
            .rows = rows,
        };
    }
};

pub const State = struct {
    placement: frame.Placement = .{},
    apps: associations.Applications,
    selected: usize = 0,
    offset: usize = 0,
    all: bool = false,
    remember: bool = false,
    focus: Focus = .list,
    message: []const u8 = "",

    pub fn geometry(self: *const State, w: i32, h: i32) Geometry {
        var g = Geometry.init(w, h, self.count());
        g.box = self.placement.box(g.box, w, h);
        return g;
    }

    pub fn pointerButton(self: *State, w: i32, h: i32, x: f64, y: f64, pressed: bool) bool {
        return self.placement.button(Geometry.init(w, h, self.count()).box, w, h, x, y, pressed);
    }

    pub fn motion(self: *State, w: i32, h: i32, x: f64, y: f64) bool {
        return self.placement.motion(Geometry.init(w, h, self.count()).box, w, h, x, y);
    }

    pub fn init(a: std.mem.Allocator, paths: []const []const u8) !State {
        const apps = try associations.Applications.init(a, paths);
        return .{ .apps = apps, .all = apps.recommended == 0 };
    }

    pub fn deinit(self: *State) void {
        self.apps.deinit();
    }

    fn count(self: *const State) usize {
        return if (self.all) self.apps.entries.items.len else self.apps.recommended;
    }

    fn reveal(self: *State, rows: usize) void {
        if (self.selected < self.offset) self.offset = self.selected;
        if (self.selected >= self.offset + rows) self.offset = self.selected + 1 - rows;
        self.offset = @min(self.offset, self.count() -| rows);
    }

    fn more(self: *State, rows: usize) void {
        self.message = "";
        self.all = !self.all;
        self.selected = if (self.all and self.apps.recommended < self.apps.entries.items.len) self.apps.recommended else 0;
        self.offset = 0;
        self.focus = .list;
        self.reveal(rows);
    }

    pub fn key(self: *State, sym: u32, shift: bool, w: i32, h: i32) Action {
        const rows = self.geometry(w, h).rows;
        if (sym == c.XKB_KEY_Escape) return .cancel;
        if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) {
            const n = @typeInfo(Focus).@"enum".fields.len;
            self.focus = @enumFromInt((@intFromEnum(self.focus) + @as(usize, if (shift or sym == c.XKB_KEY_ISO_Left_Tab) n - 1 else 1)) % n);
        } else if (sym == c.XKB_KEY_Up or sym == c.XKB_KEY_Down or sym == c.XKB_KEY_Home or sym == c.XKB_KEY_End or sym == c.XKB_KEY_Page_Up or sym == c.XKB_KEY_Page_Down) {
            self.focus = .list;
            if (sym == c.XKB_KEY_Up) self.selected -|= 1;
            if (sym == c.XKB_KEY_Down) self.selected = @min(self.selected + 1, self.count() -| 1);
            if (sym == c.XKB_KEY_Home) self.selected = 0;
            if (sym == c.XKB_KEY_End) self.selected = self.count() -| 1;
            if (sym == c.XKB_KEY_Page_Up) self.selected -|= rows;
            if (sym == c.XKB_KEY_Page_Down) self.selected = @min(self.selected + rows, self.count() -| 1);
            self.reveal(rows);
        } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space) {
            switch (self.focus) {
                .list, .open => if (self.count() > 0) return .open,
                .cancel => return .cancel,
                .more => self.more(rows),
                .remember => if (self.apps.same_type and self.count() > 0) {
                    self.remember = !self.remember;
                },
            }
        }
        return .none;
    }

    pub fn hit(self: *const State, w: i32, h: i32, x: f64, y: f64) usize {
        const g = self.geometry(w, h);
        const px: f32 = @floatCast(x - g.box.x);
        const py: f32 = @floatCast(y - g.box.y);
        if (contains(g.close, px, py)) return 1;
        if (contains(g.cancel, px, py)) return 2;
        if (contains(g.open, px, py)) return 3;
        if (contains(g.more, px, py)) return 4;
        if (contains(g.remember, px, py)) return 5;
        if (contains(g.list, px, py)) {
            const row = @as(usize, @intFromFloat((py - g.list.y) / row_height)) + self.offset;
            if (row < self.count()) return 10 + row;
        }
        return 0;
    }

    pub fn click(self: *State, w: i32, h: i32, x: f64, y: f64) Action {
        const target = self.hit(w, h, x, y);
        switch (target) {
            1, 2 => return .cancel,
            3 => if (self.count() > 0) return .open,
            4 => self.more(self.geometry(w, h).rows),
            5 => {
                self.focus = .remember;
                if (self.apps.same_type and self.count() > 0) self.remember = !self.remember;
            },
            else => if (target >= 10) {
                self.selected = target - 10;
                self.focus = .list;
            },
        }
        return .none;
    }

    pub fn wheel(self: *State, delta: f64, w: i32, h: i32) void {
        const rows = self.geometry(w, h).rows;
        if (delta > 0) self.offset = @min(self.offset + 1, self.count() -| rows) else if (delta < 0) self.offset -|= 1;
    }

    pub fn open(self: *State) bool {
        if (self.selected >= self.count()) return false;
        self.apps.launch(self.selected, self.remember) catch |err| {
            self.message = if (err == error.DefaultFailed) "Opened, but could not save the default app" else "Could not open with this app. Choose another.";
            return err == error.DefaultFailed;
        };
        return true;
    }

    pub fn draw(self: *State, cr: *c.cairo_t, w: i32, h: i32, mx: f64, my: f64, cfg: icon_theme.Config, io: std.Io) void {
        const g = self.geometry(w, h);
        self.offset = @min(self.offset, self.count() -| g.rows);
        @import("ui").cairo.setSource(cr, frame.backdropColor());
        c.cairo_paint(cr);
        var layer = ui.Layer.begin(cr, g.box) orelse return;
        defer layer.finish();
        const r = &layer.renderer;
        var palette = theme.shellPalette();
        palette.fg = theme.global.window_fg;
        palette.dim = palette.fg;
        palette.font_size = ui.textSize();
        palette.button_font_size = ui.textSize();
        r.palette = palette;
        frame.paintWindowFrame(r, layer.local(), theme.global.app_toolbar);
        frame.paintWindowTitle(r, layer.local(), "Open With", .grid, null);
        var buffer: [256]u8 = undefined;
        const subtitle = if (self.message.len > 0) self.message else if (self.apps.paths.len == 1) std.fs.path.basename(self.apps.paths[0]) else std.fmt.bufPrint(&buffer, "{d} selected files", .{self.apps.paths.len}) catch "Selected files";
        if (g.list.y - @as(f32, @floatFromInt((chrome.Metrics{}).titlebarHeight())) > 30) r.drawText(16, g.list.y - 44, g.box.w - 32, 20, .{ .content = subtitle, .font_size = ui.textSize(), .color = palette.fg });
        r.drawText(16, g.list.y - 22, g.box.w - 32, 20, .{ .content = if (self.all) "All Applications" else "Recommended Apps", .font_size = ui.headingSize(), .weight = 600, .color = palette.fg });
        const hovered = self.hit(w, h, mx, my);
        if (self.count() == 0) r.drawText(24, g.list.y, g.list.w - 16, row_height, .{ .content = "No applications available", .font_size = ui.textSize(), .color = palette.fg });
        const end = @min(self.count(), self.offset + g.rows);
        for (self.offset..end) |i| {
            const entry = self.apps.entries.items[i];
            const y = g.list.y + @as(f32, @floatFromInt(i - self.offset)) * row_height;
            if (i == self.selected or hovered == 10 + i) r.fillRect(g.list.x, y, g.list.w, row_height - 2, .{
                .color = if (i == self.selected) theme.global.app_nav_selected else theme.global.app_item_hover,
                .radius = palette.radius,
                .border_width = if (i == self.selected) 1 else 0,
                .border_color = palette.border_hover,
            });
            var icon: ?icons.Entry = null;
            for (entry.icons) |name| {
                icon = icons.get(cfg, io, name, @intFromFloat(18 * ui.scaleOf(cr)));
                if (icon != null) break;
            }
            if (icon) |im| r.drawImageCover(24, y + 4, 18, 18, 0, .{ .pixels = im.pixels, .width = @intCast(im.size), .height = @intCast(im.size) }) else r.drawIcon(24, y + 4, 18, 18, .{ .id = .grid, .color = palette.fg });
            const label = if (entry.is_default) std.fmt.bufPrint(&buffer, "{s} (default)", .{entry.name}) catch entry.name else entry.name;
            r.drawText(52, y, g.list.w - 44, row_height - 2, .{ .content = label, .font_size = ui.textSize(), .color = palette.fg });
        }
        const strip = scrollbar.gutter(theme.global.scrollbar_width);
        if (scrollbar.Geometry.compute(.vertical, .{ .x = g.box.w - strip, .y = g.list.y, .w = strip, .h = g.list.h }, @floatFromInt(g.rows), @floatFromInt(self.count()), @floatFromInt(self.offset))) |bar|
            scrollbar.paint(r, scrollbar.look(bar, .{}, theme.global.scrollbar_width, palette));
        r.fillRect(16, g.more.y - 12, g.box.w - 32, 1, .{ .color = theme.global.app_divider });
        button.paint(r, g.more, .{ .size = .sm, .variant = .ghost, .alignment = .left, .leading_icon = .plus, .label = if (self.all) "Back to recommended apps" else "Choose another app…" }, .{ .focused = self.focus == .more, .pointer = if (hovered == 4) .hover else .idle });
        const extension = std.fs.path.extension(self.apps.paths[0]);
        const remember_label = if (extension.len > 0 and self.apps.paths.len == 1)
            std.fmt.bufPrint(&buffer, "Always use this app for {s} files", .{extension}) catch "Always use this app for this file type"
        else
            "Always use this app for this file type";
        checkbox.paint(r, g.remember, remember_label, .{ .checked = self.remember, .focused = self.focus == .remember, .disabled = !self.apps.same_type or self.count() == 0 });
        button.paint(r, g.cancel, .{ .size = .sm, .label = "Cancel" }, .{ .focused = self.focus == .cancel, .pointer = if (hovered == 2) .hover else .idle });
        button.paint(r, g.open, .{ .size = .sm, .label = "Open", .variant = .primary }, .{ .focused = self.focus == .open, .pointer = if (self.count() == 0) .disabled else if (hovered == 3) .hover else .idle });
        button.paint(r, g.close, .{ .icon = .close, .variant = .chrome, .label = "Close" }, .{ .pointer = if (hovered == 1) .hover else .idle });
    }
};

fn contains(rect: Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h;
}
