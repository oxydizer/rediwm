const std = @import("std");
pub fn decode(a: std.mem.Allocator, bytes: []const u8, label: []const u8) ![]u8 {
    const begin = try std.fmt.allocPrint(a, "-----BEGIN {s}-----", .{label});
    defer a.free(begin);
    const end = try std.fmt.allocPrint(a, "-----END {s}-----", .{label});
    defer a.free(end);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, begin)) return error.InvalidArmor;
    const stop = std.mem.indexOf(u8, trimmed, end) orelse return error.InvalidArmor;
    if (std.mem.trim(u8, trimmed[stop + end.len ..], " \t\r\n").len != 0) return error.InvalidArmor;
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(a);
    for (trimmed[begin.len..stop]) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        try encoded.append(a, ch);
    }
    const decoder = std.base64.standard.Decoder;
    const out = try a.alloc(u8, try decoder.calcSizeForSlice(encoded.items));
    errdefer a.free(out);
    try decoder.decode(out, encoded.items);
    return out;
}
