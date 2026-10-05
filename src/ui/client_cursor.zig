//! Let the compositor resolve cursors from its current theme and output scale.
const std = @import("std");
const wl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const Self = @This();

manager: ?*wp.CursorShapeManagerV1 = null,
device: ?*wp.CursorShapeDeviceV1 = null,

pub fn bind(self: *Self, registry: *wl.Registry, name: u32, interface: []const u8, version: u32) void {
    if (std.mem.eql(u8, interface, "wp_cursor_shape_manager_v1") and self.manager == null) {
        self.manager = registry.bind(name, wp.CursorShapeManagerV1, @min(version, 1)) catch null;
    }
}

pub fn clearPointer(self: *Self) void {
    if (self.device) |device| device.destroy();
    self.device = null;
}

pub fn deinit(self: *Self) void {
    self.clearPointer();
    if (self.manager) |manager| manager.destroy();
    self.manager = null;
}

pub fn set(self: *Self, pointer: *wl.Pointer, serial: u32, name: []const u8) bool {
    const manager = self.manager orelse return false;
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return false;
    for (name, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
    const shape = std.meta.stringToEnum(wp.CursorShapeDeviceV1.Shape, buf[0..name.len]) orelse return false;
    if (self.device == null) self.device = manager.getPointer(pointer) catch return false;
    self.device.?.setShape(serial, shape);
    return true;
}

/// Older compositors use client surfaces; honour the session's theme and size.
pub fn loadFallback(shm: *wl.Shm) ?*wl.CursorTheme {
    const size = if (std.c.getenv("XCURSOR_SIZE")) |value|
        std.fmt.parseInt(u32, std.mem.span(value), 10) catch 24
    else
        24;
    return wl.CursorTheme.load(std.c.getenv("XCURSOR_THEME"), @intCast(std.math.clamp(size, 1, 256)), shm) catch null;
}
