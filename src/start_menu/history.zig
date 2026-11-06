//! Bounded launcher history: pinned IDs first, then most recently launched.
//! Stored independently of the catalogue so refreshes never retain app pointers.
const std = @import("std");
const Server = @import("../Server.zig");
const gpa = @import("../main.zig").gpa;

pub const History = struct {
    const Entry = struct {
        bytes: [512]u8 = undefined,
        len: usize = 0,
        pinned: bool = false,
        fn id(e: *const Entry) []const u8 {
            return e.bytes[0..e.len];
        }
    };
    entries: [32]Entry = undefined,
    len: usize = 0,
    loaded: bool = false,

    pub fn load(h: *History, server: *Server) void {
        if (h.loaded or server.greeter_mode) return;
        h.loaded = true;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const dir = (@import("../window_sizes.zig").resolveStateDir(a, server.environ) catch return) orelse return;
        const path = std.fmt.allocPrint(a, "{s}/launcher", .{dir}) catch return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(server.io, path, a, .limited(32 * 515)) catch return;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len < 3 or line[1] != '\t' or (line[0] != 'P' and line[0] != 'R')) continue;
            const app_id = line[2..];
            if (!valid(app_id) or h.index(app_id) != null or h.len == h.entries.len) continue;
            var entry: Entry = .{ .len = app_id.len, .pinned = line[0] == 'P' };
            @memcpy(entry.bytes[0..app_id.len], app_id);
            h.entries[h.len] = entry;
            h.len += 1;
        }
    }

    fn valid(app_id: []const u8) bool {
        return app_id.len > 0 and app_id.len <= 512 and std.mem.indexOfAny(u8, app_id, "\n\r\t\x00") == null;
    }

    fn index(h: *const History, app_id: []const u8) ?usize {
        for (h.entries[0..h.len], 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.id(), app_id)) return i;
        }
        return null;
    }

    pub fn pinned(h: *const History, app_id: []const u8) bool {
        return if (h.index(app_id)) |i| h.entries[i].pinned else false;
    }

    /// Move matching pins first, retaining relevance order within both groups.
    pub fn prioritize(h: *const History, results: []@import("search.zig").SearchResult) void {
        var next: usize = 0;
        for (0..results.len) |i| {
            const result = results[i];
            if (result.app_entry == null or !h.pinned(result.id)) continue;
            std.mem.copyBackwards(@import("search.zig").SearchResult, results[next + 1 .. i + 1], results[next..i]);
            results[next] = result;
            next += 1;
        }
    }

    fn remember(h: *History, app_id: []const u8) void {
        if (!valid(app_id)) return;
        const pin = h.pinned(app_id);
        const at = h.index(app_id) orelse blk: {
            if (h.len < h.entries.len) {
                h.len += 1;
                break :blk h.len - 1;
            }
            // Never evict a pin to make room for a launch.
            var i = h.len;
            while (i > 0) {
                i -= 1;
                if (!h.entries[i].pinned) break :blk i;
            }
            return;
        };
        std.mem.copyBackwards(Entry, h.entries[1 .. at + 1], h.entries[0..at]);
        h.entries[0] = .{ .len = app_id.len, .pinned = pin };
        @memcpy(h.entries[0].bytes[0..app_id.len], app_id);
    }

    pub fn launched(h: *History, server: *Server, app_id: []const u8) void {
        if (server.greeter_mode) return;
        h.load(server);
        h.remember(app_id);
        h.save(server);
    }

    pub fn pinCount(h: *const History) usize {
        var count: usize = 0;
        for (h.entries[0..h.len]) |entry| {
            if (entry.pinned) count += 1;
        }
        return count;
    }

    pub fn togglePin(h: *History, server: *Server, app_id: []const u8) void {
        if (server.greeter_mode or !valid(app_id)) return;
        h.load(server);
        if (!h.pinned(app_id) and h.pinCount() >= 5) return;
        if (h.index(app_id) == null) h.remember(app_id);
        const i = h.index(app_id) orelse return;
        h.entries[i].pinned = !h.entries[i].pinned;
        h.save(server);
    }

    /// Resolve against current results; removed/hidden apps are never offered.
    pub fn cards(h: *const History, results: anytype, out: []usize) usize {
        var count: usize = 0;
        for ([_]bool{ true, false }) |pin| {
            for (h.entries[0..h.len]) |*entry| {
                if (entry.pinned != pin) continue;
                for (results, 0..) |result, i| {
                    if (result.app_entry != null and std.mem.eql(u8, result.id, entry.id())) {
                        if (count == out.len) return count;
                        out[count] = i;
                        count += 1;
                        break;
                    }
                }
            }
        }
        return count;
    }

    fn save(h: *const History, server: *Server) void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const dir = (@import("../window_sizes.zig").resolveStateDir(a, server.environ) catch return) orelse return;
        std.Io.Dir.cwd().createDirPath(server.io, dir) catch return;
        const path = std.fmt.allocPrint(a, "{s}/launcher", .{dir}) catch return;
        const tmp = std.fmt.allocPrint(a, "{s}.tmp", .{path}) catch return;
        var bytes: std.ArrayList(u8) = .empty;
        for (h.entries[0..h.len]) |*entry| {
            bytes.appendSlice(a, if (entry.pinned) "P\t" else "R\t") catch return;
            bytes.appendSlice(a, entry.id()) catch return;
            bytes.append(a, '\n') catch return;
        }
        const file = std.Io.Dir.cwd().createFile(server.io, tmp, .{ .truncate = true }) catch return;
        defer std.Io.Dir.cwd().deleteFile(server.io, tmp) catch {};
        file.writeStreamingAll(server.io, bytes.items) catch {
            file.close(server.io);
            return;
        };
        file.close(server.io);
        std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, server.io) catch {};
    }
};

test "launcher history deduplicates launches and preserves pins when full" {
    var history: History = .{};
    history.remember("pinned.desktop");
    history.entries[0].pinned = true;
    var buf: [32]u8 = undefined;
    for (0..40) |i| history.remember(try std.fmt.bufPrint(&buf, "app-{d}.desktop", .{i}));
    try std.testing.expectEqual(@as(usize, 32), history.len);
    try std.testing.expect(history.pinned("pinned.desktop"));
    history.remember("app-39.desktop");
    try std.testing.expectEqual(@as(usize, 32), history.len);
    try std.testing.expectEqualStrings("app-39.desktop", history.entries[0].id());
}
