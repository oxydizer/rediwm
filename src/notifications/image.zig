//! Image decoder for D-Bus notification `image-data` / `image_data` hint (iiibiiay).
//! Converts raw pixel blobs to premultiplied ARGB32 (0xAARRGGBB native-endian).
const std = @import("std");
const wire = @import("dbus").wire;

pub const DecodedImage = struct {
    pixels: []u32,
    width: i32,
    height: i32,

    pub fn deinit(self: *DecodedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub fn decodeImageData(reader: *wire.Reader, allocator: std.mem.Allocator) !DecodedImage {
    try reader.alignTo(8);
    const width = try reader.int(i32);
    const height = try reader.int(i32);
    const rowstride = try reader.int(i32);
    const has_alpha = try reader.boolean();
    const bits_per_sample = try reader.int(i32);
    const channels = try reader.int(i32);

    var data_reader = try reader.array(1);
    const raw_len = data_reader.bytes.len - data_reader.offset;
    const raw_data = try data_reader.take(raw_len);

    if (width <= 0 or height <= 0 or width > 1024 or height > 1024) return error.InvalidImageDimensions;
    if (bits_per_sample != 8) return error.UnsupportedBitsPerSample;
    if (channels != 3 and channels != 4) return error.UnsupportedChannels;
    if (rowstride < width * channels) return error.InvalidRowstride;

    const min_len = @as(usize, @intCast(height - 1)) * @as(usize, @intCast(rowstride)) + @as(usize, @intCast(width * channels));
    if (raw_data.len < min_len) return error.TruncatedImageData;

    const total_pixels = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
    const pixels = try allocator.alloc(u32, total_pixels);
    errdefer allocator.free(pixels);

    const w_usize: usize = @intCast(width);
    const h_usize: usize = @intCast(height);
    const stride_usize: usize = @intCast(rowstride);
    const chan_usize: usize = @intCast(channels);

    var y: usize = 0;
    while (y < h_usize) : (y += 1) {
        const row_start = y * stride_usize;
        var x: usize = 0;
        while (x < w_usize) : (x += 1) {
            const px_start = row_start + x * chan_usize;
            const r = raw_data[px_start];
            const g = raw_data[px_start + 1];
            const b = raw_data[px_start + 2];
            const a: u8 = if (has_alpha and channels == 4) raw_data[px_start + 3] else 255;

            // Premultiply RGB by A (native-endian 0xAARRGGBB) per AGENTS.md, "Rendering"
            const argb = if (a == 255)
                (@as(u32, 255) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b)
            else if (a == 0)
                0
            else blk: {
                const pr: u32 = @divTrunc(@as(u32, r) * a + 127, 255);
                const pg: u32 = @divTrunc(@as(u32, g) * a + 127, 255);
                const pb: u32 = @divTrunc(@as(u32, b) * a + 127, 255);
                break :blk (@as(u32, a) << 24) | (pr << 16) | (pg << 8) | pb;
            };

            pixels[y * w_usize + x] = argb;
        }
    }

    return DecodedImage{
        .pixels = pixels,
        .width = width,
        .height = height,
    };
}

test "decodeImageData converts RGB and RGBA into premultiplied ARGB32" {
    const allocator = std.testing.allocator;

    // Test 1: 2x2 RGB (channels=3, has_alpha=false, stride=6)
    {
        var writer: wire.Writer = .{ .allocator = allocator };
        defer writer.deinit();

        try writer.alignTo(8);
        try writer.int(i32, 2); // width
        try writer.int(i32, 2); // height
        try writer.int(i32, 6); // rowstride
        try writer.boolean(false); // has_alpha
        try writer.int(i32, 8); // bits_per_sample
        try writer.int(i32, 3); // channels

        const arr = try writer.beginArray(1);
        // Row 0: (255, 0, 0), (0, 255, 0)
        try writer.byte(255); try writer.byte(0); try writer.byte(0);
        try writer.byte(0); try writer.byte(255); try writer.byte(0);
        // Row 1: (0, 0, 255), (255, 255, 255)
        try writer.byte(0); try writer.byte(0); try writer.byte(255);
        try writer.byte(255); try writer.byte(255); try writer.byte(255);
        try writer.endArray(arr);

        var reader: wire.Reader = .{ .bytes = writer.bytes.items, .endian = .little };
        var img = try decodeImageData(&reader, allocator);
        defer img.deinit(allocator);

        try std.testing.expectEqual(@as(i32, 2), img.width);
        try std.testing.expectEqual(@as(i32, 2), img.height);
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), img.pixels[0]); // Red
        try std.testing.expectEqual(@as(u32, 0xFF00FF00), img.pixels[1]); // Green
        try std.testing.expectEqual(@as(u32, 0xFF0000FF), img.pixels[2]); // Blue
        try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), img.pixels[3]); // White
    }

    // Test 2: 1x1 RGBA with 50% alpha (channels=4, has_alpha=true, stride=4)
    {
        var writer: wire.Writer = .{ .allocator = allocator };
        defer writer.deinit();

        try writer.alignTo(8);
        try writer.int(i32, 1);
        try writer.int(i32, 1);
        try writer.int(i32, 4);
        try writer.boolean(true);
        try writer.int(i32, 8);
        try writer.int(i32, 4);

        const arr = try writer.beginArray(1);
        // (200, 100, 50, 128)
        try writer.byte(200); try writer.byte(100); try writer.byte(50); try writer.byte(128);
        try writer.endArray(arr);

        var reader: wire.Reader = .{ .bytes = writer.bytes.items, .endian = .little };
        var img = try decodeImageData(&reader, allocator);
        defer img.deinit(allocator);

        try std.testing.expectEqual(@as(i32, 1), img.width);
        try std.testing.expectEqual(@as(i32, 1), img.height);
        const a: u32 = 128;
        const pr: u32 = @divTrunc(@as(u32, 200) * 128 + 127, 255);
        const pg: u32 = @divTrunc(@as(u32, 100) * 128 + 127, 255);
        const pb: u32 = @divTrunc(@as(u32, 50) * 128 + 127, 255);
        const expected = (a << 24) | (pr << 16) | (pg << 8) | pb;
        try std.testing.expectEqual(expected, img.pixels[0]);
    }
}
