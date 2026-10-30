//! Optional firmware charge limit. Uses existing user permissions; never elevates.
const std = @import("std");
const Io = std.Io;
pub const State = struct {
    supported: bool = false,
    writable: bool = false,
    percent: ?u32 = null,
};

fn percentage(dir: Io.Dir, io: Io, path: []const u8) ?u32 {
    var buf: [32]u8 = undefined;
    const bytes = dir.readFile(io, path, &buf) catch return null;
    const number = std.fmt.parseInt(u32, std.mem.trim(u8, bytes, " \r\n"), 10) catch return null;
    return if (number <= 100) number else null;
}

pub fn read(io: Io) State {
    return visit(io, null) catch .{};
}

pub fn set(io: Io, percent: u32) !State {
    if (percent < 50 or percent > 100) return error.InvalidValue;
    return visit(io, percent);
}

fn visit(io: Io, desired: ?u32) !State {
    var dir = try Io.Dir.cwd().openDir(io, "/sys/class/power_supply", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var state: State = .{};
    var first = true;
    while (try it.next(io)) |entry| {
        if (entry.name.len > 128 or std.mem.indexOfScalar(u8, entry.name, '/') != null) continue;
        var sub = dir.openDir(io, entry.name, .{}) catch continue;
        defer sub.close(io);
        var buf: [32]u8 = undefined;
        const kind = sub.readFile(io, "type", &buf) catch continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, kind, "\r\n"), "Battery")) continue;
        if (sub.readFile(io, "scope", &buf)) |scope| {
            if (std.mem.eql(u8, std.mem.trim(u8, scope, "\r\n"), "Device")) continue;
        } else |_| {}
        if (percentage(sub, io, "present") == 0) continue;
        var actual = percentage(sub, io, "charge_control_end_threshold") orelse continue;
        state.supported = true;
        const writer = sub.openFile(io, "charge_control_end_threshold", .{ .mode = .write_only }) catch |err| {
            if (desired != null) return err;
            state.writable = false;
            state.percent = if (first or state.percent == actual) actual else null;
            first = false;
            continue;
        };
        defer writer.close(io);
        if (first) state.writable = true;
        if (desired) |percent| {
            if (percentage(sub, io, "charge_control_start_threshold")) |start| if (start >= percent) return error.StartThresholdTooHigh;
            if (percent != actual) {
                const text = try std.fmt.bufPrint(&buf, "{d}\n", .{percent});
                try writer.writeStreamingAll(io, text);
                actual = percentage(sub, io, "charge_control_end_threshold") orelse return error.ReadbackFailed;
            }
        }
        state.percent = if (first or state.percent == actual) actual else null;
        first = false;
    }
    if (desired != null and !state.supported) return error.Unsupported;
    return state;
}
