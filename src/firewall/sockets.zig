//! Listening sockets in text form: Linux's `/proc/net/{tcp,udp}{,6}` tables
//! (read by `system_monitor/proc_linux_sockets.zig`, parsed here) and
//! FreeBSD's `sockstat -46lqn`. Pure parsers, tested on every system.
const std = @import("std");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;

pub const Socket = struct {
    proto: model.Proto,
    address: []const u8,
    port: u16,
    inode: u64 = 0,
    uid: u32 = 0,
    process: []const u8 = "",
    pid: i32 = 0,
};

fn hexAddress(a: Allocator, hex: []const u8) ![]const u8 {
    if (hex.len == 8) {
        const raw = try std.fmt.parseInt(u32, hex, 16);
        // The kernel prints the address as a host-order integer of its
        // network-order bytes.
        const bytes: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, raw));
        return std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    }
    if (hex.len == 32) {
        var bytes: [16]u8 = undefined;
        for (0..4) |i| {
            const word = try std.fmt.parseInt(u32, hex[i * 8 .. i * 8 + 8], 16);
            const le: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, word));
            @memcpy(bytes[i * 4 .. i * 4 + 4], &le);
        }
        if (std.mem.allEqual(u8, &bytes, 0)) return "::";
        if (std.mem.allEqual(u8, bytes[0..15], 0) and bytes[15] == 1) return "::1";
        if (std.mem.allEqual(u8, bytes[0..10], 0) and bytes[10] == 0xff and bytes[11] == 0xff)
            return std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}", .{ bytes[12], bytes[13], bytes[14], bytes[15] });
        var out: std.Io.Writer.Allocating = .init(a);
        for (0..8) |i| {
            const group = @as(u16, bytes[i * 2]) << 8 | bytes[i * 2 + 1];
            try out.writer.print("{s}{x}", .{ if (i == 0) "" else ":", group });
        }
        return out.toOwnedSlice();
    }
    return error.BadAddress;
}

/// One `/proc/net/*` table. TCP rows in LISTEN (0A) count; UDP rows bound to
/// a port with no remote end (state 07) count as listening.
pub fn parseProcNet(a: Allocator, text: []const u8, proto: model.Proto, out: *std.ArrayList(Socket)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        _ = it.next() orelse continue;
        const local = it.next() orelse continue;
        const remote = it.next() orelse continue;
        const state = it.next() orelse continue;
        _ = it.next();
        _ = it.next();
        _ = it.next();
        const uid_text = it.next() orelse continue;
        _ = it.next();
        const inode_text = it.next() orelse continue;
        const listening = if (proto == .tcp) std.mem.eql(u8, state, "0A") else std.mem.eql(u8, state, "07") and std.mem.endsWith(u8, remote, ":0000");
        if (!listening) continue;
        const colon = std.mem.indexOfScalar(u8, local, ':') orelse continue;
        const port = std.fmt.parseInt(u16, local[colon + 1 ..], 16) catch continue;
        if (port == 0) continue;
        const address = hexAddress(a, local[0..colon]) catch continue;
        try out.append(a, .{
            .proto = proto,
            .address = address,
            .port = port,
            .uid = std.fmt.parseInt(u32, uid_text, 10) catch 0,
            .inode = std.fmt.parseInt(u64, inode_text, 10) catch 0,
        });
    }
}

/// `sockstat -46lqn` (FreeBSD): USER COMMAND PID FD PROTO LOCAL FOREIGN.
/// With -n the user is numeric.
pub fn parseSockstat(a: Allocator, text: []const u8) ![]Socket {
    var list: std.ArrayList(Socket) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields: [8][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |field| {
            if (n == fields.len) break;
            fields[n] = field;
            n += 1;
        }
        if (n < 7) continue;
        if (std.mem.eql(u8, fields[0], "USER")) continue;
        const proto_text = fields[4];
        const proto: model.Proto = if (std.mem.startsWith(u8, proto_text, "tcp")) .tcp else if (std.mem.startsWith(u8, proto_text, "udp")) .udp else continue;
        const local = fields[5];
        const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
        const port = std.fmt.parseInt(u16, local[colon + 1 ..], 10) catch continue;
        var address = std.mem.trim(u8, local[0..colon], "[]");
        if (std.mem.eql(u8, address, "*")) address = if (std.mem.endsWith(u8, proto_text, "6")) "::" else "0.0.0.0";
        try list.append(a, .{
            .proto = proto,
            .address = try a.dupe(u8, address),
            .port = port,
            .uid = std.fmt.parseInt(u32, fields[0], 10) catch 0,
            .process = try a.dupe(u8, fields[1]),
            .pid = std.fmt.parseInt(i32, fields[2], 10) catch 0,
        });
    }
    return list.toOwnedSlice(a);
}

