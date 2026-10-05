//! URI-list transfer parsing. The worker owns received pipes and filesystem mutations.
const std = @import("std");
pub fn localPath(a: std.mem.Allocator, uri: []const u8) ![]const u8 {
    var raw = uri;
    if (std.mem.startsWith(u8, raw, "file://localhost/")) raw = raw[16..] else if (std.mem.startsWith(u8, raw, "file:///")) raw = raw[7..] else return error.NotLocalFile;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var ch = raw[i];
        if (ch == '%') {
            if (i + 2 >= raw.len) return error.InvalidEscape;
            ch = try std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16);
            i += 2;
        }
        if (ch == 0) return error.InvalidPath;
        try result.append(a, ch);
    }
    return result.toOwnedSlice(a);
}
test "URI list decoding accepts only local absolute paths" {
    const a = std.testing.allocator;
    const p = try localPath(a, "file:///tmp/a%20b%23c");
    defer a.free(p);
    try std.testing.expectEqualStrings("/tmp/a b#c", p);
    try std.testing.expectError(error.NotLocalFile, localPath(a, "file://remote/tmp/a"));
    try std.testing.expectError(error.InvalidPath, localPath(a, "file:///tmp/%00"));
}

pub fn uriList(a: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const hex = "0123456789ABCDEF";
    for (paths) |path| {
        try out.appendSlice(a, "file://");
        for (path) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~') try out.append(a, ch) else try out.appendSlice(a, &.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
        try out.appendSlice(a, "\r\n");
    }
    return out.toOwnedSlice(a);
}
