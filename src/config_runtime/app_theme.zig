//! Filesystem work runs only on an explicit Settings action. One eventfd
//! wakes the compositor when the export finishes; there are no idle timers.
const std = @import("std");
const platform = @import("platform");
const config = @import("config").app_theme;
const c = std.posix.system;
const a = std.heap.c_allocator;

pub const Job = struct {
    io: std.Io,
    env: std.process.Environ,
    toolkit: config.Toolkit,
    palette: config.Palette,
    fd: c_int,
    thread: ?std.Thread = null,
    result: anyerror!config.QtSupport = error.NotFinished,

    pub fn create(io: std.Io, env: std.process.Environ, toolkit: config.Toolkit, palette: config.Palette) !*Job {
        const self = try a.create(Job);
        errdefer a.destroy(self);
        const fd = platform.wake.create() orelse return error.EventFdFailed;
        self.* = .{ .io = io, .env = env, .toolkit = toolkit, .palette = palette, .fd = fd };
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

    fn apply(self: *Job) !config.QtSupport {
        const home = try config.configHome(a, self.env);
        defer a.free(home);
        var support = config.QtSupport{ .qt5 = false, .qt6 = false };
        if (self.toolkit == .qt) {
            const qt5 = try config.executable(a, self.io, self.env, "qt5ct");
            defer if (qt5) |path| a.free(path);
            const qt6 = try config.executable(a, self.io, self.env, "qt6ct");
            defer if (qt6) |path| a.free(path);
            support = .{ .qt5 = qt5 != null, .qt6 = qt6 != null };
        }
        try config.apply(a, self.io, home, self.toolkit, self.palette, support);
        return support;
    }
};
