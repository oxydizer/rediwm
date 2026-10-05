//! Wayland GUI for `rediwm-share-picker --xdpw-dmenu`. Labels stay opaque;
//! the selected stdin line is returned unchanged. Layout constants are part
//! of the test contract in tests/screencast.py.
const std = @import("std");
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const c = @import("c.zig").api;
const sources = @import("sources.zig");
const shell_ui = @import("ui").cairo;
const ui_button = @import("ui").widgets.button;
const ui_theme = @import("ui").theme;

const a = std.heap.c_allocator;

pub const window_w: i32 = 420;
pub const window_h: i32 = 320;
pub const header_h: i32 = 64;
pub const row_h: i32 = 44;
pub const pad: i32 = 16;

const CSD_TITLEBAR_H: i32 = 32;

const OutputInfo = struct {
    client: *Client,
    proxy: *wl.Output,
    name: u32,
    scale: i32 = 1,
};

const Client = struct {
    display: *wl.Display,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    outputs: std.ArrayList(*OutputInfo) = .empty,
    entered_outputs: std.ArrayList(*OutputInfo) = .empty,
    scale: i32 = 1,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    wm_base: ?*xdg.WmBase = null,
    decoration_manager: ?*zxdg.DecorationManagerV1 = null,
    surface: *wl.Surface = undefined,
    xdg_surface: *xdg.Surface = undefined,
    xdg_toplevel: *xdg.Toplevel = undefined,
    decoration: ?*zxdg.ToplevelDecorationV1 = null,
    decoration_mode: enum { unknown, client_side, server_side } = .unknown,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    inside: bool = false,
    configured: bool = false,
    running: bool = true,
    outstanding: usize = 0,
    xkb_context: ?*c.xkb_context = null,
    xkb_state: ?*c.xkb_state = null,
    labels: []const []const u8,
    hover: ?usize = null,
    selected: usize = 0,
    w: i32 = window_w,
    h: i32 = window_h,
    dirty: bool = true,
    decision: sources.Decision = .cancel,

    fn wantsCsd(self: *const Client) bool {
        return self.decoration_mode != .server_side;
    }

    fn titlebarHeight(self: *const Client) i32 {
        return if (self.wantsCsd()) CSD_TITLEBAR_H else 0;
    }

    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Client) void {
        switch (event) {
            .global => |g| {
                const iface = std.mem.span(g.interface);
                if (std.mem.eql(u8, iface, "wl_compositor")) {
                    self.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 4)) catch null;
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
                } else if (std.mem.eql(u8, iface, "wl_seat") and self.seat == null) {
                    self.seat = registry.bind(g.name, wl.Seat, @min(g.version, 7)) catch null;
                    if (self.seat) |seat| seat.setListener(*Client, seatEvent, self);
                } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
                    self.wm_base = registry.bind(g.name, xdg.WmBase, @min(g.version, 2)) catch null;
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
                        info.proxy.destroy();
                        a.destroy(info);
                        self.recomputeScale();
                        break;
                    }
                }
            },
        }
    }

    fn wmBaseEvent(_: *xdg.WmBase, event: xdg.WmBase.Event, self: *Client) void {
        switch (event) {
            .ping => |ev| if (self.wm_base) |wm| wm.pong(ev.serial),
        }
    }

    fn outputEvent(_: *wl.Output, event: wl.Output.Event, info: *OutputInfo) void {
        if (event == .scale) {
            info.scale = std.math.clamp(event.scale.factor, 1, 4);
            info.client.recomputeScale();
        }
    }

    fn recomputeScale(self: *Client) void {
        var new_scale: i32 = 1;
        for (self.entered_outputs.items) |info| new_scale = @max(new_scale, info.scale);
        if (new_scale != self.scale) {
            self.scale = new_scale;
            self.dirty = true;
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
                self.dirty = true;
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
                    if (self.pointer) |p| p.release();
                    self.pointer = null;
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
                self.dirty = true;
            },
        }
    }

    fn decorationEvent(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, self: *Client) void {
        switch (event) {
            .configure => |ev| {
                self.decoration_mode = switch (ev.mode) {
                    .server_side => .server_side,
                    .client_side => .client_side,
                    else => .client_side,
                };
                self.dirty = true;
            },
        }
    }

    fn xdgToplevelEvent(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Client) void {
        switch (event) {
            .configure => |ev| {
                const tbh = self.titlebarHeight();
                if (ev.width > 0 and ev.height > 0) {
                    self.w = ev.width;
                    self.h = @max(header_h + row_h, ev.height - tbh);
                }
                self.xdg_toplevel.setMinSize(320, 200 + tbh);
                self.dirty = true;
            },
            .close => {
                self.decision = .cancel;
                self.running = false;
            },
        }
    }

    fn pointerEvent(_: *wl.Pointer, event: wl.Pointer.Event, self: *Client) void {
        switch (event) {
            .enter => |ev| {
                self.inside = true;
                self.handleMotion(ev.surface_x.toDouble(), ev.surface_y.toDouble());
            },
            .leave => {
                self.inside = false;
                self.hover = null;
                self.dirty = true;
            },
            .motion => |ev| self.handleMotion(ev.surface_x.toDouble(), ev.surface_y.toDouble()),
            .button => |ev| {
                if (ev.state == .pressed and ev.button == 0x110) self.handleClick();
            },
            else => {},
        }
    }

    fn handleMotion(self: *Client, x: f64, y: f64) void {
        self.pointer_x = x;
        self.pointer_y = y;
        const content_y = y - @as(f64, @floatFromInt(self.titlebarHeight()));
        const row = rowAt(content_y);
        const next: ?usize = if (row) |r| (if (r < self.labels.len) r else null) else null;
        if (next != self.hover) {
            self.hover = next;
            if (next) |r| self.selected = r;
            self.dirty = true;
        }
    }

    fn handleClick(self: *Client) void {
        const content_y = self.pointer_y - @as(f64, @floatFromInt(self.titlebarHeight()));
        if (self.titlebarHeight() > 0 and self.pointer_y < @as(f64, @floatFromInt(self.titlebarHeight()))) {
            const close_w: f64 = @min(@as(f64, @floatFromInt(self.titlebarHeight())), 32);
            if (self.pointer_x >= @as(f64, @floatFromInt(self.w)) - close_w) {
                self.decision = .cancel;
                self.running = false;
            }
            return;
        }
        if (rowAt(content_y)) |row| {
            if (row < self.labels.len) {
                self.decision = .{ .select = self.labels[row] };
                self.running = false;
            }
        }
    }

    fn rowAt(content_y: f64) ?usize {
        if (content_y < @as(f64, @floatFromInt(header_h))) return null;
        const rel = content_y - @as(f64, @floatFromInt(header_h));
        if (rel < 0) return null;
        return @intFromFloat(@divTrunc(rel, @as(f64, @floatFromInt(row_h))));
    }

    fn keyboardEvent(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Client) void {
        switch (event) {
            .keymap => |ev| {
                defer _ = c.close(ev.fd);
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
            .key => |ev| {
                if (ev.state != .pressed) return;
                const state = self.xkb_state orelse return;
                const sym = c.xkb_state_key_get_one_sym(state, ev.key + 8);
                if (sym == c.XKB_KEY_Escape) {
                    self.decision = .cancel;
                    self.running = false;
                } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
                    if (self.labels.len > 0 and self.selected < self.labels.len) {
                        self.decision = .{ .select = self.labels[self.selected] };
                        self.running = false;
                    }
                } else if (sym == c.XKB_KEY_Up) {
                    if (self.labels.len > 0) {
                        self.selected = if (self.selected == 0) self.labels.len - 1 else self.selected - 1;
                        self.dirty = true;
                    }
                } else if (sym == c.XKB_KEY_Down) {
                    if (self.labels.len > 0) {
                        self.selected = (self.selected + 1) % self.labels.len;
                        self.dirty = true;
                    }
                }
            },
            else => {},
        }
    }

    fn render(self: *Client) !void {
        if (!self.configured or !self.dirty or self.outstanding >= 2) return;
        const tbh = self.titlebarHeight();
        const w = self.w;
        const h = self.h + tbh;
        const buffer = try Buffer.create(self, w * self.scale, h * self.scale);
        const cr = c.cairo_create(buffer.image) orelse return error.CairoFailed;
        defer c.cairo_destroy(cr);
        c.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));

        if (tbh > 0) self.renderTitlebar(cr, w, tbh);

        c.cairo_save(cr);
        c.cairo_translate(cr, 0, @floatFromInt(tbh));
        self.renderContent(cr);
        c.cairo_restore(cr);
        c.cairo_surface_flush(buffer.image);

        self.surface.setBufferScale(self.scale);
        self.xdg_surface.setWindowGeometry(0, 0, w, h);
        self.surface.attach(buffer.wl_buffer, 0, 0);
        self.surface.damage(0, 0, w, h);
        self.surface.commit();
        self.dirty = false;
    }

    fn renderTitlebar(self: *Client, cr: *c.cairo_t, w: i32, h: i32) void {
        const t = ui_theme.shellPalette();
        const w_f: f64 = @floatFromInt(w);
        const h_f: f64 = @floatFromInt(h);
        setSource(cr, t.window_bg);
        c.cairo_rectangle(cr, 0, 0, w_f, h_f);
        c.cairo_fill(cr);
        setSource(cr, t.fg);
        drawText(cr, "Share screen", 16, h_f / 2.0 + 4, 13, true);
        const close_w: f64 = @min(h_f, 32);
        const hovered = self.inside and self.pointer_y < h_f and self.pointer_x >= w_f - close_w;
        var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(w_f - close_w), .y = 0, .w = @floatCast(close_w), .h = @floatCast(h_f) }) orelse return;
        ui_button.paint(&layer.renderer, layer.local(), .{ .variant = .chrome, .icon = .close, .label = "Close" }, .{ .pointer = if (hovered) .hover else .idle });
        layer.finish();
    }

    fn renderContent(self: *Client, cr: *c.cairo_t) void {
        const t = ui_theme.shellPalette();
        const w_f: f64 = @floatFromInt(self.w);
        const h_f: f64 = @floatFromInt(self.h);
        setSource(cr, t.window_bg);
        c.cairo_rectangle(cr, 0, 0, w_f, h_f);
        c.cairo_fill(cr);

        setSource(cr, t.fg);
        drawText(cr, "Share screen", pad, 28, 16, true);
        setSource(cr, t.dim);
        drawText(cr, "Choose a source. Escape cancels.", pad, 48, 12, false);

        if (self.labels.len == 0) {
            setSource(cr, t.dim);
            drawText(cr, "No sources available.", pad, header_h + 24, 13, false);
            return;
        }

        for (self.labels, 0..) |label, i| {
            const y: f64 = @floatFromInt(header_h + @as(i32, @intCast(i)) * row_h);
            if (self.hover == i or self.selected == i) {
                // The shared selected-item tint (a toggled-on button's).
                setSource(cr, .{ t.accent[0], t.accent[1], t.accent[2], t.accent[3] * 0.22 });
                roundedRect(cr, pad - 4, y + 4, w_f - @as(f64, @floatFromInt(pad * 2)) + 8, @as(f64, @floatFromInt(row_h)) - 8, t.radius);
                c.cairo_fill(cr);
            }
            setSource(cr, t.fg);
            drawText(cr, label, pad, y + 28, 13, false);
        }
    }
};

