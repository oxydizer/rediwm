//! Find/replace controls, field focus, navigation and undoable replacements.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("../files/c.zig").api;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const field = @import("ui").widgets.field;
const button = @import("ui").widgets.button;
const Rect = @import("ui").context_menu.Rect;
const Editor = @import("../files/editor.zig").Editor;
const App = @import("app.zig").App;
const fill = @import("app.zig").fill;
const a = std.heap.c_allocator;

pub const Control = enum { query, next, toggle, close, replacement, replace, replace_all };
const order = [_]Control{ .query, .replacement, .next, .replace, .replace_all, .toggle, .close };

pub fn openSearch(self: *App, replace: bool) void {
    self.cancelDrag();
    self.find_open = true;
    self.replace_open = replace;
    self.search_focus = .query;
    self.query.select_all = true;
    self.caret_snap = true;
    self.dirty = true;
}

pub fn searchEditor(self: *App) ?*Editor {
    if (!self.find_open) return null;
    return switch (self.search_focus) {
        .query => &self.query,
        .replacement => &self.replacement,
        else => null,
    };
}

fn visible(self: *App, control: Control) bool {
    return switch (control) {
        .replacement, .replace, .replace_all => self.replace_open,
        else => true,
    };
}

pub fn searchBox(self: *App, control: Control) Rect {
    const w: f64 = @floatFromInt(self.w);
    return switch (control) {
        .query => .{ .x = 12, .y = 43, .w = w - 282, .h = 32 },
        .next => .{ .x = w - 262, .y = 43, .w = 86, .h = 32 },
        .toggle => .{ .x = w - 170, .y = 43, .w = 116, .h = 32 },
        .close => .{ .x = w - 46, .y = 43, .w = 34, .h = 32 },
        .replacement => .{ .x = 12, .y = 83, .w = w - 282, .h = 32 },
        .replace => .{ .x = w - 262, .y = 83, .w = 116, .h = 32 },
        .replace_all => .{ .x = w - 140, .y = 83, .w = 128, .h = 32 },
    };
}

pub fn searchHit(self: *App, x: f64, y: f64) ?Control {
    for (order) |control| if (visible(self, control) and self.searchBox(control).contains(x, y)) return control;
    return null;
}

pub fn findNext(self: *App, backwards: bool) void {
    const q = self.query.text.items;
    if (q.len == 0) return;
    const d = self.document();
    const sel = d.selection();
    const found = if (backwards) std.mem.lastIndexOf(u8, d.text.items[0..sel[0]], q) orelse std.mem.lastIndexOf(u8, d.text.items, q) else std.mem.indexOfPos(u8, d.text.items, sel[1], q) orelse std.mem.indexOf(u8, d.text.items, q);
    if (found) |pos| {
        d.anchor = pos;
        d.cursor = pos + q.len;
        self.notice_len = 0;
        self.reveal();
    } else self.message(tr("Text not found"));
}

fn replaceOne(self: *App) void {
    const q = self.query.text.items;
    if (q.len == 0) return;
    const d = self.document();
    var sel = d.selection();
    if (!std.mem.eql(u8, d.text.items[sel[0]..sel[1]], q)) {
        self.findNext(false);
        sel = d.selection();
        if (!std.mem.eql(u8, d.text.items[sel[0]..sel[1]], q)) return;
    }
    d.insert(self.replacement.text.items) catch |err| {
        self.failure(err);
        return;
    };
    self.reveal();
    self.findNext(false);
}

fn replaceAll(self: *App) void {
    if (self.query.text.items.len == 0) return;
    const count = self.document().replaceAll(self.query.text.items, self.replacement.text.items) catch |err| {
        self.failure(err);
        return;
    };
    if (count == 0) {
        self.message(tr("Text not found"));
        return;
    }
    self.reveal();
    var buf: [128]u8 = undefined;
    self.message(i18n.fmt(&buf, tr("Matches replaced: {count}"), .{ .count = count }) catch "");
}

pub fn searchActivate(self: *App, control: Control) void {
    if ((control == .replace or control == .replace_all) and (self.query.text.items.len == 0 or self.document().locked)) return;
    switch (control) {
        .query, .replacement => self.search_focus = control,
        .next => self.findNext(self.shift),
        .toggle => {
            self.replace_open = !self.replace_open;
            self.search_focus = if (self.replace_open) .replacement else .query;
        },
        .close => self.find_open = false,
        .replace => replaceOne(self),
        .replace_all => replaceAll(self),
    }
    self.caret_snap = true;
    self.dirty = true;
}

