//! Standalone System Monitor Wayland host. Uses the same decoration, input,
//! cursor and released-buffer lifecycle as the other native RediWM clients.
const std = @import("std");
const platform = @import("platform");
const ClientCursor = @import("ui").client_cursor;
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const wp = @import("wayland").client.wp;
const zxdg = @import("wayland").client.zxdg;
const c = @import("../files/c.zig").api;
const app_mod = @import("app.zig");
const key_repeat = @import("ui").key_repeat;
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const a = std.heap.c_allocator;
const ui = @import("ui");

// A window with no server-side decorations must draw its own titlebar so it
// stays usable (movable, closable) on compositors that don't implement
// zxdg-decoration, e.g. GNOME/Mutter. See plan-file-manager.md section 1.
const CSD_TITLEBAR_H: i32 = 32;
const RESIZE_MARGIN: f64 = 6;

const DecorationMode = enum { unknown, client_side, server_side };

const OutputInfo = struct {
    client: *Client,
    proxy: *wl.Output,
    name: u32,
    scale: i32 = 1,
    logical: ?*zxdg.OutputV1 = null,
    logical_width: i32 = 0,
    logical_height: i32 = 0,
    mode_width: i32 = 0,
    mode_height: i32 = 0,

    /// Physical pixels per logical pixel. `wl_output.scale` is the integer
    /// ceiling, so a 1.5 output reads as 2; the mode and the logical size
    /// give the real factor. Anything outside (scale - 1, scale] (a rotated
    /// or nested output) falls back to the integer.
    fn density(self: OutputInfo) f64 {
        const whole: f64 = @floatFromInt(self.scale);
        const logical = @max(self.logical_width, self.logical_height);
        const mode = @max(self.mode_width, self.mode_height);
        if (logical <= 0 or mode <= 0) return whole;
        const real = @as(f64, @floatFromInt(mode)) / @as(f64, @floatFromInt(logical));
        return if (real > whole - 1 and real <= whole + 0.01) real else whole;
    }
};

