//! A folder snapshot presented independently of Files' current directory.
const std = @import("std");
const App = @import("app.zig").App;
const bar = @import("app_audio_bar.zig");
const ui = @import("ui");
const menu = ui.context_menu;
const scrollbar = ui.widgets.scrollbar;
const draw = @import("app_draw.zig");
const c = @import("c.zig").api;
const tr = @import("i18n").tr;
const row_height = 32;
const heading = 44;

fn active(self: *App) bool {
    return self.audio_bar.playlist_open and bar.visible(self) and self.dialog == null and self.menu == null;
}

fn count(self: *App) usize {
    return if (self.audio_bar.playlist) |list| list.count() else 0;
}

fn rows(self: *App) usize {
    const anchor = bar.rect(self) orelse return 1;
    const room: usize = @intFromFloat(@max(32, @as(f64, @floatFromInt(self.h)) - anchor.y - anchor.h - heading - 24));
    return @max(1, @min(8, @min(count(self), room / row_height)));
}

fn box(self: *App) menu.Rect {
    const anchor = bar.rect(self).?;
    const width = @min(360, @as(f64, @floatFromInt(self.w - 16)));
    return .{ .x = @max(8, anchor.x + anchor.w - width), .y = anchor.y + anchor.h + 4, .w = width, .h = heading + @as(f64, @floatFromInt(rows(self) * row_height)) + 6 };
}

fn damage(self: *App) void {
    if (!active(self)) return;
    const b = box(self);
    self.addDamage(.{ .x = b.x - 8, .y = b.y - 8, .w = b.w + 16, .h = b.h + 16 });
}

fn scrollGeometry(self: *App) ?scrollbar.Geometry {
    const b = box(self);
    const gutter = scrollbar.gutter(self.scrollbar_width);
    return scrollbar.Geometry.compute(.vertical, .{ .x = @floatCast(b.x + b.w - gutter), .y = @floatCast(b.y + heading), .w = gutter, .h = @floatFromInt(rows(self) * row_height) }, @floatFromInt(rows(self)), @floatFromInt(count(self)), @floatFromInt(self.audio_bar.playlist_first));
}

fn rowAt(self: *App, x: f64, y: f64) ?usize {
    const b = box(self);
    const gutter: f64 = if (count(self) > rows(self)) scrollbar.gutter(self.scrollbar_width) else 0;
    if (x < b.x + 6 or x >= b.x + b.w - 6 - gutter or y < b.y + heading or y >= b.y + b.h - 6) return null;
    const index = self.audio_bar.playlist_first + @as(usize, @intFromFloat((y - b.y - heading) / row_height));
    return if (index < count(self)) index else null;
}

fn reveal(self: *App) void {
    const selected = self.audio_bar.playlist_selected;
    if (selected < self.audio_bar.playlist_first) self.audio_bar.playlist_first = selected;
    if (selected >= self.audio_bar.playlist_first + rows(self)) self.audio_bar.playlist_first = selected + 1 - rows(self);
    self.audio_bar.playlist_first = @min(self.audio_bar.playlist_first, count(self) -| rows(self));
}

pub fn toggle(self: *App) void {
    self.audio_bar.playlist_open = !self.audio_bar.playlist_open;
    self.audio_bar.playlist_drag.end();
    self.audio_bar.playlist_wheel = 0;
    self.cancelWheel();
    if (self.audio_bar.playlist_open) {
        if (self.audio_bar.playlist) |list| {
            for (0..list.count()) |i| {
                if (self.audio_state.isTrack(list.path(i))) {
                    self.audio_bar.playlist_selected = i;
                    break;
                }
            }
        }
        reveal(self);
    }
    self.invalidate();
}

fn activate(self: *App, index: usize) void {
    const list = self.audio_bar.playlist orelse return;
    if (index >= list.count()) return;
    const path = list.path(index);
    if (self.audio_state.isTrack(path)) {
        if (self.audio_link) |link| link.playPause();
    } else if (self.playAudio(path)) {
        self.worker.recordOpened(path);
    } else self.setStatusNotice(tr("Could not play the file"), true);
    self.audio_bar.playlist_selected = index;
    damage(self);
}

pub fn motion(self: *App, x: f64, y: f64) bool {
    if (!active(self)) return false;
    self.mouse_x = x;
    self.mouse_y = y;
    if (self.audio_bar.playlist_drag.active) {
        if (scrollGeometry(self)) |g| self.audio_bar.playlist_first = @intFromFloat(@round(self.audio_bar.playlist_drag.offsetAt(g, @floatCast(x), @floatCast(y))));
        damage(self);
    } else if (rowAt(self, x, y)) |index| {
        if (index != self.audio_bar.playlist_selected) {
            self.audio_bar.playlist_selected = index;
            damage(self);
        }
    }
    return true;
}