pub fn searchKey(self: *App, sym: u32, utf8: []const u8) void {
    if (self.ctrl and (sym == c.XKB_KEY_z or sym == c.XKB_KEY_Z or sym == c.XKB_KEY_y or sym == c.XKB_KEY_Y)) {
        self.document().undo(self.shift or sym == c.XKB_KEY_y or sym == c.XKB_KEY_Y) catch |err| self.failure(err);
        self.notice_len = 0;
        self.reveal();
    } else if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) {
        var index = std.mem.indexOfScalar(Control, &order, self.search_focus) orelse 0;
        const backwards = self.shift or sym == c.XKB_KEY_ISO_Left_Tab;
        while (true) {
            index = (index + if (backwards) order.len - 1 else @as(usize, 1)) % order.len;
            if (visible(self, order[index])) break;
        }
        self.search_focus = order[index];
        if (self.searchEditor()) |editor| editor.select_all = true;
        self.caret_snap = true;
    } else if (sym == c.XKB_KEY_F3) {
        self.findNext(self.shift);
    } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
        self.searchActivate(switch (self.search_focus) {
            .query => .next,
            .replacement => if (self.ctrl) .replace_all else .replace,
            else => self.search_focus,
        });
    } else if (self.searchEditor()) |editor| {
        if (self.ctrl and (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V)) {
            self.paste_requested = true;
        } else if (self.ctrl and (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C or sym == c.XKB_KEY_x or sym == c.XKB_KEY_X)) {
            const sel = editor.selection();
            if (sel[0] == sel[1]) return;
            self.clipboard.clearRetainingCapacity();
            self.clipboard.appendSlice(a, editor.text.items[sel[0]..sel[1]]) catch return;
            self.clipboard_revision += 1;
            if (sym == c.XKB_KEY_x or sym == c.XKB_KEY_X) editor.insert(a, "") catch |err| self.failure(err);
        } else editor.key(a, sym, utf8, self.ctrl, self.shift, self.alt);
    } else if (sym == c.XKB_KEY_space) self.searchActivate(self.search_focus);
    self.dirty = true;
}

fn textBox(self: *App, control: Control) field.Rect {
    const box = self.searchBox(control);
    return field.arrange(.{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) }, .{}, theme.global).text;
}

fn scrollField(cr: *c.cairo_t, editor: *Editor, width: f64) f64 {
    editor.normalize();
    const x = ui.measureText(cr, editor.text.items[0..editor.cursor], ui.textSize(), false);
    editor.scroll = @max(0, @max(x - width + 2, @min(editor.scroll, x)));
    return x - editor.scroll;
}

pub fn searchCaret(self: *App, cr: *c.cairo_t) @import("caret.zig").Rect {
    const editor = self.searchEditor() orelse return .{};
    const box = textBox(self, self.search_focus);
    return .{ .x = @floatCast(box.x + scrollField(cr, editor, box.w)), .y = box.y + 6, .w = 1, .h = @floatCast(ui.textSize() + 3) };
}

fn paintField(self: *App, cr: *c.cairo_t, control: Control, editor: *Editor, placeholder: []const u8) void {
    const box = self.searchBox(control);
    const focused = self.search_focus == control;
    if (ui.Layer.begin(cr, .{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) })) |l| {
        var layer = l;
        _ = field.paintFrame(&layer.renderer, layer.local(), .{}, .{ .focused = focused });
        layer.finish();
    }
    const text = textBox(self, control);
    _ = scrollField(cr, editor, text.w);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, text.x, text.y, text.w, text.h);
    c.cairo_clip(cr);
    const bytes = editor.text.items;
    const selected = editor.selection();
    const origin = text.x - editor.scroll;
    if (selected[0] != selected[1]) {
        const x = origin + ui.measureText(cr, bytes[0..selected[0]], ui.textSize(), false);
        const width = ui.measureText(cr, bytes[selected[0]..selected[1]], ui.textSize(), false);
        fill(cr, x, text.y + 3, width, text.h - 6, theme.global.app_item_selected);
    }
    var ink = theme.global.window_fg;
    if (bytes.len == 0) ink[3] *= 0.5;
    ui.setSource(cr, ink);
    ui.drawText(cr, if (bytes.len == 0) placeholder else bytes, origin, text.y + 21, ui.textSize(), false);
    if (focused) self.paintCaret(cr);
}

pub fn paintSearch(self: *App, cr: *c.cairo_t) void {
    paintField(self, cr, .query, &self.query, tr("Find…"));
    if (self.replace_open) paintField(self, cr, .replacement, &self.replacement, tr("Replace with…"));
    for (order) |control| {
        if (!visible(self, control) or control == .query or control == .replacement) continue;
        const box = self.searchBox(control);
        var layer = ui.Layer.begin(cr, .{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) }) orelse continue;
        const disabled = (control == .next or control == .replace or control == .replace_all) and (self.query.text.items.len == 0 or (control != .next and self.document().locked));
        layer.renderer.palette = theme.shellPalette();
        const proximity: button.ProximitySample = if (self.close_tab == null and !self.menu_open) self.buttonProximity(box) else .{ .distance = std.math.inf(f32), .x = 0, .y = 0 };
        button.paint(&layer.renderer, layer.local(), .{
            .label = switch (control) {
                .next => tr("Next"),
                .toggle, .replace => tr("Replace"),
                .replace_all => tr("Replace All"),
                .close => tr("Close"),
                else => unreachable,
            },
            .icon = if (control == .close) .close else null,
            .leading_icon = if (control == .toggle) (if (self.replace_open) .chevron_up else .chevron_down) else null,
            .variant = .ghost,
            .size = .sm,
        }, .{
            .selected = control == .toggle and self.replace_open,
            .focused = self.search_focus == control,
            .pointer = if (disabled) .disabled else if (self.close_tab == null and !self.menu_open and box.contains(self.px, self.py)) .hover else .idle,
            .proximity_distance = proximity.distance,
            .proximity_x = proximity.x,
            .proximity_y = proximity.y,
        });
        layer.finish();
    }
}
