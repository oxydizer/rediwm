//! Recent blocked connections, from the kernel log lines our table, ufw and
//! firewalld write (Linux, via `journalctl -k`) or from pflog (FreeBSD, via
//! `tcpdump -r`). Shown on request only; nothing follows the log.
const std = @import("std");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;

pub const max_blocks = 100;

/// The `-g` pattern for journalctl: our prefix, ufw's and firewalld's.
pub const journal_pattern = "rediwm-drop|UFW BLOCK|UFW LIMIT BLOCK|_REJECT: |_DROP: |FINAL_REJECT";

fn field(line: []const u8, key: []const u8) []const u8 {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, key)) |i| {
        if (i == 0 or line[i - 1] == ' ') {
            const begin = i + key.len;
            const end = std.mem.indexOfScalarPos(u8, line, begin, ' ') orelse line.len;
            return line[begin..end];
        }
        start = i + key.len;
    }
    return "";
}

/// One `journalctl -k -o short-iso` line: "2026-11-17T10:00:00+0100 host
/// kernel: rediwm-drop IN=wlan0 OUT= … SRC=… DST=… PROTO=TCP SPT=… DPT=22".
pub fn parseKernel(line: []const u8) ?model.Block {
    const time_end = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const in = field(line, "IN=");
    const out = field(line, "OUT=");
    const src = field(line, "SRC=");
    if (src.len == 0) return null;
    return .{
        .time = line[0..time_end],
        .direction = if (in.len == 0 and out.len != 0) .out else .in,
        .proto = field(line, "PROTO="),
        .source = if (in.len == 0 and out.len != 0) field(line, "DST=") else src,
        .port = std.fmt.parseInt(u16, field(line, "DPT="), 10) catch 0,
        .iface = if (in.len != 0) in else out,
    };
}

fn splitHostPort(text: []const u8) struct { host: []const u8, port: u16 } {
    const trimmed = std.mem.trimEnd(u8, text, ":,");
    const dot = std.mem.lastIndexOfScalar(u8, trimmed, '.') orelse return .{ .host = trimmed, .port = 0 };
    const port = std.fmt.parseInt(u16, trimmed[dot + 1 ..], 10) catch return .{ .host = trimmed, .port = 0 };
    return .{ .host = trimmed[0..dot], .port = port };
}

/// One `tcpdump -n -e -tttt -r /var/log/pflog` line: "2026-11-17
/// 10:00:00.123456 rule 3/0(match): block in on em0: 192.0.2.5.51234 >
/// 192.0.2.10.22: Flags [S], …".
pub fn parsePflog(line: []const u8) ?model.Block {
    const marker = std.mem.indexOf(u8, line, "(match): block ") orelse return null;
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const second_space = std.mem.indexOfScalarPos(u8, line, first_space + 1, ' ') orelse return null;
    var rest = line[marker + "(match): block ".len ..];
    const out = std.mem.startsWith(u8, rest, "out");
    const on = std.mem.indexOf(u8, rest, " on ") orelse return null;
    const iface_end = std.mem.indexOfScalarPos(u8, rest, on + 4, ':') orelse return null;
    const iface = rest[on + 4 .. iface_end];
    rest = std.mem.trimStart(u8, rest[iface_end + 1 ..], " ");
    const gt = std.mem.indexOf(u8, rest, " > ") orelse return null;
    const src = splitHostPort(rest[0..gt]);
    const dst_end = std.mem.indexOfScalarPos(u8, rest, gt + 3, ' ') orelse rest.len;
    const dst = splitHostPort(rest[gt + 3 .. dst_end]);
    const tail = rest[dst_end..];
    const proto: []const u8 = if (std.mem.indexOf(u8, tail, "Flags [") != null) "TCP" else if (std.mem.indexOf(u8, tail, "UDP") != null) "UDP" else if (std.mem.indexOf(u8, tail, "ICMP") != null) "ICMP" else "";
    return .{
        .time = line[0..second_space],
        .direction = if (out) .out else .in,
        .proto = proto,
        .source = if (out) dst.host else src.host,
        .port = dst.port,
        .iface = iface,
    };
}

/// The newest `max_blocks` blocks, newest first.
pub fn parse(a: Allocator, text: []const u8, pflog: bool) ![]model.Block {
    var list: std.ArrayList(model.Block) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const block = (if (pflog) parsePflog(line) else parseKernel(line)) orelse continue;
        try list.append(a, block);
    }
    std.mem.reverse(model.Block, list.items);
    if (list.items.len > max_blocks) list.shrinkRetainingCapacity(max_blocks);
    return list.toOwnedSlice(a);
}

test "kernel log" {
    const b = parseKernel("2026-11-17T10:00:00+0100 laptop kernel: rediwm-drop IN=wlan0 OUT= MAC=aa:bb SRC=192.0.2.5 DST=192.0.2.10 LEN=60 TOS=0x00 PROTO=TCP SPT=51234 DPT=22 WINDOW=64240 SYN").?;
    try std.testing.expectEqualStrings("192.0.2.5", b.source);
    try std.testing.expectEqual(@as(u16, 22), b.port);
    try std.testing.expectEqualStrings("wlan0", b.iface);
    try std.testing.expectEqualStrings("TCP", b.proto);
    try std.testing.expectEqual(model.Direction.in, b.direction);
    const ufw = parseKernel("2026-11-17T10:00:01+0100 laptop kernel: [UFW BLOCK] IN=eth0 OUT= SRC=198.51.100.7 DST=192.0.2.10 PROTO=UDP SPT=5353 DPT=5353").?;
    try std.testing.expectEqual(@as(u16, 5353), ufw.port);
    try std.testing.expect(parseKernel("2026-11-17T10:00:01+0100 laptop kernel: usb 1-1: new device") == null);
}

test "pflog" {
    const b = parsePflog("2026-11-17 10:00:00.123456 rule 3/0(match): block in on em0: 192.0.2.5.51234 > 192.0.2.10.22: Flags [S], seq 1, win 65535").?;
    try std.testing.expectEqualStrings("192.0.2.5", b.source);
    try std.testing.expectEqual(@as(u16, 22), b.port);
    try std.testing.expectEqualStrings("em0", b.iface);
    try std.testing.expectEqualStrings("TCP", b.proto);
    try std.testing.expectEqualStrings("2026-11-17 10:00:00.123456", b.time);
}
