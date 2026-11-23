//! Globals and window events: the registry, outputs and scale, the seat, xdg surface and toplevel, and decorations.

const std = @import("std");
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const ui_theme = @import("ui").theme;
const a = std.heap.c_allocator;
const main_mod = @import("main.zig");
const Client = main_mod.Client;
const OutputInfo = main_mod.OutputInfo;
const pointerEvent = Client.pointerEvent;
const keyboardEvent = Client.keyboardEvent;

pub fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Client) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.span(g.interface);
            self.cursor_shape.bind(registry, g.name, iface, g.version);
            self.tabs.bind(registry, g.name, iface, g.version);
            if (std.mem.eql(u8, iface, "zwp_text_input_manager_v3")) self.ime.manager = registry.bind(g.name, @import("wayland").client.zwp.TextInputManagerV3, 1) catch null;
            if (std.mem.eql(u8, iface, "wl_data_device_manager")) self.clipboard.manager = registry.bind(g.name, wl.DataDeviceManager, @min(g.version, 3)) catch null;
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
            } else if (std.mem.eql(u8, iface, "xdg_activation_v1")) {
                self.activation = registry.bind(g.name, xdg.ActivationV1, 1) catch null;
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

pub fn close(self: *Client) void {
    self.running = false;
}

pub fn wmBaseEvent(_: *xdg.WmBase, event: xdg.WmBase.Event, self: *Client) void {
    switch (event) {
        .ping => |ev| {
            if (self.wm_base) |wm| wm.pong(ev.serial);
        },
    }
}

pub fn logicalOutputEvent(_: *zxdg.OutputV1, event: zxdg.OutputV1.Event, info: *OutputInfo) void {
    if (event == .logical_size) {
        info.logical_width = event.logical_size.width;
        info.logical_height = event.logical_size.height;
    }
}

pub fn outputEvent(_: *wl.Output, event: wl.Output.Event, info: *OutputInfo) void {
    if (event == .scale) {
        info.scale = std.math.clamp(event.scale.factor, 1, 4);
        info.client.recomputeScale();
    }
}

// The window may span multiple outputs at different scales; use the
// largest scale among outputs the surface currently overlaps, per the
// usual Wayland client convention. Falls back to 1 before the first
// wl_surface.enter is received.
pub fn recomputeScale(self: *Client) void {
    var new_scale: i32 = 1;
    for (self.entered_outputs.items) |info| new_scale = @max(new_scale, info.scale);
    if (new_scale != self.scale) {
        self.scale = new_scale;
        self.app.scale = new_scale;
        self.app.dirty = true;
    }
}

pub fn removeEnteredOutput(self: *Client, info: *OutputInfo) void {
    for (self.entered_outputs.items, 0..) |o, i| {
        if (o == info) {
            _ = self.entered_outputs.swapRemove(i);
            return;
        }
    }
}

pub fn surfaceEvent(_: *wl.Surface, event: wl.Surface.Event, self: *Client) void {
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

pub fn seatEvent(seat: *wl.Seat, event: wl.Seat.Event, self: *Client) void {
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

pub fn xdgSurfaceEvent(xdg_surf: *xdg.Surface, event: xdg.Surface.Event, self: *Client) void {
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
pub fn wantsCsd(self: *const Client) bool {
    return self.decoration_mode != .server_side;
}

pub fn titlebarHeight(self: *const Client) i32 {
    return if (self.wantsCsd() and !self.fullscreen) @intFromFloat(@round(ui_theme.global.chrome_height)) else 0;
}

pub fn decorationEvent(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, self: *Client) void {
    switch (event) {
        .configure => |ev| {
            self.decoration_mode = switch (ev.mode) {
                .server_side => .server_side,
                .client_side => .client_side,
                else => .client_side,
            };
            self.app.has_titlebar = self.titlebarHeight() > 0;
            self.app.dirty = true;
        },
    }
}

pub fn xdgToplevelEvent(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Client) void {
    switch (event) {
        .configure => |ev| {
            self.maximized = false;
            self.fullscreen = false;
            for (ev.states.slice(xdg.Toplevel.State)) |state| switch (state) {
                .maximized => self.maximized = true,
                .fullscreen => self.fullscreen = true,
                else => {},
            };
            const tbh = self.titlebarHeight();
            self.app.has_titlebar = tbh > 0;
            if (ev.width > 0 and ev.height > 0) {
                self.app.resize(ev.width, @max(1, ev.height - tbh));
            } else if (!self.configured) {
                var width: i32 = 900;
                var height: i32 = 500;
                if (self.outputs.items.len > 0) {
                    const output = self.outputs.items[0];
                    if (output.logical_width > 0) width = std.math.clamp(output.logical_width - 160, 520, 900);
                    if (output.logical_height > 0) height = std.math.clamp(output.logical_height - 200, 240, 640);
                }
                self.app.resize(width, height);
            }
            self.xdg_toplevel.setMinSize(520, 240 + tbh);
            self.app.dirty = true;
        },
        .close => {
            self.app.requestClose();
        },
        .configure_bounds, .wm_capabilities => {},
    }
}