/// One row per (proto, port, address family): a daemon bound to both
/// 0.0.0.0 and :: shows once.
pub fn listeners(a: Allocator, sockets: []const Socket, status: model.Status) ![]model.Listener {
    var list: std.ArrayList(model.Listener) = .empty;
    outer: for (sockets) |s| {
        for (list.items) |existing| {
            if (existing.proto == s.proto and existing.port == s.port and std.mem.eql(u8, existing.process, s.process) and
                (std.mem.eql(u8, existing.address, s.address) or (wildcard(existing.address) and wildcard(s.address)))) continue :outer;
        }
        var l: model.Listener = .{ .proto = s.proto, .address = s.address, .port = s.port, .process = s.process, .pid = s.pid, .uid = s.uid };
        l.verdict = model.verdict(status, l);
        try list.append(a, l);
    }
    std.mem.sort(model.Listener, list.items, {}, struct {
        fn less(_: void, x: model.Listener, y: model.Listener) bool {
            if (x.verdict != y.verdict) return @backingInt(x.verdict) > @backingInt(y.verdict);
            return x.port < y.port;
        }
    }.less);
    return list.toOwnedSlice(a);
}

fn wildcard(address: []const u8) bool {
    return std.mem.eql(u8, address, "0.0.0.0") or std.mem.eql(u8, address, "::");
}

test "proc net tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tcp =
        \\  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        \\   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 23456 1 0000000000000000 100 0 0 10 0
        \\   1: 0100007F:0277 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 23457 1 0000000000000000 100 0 0 10 0
        \\   2: 0F02000A:D2A4 5E7C2B8E:01BB 01 00000000:00000000 02:000A7A0C 00000000  1000        0 99999 2 0000000000000000 20 4 30 10 -1
    ;
    var list: std.ArrayList(Socket) = .empty;
    try parseProcNet(a, tcp, .tcp, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("0.0.0.0", list.items[0].address);
    try std.testing.expectEqual(@as(u16, 22), list.items[0].port);
    try std.testing.expectEqualStrings("127.0.0.1", list.items[1].address);
    try std.testing.expectEqual(@as(u16, 631), list.items[1].port);
    const tcp6 =
        \\  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        \\   0: 00000000000000000000000000000000:0016 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 23458 1 0000000000000000 100 0 0 10 0
        \\   1: 00000000000000000000000001000000:0277 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 23459 1 0000000000000000 100 0 0 10 0
    ;
    try parseProcNet(a, tcp6, .tcp, &list);
    try std.testing.expectEqualStrings("::", list.items[2].address);
    try std.testing.expectEqualStrings("::1", list.items[3].address);
    const udp =
        \\   sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
        \\  100: 00000000:14E9 00000000:0000 07 00000000:00000000 00:00000000 00000000    95        0 31337 2 0000000000000000 0
    ;
    try parseProcNet(a, udp, .udp, &list);
    try std.testing.expectEqual(@as(u16, 5353), list.items[4].port);
    try std.testing.expectEqual(@as(u32, 95), list.items[4].uid);
}

test "sockstat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\0        sshd       812   4  tcp6   *:22                  *:*
        \\0        sshd       812   5  tcp4   *:22                  *:*
        \\0        cupsd      700   6  tcp4   127.0.0.1:631         *:*
        \\1001     syncthing  9001  12 udp46  *:21027               *:*
        \\0        ntpd       600   20 udp6   [fe80::1%em0]:123     *:*
    ;
    const sockets = try parseSockstat(a, text);
    try std.testing.expectEqual(@as(usize, 5), sockets.len);
    try std.testing.expectEqualStrings("::", sockets[0].address);
    try std.testing.expectEqualStrings("sshd", sockets[0].process);
    try std.testing.expectEqual(@as(i32, 812), sockets[0].pid);
    try std.testing.expectEqualStrings("127.0.0.1", sockets[2].address);
    try std.testing.expectEqual(@as(u32, 1001), sockets[3].uid);
    try std.testing.expectEqual(@as(u16, 123), sockets[4].port);
    const rows = try listeners(a, sockets, .{ .backend = .own, .running = true, .rules = &.{.{ .port = "22", .proto = .tcp }} });
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expectEqual(model.Verdict.everywhere, rows[0].verdict);
    try std.testing.expectEqual(@as(u16, 22), rows[0].port);
}
