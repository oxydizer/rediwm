// Read and decode the wallpaper file on a managed worker thread. The worker
// never touches wlroots or GPU objects — it produces owned CPU pixels (and the
// Appearance page's preview) that the compositor thread wraps in ImageBuffer
// after the eventfd wake.
const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const c = std.posix.system;

const png = @import("png.zig");
const pixbuf = @import("desktop/wallpaper.zig");
const startup = @import("startup.zig");
const stats = @import("ipc/stats.zig");
const wallpapers = @import("wallpapers.zig");

const log = std.log.scoped(.wallpaper);

/// Larger files are not wallpapers; this also bounds the read.
const max_file_bytes = 256 << 20;

/// Twice the Appearance page's preview, so it stays sharp at 2x.
pub const thumb_width = 320;
pub const thumb_height = 180;

pub const Thumb = struct {
    pixels: []u32,

    pub fn deinit(thumb: Thumb, allocator: Allocator) void {
        allocator.free(thumb.pixels);
    }
};

pub const Result = struct {
    path_index: usize = 0,
    image: png.Image,
    thumb: ?Thumb,
};

pub const Loader = struct {
    allocator: Allocator,
    io: std.Io,
    /// Tried in order; the first that decodes wins.
    paths: []const []const u8,
    delay_ns: u64,
    eventfd: posix.fd_t = -1,
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    thread: ?std.Thread = null,
    result: ?Result = null,
    failed: bool = false,
    decode_ns: u64 = 0,

    pub fn start(allocator: Allocator, io: std.Io, candidates: []const []const u8, delay_ns: u64) !*Loader {
        const self = try allocator.create(Loader);
        errdefer allocator.destroy(self);

        const paths = try allocator.alloc([]const u8, candidates.len);
        var owned: usize = 0;
        errdefer {
            for (paths[0..owned]) |p| allocator.free(p);
            allocator.free(paths);
        }
        for (candidates) |path| {
            paths[owned] = try allocator.dupe(u8, path);
            owned += 1;
        }

        const efd = c.eventfd(0, @intCast(std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK));
        if (efd < 0) return error.EventFdFailed;
        errdefer _ = c.close(efd);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .paths = paths,
            .delay_ns = delay_ns,
            .eventfd = efd,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn wakeFd(self: *const Loader) posix.fd_t {
        return self.eventfd;
    }

    /// Joins the worker: a decode in progress finishes first.
    pub fn deinit(self: *Loader) void {
        self.running.store(false, .seq_cst);
        if (self.thread) |t| t.join();
        if (self.result) |result| freeResult(self.allocator, result);
        if (self.eventfd >= 0) _ = c.close(self.eventfd);
        for (self.paths) |p| self.allocator.free(p);
        self.allocator.free(self.paths);
        self.allocator.destroy(self);
    }

    /// Compositor thread. Takes ownership of the decoded pixels, if any.
    pub fn take(self: *Loader) ?Result {
        var discard: [8]u8 = undefined;
        _ = c.read(self.eventfd, &discard, discard.len);
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const result = self.result;
        self.result = null;
        return result;
    }

    pub fn takeFailed(self: *Loader) bool {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        return self.failed;
    }

    fn run(self: *Loader) void {
        startup.interruptibleSleep(&self.running, self.delay_ns);
        if (!self.running.load(.seq_cst)) return;

        const t0 = stats.nowNs();
        var decoded: ?Result = null;
        for (self.paths, 0..) |path, path_index| {
            if (!self.running.load(.seq_cst)) break;
            const image = decodeFile(self.allocator, self.io, path) catch |err| {
                log.warn("wallpaper '{s}': {}", .{ path, err });
                continue;
            };
            const thumb: ?Thumb = if (wallpapers.thumbnail(self.allocator, image.pixels, image.width, image.height, thumb_width, thumb_height)) |pixels|
                .{ .pixels = pixels }
            else |_|
                null;
            decoded = .{ .image = image, .thumb = thumb, .path_index = path_index };
            break;
        }
        const decode_ns = stats.nowNs() -% t0;

        _ = c.pthread_mutex_lock(&self.mutex);
        if (!self.running.load(.seq_cst)) {
            if (decoded) |result| freeResult(self.allocator, result);
            _ = c.pthread_mutex_unlock(&self.mutex);
            return;
        }
        if (decoded) |result| {
            self.result = result;
            self.decode_ns = decode_ns;
        } else {
            self.failed = true;
        }
        _ = c.pthread_mutex_unlock(&self.mutex);

        const val: u64 = 1;
        _ = c.write(self.eventfd, std.mem.asBytes(&val), @sizeOf(u64));
    }
};

pub fn freeResult(allocator: Allocator, result: Result) void {
    result.image.deinit(allocator);
    if (result.thumb) |thumb| thumb.deinit(allocator);
}

/// png.zig's decoder for the PNGs it supports (the bundled one included),
/// GdkPixbuf for everything else.
pub fn decodeFile(allocator: Allocator, io: std.Io, path: []const u8) !png.Image {
    if (std.ascii.endsWithIgnoreCase(path, ".png")) {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes));
        defer allocator.free(bytes);
        if (png.decode(allocator, bytes)) |image| return image else |err| switch (err) {
            // GdkPixbuf sniffs content, so misnamed files still load.
            error.UnsupportedPng, error.InvalidPng => {},
            else => return err,
        }
    }
    const image = try pixbuf.load(allocator, path, .fill);
    var opaque_pixels = true;
    for (image.pixels) |p| {
        if (p >> 24 != 0xff) {
            opaque_pixels = false;
            break;
        }
    }
    return .{ .width = image.w, .height = image.h, .pixels = image.pixels, .has_alpha = !opaque_pixels };
}
