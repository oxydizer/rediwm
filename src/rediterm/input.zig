//! RediTerm keyboard, pointer and wheel input. Programs that ask for the
//! mouse get it unless Shift is held; otherwise the left button selects.
const std = @import("std");
const c = @import("c_gfx");
const App = @import("app.zig").App;
const model = @import("../files/terminal/model.zig");
const tc = model.c;

fn isModifier(sym: u32) bool {
    return switch (sym) {
        c.XKB_KEY_Shift_L, c.XKB_KEY_Shift_R, c.XKB_KEY_Control_L, c.XKB_KEY_Control_R,
        c.XKB_KEY_Alt_L, c.XKB_KEY_Alt_R, c.XKB_KEY_Meta_L, c.XKB_KEY_Meta_R,
        c.XKB_KEY_Super_L, c.XKB_KEY_Super_R, c.XKB_KEY_Hyper_L, c.XKB_KEY_Hyper_R,
        c.XKB_KEY_Caps_Lock, c.XKB_KEY_Num_Lock, c.XKB_KEY_Scroll_Lock,
        c.XKB_KEY_ISO_Level3_Shift, c.XKB_KEY_ISO_Level5_Shift, c.XKB_KEY_Mode_switch,
        => true,
        else => false,
    };
}

const Shortcut = enum { copy, paste, page_up, page_down };

fn shortcut(self: *const App, sym: u32) ?Shortcut {
    if (self.ctrl and self.shift and (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C)) return .copy;
    if (self.ctrl and self.shift and (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V)) return .paste;
    if (self.shift and !self.ctrl and sym == c.XKB_KEY_Insert) return .paste;
    if (self.shift and sym == c.XKB_KEY_Page_Up) return .page_up;
    if (self.shift and sym == c.XKB_KEY_Page_Down) return .page_down;
    return null;
}

fn modifiers(self: *const App) c_int {
    return @as(c_int, if (self.shift) 1 else 0) | @as(c_int, if (self.alt) 2 else 0) | @as(c_int, if (self.ctrl) 4 else 0);
}

pub fn handleKey(self: *App, sym: u32, text: []const u8) void {
    // Modifier presses carry no input, and Ctrl+Shift must keep the
    // selection until the copy key arrives.
    if (isModifier(sym)) return;
    const session = self.session orelse return;
    if (!tc.ft_running(session)) return;
    // No frame of its own: the echo (or anything else the key changes in the
    // engine) asks for one, and drawing before it arrives would delay it.
    if (shortcut(self, sym)) |action| switch (action) {
        .copy => self.copySelection(),
        .paste => self.paste_requested = true,
        .page_up, .page_down => {
            const page: c_int = @max(1, tc.ft_rows(session) - 1);
            tc.ft_scroll(session, if (action == .page_up) page else -page);
            self.dirty = true;
        },
    } else {
        if (self.selection != null) self.dirty = true;
        self.selection = null;
        tc.ft_key(session, sym, text.ptr, text.len, modifiers(self));
    }
}

pub fn keyRepeats(self: *App, sym: u32, _: []const u8) bool {
    if (isModifier(sym)) return false;
    const action = shortcut(self, sym) orelse return true;
    return action == .page_up or action == .page_down;
}

fn row(session: *tc.FT, p: model.Point) c_int {
    return @intCast(p.line - tc.ft_line(session) + tc.ft_offset(session));
}

fn reportsMouse(self: *const App, session: *tc.FT) bool {
    return !self.shift and tc.ft_mouse_mode(session) != 0;
}

pub fn handleMotion(self: *App, x: f64, y: f64) void {
    self.mouse_x = x;
    self.mouse_y = y;
    const session = self.session orelse return;
    if (self.selecting) {
        if (self.selection) |*selection| selection.end = self.pointAt(x, y);
        self.dirty = true;
    } else if (self.mouse_buttons != 0 or reportsMouse(self, session)) {
        const p = self.pointAt(x, y);
        tc.ft_mouse(session, row(session, p), p.col, 0, false, modifiers(self));
    }
}

pub fn handleButton(self: *App, button: u32, pressed: bool) void {
    const session = self.session orelse return;
    const mouse_button: c_int = switch (button) {
        0x110 => 1,
        0x112 => 2,
        0x111 => 3,
        else => 0,
    };
    const bit: u8 = if (mouse_button > 0) @as(u8, 1) << @intCast(mouse_button - 1) else 0;
    const p = self.pointAt(self.mouse_x, self.mouse_y);
    if (!pressed) {
        if (self.mouse_buttons & bit != 0) {
            tc.ft_mouse(session, row(session, p), p.col, mouse_button, false, modifiers(self));
            self.mouse_buttons &= ~bit;
        } else if (button == 0x110 and self.selecting) {
            self.selecting = false;
            self.dirty = true;
        }
        return;
    }
    if (mouse_button != 0 and reportsMouse(self, session)) {
        tc.ft_mouse(session, row(session, p), p.col, mouse_button, true, modifiers(self));
        self.mouse_buttons |= bit;
    } else if (button == 0x110) {
        self.selection = .{ .anchor = p, .end = p };
        self.selecting = true;
        self.dirty = true;
    }
}

/// Releases buttons a program saw pressed; a selection being dragged stays.
pub fn cancelDrag(self: *App) void {
    self.selecting = false;
    const session = self.session orelse return;
    if (self.mouse_buttons != 0) {
        const p = self.pointAt(self.mouse_x, self.mouse_y);
        for (0..3) |index| {
            if (self.mouse_buttons & (@as(u8, 1) << @intCast(index)) != 0)
                tc.ft_mouse(session, row(session, p), p.col, @intCast(index + 1), false, modifiers(self));
        }
    }
    self.mouse_buttons = 0;
}

/// Positive dy is down. History scrolls on the normal screen; full-screen
/// programs get wheel buttons when they take the mouse, else arrow keys.
pub fn handleAxis(self: *App, _: f64, dy: f64) void {
    const session = self.session orelse return;
    self.wheel += dy;
    const lines: i32 = @intFromFloat(@trunc(self.wheel / @import("app.zig").wheel_step));
    if (lines == 0) return;
    self.wheel -= @as(f64, @floatFromInt(lines)) * @import("app.zig").wheel_step;
    const count: usize = @intCast(@min(@abs(lines), 16));
    if (reportsMouse(self, session)) {
        const p = self.pointAt(self.mouse_x, self.mouse_y);
        for (0..count) |_| tc.ft_mouse(session, row(session, p), p.col, if (lines < 0) 4 else 5, true, modifiers(self));
    } else if (tc.ft_alternate(session)) {
        const sym: u32 = if (lines < 0) c.XKB_KEY_Up else c.XKB_KEY_Down;
        for (0..count) |_| tc.ft_key(session, sym, "", 0, 0);
    } else tc.ft_scroll(session, -lines);
    self.dirty = true;
}
