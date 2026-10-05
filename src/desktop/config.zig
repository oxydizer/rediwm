const std = @import("std");
const grid = @import("grid.zig");
pub const Position = struct { path: []const u8, cell: grid.Cell };
// JSON quoted strings are a compatible subset of TOML basic strings.
pub fn encode(a: std.mem.Allocator, positions: []const Position) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    for (positions) |p| {
        try out.writer.writeAll("[[icons]]\npath = ");
        try std.json.Stringify.value(p.path, .{}, &out.writer);
        try out.writer.print("\ncell_col = {d}\ncell_row = {d}\n\n", .{ p.cell.col, p.cell.row });
    }
    return out.toOwnedSlice();
}
pub fn lookup(a: std.mem.Allocator, data: []const u8, path: []const u8) ?grid.Cell {
    var lines = std.mem.splitScalar(u8, data, '\n');
    var matching = false;
    var cell = grid.Cell{};
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "[[icons]]")) {
            if (matching) return cell;
            matching = false;
            cell = .{};
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "path")) {
            const parsed = std.json.parseFromSlice([]const u8, a, value, .{}) catch continue;
            defer parsed.deinit();
            matching = std.mem.eql(u8, parsed.value, path);
        } else if (std.mem.eql(u8, key, "cell_col")) {
            cell.col = std.fmt.parseInt(i32, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "cell_row")) {
            cell.row = std.fmt.parseInt(i32, value, 10) catch 0;
        }
    }
    return if (matching) cell else null;
}
test "layout preserves quotes and unicode paths" {
    const a = std.testing.allocator;
    const encoded = try encode(a, &.{.{ .path = "/Desktop/\"café\"", .cell = .{ .col = 2, .row = 3 } }});
    defer a.free(encoded);
    try std.testing.expectEqual(grid.Cell{ .col = 2, .row = 3 }, lookup(a, encoded, "/Desktop/\"café\"").?);
}
