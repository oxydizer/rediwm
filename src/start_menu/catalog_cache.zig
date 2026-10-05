// Versioned, bounded application-catalogue cache under the XDG cache dir.
// Never serializes pointers. A matching file is only a prompt; the worker
// revalidates source identities (every desktop file, not a directory mtime)
// and TryExec before treating the snapshot as authoritative. Cache I/O
// failure must not prevent startup.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const applications = @import("applications.zig");
const AppEntry = applications.AppEntry;

const log = std.log.scoped(.catalog_cache);

pub const schema_version: u16 = 2;
pub const max_bytes: usize = 4 * 1024 * 1024;
pub const max_string: usize = 64 * 1024;
pub const max_entries: u32 = 4096;
pub const max_sources: u32 = 8192;

const magic = [_]u8{ 'T', 'W', 'L', 'C' };

pub const SourceIdent = struct {
    path: []const u8,
    mtime_sec: i64,
    mtime_nsec: i64,
    size: u64,
};

pub const Payload = struct {
    locale_tag: []const u8,
    current_desktop: []const u8,
    app_dirs: []const []const u8,
    path_env: []const u8,
    sources: []const SourceIdent,
    entries: []const AppEntry,
};

pub fn cachePath(arena: Allocator, environ: std.process.Environ) ![]const u8 {
    if (environ.getPosix("REDIWM_DISABLE_CATALOG_CACHE")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "false")) return "";
    }
    if (environ.getPosix("REDIWM_CATALOG_CACHE_PATH")) |p| {
        return arena.dupe(u8, p);
    }
    if (environ.getPosix("XDG_CACHE_HOME")) |home| {
        const trimmed = std.mem.trimEnd(u8, home, "/");
        return std.fmt.allocPrint(arena, "{s}/rediwm/catalog-v{d}.bin", .{ trimmed, schema_version });
    }
    if (environ.getPosix("HOME")) |home| {
        const trimmed = std.mem.trimEnd(u8, home, "/");
        return std.fmt.allocPrint(arena, "{s}/.cache/rediwm/catalog-v{d}.bin", .{ trimmed, schema_version });
    }
    return "";
}

pub fn envKeys(arena: Allocator, environ: std.process.Environ) !struct {
    locale_tag: []const u8,
    current_desktop: []const u8,
    app_dirs: []const []const u8,
    path_env: []const u8,
} {
    const locale_tag = environ.getPosix("LC_ALL") orelse
        environ.getPosix("LC_MESSAGES") orelse
        environ.getPosix("LANG") orelse "";
    const current_desktop = environ.getPosix("XDG_CURRENT_DESKTOP") orelse "";
    const path_env = environ.getPosix("PATH") orelse "";
    const app_dirs = try applications.resolveApplicationDirs(arena, environ);
    return .{
        .locale_tag = locale_tag,
        .current_desktop = current_desktop,
        .app_dirs = app_dirs,
        .path_env = path_env,
    };
}

pub fn keysMatch(payload: Payload, locale_tag: []const u8, current_desktop: []const u8, app_dirs: []const []const u8, path_env: []const u8) bool {
    if (!std.mem.eql(u8, payload.locale_tag, locale_tag)) return false;
    if (!std.mem.eql(u8, payload.current_desktop, current_desktop)) return false;
    if (!std.mem.eql(u8, payload.path_env, path_env)) return false;
    if (payload.app_dirs.len != app_dirs.len) return false;
    for (payload.app_dirs, app_dirs) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

pub fn sourcesMatch(a: []const SourceIdent, b: []const SourceIdent) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.path, right.path)) return false;
        if (left.mtime_sec != right.mtime_sec) return false;
        if (left.mtime_nsec != right.mtime_nsec) return false;
        if (left.size != right.size) return false;
    }
    return true;
}

pub fn sortSources(sources: []SourceIdent) void {
    std.mem.sort(SourceIdent, sources, {}, struct {
        fn less(_: void, lhs: SourceIdent, rhs: SourceIdent) bool {
            return std.mem.order(u8, lhs.path, rhs.path) == .lt;
        }
    }.less);
}

