//! Running system tools and touching root-owned files for the firewall
//! helper. Tools are found only in root-owned system directories and run
//! with a fixed environment (C locale, so their output parses), never a
//! shell.
const std = @import("std");
const c = @import("c");
const platform = @import("platform");
const Allocator = std.mem.Allocator;

pub const Ctx = struct {
    a: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
};

const dirs = [_][]const u8{ "/usr/sbin", "/sbin", "/usr/bin", "/bin", "/usr/local/sbin", "/usr/local/bin" };

/// `name` in the system directories, or null. Init-aware programs (`systemctl`,
/// `journalctl`) look in `/usr/local/bin` first, where a system without systemd
/// as PID 1 installs its wrappers; see platform/tool.zig.
pub fn tool(ctx: Ctx, comptime name: []const u8) ?[]const u8 {
    if (comptime platform.tool.isInitAware(name)) {
        const path = "/usr/local/bin/" ++ name;
        if (std.Io.Dir.accessAbsolute(ctx.io, path, .{ .execute = true })) |_| return path else |_| {}
    }
    inline for (dirs) |dir| {
        const path = dir ++ "/" ++ name;
        if (std.Io.Dir.accessAbsolute(ctx.io, path, .{ .execute = true })) |_| return path else |_| {}
    }
    return null;
}

pub const Result = struct {
    ok: bool,
    code: u8,
    out: []const u8,
    err: []const u8,
};

pub fn environment(a: Allocator) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(a);
    try env.put("PATH", "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin");
    try env.put("LC_ALL", "C");
    try env.put("LANG", "C");
    return env;
}

/// Runs argv (argv[0] absolute) and collects its output. A tool that cannot
/// start, times out or dies from a signal is `ok = false` with code 255.
pub fn run(ctx: Ctx, argv: []const []const u8) Result {
    const result = std.process.run(ctx.a, ctx.io, .{
        .argv = argv,
        .environ_map = ctx.env,
        .stdout_limit = .limited(8 << 20),
        .stderr_limit = .limited(64 << 10),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(40), .clock = .awake } },
    }) catch |err| {
        std.log.err("{s}: {s}", .{ argv[0], @errorName(err) });
        return .{ .ok = false, .code = 255, .out = "", .err = "" };
    };
    const code: u8 = switch (result.term) {
        .exited => |status| status,
        else => 255,
    };
    if (code != 0) std.log.info("{s} exited {d}: {s}", .{ argv[0], code, std.mem.trim(u8, result.stderr, " \n") });
    return .{ .ok = code == 0, .code = code, .out = result.stdout, .err = result.stderr };
}

/// Like `run` with a tool looked up by name; null when it is not installed.
pub fn tryTool(ctx: Ctx, comptime name: []const u8, args: []const []const u8) ?Result {
    const path = tool(ctx, name) orelse return null;
    const argv = ctx.a.alloc([]const u8, args.len + 1) catch return null;
    argv[0] = path;
    @memcpy(argv[1..], args);
    return run(ctx, argv);
}

/// Fails unless the tool exists and exits 0.
pub fn must(ctx: Ctx, comptime name: []const u8, args: []const []const u8) !void {
    const result = tryTool(ctx, name, args) orelse return error.ToolMissing;
    if (!result.ok) return error.ToolFailed;
}

pub fn readFile(ctx: Ctx, path: []const u8, limit: usize) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.a, .limited(limit)) catch null;
}

pub fn exists(ctx: Ctx, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(ctx.io, path, .{}) catch return false;
    return true;
}

/// Writes `data` to `path` through a temporary file in the same directory and
/// a rename, so a reader sees the old or the new file, never half of one.
pub fn writeAtomic(ctx: Ctx, path: []const u8, data: []const u8, mode: c.mode_t) !void {
    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    try makePath(ctx, dir);
    const tmp = try std.fmt.allocPrintSentinel(ctx.a, "{s}.new", .{path}, 0);
    const fd = c.open(tmp.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, mode));
    if (fd < 0) return error.WriteFailed;
    var done: usize = 0;
    while (done < data.len) {
        const n = c.write(fd, data.ptr + done, data.len - done);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) {
            _ = c.close(fd);
            return error.WriteFailed;
        }
        done += @intCast(n);
    }
    _ = c.fchmod(fd, @intCast(mode));
    if (c.fsync(fd) != 0) {
        _ = c.close(fd);
        return error.WriteFailed;
    }
    _ = c.close(fd);
    const final = try ctx.a.dupeSentinel(u8, path, 0);
    if (c.rename(tmp.ptr, final.ptr) != 0) return error.WriteFailed;
}

pub fn makePath(ctx: Ctx, dir: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch return error.WriteFailed;
}

pub fn remove(ctx: Ctx, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
}

/// Entries of a directory (names only), or empty.
pub fn list(ctx: Ctx, path: []const u8) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const z = ctx.a.dupeSentinel(u8, path, 0) catch return &.{};
    const dir = c.opendir(z.ptr) orelse return &.{};
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (name.len == 0 or name[0] == '.') continue;
        names.append(ctx.a, ctx.a.dupe(u8, name) catch continue) catch continue;
    }
    return names.toOwnedSlice(ctx.a) catch &.{};
}

pub fn nowSeconds() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @intCast(ts.tv_sec);
}
