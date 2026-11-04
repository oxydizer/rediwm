//! Geometry, toolbar actions, zoom and navigation, keyboard, pointer and scroll input.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("../files/c.zig").api;
const view = @import("view.zig");
const cache_mod = @import("cache.zig");
const Rect = view.Rect;
const edit = @import("edit.zig");
const scrollbar = @import("ui").widgets.scrollbar;
const button_widget = @import("ui").widgets.button;
const ui_theme = @import("ui").theme;
const a = std.heap.c_allocator;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Action = app_mod.Action;

pub fn canvas(self: *const App) Rect {
    const top = self.toolbarBottom() + 28;
    return .{ .x = 16, .y = top, .w = @floatFromInt(@max(1, self.w - 32)), .h = @max(1, @as(f64, @floatFromInt(self.h)) - top - self.thumbHeight() - 48) };
}

pub fn buttonRect(self: *const App, action: Action) Rect {
    const columns: usize = if (self.w < 740) 6 else 12;
    const width = (@as(f64, @floatFromInt(self.w)) - 24) / @as(f64, @floatFromInt(columns));
    const n = @intFromEnum(action);
    return .{ .x = 12 + @as(f64, @floatFromInt(n % columns)) * width, .y = 8 + @as(f64, @floatFromInt(n / columns)) * 40, .w = width - 4, .h = 36 };
}

pub fn buttonProximity(
    self: *const App,
    action: Action,
    x: f64,
    y: f64,
) button_widget.ProximitySample {
    const rect = self.buttonRect(action);
    const absent = button_widget.ProximitySample{
        .distance = std.math.inf(f32),
        .x = @floatCast(x - rect.x),
        .y = @floatCast(y - rect.y),
    };
    if (self.dialog != .none or self.operation != null or !self.enabled(action))
        return absent;

    return button_widget.sampleProximity(
        .{
            .x = @floatCast(rect.x),
            .y = @floatCast(rect.y),
            .w = @floatCast(rect.w),
            .h = @floatCast(rect.h),
        },
        @floatCast(x),
        @floatCast(y),
        .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.w),
            .h = @floatCast(self.toolbarBottom()),
        },
    );
}

fn toolbarProximityChanged(
    self: *const App,
    old_x: f64,
    old_y: f64,
    new_x: f64,
    new_y: f64,
) bool {
    const reach = ui_theme.global.border_glow_reach;
    if (!button_widget.proximityGlowVisible(ui_theme.global) or
        self.dialog != .none or self.operation != null)
        return false;

    for (std.meta.tags(Action)) |action| {
        const before = self.buttonProximity(action, old_x, old_y);
        const after = self.buttonProximity(action, new_x, new_y);
        if (@min(before.distance, after.distance) <= reach) return true;
    }
    return false;
}

pub fn hit(self: *const App, x: f64, y: f64) ?Action {
    inline for (std.meta.tags(Action)) |action| if (self.buttonRect(action).contains(x, y)) return action;
    return null;
}

pub fn clamp(self: *App) void {
    if (self.image) |im| self.view.clamp(self.canvas(), @floatFromInt(im.w), @floatFromInt(im.h));
}

pub fn zoom(self: *App, factor: f64, x: f64, y: f64) void {
    if (self.image) |im| {
        self.view.zoomAt(factor, x, y, self.canvas(), @floatFromInt(im.w), @floatFromInt(im.h));
        self.dirty = true;
    }
}

pub fn navigate(self: *App, forward: bool) void {
    const pos = self.position();
    const index = self.indexAt(if (forward) @min(pos + 1, self.count() - 1) else pos -| 1);
    if (index != self.selected) self.requestSelect(index);
}

