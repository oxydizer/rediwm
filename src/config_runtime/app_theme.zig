//! A bounded background export. The compositor-owned manager serializes jobs;
//! no toolkit work runs on the event loop and there are no idle timers.
const std = @import("std");
const platform = @import("platform");
const config = @import("config").app_theme;
const c = std.posix.system;
const a = std.heap.c_allocator;

pub const Action = enum { gtk, qt, follow };
pub const Result = struct {
    support: config.QtSupport = .{ .qt5 = false, .qt6 = false },
    gtk_slot: ?u1 = null,
    gtk_notified: bool = false,
    qt_error: ?anyerror = null,
};

/// RediWM Qt style plugins installed beside this executable
/// (`<bin>/../lib/rediwm/qt<N>/styles`, see build/qt_style.zig).
pub const QtStyles = struct {
    /// `QT_PLUGIN_PATH` entries for the installed majors, or null for none.
    path: ?[]u8 = null,
    qt5: bool = false,
    qt6: bool = false,

    pub fn deinit(self: *QtStyles) void {
        if (self.path) |path| a.free(path);
        self.* = .{};
    }
};

pub fn findQtStyles(io: std.Io) QtStyles {
    const bin = std.process.executableDirPathAlloc(io, a) catch return .{};
    defer a.free(bin);
    var result: QtStyles = .{};
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(a);
    for ([_]u8{ 6, 5 }) |major| {
        const dir = std.fmt.allocPrint(a, "{s}/../lib/rediwm/qt{d}", .{ bin, major }) catch return .{};
        defer a.free(dir);
        const plugin = std.fmt.allocPrint(a, "{s}/styles/librediwm-style.so", .{dir}) catch return .{};
        defer a.free(plugin);
        std.Io.Dir.cwd().access(io, plugin, .{}) catch continue;
        const resolved = std.fs.path.resolve(a, &.{dir}) catch return .{};
        defer a.free(resolved);
        if (path.items.len > 0) path.append(a, ':') catch return .{};
        path.appendSlice(a, resolved) catch return .{};
        if (major == 5) result.qt5 = true else result.qt6 = true;
    }
    if (path.items.len > 0) result.path = path.toOwnedSlice(a) catch return .{};
    return result;
}

pub const Job = struct {
    io: std.Io,
    env: std.process.Environ,
    action: Action,
    palette: config.Palette,
    styles: [2]bool,
    fd: c_int,
    thread: ?std.Thread = null,
    result: anyerror!Result = error.NotFinished,

    pub fn create(io: std.Io, env: std.process.Environ, action: Action, palette: config.Palette, styles: [2]bool) !*Job {
        const self = try a.create(Job);
        errdefer a.destroy(self);
        const fd = platform.wake.create() orelse return error.EventFdFailed;
        self.* = .{ .io = io, .env = env, .action = action, .palette = palette, .styles = styles, .fd = fd };
        return self;
    }

    pub fn start(self: *Job) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn join(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    pub fn deinit(self: *Job) void {
        self.join();
        _ = c.close(self.fd);
        a.destroy(self);
    }

    fn run(self: *Job) void {
        self.result = self.apply();
        const value: u64 = 1;
        _ = c.write(self.fd, std.mem.asBytes(&value), @sizeOf(u64));
    }

    fn apply(self: *Job) !Result {
        const home = try config.configHome(a, self.env);
        defer a.free(home);
        var support = config.QtSupport{ .qt5 = false, .qt6 = false };
        if (self.action != .gtk) {
            const qt5 = try config.executable(a, self.io, self.env, "qt5ct");
            defer if (qt5) |path| a.free(path);
            const qt6 = try config.executable(a, self.io, self.env, "qt6ct");
            defer if (qt6) |path| a.free(path);
            support = .{ .qt5 = qt5 != null, .qt6 = qt6 != null, .style5 = self.styles[0], .style6 = self.styles[1] };
        }
        if (self.action != .follow) {
            try config.apply(a, self.io, home, if (self.action == .gtk) .gtk else .qt, self.palette, support);
            return .{ .support = support };
        }
        const data = try config.follow.dataHome(a, self.env);
        defer a.free(data);
        const slot = try config.follow.apply(a, self.io, home, data, self.palette);
        var result = Result{ .support = support, .gtk_slot = slot };
        if (support.qt5 or support.qt6) {
            var buf: [16]u8 = undefined;
            const revision = std.fmt.bufPrint(&buf, "{x:0>16}", .{std.hash.Wyhash.hash(0, std.mem.asBytes(&self.palette))}) catch unreachable;
            config.applyRevision(a, self.io, home, .qt, self.palette, support, revision) catch |err| {
                result.qt_error = err;
            };
        }
        result.gtk_notified = @import("app_theme_notify.zig").gtk(self.io, self.env, home, config.follow.name(slot)) catch false;
        if (!result.gtk_notified) {
            // Without a working settings transport, the user stylesheet is
            // the reliable startup fallback even when GSettings overrides ini.
            try config.apply(a, self.io, home, .gtk, self.palette, support);
        }
        return result;
    }
};
