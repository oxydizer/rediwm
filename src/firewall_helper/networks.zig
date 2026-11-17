//! Networks and their trust. With NetworkManager a network is an active
//! connection and its trust is the connection's zone (`connection.zone`,
//! which firewalld follows natively and our dispatcher reads for our table).
//! Without it, a network is an interface and its trust is in our state.
const std = @import("std");
const builtin = @import("builtin");
const fw = @import("firewall");
const model = fw.model;
const run = @import("run.zig");
const Ctx = run.Ctx;

const Active = struct { name: []const u8, uuid: []const u8, device: []const u8, kind: []const u8 };

/// Splits one `nmcli -t` line, honouring `\:` and `\\` escapes.
fn terse(a: std.mem.Allocator, line: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var field: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (ch == '\\' and i + 1 < line.len) {
            i += 1;
            field.append(a, line[i]) catch return n;
        } else if (ch == ':') {
            if (n == out.len) return n;
            out[n] = field.toOwnedSlice(a) catch "";
            n += 1;
        } else field.append(a, ch) catch return n;
    }
    if (n < out.len) {
        out[n] = field.toOwnedSlice(a) catch "";
        n += 1;
    }
    return n;
}

fn active(ctx: Ctx) ?[]Active {
    const result = run.tryTool(ctx, "nmcli", &.{ "-t", "-f", "NAME,UUID,DEVICE,TYPE", "connection", "show", "--active" }) orelse return null;
    if (!result.ok) return null;
    var list: std.ArrayList(Active) = .empty;
    var lines = std.mem.splitScalar(u8, result.out, '\n');
    while (lines.next()) |line| {
        var fields: [4][]const u8 = undefined;
        if (terse(ctx.a, line, &fields) != 4) continue;
        if (std.mem.eql(u8, fields[3], "loopback") or !fw.validate.uuid(fields[1])) continue;
        list.append(ctx.a, .{ .name = fields[0], .uuid = fields[1], .device = fields[2], .kind = fields[3] }) catch continue;
    }
    return list.items;
}

fn zoneTrust(ctx: Ctx, uuid: []const u8) model.Trust {
    const result = run.tryTool(ctx, "nmcli", &.{ "-g", "connection.zone", "connection", "show", "uuid", uuid }) orelse return .public;
    const zone = std.mem.trim(u8, result.out, " \n");
    return if (std.mem.eql(u8, zone, "home") or std.mem.eql(u8, zone, "trusted") or std.mem.eql(u8, zone, "internal") or std.mem.eql(u8, zone, "work")) .home else .public;
}

fn interfaces(ctx: Ctx) []const []const u8 {
    if (builtin.os.tag == .freebsd) {
        const result = run.tryTool(ctx, "ifconfig", &.{"-l"}) orelse return &.{};
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, result.out, " \n");
        while (it.next()) |name| {
            if (std.mem.startsWith(u8, name, "lo") or std.mem.startsWith(u8, name, "pflog") or std.mem.startsWith(u8, name, "enc") or std.mem.startsWith(u8, name, "pfsync")) continue;
            list.append(ctx.a, name) catch continue;
        }
        return list.items;
    }
    var list: std.ArrayList([]const u8) = .empty;
    for (run.list(ctx, "/sys/class/net")) |name| {
        if (std.mem.eql(u8, name, "lo") or !fw.validate.iface(name)) continue;
        list.append(ctx.a, name) catch continue;
    }
    return list.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

/// The networks the page lists. `home_ifaces` is our state's per-interface
/// trust, used where there is no NetworkManager.
pub fn networks(ctx: Ctx, home_ifaces: []const []const u8) ![]const model.Network {
    var out: std.ArrayList(model.Network) = .empty;
    if (active(ctx)) |connections| {
        for (connections) |conn| try out.append(ctx.a, .{ .name = conn.name, .iface = conn.device, .uuid = conn.uuid, .trust = zoneTrust(ctx, conn.uuid), .active = true });
        return out.items;
    }
    for (interfaces(ctx)) |name| try out.append(ctx.a, .{ .name = name, .iface = name, .trust = if (contains(home_ifaces, name)) .home else .public, .active = true });
    return out.items;
}

/// Interfaces of the active connections trusted as home; null without
/// NetworkManager (the caller then uses its saved per-interface trust).
pub fn homeIfaces(ctx: Ctx) ?[]const []const u8 {
    const connections = active(ctx) orelse return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (connections) |conn| {
        if (conn.device.len == 0 or !fw.validate.iface(conn.device)) continue;
        if (zoneTrust(ctx, conn.uuid) == .home) out.append(ctx.a, conn.device) catch continue;
    }
    return out.items;
}

/// Sets a connection's zone and reapplies it, so firewalld (or our
/// dispatcher) sees the change now rather than at the next connection.
pub fn setTrust(ctx: Ctx, uuid: []const u8, trust: model.Trust) !void {
    if (!fw.validate.uuid(uuid)) return error.InvalidRequest;
    try run.must(ctx, "nmcli", &.{ "connection", "modify", "uuid", uuid, "connection.zone", if (trust == .home) "home" else "public" });
    if (active(ctx)) |connections| for (connections) |conn| {
        if (std.mem.eql(u8, conn.uuid, uuid) and conn.device.len != 0 and fw.validate.iface(conn.device)) {
            run.must(ctx, "nmcli", &.{ "device", "reapply", conn.device }) catch {};
        }
    };
}