pub fn perform(self: *App, act: Action) void {
    if (self.closed or self.operation != null or !self.enabled(act)) return;
    self.cancelDrag();
    const box = self.canvas();
    switch (act) {
        .back => self.requestClose(),
        .previous => self.navigate(false),
        .next => self.navigate(true),
        .rotate => {
            if (self.image) |im| self.replaceImage(edit.rotate(im) catch {
                self.message(tr("Could not rotate: not enough memory."));
                return;
            });
        },
        .crop => if (self.crop_mode) self.applyCrop() else self.beginCrop(),
        .undo => self.undo(),
        .save => self.openSave(),
        .trash => {
            self.cancelDrag();
            self.trash_stamp = cache_mod.Stamp.read(self.paths[self.selected]);
            self.deletion.deinit();
            self.deletion.add(self.paths[self.selected], std.fs.path.basename(self.paths[self.selected]), false, if (self.trash_stamp) |stamp| stamp.size else 0, null) catch {
                self.deletion.deinit();
                self.message(tr("Could not open the delete dialog."));
                return;
            };
            self.deletion.permanent = self.shift;
            self.dialog = .trash;
            self.notice_len = 0;
        },
        .smaller => self.zoom(1.0 / 1.25, box.x + box.w / 2, box.y + box.h / 2),
        .larger => self.zoom(1.25, box.x + box.w / 2, box.y + box.h / 2),
        .fit => {
            self.view.fitting = true;
            self.view.pan_x = 0;
            self.view.pan_y = 0;
        },
        .actual => {
            self.view.fitting = false;
            self.view.zoom = 1 / self.density;
            self.clamp();
        },
    }
    self.dirty = true;
}

/// Which held keys the client repeats: typing in the save dialog's name
/// field; stepping through images and zooming otherwise. Delete, rotate,
/// crop and the rest fire once.
pub fn keyRepeats(self: *const App, sym: u32, utf8: []const u8) bool {
    if (self.ctrl or self.alt) return false;
    if (self.dialog != .none) return self.dialog == .save and @import("ui").key_repeat.editingKey(switch (sym) {
        c.XKB_KEY_BackSpace, c.XKB_KEY_Delete, c.XKB_KEY_Left, c.XKB_KEY_Right => true,
        else => false,
    }, utf8);
    if (self.crop_mode) return false;
    return switch (sym) {
        c.XKB_KEY_Left, c.XKB_KEY_Right, c.XKB_KEY_plus, c.XKB_KEY_equal, c.XKB_KEY_KP_Add, c.XKB_KEY_minus, c.XKB_KEY_KP_Subtract => true,
        else => false,
    };
}

pub fn handleKey(self: *App, sym: u32, utf8: []const u8) void {
    if (self.closed or self.operation != null) return;
    if (self.dialog == .trash) {
        self.deleteAction(self.deletion.key(sym));
        return;
    }
    if (self.dialog != .none) {
        self.cancelDrag();
        if (sym == c.XKB_KEY_Escape) {
            self.dialog = .none;
            self.pending = .none;
            self.notice_len = 0;
        } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) self.confirmDialog() else if (self.dialog == .save) self.filename.key(a, sym, utf8, self.ctrl, self.shift, self.alt);
        self.dirty = true;
        return;
    }
    if (self.ctrl) {
        if (sym == c.XKB_KEY_s or sym == c.XKB_KEY_S) self.perform(.save);
        if (sym == c.XKB_KEY_z or sym == c.XKB_KEY_Z) self.perform(.undo);
        return;
    }
    if (self.alt) return;
    if (self.crop_mode) {
        if (sym == c.XKB_KEY_Escape) {
            self.crop_mode = false;
            self.crop_drag = false;
            self.dirty = true;
            return;
        }
        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
            self.applyCrop();
            return;
        }
    }
    switch (sym) {
        c.XKB_KEY_Escape, c.XKB_KEY_space => self.perform(.back),
        c.XKB_KEY_Left => self.perform(.previous),
        c.XKB_KEY_Right => self.perform(.next),
        c.XKB_KEY_r, c.XKB_KEY_R => self.perform(.rotate),
        c.XKB_KEY_c, c.XKB_KEY_C => self.perform(.crop),
        c.XKB_KEY_Delete => self.perform(.trash),
        c.XKB_KEY_plus, c.XKB_KEY_equal, c.XKB_KEY_KP_Add => self.perform(.larger),
        c.XKB_KEY_minus, c.XKB_KEY_KP_Subtract => self.perform(.smaller),
        c.XKB_KEY_f, c.XKB_KEY_F, c.XKB_KEY_0 => self.perform(.fit),
        c.XKB_KEY_1 => self.perform(.actual),
        c.XKB_KEY_Home => self.requestSelect(self.indexAt(0)),
        c.XKB_KEY_End => self.requestSelect(self.indexAt(self.count() - 1)),
        else => {},
    }
}

