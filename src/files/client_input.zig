//! Pointer and keyboard: motion, buttons, resize edges, the titlebar, cursors, key delivery and repeat.

const std = @import("std");
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const key_repeat_mod = @import("ui").key_repeat;
const main = @import("main.zig");
const CSD_TITLEBAR_H = main.CSD_TITLEBAR_H;
const RESIZE_MARGIN = main.RESIZE_MARGIN;
const Client = @import("Client.zig");

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
            self.app.text_dragging = false;
            self.app.cancelDrag();
            self.app.handleMotion(-1, -1);
        },
        .motion => |ev| {
            self.handlePointerMotion(ev.surface_x.toDouble(), ev.surface_y.toDouble());
        },
        .button => |ev| {
            self.input_serial = ev.serial;
            if (ev.button == 0x110 and ev.state == .pressed) self.drag_serial = ev.serial;
            self.handlePointerButton(ev.button, ev.state == .pressed);
        },
        .axis => |ev| {
            if (ev.axis == .vertical_scroll) {
                self.axis_delta += ev.value.toDouble();
            } else self.horizontal_delta += ev.value.toDouble();
            if (self.pointer.?.getVersion() < 5) self.flushScroll();
        },
        .axis_source => |ev| self.axis_source = ev.axis_source,
        .axis_discrete => |ev| {
            if (ev.axis == .vertical_scroll) self.axis_notches = (self.axis_notches orelse 0) + @as(f64, @floatFromInt(ev.discrete)) else self.horizontal_notches = (self.horizontal_notches orelse 0) + @as(f64, @floatFromInt(ev.discrete));
        },
        .axis_value120 => |ev| {
            if (ev.axis == .vertical_scroll) self.axis_notches = (self.axis_notches orelse 0) + @as(f64, @floatFromInt(ev.value120)) / 120.0 else self.horizontal_notches = (self.horizontal_notches orelse 0) + @as(f64, @floatFromInt(ev.value120)) / 120.0;
        },
        .frame => self.flushScroll(),
        else => {},
    }
}

pub fn flushScroll(self: *Client) void {
    if (self.axis_source == .wheel or self.axis_source == .wheel_tilt) {
        const pixels_per_notch = 100.0;
        const pixels = if (self.axis_notches) |n| n * pixels_per_notch else self.axis_delta * (pixels_per_notch / 15.0);
        self.app.handleWheel(pixels, app_mod.nowMs());
        self.app.handleHorizontalScroll(if (self.horizontal_notches) |n| n * pixels_per_notch else self.horizontal_delta * (pixels_per_notch / 15.0));
    } else {
        if (self.axis_delta != 0) self.app.handleScroll(self.axis_delta);
        self.app.handleHorizontalScroll(self.horizontal_delta);
    }
    self.horizontal_delta = 0;
    self.horizontal_notches = null;
    self.axis_delta = 0;
    self.axis_notches = null;
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
pub fn handlePointerMotion(self: *Client, x: f64, y: f64) void {
    const old_close_hover = self.pointer_y < CSD_TITLEBAR_H and self.pointer_x >= @as(f64, @floatFromInt(self.app.w - 32));
    self.pointer_x = x;
    self.pointer_y = y;
    defer {
        if (self.app.drag_ready) {
            self.app.drag_ready = false;
            self.startFileDrag() catch self.app.setStatusNotice(@import("i18n").tr("Could not start file drag"), true);
        }
    }

    const tbh: f64 = @floatFromInt(self.titlebarHeight());
    self.app.handleMotion(x, @max(0, y - tbh));
    if (self.wantsCsd() and old_close_hover != (y < tbh and x >= @as(f64, @floatFromInt(self.app.w - 32)))) self.app.invalidate();
    self.refreshCursor();
}

pub fn refreshCursor(self: *Client) void {
    if (self.app.column_resize != null or self.app.sidebar_resize != null) {
        self.setCursor("col-resize");
        return;
    }
    const x = self.pointer_x;
    const y = self.pointer_y;
    const tbh: f64 = @floatFromInt(self.titlebarHeight());
    if (self.wantsCsd() and !self.app.text_dragging) {
        if (edgeAt(x, y, @floatFromInt(self.app.w), @as(f64, @floatFromInt(self.app.h)) + tbh)) |edge| {
            self.setCursor(cursorNameForEdge(edge));
            return;
        }
    }
    self.setCursor(if (y < tbh) "default" else self.app.pointerCursor(x, y - tbh));
}

pub fn handlePointerButton(self: *Client, button: u32, pressed: bool) void {
    defer self.refreshCursor();
    if (button == 0x110 and pressed and self.wantsCsd()) {
        const tbh_f: f64 = @floatFromInt(self.titlebarHeight());
        const w_f: f64 = @floatFromInt(self.app.w);
        const h_f: f64 = @as(f64, @floatFromInt(self.app.h)) + tbh_f;
        if (edgeAt(self.pointer_x, self.pointer_y, w_f, h_f)) |edge| {
            if (self.seat) |seat| self.xdg_toplevel.resize(seat, self.input_serial, edge);
            return;
        }
        if (self.pointer_y < tbh_f) {
            self.handleTitlebarClick(w_f, tbh_f);
            return;
        }
    }
    self.app.handleButton(button, pressed);
}

pub fn handleTitlebarClick(self: *Client, w_f: f64, tbh_f: f64) void {
    const close_w: f64 = @min(tbh_f, 32);
    if (self.pointer_x >= w_f - close_w) {
        self.app.terminalRequestClose();
        return;
    }
    if (self.seat) |seat| self.xdg_toplevel.move(seat, self.input_serial);
}

/// One press of evdev `key` through the current XKB state.
pub fn deliverKey(self: *Client, key: u32) void {
    const state = self.xkb_state orelse return;
    const sym = c.xkb_state_key_get_one_sym(state, key + 8);
    var buf: [64]u8 = undefined;
    const n = c.xkb_state_key_get_utf8(state, key + 8, &buf, buf.len);
    // Dead keys have no text of their own: sequences resolve here, and a
    // shortcut modifier abandons a half-typed one.
    if (!self.app.ctrl and !self.app.alt) {
        var composed: [64]u8 = undefined;
        if (self.compose.feed(self.locale, sym, &composed)) |text| {
            if (text.len > 0) self.app.handleKey(0, text);
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
    const key = self.key_repeat.due(key_repeat_mod.nowMs()) orelse return;
    if (!self.appRepeats(key)) return self.key_repeat.stop();
    self.deliverKey(key);
}

pub fn keyboardEvent(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Client) void {
    switch (event) {
        .enter => {
            self.app.terminal.window_focused = true;
            self.app.refreshPins();
        },
        .leave => {
            self.app.terminal.window_focused = false;
            self.key_repeat.stop();
            self.compose.reset();
            self.app.menu = null;
            self.app.ctrl = false;
            self.app.shift = false;
            self.app.alt = false;
            self.app.invalidate();
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
                if (self.drag_offer != null) {
                    self.dragOver(
                        self.drag_x,
                        self.drag_y + @as(f64, @floatFromInt(self.titlebarHeight())),
                        false,
                    );
                }
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
                self.key_repeat.press(ev.key, keymap_repeats, self.appRepeats(ev.key), key_repeat_mod.nowMs());
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
