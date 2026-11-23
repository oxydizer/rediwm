//! Pointer and keyboard: motion, buttons, resize edges, the header buttons, cursors, key delivery and repeat.

const std = @import("std");
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const c = @import("../files/c.zig").api;
const key_repeat = @import("ui").key_repeat;
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const main_mod = @import("main.zig");
const Client = main_mod.Client;
const RESIZE_MARGIN = main_mod.RESIZE_MARGIN;
const close = Client.close;

pub fn pointerEvent(_: *wl.Pointer, event: wl.Pointer.Event, self: *Client) void {
    switch (event) {
        .enter => |ev| {
            self.cursor_serial = ev.serial;
            self.input_serial = ev.serial;
            self.inside = true;
            // Force the next setCursor to reassert the image: another
            // surface may have changed the shared per-seat pointer
            // cursor while we weren't hovered.
            self.cursor_name = "";
            self.handlePointerMotion(ev.surface_x.toDouble(), ev.surface_y.toDouble());
        },
        .leave => {
            self.inside = false;
            self.app.cancelDrag();
            self.app.handleMotion(-1, -1);
            self.app.dirty = true;
        },
        .motion => |ev| {
            self.handlePointerMotion(ev.surface_x.toDouble(), ev.surface_y.toDouble());
        },
        .button => |ev| {
            self.input_serial = ev.serial;
            self.handlePointerButton(ev.button, ev.state == .pressed);
        },
        .axis => |ev| {
            if (ev.axis == .vertical_scroll) {
                self.app.handleScroll(ev.value.toDouble());
            }
        },
        else => {},
    }
}

pub fn edgeAt(x: f64, y: f64, w: f64, h: f64) ?xdg.Toplevel.ResizeEdge {
    const left = x <= RESIZE_MARGIN;
    const right = x >= w - RESIZE_MARGIN;
    const top = y <= RESIZE_MARGIN;
    const bottom = y >= h - RESIZE_MARGIN;
    if (top and left) return .top_left;
    if (top and right) return .top_right;
    if (bottom and left) return .bottom_left;
    if (bottom and right) return .bottom_right;
    if (top) return .top;
    if (bottom) return .bottom;
    if (left) return .left;
    if (right) return .right;
    return null;
}

pub fn cursorNameForEdge(edge: xdg.Toplevel.ResizeEdge) [*:0]const u8 {
    return switch (edge) {
        .top => "n-resize",
        .bottom => "s-resize",
        .left => "w-resize",
        .right => "e-resize",
        .top_left => "nw-resize",
        .top_right => "ne-resize",
        .bottom_left => "sw-resize",
        .bottom_right => "se-resize",
        .none => "default",
        else => "default",
    };
}

// Only the CSD titlebar and its resize border are handled here; anything
// below is forwarded to the App with the titlebar height subtracted so
// its hardcoded content-area layout stays oblivious to decorations.
pub fn updateCursor(self: *Client) void {
    if (self.wantsCsd() and !self.fullscreen) {
        const tbh: f64 = @floatFromInt(self.titlebarHeight());
        if (if (self.maximized) null else edgeAt(self.pointer_x, self.pointer_y, @floatFromInt(self.app.w), @as(f64, @floatFromInt(self.app.h)) + tbh)) |edge| {
            self.setCursor(cursorNameForEdge(edge));
            return;
        }
        if (self.pointer_y < tbh) {
            self.setCursor("default");
            return;
        }
    }
    self.setCursor(self.app.cursorName());
}

pub fn handlePointerMotion(self: *Client, x: f64, y: f64) void {
    const was_title = self.pointer_y < @as(f64, @floatFromInt(self.titlebarHeight()));
    self.pointer_x = x;
    self.pointer_y = y;
    const tbh: f64 = @floatFromInt(self.titlebarHeight());
    self.app.handleMotion(x, y - tbh);
    self.updateCursor();
    if (tbh > 0 and (was_title or y < tbh)) self.app.dirty = true;
}