pub fn statPath(io: Io, path: []const u8) ?SourceIdent {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    const ns = st.mtime.nanoseconds;
    return .{
        .path = path,
        .mtime_sec = @intCast(@divTrunc(ns, 1_000_000_000)),
        .mtime_nsec = @intCast(@mod(ns, 1_000_000_000)),
        .size = st.size,
    };
}

pub fn read(arena: Allocator, io: Io, environ: std.process.Environ) ?Payload {
    const path = cachePath(arena, environ) catch return null;
    if (path.len == 0) return null;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch return null;
    const payload = parse(arena, bytes) catch |err| {
        log.warn("ignoring catalog cache {s}: {}", .{ path, err });
        return null;
    };
    const keys = envKeys(arena, environ) catch return null;
    if (!keysMatch(payload, keys.locale_tag, keys.current_desktop, keys.app_dirs, keys.path_env)) {
        return null;
    }
    return payload;
}

pub fn write(allocator: Allocator, io: Io, environ: std.process.Environ, payload: Payload) void {
    var tmp_arena = std.heap.ArenaAllocator.init(allocator);
    defer tmp_arena.deinit();
    const arena = tmp_arena.allocator();
    const path = cachePath(arena, environ) catch return;
    if (path.len == 0) return;

    if (std.fs.path.dirname(path)) |dir| {
        Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            log.warn("catalog cache mkdir {s}: {}", .{ dir, err });
            return;
        };
    }

    const encoded = encode(arena, payload) catch |err| {
        log.warn("catalog cache encode: {}", .{err});
        return;
    };
    if (encoded.len > max_bytes) {
        log.warn("catalog cache too large to write ({d} bytes)", .{encoded.len});
        return;
    }

    const tmp = std.fmt.allocPrint(arena, "{s}.tmp-{d}", .{ path, std.os.linux.getpid() }) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = encoded }) catch |err| {
        log.warn("catalog cache write {s}: {}", .{ tmp, err });
        return;
    };
    const cwd = Io.Dir.cwd();
    cwd.rename(tmp, cwd, path, io) catch |err| {
        log.warn("catalog cache rename {s} -> {s}: {}", .{ tmp, path, err });
        cwd.deleteFile(io, tmp) catch {};
        return;
    };
}

pub fn encode(arena: Allocator, payload: Payload) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.appendSlice(arena, &magic);
    try putU16(&out, arena, schema_version);
    try putU16(&out, arena, 0);
    try putStr(&out, arena, payload.locale_tag);
    try putStr(&out, arena, payload.current_desktop);
    try putU32(&out, arena, @intCast(payload.app_dirs.len));
    for (payload.app_dirs) |dir| try putStr(&out, arena, dir);
    try putStr(&out, arena, payload.path_env);
    if (payload.sources.len > max_sources) return error.TooManySources;
    try putU32(&out, arena, @intCast(payload.sources.len));
    for (payload.sources) |src| {
        try putStr(&out, arena, src.path);
        try putI64(&out, arena, src.mtime_sec);
        try putI64(&out, arena, src.mtime_nsec);
        try putU64(&out, arena, src.size);
    }
    if (payload.entries.len > max_entries) return error.TooManyEntries;
    try putU32(&out, arena, @intCast(payload.entries.len));
    for (payload.entries) |e| {
        try putStr(&out, arena, e.id);
        try putStr(&out, arena, e.desktop_file_path);
        try putStr(&out, arena, e.name);
        try putStr(&out, arena, e.generic_name orelse "");
        try putStr(&out, arena, e.comment orelse "");
        try putStr(&out, arena, e.icon orelse "");
        try putStr(&out, arena, e.startup_wm_class orelse "");
        try putStr(&out, arena, e.exec);
        try putStr(&out, arena, e.path orelse "");
        try putStr(&out, arena, e.try_exec orelse "");
        try putStr(&out, arena, e.keywords);
        try putStr(&out, arena, e.categories);
        try out.append(arena, if (e.terminal) 1 else 0);
        try out.append(arena, if (e.dbus_activatable) 1 else 0);
    }
    return out.toOwnedSlice(arena);
}

