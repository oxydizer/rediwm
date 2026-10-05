//! Pixel edits and background file operations. Originals are never overwritten.
const std = @import("std");
const c = @import("../files/c.zig").api;
const Image = @import("loader.zig").Image;
const Stamp = @import("cache.zig").Stamp;
const a = std.heap.c_allocator;

pub fn crop(im: Image, x: i32, y: i32, w: i32, h: i32) !Image {
    if (x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > im.w or y + h > im.h) return error.InvalidCrop;
    const pixels = try a.alloc(u32, @intCast(@as(i64, w) * h));
    for (0..@intCast(h)) |row| {
        const src = (row + @as(usize, @intCast(y))) * @as(usize, @intCast(im.w)) + @as(usize, @intCast(x));
        const dst = row * @as(usize, @intCast(w));
        @memcpy(pixels[dst..][0..@intCast(w)], im.pixels[src..][0..@intCast(w)]);
    }
    return .{ .pixels = pixels, .w = w, .h = h };
}
pub fn rotate(im: Image) !Image {
    const pixels = try a.alloc(u32, im.pixels.len);
    const w: usize = @intCast(im.w);
    const h: usize = @intCast(im.h);
    for (0..h) |y| for (0..w) |x| {
        pixels[x * h + h - 1 - y] = im.pixels[y * w + x];
    };
    return .{ .pixels = pixels, .w = im.h, .h = im.w };
}
fn writePng(context: ?*anyopaque, data: [*c]const u8, len: c_uint) callconv(.c) c.cairo_status_t {
    const fd: *const c_int = @ptrCast(@alignCast(context.?));
    var offset: usize = 0;
    while (offset < len) {
        const n = c.write(fd.*, data + offset, len - offset);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return c.CAIRO_STATUS_WRITE_ERROR;
        offset += @intCast(n);
    }
    return c.CAIRO_STATUS_SUCCESS;
}
fn save(im: Image, path: [:0]const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const temp = try std.fmt.allocPrintSentinel(a, "{s}/.rediwm-images-XXXXXX", .{parent}, 0);
    defer a.free(temp);
    var fd = c.mkostemp(temp, c.O_CLOEXEC);
    if (fd < 0) return error.CreateFailed;
    defer _ = c.close(fd);
    defer _ = c.unlink(temp);
    const surface = c.cairo_image_surface_create_for_data(@ptrCast(im.pixels.ptr), c.CAIRO_FORMAT_ARGB32, im.w, im.h, im.w * 4);
    defer c.cairo_surface_destroy(surface);
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS or c.cairo_surface_write_to_png_stream(surface, writePng, &fd) != c.CAIRO_STATUS_SUCCESS) return error.WriteFailed;
    if (c.fsync(fd) != 0) return error.WriteFailed;
    // Publish only a complete file, and never replace an existing destination.
    if (c.renameat2(c.AT_FDCWD, temp, c.AT_FDCWD, path, c.RENAME_NOREPLACE) != 0) {
        if (std.posix.errno(@as(c_int, -1)) == .EXIST) return error.PathAlreadyExists;
        return error.PublishFailed;
    }
}

pub const Operation = struct {
    pub const Kind = enum { save, trash, delete };
    kind: Kind,
    path: [:0]const u8,
    image: ?Image = null,
    stamp: ?Stamp = null,
    io: std.Io,
    fds: [2]c_int = undefined,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,

    pub fn start(kind: Kind, io: std.Io, path: []const u8, im: ?Image, stamp: ?Stamp) !*Operation {
        const self = try a.create(Operation);
        errdefer a.destroy(self);
        self.* = .{ .kind = kind, .path = try a.dupeZ(u8, path), .io = io, .stamp = stamp };
        errdefer a.free(self.path);
        if (im) |image| self.image = .{ .pixels = try a.dupe(u32, image.pixels), .w = image.w, .h = image.h };
        errdefer if (self.image) |image| image.deinit();
        if (c.pipe2(&self.fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return error.PipeFailed;
        errdefer {
            _ = c.close(self.fds[0]);
            _ = c.close(self.fds[1]);
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn deinit(self: *Operation) void {
        self.thread.?.join();
        if (self.image) |image| image.deinit();
        a.free(self.path);
        _ = c.close(self.fds[0]);
        _ = c.close(self.fds[1]);
        a.destroy(self);
    }
    fn run(self: *Operation) void {
        self.execute() catch |err| {
            self.err = err;
        };
        self.done.store(true, .release);
        _ = c.write(self.fds[1], "x", 1);
    }
    fn execute(self: *Operation) !void {
        switch (self.kind) {
            .save => try save(self.image.?, self.path),
            .trash, .delete => {
                if (self.stamp == null or !std.meta.eql(self.stamp, Stamp.read(self.path))) return error.FileChanged;
                if (self.kind == .delete) {
                    try @import("../files/ops.zig").deleteItems(self.io, &.{self.path});
                } else {
                    try @import("../files/ops.zig").trashItems(self.io, &.{self.path});
                }
            },
        }
    }
};
