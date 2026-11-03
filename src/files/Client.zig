//! The Files window's Wayland client: globals, seat, surface state and the
//! poll deadline. Its event handlers and drawing are in `client_*.zig` beside it
//! (window, input, dnd, clipboard, render); `main.zig` re-exports it.

const std = @import("std");
const ClientCursor = @import("ui").client_cursor;
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const key_repeat_mod = @import("ui").key_repeat;
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const transfer = @import("transfer.zig");
const clipboard_mod = @import("clipboard.zig");
const a = std.heap.c_allocator;
const main = @import("main.zig");
const Offer = main.Offer;
const CSD_TITLEBAR_H = main.CSD_TITLEBAR_H;
const RESIZE_MARGIN = main.RESIZE_MARGIN;
const DecorationMode = main.DecorationMode;
const OutputInfo = main.OutputInfo;
const ClipboardSource = main.ClipboardSource;
const DragIcon = main.DragIcon;
const Buffer = main.Buffer;
const Client = @This();

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
drop_terminal: bool = false,
drop_move: bool = false,
clipboard_source: ?*ClipboardSource = null,
drag_source: ?*ClipboardSource = null,
drag_serial: u32 = 0,
drag_icon: ?DragIcon = null,
axis_source: wl.Pointer.AxisSource = .wheel,
finger_navigation: @import("ui").trackpad_navigation.Gesture = .{},
axis_delta: f64 = 0,
horizontal_delta: f64 = 0,
horizontal_notches: ?f64 = null,
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
key_repeat: key_repeat_mod.KeyRepeat = .{},
compose: @import("ui").compose.Compose = .{},
ime: @import("terminal/ime.zig").Ime = undefined,
/// LC_CTYPE of the session; picks the Compose table (´+c is ç in pt_BR).
locale: []const u8 = "",
app: app_mod.App,

pub fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Client) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.span(g.interface);
            self.cursor_shape.bind(registry, g.name, iface, g.version);
            if (std.mem.eql(u8, iface, "zwp_text_input_manager_v3")) self.ime.manager = registry.bind(g.name, @import("wayland").client.zwp.TextInputManagerV3, 1) catch null;
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
pub fn pollTimeout(self: *Client) c_int {
    if (self.app.wheel_glide.active() or self.app.selectionNeedsScroll() or self.app.hover_active or self.app.layout_active or self.app.scroll_appearance.active or self.app.sidebar_scroll_appearance.active or self.app.horizontal_appearance.active or self.app.terminal.active or self.app.terminal.bar.active) return 16;
    if (self.app.hasRunningFolderSize()) return 33;
    var deadline: ?i64 = self.app.torrents.retry_at;
    if (self.app.terminal.close_at) |at| deadline = earlier(deadline, at);
    if (self.app.terminal.visible) if (self.app.terminal.bar.deadline) |at| {
        deadline = earlier(deadline, at);
    };
    if (self.app.status_notice != null) deadline = earlier(deadline, self.app.status_notice_until);
    if (self.app.scanNoticeDeadline()) |at| deadline = earlier(deadline, at);
    if (self.app.scroll_appearance.deadline) |at| deadline = earlier(deadline, at);
    if (self.app.horizontal_appearance.deadline) |at| deadline = earlier(deadline, at);
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

const client_window = @import("client_window.zig");
pub const openEditor = client_window.openEditor;
pub const previewReturned = client_window.previewReturned;
const wmBaseEvent = client_window.wmBaseEvent;
const outputEvent = client_window.outputEvent;
pub const recomputeScale = client_window.recomputeScale;
pub const removeEnteredOutput = client_window.removeEnteredOutput;
pub const surfaceEvent = client_window.surfaceEvent;
const seatEvent = client_window.seatEvent;
pub const xdgSurfaceEvent = client_window.xdgSurfaceEvent;
pub const wantsCsd = client_window.wantsCsd;
pub const titlebarHeight = client_window.titlebarHeight;
pub const decorationEvent = client_window.decorationEvent;
pub const xdgToplevelEvent = client_window.xdgToplevelEvent;

const client_input = @import("client_input.zig");
pub const pointerEvent = client_input.pointerEvent;
pub const flushScroll = client_input.flushScroll;
pub const handlePointerMotion = client_input.handlePointerMotion;
pub const refreshCursor = client_input.refreshCursor;
pub const handlePointerButton = client_input.handlePointerButton;
pub const handleTitlebarClick = client_input.handleTitlebarClick;
pub const deliverKey = client_input.deliverKey;
pub const appRepeats = client_input.appRepeats;
pub const repeatDue = client_input.repeatDue;
pub const keyboardEvent = client_input.keyboardEvent;
pub const setCursor = client_input.setCursor;

const client_dnd = @import("client_dnd.zig");
pub const discardOffer = client_dnd.discardOffer;
pub const dataEvent = client_dnd.dataEvent;
pub const dragOver = client_dnd.dragOver;
pub const dragDropped = client_dnd.dragDropped;
pub const startDropReceive = client_dnd.startDropReceive;
pub const receiveDrop = client_dnd.receiveDrop;
pub const finishDrop = client_dnd.finishDrop;
pub const endDrop = client_dnd.endDrop;
pub const clearDragIcon = client_dnd.clearDragIcon;
pub const startFileDrag = client_dnd.startFileDrag;

const client_clipboard = @import("client_clipboard.zig");
pub const clipboardEvent = client_clipboard.clipboardEvent;
pub const destroyClipboardSource = client_clipboard.destroyClipboardSource;
pub const publishClipboard = client_clipboard.publishClipboard;
pub const cancelReceive = client_clipboard.cancelReceive;
pub const receiveClipboard = client_clipboard.receiveClipboard;
pub const handleClipboard = client_clipboard.handleClipboard;

const client_render = @import("client_render.zig");
pub const acquireBuffer = client_render.acquireBuffer;
pub const render = client_render.render;
pub const renderTitlebar = client_render.renderTitlebar;