pub fn parse(arena: Allocator, bytes: []const u8) !Payload {
    if (bytes.len < magic.len + 4) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.BadMagic;
    var r = Cursor{ .bytes = bytes, .i = magic.len };
    const version = try r.u16le();
    if (version != schema_version) return error.SchemaMismatch;
    _ = try r.u16le();
    const locale_tag = try r.str(arena);
    const current_desktop = try r.str(arena);
    const dir_count = try r.u32le();
    if (dir_count > 64) return error.TooManyDirs;
    const app_dirs = try arena.alloc([]const u8, dir_count);
    for (app_dirs) |*dir| dir.* = try r.str(arena);
    const path_env = try r.str(arena);
    const source_count = try r.u32le();
    if (source_count > max_sources) return error.TooManySources;
    const sources = try arena.alloc(SourceIdent, source_count);
    for (sources) |*src| {
        src.* = .{
            .path = try r.str(arena),
            .mtime_sec = try r.i64le(),
            .mtime_nsec = try r.i64le(),
            .size = try r.u64le(),
        };
    }
    const entry_count = try r.u32le();
    if (entry_count > max_entries) return error.TooManyEntries;
    const entries = try arena.alloc(AppEntry, entry_count);
    for (entries) |*e| {
        const id = try r.str(arena);
        const desktop_file_path = try r.str(arena);
        const name = try r.str(arena);
        const generic = try r.str(arena);
        const comment = try r.str(arena);
        const icon = try r.str(arena);
        const startup_wm_class = try r.str(arena);
        const exec = try r.str(arena);
        const path = try r.str(arena);
        const try_exec = try r.str(arena);
        const keywords = try r.str(arena);
        const categories = try r.str(arena);
        e.* = .{
            .id = id,
            .desktop_file_path = desktop_file_path,
            .name = name,
            .generic_name = if (generic.len == 0) null else generic,
            .comment = if (comment.len == 0) null else comment,
            .icon = if (icon.len == 0) null else icon,
            .startup_wm_class = if (startup_wm_class.len == 0) null else startup_wm_class,
            .exec = exec,
            .path = if (path.len == 0) null else path,
            .try_exec = if (try_exec.len == 0) null else try_exec,
            .keywords = keywords,
            .categories = categories,
            .terminal = (try r.byte()) != 0,
            .dbus_activatable = (try r.byte()) != 0,
        };
    }
    return .{
        .locale_tag = locale_tag,
        .current_desktop = current_desktop,
        .app_dirs = app_dirs,
        .path_env = path_env,
        .sources = sources,
        .entries = entries,
    };
}

const Cursor = struct {
    bytes: []const u8,
    i: usize,

    fn take(self: *Cursor, n: usize) ![]const u8 {
        const end = std.math.add(usize, self.i, n) catch return error.Truncated;
        if (end > self.bytes.len) return error.Truncated;
        const slice = self.bytes[self.i..end];
        self.i = end;
        return slice;
    }

    fn u16le(self: *Cursor) !u16 {
        const b = try self.take(2);
        return std.mem.readInt(u16, b[0..2], .little);
    }
    fn u32le(self: *Cursor) !u32 {
        const b = try self.take(4);
        return std.mem.readInt(u32, b[0..4], .little);
    }
    fn u64le(self: *Cursor) !u64 {
        const b = try self.take(8);
        return std.mem.readInt(u64, b[0..8], .little);
    }
    fn i64le(self: *Cursor) !i64 {
        return @bitCast(try self.u64le());
    }
    fn byte(self: *Cursor) !u8 {
        const b = try self.take(1);
        return b[0];
    }
    fn str(self: *Cursor, arena: Allocator) ![]u8 {
        const len = try self.u32le();
        if (len > max_string) return error.StringTooLong;
        const bytes = try self.take(len);
        return arena.dupe(u8, bytes);
    }
};