pub const Client = struct {
    display: *wl.Display,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    output_manager: ?*zxdg.OutputManagerV1 = null,
    outputs: std.ArrayList(*OutputInfo) = .empty,
    entered_outputs: std.ArrayList(*OutputInfo) = .empty,
    scale: i32 = 1,
    density: f64 = 1,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    input_serial: u32 = 0,
    wm_base: ?*xdg.WmBase = null,
    viewporter: ?*wp.Viewporter = null,
    viewport: ?*wp.Viewport = null,
    fractional_manager: ?*wp.FractionalScaleManagerV1 = null,
    fractional: ?*wp.FractionalScaleV1 = null,
    preferred_density: ?f64 = null,
    decoration_manager: ?*zxdg.DecorationManagerV1 = null,
    surface: *wl.Surface = undefined,
    xdg_surface: *xdg.Surface = undefined,
    xdg_toplevel: *xdg.Toplevel = undefined,
    decoration: ?*zxdg.ToplevelDecorationV1 = null,
    decoration_mode: DecorationMode = .unknown,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    cursor_shape: ClientCursor = .{},
    cursor_surface: *wl.Surface = undefined,
    cursor_theme: ?*wl.CursorTheme = null,
    cursor_serial: u32 = 0,
    cursor_name: [*:0]const u8 = "",
    inside: bool = false,
    configured: bool = false,
    running: bool = true,
    outstanding: usize = 0,
    buffers: [2]?*Buffer = @splat(null),
    applied_scale: i32 = 0,
    xkb_context: ?*c.xkb_context = null,
    xkb_state: ?*c.xkb_state = null,
    key_repeat: key_repeat.KeyRepeat = .{},
    compose: @import("ui").compose.Compose = .{},
    /// LC_CTYPE of the session; picks the Compose table (´+c is ç in pt_BR).
    locale: []const u8 = "",
    app: app_mod.App,
    close_button: ui.layout.Widget = .{ .kind = .{ .button = .{ .variant = .chrome, .icon = .close, .label = "" } } },
    chrome_input: ui.input.Dispatcher = .{},

    fn arrangeClose(self: *Client) void {
        self.close_button.kind.button.label = @import("i18n").tr("Close");
        self.close_button.kind.button.owner = self;
        self.close_button.kind.button.on_click = closeClicked;
        const height: f32 = @floatFromInt(self.titlebarHeight());
        ui.arrange.arrange(&self.close_button, @as(f32, @floatFromInt(self.app.w)) - height, 0, height, height);
    }

    fn closeClicked(owner: ?*anyopaque, _: usize) void {
        const self: *Client = @ptrCast(@alignCast(owner.?));
        self.app.requestClose();
    }

    pub fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Client) void {
        switch (event) {
            .global => |g| {
                const iface = std.mem.span(g.interface);
                self.cursor_shape.bind(registry, g.name, iface, g.version);
                if (std.mem.eql(u8, iface, "wl_compositor")) {
                    self.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 5)) catch null;
                } else if (std.mem.eql(u8, iface, "wl_shm")) {
                    self.shm = registry.bind(g.name, wl.Shm, 1) catch null;
                } else if (std.mem.eql(u8, iface, "wl_output")) {
                    if (registry.bind(g.name, wl.Output, @min(g.version, 4)) catch null) |proxy| {
                        const info = a.create(OutputInfo) catch {
                            proxy.destroy();
                            return;
                        };
                        info.* = .{ .client = self, .proxy = proxy, .name = g.name };
                        self.outputs.append(a, info) catch {
                            proxy.destroy();
                            a.destroy(info);
                            return;
                        };
                        proxy.setListener(*OutputInfo, outputEvent, info);
                    }
                } else if (std.mem.eql(u8, iface, "zxdg_output_manager_v1")) {
                    self.output_manager = registry.bind(g.name, zxdg.OutputManagerV1, @min(g.version, 3)) catch null;
                } else if (std.mem.eql(u8, iface, "wl_seat") and self.seat == null) {
                    self.seat = registry.bind(g.name, wl.Seat, @min(g.version, 7)) catch null;
                    if (self.seat) |seat| seat.setListener(*Client, seatEvent, self);
                } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
                    self.viewporter = registry.bind(g.name, wp.Viewporter, 1) catch null;
                } else if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1")) {
                    self.fractional_manager = registry.bind(g.name, wp.FractionalScaleManagerV1, 1) catch null;
                } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
                    self.wm_base = registry.bind(g.name, xdg.WmBase, @min(g.version, 6)) catch null;
                    if (self.wm_base) |wm| wm.setListener(*Client, wmBaseEvent, self);
                } else if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
                    self.decoration_manager = registry.bind(g.name, zxdg.DecorationManagerV1, 1) catch null;
                }
            },
            .global_remove => |ev| {
                for (self.outputs.items, 0..) |info, i| {
                    if (info.name == ev.name) {
                        _ = self.outputs.swapRemove(i);
                        self.removeEnteredOutput(info);
                        if (info.logical) |logical| logical.destroy();
                        info.proxy.destroy();
                        a.destroy(info);
                        self.recomputeScale();
                        break;
                    }
                }
            },
        }
    }

    fn close(self: *Client) void {
        self.app.requestClose();
        self.running = false;
    }

    fn fractionalEvent(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, self: *Client) void {
        if (event == .preferred_scale and event.preferred_scale.scale > 0) {
            self.preferred_density = std.math.clamp(@as(f64, @floatFromInt(event.preferred_scale.scale)) / 120, 0.5, 4);
            self.recomputeScale();
        }
    }

    fn wmBaseEvent(_: *xdg.WmBase, event: xdg.WmBase.Event, self: *Client) void {
        switch (event) {
            .ping => |ev| {
                if (self.wm_base) |wm| wm.pong(ev.serial);
            },
        }
    }

    fn logicalOutputEvent(_: *zxdg.OutputV1, event: zxdg.OutputV1.Event, info: *OutputInfo) void {
        if (event == .logical_size) {
            info.logical_width = event.logical_size.width;
            info.logical_height = event.logical_size.height;
            info.client.recomputeScale();
        }
    }

    fn outputEvent(_: *wl.Output, event: wl.Output.Event, info: *OutputInfo) void {
        switch (event) {
            .scale => |ev| {
                info.scale = std.math.clamp(ev.factor, 1, 4);
                info.client.recomputeScale();
            },
            .mode => |ev| if (ev.flags.current) {
                info.mode_width = ev.width;
                info.mode_height = ev.height;
                info.client.recomputeScale();
            },
            else => {},
        }
    }

    // The window may span multiple outputs at different scales; use the
    // largest scale among outputs the surface currently overlaps, per the
    // usual Wayland client convention. Falls back to 1 before the first
    // wl_surface.enter is received.
    fn recomputeScale(self: *Client) void {
        var new_scale: i32 = 1;
        var new_density: f64 = 1;
        for (self.entered_outputs.items) |info| {
            new_scale = @max(new_scale, info.scale);
            new_density = @max(new_density, info.density());
        }
        if (self.viewport != null) new_density = self.preferred_density orelse new_density;
        if (new_scale != self.scale or new_density != self.density) {
            self.scale = new_scale;
            self.density = new_density;
            self.app.scale = new_scale;
            self.app.density = new_density;
            self.app.dirty = true;
        }
    }

    fn removeEnteredOutput(self: *Client, info: *OutputInfo) void {
        for (self.entered_outputs.items, 0..) |o, i| {
            if (o == info) {
                _ = self.entered_outputs.swapRemove(i);
                return;
            }
        }
    }

    fn surfaceEvent(_: *wl.Surface, event: wl.Surface.Event, self: *Client) void {
        switch (event) {
            .enter => |ev| {
                if (ev.output) |out| {
                    for (self.outputs.items) |info| {
                        if (info.proxy == out) {
                            self.entered_outputs.append(a, info) catch {};
                            self.recomputeScale();
                            break;
                        }
                    }
                }
                self.app.dirty = true;
            },
            .leave => |ev| {
                if (ev.output) |out| {
                    for (self.outputs.items) |info| {
                        if (info.proxy == out) {
                            self.removeEnteredOutput(info);
                            self.recomputeScale();
                            break;
                        }
                    }
                }
            },
        }
    }

    fn seatEvent(seat: *wl.Seat, event: wl.Seat.Event, self: *Client) void {
        switch (event) {
            .capabilities => |ev| {
                if (ev.capabilities.pointer and self.pointer == null) {
                    self.pointer = seat.getPointer() catch null;
                    if (self.pointer) |p| p.setListener(*Client, pointerEvent, self);
                }
                if (!ev.capabilities.pointer) {
                    self.cursor_shape.clearPointer();
                    if (self.pointer) |p| p.release();
                    self.pointer = null;
                    self.app.cancelDrag();
                }
                if (ev.capabilities.keyboard and self.keyboard == null) {
                    self.keyboard = seat.getKeyboard() catch null;
                    if (self.keyboard) |k| k.setListener(*Client, keyboardEvent, self);
                }
                if (!ev.capabilities.keyboard) {
                    if (self.keyboard) |k| k.release();
                    self.keyboard = null;
                }
            },
            else => {},
        }
    }

    fn xdgSurfaceEvent(xdg_surf: *xdg.Surface, event: xdg.Surface.Event, self: *Client) void {
        switch (event) {
            .configure => |ev| {
                xdg_surf.ackConfigure(ev.serial);
                self.configured = true;
                self.app.dirty = true;
            },
        }
    }

    // Whether this window must draw its own titlebar: either the compositor
    // never advertised zxdg_decoration_manager_v1 (no configure event will
    // ever arrive, so self-decorate unconditionally), or it did negotiate a
    // mode and that mode isn't server_side. Per the xdg-decoration spec, a
    // mode that hasn't been negotiated yet is assumed to be client_side.
    fn wantsCsd(self: *const Client) bool {
        return self.decoration_mode != .server_side;
    }

    fn titlebarHeight(self: *const Client) i32 {
        return if (self.wantsCsd()) CSD_TITLEBAR_H else 0;
    }

    fn decorationEvent(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, self: *Client) void {
        switch (event) {
            .configure => |ev| {
                self.decoration_mode = switch (ev.mode) {
                    .server_side => .server_side,
                    .client_side => .client_side,
                    else => .client_side,
                };
                self.app.dirty = true;
            },
        }
    }

    fn xdgToplevelEvent(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Client) void {
        switch (event) {
            .configure => |ev| {
                const tbh = self.titlebarHeight();
                if (ev.width > 0 and ev.height > 0) {
                    self.app.resize(ev.width, @max(1, ev.height - tbh));
                } else if (!self.configured) {
                    var width: i32 = 960;
                    var height: i32 = 640;
                    if (self.outputs.items.len > 0) {
                        const output = self.outputs.items[0];
                        if (output.logical_width > 0) width = std.math.clamp(output.logical_width - 160, 640, 1080);
                        if (output.logical_height > 0) height = std.math.clamp(output.logical_height - 200, 480, 640);
                    }
                    self.app.resize(width, height);
                }
                var suspended = false;
                for (ev.states.slice(u32)) |state| if (state == @intFromEnum(xdg.Toplevel.State.suspended)) {
                    suspended = true;
                };
                self.app.setSuspended(suspended);
                self.xdg_toplevel.setMinSize(640, 480 + tbh);
                self.app.dirty = true;
            },
            .close => {
                self.app.requestClose();
            },
            .configure_bounds, .wm_capabilities => {},
        }
    }

    fn pointerEvent(_: *wl.Pointer, event: wl.Pointer.Event, self: *Client) void {
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

    fn edgeAt(x: f64, y: f64, w: f64, h: f64) ?xdg.Toplevel.ResizeEdge {
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

    fn cursorNameForEdge(edge: xdg.Toplevel.ResizeEdge) [*:0]const u8 {
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
    fn updateCursor(self: *Client) void {
        if (self.wantsCsd()) {
            const tbh: f64 = @floatFromInt(self.titlebarHeight());
            if (edgeAt(self.pointer_x, self.pointer_y, @floatFromInt(self.app.w), @as(f64, @floatFromInt(self.app.h)) + tbh)) |edge| {
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
    fn handlePointerMotion(self: *Client, x: f64, y: f64) void {
        self.pointer_x = x;
        self.pointer_y = y;
        const tbh: f64 = @floatFromInt(self.titlebarHeight());
        if (tbh > 0) {
            self.arrangeClose();
            self.chrome_input.pointerMotion(&self.close_button, @floatCast(x), @floatCast(y));
        }
        self.app.handleMotion(x, y - tbh);
        self.updateCursor();
        if (tbh > 0 and y < tbh) self.app.dirty = true;
    }

    fn handlePointerButton(self: *Client, button: u32, pressed: bool) void {
        if (button == 0x110 and !pressed and self.chrome_input.pressed != null) {
            self.chrome_input.pointerButtonUp(&self.close_button, @floatCast(self.pointer_x), @floatCast(self.pointer_y));
            self.app.dirty = true;
            return;
        }
        if (button == 0x110 and pressed and self.wantsCsd()) {
            const tbh_f: f64 = @floatFromInt(self.titlebarHeight());
            const w_f: f64 = @floatFromInt(self.app.w);
            const h_f: f64 = @as(f64, @floatFromInt(self.app.h)) + tbh_f;
            if (edgeAt(self.pointer_x, self.pointer_y, w_f, h_f)) |edge| {
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

    fn handleTitlebarClick(self: *Client) void {
        self.arrangeClose();
        self.chrome_input.pointerButtonDown(&self.close_button, @floatCast(self.pointer_x), @floatCast(self.pointer_y));
        if (self.chrome_input.pressed != null) return;
        if (self.seat) |seat| self.xdg_toplevel.move(seat, self.input_serial);
    }

    /// One press of evdev `key` through the current XKB state.
    fn deliverKey(self: *Client, key: u32) void {
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

    fn appRepeats(self: *Client, key: u32) bool {
        if (self.compose.consumed) return false;
        const state = self.xkb_state orelse return false;
        var buf: [64]u8 = undefined;
        const n = c.xkb_state_key_get_utf8(state, key + 8, &buf, buf.len);
        return self.app.keyRepeats(c.xkb_state_key_get_one_sym(state, key + 8), buf[0..@intCast(std.math.clamp(n, 0, 63))]);
    }

    /// A due repeat of the held key, if the app still takes it where its
    /// focus is now (a repeat may have opened a dialog or left a field).
    fn repeatDue(self: *Client) void {
        const key = self.key_repeat.due(key_repeat.nowMs()) orelse return;
        if (!self.appRepeats(key)) return self.key_repeat.stop();
        self.deliverKey(key);
    }

    fn keyboardEvent(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Client) void {
        switch (event) {
            .enter => {
                self.app.focused = true;
                self.app.dirty = true;
            },
            .leave => {
                self.app.focused = false;
                self.key_repeat.stop();
                self.compose.reset();
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

    fn setCursor(self: *Client, name: [*:0]const u8) void {
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

    fn acquireBuffer(self: *Client, w: i32, h: i32) !?*Buffer {
        for (self.buffers) |slot| if (slot) |buffer| {
            if (!buffer.busy and buffer.w == w and buffer.h == h) return buffer;
        };
        for (&self.buffers) |*slot| {
            if (slot.*) |buffer| {
                if (buffer.busy) continue;
                buffer.destroy();
                slot.* = null;
            }
            slot.* = try Buffer.create(self, w, h);
            return slot.*;
        }
        return null;
    }
    fn render(self: *Client) !void {
        self.updateCursor();
        if (!self.configured or !self.app.dirty or self.app.suspended or self.outstanding >= 2) return;

        const tbh = self.titlebarHeight();
        const w = self.app.w;
        const h = self.app.h + tbh;
        const raster_scale: f64 = if (self.viewport != null) self.density else @floatFromInt(self.scale);
        const bw: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * raster_scale));
        const bh: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(h)) * raster_scale));
        const buffer = (try self.acquireBuffer(bw, bh)) orelse return;

        const cr = c.cairo_create(buffer.image) orelse return error.CairoFailed;
        defer c.cairo_destroy(cr);

        c.cairo_scale(cr, @as(f64, @floatFromInt(bw)) / @as(f64, @floatFromInt(w)), @as(f64, @floatFromInt(bh)) / @as(f64, @floatFromInt(h)));

        if (tbh > 0) self.renderTitlebar(cr, w, tbh);

        c.cairo_save(cr);
        c.cairo_translate(cr, 0, @floatFromInt(tbh));
        self.app.render(cr);
        c.cairo_restore(cr);

        c.cairo_surface_flush(buffer.image);

        const buffer_scale: i32 = if (self.viewport != null) 1 else self.scale;
        if (self.applied_scale != buffer_scale) {
            self.surface.setBufferScale(buffer_scale);
            self.applied_scale = buffer_scale;
        }
        if (self.viewport) |viewport| viewport.setDestination(w, h);
        self.xdg_surface.setWindowGeometry(0, 0, w, h);
        buffer.busy = true;
        self.outstanding += 1;
        self.surface.attach(buffer.wl_buffer, 0, 0);
        self.surface.damage(0, 0, w, h);
        self.surface.commit();
        self.app.dirty = false;
    }

    fn renderTitlebar(self: *Client, cr: *c.cairo_t, w: i32, h: i32) void {
        shell_ui.setSource(cr, ui_theme.global.window_bg);
        c.cairo_rectangle(cr, 0, 0, @floatFromInt(w), @floatFromInt(h));
        c.cairo_fill(cr);
        shell_ui.setSource(cr, ui_theme.global.window_fg);
        shell_ui.drawText(cr, @import("i18n").tr("System Monitor"), 16, @as(f64, @floatFromInt(h)) / 2 + shell_ui.statusSize() / 3, shell_ui.statusSize(), true);
        self.arrangeClose();
        if (shell_ui.Layer.begin(cr, .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) })) |value| {
            var layer = value;
            ui.paint.paint(&self.close_button, &layer.renderer);
            layer.finish();
        }
    }
    fn deinit(self: *Client) void {
        for (self.outputs.items) |info| {
            if (info.logical) |logical| logical.destroy();
            info.proxy.destroy();
            a.destroy(info);
        }
        self.outputs.deinit(a);
        self.entered_outputs.deinit(a);
        if (self.xkb_state) |state| c.xkb_state_unref(state);
        if (self.xkb_context) |context| c.xkb_context_unref(context);
        if (self.pointer) |pointer| pointer.release();
        if (self.keyboard) |keyboard| keyboard.release();
        if (self.seat) |seat| seat.release();
        if (self.output_manager) |manager| manager.destroy();
        if (self.fractional_manager) |manager| manager.destroy();
        if (self.viewporter) |manager| manager.destroy();
        if (self.decoration_manager) |manager| manager.destroy();
        if (self.wm_base) |wm| wm.destroy();
        if (self.shm) |shm| shm.destroy();
        if (self.compositor) |compositor| compositor.destroy();
        self.cursor_shape.deinit();
    }
};

const Buffer = struct {
    client: *Client,
    wl_buffer: *wl.Buffer,
    image: *c.cairo_surface_t,
    memory: *anyopaque,
    len: usize,
    w: i32,
    h: i32,
    busy: bool = false,

    fn create(client: *Client, w: i32, h: i32) !*Buffer {
        if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return error.InvalidSize;
        const len: usize = @intCast(w * h * 4);
        const fd = c.memfd_create("rediwm-monitor", c.MFD_CLOEXEC);
        if (fd < 0) return error.ShmFailed;
        defer _ = c.close(fd);

        if (c.ftruncate(fd, @intCast(len)) != 0) return error.ShmFailed;
        const memory = c.mmap(null, len, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (memory == c.MAP_FAILED) return error.ShmFailed;
        errdefer _ = c.munmap(memory, len);

        const pool = try client.shm.?.createPool(fd, @intCast(len));
        defer pool.destroy();

        const buffer = try pool.createBuffer(0, w, h, w * 4, .argb8888);
        errdefer buffer.destroy();

        const image = c.cairo_image_surface_create_for_data(
            @ptrCast(memory),
            c.CAIRO_FORMAT_ARGB32,
            w,
            h,
            w * 4,
        ) orelse return error.CairoFailed;
        errdefer c.cairo_surface_destroy(image);
        if (c.cairo_surface_status(image) != c.CAIRO_STATUS_SUCCESS) return error.CairoFailed;

        const self = try a.create(Buffer);
        self.* = .{
            .client = client,
            .wl_buffer = buffer,
            .image = image,
            .memory = memory.?,
            .len = len,
            .w = w,
            .h = h,
        };
        buffer.setListener(*Buffer, released, self);
        return self;
    }

    fn released(_: *wl.Buffer, _: wl.Buffer.Event, self: *Buffer) void {
        self.busy = false;
        self.client.outstanding -= 1;
    }
    fn destroy(self: *Buffer) void {
        self.wl_buffer.destroy();
        c.cairo_surface_destroy(self.image);
        _ = c.munmap(self.memory, self.len);
        a.destroy(self);
    }
};

pub fn run(init: std.process.Init) !void {
    platform.process.ignoreBrokenPipes();
    defer @import("../files/settings.zig").deinitTheme();
    var watch = try @import("settings_watch.zig").Watch.init(init.io, init.minimal.environ);
    defer watch.deinit();
    defer @import("ui").compose.flushTable();
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    var self = Client{ .display = display, .app = try app_mod.App.init(init.io), .locale = @import("ui").compose.localeFromEnviron(init.minimal.environ) };
    defer self.deinit();
    defer self.compose.deinit();
    defer self.app.deinit();
    defer for (self.buffers) |slot| {
        if (slot) |buffer| buffer.destroy();
    };

    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(*Client, Client.registryEvent, &self);

    if (display.roundtrip() != .SUCCESS) return error.DisplayFailed;
    if (self.compositor == null or self.shm == null or self.wm_base == null) {
        return error.MissingWaylandGlobals;
    }

    if (self.output_manager) |manager| {
        for (self.outputs.items) |info| {
            info.logical = try manager.getXdgOutput(info.proxy);
            info.logical.?.setListener(*OutputInfo, Client.logicalOutputEvent, info);
        }
        if (display.roundtrip() != .SUCCESS) return error.DisplayFailed;
    }

    self.surface = try self.compositor.?.createSurface();
    defer self.surface.destroy();
    self.surface.setListener(*Client, Client.surfaceEvent, &self);

    self.cursor_surface = try self.compositor.?.createSurface();
    defer self.cursor_surface.destroy();
    defer self.cursor_shape.deinit();
    if (self.cursor_shape.manager == null) self.cursor_theme = ClientCursor.loadFallback(self.shm.?);
    defer if (self.cursor_theme) |theme_ptr| theme_ptr.destroy();

    if (self.viewporter) |manager| self.viewport = try manager.getViewport(self.surface);
    defer if (self.viewport) |viewport| viewport.destroy();
    if (self.fractional_manager) |manager| {
        self.fractional = try manager.getFractionalScale(self.surface);
        self.fractional.?.setListener(*Client, Client.fractionalEvent, &self);
    }
    defer if (self.fractional) |fractional| fractional.destroy();

    self.xdg_surface = try self.wm_base.?.getXdgSurface(self.surface);
    defer self.xdg_surface.destroy();
    self.xdg_surface.setListener(*Client, Client.xdgSurfaceEvent, &self);

    self.xdg_toplevel = try self.xdg_surface.getToplevel();
    defer self.xdg_toplevel.destroy();
    self.xdg_toplevel.setListener(*Client, Client.xdgToplevelEvent, &self);

    self.xdg_toplevel.setAppId("rediwm-monitor");
    self.xdg_toplevel.setTitle(self.app.getTitle());
    // Real min size is set from xdgToplevelEvent once the decoration mode
    // (and thus titlebar height) is known; this is just a safe pre-configure
    // default sized for the worst case (self-decorated).
    self.xdg_toplevel.setMinSize(640, 480 + CSD_TITLEBAR_H);

    // Prefer server-side decorations; the compositor may still tell us via
    // decorationEvent to self-decorate (e.g. it has no SSD implementation),
    // and if zxdg_decoration_manager_v1 isn't advertised at all we already
    // default to self-decorating (see wantsCsd).
    if (self.decoration_manager) |mgr| {
        self.decoration = mgr.getToplevelDecoration(self.xdg_toplevel) catch null;
        if (self.decoration) |dec| {
            dec.setListener(*Client, Client.decorationEvent, &self);
            dec.setMode(.server_side);
        }
    }
    defer if (self.decoration) |dec| dec.destroy();

    // Initial commit to start xdg configuration sequence
    self.surface.commit();

    self.app.start();
    while (self.running) {
        if (watch.poll()) self.app.dirty = true;
        self.app.sync();
        self.app.stepAnimations(key_repeat.nowMs());
        if (self.app.closed) self.close();
        if (!self.running) break;

        try self.render();

        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        }
        if (!self.running or self.app.closed) {
            display.cancelRead();
            self.close();
            break;
        }

        if (self.configured and self.app.dirty and !self.app.suspended and self.outstanding < 2) {
            display.cancelRead();
            continue;
        }
        const flushed = display.flush();
        if (flushed != .SUCCESS and flushed != .AGAIN) {
            display.cancelRead();
            return error.DisplayFailed;
        }

        var fds = [_]c.struct_pollfd{
            .{ .fd = display.getFd(), .events = @intCast(c.POLLIN | @as(c_int, if (flushed == .AGAIN) c.POLLOUT else 0)), .revents = 0 },
            .{ .fd = self.app.worker.notify_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = watch.fd(), .events = c.POLLIN, .revents = 0 },
        };
        const now = key_repeat.nowMs();
        var timeout: c_int = if (self.key_repeat.timeoutMs(now)) |wait| @intCast(@min(wait, 60_000)) else -1;
        if (self.app.animationTimeout(now)) |wait| timeout = if (timeout < 0) @intCast(wait) else @min(timeout, @as(c_int, @intCast(wait)));
        if (self.app.suspended) {
            self.key_repeat.stop();
            timeout = -1;
        }
        const result = c.poll(&fds, fds.len, timeout);
        if (result > 0 and (fds[0].revents & c.POLLIN != 0)) {
            if (display.readEvents() != .SUCCESS) return error.DisplayFailed;
        } else {
            display.cancelRead();
        }
        if ((fds[0].revents & (c.POLLERR | c.POLLHUP)) != 0) return error.DisplayFailed;
        if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        self.repeatDue();
    }
}