pub fn handleMotion(self: *App, x: f64, y: f64) void {
    if (self.closed) return;
    const old_x = self.px;
    const old_y = self.py;
    if (self.dialog == .trash) {
        if (self.deletion.motion(self.w, self.h, x, y)) self.dirty = true;
        const g = self.deletion.geometry(self.w, self.h);
        if (g.target(self.px, self.py) != g.target(x, y)) self.dirty = true;
    }
    const hover = if (self.dialog == .none and self.operation == null) self.hit(x, y) else null;
    if (hover != self.hover) {
        self.hover = hover;
        self.dirty = true;
    }
    if (toolbarProximityChanged(self, old_x, old_y, x, y)) self.toolbar_dirty = true;
    if (self.operation != null or (self.dialog != .none and !self.filename_drag)) {
        self.px = x;
        self.py = y;
        return;
    }
    if (self.filename_drag) {
        self.px = x;
        self.py = y;
        self.placeCaret(true);
        self.dirty = true;
    } else if (self.strip_drag.active) self.dragStrip(x, y) else if (self.crop_drag) {
        const p = self.imagePoint(x, y);
        self.crop_rect = .{ .x = @min(p[0], self.crop_start[0]), .y = @min(p[1], self.crop_start[1]), .w = @abs(p[0] - self.crop_start[0]), .h = @abs(p[1] - self.crop_start[1]) };
        self.dirty = true;
    } else if (self.dragging) {
        self.view.pan_x += x - self.px;
        self.view.pan_y += y - self.py;
        self.clamp();
        self.dirty = true;
    }
    self.px = x;
    self.py = y;
}

pub fn handleButton(self: *App, button: u32, pressed: bool) void {
    if (self.closed or button != 0x110) return;
    if (self.dialog == .trash and self.deletion.pointerButton(self.w, self.h, self.px, self.py, pressed)) return;
    if (!pressed) {
        self.cancelDrag();
        return;
    }
    if (self.operation != null) return;
    if (self.dialog == .trash) {
        self.deletion.keyboard_focus = false;
        self.deleteAction(self.deletion.geometry(self.w, self.h).hit(self.px, self.py));
        return;
    }
    if (self.dialog != .none) {
        if (self.dialogButton(0).contains(self.px, self.py)) {
            self.dialog = .none;
            self.pending = .none;
            self.notice_len = 0;
        } else if (self.dialogButton(1).contains(self.px, self.py)) {
            if (self.dialog == .discard) self.finishPending() else self.confirmDialog();
        } else if (self.dialog == .discard and self.dialogButton(2).contains(self.px, self.py)) self.openSave() else if (self.dialog == .save and self.filenameRect().contains(self.px, self.py)) {
            self.placeCaret(self.shift);
            self.filename_drag = true;
        }
        self.dirty = true;
        return;
    }
    if (self.hit(self.px, self.py)) |act| {
        self.perform(act);
        return;
    }
    if (self.stripBar()) |bar| {
        const start: f32 = @floatFromInt(self.thumbStart());
        if (scrollbar.press(bar, @floatCast(self.px), @floatCast(self.py), start)) |action| {
            switch (action) {
                .grab => self.strip_drag.begin(bar, @floatCast(self.px), @floatCast(self.py), start),
                .page => |offset| self.scrollStrip(@intFromFloat(@round(offset))),
            }
            return;
        }
    }
    for (0..self.thumbCount()) |slot| {
        if (self.thumbRect(slot).contains(self.px, self.py)) {
            self.requestSelect(self.indexAt(self.thumbStart() + slot));
            return;
        }
    }
    if (self.crop_mode and self.imageRect().contains(self.px, self.py) and self.canvas().contains(self.px, self.py)) {
        self.crop_start = self.imagePoint(self.px, self.py);
        self.crop_rect = .{ .x = self.crop_start[0], .y = self.crop_start[1], .w = 0, .h = 0 };
        self.crop_drag = true;
        self.dirty = true;
    } else self.dragging = !self.crop_mode and self.image != null and self.canvas().contains(self.px, self.py) and !self.view.fitting;
}

