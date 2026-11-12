//! Native user-manager transport. The Linux implementation uses Redinit's
//! exported client module verbatim; other platforms retain their usual backend.
const std = @import("std");
const builtin = @import("builtin");
const client = if (builtin.os.tag == .linux) @import("redi_ctl") else struct {};

pub fn path(allocator: std.mem.Allocator, runtime: []const u8) !?[:0]u8 {
    if (builtin.os.tag != .linux) return null;
    if (!std.fs.path.isAbsolute(runtime)) return null;
    const result = try std.fmt.allocPrintSentinel(allocator, "{s}/redinit/ctl", .{runtime}, 0);
    if (std.c.access(result, std.posix.F_OK) != 0) {
        allocator.free(result);
        return null;
    }
    return result;
}
pub fn fromBusAddress(allocator: std.mem.Allocator, address: []const u8) !?[:0]u8 {
    const prefix = "unix:path=";
    if (!std.mem.startsWith(u8, address, prefix) or !std.mem.endsWith(u8, address, "/bus")) return null;
    return path(allocator, address[prefix.len .. address.len - 4]);
}
pub fn adopt(socket: []const u8, name: []const u8, pid: i32) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var conn = try client.Connection.connectTimeout(socket, 1000);
    defer conn.close();
    const a = std.heap.c_allocator;
    const reply = try client.adopt(&conn, a, name, pid);
    defer a.free(reply.message);
    if (!reply.ok) return error.AdoptionRefused;
}
pub fn environment(socket: []const u8, allocator: std.mem.Allocator) ![][]u8 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var conn = try client.Connection.connectTimeout(socket, 1000);
    defer conn.close();
    return client.environment(&conn, allocator);
}
pub fn changeEnvironment(socket: []const u8, allocator: std.mem.Allocator, set: bool, entries: []const []const u8) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var conn = try client.Connection.connectTimeout(socket, 1000);
    defer conn.close();
    const reply = try client.changeEnvironment(&conn, allocator, set, entries);
    defer allocator.free(reply.message);
    if (!reply.ok) return error.EnvironmentRefused;
}
