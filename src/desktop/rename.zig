const std = @import("std");
const c = @import("c.zig").api;
const grid = @import("grid.zig");
const text = @import("ui").text;
const input = @import("ui").widgets.text_input;
const Widget = @import("ui").layout.Widget;
const shell_ui = @import("ui").cairo;
const ui_field = @import("ui").widgets.field;
const ui_button = @import("ui").widgets.button;
const ui_theme = @import("ui").theme;
const a = std.heap.c_allocator;

pub const Geometry = struct {
    panel: grid.Rect,
    field: grid.Rect,
    confirm: grid.Rect,
    cancel: grid.Rect,

    pub fn init(icon: grid.Rect, desktop: grid.Grid) Geometry {
        const w = @min(236, @max(80, desktop.w - 8));
        const x = std.math.clamp(icon.x + @divTrunc(icon.w - w, 2), 4, @max(4, desktop.w - w - 4));
        const y = std.math.clamp(icon.y + 70, 4, @max(4, desktop.h - desktop.bottom - 48));
        return .{
            .panel = .{ .x = x, .y = y, .w = w, .h = 44 },
            .field = .{ .x = x + 6, .y = y + 6, .w = w - 70, .h = 32 },
            .confirm = .{ .x = x + w - 62, .y = y + 6, .w = 28, .h = 32 },
            .cancel = .{ .x = x + w - 34, .y = y + 6, .w = 28, .h = 32 },
        };
    }
};

pub const Editor = struct {
    field: Widget = .{ .kind = .{ .text_input = .{ .placeholder = "", .value = &.{}, .on_change = changed } } },
    scroll: f64 = 0,
    raster_scale: f32 = 1,
    selecting: bool = false,

    fn changed(_: ?*anyopaque, _: usize, _: []const u8) void {}
    pub fn deinit(self: *Editor) void {
        a.free(self.field.kind.text_input.value);
        self.* = .{};
    }
    pub fn begin(self: *Editor, name: []const u8, folder: bool) !void {
        const owned = try a.dupe(u8, name);
        self.deinit();
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
        const end = if (!folder and dot > 0) dot else name.len;
        self.field.kind.text_input.value = owned;
        self.field.kind.text_input.cursor_pos = end;
        self.field.kind.text_input.selection_anchor = 0;
    }
    pub fn value(self: *const Editor) []const u8 {
        return self.field.kind.text_input.value;
    }
    pub fn key(self: *Editor, sym: u32, utf8: []const u8, ctrl: bool, shift: bool) void {
        switch (sym) {
            c.XKB_KEY_Left => input.moveCursorLeft(&self.field, shift),
            c.XKB_KEY_Right => input.moveCursorRight(&self.field, shift),
            c.XKB_KEY_Home => input.moveCursorHome(&self.field, shift),
            c.XKB_KEY_End => input.moveCursorEnd(&self.field, shift),
            c.XKB_KEY_BackSpace => input.backspace(a, &self.field) catch {},
            c.XKB_KEY_Delete => input.deleteForward(a, &self.field) catch {},
            else => {
                if (ctrl) {
                    if (sym == c.XKB_KEY_a or sym == c.XKB_KEY_A) input.selectAll(&self.field);
                } else if (utf8.len > 0 and utf8[0] >= 32) {
                    const data = self.field.kind.text_input;
                    const selected = data.selectedText().len;
                    if (data.value.len - selected + utf8.len <= 255) input.insertText(a, &self.field, utf8) catch {};
                }
            },
        }
    }
    pub fn point(self: *Editor, g: Geometry, x: f64, extend: bool) void {
        const target = x - (textArea(g).x - self.scroll);
        const pos = text.offsetAtX(self.value(), .manrope, font_size, self.raster_scale, @floatCast(target)) catch return;
        input.setCursor(&self.field, pos, extend);
    }
    fn measure(self: *const Editor, value_: []const u8) f64 {
        return text.measureWidthF(value_, .manrope, font_size, self.raster_scale) catch 0;
    }

    /// A popover card holding the shared field and ✓ / ✕ buttons.
    pub fn draw(self: *Editor, cr: *c.cairo_t, g: Geometry, mx: f64, my: f64) void {
        const t = ui_theme.shellPalette();
        const p = g.panel;
        if (shell_ui.Layer.begin(cr, rectOf(p))) |begun| {
            var layer = begun;
            const r = &layer.renderer;
            r.fillRect(0, 0, @floatFromInt(p.w), @floatFromInt(p.h), .{ .color = .{ t.window_bg[0], t.window_bg[1], t.window_bg[2], 1 }, .radius = 12, .border_width = 1, .border_color = t.border_hover });
            _ = ui_field.paintFrame(r, local(g.field, p), .{}, .{ .focused = true });
            for ([_]grid.Rect{ g.confirm, g.cancel }, 0..) |b, i| ui_button.paint(r, local(b, p), .{
                .variant = .ghost,
                .icon = if (i == 0) .checkmark else .close,
                .icon_scale = 0.55,
                .label = if (i == 0) "Rename" else "Cancel",
            }, .{ .pointer = if (b.contains(mx, my)) .hover else .idle });
            layer.finish();
        }
        self.raster_scale = shell_ui.scaleOf(cr);
        const area = textArea(g);
        const data = self.field.kind.text_input;
        const caret = self.measure(data.value[0..data.cursor_pos]);
        const visible = area.w - 2;
        self.scroll = std.math.clamp(self.scroll, @max(0, caret - visible + 1), caret);
        self.scroll = @min(self.scroll, @max(0, self.measure(data.value) - visible + 1));
        self.scroll = @round(self.scroll * self.raster_scale) / self.raster_scale;
        const origin = area.x - self.scroll;
        const m = shell_ui.fontMetrics(cr, font_size);
        const ink = m.ascent + m.descent;
        const top = area.y + (area.h - ink) / 2;
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        c.cairo_rectangle(cr, area.x, area.y, area.w, area.h);
        c.cairo_clip(cr);
        if (data.selection()) |range| {
            setSource(cr, t.selectionColor());
            c.cairo_rectangle(cr, origin + self.measure(data.value[0..range.start]), top, self.measure(data.value[0..range.end]) - self.measure(data.value[0..range.start]), ink);
            c.cairo_fill(cr);
        }
        setSource(cr, t.fg);
        shell_ui.drawText(cr, data.value, origin, top + m.ascent, font_size, false);
        if (data.selection() == null) {
            setSource(cr, t.caretColor());
            c.cairo_rectangle(cr, origin + caret, top, t.caret_width, ink);
            c.cairo_fill(cr);
        }
    }
};