pub fn handlePointerButton(self: *Client, button: u32, pressed: bool) void {
    if (button == 0x110 and pressed and self.wantsCsd() and !self.fullscreen) {
        const tbh_f: f64 = @floatFromInt(self.titlebarHeight());
        const w_f: f64 = @floatFromInt(self.app.w);
        const h_f: f64 = @as(f64, @floatFromInt(self.app.h)) + tbh_f;
        if (if (self.maximized) null else edgeAt(self.pointer_x, self.pointer_y, w_f, h_f)) |edge| {
            if (self.seat) |seat| self.xdg_toplevel.resize(seat, self.input_serial, edge);
            return;
        }
        if (self.pointer_y < tbh_f) {
            self.handleTitlebarClick();
            return;
        }
    }
    self.app.handleButton(button, pressed);
    self.handlePointerMotion(self.pointer_x, self.pointer_y);
}

pub const HeaderControl = enum { close, maximize, minimize, menu };

pub fn headerButton(self: *const Client, control: HeaderControl) shell_ui.Rect {
    const h: f32 = @floatFromInt(self.titlebarHeight());
    const size = @round(34 * h / 55);
    const gap = ui_theme.global.chrome_control_gap;
    const right = @round(12 * h / 55);
    const index: f32 = @floatFromInt(@intFromEnum(control));
    return .{
        .x = @as(f32, @floatFromInt(self.app.w)) - right - size - index * (size + gap) - @as(f32, if (control == .menu) 12 else 0),
        .y = (h - size) / 2,
        .w = size,
        .h = size,
    };
}

pub fn overHeaderButton(self: *const Client, control: HeaderControl) bool {
    const r = self.headerButton(control);
    return self.inside and self.pointer_x >= r.x and self.pointer_x < r.x + r.w and self.pointer_y >= r.y and self.pointer_y < r.y + r.h;
}

pub fn toggleMaximized(self: *Client) void {
    if (self.maximized) self.xdg_toplevel.unsetMaximized() else self.xdg_toplevel.setMaximized();
}

pub fn handleTitlebarClick(self: *Client) void {
    self.app.dismissMenu();
    if (self.overHeaderButton(.close)) {
        self.app.requestClose();
    } else if (self.overHeaderButton(.maximize)) {
        self.toggleMaximized();
    } else if (self.overHeaderButton(.minimize)) {
        self.xdg_toplevel.setMinimized();
    } else {
        const now = key_repeat.nowMs();
        if (self.last_title_click != 0 and now - self.last_title_click < 400) {
            self.last_title_click = 0;
            self.toggleMaximized();
        } else {
            self.last_title_click = now;
            if (self.seat) |seat| self.xdg_toplevel.move(seat, self.input_serial);
        }
    }
}

/// One press of evdev `key` through the current XKB state.
pub fn deliverKey(self: *Client, key: u32) void {
    const state = self.xkb_state orelse return;
    const sym = c.xkb_state_key_get_one_sym(state, key + 8);
    var buf: [64]u8 = undefined;
    const n = c.xkb_state_key_get_utf8(state, key + 8, &buf, buf.len);
    if (!self.app.ctrl and !self.app.alt and !self.app.menu_open) {
        var composed: [128]u8 = undefined;
        if (self.compose.feed(self.locale, sym, &composed)) |value| {
            if (value.len > 0) self.app.pasteText(value);
            return;
        }
    } else self.compose.reset();
    self.app.handleKey(sym, buf[0..@intCast(std.math.clamp(n, 0, 63))]);
}

pub fn appRepeats(self: *Client, key: u32) bool {
    if (self.compose.consumed) return false;
    const state = self.xkb_state orelse return false;
    var buf: [64]u8 = undefined;
    const n = c.xkb_state_key_get_utf8(state, key + 8, &buf, buf.len);
    return self.app.keyRepeats(c.xkb_state_key_get_one_sym(state, key + 8), buf[0..@intCast(std.math.clamp(n, 0, 63))]);
}

/// A due repeat of the held key, if the app still takes it where its
/// focus is now (a repeat may have opened a dialog or left a field).
pub fn repeatDue(self: *Client) void {
    const key = self.key_repeat.due(key_repeat.nowMs()) orelse return;
    if (!self.appRepeats(key)) return self.key_repeat.stop();
    self.deliverKey(key);
}