pub fn cancelDrag(self: *App) void {
    self.deletion.placement.grab = null;
    if (self.dragging or self.strip_drag.active or self.crop_drag or self.filename_drag) self.dirty = true;
    self.dragging = false;
    self.strip_drag.end();
    self.crop_drag = false;
    self.filename_drag = false;
}

pub fn overFilmstrip(self: *const App) bool {
    return self.count() > 0 and self.py >= self.thumbRect(0).y - 8;
}

pub fn handleScroll(self: *App, amount: f64) void {
    if (self.closed or amount == 0 or self.dialog != .none or self.operation != null) return;
    if (self.overFilmstrip()) {
        self.scrollStrip(if (amount > 0) self.thumbStart() + 1 else self.thumbStart() -| 1);
    } else if (!self.crop_mode and self.canvas().contains(self.px, self.py)) self.zoom(if (amount < 0) 1.15 else 1.0 / 1.15, self.px, self.py);
}

pub fn count(self: *const App) usize {
    return if (self.order.capacity > 0) self.order.items.len else self.paths.len;
}

pub fn indexAt(self: *const App, pos: usize) usize {
    return if (self.order.capacity > 0) self.order.items[pos] else pos;
}

pub fn position(self: *const App) usize {
    if (self.order.capacity == 0) return self.selected;
    for (self.order.items, 0..) |idx, pos| if (idx == self.selected) return pos;
    return 0;
}

pub fn toolbarBottom(self: *const App) f64 {
    return if (self.w < 740) 84 else 44;
}

pub fn enabled(self: *const App, act: Action) bool {
    return switch (act) {
        .previous => self.position() > 0,
        .next => self.position() + 1 < self.count(),
        .rotate, .crop, .save => self.image != null,
        .smaller, .larger, .fit, .actual => self.image != null and !self.crop_mode,
        .undo => self.original != null,
        else => true,
    };
}

pub fn message(self: *App, msg: []const u8) void {
    const n = @min(msg.len, self.notice.len);
    @memcpy(self.notice[0..n], msg[0..n]);
    self.notice_len = n;
    self.dirty = true;
}

pub fn revealSelected(self: *App) void {
    const pos = self.position();
    const start = self.thumbStart();
    self.strip_start = if (pos < start) pos else if (pos >= start + self.thumbCount()) pos + 1 - self.thumbCount() else start;
}

test "Images toolbar proximity drives redraws outside direct hover" {
    const paths = [_][:0]const u8{"/nonexistent/image.png"};
    var app: App = .{
        .paths = &paths,
        .selected = 0,
        .loader = undefined,
        .thumbnail_loader = undefined,
    };

    const saved_theme = ui_theme.global;
    defer ui_theme.global = saved_theme;
    ui_theme.global.button_hover_glow_enabled = true;
    ui_theme.global.border_glow_reach = 56;

    const rect = app.buttonRect(.back);
    const x = rect.x + rect.w / 2;
    const y = rect.y - 4;
    const sample = buttonProximity(&app, .back, x, y);

    try std.testing.expectApproxEqAbs(@as(f32, 4), sample.distance, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, @floatCast(rect.w / 2)), sample.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -4), sample.y, 0.001);

    const disabled = buttonProximity(&app, .previous, x, y);
    try std.testing.expect(std.math.isInf(disabled.distance));

    app.px = 500;
    app.py = 500;
    // Glow alone repaints the toolbar strip, never the whole window.
    app.dirty = false;
    app.handleMotion(x, y);
    try std.testing.expect(app.toolbar_dirty and !app.dirty);
    try std.testing.expect(app.hover == null);

    app.toolbar_dirty = false;
    app.handleMotion(500, 500);
    try std.testing.expect(app.toolbar_dirty and !app.dirty);
}
