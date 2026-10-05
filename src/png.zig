const std = @import("std");

// Just enough PNG to load the wallpaper: 8 bits per channel, truecolor with or
// without alpha, no interlacing. Anything else is rejected rather than guessed
// at, which keeps the decoder small enough to read in one sitting.

pub const Error = error{ InvalidPng, UnsupportedPng, ImageTooLarge };

pub const Image = struct {
    width: i32,
    height: i32,
    // Premultiplied 0xAARRGGBB, the layout wlroots expects for ARGB8888.
    pixels: []u32,
    has_alpha: bool,

    pub fn deinit(image: Image, allocator: std.mem.Allocator) void {
        allocator.free(image.pixels);
    }
};

const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], &signature))
        return error.InvalidPng;

    var width: u32 = 0;
    var height: u32 = 0;
    var channels: usize = 0;

    // The pixel data is one zlib stream cut across however many IDAT chunks the
    // encoder felt like emitting, so the pieces are stitched back together.
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);

    var offset: usize = signature.len;
    while (offset + 8 <= bytes.len) {
        const length = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        const kind = bytes[offset + 4 ..][0..4];
        const body_start = offset + 8;
        const body_end = std.math.add(usize, body_start, length) catch return error.InvalidPng;
        if (body_end + 4 > bytes.len) return error.InvalidPng;
        const body = bytes[body_start..body_end];

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (body.len < 13) return error.InvalidPng;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            if (body[8] != 8 or body[12] != 0) return error.UnsupportedPng;
            channels = switch (body[9]) {
                2 => 3,
                6 => 4,
                else => return error.UnsupportedPng,
            };
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try compressed.appendSlice(allocator, body);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }

        offset = body_end + 4; // Past the chunk's CRC.
    }

    if (width == 0 or height == 0 or channels == 0) return error.InvalidPng;
    if (width > 32768 or height > 32768 or @as(u64, width) * height > 32 * 1024 * 1024) return error.ImageTooLarge;
    if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return error.UnsupportedPng;

    const stride = @as(usize, width) * channels;
    const pixels = try allocator.alloc(u32, @as(usize, width) * height);
    errdefer allocator.free(pixels);

    // Each scanline is filtered against the one above it, so two are kept.
    const scanlines = try allocator.alloc(u8, stride * 2);
    defer allocator.free(scanlines);
    @memset(scanlines, 0);
    var previous = scanlines[0..stride];
    var current = scanlines[stride..];

    var input: std.Io.Reader = .fixed(compressed.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    const reader = &inflate.reader;

    for (0..height) |y| {
        const filter = reader.takeByte() catch return error.InvalidPng;
        reader.readSliceAll(current) catch return error.InvalidPng;
        try unfilter(filter, current, previous, channels);

        const row = pixels[y * width ..][0..width];
        for (row, 0..) |*pixel, x| {
            const sample = current[x * channels ..];
            pixel.* = if (channels == 4)
                premultiply(sample[0], sample[1], sample[2], sample[3])
            else
                0xff00_0000 |
                    (@as(u32, sample[0]) << 16) |
                    (@as(u32, sample[1]) << 8) |
                    @as(u32, sample[2]);
        }

        std.mem.swap([]u8, &previous, &current);
    }

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixels = pixels,
        .has_alpha = channels == 4,
    };
}

fn premultiply(r: u8, g: u8, b: u8, a: u8) u32 {
    if (a == 255) return 0xff00_0000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    if (a == 0) return 0;
    const alpha: u32 = a;
    const pr: u32 = (@as(u32, r) * alpha + 127) / 255;
    const pg: u32 = (@as(u32, g) * alpha + 127) / 255;
    const pb: u32 = (@as(u32, b) * alpha + 127) / 255;
    return (alpha << 24) | (pr << 16) | (pg << 8) | pb;
}

fn unfilter(filter: u8, row: []u8, previous: []const u8, bpp: usize) !void {
    switch (filter) {
        0 => {},
        1 => for (bpp..row.len) |i| {
            row[i] +%= row[i - bpp];
        },
        2 => for (row, previous) |*byte, above| {
            byte.* +%= above;
        },
        3 => for (0..row.len) |i| {
            const left: u16 = if (i >= bpp) row[i - bpp] else 0;
            row[i] +%= @intCast((left + previous[i]) / 2);
        },
        4 => for (0..row.len) |i| {
            const left: u8 = if (i >= bpp) row[i - bpp] else 0;
            const upper_left: u8 = if (i >= bpp) previous[i - bpp] else 0;
            row[i] +%= paeth(left, previous[i], upper_left);
        },
        else => return error.InvalidPng,
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const estimate = @as(i16, a) + @as(i16, b) - @as(i16, c);
    const da = @abs(estimate - @as(i16, a));
    const db = @abs(estimate - @as(i16, b));
    const dc = @abs(estimate - @as(i16, c));
    if (da <= db and da <= dc) return a;
    if (db <= dc) return b;
    return c;
}