fn drawText(cr: *c.cairo_t, str: []const u8, x: f64, y: f64, size: f64, bold: bool) void {
    shell_ui.drawText(cr, str, x, y, size, bold);
}

fn setSource(cr: *c.cairo_t, color: [4]f32) void {
    c.cairo_set_source_rgba(cr, color[0], color[1], color[2], color[3]);
}

fn roundedRect(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + w - r, y + r, r, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, x + w - r, y + h - r, r, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, x + r, y + h - r, r, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, x + r, y + r, r, std.math.pi, std.math.pi * 1.5);
    c.cairo_close_path(cr);
}

const Buffer = struct {
    client: *Client,
    wl_buffer: *wl.Buffer,
    image: *c.cairo_surface_t,
    memory: *anyopaque,
    len: usize,

    fn create(client: *Client, w: i32, h: i32) !*Buffer {
        if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return error.InvalidSize;
        const len: usize = @intCast(w * h * 4);
        const fd = c.memfd_create("rediwm-share-picker", c.MFD_CLOEXEC);
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
        const image = c.cairo_image_surface_create_for_data(@ptrCast(memory), c.CAIRO_FORMAT_ARGB32, w, h, w * 4) orelse return error.CairoFailed;

        const self = try a.create(Buffer);
        self.* = .{
            .client = client,
            .wl_buffer = buffer,
            .image = image,
            .memory = memory.?,
            .len = len,
        };
        buffer.setListener(*Buffer, released, self);
        client.outstanding += 1;
        return self;
    }

    fn released(buffer: *wl.Buffer, _: wl.Buffer.Event, self: *Buffer) void {
        buffer.destroy();
        c.cairo_surface_destroy(self.image);
        _ = c.munmap(self.memory, self.len);
        self.client.outstanding -= 1;
        a.destroy(self);
    }
};

