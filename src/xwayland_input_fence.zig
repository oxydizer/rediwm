//! A marker on the XWM connection orders pointer delivery after X11 restacks.
//! The X server has processed every earlier request from this connection when
//! its event arrives. wlroots remains the sole reader of the X socket.
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");
const Xwayland = @import("Xwayland.zig");
const xcb = wlr.Xwayland.Xcb;
const Self = @This();

root: u32 = 0,
phase: enum { unavailable, extension, selection, ready } = .unavailable,
setup_marker: u32 = 0,
select_sequence: u32 = 0,
version: xcb.VersionCookie = .{ .sequence = 0 },
opcode: u8 = 0,
writable: ?*wl.EventSource = null,
client_destroy: wl.Listener(*wl.Client) = .init(clientDestroyed),

// This ClientMessage is delivered to the root's exclusive SubstructureRedirect
// selector (the XWM). The sequence used for the acknowledgment comes from XCB's
// event header, independent of the message payload.
const marker = [5]u32{ 0x52656469, 0x574d5846, 0, 0, 0 };

pub fn start(self: *Self, owner: *Xwayland) void {
    self.reset(owner);
    const xw = owner.wlr_xwayland;
    const client = (xw.server orelse return).client orelse return;
    const conn = xw.getXwmConnection() orelse return;
    const screen = xcb.rootsIterator(xcb.getSetup(conn)).data;
    if (screen == null) return;
    self.root = screen.*.root;
    client.addDestroyListener(&self.client_destroy);
    xw.data = owner;
    xw.user_event_handler = handleEvent;
    // Put a marker behind each setup request. Its arrival means the preceding
    // reply is already in XCB, so the compositor never waits for the X server.
    self.phase = .extension;
    xcb.prefetchExtension(conn, xcb.input_id);
    self.setup_marker = self.sendMarker(owner) orelse return self.reset(owner);
}

pub fn reset(self: *Self, owner: *Xwayland) void {
    if (self.root != 0) self.client_destroy.link.remove();
    self.root = 0;
    self.phase = .unavailable;
    if (self.writable) |source| source.remove();
    self.writable = null;
    owner.wlr_xwayland.user_event_handler = null;
    owner.wlr_xwayland.data = null;
    owner.pointerFenceReset();
}

fn clientDestroyed(listener: *wl.Listener(*wl.Client), _: *wl.Client) void {
    const self: *Self = @fieldParentPtr("client_destroy", listener);
    const owner: *Xwayland = @fieldParentPtr("input_fence", self);
    self.reset(owner);
}

pub fn submit(self: *Self, owner: *Xwayland) ?u32 {
    if (!self.canFence()) return null;
    return self.sendMarker(owner);
}

pub fn canFence(self: *const Self) bool {
    return self.phase == .ready;
}

fn sendMarker(self: *Self, owner: *Xwayland) ?u32 {
    const conn = owner.wlr_xwayland.getXwmConnection() orelse return null;
    if (xcb.hasError(conn) != 0) return null;
    if (self.writable == null) {
        const loop = owner.server.wl_server.getEventLoop();
        self.writable = loop.addFd(*Xwayland, xcb.fd(conn), .{ .writable = true }, flush, owner) catch return null;
    }
    const message: xcb.ClientMessage = .{
        .response_type = xcb.client_message,
        .format = 32,
        .sequence = 0,
        .window = self.root,
        .type = xcb.cardinal,
        .data = .{ .data32 = marker },
    };
    return xcb.sendEvent(conn, 0, self.root, xcb.substructure_redirect, @ptrCast(&message)).sequence;
}

fn flush(_: c_int, mask: wl.EventMask, owner: *Xwayland) c_int {
    const self = &owner.input_fence;
    self.writable.?.remove();
    self.writable = null;
    if (!mask.hangup and !mask.@"error") {
        if (owner.wlr_xwayland.getXwmConnection()) |conn| if (xcb.flush(conn) > 0) return 0;
    }
    self.reset(owner);
    return 0;
}

fn handleEvent(xw: *wlr.Xwayland, event: *xcb.Event) callconv(.c) bool {
    const owner: *Xwayland = @ptrCast(@alignCast(xw.data orelse return false));
    const self = &owner.input_fence;
    if (event.response_type == 0 and self.phase == .selection and event.full_sequence == self.select_sequence) {
        self.reset(owner);
        return true;
    }
    if (event.response_type == xcb.generic_event and self.canFence()) {
        const raw: *const xcb.RawButton = @ptrCast(event);
        if (raw.extension != self.opcode or (raw.event_type != xcb.press and raw.event_type != xcb.release)) return false;
        // Xwayland maps the first three evdev buttons explicitly and skips
        // X11's four wheel buttons when numbering the rest.
        const button = switch (raw.detail) {
            1 => @as(u32, 0x110),
            2 => @as(u32, 0x112),
            3 => @as(u32, 0x111),
            8...255 => 0x113 + raw.detail - 8,
            else => return true,
        };
        owner.pointerButtonDone(button, raw.event_type == xcb.press);
        return true;
    }
    if (event.response_type != (0x80 | xcb.client_message)) return false;
    const message: *const xcb.ClientMessage = @ptrCast(event);
    if (message.window != self.root or message.type != xcb.cardinal or
        message.format != 32 or !std.mem.eql(u32, &message.data.data32, &marker)) return false;
    if (self.canFence()) {
        owner.pointerFenceDone(event.full_sequence);
    } else if (event.full_sequence == self.setup_marker) {
        self.finishSetup(owner);
    }
    return true;
}

fn finishSetup(self: *Self, owner: *Xwayland) void {
    const conn = owner.wlr_xwayland.getXwmConnection() orelse return self.reset(owner);
    switch (self.phase) {
        .extension => {
            const extension = xcb.getExtension(conn, xcb.input_id);
            if (extension == null or extension.*.present == 0) return self.reset(owner);
            self.opcode = extension.*.major_opcode;
            // XI2.1 delivers raw events even while another X client has a grab.
            self.version = xcb.queryVersion(conn, 2, 1);
            const selection: extern struct { header: xcb.EventMask, bits: u32 } = .{
                .header = .{ .deviceid = xcb.all_master, .mask_len = 1 },
                .bits = xcb.raw_buttons,
            };
            self.select_sequence = xcb.selectEvents(conn, self.root, 1, &selection.header).sequence;
            self.phase = .selection;
            self.setup_marker = self.sendMarker(owner) orelse return self.reset(owner);
        },
        .selection => {
            const reply = xcb.versionReply(conn, self.version, null);
            if (reply == null) return self.reset(owner);
            defer std.c.free(reply);
            if (reply.*.major_version < 2 or (reply.*.major_version == 2 and reply.*.minor_version < 1))
                return self.reset(owner);
            self.phase = .ready;
        },
        else => unreachable,
    }
}
