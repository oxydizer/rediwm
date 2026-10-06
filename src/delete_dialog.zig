//! Shared modal for Files and desktop. Own the targets until confirmation.
const std = @import("std");
const c = @import("files/c.zig").api;
const icons = @import("icon_cache.zig");
const shell_ui = @import("ui").cairo;
const theme = @import("ui").theme;
const chrome = @import("ui").window_chrome;
const dialog = @import("ui").widgets.dialog;
const button = @import("ui").widgets.button;
const checkbox = @import("ui").widgets.checkbox;
const Rect = shell_ui.Rect;
const a = std.heap.c_allocator;

fn inside(box: Rect, x: f32, y: f32) bool {
    return x >= box.x and x <= box.x + box.w and y >= box.y and y <= box.y + box.h;
}

pub const Action = enum { none, cancel, toggle, confirm };
pub const Target = enum { none, close, cancel, toggle, confirm };
pub const State = struct {
    placement: dialog.Placement = .{},
    paths: std.ArrayList([]const u8) = .empty,
    name: []const u8 = "",
    folder: bool = false,
    bytes: i64 = 0,
    preview: ?icons.Entry = null,
    permanent: bool = false,
    focus: enum { cancel, toggle, confirm } = .cancel,

    keyboard_focus: bool = false,

    pub fn geometry(self: *const State, w: i32, h: i32) Geometry {
        var g = Geometry.init(w, h);
        const box = self.placement.box(g.box(), w, h);
        g.x = box.x;
        g.y = box.y;
        return g;
    }

    pub fn pointerButton(self: *State, w: i32, h: i32, x: f64, y: f64, pressed: bool) bool {
        return self.placement.button(Geometry.init(w, h).box(), w, h, x, y, pressed);
    }

    pub fn motion(self: *State, w: i32, h: i32, x: f64, y: f64) bool {
        return self.placement.motion(Geometry.init(w, h).box(), w, h, x, y);
    }

    pub fn deinit(self: *State) void {
        for (self.paths.items) |path| a.free(path);
        self.paths.deinit(a);
        a.free(self.name);
        if (self.preview) |im| a.free(im.pixels);
        self.* = .{};
    }

    pub fn add(self: *State, path: []const u8, name: []const u8, folder: bool, bytes: i64, preview: ?icons.Entry) !void {
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        if (self.paths.items.len == 0) {
            const owned_name = try a.dupe(u8, name);
            a.free(self.name);
            self.name = owned_name;
            self.folder = folder;
            self.bytes = bytes;
            if (preview) |im| self.preview = .{ .pixels = try a.dupe(u32, im.pixels), .size = im.size };
        }
        try self.paths.append(a, owned);
    }

    pub fn key(self: *State, sym: u32) Action {
        if (sym == c.XKB_KEY_Escape) return .cancel;
        if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) {
            self.keyboard_focus = true;
            const n: usize = @intFromEnum(self.focus);
            self.focus = @enumFromInt((n + (if (sym == c.XKB_KEY_Tab) @as(usize, 1) else 2)) % 3);
        }
        if (sym == c.XKB_KEY_space or ((sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) and self.keyboard_focus)) return switch (self.focus) {
            .cancel => .cancel,
            .toggle => .toggle,
            .confirm => .confirm,
        };
        // Preserve the existing Enter-to-confirm shortcut.
        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) return .confirm;
        return .none;
    }

    pub fn draw(self: *const State, ctx: anytype, w: i32, h: i32, mx: f64, my: f64, background: ?[4]f32) void {
        const cr: *c.cairo_t = @ptrCast(ctx);
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        @import("ui").cairo.setSource(cr, dialog.backdropColor());
        c.cairo_paint(cr);
        self.drawWindow(ctx, w, h, mx, my, background);
    }

    /// Floating compositor prompts have no app-sized backdrop to dim.
    pub fn drawWindow(self: *const State, ctx: anytype, w: i32, h: i32, mx: f64, my: f64, background: ?[4]f32) void {
        const cr: *c.cairo_t = @ptrCast(ctx);
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        const g = self.geometry(w, h);
        c.cairo_translate(cr, g.x, g.y);
        var layer = shell_ui.Layer.begin(cr, .{ .x = 0, .y = 0, .w = g.width, .h = g.height }) orelse return;
        defer layer.finish();
        const r = &layer.renderer;
        var t = theme.shellPalette();
        t.font_size = shell_ui.textSize();
        t.button_font_size = shell_ui.textSize();
        r.palette = t;
        dialog.paintWindowFrame(r, layer.local(), background);
        dialog.paintWindowTitle(r, layer.local(), if (self.paths.items.len > 1) "Delete items?" else if (self.folder) "Delete folder?" else "Delete file?", .trash, null);
        const hover = g.target(mx, my);
        button.paint(r, g.close, .{ .variant = .chrome, .icon = .close, .label = "Close" }, .{ .pointer = if (hover == .close) .hover else .idle });
        r.drawText(16, g.header + 16, g.width - 32, 24, .{
            .content = if (self.permanent) "This cannot be undone." else if (self.paths.items.len == 1) "You can restore it later from Trash." else "You can restore them later from Trash.",
            .font_size = shell_ui.textSize(),
            .color = t.fg,
        });
        const inset_y = g.header + 50;
        const inset_h = @min(80, g.toggle.y - inset_y - 16);
        r.fillRect(16, inset_y, g.width - 32, inset_h, .{ .color = t.app_toolbar, .radius = t.radius_md, .border_width = 1, .border_color = t.app_item_border });
        const icon_size = @min(32, inset_h - 12);
        const icon_y = inset_y + (inset_h - icon_size) / 2;
        if (self.preview) |im| {
            r.drawImageCover(28, icon_y, icon_size, icon_size, 0, .{ .pixels = im.pixels, .width = @intCast(im.size), .height = @intCast(im.size) });
        } else r.drawIcon(28, icon_y, icon_size, icon_size, .{ .id = if (self.folder) .folder else .document, .color = t.fg });
        var buf: [256]u8 = undefined;
        const name = if (self.paths.items.len == 1) self.name else std.fmt.bufPrint(&buf, "{d} selected items", .{self.paths.items.len}) catch "Selected items";
        r.drawText(76, inset_y + @max(0, (inset_h - 48) / 2), g.width - 108, @min(24, inset_h), .{ .content = name, .font_size = shell_ui.textSize(), .weight = 600, .color = t.fg });
        var detail_buf: [128]u8 = undefined;
        const detail = if (self.paths.items.len > 1) "Files and folders in this selection" else if (self.folder) "Folder · includes its contents" else std.fmt.bufPrint(&detail_buf, "{s} · {d:.1} {s}", .{ if (std.ascii.eqlIgnoreCase(std.fs.path.extension(self.name), ".pdf")) "PDF document" else "File", @as(f64, @floatFromInt(@max(0, self.bytes))) / (if (self.bytes >= 1048576) @as(f64, 1048576) else if (self.bytes >= 1024) @as(f64, 1024) else 1), if (self.bytes >= 1048576) "MB" else if (self.bytes >= 1024) "KB" else "bytes" }) catch "File";
        if (inset_h >= 48) r.drawText(76, inset_y + (inset_h - 48) / 2 + 28, g.width - 108, 20, .{ .content = detail, .font_size = shell_ui.textSize(), .color = t.fg });
        const focus = if (self.keyboard_focus) self.focus else null;
        checkbox.paint(r, g.toggle, "Delete permanently", .{ .checked = self.permanent, .focused = focus == .toggle });
        button.paint(r, g.cancel, .{ .size = .sm, .label = "Cancel" }, .{ .focused = focus == .cancel, .pointer = if (hover == .cancel) .hover else .idle });
        button.paint(r, g.confirm, .{ .variant = .primary, .size = .sm, .leading_icon = .trash, .label = if (self.permanent) "Delete permanently" else "Move to Trash" }, .{ .focused = focus == .confirm, .pointer = if (hover == .confirm) .hover else .idle });
    }
};