const font_size = 13;

/// Where the name runs inside the field, in desktop coordinates.
fn textArea(g: Geometry) ui_field.Rect {
    return ui_field.arrange(rectOf(g.field), .{}, ui_theme.shellPalette()).text;
}

fn rectOf(r: grid.Rect) ui_field.Rect {
    return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
}

fn local(r: grid.Rect, origin: grid.Rect) ui_field.Rect {
    return .{ .x = @floatFromInt(r.x - origin.x), .y = @floatFromInt(r.y - origin.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
}

fn setSource(cr: *c.cairo_t, color: [4]f32) void {
    c.cairo_set_source_rgba(cr, color[0], color[1], color[2], color[3]);
}

test "rename selects a file stem, but whole dotfiles and folder names" {
    var editor = Editor{};
    defer editor.deinit();
    for ([_]struct { name: []const u8, folder: bool, selected: []const u8 }{
        .{ .name = "Project Brief.pdf", .folder = false, .selected = "Project Brief" },
        .{ .name = ".config", .folder = false, .selected = ".config" },
        .{ .name = "Folder.name", .folder = true, .selected = "Folder.name" },
        .{ .name = "archive.tar.gz", .folder = false, .selected = "archive.tar" },
    }) |case| {
        try editor.begin(case.name, case.folder);
        try std.testing.expectEqualStrings(case.selected, editor.field.kind.text_input.selectedText());
    }
    try editor.begin("Résumé.txt", false);
    editor.key(0, "Café", false, false);
    try std.testing.expectEqualStrings("Café.txt", editor.value());
    editor.key(c.XKB_KEY_BackSpace, "", false, false);
    try std.testing.expectEqualStrings("Caf.txt", editor.value());
    editor.key(c.XKB_KEY_a, "", true, false);
    try std.testing.expectEqualStrings("Caf.txt", editor.value());
    editor.key(c.XKB_KEY_Right, "", false, false);
    editor.key(c.XKB_KEY_Left, "", false, true);
    editor.key(0, "T", false, false);
    try std.testing.expectEqualStrings("Caf.txT", editor.value());
}

test "rename controls fit within the usable desktop at grid edges" {
    const desktop = grid.Grid{ .w = 1280, .h = 720 };
    for ([_]grid.Cell{ .{}, .{ .col = desktop.cols() - 1, .row = desktop.rows() - 1 } }) |cell| {
        const g = Geometry.init(desktop.rect(cell), desktop);
        try std.testing.expect(g.panel.x >= 0 and g.panel.x + g.panel.w <= desktop.w);
        try std.testing.expect(g.panel.y >= 0 and g.panel.y + g.panel.h <= desktop.h - desktop.bottom);
        try std.testing.expect(g.field.x + g.field.w <= g.confirm.x);
        try std.testing.expect(g.confirm.x + g.confirm.w <= g.cancel.x);
    }
}