pub fn run(labels: []const []const u8) !sources.Decision {
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);
    const display = wl.Display.connect(null) catch return error.DisplayConnectFailed;
    defer display.disconnect();

    var self = Client{
        .display = display,
        .labels = labels,
    };

    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(*Client, Client.registryEvent, &self);
    if (display.roundtrip() != .SUCCESS) return error.DisplayFailed;
    if (self.compositor == null or self.shm == null or self.wm_base == null) return error.MissingWaylandGlobals;

    self.surface = try self.compositor.?.createSurface();
    defer self.surface.destroy();
    self.surface.setListener(*Client, Client.surfaceEvent, &self);

    self.xdg_surface = try self.wm_base.?.getXdgSurface(self.surface);
    defer self.xdg_surface.destroy();
    self.xdg_surface.setListener(*Client, Client.xdgSurfaceEvent, &self);

    self.xdg_toplevel = try self.xdg_surface.getToplevel();
    defer self.xdg_toplevel.destroy();
    self.xdg_toplevel.setListener(*Client, Client.xdgToplevelEvent, &self);
    self.xdg_toplevel.setAppId("rediwm-share-picker");
    self.xdg_toplevel.setTitle("Share screen");
    self.xdg_toplevel.setMinSize(320, 200 + CSD_TITLEBAR_H);

    if (self.decoration_manager) |mgr| {
        self.decoration = mgr.getToplevelDecoration(self.xdg_toplevel) catch null;
        if (self.decoration) |dec| {
            dec.setListener(*Client, Client.decorationEvent, &self);
            dec.setMode(.server_side);
        }
    }
    defer if (self.decoration) |dec| dec.destroy();

    self.surface.commit();

    while (self.running) {
        try self.render();
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        }
        const flushed = display.flush();
        if (flushed != .SUCCESS and flushed != .AGAIN) {
            display.cancelRead();
            return error.DisplayFailed;
        }
        var fd = c.struct_pollfd{
            .fd = display.getFd(),
            .events = @intCast(c.POLLIN | @as(c_int, if (flushed == .AGAIN) c.POLLOUT else 0)),
            .revents = 0,
        };
        const result = c.poll(&fd, 1, 16);
        if (result > 0 and (fd.revents & c.POLLIN != 0)) {
            if (display.readEvents() != .SUCCESS) return error.DisplayFailed;
        } else {
            display.cancelRead();
        }
        if ((fd.revents & (c.POLLERR | c.POLLHUP)) != 0) return error.DisplayFailed;
        if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
    }

    for (self.outputs.items) |info| {
        info.proxy.destroy();
        a.destroy(info);
    }
    self.outputs.deinit(a);
    self.entered_outputs.deinit(a);
    if (self.xkb_state) |state| c.xkb_state_unref(state);
    if (self.xkb_context) |context| c.xkb_context_unref(context);
    if (self.seat) |seat| seat.release();
    return self.decision;
}
