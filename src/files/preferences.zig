//! Files-specific preferences, kept separate from compositor configuration.
const std = @import("std");

pub const Preferences = struct {
    list: bool = false,
    sort: u8 = 0,
    unpinned_places: u8 = 0,
    /// Git status, branches and the changed-files list inside repositories.
    git_view: bool = true,

    pub fn path(a: std.mem.Allocator, env: std.process.Environ) ![]u8 {
        if (env.getPosix("XDG_STATE_HOME")) |base| {
            if (std.fs.path.isAbsolute(base)) return std.fs.path.join(a, &.{ base, "rediwm", "files-view" });
        }
        const home = env.getPosix("HOME") orelse return error.NoHome;
        return std.fs.path.join(a, &.{ home, ".local/state/rediwm/files-view" });
    }
    pub fn load(a: std.mem.Allocator, io: std.Io, file: []const u8) Preferences {
        const data = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(128)) catch return .{};
        defer a.free(data);
        const legacy = data.len == 4 and data[0] == '1';
        const places = data.len == 5 and data[0] == '2';
        const current = data.len == 6 and data[0] == '3';
        if ((!legacy and !places and !current) or data[1] > 1 or data[2] > 7 or data[data.len - 1] != '\n') return .{};
        if ((places or current) and data[3] > 0x7f) return .{};
        if (current and data[4] > 1) return .{};
        return .{
            .list = data[1] == 1,
            .sort = data[2],
            .unpinned_places = if (places or current) data[3] else 0,
            .git_view = if (current) data[4] == 1 else true,
        };
    }
    pub fn save(self: Preferences, a: std.mem.Allocator, io: std.Io, file: []const u8) !void {
        if (std.fs.path.dirname(file)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        const temporary = try std.fmt.allocPrint(a, "{s}.{d}.tmp", .{ file, @import("c.zig").api.getpid() });
        defer a.free(temporary);
        defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        const data = [_]u8{ '3', @intFromBool(self.list), self.sort, self.unpinned_places, @intFromBool(self.git_view), '\n' };
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = &data });
        try std.Io.Dir.rename(.cwd(), temporary, .cwd(), file, io);
    }
};
