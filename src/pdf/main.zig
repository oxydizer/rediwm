//! Wayland client lifecycle, buffer presentation, decoration negotiation and input loop for rediwm-pdf.
const std = @import("std");
const ClientCursor = @import("ui").client_cursor;
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const c = @import("c.zig");
const app_mod = @import("app.zig");
const key_repeat = @import("ui").key_repeat;
const ui_theme = @import("ui").theme;
const shell_ui = @import("ui").cairo;
const shell_text = @import("ui").text;

const a = std.heap.c_allocator;

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
};

pub const Client = struct {
    display: *wl.Display,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    output_manager: ?*zxdg.OutputManagerV1 = null,
    outputs: std.ArrayList(*OutputInfo) = .empty,
    entered_outputs: std.ArrayList(*OutputInfo) = .empty,
    scale: i32 = 1,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    input_serial: u32 = 0,
    wm_base: ?*xdg.WmBase = null,
    activation: ?*xdg.ActivationV1 = null,
    decoration_manager: ?*zxdg.DecorationManagerV1 = null,
    data_manager: ?*wl.DataDeviceManager = null,
    data_device: ?*wl.DataDevice = null,
    clipboard_source: ?*ClipboardSource = null,
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
    xkb_context: ?*c.api.xkb_context = null,
    xkb_state: ?*c.api.xkb_state = null,
    key_repeat: key_repeat.KeyRepeat = .{},
    app: app_mod.App,

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
                } else if (std.mem.eql(u8, iface, "xdg_activation_v1")) {
                    self.activation = registry.bind(g.name, xdg.ActivationV1, 1) catch null;
                } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
                    self.wm_base = registry.bind(g.name, xdg.WmBase, @min(g.version, 2)) catch null;
                    if (self.wm_base) |wm| wm.setListener(*Client, wmBaseEvent, self);
                } else if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
                    self.decoration_manager = registry.bind(g.name, zxdg.DecorationManagerV1, 1) catch null;
                } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
                    self.data_manager = registry.bind(g.name, wl.DataDeviceManager, @min(g.version, 3)) catch null;
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

    fn outputEvent(proxy: *wl.Output, event: wl.Output.Event, info: *OutputInfo) void {
        switch (event) {
            .scale => |ev| {
                info.scale = ev.factor;
                info.client.recomputeScale();
            },
            else => {},
        }
        _ = proxy;
    }

    fn logicalOutputEvent(_: *zxdg.OutputV1, event: zxdg.OutputV1.Event, info: *OutputInfo) void {
        switch (event) {
            .logical_size => |ev| {
                info.logical_width = ev.width;
                info.logical_height = ev.height;
            },
            else => {},
        }
    }

    fn surfaceEvent(_: *wl.Surface, event: wl.Surface.Event, self: *Client) void {
        switch (event) {
            .enter => |ev| {
                for (self.outputs.items) |info| {
                    if (info.proxy == ev.output) {
                        self.entered_outputs.append(a, info) catch return;
                        self.recomputeScale();
                        break;
                    }
                }
            },
            .leave => |ev| {
                for (self.entered_outputs.items, 0..) |info, i| {
                    if (info.proxy == ev.output) {
                        _ = self.entered_outputs.swapRemove(i);
                        self.recomputeScale();
                        break;
                    }
                }
            },
        }
    }

    fn removeEnteredOutput(self: *Client, info: *OutputInfo) void {
        for (self.entered_outputs.items, 0..) |entered, i| {
            if (entered == info) {
                _ = self.entered_outputs.swapRemove(i);
                break;
            }
        }
    }

    fn recomputeScale(self: *Client) void {
        var max_scale: i32 = 1;
        for (self.entered_outputs.items) |info| {
            if (info.scale > max_scale) max_scale = info.scale;
        }
        if (self.scale != max_scale) {
            self.scale = max_scale;
            self.app.scale = max_scale;
            self.app.dirty = true;
        }
    }

    fn wmBaseEvent(wm: *xdg.WmBase, event: xdg.WmBase.Event, _: *Client) void {
        switch (event) {
            .ping => |ev| wm.pong(ev.serial),
        }
    }

    fn seatEvent(_: *wl.Seat, event: wl.Seat.Event, self: *Client) void {
        switch (event) {
            .capabilities => |ev| {
                if (ev.capabilities.pointer and self.pointer == null) {
                    self.pointer = self.seat.?.getPointer() catch null;
                    if (self.pointer) |p| p.setListener(*Client, pointerEvent, self);
                }
                if (!ev.capabilities.pointer) {
                    if (self.pointer) |p| p.release();
                    self.pointer = null;
                }
                if (ev.capabilities.keyboard and self.keyboard == null) {
                    self.keyboard = self.seat.?.getKeyboard() catch null;
                    if (self.keyboard) |k| k.setListener(*Client, keyboardEvent, self);
                }
                if (!ev.capabilities.keyboard) {
                    if (self.keyboard) |k| k.release();
                    self.keyboard = null;
                }
                if (self.data_manager) |mgr| {
                    if (self.data_device == null) {
                        self.data_device = mgr.getDataDevice(self.seat.?) catch null;
                        if (self.data_device) |device| device.setListener(*Client, dataDeviceEvent, self);
                    }
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
                    var width: i32 = 1000;
                    var height: i32 = 700;
                    if (self.outputs.items.len > 0) {
                        const output = self.outputs.items[0];
                        if (output.logical_width > 0) width = std.math.clamp(output.logical_width - 160, 480, 1200);
                        if (output.logical_height > 0) height = std.math.clamp(output.logical_height - 180, 360, 800);
                    }
                    self.app.resize(width, height);
                }
                self.xdg_toplevel.setMinSize(480, 320 + tbh);
                self.app.dirty = true;
            },
            .close => {
                self.app.requestClose();
            },
        }
    }

    fn pointerEvent(_: *wl.Pointer, event: wl.Pointer.Event, self: *Client) void {
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
                    if (self.app.shift) {
                        self.app.handleHorizontalScroll(ev.value.toDouble());
                    } else {
                        self.app.handleScroll(ev.value.toDouble());
                    }
                } else if (ev.axis == .horizontal_scroll) {
                    self.app.handleHorizontalScroll(ev.value.toDouble());
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

    fn updateCursor(self: *Client) void {
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

    fn handlePointerMotion(self: *Client, x: f64, y: f64) void {
        self.pointer_x = x;
        self.pointer_y = y;
        const tbh: f64 = @floatFromInt(self.titlebarHeight());
        self.app.handleMotion(x, y - tbh);
        self.updateCursor();
        if (tbh > 0 and y < tbh) self.app.dirty = true;
    }

    fn handlePointerButton(self: *Client, button: u32, pressed: bool) void {
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

    fn handleTitlebarClick(self: *Client, w_f: f64, tbh_f: f64) void {
        const close_w: f64 = @min(tbh_f, 32.0);
        if (self.pointer_x >= w_f - close_w) {
            self.app.requestClose();
            return;
        }
        if (self.seat) |seat| self.xdg_toplevel.move(seat, self.input_serial);
    }

    fn deliverKey(self: *Client, key: u32) void {
        const state = self.xkb_state orelse return;
        const sym = c.api.xkb_state_key_get_one_sym(state, key + 8);
        var buf: [64]u8 = undefined;
        const n = c.api.xkb_state_key_get_utf8(state, key + 8, &buf, buf.len);
        self.app.handleKey(sym, buf[0..@intCast(std.math.clamp(n, 0, 63))]);
    }

    fn appRepeats(self: *Client, key: u32) bool {
        const state = self.xkb_state orelse return false;
        var buf: [64]u8 = undefined;
        const n = c.api.xkb_state_key_get_utf8(state, key + 8, &buf, buf.len);
        return self.app.keyRepeats(c.api.xkb_state_key_get_one_sym(state, key + 8), buf[0..@intCast(std.math.clamp(n, 0, 63))]);
    }

    fn repeatDue(self: *Client) void {
        const key = self.key_repeat.due(key_repeat.nowMs()) orelse return;
        if (!self.appRepeats(key)) return self.key_repeat.stop();
        self.deliverKey(key);
    }

    fn keyboardEvent(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Client) void {
        switch (event) {
            .leave => {
                self.key_repeat.stop();
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
        if (!self.configured or !self.app.dirty or self.outstanding >= 2) return;

        const tbh = self.titlebarHeight();
        const w = self.app.w;
        const h = self.app.h + tbh;
        const buffer = (try self.acquireBuffer(w * self.scale, h * self.scale)) orelse return;

        const cr = c.api.cairo_create(buffer.image) orelse return error.CairoFailed;
        defer c.api.cairo_destroy(cr);

        c.api.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));

        if (tbh > 0) self.renderTitlebar(cr, w, tbh);

        c.api.cairo_save(cr);
        c.api.cairo_translate(cr, 0, @floatFromInt(tbh));
        self.app.render(cr);
        c.api.cairo_restore(cr);

        c.api.cairo_surface_flush(buffer.image);

        if (self.applied_scale != self.scale) {
            self.surface.setBufferScale(self.scale);
            self.applied_scale = self.scale;
        }
        self.xdg_surface.setWindowGeometry(0, 0, w, h);
        buffer.busy = true;
        self.outstanding += 1;
        self.surface.attach(buffer.wl_buffer, 0, 0);
        self.surface.damage(0, 0, w, h);
        self.surface.commit();
        self.app.dirty = false;
    }

    fn renderTitlebar(self: *Client, cr: *c.api.cairo_t, w: i32, h: i32) void {
        const w_f: f64 = @floatFromInt(w);
        const h_f: f64 = @floatFromInt(h);

        shell_ui.setSource(cr, ui_theme.global.window_bg);
        c.api.cairo_rectangle(cr, 0, 0, w_f, h_f);
        c.api.cairo_fill(cr);

        shell_ui.setSource(cr, ui_theme.global.app_divider);
        c.api.cairo_set_line_width(cr, 1.0);
        c.api.cairo_move_to(cr, 0, h_f - 0.5);
        c.api.cairo_line_to(cr, w_f, h_f - 0.5);
        c.api.cairo_stroke(cr);

        const title = std.mem.span(self.app.getTitle());
        shell_ui.setSource(cr, ui_theme.global.window_fg);
        const tw = shell_ui.measureText(cr, title, 12, true);
        c.api.cairo_save(cr);
        c.api.cairo_rectangle(cr, 36, 0, @max(0, w_f - 72), h_f);
        c.api.cairo_clip(cr);
        shell_ui.drawText(cr, title, @max(36.0, (w_f - tw) / 2.0), h_f / 2.0 + 4, 12, true);
        c.api.cairo_restore(cr);

        const close_w: f64 = @min(h_f, 32.0);
        const hovered = self.inside and self.pointer_y < h_f and self.pointer_x >= w_f - close_w;
        if (hovered) {
            shell_ui.setSource(cr, ui_theme.global.window_close_hover);
            c.api.cairo_rectangle(cr, w_f - close_w, 0, close_w, h_f);
            c.api.cairo_fill(cr);
            c.api.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
        } else {
            shell_ui.setSource(cr, ui_theme.global.window_dim);
        }
        const cx = w_f - close_w / 2.0;
        const cy = h_f / 2.0;
        c.api.cairo_set_line_width(cr, 1.5);
        c.api.cairo_move_to(cr, cx - 5, cy - 5);
        c.api.cairo_line_to(cr, cx + 5, cy + 5);
        c.api.cairo_move_to(cr, cx + 5, cy - 5);
        c.api.cairo_line_to(cr, cx - 5, cy + 5);
        c.api.cairo_stroke(cr);
    }

    fn publishClipboard(self: *Client) void {
        const mgr = self.data_manager orelse return;
        const dev = self.data_device orelse return;
        const text = self.app.clipboard_text orelse return;

        const source = mgr.createDataSource() catch return;
        errdefer source.destroy();

        const clip = a.create(ClipboardSource) catch return;
        clip.* = .{
            .client = self,
            .proxy = source,
            .text = a.dupeZ(u8, text) catch return,
        };
        source.setListener(*ClipboardSource, ClipboardSource.event, clip);
        source.offer("text/plain;charset=utf-8");
        source.offer("text/plain");

        dev.setSelection(source, self.input_serial);
        if (self.clipboard_source) |cs| cs.destroy();
        self.clipboard_source = clip;
        self.app.clipboard_request = false;
    }
};

const ClipboardSource = struct {
    client: *Client,
    proxy: *wl.DataSource,
    text: [:0]const u8,

    fn destroy(self: *ClipboardSource) void {
        self.proxy.destroy();
        a.free(self.text);
        a.destroy(self);
    }

    fn event(proxy: *wl.DataSource, ev: wl.DataSource.Event, self: *ClipboardSource) void {
        switch (ev) {
            .send => |s| {
                defer _ = c.api.close(s.fd);
                _ = c.api.write(s.fd, self.text.ptr, self.text.len);
            },
            .cancelled => {
                if (self.client.clipboard_source == self) {
                    self.client.clipboard_source = null;
                }
                self.destroy();
            },
            else => {},
        }
        _ = proxy;
    }
};

fn dataDeviceEvent(_: *wl.DataDevice, _: wl.DataDevice.Event, _: *Client) void {}

const Buffer = struct {
    client: *Client,
    wl_buffer: *wl.Buffer,
    image: *c.api.cairo_surface_t,
    memory: *anyopaque,
    len: usize,
    w: i32,
    h: i32,
    busy: bool = false,

    fn create(client: *Client, w: i32, h: i32) !*Buffer {
        if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return error.InvalidSize;
        const len: usize = @intCast(w * h * 4);
        const fd = c.api.memfd_create("rediwm-pdf", c.api.MFD_CLOEXEC);
        if (fd < 0) return error.ShmFailed;
        defer _ = c.api.close(fd);

        if (c.api.ftruncate(fd, @intCast(len)) != 0) return error.ShmFailed;
        const memory = c.api.mmap(null, len, c.api.PROT_READ | c.api.PROT_WRITE, c.api.MAP_SHARED, fd, 0);
        if (memory == c.api.MAP_FAILED) return error.ShmFailed;
        errdefer _ = c.api.munmap(memory, len);

        const pool = try client.shm.?.createPool(fd, @intCast(len));
        defer pool.destroy();

        const buffer = try pool.createBuffer(0, w, h, w * 4, .argb8888);
        errdefer buffer.destroy();

        const image = c.api.cairo_image_surface_create_for_data(
            @ptrCast(memory),
            c.api.CAIRO_FORMAT_ARGB32,
            w,
            h,
            w * 4,
        ) orelse return error.CairoFailed;
        errdefer c.api.cairo_surface_destroy(image);
        if (c.api.cairo_surface_status(image) != c.api.CAIRO_STATUS_SUCCESS) return error.CairoFailed;

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
        c.api.cairo_surface_destroy(self.image);
        _ = c.api.munmap(self.memory, self.len);
        a.destroy(self);
    }
};

pub fn run(init: std.process.Init.Minimal) !void {
    _ = c.api.signal(c.api.SIGPIPE, c.api.SIG_IGN);
    const args = init.args.vector;

    if (args.len >= 2 and (std.mem.eql(u8, std.mem.span(args[1]), "--help") or std.mem.eql(u8, std.mem.span(args[1]), "-h"))) {
        std.debug.print(
            \\Usage: rediwm-pdf [--] FILE
            \\
            \\A sandboxed Wayland PDF viewer; one document per process.
            \\Open another document from Files to start a new viewer.
            \\
            \\Controls:
            \\  Wheel/Arrows: Scroll document
            \\  Ctrl+Wheel / +/-: Zoom in/out
            \\  0 / 9: Fit width / Fit page
            \\  R: Rotate 90° clockwise
            \\  Ctrl+L: Jump to page
            \\  PageUp / PageDown / Space: Move viewport
            \\  Home / End: First / Last page
            \\  Ctrl+W / Esc: Close window / dialog
            \\
        , .{});
        return;
    }

    if (args.len >= 2 and std.mem.eql(u8, std.mem.span(args[1]), "--version")) {
        std.debug.print("rediwm-pdf 0.1.0\n", .{});
        return;
    }

    var i: usize = 1;
    if (args.len >= 2 and std.mem.eql(u8, std.mem.span(args[1]), "--")) i = 2;
    if (args.len != i + 1) {
        std.log.err("usage: rediwm-pdf [--] FILE; open another PDF from Files", .{});
        return error.ExpectedDocument;
    }
    const raw = std.mem.span(args[i]);
    const initial_path = try a.dupeZ(u8, raw);
    defer a.free(initial_path);
    const document_fd = c.rediwm_pdf_open_document(initial_path.ptr);
    if (document_fd < 0) return error.CannotOpenRegularFile;
    defer _ = c.api.close(document_fd);
    const force_csd = init.environ.getPosix("REDIWM_PDF_FORCE_CSD") != null;
    // Read before the sandbox closes the filesystem.
    @import("../files/settings.zig").loadTheme(a, std.Io.Threaded.global_single_threaded.io(), init.environ);
    defer @import("../files/settings.zig").deinitTheme();
    // Open the selected faces now: user-installed fonts can live outside
    // the system font directories the sandbox permits.
    for ([_]shell_text.Font{ .manrope, .manrope_bold }) |font| {
        shell_text.warmGlyphs(font, shell_ui.textSize(), 1, "") catch {};
    }

    const display = try @import("connection.zig").connect();
    defer display.disconnect();
    if (c.rediwm_pdf_sandbox_enter(document_fd, display.getFd()) != 0) {
        std.log.err("required PDF sandbox could not be installed; refusing to parse the document", .{});
        return error.SandboxUnavailable;
    }

    var self = Client{
        .display = display,
        .app = try app_mod.App.init(initial_path, document_fd),
    };
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

    self.xdg_surface = try self.wm_base.?.getXdgSurface(self.surface);
    defer self.xdg_surface.destroy();
    self.xdg_surface.setListener(*Client, Client.xdgSurfaceEvent, &self);

    self.xdg_toplevel = try self.xdg_surface.getToplevel();
    defer self.xdg_toplevel.destroy();
    self.xdg_toplevel.setListener(*Client, Client.xdgToplevelEvent, &self);

    self.xdg_toplevel.setAppId("rediwm-pdf");
    self.xdg_toplevel.setTitle(self.app.getTitle());
    self.xdg_toplevel.setMinSize(480, 320 + CSD_TITLEBAR_H);

    if (self.decoration_manager) |mgr| {
        if (!force_csd) {
            self.decoration = mgr.getToplevelDecoration(self.xdg_toplevel) catch null;
            if (self.decoration) |dec| {
                dec.setListener(*Client, Client.decorationEvent, &self);
                dec.setMode(.server_side);
            }
        }
    }
    defer if (self.decoration) |dec| dec.destroy();

    self.surface.commit();

    while (self.running) {
        self.app.sync();
        if (self.app.clipboard_request) {
            self.publishClipboard();
        }
        if (self.app.closed) {
            self.running = false;
            break;
        }

        if (self.app.title_changed) {
            self.xdg_toplevel.setTitle(self.app.getTitle());
            self.app.title_changed = false;
        }

        self.app.stepBar(key_repeat.nowMs());
        try self.render();

        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        }
        if (!self.running) {
            display.cancelRead();
            break;
        }

        const flushed = display.flush();
        if (flushed != .SUCCESS and flushed != .AGAIN) {
            display.cancelRead();
            return error.DisplayFailed;
        }

        var fds = [_]c.api.struct_pollfd{
            .{ .fd = display.getFd(), .events = @intCast(c.api.POLLIN | @as(c_int, if (flushed == .AGAIN) c.api.POLLOUT else 0)), .revents = 0 },
            .{ .fd = self.app.worker.fds[0], .events = c.api.POLLIN, .revents = 0 },
        };
        const now = key_repeat.nowMs();
        var timeout: c_int = if (self.key_repeat.timeoutMs(now)) |wait| @intCast(@min(wait, 60_000)) else -1;
        if (self.app.barTimeout(now)) |wait| timeout = if (timeout < 0) @intCast(wait) else @min(timeout, @as(c_int, @intCast(wait)));
        const result = c.api.poll(&fds, fds.len, timeout);
        if (result > 0 and (fds[0].revents & c.api.POLLIN != 0)) {
            if (display.readEvents() != .SUCCESS) return error.DisplayFailed;
        } else {
            display.cancelRead();
        }
        if ((fds[0].revents & (c.api.POLLERR | c.api.POLLHUP)) != 0) return error.DisplayFailed;
        if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        self.repeatDue();
    }

    if (self.clipboard_source) |cs| cs.destroy();
    if (self.data_device) |dd| dd.release();

    for (self.outputs.items) |info| {
        if (info.logical) |logical| logical.destroy();
        info.proxy.destroy();
        a.destroy(info);
    }
    self.outputs.deinit(a);
    self.entered_outputs.deinit(a);
    if (self.xkb_state) |state| c.api.xkb_state_unref(state);
    if (self.xkb_context) |context| c.api.xkb_context_unref(context);
}
