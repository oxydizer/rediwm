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
//! (surface units, positive dy is down);
//!   themeChanged(*App) after a live theme reload (a frame follows anyway);
//!   pollFds(*App, []c.struct_pollfd) usize to add up to 8 descriptors of the
//!   App's own to the loop (override the capacity with `poll_slots`),
//!   pollReady(*App, []const c.struct_pollfd) called
//!   with them (and their revents, zero on a timeout) after every poll, and
//!   timeoutMs(*App, now_ms: i64) ?i64 for the App's next deadline;
//!   pasteText(*App, []const u8) for a plain-text clipboard, with fields
//!   clipboard_revision: u64 (bump it to publish clipboardText(*App) []const u8)
//!   and paste_requested: bool (set it to get the selection in pasteText);
//!   frameDamage(*App) ui.repaint.Region, called right before each render,
//!   for partial repaints: what the App draws differently since its previous
//!   frame (content coordinates, logical pixels; focus changes included;
//!   `.whole` for everything). render then runs clipped to that plus what the
//!   recycled buffer missed, and should skip drawing outside the clip; only
//!   that much is damaged. Without it every frame is a full repaint;
//!   animating: bool, set (in render or frameDamage) while an animation needs
//!   another frame: the commit asks for a frame callback and its arrival sets
//!   `dirty`, so animations step with the display instead of a timer.
//!   titlebarTabHandler(*App) ui.client_tabs.Handler, setTitlebarTabs(*App, bool)
//!   and publishTitlebarTabs(*App, *ui.client_tabs) for a client-owned tab strip.
//! getTitle is read every loop iteration and the title resent when it changes.
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
const Clipboard = @import("window_clipboard.zig").Clipboard;
const clipboard_slots = @import("window_clipboard.zig").slots;
/// Descriptors an App may add through `pollFds`.
pub const app_poll_slots = 8;
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
        fullscreen: bool = false,
        tabs: ui.client_tabs = .{},
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
        clipboard: Clipboard = .{},
        clipboard_revision: u64 = 0,
        /// The title last sent, to resend only a changed one.
        title: ?[:0]u8 = null,
        /// What the host itself changed (configure, scale, theme, titlebar),
        /// in surface coordinates; the App reports its own (`frameDamage`).
        damage: ui.repaint.Region = .whole,
        /// The pending frame callback, while an App animation waits for the display.
        frame_callback: ?*wl.Callback = null,

        const has_clipboard = @hasDecl(App, "pasteText");
        const has_tabs = @hasDecl(App, "titlebarTabHandler");
        const poll_slots = if (@hasDecl(App, "poll_slots")) App.poll_slots else app_poll_slots;
        pub const has_damage = @hasDecl(App, "frameDamage");
        pub const has_animation = @hasField(App, "animating");

        /// A frame repainting everything.
        fn invalidate(self: *Client) void {
            self.damage = .whole;
            self.app.dirty = true;
        }

        fn invalidateTitlebar(self: *Client) void {
            self.damage.add(.{ .x = 0, .y = 0, .w = self.app.w, .h = self.titlebarHeight() });
            self.app.dirty = true;
        }

        pub fn arrangeClose(self: *Client) void {
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
                    if (has_tabs) self.tabs.bind(registry, g.name, iface, g.version);
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
                    } else if (has_clipboard and std.mem.eql(u8, iface, "wl_data_device_manager")) {
                        self.clipboard.bind(registry, g.name, g.version);
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
                self.invalidate();
            }
        }

        fn surfaceEvent(_: *wl.Surface, event: wl.Surface.Event, self: *Client) void {
            switch (event) {
                .enter => |ev| {
                    if (ev.output) |out| self.outputs.enter(out);
                    self.invalidate();
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
                    self.invalidate();
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

        pub fn titlebarHeight(self: *const Client) i32 {
            return if (self.wantsCsd()) CSD_TITLEBAR_H else 0;
        }

        fn updateTitlebarTabs(self: *Client) void {
            if (has_tabs) self.app.setTitlebarTabs(self.tabs.strip != null and !self.wantsCsd() and !self.fullscreen);
        }

        fn decorationEvent(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, self: *Client) void {
            switch (event) {
                .configure => |ev| {
                    self.decoration_mode = switch (ev.mode) {
                        .server_side => .server_side,
                        .client_side => .client_side,
                        else => .client_side,
                    };
                    self.updateTitlebarTabs();
                    self.invalidate();
                },
            }
        }

        fn xdgToplevelEvent(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Client) void {
            switch (event) {
                .configure => |ev| {
                    var suspended = false;
                    if (has_tabs) self.fullscreen = false;
                    for (ev.states.slice(u32)) |state| {
                        if (state == @backingInt(xdg.Toplevel.State.suspended)) suspended = true;
                        if (has_tabs and state == @backingInt(xdg.Toplevel.State.fullscreen)) self.fullscreen = true;
                    }
                    self.updateTitlebarTabs();
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
                    self.app.setSuspended(suspended);
                    self.xdg_toplevel.setMinSize(o.min_width, o.min_height + tbh);
                    self.invalidate();
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
        pub fn updateCursor(self: *Client) void {
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
            if (tbh > 0 and y < tbh) self.invalidateTitlebar();
        }

        fn handlePointerButton(self: *Client, button: u32, pressed: bool) void {
            if (button == 0x110 and !pressed and self.chrome_input.pressed != null) {
                self.chrome_input.pointerButtonUp(&self.close_button, @floatCast(self.pointer_x), @floatCast(self.pointer_y));
                self.invalidateTitlebar();
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

        const keyboard_group = @import("window_keyboard.zig").Keyboard(Client);
        pub const deliverKey = keyboard_group.deliverKey;
        pub const appRepeats = keyboard_group.appRepeats;
        pub const repeatDue = keyboard_group.repeatDue;
        pub const keyboardEvent = keyboard_group.keyboardEvent;

        const render_group = @import("window_render.zig").Render(Client);
        pub const requestAnimationFrame = render_group.requestAnimationFrame;
        pub const frameDone = render_group.frameDone;
        pub const wantsFrame = render_group.wantsFrame;
        pub const render = render_group.render;
        pub const renderTitlebar = render_group.renderTitlebar;

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

        /// Resends the App's title when it changed; a drawn titlebar repaints.
        fn syncTitle(self: *Client) void {
            const title = std.mem.span(self.app.getTitle());
            if (self.title) |old| if (std.mem.eql(u8, old, title)) return;
            const copy = a.dupeSentinel(u8, title, 0) catch return;
            if (self.title) |old| a.free(old);
            self.title = copy;
            self.xdg_toplevel.setTitle(copy);
            if (self.wantsCsd()) self.invalidateTitlebar();
        }

        /// Publishes a bumped clipboard revision and starts a requested paste.
        fn syncClipboard(self: *Client) void {
            if (!has_clipboard) return;
            if (self.app.clipboard_revision != self.clipboard_revision) {
                self.clipboard_revision = self.app.clipboard_revision;
                self.clipboard.publish(self.app.clipboardText(), self.input_serial) catch {};
            }
            if (self.app.paste_requested) {
                self.app.paste_requested = false;
                if (self.clipboard.paste() catch null) |own| self.app.pasteText(own);
            }
        }

        fn deinit(self: *Client) void {
            if (self.frame_callback) |callback| callback.destroy();
            if (self.title) |title| a.free(title);
            self.clipboard.deinit();
            if (has_tabs) self.tabs.deinit();
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
            if (has_tabs) self.tabs.attach(self.surface, self.app.titlebarTabHandler());

            self.xdg_toplevel.setAppId(options.app_id);
            self.syncTitle();
            if (self.seat) |seat| self.clipboard.setup(seat);
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
                if (watch.poll()) {
                    self.invalidate();
                    if (@hasDecl(App, "themeChanged")) self.app.themeChanged();
                }
                if (self.app.closed) self.close();
                if (!self.running) break;

                self.syncTitle();
                if (has_tabs) self.app.publishTitlebarTabs(&self.tabs);
                self.syncClipboard();
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

                // Display, theme watch, clipboard transfers, then the App's own.
                var fds: [2 + clipboard_slots + poll_slots]c.struct_pollfd = undefined;
                fds[0] = .{ .fd = display.getFd(), .events = @intCast(c.POLLIN | @as(c_int, if (flushed == .AGAIN) c.POLLOUT else 0)), .revents = 0 };
                fds[1] = .{ .fd = watch.fd(), .events = c.POLLIN, .revents = 0 };
                self.clipboard.pollFds(fds[2..][0..clipboard_slots]);
                const app_fds = fds[2 + clipboard_slots ..];
                const app_count: usize = if (@hasDecl(App, "pollFds")) @min(self.app.pollFds(app_fds), app_fds.len) else 0;
                for (app_fds[0..app_count]) |*fd| fd.revents = 0;
                const now = key_repeat.nowMs();
                var wait: ?i64 = if (self.app.suspended) null else self.key_repeat.timeoutMs(now);
                if (self.app.suspended) self.key_repeat.stop();
                if (self.clipboard.timeoutMs(now)) |ms| wait = if (wait) |w| @min(w, ms) else ms;
                if (@hasDecl(App, "timeoutMs")) if (self.app.timeoutMs(now)) |ms| {
                    wait = if (wait) |w| @min(w, ms) else ms;
                };
                const timeout: c_int = if (wait) |ms| @intCast(std.math.clamp(ms, 0, 60_000)) else -1;
                const result = c.poll(&fds, @intCast(2 + clipboard_slots + app_count), timeout);
                if (result > 0 and (fds[0].revents & c.POLLIN != 0)) {
                    if (display.readEvents() != .SUCCESS) return error.DisplayFailed;
                } else {
                    display.cancelRead();
                }
                if ((fds[0].revents & (c.POLLERR | c.POLLHUP)) != 0) return error.DisplayFailed;
                // A finished paste lands before input that arrived with it.
                if (self.clipboard.dispatch()) |value| {
                    var received = value;
                    defer received.deinit();
                    if (has_clipboard and !self.app.paste_requested) self.app.pasteText(received.bytes.items);
                }
                if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
                if (@hasDecl(App, "pollReady")) self.app.pollReady(app_fds[0..app_count]);
                self.repeatDue();
            }
        }
    };
}
