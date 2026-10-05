//! Remembered window dimensions per desktop ID.
//!
//! Stores settled window geometry in `$XDG_STATE_HOME/rediwm/window_sizes` so
//! future launches of the same application open at the size the user settled on.
const std = @import("std");
const Io = std.Io;

pub const SavedSize = struct {
    width: i32,
    height: i32,
};

pub fn resolveStateDir(allocator: std.mem.Allocator, environ: std.process.Environ) !?[]const u8 {
    if (environ.getPosix("XDG_STATE_HOME")) |state_home| {
        if (state_home.len > 0) return try std.fmt.allocPrint(allocator, "{s}/rediwm", .{state_home});
    }
    if (environ.getPosix("HOME")) |home| {
        if (home.len > 0) return try std.fmt.allocPrint(allocator, "{s}/.local/state/rediwm", .{home});
    }
    return null;
}

pub fn resolveFilePath(allocator: std.mem.Allocator, environ: std.process.Environ) !?[]const u8 {
    const dir = (try resolveStateDir(allocator, environ)) orelse return null;
    defer allocator.free(dir);
    return try std.fmt.allocPrint(allocator, "{s}/window_sizes", .{dir});
}

pub fn parseSavedLine(line: []const u8) ?struct { desktop_id: []const u8, size: SavedSize } {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    var it = std.mem.splitScalar(u8, trimmed, '\t');
    const id = it.next() orelse return null;
    const w_str = it.next() orelse return null;
    const h_str = it.next() orelse return null;

    const w = std.fmt.parseInt(i32, w_str, 10) catch return null;
    const h = std.fmt.parseInt(i32, h_str, 10) catch return null;
    if (w < 100 or h < 100 or w > 16384 or h > 16384) return null;

    return .{
        .desktop_id = id,
        .size = .{ .width = w, .height = h },
    };
}

pub fn load(io: Io, environ: std.process.Environ, desktop_id: []const u8) ?SavedSize {
    if (desktop_id.len == 0) return null;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = (resolveFilePath(a, environ) catch return null) orelse return null;
    const content = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(512 * 1024)) catch return null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var result: ?SavedSize = null;
    while (lines.next()) |line| {
        if (parseSavedLine(line)) |parsed| {
            if (std.mem.eql(u8, parsed.desktop_id, desktop_id)) {
                result = parsed.size;
            }
        }
    }
    return result;
}

pub fn save(io: Io, environ: std.process.Environ, desktop_id: []const u8, width: i32, height: i32) void {
    if (desktop_id.len == 0 or width < 100 or height < 100 or width > 16384 or height > 16384) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dir_path = (resolveStateDir(a, environ) catch return) orelse return;
    Io.Dir.cwd().createDirPath(io, dir_path) catch return;

    const file_path = std.fmt.allocPrint(a, "{s}/window_sizes", .{dir_path}) catch return;
    const existing = Io.Dir.cwd().readFileAlloc(io, file_path, a, .limited(512 * 1024)) catch "";

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    var replaced = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (parseSavedLine(trimmed)) |parsed| {
            if (std.mem.eql(u8, parsed.desktop_id, desktop_id)) {
                const s = std.fmt.allocPrint(a, "{s}\t{d}\t{d}\n", .{ desktop_id, width, height }) catch return;
                out.appendSlice(a, s) catch return;
                replaced = true;
                continue;
            }
        }
        const s = std.fmt.allocPrint(a, "{s}\n", .{trimmed}) catch return;
        out.appendSlice(a, s) catch return;
    }
    if (!replaced) {
        const s = std.fmt.allocPrint(a, "{s}\t{d}\t{d}\n", .{ desktop_id, width, height }) catch return;
        out.appendSlice(a, s) catch return;
    }

    const tmp_path = std.fmt.allocPrint(a, "{s}.tmp", .{file_path}) catch return;
    const file = Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true }) catch return;
    file.writeStreamingAll(io, out.items) catch {
        file.close(io);
        Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return;
    };
    file.close(io);
    Io.Dir.rename(.cwd(), tmp_path, .cwd(), file_path, io) catch {
        Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    };
}

test "window_sizes line parser" {
    const valid = parseSavedLine("firefox.desktop\t1200\t800");
    try std.testing.expect(valid != null);
    try std.testing.expectEqualStrings("firefox.desktop", valid.?.desktop_id);
    try std.testing.expectEqual(@as(i32, 1200), valid.?.size.width);
    try std.testing.expectEqual(@as(i32, 800), valid.?.size.height);

    try std.testing.expect(parseSavedLine("") == null);
    try std.testing.expect(parseSavedLine("# comment") == null);
    try std.testing.expect(parseSavedLine("foot.desktop\t50\t50") == null); // too small
    try std.testing.expect(parseSavedLine("foot.desktop\tnotanumber\t100") == null);
}
