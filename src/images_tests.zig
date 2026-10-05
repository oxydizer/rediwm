const std = @import("std");
const c = @import("files/c.zig").api;
const loader = @import("images/loader.zig");
test {
    _ = @import("images/view.zig");
    _ = @import("images/app.zig");
    _ = @import("images/cache.zig");
}
test "decoder handles alpha and rejects corrupt images" {
    var path = "/tmp/rediwm-images-test-XXXXXX".*;
    const fd = c.mkstemp(&path);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    defer _ = c.unlink(&path);
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 2, 3);
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface);
    defer c.cairo_destroy(cr);
    c.cairo_set_source_rgba(cr, 1, 0, 0, 0.5);
    c.cairo_paint(cr);
    try std.testing.expectEqual(@as(c_uint, c.CAIRO_STATUS_SUCCESS), c.cairo_surface_write_to_png(surface, &path));
    const image = try loader.load(std.mem.sliceTo(&path, 0), false);
    defer image.deinit();
    try std.testing.expectEqual(@as(i32, 2), image.w);
    try std.testing.expectEqual(@as(i32, 3), image.h);
    try std.testing.expectEqual(@as(u32, 0x80800000), image.pixels[0]);
    const reused = try loader.makeThumbnail(image);
    defer reused.deinit();
    try std.testing.expectEqual(@as(u32, 0x80800000), reused.pixels[0]);
    const thumb = try loader.load(std.mem.sliceTo(&path, 0), true);
    defer thumb.deinit();
    try std.testing.expect(thumb.w <= 240 and thumb.h <= 160);
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(fd, 0));
    try std.testing.expectError(error.UnsupportedImage, loader.load(std.mem.sliceTo(&path, 0), false));
}

test "decoder worker replaces pending navigation and wakes without polling" {
    const paths = [_][:0]const u8{ "/nonexistent/rediwm-image-a", "/nonexistent/rediwm-image-b" };
    const worker = try loader.Loader.init(&paths);
    defer worker.deinit();
    _ = worker.request(&.{.{ .index = 0 }});
    const generation = worker.request(&.{.{ .index = 1 }});
    var found = false;
    // At most one old result can already have been published when replaced.
    for (0..2) |_| {
        var fd = c.struct_pollfd{ .fd = worker.fds[0], .events = c.POLLIN, .revents = 0 };
        try std.testing.expect(c.poll(&fd, 1, 5000) > 0);
        const result = worker.take() orelse return error.MissingResult;
        if (result.image) |image| image.deinit();
        if (result.generation != generation) continue;
        try std.testing.expectEqual(@as(usize, 1), result.job.index);
        try std.testing.expect(result.err != null);
        found = true;
        break;
    }
    try std.testing.expect(found);
}

test "streaming decoder enforces dimensions before full raster allocation" {
    var path = "/tmp/rediwm-images-size-XXXXXX".*;
    const fd = c.mkstemp(&path);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    defer _ = c.unlink(&path);
    // PPM exposes dimensions in its header, before any pixel data arrives.
    const header = "P6\n32769 1\n255\n";
    try std.testing.expectEqual(@as(isize, header.len), c.write(fd, header.ptr, header.len));
    const raster = [_]u8{0} ** (32769 * 3);
    try std.testing.expectEqual(@as(isize, raster.len), c.write(fd, &raster, raster.len));
    try std.testing.expectError(error.ImageTooLarge, loader.load(std.mem.sliceTo(&path, 0), false));
}