pub fn keyboardEvent(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Client) void {
    switch (event) {
        .enter => {
            self.app.focused = true;
            self.app.dirty = true;
        },
        .leave => {
            self.app.focused = false;
            self.app.dismissMenu();
            self.compose.reset();
            self.key_repeat.stop();
            self.app.cancelDrag();
            self.app.ctrl = false;
            self.app.shift = false;
            self.app.alt = false;
            self.app.dirty = true;
        },
        .keymap => |ev| {
            defer _ = c.close(ev.fd);
            self.key_repeat.stop();
            if (ev.format != .xkb_v1 or ev.size == 0) return;
            const memory = c.mmap(null, ev.size, c.PROT_READ, c.MAP_PRIVATE, ev.fd, 0);
            if (memory == c.MAP_FAILED) return;
            defer _ = c.munmap(memory, ev.size);

            const bytes: [*]const u8 = @ptrCast(memory);
            if (bytes[ev.size - 1] != 0) return;

            if (self.xkb_context == null) self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
            const keymap = c.xkb_keymap_new_from_string(
                self.xkb_context,
                @ptrCast(memory),
                c.XKB_KEYMAP_FORMAT_TEXT_V1,
                c.XKB_KEYMAP_COMPILE_NO_FLAGS,
            ) orelse return;
            defer c.xkb_keymap_unref(keymap);

            if (self.xkb_state) |state| c.xkb_state_unref(state);
            self.xkb_state = c.xkb_state_new(keymap);
        },
        .modifiers => |ev| {
            if (self.xkb_state) |state| {
                _ = c.xkb_state_update_mask(state, ev.mods_depressed, ev.mods_latched, ev.mods_locked, 0, 0, ev.group);
                self.app.ctrl = c.xkb_state_mod_name_is_active(state, "Control", c.XKB_STATE_MODS_EFFECTIVE) > 0;
                self.app.shift = c.xkb_state_mod_name_is_active(state, "Shift", c.XKB_STATE_MODS_EFFECTIVE) > 0;
                self.app.alt = c.xkb_state_mod_name_is_active(state, "Mod1", c.XKB_STATE_MODS_EFFECTIVE) > 0 or
                    c.xkb_state_mod_name_is_active(state, "Alt", c.XKB_STATE_MODS_EFFECTIVE) > 0;
            }
        },
        .key => |ev| {
            self.input_serial = ev.serial;
            if (ev.state == .pressed) {
                const state = self.xkb_state orelse return;
                self.deliverKey(ev.key);
                // Asked after the key, of the state it left: the repeats
                // go wherever this press put focus.
                const keymap_repeats = c.xkb_keymap_key_repeats(c.xkb_state_get_keymap(state), ev.key + 8) != 0;
                self.key_repeat.press(ev.key, keymap_repeats, self.appRepeats(ev.key), key_repeat.nowMs());
            } else self.key_repeat.release(ev.key);
        },
        .repeat_info => |ev| self.key_repeat.setInfo(ev.rate, ev.delay),
    }
}

pub fn setCursor(self: *Client, name: [*:0]const u8) void {
    if (!self.inside) return;
    if (std.mem.eql(u8, std.mem.span(self.cursor_name), std.mem.span(name))) return;
    const pointer = self.pointer orelse return;
    if (self.cursor_shape.set(pointer, self.cursor_serial, std.mem.span(name))) {
        self.cursor_name = name;
        return;
    }
    const theme_ptr = self.cursor_theme orelse return;
    const cursor = theme_ptr.getCursor(name) orelse theme_ptr.getCursor("default") orelse theme_ptr.getCursor("left_ptr") orelse return;
    if (cursor.image_count == 0) return;
    const img = cursor.images[0];
    const buffer = img.getBuffer() catch return;

    pointer.setCursor(self.cursor_serial, self.cursor_surface, @intCast(img.hotspot_x), @intCast(img.hotspot_y));
    self.cursor_surface.attach(buffer, 0, 0);
    self.cursor_surface.damage(0, 0, @intCast(img.width), @intCast(img.height));
    self.cursor_surface.commit();
    self.cursor_name = name;
}
