//! Patch only the selected connector's mode, scale or position fields, then atomically replace
//! the config. Validate both versions so an invalid file is never overwritten.
const std = @import("std");
const Io = std.Io;
const loader = @import("loader.zig");
const theme = @import("ui").theme;
const output_transform = @import("output_transform.zig");

pub const Patch = @import("output_config.zig").Patch;

/// A validated file staged before the display commit; publish only after it succeeds.
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    temporary: []const u8,
    config: ?loader.Config,

    pub fn publish(self: Prepared) !void {
        try Io.Dir.rename(.cwd(), self.temporary, .cwd(), self.path, self.io);
    }

    pub fn deinit(self: *Prepared) void {
        if (self.config) |*config| config.deinit();
        Io.Dir.cwd().deleteFile(self.io, self.temporary) catch {};
        self.allocator.free(self.temporary);
    }
};

pub fn prepare(allocator: std.mem.Allocator, io: Io, path: []const u8, name: []const u8, patch: Patch, environ: std.process.Environ) !Prepared {
    try patch.validate();
    var fields_list: std.ArrayList(u8) = .empty;
    defer fields_list.deinit(allocator);
    inline for (.{ "width", "height", "refresh_mhz", "x", "y", "scale" }) |key| {
        if (@field(patch, key)) |value| {
            const line = try std.fmt.allocPrint(allocator, "{s} = {d}\n", .{ key, value });
            defer allocator.free(line);
            try fields_list.appendSlice(allocator, line);
        }
    }
    if (patch.transform) |value| {
        const line = try std.fmt.allocPrint(allocator, "transform = \"{s}\"\n", .{output_transform.name(value)});
        defer allocator.free(line);
        try fields_list.appendSlice(allocator, line);
    }
    if (patch.enabled) |value| try fields_list.appendSlice(allocator, if (value) "enabled = true\n" else "enabled = false\n");
    if (patch.primary) |value| try fields_list.appendSlice(allocator, if (value) "primary = true\n" else "primary = false\n");
    if (patch.auto_scale) try fields_list.appendSlice(allocator, "scale = \"auto\"\n");
    const fields = fields_list.items;
    if (path.len == 0) return error.NoConfigPath;
    // Connector names normally contain only letters, digits and hyphens.
    // This parser's strings do not decode escapes, so reject unsafe names.
    if (std.mem.indexOfAny(u8, name, "\"\\\r\n") != null) return error.InvalidOutputName;
    const original = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(original);
    var old = try loader.parse(allocator, original, path);
    defer old.deinit();
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var matched = false;
    var start: usize = 0;
    var offset: usize = 0;
    var output_block = false;
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |raw| {
        const line = theme.stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (std.mem.startsWith(u8, line, "[")) {
            try appendBlock(allocator, &result, original[start..offset], output_block, name, fields, patch, &matched);
            start = offset;
            output_block = std.mem.eql(u8, line, "[[outputs]]");
        }
        offset = @min(original.len, offset + raw.len + 1);
    }
    try appendBlock(allocator, &result, original[start..], output_block, name, fields, patch, &matched);
    if (!matched) {
        const header = try std.fmt.allocPrint(allocator, "\n[[outputs]]\nname = \"{s}\"\n", .{name});
        defer allocator.free(header);
        try result.appendSlice(allocator, header);
        try result.appendSlice(allocator, fields);
    }
    var checked = try loader.loadFromBytes(allocator, result.items, path, environ, io);
    errdefer checked.deinit();
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    const temporary = try std.fmt.allocPrint(allocator, "{s}.display-save.tmp", .{path});
    errdefer allocator.free(temporary);
    const file = try Io.Dir.cwd().createFile(io, temporary, .{ .exclusive = true, .permissions = stat.permissions });
    defer file.close(io);
    errdefer Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try file.writeStreamingAll(io, result.items);
    try file.sync(io);
    return .{ .allocator = allocator, .io = io, .path = path, .temporary = temporary, .config = checked };
}

fn appendBlock(allocator: std.mem.Allocator, result: *std.ArrayList(u8), block: []const u8, is_output: bool, name: []const u8, fields: []const u8, patch: Patch, matched: *bool) !void {
    var target = false;
    var lines = std.mem.splitScalar(u8, block, '\n');
    if (is_output) while (lines.next()) |raw| {
        const line = theme.stripComment(std.mem.trim(u8, raw, " \t\r"));
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\"");
        if (!std.mem.eql(u8, key, "name")) continue;
        const value = try theme.unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        target = std.mem.eql(u8, value, name);
    };
    if (!target) {
        // A primary preference is unique. Clear a previous preference in the
        // same file update before adding it to the selected block.
        if (is_output and patch.primary == true) {
            lines = std.mem.splitScalar(u8, block, '\n');
            var clear_offset: usize = 0;
            while (lines.next()) |raw| {
                const end = @min(block.len, clear_offset + raw.len + 1);
                const line = theme.stripComment(std.mem.trim(u8, raw, " \t\r"));
                const eq = std.mem.indexOfScalar(u8, line, '=');
                const key = if (eq) |i| std.mem.trim(u8, line[0..i], " \t\"") else "";
                if (std.mem.eql(u8, key, "primary")) {
                    if (std.mem.indexOfScalar(u8, raw, '#')) |comment| {
                        try result.appendSlice(allocator, raw[comment..]);
                        try result.append(allocator, '\n');
                    } else {
                        try result.appendSlice(allocator, "primary = false\n");
                    }
                } else {
                    try result.appendSlice(allocator, block[clear_offset..end]);
                }
                clear_offset = end;
            }
            return;
        }
        return result.appendSlice(allocator, block);
    }
    matched.* = true;
    lines = std.mem.splitScalar(u8, block, '\n');
    var offset: usize = 0;
    while (lines.next()) |raw| {
        const end = @min(block.len, offset + raw.len + 1);
        const line = theme.stripComment(std.mem.trim(u8, raw, " \t\r"));
        const eq = std.mem.indexOfScalar(u8, line, '=');
        const key = if (eq) |i| std.mem.trim(u8, line[0..i], " \t\"") else "";
        const replaced = blk: {
            inline for (.{ "width", "height", "refresh_mhz", "x", "y", "scale" }) |field| {
                if (std.mem.eql(u8, key, field) and @field(patch, field) != null) break :blk true;
            }
            if (patch.transform != null and std.mem.eql(u8, key, "transform")) break :blk true;
            if (patch.auto_scale and std.mem.eql(u8, key, "scale")) break :blk true;
            if (patch.auto_position and (std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "y"))) break :blk true;
            if (patch.enabled != null and std.mem.eql(u8, key, "enabled")) break :blk true;
            if (patch.primary != null and std.mem.eql(u8, key, "primary")) break :blk true;
            break :blk false;
        };
        if (!replaced) {
            try result.appendSlice(allocator, block[offset..end]);
        } else if (std.mem.indexOfScalar(u8, raw, '#')) |comment| {
            try result.appendSlice(allocator, raw[comment..]);
            try result.append(allocator, '\n');
        }
        offset = end;
    }
    if (result.items.len > 0 and result.items[result.items.len - 1] != '\n') try result.append(allocator, '\n');
    try result.appendSlice(allocator, fields);
}
