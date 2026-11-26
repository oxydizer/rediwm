//! One xdg-toplevel window for an app drawn with Cairo and the shared `ui`
//! widgets: registry, fractional scale, server- or client-side decorations
//! (a titlebar with a close button and resize edges when the compositor does
//! not decorate), cursor shapes, keyboard with compose and key repeat, theme
//! reloads, and a released-buffer render loop that sleeps while idle.
//!
//! `run(App, &app, init, options)` drives an `App` the caller owns. The App
//! keeps its state in these fields, which the host reads and writes:
//!   w, h: i32 (content size, below the titlebar), scale: i32, density: f64,
//!   dirty, closed, suspended, focused, ctrl, shift, alt: bool
//! and provides:
//!   getTitle(*App) [*:0]const u8, requestClose(*App), setSuspended(*App, bool),
//!   cancelDrag(*App), resize(*App, i32, i32), handleMotion(*App, f64, f64),
//!   handleButton(*App, u32, bool), handleKey(*App, u32 keysym, []const u8 text),
//!   keyRepeats(*App, u32, []const u8) bool, cursorName(*App) [*:0]const u8,
//!   render(*App, *cairo_t)
//! Optional: handleAxis(*App, dx: f64, dy: f64) for wheel and touchpad scrolling
//! (surface units, positive dy is down).
//! Set `dirty` to get a frame; set `closed` to quit.
const std = @import("std");
const platform = @import("platform");
const ui = @import("ui");
const ClientCursor = ui.client_cursor;
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const wp = @import("wayland").client.wp;
const zxdg = @import("wayland").client.zxdg;
const c = @import("c_gfx");
const key_repeat = ui.key_repeat;
const shell_ui = ui.cairo;
const ui_theme = ui.theme;
const Outputs = @import("window_outputs.zig").Outputs;
const Pool = @import("window_buffer.zig").Pool;
const a = std.heap.c_allocator;

// A window with no server-side decorations must draw its own titlebar so it
// stays usable (movable, closable) on compositors that don't implement
// zxdg-decoration, e.g. GNOME/Mutter.
const CSD_TITLEBAR_H: i32 = 32;
const RESIZE_MARGIN: f64 = 6;

const DecorationMode = enum { unknown, client_side, server_side };

pub const Options = struct {
    /// xdg app id; also names the desktop entry the shell matches.
    app_id: [:0]const u8,
    /// First size when the compositor leaves it to us, shrunk to fit the output.
    default_width: i32 = 640,
    default_height: i32 = 480,
    min_width: i32 = 280,
    min_height: i32 = 200,
};

pub fn run(comptime App: type, app: *App, init: std.process.Init, options: Options) !void {
    return Host(App).run(app, init, options);
}

