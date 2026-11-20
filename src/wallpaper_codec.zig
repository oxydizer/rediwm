//! Wallpaper decoding without GdkPixbuf: `wallpaper_codec.c` reads PNG, JPEG
//! and WebP in-process (GdkPixbuf 2.44 starts a sandboxed glycin loader
//! process for every decode). The raster is allocated here, with the caller's
//! allocator, and the codec fills it. Safe from any thread.
const std = @import("std");
const png = @import("png.zig");
const c = @import("c_wallpaper_codec");

/// Per edge, as a texture can be no larger, and in total (about 400 MiB of
/// pixels): a hostile header must not be able to ask for more.
pub const max_edge = 16384;
pub const max_pixels = 100 << 20;

pub const Error = error{ UnsupportedImage, ImageTooLarge, InvalidImage };

/// Premultiplied 0xAARRGGBB pixels of a PNG, JPEG or still WebP, chosen by
/// content. The caller owns `pixels`.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !png.Image {
    var size: c.wc_info = undefined;
    try check(c.wc_probe(bytes.ptr, bytes.len, &size));
    if (size.w <= 0 or size.h <= 0 or size.w > max_edge or size.h > max_edge or @as(u64, @intCast(size.w)) * @as(u64, @intCast(size.h)) > max_pixels) return error.ImageTooLarge;
    const pixels = try allocator.alloc(u32, @as(usize, @intCast(size.w)) * @as(usize, @intCast(size.h)));
    errdefer allocator.free(pixels);
    var has_alpha: c_int = 0;
    try check(c.wc_decode(bytes.ptr, bytes.len, pixels.ptr, size.w, size.h, &has_alpha));
    return .{ .width = size.w, .height = size.h, .pixels = pixels, .has_alpha = has_alpha != 0 };
}

fn check(status: c_int) Error!void {
    return switch (status) {
        c.WC_OK => {},
        c.WC_UNSUPPORTED => error.UnsupportedImage,
        c.WC_TOO_LARGE => error.ImageTooLarge,
        else => error.InvalidImage,
    };
}

test "content that is not a still PNG, JPEG or WebP is unsupported, not decoded" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedImage, decode(a, ""));
    try std.testing.expectError(error.UnsupportedImage, decode(a, "GIF89a\x01\x00\x01\x00"));
    try std.testing.expectError(error.UnsupportedImage, decode(a, "<svg xmlns='http://www.w3.org/2000/svg'/>"));
    // A signature alone is a corrupt image, never a crash.
    try std.testing.expectError(error.InvalidImage, decode(a, "\x89PNG\r\n\x1a\n"));
    try std.testing.expectError(error.InvalidImage, decode(a, "\xff\xd8\xff\xe0"));
    try std.testing.expectError(error.InvalidImage, decode(a, "RIFF\x04\x00\x00\x00WEBP"));
}

/// A PNG that stops after its first IDAT header: enough for a size, no pixels.
fn claiming(buffer: *[45]u8, width: u32, height: u32) []const u8 {
    var ihdr: [13]u8 = @splat(0);
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    @memcpy(buffer[0..8], "\x89PNG\r\n\x1a\n");
    var out: usize = 8;
    inline for (.{ .{ "IHDR", ihdr[0..] }, .{ "IDAT", ihdr[0..0] } }) |chunk| {
        std.mem.writeInt(u32, buffer[out..][0..4], chunk[1].len, .big);
        @memcpy(buffer[out + 4 ..][0..4], chunk[0]);
        @memcpy(buffer[out + 8 ..][0..chunk[1].len], chunk[1]);
        var crc: std.hash.Crc32 = .init();
        crc.update(chunk[0]);
        crc.update(chunk[1]);
        std.mem.writeInt(u32, buffer[out + 8 + chunk[1].len ..][0..4], crc.final(), .big);
        out += 12 + chunk[1].len;
    }
    return buffer[0..out];
}

test "a header claiming too large an image is refused before anything is allocated" {
    // The testing allocator would fail the test on a leak, and a failing
    // allocator proves no allocation was attempted at all.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var buffer: [45]u8 = undefined;
    try std.testing.expectError(error.ImageTooLarge, decode(failing.allocator(), claiming(&buffer, max_edge + 1, 8)));
    try std.testing.expectError(error.ImageTooLarge, decode(failing.allocator(), claiming(&buffer, 8, max_edge + 1)));
    // Each edge within bounds, the area not: 16000 x 16000 is 256 million pixels.
    try std.testing.expectError(error.ImageTooLarge, decode(failing.allocator(), claiming(&buffer, 16000, 16000)));
}