pub const Geometry = struct {
    x: f64,
    y: f64,
    width: f32,
    height: f32,
    header: f32,
    close: Rect,
    toggle: Rect,
    cancel: Rect,
    confirm: Rect,

    pub fn init(w: i32, h: i32) Geometry {
        const width = @min(480, @as(f32, @floatFromInt(w)) - 24);
        const header: f32 = @floatFromInt((chrome.Metrics{}).titlebarHeight());
        const stacked = width < 440;
        const height = @min(header + @as(f32, if (stacked) 264 else 222), @as(f32, @floatFromInt(h)) - 16);
        const footer = height - 58;
        return .{
            .x = (@as(f64, @floatFromInt(w)) - width) / 2,
            .y = (@as(f64, @floatFromInt(h)) - height) / 2,
            .width = width,
            .height = height,
            .header = header,
            .close = dialog.closeBox(width),
            .toggle = .{ .x = 16, .y = footer - @as(f32, if (stacked) 42 else 0), .w = if (stacked) width - 32 else 174, .h = 34 },
            .cancel = .{ .x = width - 268, .y = footer, .w = 80, .h = 34 },
            .confirm = .{ .x = width - 180, .y = footer, .w = 164, .h = 34 },
        };
    }

    pub fn box(self: Geometry) Rect {
        return .{ .x = @floatCast(self.x), .y = @floatCast(self.y), .w = self.width, .h = self.height };
    }

    pub fn hit(self: Geometry, px: f64, py: f64) Action {
        return switch (self.target(px, py)) {
            .none => .none,
            .close, .cancel => .cancel,
            .toggle => .toggle,
            .confirm => .confirm,
        };
    }

    pub fn target(self: Geometry, px: f64, py: f64) Target {
        const x: f32 = @floatCast(px - self.x);
        const y: f32 = @floatCast(py - self.y);
        if (inside(self.close, x, y)) return .close;
        if (inside(self.cancel, x, y)) return .cancel;
        if (inside(self.toggle, x, y)) return .toggle;
        if (inside(self.confirm, x, y)) return .confirm;
        return .none;
    }
};
