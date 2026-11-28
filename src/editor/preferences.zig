//! Editor-specific preferences, kept separate from compositor configuration.
const std = @import("std");
const c = @import("../files/c.zig").api;

pub const Preferences = struct {
    line_numbers: bool = false,

    pub fn path(a: std.mem.Allocator, env: std.process.Environ) ![]u8 {
        if (env.getPosix("XDG_STATE_HOME")) |base| {
            if (std.fs.path.isAbsolute(base)) return std.fs.path.join(a, &.{ base, "rediwm", "editor" });
        }
        const home = env.getPosix("HOME") orelse return error.NoHome;
        return std.fs.path.join(a, &.{ home, ".local/state/rediwm/editor" });
    }

    pub fn load(a: std.mem.Allocator, io: std.Io, file: []const u8) Preferences {
        const data = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(16)) catch return .{};
        defer a.free(data);
        if (data.len != 3 or data[0] != '1' or data[1] > 1 or data[2] != '\n') return .{};
        return .{ .line_numbers = data[1] == 1 };
    }

    pub fn save(self: Preferences, a: std.mem.Allocator, io: std.Io, file: []const u8) !void {
        if (std.fs.path.dirname(file)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        const temporary = try std.fmt.allocPrint(a, "{s}.{d}.tmp", .{ file, c.getpid() });
        defer a.free(temporary);
        defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        const data = [_]u8{ '1', @intFromBool(self.line_numbers), '\n' };
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = &data });
        try std.Io.Dir.rename(.cwd(), temporary, .cwd(), file, io);
    }
};
