// wlroots 0.20 does not expose or validate the cursor-shape enter serial.
// Observe actual outgoing enters: focus-change alone misses wl_seat.get_pointer
// while already focused, which sends a fresh enter without changing focus.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const CursorSerial = @This();

seat: *wlr.Seat = undefined,
logger: *wl.ProtocolLogger = undefined,
enter_serial: ?u32 = null,

// zig-wayland 0.6's addProtocolLogger wrapper discards the returned handle.
// Keep it here so allocation failure and teardown are both handled.
extern fn wl_display_add_protocol_logger(
    display: *wl.Server,
    callback: *const fn (?*anyopaque, wl.ProtocolLogger.Type, *const wl.ProtocolLogger.LogMessage) callconv(.c) void,
    data: ?*anyopaque,
) ?*wl.ProtocolLogger;

pub fn init(tracker: *CursorSerial, display: *wl.Server, seat: *wlr.Seat) !void {
    tracker.seat = seat;
    tracker.logger = wl_display_add_protocol_logger(display, observe, tracker) orelse return error.OutOfMemory;
}

pub fn deinit(tracker: *CursorSerial) void {
    tracker.logger.destroy();
}

fn observe(data: ?*anyopaque, direction: wl.ProtocolLogger.Type, message: *const wl.ProtocolLogger.LogMessage) callconv(.c) void {
    if (direction != .event or message.message_opcode > 1) return;
    if (!std.mem.eql(u8, std.mem.span(message.resource.getClass()), "wl_pointer")) return;
    const tracker: *CursorSerial = @ptrCast(@alignCast(data));
    const client = wlr.Seat.Client.fromWlPointer(@ptrCast(message.resource)) orelse return;
    if (client.seat != tracker.seat) return;
    // wl_pointer.enter is opcode 0; leave is opcode 1. No messages are logged.
    tracker.enter_serial = if (message.message_opcode == 0) message.arguments.?[0].u else null;
}