pub fn Host(comptime App: type) type {
    return struct {
        const Client = @This();

        display: *wl.Display,
        options: Options,
        compositor: ?*wl.Compositor = null,
        shm: ?*wl.Shm = null,
        outputs: Outputs = .{},
        scale: i32 = 1,
        density: f64 = 1,
        seat: ?*wl.Seat = null,
        pointer: ?*wl.Pointer = null,
        keyboard: ?*wl.Keyboard = null,
        input_serial: u32 = 0,
        wm_base: ?*xdg.WmBase = null,
        activation: ?*xdg.ActivationV1 = null,
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
        buffers: Pool = .{},
        applied_scale: i32 = 0,
        xkb_context: ?*c.xkb_context = null,
        xkb_state: ?*c.xkb_state = null,
        key_repeat: key_repeat.KeyRepeat = .{},
        compose: ui.compose.Compose = .{},
        /// LC_CTYPE of the session; picks the Compose table (´+c is ç in pt_BR).
        locale: []const u8 = "",
        app: *App,
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

        fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Client) void {
            switch (event) {
                .global => |g| {
                    const iface = std.mem.span(g.interface);
                    self.cursor_shape.bind(registry, g.name, iface, g.version);
                    if (std.mem.eql(u8, iface, "wl_compositor")) {
                        self.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 5)) catch null;
                    } else if (std.mem.eql(u8, iface, "wl_shm")) {
                        self.shm = registry.bind(g.name, wl.Shm, 1) catch null;
                    } else if (std.mem.eql(u8, iface, "wl_output")) {
                        self.outputs.add(registry, g.name, g.version);
                    } else if (std.mem.eql(u8, iface, "zxdg_output_manager_v1")) {
                        self.outputs.setManager(registry, g.name, g.version);
                    } else if (std.mem.eql(u8, iface, "wl_seat") and self.seat == null) {
                        self.seat = registry.bind(g.name, wl.Seat, @min(g.version, 7)) catch null;
                        if (self.seat) |seat| seat.setListener(*Client, seatEvent, self);
                    } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
                        self.viewporter = registry.bind(g.name, wp.Viewporter, 1) catch null;
                    } else if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1")) {
                        self.fractional_manager = registry.bind(g.name, wp.FractionalScaleManagerV1, 1) catch null;
                    } else if (std.mem.eql(u8, iface, "xdg_activation_v1")) {
                        self.activation = registry.bind(g.name, xdg.ActivationV1, 1) catch null;
                    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
                        self.wm_base = registry.bind(g.name, xdg.WmBase, @min(g.version, 6)) catch null;
                        if (self.wm_base) |wm| wm.setListener(*Client, wmBaseEvent, self);
                    } else if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
                        self.decoration_manager = registry.bind(g.name, zxdg.DecorationManagerV1, 1) catch null;
                    }
                },
                .global_remove => |ev| self.outputs.remove(ev.name),
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

        fn outputsChanged(owner: *anyopaque) void {
            const self: *Client = @ptrCast(@alignCast(owner));
            self.recomputeScale();
        }

        // The window may span outputs at different scales; draw at the
        // largest, or at the fractional-scale preference when a viewport
        // can present it.
        fn recomputeScale(self: *Client) void {
            const now = self.outputs.current();
            const new_scale = now.scale;
            var new_density = now.density;
            if (self.viewport != null) new_density = self.preferred_density orelse new_density;
            if (new_scale != self.scale or new_density != self.density) {
                self.scale = new_scale;
                self.density = new_density;
                self.app.scale = new_scale;
                self.app.density = new_density;
                self.app.dirty = true;
            }
        }

        fn surfaceEvent(_: *wl.Surface, event: wl.Surface.Event, self: *Client) void {
            switch (event) {
                .enter => |ev| {
                    if (ev.output) |out| self.outputs.enter(out);
                    self.app.dirty = true;
                },
                .leave => |ev| if (ev.output) |out| self.outputs.leave(out),
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
                    const o = self.options;
                    if (ev.width > 0 and ev.height > 0) {
                        self.app.resize(ev.width, @max(1, ev.height - tbh));
                    } else if (!self.configured) {
                        var width: i32 = o.default_width;
                        var height: i32 = o.default_height;
                        const output = self.outputs.firstLogicalSize();
                        if (output.w > 0) width = std.math.clamp(output.w - 160, o.min_width, @max(o.min_width, o.default_width));
                        if (output.h > 0) height = std.math.clamp(output.h - 200, o.min_height, @max(o.min_height, o.default_height));
                        self.app.resize(width, height);
                    }
                    var suspended = false;
                    for (ev.states.slice(u32)) |state| if (state == @backingInt(xdg.Toplevel.State.suspended)) {
                        suspended = true;
                    };
                    self.app.setSuspended(suspended);
                    self.xdg_toplevel.setMinSize(o.min_width, o.min_height + tbh);
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
                .axis => |ev| if (@hasDecl(App, "handleAxis")) {
                    const value = ev.value.toDouble();
                    if (ev.axis == .vertical_scroll) self.app.handleAxis(0, value) else self.app.handleAxis(value, 0);
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
        // its content-area layout stays oblivious to decorations.
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

        fn wantsFrame(self: *const Client) bool {
            return self.configured and self.app.dirty and !self.app.suspended and self.buffers.outstanding < 2;
        }

        fn render(self: *Client) !void {
            self.updateCursor();
            if (!self.wantsFrame()) return;

            const tbh = self.titlebarHeight();
            const w = self.app.w;
            const h = self.app.h + tbh;
            const raster_scale: f64 = if (self.viewport != null) self.density else @floatFromInt(self.scale);
            const bw: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * raster_scale));
            const bh: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(h)) * raster_scale));
            const buffer = (try self.buffers.acquire(bw, bh)) orelse return;

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
            self.buffers.submit(buffer);
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
            shell_ui.drawText(cr, std.mem.span(self.app.getTitle()), 16, @as(f64, @floatFromInt(h)) / 2 + shell_ui.statusSize() / 3, shell_ui.statusSize(), true);
            self.arrangeClose();
            if (shell_ui.Layer.begin(cr, .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) })) |value| {
                var layer = value;
                ui.paint.paint(&self.close_button, &layer.renderer);
                layer.finish();
            }
        }

        fn deinit(self: *Client) void {
            self.outputs.deinit();
            if (self.xkb_state) |state| c.xkb_state_unref(state);
            if (self.xkb_context) |context| c.xkb_context_unref(context);
            if (self.pointer) |pointer| pointer.release();
            if (self.keyboard) |keyboard| keyboard.release();
            if (self.seat) |seat| seat.release();
            if (self.fractional_manager) |manager| manager.destroy();
            if (self.viewporter) |manager| manager.destroy();
            if (self.decoration_manager) |manager| manager.destroy();
            if (self.wm_base) |wm| wm.destroy();
            if (self.activation) |activation| activation.destroy();
            if (self.shm) |shm| shm.destroy();
            if (self.compositor) |compositor| compositor.destroy();
            self.cursor_shape.deinit();
        }

        pub fn run(app: *App, init: std.process.Init, options: Options) !void {
            platform.process.ignoreBrokenPipes();
            defer @import("settings.zig").deinitTheme();
            var watch = try @import("settings_watch.zig").Watch.init(init.io, init.minimal.environ);
            defer watch.deinit();
            defer ui.compose.flushTable();
            const display = try wl.Display.connect(null);
            defer display.disconnect();
            var self = Client{ .display = display, .options = options, .app = app, .locale = ui.compose.localeFromEnviron(init.minimal.environ) };
            self.outputs.owner = &self;
            self.outputs.on_change = outputsChanged;
            self.buffers.name = options.app_id;
            defer self.deinit();
            defer self.compose.deinit();
            defer self.buffers.deinit();

            const registry = try display.getRegistry();
            defer registry.destroy();
            registry.setListener(*Client, registryEvent, &self);

            if (display.roundtrip() != .SUCCESS) return error.DisplayFailed;
            if (self.compositor == null or self.shm == null or self.wm_base == null) {
                return error.MissingWaylandGlobals;
            }
            self.buffers.shm = self.shm.?;
            // Logical output sizes, for the first window size.
            if (self.outputs.manager != null and display.roundtrip() != .SUCCESS) return error.DisplayFailed;

            self.surface = try self.compositor.?.createSurface();
            defer self.surface.destroy();
            self.surface.setListener(*Client, surfaceEvent, &self);

            self.cursor_surface = try self.compositor.?.createSurface();
            defer self.cursor_surface.destroy();
            if (self.cursor_shape.manager == null) self.cursor_theme = ClientCursor.loadFallback(self.shm.?);
            defer if (self.cursor_theme) |theme_ptr| theme_ptr.destroy();

            if (self.viewporter) |manager| self.viewport = try manager.getViewport(self.surface);
            defer if (self.viewport) |viewport| viewport.destroy();
            if (self.fractional_manager) |manager| {
                self.fractional = try manager.getFractionalScale(self.surface);
                self.fractional.?.setListener(*Client, fractionalEvent, &self);
            }
            defer if (self.fractional) |fractional| fractional.destroy();

            self.xdg_surface = try self.wm_base.?.getXdgSurface(self.surface);
            defer self.xdg_surface.destroy();
            self.xdg_surface.setListener(*Client, xdgSurfaceEvent, &self);

            self.xdg_toplevel = try self.xdg_surface.getToplevel();
            defer self.xdg_toplevel.destroy();
            self.xdg_toplevel.setListener(*Client, xdgToplevelEvent, &self);

            self.xdg_toplevel.setAppId(options.app_id);
            self.xdg_toplevel.setTitle(self.app.getTitle());
            // Real min size is set from xdgToplevelEvent once the decoration mode
            // (and thus titlebar height) is known; this is just a safe pre-configure
            // default sized for the worst case (self-decorated).
            self.xdg_toplevel.setMinSize(options.min_width, options.min_height + CSD_TITLEBAR_H);

            // Prefer server-side decorations; the compositor may still tell us via
            // decorationEvent to self-decorate (e.g. it has no SSD implementation),
            // and if zxdg_decoration_manager_v1 isn't advertised at all we already
            // default to self-decorating (see wantsCsd).
            if (self.decoration_manager) |mgr| {
                self.decoration = mgr.getToplevelDecoration(self.xdg_toplevel) catch null;
                if (self.decoration) |dec| {
                    dec.setListener(*Client, decorationEvent, &self);
                    dec.setMode(.server_side);
                }
            }
            defer if (self.decoration) |dec| dec.destroy();

            // Initial commit to start xdg configuration sequence
            self.surface.commit();
            if (self.activation) |activation| {
                if (init.minimal.environ.getPosix("XDG_ACTIVATION_TOKEN")) |token| {
                    const terminated = try a.dupeSentinel(u8, token, 0);
                    defer a.free(terminated);
                    activation.activate(terminated, self.surface);
                }
            }

            while (self.running) {
                if (watch.poll()) self.app.dirty = true;
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

                if (self.wantsFrame()) {
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
                    .{ .fd = watch.fd(), .events = c.POLLIN, .revents = 0 },
                };
                const now = key_repeat.nowMs();
                var timeout: c_int = if (self.key_repeat.timeoutMs(now)) |wait| @intCast(@min(wait, 60_000)) else -1;
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
    };
}