fn putU16(out: *std.ArrayList(u8), arena: Allocator, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try out.appendSlice(arena, &buf);
}
fn putU32(out: *std.ArrayList(u8), arena: Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(arena, &buf);
}
fn putU64(out: *std.ArrayList(u8), arena: Allocator, v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try out.appendSlice(arena, &buf);
}
fn putI64(out: *std.ArrayList(u8), arena: Allocator, v: i64) !void {
    try putU64(out, arena, @bitCast(v));
}
fn putStr(out: *std.ArrayList(u8), arena: Allocator, s: []const u8) !void {
    if (s.len > max_string) return error.StringTooLong;
    try putU32(out, arena, @intCast(s.len));
    try out.appendSlice(arena, s);
}

fn sampleEntry() AppEntry {
    return .{
        .id = "foot.desktop",
        .desktop_file_path = "/usr/share/applications/foot.desktop",
        .name = "Foot",
        .generic_name = "Terminal",
        .comment = "A terminal",
        .icon = "foot",
        .exec = "foot",
        .try_exec = "foot",
        .keywords = "shell;terminal",
        .categories = "System;TerminalEmulator;",
        .terminal = false,
        .dbus_activatable = false,
    };
}

test "catalog cache roundtrip" {
    const payload = Payload{
        .locale_tag = "en_US.UTF-8",
        .current_desktop = "rediwm",
        .app_dirs = &.{ "/usr/share/applications", "/home/me/.local/share/applications" },
        .path_env = "/usr/bin:/bin",
        .sources = &.{
            .{ .path = "/usr/share/applications/foot.desktop", .mtime_sec = 10, .mtime_nsec = 20, .size = 30 },
        },
        .entries = &.{sampleEntry()},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const encoded = try encode(arena.allocator(), payload);
    const parsed = try parse(arena.allocator(), encoded);
    try std.testing.expect(keysMatch(parsed, payload.locale_tag, payload.current_desktop, payload.app_dirs, payload.path_env));
    try std.testing.expect(sourcesMatch(parsed.sources, payload.sources));
    try std.testing.expectEqual(@as(usize, 1), parsed.entries.len);
    try std.testing.expectEqualStrings("Foot", parsed.entries[0].name);
    try std.testing.expectEqualStrings("foot", parsed.entries[0].try_exec.?);
}

test "catalog cache rejects truncated, bad magic, and schema mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Truncated, parse(arena.allocator(), "TW"));
    try std.testing.expectError(error.BadMagic, parse(arena.allocator(), "XXXX\x01\x00\x00\x00"));
    const payload = Payload{
        .locale_tag = "",
        .current_desktop = "",
        .app_dirs = &.{},
        .path_env = "",
        .sources = &.{},
        .entries = &.{},
    };
    const encoded = try encode(arena.allocator(), payload);
    var mutated = try arena.allocator().dupe(u8, encoded);
    mutated[4] = 99;
    mutated[5] = 0;
    try std.testing.expectError(error.SchemaMismatch, parse(arena.allocator(), mutated));
}

test "catalog cache keysMatch is strict on dir order and locale" {
    const payload = Payload{
        .locale_tag = "de_DE",
        .current_desktop = "sway",
        .app_dirs = &.{ "/a", "/b" },
        .path_env = "/bin",
        .sources = &.{},
        .entries = &.{},
    };
    try std.testing.expect(!keysMatch(payload, "en_US", "sway", &.{ "/a", "/b" }, "/bin"));
    try std.testing.expect(!keysMatch(payload, "de_DE", "sway", &.{ "/b", "/a" }, "/bin"));
    try std.testing.expect(!keysMatch(payload, "de_DE", "sway", &.{ "/a", "/b" }, "/usr/bin"));
    try std.testing.expect(keysMatch(payload, "de_DE", "sway", &.{ "/a", "/b" }, "/bin"));
}
