// Thumbnails for Appearance's wallpaper strip. A worker thread decodes each
// image in turn and keeps a small copy; the compositor thread reads the
// finished ones after the eventfd wake. Like wallpaper_load.zig, the worker
// never touches wlroots or GPU objects.
const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const c = std.posix.system;

const wallpaper_load = @import("wallpaper_load.zig");
const wallpapers = @import("wallpapers.zig");

const log = std.log.scoped(.wallpaper);

/// Twice the strip's tile, so it stays sharp at 2x.
pub const thumb_width = 320;
pub const thumb_height = 180;

pub const Strip = struct {
    allocator: Allocator,
    io: std.Io,
    /// One per image; owned copies, fixed for the strip's lifetime.
    paths: [][]u8,
    /// Filled by the worker, one at a time, and never freed before `deinit`,
    /// so a slice returned by `thumb` stays valid until then.
    thumbs: []?[]u32,
    eventfd: posix.fd_t = -1,
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    thread: ?std.Thread = null,

    pub fn start(allocator: Allocator, io: std.Io, entries: []const wallpapers.Entry) !*Strip {
        const self = try allocator.create(Strip);
        errdefer allocator.destroy(self);
        const paths = try allocator.alloc([]u8, entries.len);
        var owned: usize = 0;
        errdefer {
            for (paths[0..owned]) |p| allocator.free(p);
            allocator.free(paths);
        }
        for (entries) |entry| {
            paths[owned] = try allocator.dupe(u8, entry.path);
            owned += 1;
        }
        const thumbs = try allocator.alloc(?[]u32, entries.len);
        errdefer allocator.free(thumbs);
        @memset(thumbs, null);
        const efd = c.eventfd(0, @intCast(std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK));
        if (efd < 0) return error.EventFdFailed;
        errdefer _ = c.close(efd);
        self.* = .{ .allocator = allocator, .io = io, .paths = paths, .thumbs = thumbs, .eventfd = efd };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Joins the worker: a decode in progress finishes first.
    pub fn deinit(self: *Strip) void {
        self.running.store(false, .seq_cst);
        if (self.thread) |t| t.join();
        for (self.thumbs) |maybe| if (maybe) |pixels| self.allocator.free(pixels);
        self.allocator.free(self.thumbs);
        for (self.paths) |p| self.allocator.free(p);
        self.allocator.free(self.paths);
        if (self.eventfd >= 0) _ = c.close(self.eventfd);
        self.allocator.destroy(self);
    }

    pub fn wakeFd(self: *const Strip) posix.fd_t {
        return self.eventfd;
    }

    /// Compositor thread: clears the wake so the fd stops reporting readable.
    pub fn drain(self: *Strip) void {
        var discard: [8]u8 = undefined;
        _ = c.read(self.eventfd, &discard, discard.len);
    }

    /// Whether this strip was started for exactly these images.
    pub fn matches(self: *const Strip, entries: []const wallpapers.Entry) bool {
        if (entries.len != self.paths.len) return false;
        for (entries, self.paths) |entry, path| {
            if (!std.mem.eql(u8, entry.path, path)) return false;
        }
        return true;
    }

    /// The finished thumbnail (`thumb_width` x `thumb_height`), if the worker
    /// has got that far and could decode the file.
    pub fn thumb(self: *Strip, index: usize) ?[]const u32 {
        if (index >= self.thumbs.len) return null;
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        return self.thumbs[index];
    }

    fn run(self: *Strip) void {
        for (self.paths, 0..) |path, i| {
            if (!self.running.load(.seq_cst)) return;
            const image = wallpaper_load.decodeFile(self.allocator, self.io, path) catch |err| {
                log.warn("wallpaper thumbnail '{s}': {}", .{ path, err });
                continue;
            };
            defer image.deinit(self.allocator);
            const pixels = wallpapers.thumbnail(self.allocator, image.pixels, image.width, image.height, thumb_width, thumb_height) catch continue;
            _ = c.pthread_mutex_lock(&self.mutex);
            self.thumbs[i] = pixels;
            _ = c.pthread_mutex_unlock(&self.mutex);
            const val: u64 = 1;
            _ = c.write(self.eventfd, std.mem.asBytes(&val), @sizeOf(u64));
        }
    }
};
