const std = @import("std");
const ClientCursor = @import("ui").client_cursor;
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const key_repeat = @import("ui").key_repeat;
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const worker_mod = @import("worker.zig");
const transfer = @import("transfer.zig");
const clipboard_mod = @import("clipboard.zig");
const theme = @import("../icon_theme.zig");
const Allocator = std.mem.Allocator;
const a = std.heap.c_allocator;

const Offer = struct {
    proxy: *wl.DataOffer,
    uri: bool = false,
    files: bool = false,
    gnome: bool = false,
    text: bool = false,
    utf8: bool = false,
    action: wl.DataDeviceManager.DndAction = .{},
};

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
};

const ClipboardSource = struct {
    client: *Client,
    proxy: *wl.DataSource,
    uris: []const u8,
    gnome: []const u8,
    text: bool = false,
};

pub const Client = struct {
    display: *wl.Display,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    outputs: std.ArrayList(*OutputInfo) = .empty,
    entered_outputs: std.ArrayList(*OutputInfo) = .empty,
    scale: i32 = 1,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    data_manager: ?*wl.DataDeviceManager = null,
    data_device: ?*wl.DataDevice = null,
    selection_offer: ?*Offer = null,
    drag_offer: ?*Offer = null,
    /// The serial of the drag's last `enter`, which `accept` must quote.
    drag_enter_serial: u32 = 0,
    /// Whether the drag over the window was last told a drop here would work.
    drag_accepting: bool = false,
    drag_moving: bool = false,
    drag_x: f64 = 0,
    drag_y: f64 = 0,
    /// A dropped offer being read, and the pin gap it was dropped on.
    drop_offer: ?*Offer = null,
    drop_receiving: ?transfer.Receive = null,
    drop_slot: ?usize = null,
    drop_move: bool = false,
    clipboard_source: ?*ClipboardSource = null,
    drag_source: ?*ClipboardSource = null,
    drag_serial: u32 = 0,
    drag_icon: ?DragIcon = null,
    axis_source: wl.Pointer.AxisSource = .wheel,
    axis_delta: f64 = 0,
    axis_notches: ?f64 = null,
    clipboard_revision: usize = 0,
    offers: std.ArrayList(*Offer) = .empty,
    input_serial: u32 = 0,
    wm_base: ?*xdg.WmBase = null,
    activation: ?*xdg.ActivationV1 = null,
    preview_token: [4096:0]u8 = @splat(0),
    preview_token_len: usize = 0,
    editor_token_pending: bool = false,
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
    /// An acked configure is applied only by a commit; the compositor holds
    /// further interactive-resize configures until then, even when the new
    /// frame is pixel-identical (e.g. the size-unchanged "resizing" configure).
    ack_uncommitted: bool = false,
    running: bool = true,
    outstanding: usize = 0,
    buffers: std.ArrayList(*Buffer) = .empty,
    retained: std.ArrayList(u8) = .empty,
    retained_w: i32 = 0,
    applied_scale: i32 = 0,
    receiving: ?transfer.Receive = null,
    sends: std.ArrayList(transfer.Send) = .empty,
    xkb_context: ?*c.xkb_context = null,
    xkb_state: ?*c.xkb_state = null,
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
                } else if (std.mem.eql(u8, iface, "wl_seat") and self.seat == null) {
                    self.seat = registry.bind(g.name, wl.Seat, @min(g.version, 8)) catch null;
                    if (self.seat) |seat| seat.setListener(*Client, seatEvent, self);
                } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
                    self.data_manager = registry.bind(g.name, wl.DataDeviceManager, @min(g.version, 3)) catch null;
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
                        info.proxy.destroy();
                        a.destroy(info);
                        self.recomputeScale();
                        break;
                    }
                }
            },
        }
    }

    /// Worker results, the preview helper, clipboard pipes and input all wake
    /// the poll, including file-operation state changes. Only animation and
    /// known deadlines need a timeout; an idle window sleeps.
    fn pollTimeout(self: *Client) c_int {
        if (self.app.wheel_glide.active() or self.app.selectionNeedsScroll() or self.app.hover_active or self.app.layout_active or self.app.scroll_appearance.active or self.app.sidebar_scroll_appearance.active) return 16;
        if (self.app.hasRunningFolderSize()) return 33;
        var deadline: ?i64 = null;
        if (self.app.status_notice != null) deadline = self.app.status_notice_until;
        if (self.app.scanNoticeDeadline()) |at| deadline = earlier(deadline, at);
        if (self.app.scroll_appearance.deadline) |at| deadline = earlier(deadline, at);
        if (self.app.sidebar_scroll_appearance.deadline) |at| deadline = earlier(deadline, at);
        // Transfers expire once strictly past their timeout.
        if (self.receiving) |receive| deadline = earlier(deadline, receive.started + transfer.timeout_ms + 1);
        if (self.drop_receiving) |receive| deadline = earlier(deadline, receive.started + transfer.timeout_ms + 1);
        for (self.sends.items) |send| deadline = earlier(deadline, send.started + transfer.timeout_ms + 1);
        if (self.key_repeat.timeoutMs(app_mod.nowMs())) |wait| deadline = earlier(deadline, app_mod.nowMs() + wait);
        const at = deadline orelse return -1;
        return @intCast(std.math.clamp(at - app_mod.nowMs(), 0, 60_000));
    }

    fn earlier(current: ?i64, candidate: i64) i64 {
        return if (current) |value| @min(value, candidate) else candidate;
    }

    fn editorToken(token: *xdg.ActivationTokenV1, event: xdg.ActivationTokenV1.Event, self: *Client) void {
        if (event == .done) {
            self.app.launchEditor(std.mem.span(event.done.token));
            token.destroy();
            self.editor_token_pending = false;
        }
    }
    fn openEditor(self: *Client) void {
        if (self.app.editor_path == null or self.editor_token_pending) return;
        if (self.activation) |activation| {
            const token = activation.getActivationToken() catch {
                self.app.launchEditor("");
                return;
            };
            token.setListener(*Client, editorToken, self);
            token.setSurface(self.surface);
            if (self.seat) |seat| token.setSerial(self.input_serial, seat);
            token.setAppId("rediwm-editor");
            token.commit();
            self.editor_token_pending = true;
        } else self.app.launchEditor("");
    }

    fn previewReturned(self: *Client) void {
        const fd = self.app.preview_return_fd orelse return;
        const n = c.read(fd, self.preview_token[self.preview_token_len..].ptr, self.preview_token.len - self.preview_token_len);
        if (n > 0) {
            self.preview_token_len += @intCast(n);
            if (std.mem.indexOfScalar(u8, self.preview_token[0..self.preview_token_len], '\n')) |end| {
                self.preview_token[end] = 0;
                if (self.activation) |activation| activation.activate(&self.preview_token, self.surface);
            } else if (self.preview_token_len < self.preview_token.len) return;
        } else if (n < 0 and std.posix.errno(n) == .INTR) return;
        _ = c.close(fd);
        self.app.preview_return_fd = null;
        self.preview_token_len = 0;
    }

    fn wmBaseEvent(_: *xdg.WmBase, event: xdg.WmBase.Event, self: *Client) void {
        switch (event) {
            .ping => |ev| {
                if (self.wm_base) |wm| wm.pong(ev.serial);
            },
        }
    }

    fn outputEvent(_: *wl.Output, event: wl.Output.Event, info: *OutputInfo) void {
        if (event == .scale) {
            info.scale = std.math.clamp(event.scale.factor, 1, 4);
            info.client.recomputeScale();
        }
    }

    // The window may span multiple outputs at different scales; use the
    // largest scale among outputs the surface currently overlaps, per the
    // usual Wayland client convention. Falls back to 1 before the first
    // wl_surface.enter is received.
    fn recomputeScale(self: *Client) void {
        var new_scale: i32 = 1;
        for (self.entered_outputs.items) |info| new_scale = @max(new_scale, info.scale);
        if (new_scale != self.scale) {
            self.scale = new_scale;
            self.app.scale = new_scale;
            self.app.invalidate();
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
                self.app.invalidate();
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
                self.ack_uncommitted = true;
                self.app.invalidate();
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
                self.app.invalidate();
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
                    self.app.resize(960, @max(540, 214 + self.app.footerHeight()));
                }
                self.xdg_toplevel.setMinSize(if (self.app.chooser != null) 600 else 360, 214 + self.app.footerHeight() + tbh);
                self.app.invalidate();
            },
            .close => {
                self.running = false;
            },
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
                    if (self.pointer.?.getVersion() < 5) self.flushScroll();
                }
            },
            .axis_source => |ev| self.axis_source = ev.axis_source,
            .axis_discrete => |ev| {
                if (ev.axis == .vertical_scroll) self.axis_notches = (self.axis_notches orelse 0) + @as(f64, @floatFromInt(ev.discrete));
            },
            .axis_value120 => |ev| {
                if (ev.axis == .vertical_scroll) self.axis_notches = (self.axis_notches orelse 0) + @as(f64, @floatFromInt(ev.value120)) / 120.0;
            },
            .frame => self.flushScroll(),
            else => {},
        }
    }

    fn flushScroll(self: *Client) void {
        if (self.axis_source == .wheel or self.axis_source == .wheel_tilt) {
            const pixels_per_notch = 100.0;
            const pixels = if (self.axis_notches) |n| n * pixels_per_notch else self.axis_delta * (pixels_per_notch / 15.0);
            self.app.handleWheel(pixels, app_mod.nowMs());
        } else if (self.axis_delta != 0) {
            self.app.handleScroll(self.axis_delta);
        }
        self.axis_delta = 0;
        self.axis_notches = null;
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
    fn handlePointerMotion(self: *Client, x: f64, y: f64) void {
        const old_close_hover = self.pointer_y < CSD_TITLEBAR_H and self.pointer_x >= @as(f64, @floatFromInt(self.app.w - 32));
        self.pointer_x = x;
        self.pointer_y = y;
        defer {
            if (self.app.drag_ready) {
                self.app.drag_ready = false;
                self.startFileDrag() catch self.app.setStatusNotice("Could not start file drag", true);
            }
        }

        const tbh: f64 = @floatFromInt(self.titlebarHeight());
        self.app.handleMotion(x, @max(0, y - tbh));
        if (self.wantsCsd() and old_close_hover != (y < tbh and x >= @as(f64, @floatFromInt(self.app.w - 32)))) self.app.invalidate();
        self.refreshCursor();
    }

    fn refreshCursor(self: *Client) void {
        if (self.app.column_resize != null) {
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

    fn handlePointerButton(self: *Client, button: u32, pressed: bool) void {
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

    fn handleTitlebarClick(self: *Client, w_f: f64, tbh_f: f64) void {
        const close_w: f64 = @min(tbh_f, 32);
        if (self.pointer_x >= w_f - close_w) {
            self.running = false;
            return;
        }
        if (self.seat) |seat| self.xdg_toplevel.move(seat, self.input_serial);
    }

    /// One press of evdev `key` through the current XKB state.
    fn deliverKey(self: *Client, key: u32) void {
        const state = self.xkb_state orelse return;
        const sym = c.xkb_state_key_get_one_sym(state, key + 8);
        var buf: [64]u8 = undefined;
        const n = c.xkb_state_key_get_utf8(state, key + 8, &buf, buf.len);
        self.app.handleKey(sym, buf[0..@intCast(std.math.clamp(n, 0, 63))]);
    }

    fn appRepeats(self: *Client, key: u32) bool {
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
            .enter => self.app.refreshPins(),
            .leave => {
                self.key_repeat.stop();
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

    fn offerEvent(_: *wl.DataOffer, event: wl.DataOffer.Event, offer: *Offer) void {
        if (event == .action) offer.action = event.action.dnd_action;
        if (event == .offer) {
            if (std.mem.eql(u8, std.mem.span(event.offer.mime_type), "text/plain")) offer.text = true;
            if (std.mem.eql(u8, std.mem.span(event.offer.mime_type), "text/plain;charset=utf-8")) offer.utf8 = true;
            if (std.mem.eql(u8, std.mem.span(event.offer.mime_type), "text/uri-list")) offer.uri = true;
            if (std.mem.eql(u8, std.mem.span(event.offer.mime_type), "application/x-rediwm-file-transfer")) offer.files = true;
            if (std.mem.eql(u8, std.mem.span(event.offer.mime_type), "x-special/gnome-copied-files")) offer.gnome = true;
        }
    }

    fn discardOffer(self: *Client, offer: *Offer) void {
        for (self.offers.items, 0..) |o, i| {
            if (o == offer) {
                _ = self.offers.swapRemove(i);
                break;
            }
        }
        offer.proxy.destroy();
        a.destroy(offer);
    }

    fn dataEvent(_: *wl.DataDevice, event: wl.DataDevice.Event, self: *Client) void {
        switch (event) {
            .data_offer => |ev| {
                const offer = a.create(Offer) catch return;
                offer.* = .{ .proxy = ev.id };
                self.offers.append(a, offer) catch {
                    a.destroy(offer);
                    return;
                };
                ev.id.setListener(*Offer, offerEvent, offer);
            },
            .enter => |ev| {
                if (self.drag_offer) |old| self.discardOffer(old);
                self.drag_offer = if (ev.id) |id| @ptrCast(@alignCast(id.getUserData())) else null;
                self.drag_enter_serial = ev.serial;
                // Offers are released on leave instead of retaining every re-entry.
                self.dragOver(ev.x.toDouble(), ev.y.toDouble(), true);
            },
            .motion => |ev| self.dragOver(ev.x.toDouble(), ev.y.toDouble(), false),
            .leave => {
                self.app.dropLeave();
                if (self.drag_offer) |offer| self.discardOffer(offer);
                self.drag_offer = null;
            },
            .drop => self.dragDropped(),
            .selection => |ev| {
                self.cancelReceive();
                if (self.selection_offer) |old| self.discardOffer(old);
                self.selection_offer = if (ev.id) |id| @ptrCast(@alignCast(id.getUserData())) else null;
            },
        }
    }

    fn dragOver(self: *Client, x: f64, y: f64, entered: bool) void {
        const offer = self.drag_offer orelse return;
        self.drag_x = x;
        self.drag_y = y - @as(f64, @floatFromInt(self.titlebarHeight()));
        const available = offer.uri and self.drop_receiving == null;
        const pin = available and self.app.dropMotion(x, self.drag_y);
        const folder = available and !pin and self.app.dropDirectoryAt(x, self.drag_y) != null;
        self.app.highlightDrop(x, self.drag_y, folder);
        const wanted = pin or folder;
        const moving = folder and offer.files;
        if (!entered and wanted == self.drag_accepting and moving == self.drag_moving) return;
        self.drag_accepting = wanted;
        self.drag_moving = moving;
        offer.proxy.accept(self.drag_enter_serial, if (wanted) "text/uri-list" else null);
        if (offer.proxy.getVersion() >= 3) {
            // Files performs filesystem moves in the receiving job, never in
            // the source's finished callback. Other sources and pins copy.
            offer.proxy.setActions(.{ .copy = wanted, .move = moving }, if (moving) .{ .move = true } else .{ .copy = wanted });
        }
    }

    fn dragDropped(self: *Client) void {
        const offer = self.drag_offer orelse return;
        self.drag_offer = null;
        defer self.app.dropLeave();
        const accepted = self.drag_accepting;
        self.drag_accepting = false;
        const slot = self.app.takePinDrop();
        const directory = if (slot != null) "" else self.app.dropDirectoryAt(self.drag_x, self.drag_y) orelse {
            self.discardOffer(offer);
            return;
        };
        if (!accepted or (offer.proxy.getVersion() >= 3 and !offer.action.copy and !offer.action.move)) {
            self.discardOffer(offer);
            return;
        }
        self.startDropReceive(offer, slot, directory) catch {
            self.app.setStatusNotice("Could not read the dropped items", true);
            self.discardOffer(offer);
        };
    }

    fn startDropReceive(self: *Client, offer: *Offer, slot: ?usize, target: []const u8) !void {
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return error.PipeFailed;
        defer _ = c.close(fds[1]);
        errdefer _ = c.close(fds[0]);
        if (c.fcntl(fds[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.NonblockingFailed;
        const directory = try a.dupe(u8, target);
        self.drop_receiving = .{ .fd = fds[0], .text = false, .revision = 0, .directory = directory, .started = app_mod.nowMs() };
        self.drop_offer = offer;
        self.drop_slot = slot;
        self.drop_move = slot == null and offer.action.move;
        offer.proxy.receive("text/uri-list", fds[1]);
    }

    fn canonicalPath(path: []const u8) ![]u8 {
        const terminated = try a.dupeZ(u8, path);
        defer a.free(terminated);
        var buffer: [4096]u8 = undefined;
        const resolved = c.realpath(terminated, &buffer) orelse return error.InvalidPath;
        return a.dupe(u8, std.mem.span(resolved));
    }

    fn receiveDrop(self: *Client) void {
        const receive = if (self.drop_receiving) |*r| r else return;
        if (app_mod.nowMs() - receive.started > transfer.timeout_ms) {
            self.app.setStatusNotice("The drop timed out", true);
            self.finishDrop();
            return;
        }
        const done = receive.read() catch {
            self.app.setStatusNotice("The dropped list failed or exceeded 1 MiB", true);
            self.finishDrop();
            return;
        };
        if (!done) return;
        defer self.finishDrop();
        const decoded = clipboard_mod.decodeUris(a, receive.bytes.items) catch {
            self.app.setStatusNotice("Invalid dropped list", true);
            return;
        };
        defer decoded.deinit(a);
        if (self.drop_slot) |slot| {
            self.app.pinDropped(slot, decoded.paths);
        } else {
            const destination = canonicalPath(receive.directory) catch {
                self.app.setStatusNotice("The destination folder is unavailable", true);
                return;
            };
            defer a.free(destination);
            var paths: std.ArrayList([]const u8) = .empty;
            defer paths.deinit(a);
            for (decoded.paths) |path| {
                const resolved = canonicalPath(path) catch continue;
                defer a.free(resolved);
                if (@import("ops.zig").isDescendantOrSame(resolved, destination)) {
                    self.app.setStatusNotice("Cannot drop a folder into itself", true);
                    return;
                }
                const parent = std.fs.path.dirname(path) orelse continue;
                const resolved_parent = canonicalPath(parent) catch continue;
                defer a.free(resolved_parent);
                if (self.drop_move and std.mem.eql(u8, resolved_parent, destination)) continue;
                paths.append(a, path) catch return;
            }
            if (paths.items.len == 0) return;
            _ = self.app.executeTransfer(if (self.drop_move) .move else .copy, paths.items, destination, false);
        }
    }

    fn finishDrop(self: *Client) void {
        if (self.drop_receiving) |*receive| receive.deinit();
        self.drop_receiving = null;
        const offer = self.drop_offer orelse return;
        self.drop_offer = null;
        self.endDrop(offer);
    }

    /// Tells the source the drop is over, so it can let go of the drag, and
    /// releases the offer.
    fn endDrop(self: *Client, offer: *Offer) void {
        if (offer.proxy.getVersion() >= 3) offer.proxy.finish();
        self.discardOffer(offer);
    }

    fn clipboardEvent(source: *wl.DataSource, event: wl.DataSource.Event, clip: *ClipboardSource) void {
        switch (event) {
            .send => |ev| {
                const mime = std.mem.span(ev.mime_type);
                const data = if (std.mem.eql(u8, mime, "x-special/gnome-copied-files")) clip.gnome else clip.uris;
                if (clip.client.sends.items.len >= 8) {
                    _ = c.close(ev.fd);
                    return;
                }
                var send = transfer.Send.init(ev.fd, data, app_mod.nowMs()) catch return;
                clip.client.sends.append(a, send) catch send.deinit();
            },
            .dnd_drop_performed => {
                if (clip.client.drag_source == clip) clip.client.clearDragIcon();
            },
            .cancelled, .dnd_finished => {
                if (clip.client.drag_source == clip) {
                    clip.client.clearDragIcon();
                    clip.client.drag_source = null;
                }
                if (clip.client.clipboard_source == clip) {
                    clip.client.clipboard_source = null;
                    clip.client.app.clearClipboard();
                    clip.client.app.clipboard_cut = false;
                    clip.client.app.clipboard_text.clearRetainingCapacity();
                    clip.client.app.invalidate();
                }
                source.destroy();
                a.free(clip.uris);
                a.free(clip.gnome);
                a.destroy(clip);
            },
            else => {},
        }
    }

    fn clearDragIcon(self: *Client) void {
        if (self.drag_icon) |*icon| icon.destroy();
        self.drag_icon = null;
    }

    fn startFileDrag(self: *Client) !void {
        const manager = self.data_manager orelse return;
        const device = self.data_device orelse return;
        if (self.drag_source != null) return;
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(a);
        for (self.app.items.items) |item| {
            if (item.selected and !item.missing) try paths.append(a, item.path);
        }
        if (paths.items.len == 0) return;
        const source = try manager.createDataSource();
        errdefer source.destroy();
        const clip = try a.create(ClipboardSource);
        errdefer a.destroy(clip);
        const uris = try clipboard_mod.encodeUriList(a, paths.items);
        errdefer a.free(uris);
        const gnome = try a.dupe(u8, "");
        clip.* = .{ .client = self, .proxy = source, .uris = uris, .gnome = gnome };
        source.setListener(*ClipboardSource, clipboardEvent, clip);
        source.offer("text/uri-list");
        source.offer("application/x-rediwm-file-transfer");
        // The receiving file manager performs moves; upload targets choose copy.
        if (source.getVersion() >= 3) source.setActions(.{ .copy = true, .move = !self.app.ctrl });
        self.drag_source = clip;
        self.app.cancelWheel();
        self.app.cancelDrag();
        // The icon is optional: an allocation failure must not lose the drag.
        self.drag_icon = DragIcon.create(self) catch null;
        device.startDrag(source, self.surface, if (self.drag_icon) |icon| icon.surface else null, self.drag_serial);
        if (self.drag_icon) |icon| icon.surface.commit();
    }

    fn destroyClipboardSource(self: *Client) void {
        if (self.clipboard_source) |clip| {
            clip.proxy.destroy();
            a.free(clip.uris);
            a.free(clip.gnome);
            a.destroy(clip);
            self.clipboard_source = null;
        }
    }

    fn publishClipboard(self: *Client) !void {
        const manager = self.data_manager orelse return;
        const device = self.data_device orelse return;
        if (!self.app.clipboard_is_text and self.app.clipboard_paths.items.len == 0) {
            device.setSelection(null, self.input_serial);
            self.destroyClipboardSource();
            return;
        }
        const source = try manager.createDataSource();
        errdefer source.destroy();
        const clip = try a.create(ClipboardSource);
        errdefer a.destroy(clip);
        const mode: clipboard_mod.ClipboardMode = if (self.app.clipboard_cut) .cut else .copy;
        const uris = if (self.app.clipboard_is_text) try a.dupe(u8, self.app.clipboard_text.items) else try clipboard_mod.encodeUriList(a, self.app.clipboard_paths.items);
        errdefer a.free(uris);
        const gnome = if (self.app.clipboard_is_text) try a.dupe(u8, "") else try clipboard_mod.encodeGnomeCopiedFiles(a, mode, self.app.clipboard_paths.items);
        clip.* = .{ .client = self, .proxy = source, .uris = uris, .gnome = gnome, .text = self.app.clipboard_is_text };
        source.setListener(*ClipboardSource, clipboardEvent, clip);
        if (clip.text) {
            source.offer("text/plain;charset=utf-8");
            source.offer("text/plain");
        } else {
            source.offer("text/uri-list");
            source.offer("x-special/gnome-copied-files");
        }
        device.setSelection(source, self.input_serial);
        self.destroyClipboardSource();
        self.clipboard_source = clip;
    }

    fn cancelReceive(self: *Client) void {
        if (self.receiving) |*receive| receive.deinit();
        self.receiving = null;
    }

    fn receiveClipboard(self: *Client) void {
        const receive = if (self.receiving) |*r| r else return;
        if (app_mod.nowMs() - receive.started > transfer.timeout_ms) {
            self.app.setStatusNotice("Clipboard transfer timed out", true);
            self.cancelReceive();
            return;
        }
        const done = receive.read() catch {
            self.app.setStatusNotice("Clipboard transfer failed or exceeded 1 MiB", true);
            self.cancelReceive();
            return;
        };
        if (!done) return;
        defer self.cancelReceive();
        if (receive.text) {
            if (receive.revision == self.app.edit_revision) self.app.pasteText(receive.bytes.items);
        } else {
            // A delayed reply must not paste into a folder navigated to meanwhile.
            if (!std.mem.eql(u8, receive.directory, self.app.history.current)) return;
            const decoded = clipboard_mod.decodeUris(a, receive.bytes.items) catch {
                self.app.setStatusNotice("Invalid file clipboard", true);
                return;
            };
            defer decoded.deinit(a);
            self.app.executePasteExternal(decoded.mode, decoded.paths);
        }
    }

    fn handleClipboard(self: *Client) !void {
        if (self.app.clipboard_revision != self.clipboard_revision) {
            try self.publishClipboard();
            self.clipboard_revision = self.app.clipboard_revision;
        }
        if (!self.app.paste_requested and !self.app.text_paste_requested) return;
        const text = self.app.text_paste_requested;
        self.app.paste_requested = false;
        self.app.text_paste_requested = false;
        self.cancelReceive();
        if (self.clipboard_source) |clip| {
            if (text and clip.text) self.app.pasteText(clip.uris);
            if (!text and !clip.text) self.app.executePasteLocal();
            return;
        }
        const offer = self.selection_offer orelse return;
        const mime: [:0]const u8 = if (text) (if (offer.utf8) "text/plain;charset=utf-8" else if (offer.text) "text/plain" else return) else (if (offer.gnome) "x-special/gnome-copied-files" else if (offer.uri) "text/uri-list" else return);
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return error.PipeFailed;
        defer _ = c.close(fds[1]);
        errdefer _ = c.close(fds[0]);
        if (c.fcntl(fds[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.NonblockingFailed;
        const directory = try a.dupe(u8, self.app.history.current);
        self.receiving = .{ .fd = fds[0], .text = text, .revision = self.app.edit_revision, .directory = directory, .started = app_mod.nowMs() };
        offer.proxy.receive(mime, fds[1]);
        // The main loop flushes this request before polling the receive pipe.
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

    fn acquireBuffer(self: *Client, w: i32, h: i32) !*Buffer {
        var i: usize = 0;
        while (i < self.buffers.items.len) {
            const buffer = self.buffers.items[i];
            if (!buffer.busy and (buffer.w != w or buffer.h != h)) {
                _ = self.buffers.swapRemove(i);
                buffer.destroy();
            } else i += 1;
        }
        for (self.buffers.items) |buffer| {
            if (!buffer.busy) return buffer;
        }
        const buffer = try Buffer.create(self, w, h);
        errdefer buffer.destroy();
        try self.buffers.append(a, buffer);
        return buffer;
    }

    fn render(self: *Client) !void {
        if (!self.configured or !self.app.dirty or self.outstanding >= 2) return;

        const tbh = self.titlebarHeight();
        const w = self.app.w;
        const h = self.app.h + tbh;
        const bw = w * self.scale;
        const bh = h * self.scale;
        const buffer = try self.acquireBuffer(bw, bh);

        const partial = self.retained.items.len == buffer.len and self.retained_w == bw and self.applied_scale == self.scale and self.app.paint_damage != null;
        if (partial) {
            const pixels: [*]u8 = @ptrCast(buffer.memory);
            @memcpy(pixels[0..buffer.len], self.retained.items);
            c.cairo_surface_mark_dirty(buffer.image);
        }
        const cr = c.cairo_create(buffer.image) orelse return error.CairoFailed;
        defer c.cairo_destroy(cr);

        c.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));
        if (partial) {
            var rect = self.app.paint_damage.?;
            rect.y += @floatFromInt(tbh);
            app_mod.clipDamage(cr, rect);
        }

        if (tbh > 0) self.renderTitlebar(cr, w, tbh);

        c.cairo_save(cr);
        c.cairo_translate(cr, 0, @floatFromInt(tbh));
        self.app.render(cr);
        c.cairo_restore(cr);

        c.cairo_surface_flush(buffer.image);

        const bytes: []const u8 = @as([*]const u8, @ptrCast(buffer.memory))[0..buffer.len];
        var x1 = bw;
        var y1 = bh;
        var x2: i32 = 0;
        var y2: i32 = 0;
        if (self.retained.items.len != bytes.len or self.retained_w != bw or self.applied_scale != self.scale) {
            x1 = 0;
            y1 = 0;
            x2 = bw;
            y2 = bh;
        } else {
            // Compare against the last published image, never against this recycled buffer.
            const stride: usize = @intCast(bw * 4);
            for (0..@intCast(bh)) |row| {
                const offset = row * stride;
                if (std.mem.eql(u8, bytes[offset..][0..stride], self.retained.items[offset..][0..stride])) continue;
                y1 = @min(y1, @as(i32, @intCast(row)));
                y2 = @as(i32, @intCast(row + 1));
                var left: usize = 0;
                while (left < stride and std.mem.eql(u8, bytes[offset + left ..][0..4], self.retained.items[offset + left ..][0..4])) : (left += 4) {}
                var right = stride;
                while (right > left and std.mem.eql(u8, bytes[offset + right - 4 ..][0..4], self.retained.items[offset + right - 4 ..][0..4])) : (right -= 4) {}
                x1 = @min(x1, @as(i32, @intCast(left / 4)));
                x2 = @max(x2, @as(i32, @intCast(right / 4)));
            }
        }
        try self.retained.resize(a, bytes.len);
        @memcpy(self.retained.items, bytes);
        self.retained_w = bw;
        if (self.applied_scale != self.scale) {
            self.surface.setBufferScale(self.scale);
            self.applied_scale = self.scale;
        }
        if (x2 > x1 and y2 > y1) {
            self.xdg_surface.setWindowGeometry(0, 0, w, h);
            self.surface.attach(buffer.wl_buffer, 0, 0);
            self.surface.damageBuffer(x1, y1, x2 - x1, y2 - y1);
            self.surface.commit();
            buffer.busy = true;
            self.outstanding += 1;
        } else if (self.ack_uncommitted) {
            // Keep the attached buffer; the commit only applies the ack.
            self.xdg_surface.setWindowGeometry(0, 0, w, h);
            self.surface.commit();
        }
        self.ack_uncommitted = false;
        self.app.dirty = false;
    }

    fn renderTitlebar(self: *Client, cr: *c.cairo_t, w: i32, h: i32) void {
        const w_f: f64 = @floatFromInt(w);
        const h_f: f64 = @floatFromInt(h);

        shell_ui.setSource(cr, ui_theme.global.window_bg);
        c.cairo_rectangle(cr, 0, 0, w_f, h_f);
        c.cairo_fill(cr);

        shell_ui.setSource(cr, ui_theme.global.app_divider);
        c.cairo_set_line_width(cr, 1);
        c.cairo_move_to(cr, 0, h_f - 0.5);
        c.cairo_line_to(cr, w_f, h_f - 0.5);
        c.cairo_stroke(cr);

        const title = std.mem.span(self.app.getTitle());
        shell_ui.setSource(cr, ui_theme.global.window_fg);
        const tw = app_mod.measureText(cr, title, 12, true);
        app_mod.drawText(cr, title, (w_f - tw) / 2.0, h_f / 2.0 + 4, 12, true);

        const close_w: f64 = @min(h_f, 32);
        const hovered = self.inside and self.pointer_y < h_f and self.pointer_x >= w_f - close_w;
        if (hovered) {
            shell_ui.setSource(cr, ui_theme.global.window_close_hover);
            c.cairo_rectangle(cr, w_f - close_w, 0, close_w, h_f);
            c.cairo_fill(cr);
            c.cairo_set_source_rgb(cr, 1, 1, 1);
        } else {
            shell_ui.setSource(cr, ui_theme.global.window_dim);
        }
        const cx = w_f - close_w / 2.0;
        const cy = h_f / 2.0;
        c.cairo_set_line_width(cr, 1.5);
        c.cairo_move_to(cr, cx - 5, cy - 5);
        c.cairo_line_to(cr, cx + 5, cy + 5);
        c.cairo_move_to(cr, cx + 5, cy - 5);
        c.cairo_line_to(cr, cx - 5, cy + 5);
        c.cairo_stroke(cr);
    }
};

/// A separate, immutable buffer: window repaints must never recycle the drag image.
const DragIcon = struct {
    surface: *wl.Surface,
    buffer: *Buffer,

    fn create(client: *Client) !DragIcon {
        const surface = try client.compositor.?.createSurface();
        errdefer surface.destroy();
        const buffer = try Buffer.create(client, 48 * client.scale, 56 * client.scale);
        errdefer buffer.destroy();
        buffer.counts_frame = false;
        const cr = c.cairo_create(buffer.image) orelse return error.CairoFailed;
        defer c.cairo_destroy(cr);
        c.cairo_scale(cr, @floatFromInt(client.scale), @floatFromInt(client.scale));
        // Transparent padding places the file below and to the right of the pointer.
        for (client.app.items.items) |item| {
            if (!item.selected or item.missing) continue;
            client.app.drawItemIcon(cr, item, 8, 16, 32);
            break;
        }
        c.cairo_surface_flush(buffer.image);
        surface.setBufferScale(client.scale);
        surface.attach(buffer.wl_buffer, 0, 0);
        surface.damageBuffer(0, 0, buffer.w, buffer.h);
        return .{ .surface = surface, .buffer = buffer };
    }

    fn destroy(self: *DragIcon) void {
        self.surface.destroy();
        self.buffer.destroy();
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
    counts_frame: bool = true,

    fn create(client: *Client, w: i32, h: i32) !*Buffer {
        if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return error.InvalidSize;
        const len: usize = @intCast(w * h * 4);
        const fd = c.memfd_create("rediwm-files", c.MFD_CLOEXEC);
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
        if (self.counts_frame) self.client.outstanding -= 1;
    }
    fn destroy(self: *Buffer) void {
        self.wl_buffer.destroy();
        c.cairo_surface_destroy(self.image);
        _ = c.munmap(self.memory, self.len);
        a.destroy(self);
    }
};

pub fn run(init: std.process.Init, target_dir: []const u8, selected_file: ?[]const u8, chooser: ?@import("chooser.zig").Options) !void {
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);

    const home_dir = init.minimal.environ.getPosix("HOME") orelse "/";
    // Test-only escape hatch: skip decoration negotiation to exercise the
    // same fallback as a compositor without xdg-decoration support.
    const force_csd = init.minimal.environ.getPosix("REDIWM_FILES_FORCE_CSD") != null;
    // The worker follows later edits.
    @import("settings.zig").loadTheme(init.gpa, init.io, init.minimal.environ);
    defer @import("settings.zig").deinitTheme();

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const worker = try worker_mod.Worker.init(a, init.io, init.minimal.environ, target_dir);
    defer worker.deinit();

    const app = try app_mod.App.init(
        a,
        init.io,
        init.minimal.environ,
        worker.theme_cfg,
        worker,
        target_dir,
        home_dir,
    );

    var self = Client{
        .display = display,
        .app = app,
    };
    defer self.app.deinit();
    if (chooser) |options| try self.app.configureChooser(options);
    if (selected_file) |path| self.app.selectOnLoad(path);
    self.app.startDevices();
    defer {
        self.clearDragIcon();
        self.cancelReceive();
        if (self.drop_receiving) |*receive| receive.deinit();
        for (self.sends.items) |*send| send.deinit();
        self.sends.deinit(a);
        for (self.buffers.items) |buffer| buffer.destroy();
        self.buffers.deinit(a);
        self.retained.deinit(a);
    }

    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(*Client, Client.registryEvent, &self);

    if (display.roundtrip() != .SUCCESS) return error.DisplayFailed;
    if (self.compositor == null or self.shm == null or self.wm_base == null) {
        return error.MissingWaylandGlobals;
    }

    if (self.data_manager) |manager| {
        if (self.seat) |seat| {
            self.data_device = manager.getDataDevice(seat) catch null;
            if (self.data_device) |device| device.setListener(*Client, Client.dataEvent, &self);
        }
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

    self.xdg_toplevel.setAppId(if (chooser != null) "rediwm-file-chooser" else "rediwm-files");
    self.xdg_toplevel.setTitle(self.app.getTitle());
    // Real min size is set from xdgToplevelEvent once the decoration mode
    // (and thus titlebar height) is known; this is just a safe pre-configure
    // default sized for the worst case (self-decorated).
    self.xdg_toplevel.setMinSize(if (chooser != null) 600 else 360, 214 + self.app.footerHeight() + CSD_TITLEBAR_H);

    // Prefer server-side decorations; the compositor may still tell us via
    // decorationEvent to self-decorate (e.g. it has no SSD implementation),
    // and if zxdg_decoration_manager_v1 isn't advertised at all we already
    // default to self-decorating (see wantsCsd).
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

    // Initial commit to start xdg configuration sequence
    self.surface.commit();

    while (self.running and !self.app.chooser_done) {
        self.openEditor();
        try self.handleClipboard();
        self.app.sync();
        self.app.stepThumbs();
        self.app.stepWheel(app_mod.nowMs());
        self.app.stepSelection(app_mod.nowMs());
        self.app.stepLayout(app_mod.nowMs());
        self.app.stepHover(app_mod.nowMs());
        self.app.stepScrollbar(app_mod.nowMs());
        self.app.stepScanNotice(app_mod.nowMs());
        self.refreshCursor();

        if (self.app.title_changed) {
            self.xdg_toplevel.setTitle(self.app.getTitle());
            self.app.title_changed = false;
        }

        try self.render();

        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        }

        if (self.app.chooser_done) {
            display.cancelRead();
            break;
        }
        const flushed = display.flush();
        if (flushed != .SUCCESS and flushed != .AGAIN) {
            display.cancelRead();
            return error.DisplayFailed;
        }

        var fds: [19]c.struct_pollfd = @splat(.{ .fd = -1, .events = c.POLLIN, .revents = 0 });
        fds[0] = .{ .fd = display.getFd(), .events = @intCast(c.POLLIN | @as(c_int, if (flushed == .AGAIN) c.POLLOUT else 0)), .revents = 0 };
        fds[1].fd = self.app.preview_return_fd orelse -1;
        fds[2].fd = if (self.receiving) |receive| receive.fd else -1;
        fds[3].fd = self.app.worker.wake_main;
        fds[4].fd = if (self.app.dirsize_pool) |p| p.done_fd else -1;
        fds[5].fd = self.app.thumbWakeFd();
        // Slots 6..13 belong to the clipboard sends (at most eight).
        fds[14].fd = self.app.devicesWakeFd();
        fds[15].fd = if (self.drop_receiving) |receive| receive.fd else -1;
        fds[16].fd = self.app.children.fd;
        fds[17].fd = self.app.extract_picker_fd orelse -1;
        fds[18].fd = if (self.app.job_runner) |runner| runner.wake_fd else -1;
        const send_count = self.sends.items.len;
        for (self.sends.items, 0..) |send, i| fds[i + 6] = .{ .fd = send.fd, .events = c.POLLOUT, .revents = 0 };

        const result = c.poll(&fds, fds.len, self.pollTimeout());
        if (result > 0 and (fds[0].revents & c.POLLIN != 0)) {
            if (display.readEvents() != .SUCCESS) return error.DisplayFailed;
        } else {
            display.cancelRead();
        }

        if ((fds[0].revents & (c.POLLERR | c.POLLHUP)) != 0) return error.DisplayFailed;
        if (fds[3].revents & c.POLLIN != 0) self.app.worker.drainMain();
        if (fds[4].revents & c.POLLIN != 0) {
            if (self.app.dirsize_pool) |p| p.drainDone();
        }
        if (fds[5].revents & c.POLLIN != 0) self.app.drainThumbs();
        if (fds[14].revents & c.POLLIN != 0) self.app.drainDevices();
        if (fds[16].revents != 0) while (self.app.children.next() != null) {};
        if (fds[18].revents != 0) if (self.app.job_runner) |runner| runner.drain();
        if (fds[17].revents != 0) self.app.extractionFolderReady();
        if (fds[1].revents != 0) self.previewReturned();
        if (self.receiving != null and (fds[2].revents != 0 or app_mod.nowMs() - self.receiving.?.started > transfer.timeout_ms)) self.receiveClipboard();
        if (self.drop_receiving != null and (fds[15].revents != 0 or app_mod.nowMs() - self.drop_receiving.?.started > transfer.timeout_ms)) self.receiveDrop();
        var si = send_count;
        while (si > 0) {
            si -= 1;
            const send = &self.sends.items[si];
            const expired = app_mod.nowMs() - send.started > transfer.timeout_ms;
            if (expired or (fds[si + 6].revents != 0 and (send.write() catch true))) {
                send.deinit();
                _ = self.sends.orderedRemove(si);
            }
        }
        if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        // After dispatch: a release read by this poll ends the repeat first.
        self.repeatDue();
    }

    if (chooser != null) {
        const result: @import("chooser.zig").Result = .{
            .paths = if (self.app.chooser_accepted) self.app.chooser_paths.items else &.{},
            .filter_index = self.app.chooser.?.filter_index,
            .choices = self.app.chooser_choices.items,
        };
        const bytes = try std.json.Stringify.valueAlloc(a, result, .{});
        defer a.free(bytes);
        try std.Io.File.stdout().writeStreamingAll(init.io, bytes);
    }
    for (self.offers.items) |o| {
        o.proxy.destroy();
        a.destroy(o);
    }
    self.offers.deinit(a);
    for (self.outputs.items) |info| {
        info.proxy.destroy();
        a.destroy(info);
    }
    self.outputs.deinit(a);
    self.entered_outputs.deinit(a);
    if (self.clipboard_source) |clip| {
        clip.proxy.destroy();
        a.free(clip.uris);
        a.free(clip.gnome);
        a.destroy(clip);
    }
    if (self.drag_source) |clip| {
        clip.proxy.destroy();
        a.free(clip.uris);
        a.free(clip.gnome);
        a.destroy(clip);
    }
    if (self.data_device) |device| device.release();

    if (self.xkb_state) |state| c.xkb_state_unref(state);
    if (self.xkb_context) |context| c.xkb_context_unref(context);
}
