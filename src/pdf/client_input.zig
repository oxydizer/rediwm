//! Pointer and keyboard: motion, buttons, resize edges, the titlebar, cursors, key delivery and repeat.

const std = @import("std");
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const c = @import("c.zig");
const key_repeat = @import("ui").key_repeat;
const main_mod = @import("main.zig");
const Client = main_mod.Client;
const RESIZE_MARGIN = main_mod.RESIZE_MARGIN;

pub fn pointerEvent(_: *wl.Pointer, event: wl.Pointer.Event, self: *Client) void {
    switch (event) {
        .enter => |ev| {
            self.cursor_serial = ev.serial;
            self.input_serial = ev.serial;
            self.inside = true;
            self.cursor_name = "";
            self.handlePointerMotion(ev.surface_x.toDouble(), ev.surface_y.toDouble());
        },
        .leave => {
            self.inside = false;
            self.finger_navigation.reset();
            self.app.cancelDrag();
        },
        .motion => |ev| {
            self.handlePointerMotion(ev.surface_x.toDouble(), ev.surface_y.toDouble());
        },
        .button => |ev| {
            self.input_serial = ev.serial;
            self.handlePointerButton(ev.button, ev.state == .pressed);
        },
        .axis_source => |ev| {
            if (self.axis_source != ev.axis_source) self.finger_navigation.reset();
            self.axis_source = ev.axis_source;
        },
        .axis => |ev| {
            const delta = ev.value.toDouble();
            if (self.axis_source == .finger and !self.app.ctrl and !self.app.shift) {
                self.finger_navigation.add(ev.axis == .horizontal_scroll, delta);
                if (ev.axis == .vertical_scroll) self.app.handleScroll(delta);
            } else if (ev.axis == .vertical_scroll) {
                if (self.app.ctrl) {
                    self.app.handleZoomScroll(delta);
                } else if (self.app.shift) {
                    self.app.handleHorizontalScroll(delta);
                } else {
                    self.app.handleScroll(delta);
                }
            } else if (ev.axis == .horizontal_scroll) {
                self.app.handleHorizontalScroll(delta);
            }
        },
        .axis_stop => |ev| {
            if (self.axis_source == .finger) {
                if (self.finger_navigation.stop(ev.axis == .horizontal_scroll)) |gesture| {
                    if (self.app.dialog == .none) {
                        if (gesture.direction) |direction| {
                            if (self.app.n_pages > 0) {
                                switch (direction) {
                                    .back => if (self.app.current_page > 0)
                                        self.app.goToPage(self.app.current_page - 1),
                                    .forward => if (self.app.current_page < self.app.n_pages - 1)
                                        self.app.goToPage(self.app.current_page + 1),
                                }
                            }
                        } else {
                            self.app.handleHorizontalScroll(gesture.horizontal_delta);
                        }
                    }
                }
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

pub fn updateCursor(self: *Client) void {
    if (!self.inside) return;
    const tbh_f: f64 = @floatFromInt(self.titlebarHeight());
    const w_f: f64 = @floatFromInt(self.app.w);
    const h_f: f64 = @as(f64, @floatFromInt(self.app.h)) + tbh_f;
    if (self.wantsCsd()) {
        if (edgeAt(self.pointer_x, self.pointer_y, w_f, h_f)) |edge| {
            self.setCursor(switch (edge) {
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
            });
            return;
        }
    }
    self.setCursor(self.app.cursorName());
}

pub fn handlePointerMotion(self: *Client, x: f64, y: f64) void {
    self.pointer_x = x;
    self.pointer_y = y;
    const tbh: f64 = @floatFromInt(self.titlebarHeight());
    self.app.handleMotion(x, y - tbh);
    self.updateCursor();
    if (tbh > 0 and y < tbh) self.app.dirty = true;
}

pub fn handlePointerButton(self: *Client, button: u32, pressed: bool) void {
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
    self.handlePointerMotion(self.pointer_x, self.pointer_y);
}

pub fn handleTitlebarClick(self: *Client, w_f: f64, tbh_f: f64) void {
    const close_w: f64 = @min(tbh_f, 32.0);
    if (self.pointer_x >= w_f - close_w) {
        self.app.requestClose();
        return;
    }
    if (self.seat) |seat| self.xdg_toplevel.move(seat, self.input_serial);
}

pub fn deliverKey(self: *Client, key: u32) void {
    const state = self.xkb_state orelse return;
    const sym = c.api.xkb_state_key_get_one_sym(state, key + 8);
    var buf: [64]u8 = undefined;
    const n = c.api.xkb_state_key_get_utf8(state, key + 8, &buf, buf.len);
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
    const n = c.api.xkb_state_key_get_utf8(state, key + 8, &buf, buf.len);
    return self.app.keyRepeats(c.api.xkb_state_key_get_one_sym(state, key + 8), buf[0..@intCast(std.math.clamp(n, 0, 63))]);
}

pub fn repeatDue(self: *Client) void {
    const key = self.key_repeat.due(key_repeat.nowMs()) orelse return;
    if (!self.appRepeats(key)) return self.key_repeat.stop();
    self.deliverKey(key);
}

pub fn keyboardEvent(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Client) void {
    switch (event) {
        .leave => {
            self.key_repeat.stop();
            self.compose.reset();
            self.app.cancelDrag();
            self.app.ctrl = false;
            self.app.shift = false;
            self.app.alt = false;
            self.app.dirty = true;
        },
        .keymap => |ev| {
            defer _ = c.api.close(ev.fd);
            self.key_repeat.stop();
            if (ev.format != .xkb_v1 or ev.size == 0) return;
            const memory = c.api.mmap(null, ev.size, c.api.PROT_READ, c.api.MAP_PRIVATE, ev.fd, 0);
            if (memory == c.api.MAP_FAILED) return;
            defer _ = c.api.munmap(memory, ev.size);

            const bytes: [*]const u8 = @ptrCast(memory);
            if (bytes[ev.size - 1] != 0) return;

            if (self.xkb_context == null) self.xkb_context = c.api.xkb_context_new(c.api.XKB_CONTEXT_NO_FLAGS);
            const keymap = c.api.xkb_keymap_new_from_string(
                self.xkb_context,
                @ptrCast(memory),
                c.api.XKB_KEYMAP_FORMAT_TEXT_V1,
                c.api.XKB_KEYMAP_COMPILE_NO_FLAGS,
            ) orelse return;
            defer c.api.xkb_keymap_unref(keymap);

            if (self.xkb_state) |state| c.api.xkb_state_unref(state);
            self.xkb_state = c.api.xkb_state_new(keymap);
        },
        .modifiers => |ev| {
            if (self.xkb_state) |state| {
                _ = c.api.xkb_state_update_mask(state, ev.mods_depressed, ev.mods_latched, ev.mods_locked, 0, 0, ev.group);
                self.app.ctrl = c.api.xkb_state_mod_name_is_active(state, "Control", c.api.XKB_STATE_MODS_EFFECTIVE) > 0;
                self.app.shift = c.api.xkb_state_mod_name_is_active(state, "Shift", c.api.XKB_STATE_MODS_EFFECTIVE) > 0;
                self.app.alt = c.api.xkb_state_mod_name_is_active(state, "Mod1", c.api.XKB_STATE_MODS_EFFECTIVE) > 0 or
                    c.api.xkb_state_mod_name_is_active(state, "Alt", c.api.XKB_STATE_MODS_EFFECTIVE) > 0;
            }
        },
        .key => |ev| {
            self.input_serial = ev.serial;
            if (ev.state == .pressed) {
                const state = self.xkb_state orelse return;
                self.deliverKey(ev.key);
                const keymap_repeats = c.api.xkb_keymap_key_repeats(c.api.xkb_state_get_keymap(state), ev.key + 8) != 0;
                self.key_repeat.press(ev.key, keymap_repeats, self.appRepeats(ev.key), key_repeat.nowMs());
            } else self.key_repeat.release(ev.key);
        },
        .repeat_info => |ev| self.key_repeat.setInfo(ev.rate, ev.delay),
        else => {},
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
