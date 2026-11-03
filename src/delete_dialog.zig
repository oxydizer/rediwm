//! Shared modal for Files and desktop. Own the targets until confirmation.
const i18n = @import("i18n");
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
    empty_trash: bool = false,
    /// Deleting entries that are already in Trash: always permanent, so the
    /// checkbox is gone, as for Empty Trash.
    in_trash: bool = false,
    focus: enum { cancel, toggle, confirm } = .cancel,

    keyboard_focus: bool = false,

    pub fn geometry(self: *const State, w: i32, h: i32) Geometry {
        var g = Geometry.init(w, h);
        const box = self.placement.box(g.box(), w, h);
        g.x = box.x;
        g.y = box.y;
        if (self.fixedChoice()) {
            g.toggle.w = 0;
            g.toggle.h = 0;
        }
        return g;
    }

    /// Nothing to choose between: the action is permanent either way.
    pub fn fixedChoice(self: *const State) bool {
        return self.empty_trash or self.in_trash;
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
            self.focus = if (self.fixedChoice()) (if (self.focus == .cancel) .confirm else .cancel) else @enumFromInt((n + (if (sym == c.XKB_KEY_Tab) @as(usize, 1) else 2)) % 3);
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
        dialog.paintWindowTitle(r, layer.local(), if (self.empty_trash) i18n.tr("Empty Trash?") else if (self.paths.items.len > 1) i18n.tr("Delete items?") else if (self.folder) i18n.tr("Delete folder?") else i18n.tr("Delete file?"), .trash, null);
        const hover = g.target(mx, my);
        button.paint(r, g.close, .{ .variant = .chrome, .icon = .close, .label = i18n.tr("Close") }, .{ .pointer = if (hover == .close) .hover else .idle });
        // The body is the app surface: it takes the app's foreground, not the dark chrome's.
        const app = theme.global.forApp();
        t.fg = app.window_fg;
        t.dim = app.window_dim;
        t.field_bg = app.field_bg;
        t.field_border = app.field_border;
        t.surface_hover = app.surface_hover;
        r.palette = t;
        r.drawText(16, g.header + 16, g.width - 32, 24, .{
            .content = if (self.permanent) i18n.tr("This cannot be undone.") else if (self.paths.items.len == 1) i18n.tr("You can restore it later from Trash.") else i18n.tr("You can restore them later from Trash."),
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
        } else r.drawIcon(28, icon_y, icon_size, icon_size, .{ .id = if (self.empty_trash) .trash else if (self.folder) .folder else .document, .color = t.fg });
        var buf: [256]u8 = undefined;
        const name = if (self.empty_trash) i18n.tr("All items in Trash") else if (self.paths.items.len == 1) self.name else i18n.fmt(&buf, i18n.trn("{count} selected item", "{count} selected items", self.paths.items.len), .{ .count = self.paths.items.len }) catch i18n.tr("Selected items");
        r.drawText(76, inset_y + @max(0, (inset_h - 48) / 2), g.width - 108, @min(24, inset_h), .{ .content = name, .font_size = shell_ui.textSize(), .weight = 600, .color = t.fg });
        var detail_buf: [128]u8 = undefined;
        var size_buffer: [48]u8 = undefined;
        const size = std.fmt.bufPrint(&size_buffer, "{d:.1}", .{@as(f64, @floatFromInt(@max(0, self.bytes))) / (if (self.bytes >= 1048576) @as(f64, 1048576) else if (self.bytes >= 1024) @as(f64, 1024) else 1)}) catch "";
        const detail = if (self.empty_trash) i18n.tr("Permanently delete all trashed files and folders") else if (self.paths.items.len > 1) i18n.tr("Files and folders in this selection") else if (self.folder) i18n.tr("Folder · includes its contents") else i18n.fmt(&detail_buf, i18n.tr("{kind} · {size} {unit}"), .{ .kind = if (std.ascii.eqlIgnoreCase(std.fs.path.extension(self.name), ".pdf")) i18n.tr("PDF document") else i18n.tr("File"), .size = size, .unit = if (self.bytes >= 1048576) "MB" else if (self.bytes >= 1024) "KB" else i18n.tr("bytes") }) catch i18n.tr("File");
        if (inset_h >= 48) r.drawText(76, inset_y + (inset_h - 48) / 2 + 28, g.width - 108, 20, .{ .content = detail, .font_size = shell_ui.textSize(), .color = t.fg });
        const focus = if (self.keyboard_focus) self.focus else null;
        if (!self.fixedChoice()) checkbox.paint(r, g.toggle, i18n.tr("Delete permanently"), .{ .checked = self.permanent, .focused = focus == .toggle });
        button.paint(r, g.cancel, .{ .size = .sm, .label = i18n.tr("Cancel") }, .{ .focused = focus == .cancel, .pointer = if (hover == .cancel) .hover else .idle });
        button.paint(r, g.confirm, .{ .variant = .primary, .size = .sm, .leading_icon = .trash, .label = if (self.empty_trash) i18n.tr("Empty Trash") else if (self.permanent) i18n.tr("Delete permanently") else i18n.tr("Move to Trash") }, .{ .focused = focus == .confirm, .pointer = if (hover == .confirm) .hover else .idle });
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
        var palette = theme.shellPalette();
        palette.font_size = shell_ui.textSize();
        palette.button_font_size = shell_ui.textSize();
        const text = @import("ui").text;
        const permanent_width = text.measureWidthF(i18n.tr("Delete permanently"), .manrope, palette.font_size, 1) catch 146;
        const toggle_width = checkbox.box_size + checkbox.gap + permanent_width + 4;
        const cancel_label_width = text.measureWidthF(i18n.tr("Cancel"), .manrope_bold, palette.button_font_size, 1) catch 58;
        const cancel_width = @max(80, button.naturalSize(.{ .size = .sm }, palette, cancel_label_width).w + 4);
        var confirm_width: f32 = 164;
        for ([_][]const u8{ i18n.tr("Empty Trash"), i18n.tr("Delete permanently"), i18n.tr("Move to Trash") }) |label| {
            const label_width = text.measureWidthF(label, .manrope_bold, palette.button_font_size, 1) catch 120;
            confirm_width = @max(confirm_width, button.naturalSize(.{ .size = .sm, .leading_icon = .trash }, palette, label_width).w + 4);
        }
        const available = @max(1, width - 32);
        // Keep the checkbox label whole. Expanded translations get their own
        // row; every pointer target uses this same measured geometry.
        const stacked = width < 440 or toggle_width + cancel_width + confirm_width + 16 > available;
        const stacked_buttons = cancel_width + confirm_width + 8 > available;
        const height = @min(header + 222 + @as(f32, if (stacked) 42 else 0) + @as(f32, if (stacked_buttons) 42 else 0), @as(f32, @floatFromInt(h)) - 16);
        const footer = height - 58;
        const confirm_w = @min(available, confirm_width);
        const cancel_w = @min(available, cancel_width);
        const cancel_x = if (stacked_buttons) width - 16 - cancel_w else width - 16 - confirm_w - 8 - cancel_w;
        const cancel_y = footer - @as(f32, if (stacked_buttons) 42 else 0);
        return .{
            .x = (@as(f64, @floatFromInt(w)) - width) / 2,
            .y = (@as(f64, @floatFromInt(h)) - height) / 2,
            .width = width,
            .height = height,
            .header = header,
            .close = dialog.closeBox(width),
            .toggle = .{ .x = 16, .y = cancel_y - @as(f32, if (stacked) 42 else 0), .w = if (stacked) available else @max(toggle_width, cancel_x - 24), .h = 34 },
            .cancel = .{ .x = cancel_x, .y = cancel_y, .w = cancel_w, .h = 34 },
            .confirm = .{ .x = width - 16 - confirm_w, .y = footer, .w = confirm_w, .h = 34 },
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