pub fn button(self: *App, code: u32, pressed: bool) bool {
    if (!active(self)) return false;
    if (!pressed) {
        self.audio_bar.playlist_drag.end();
        return true;
    }
    const x = self.mouse_x;
    const y = self.mouse_y;
    if (!box(self).contains(x, y)) {
        toggle(self);
        return true;
    }
    if (code != 0x110) return true;
    if (scrollGeometry(self)) |g| {
        if (scrollbar.press(g, @floatCast(x), @floatCast(y), @floatFromInt(self.audio_bar.playlist_first))) |press| {
            switch (press) {
                .grab => self.audio_bar.playlist_drag.begin(g, @floatCast(x), @floatCast(y), @floatFromInt(self.audio_bar.playlist_first)),
                .page => |offset| self.audio_bar.playlist_first = @intFromFloat(@round(offset)),
            }
            damage(self);
            return true;
        }
    }
    if (rowAt(self, x, y)) |index| activate(self, index);
    return true;
}

pub fn wheel(self: *App, delta: f64) bool {
    if (!active(self)) return false;
    self.audio_bar.playlist_wheel += delta / row_height;
    const whole = @trunc(self.audio_bar.playlist_wheel);
    self.audio_bar.playlist_wheel -= whole;
    const offset: f64 = @floatFromInt(self.audio_bar.playlist_first);
    const max: f64 = @floatFromInt(count(self) -| rows(self));
    self.audio_bar.playlist_first = @intFromFloat(std.math.clamp(offset + whole, 0, max));
    damage(self);
    return true;
}

pub fn key(self: *App, sym: u32) bool {
    if (!active(self)) return false;
    const n = count(self);
    switch (sym) {
        c.XKB_KEY_Escape => toggle(self),
        c.XKB_KEY_Return, c.XKB_KEY_space => activate(self, self.audio_bar.playlist_selected),
        c.XKB_KEY_Up => self.audio_bar.playlist_selected -|= 1,
        c.XKB_KEY_Down => self.audio_bar.playlist_selected = @min(n -| 1, self.audio_bar.playlist_selected + 1),
        c.XKB_KEY_Home => self.audio_bar.playlist_selected = 0,
        c.XKB_KEY_End => self.audio_bar.playlist_selected = n -| 1,
        else => {},
    }
    if (active(self)) reveal(self);
    damage(self);
    return true;
}

pub fn cursor(self: *App) ?[:0]const u8 {
    if (!active(self)) return null;
    return if (rowAt(self, self.mouse_x, self.mouse_y) != null) "pointer" else "default";
}

pub fn paint(self: *App, cr: *c.cairo_t) void {
    if (!active(self)) return;
    const b = box(self);
    menu.frame(cr, b, true);
    draw.setSource(cr, ui.theme.global.window_fg);
    draw.drawText(cr, tr("Playlist"), b.x + 12, b.y + 18, ui.cairo.textSize(), true);
    const list = self.audio_bar.playlist;
    const origin = if (list != null and list.?.count() > 0) std.fs.path.dirname(list.?.path(0)) orelse "" else "";
    draw.drawEllipsis(cr, origin, b.x + 12, b.y + 36, b.w - 24, ui.cairo.statusSize(), false);
    const gutter: f64 = if (count(self) > rows(self)) scrollbar.gutter(self.scrollbar_width) else 0;
    for (0..rows(self)) |row| {
        const index = self.audio_bar.playlist_first + row;
        if (index >= count(self)) break;
        const path = list.?.path(index);
        const r: menu.Rect = .{ .x = b.x + 6, .y = b.y + heading + @as(f64, @floatFromInt(row * row_height)), .w = b.w - 12 - gutter, .h = row_height };
        c.cairo_save(cr);
        c.cairo_rectangle(cr, r.x, r.y, r.w, r.h);
        c.cairo_clip(cr);
        menu.row(cr, r, .{ .label = "", .icon = if (self.audio_state.isTrack(path)) .music else .play, .selected = index == self.audio_bar.playlist_selected }, true);
        draw.setSource(cr, ui.theme.global.window_fg);
        draw.drawEllipsis(cr, std.fs.path.basename(path), r.x + 36, r.y + 21, r.w - 44, ui.cairo.textSize(), false);
        c.cairo_restore(cr);
    }
    if (count(self) == 0) draw.drawText(cr, tr("No audio files"), b.x + 12, b.y + heading + 21, ui.cairo.textSize(), false);
    if (scrollGeometry(self)) |g| ui.cairo.drawScrollbar(cr, scrollbar.look(g, .{}, self.scrollbar_width, ui.theme.shellPalette()));
}
