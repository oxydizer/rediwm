const std = @import("std");
const gpa = @import("memory").gpa;
const font_fallback = @import("font_fallback.zig");
const text = @import("text.zig");
const c = text.c;
const Rect = text.Rect;
const Color = text.Color;
const Font = text.Font;
const size26 = text.size26;
const setPreferredFamilies = text.setPreferredFamilies;
const primaryId = text.primaryId;
const ensureLoaded = text.ensureLoaded;
const ensureFace = text.ensureFace;
const applySize = text.applySize;
const setSize = text.setSize;
const shape = text.shape;
const nextClusterEnd = text.nextClusterEnd;
const uncachedRun = text.uncachedRun;
const measureSensitiveWidth = text.measureSensitiveWidth;
const measureWidth = text.measureWidth;
const measureWidthF = text.measureWidthF;
const offsetAtX = text.offsetAtX;
const draw = text.draw;
const drawOpts = text.drawOpts;
const devicePixels = text.devicePixels;

test "manrope face selects Regular (400) weight, not the fvar default (200/ExtraLight)" {
    const slot = try ensureFace(.manrope);
    var coords: [1]c.FT_Fixed = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Get_Var_Design_Coordinates(slot.ft_face, 1, &coords));
    try std.testing.expectEqual(@as(c.FT_Fixed, 400 << 16), coords[0]);
}

test "fractional physical font sizes survive size caching and shaping" {
    setPreferredFamilies("", "");
    const slot = try setSize(.manrope, 13, 1.5);
    const fractional_scale = slot.ft_face.*.size.*.metrics.y_scale;
    const fractional = try shape(slot, "Rendering Settings");
    defer fractional.deinit();
    _ = try setSize(.manrope, 20, 1);
    try std.testing.expect(fractional_scale < slot.ft_face.*.size.*.metrics.y_scale);
    const rounded = try shape(slot, "Rendering Settings");
    defer rounded.deinit();
    try std.testing.expect(fractional.width < rounded.width);

    _ = try setSize(.manrope, 13, 1.5);
    try std.testing.expectEqual(fractional_scale, slot.ft_face.*.size.*.metrics.y_scale);
    const again = try shape(slot, "Rendering Settings");
    defer again.deinit();
    try std.testing.expectEqual(fractional.width, again.width);
    const integral = try setSize(.manrope, 12, 1.5);
    try std.testing.expectEqual(@as(c_ushort, 18), integral.ft_face.*.size.*.metrics.y_ppem);
}

test "text retains grayscale coverage and premultiplied opacity at output scales" {
    setPreferredFamilies("", "");
    for ([_]Font{ .manrope, .mono, .mono_bold }) |font| {
        for ([_]f32{ 1, 1.5, 2 }) |scale| {
            const width = devicePixels(180, scale);
            const height = devicePixels(32, scale);
            const pixels = try std.testing.allocator.alloc(u32, @intCast(width * height));
            defer std.testing.allocator.free(pixels);
            @memset(pixels, 0);
            try draw(pixels, width, height, .{ .x = 1, .y = 1, .w = 178, .h = 30 }, "Aaeg 0123456789", .{ .r = 1, .g = 0.5, .b = 0.25, .a = 0.5 }, scale, font, 13);
            var levels: [129]bool = @splat(false);
            for (pixels) |pixel| {
                const alpha = pixel >> 24;
                const red = (pixel >> 16) & 255;
                const green = (pixel >> 8) & 255;
                const blue = pixel & 255;
                try std.testing.expect(alpha <= 128);
                try std.testing.expectEqual(alpha, red);
                try std.testing.expect(green <= red and blue <= green);
                try std.testing.expect(@abs(@as(i32, @intCast(green * 2)) - @as(i32, @intCast(red))) <= 1);
                levels[alpha] = true;
            }
            var intermediate: usize = 0;
            for (levels[1..128]) |present| intermediate += @intFromBool(present);
            try std.testing.expect(intermediate > 32);
        }
    }
}

test "accelerator underline follows its shaped cluster and uses the supplied color" {
    setPreferredFamilies("", "");
    const width: i32 = 120;
    const height: i32 = 40;
    const count: usize = @intCast(width * height);
    const plain = try std.testing.allocator.alloc(u32, count);
    defer std.testing.allocator.free(plain);
    const marked = try std.testing.allocator.alloc(u32, count);
    defer std.testing.allocator.free(marked);
    @memset(plain, 0);
    @memset(marked, 0);

    const rect: Rect = .{ .x = 4, .y = 0, .w = 110, .h = 40 };
    const ink: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const accent: Color = .{ .r = 1, .g = 0, .b = 0, .a = 1 };
    try drawOpts(plain, width, height, "Merge", ink, 1, .manrope, 16, .{ .rect = rect });
    try drawOpts(marked, width, height, "Merge", ink, 1, .manrope, 16, .{
        .rect = rect,
        .accelerator = .{ .byte_offset = 1, .color = accent },
    });

    var found_accent_pixel = false;
    for (marked) |pixel| {
        const red = (pixel >> 16) & 255;
        const green = (pixel >> 8) & 255;
        const blue = pixel & 255;
        if (red > 0 and green == 0 and blue == 0) {
            found_accent_pixel = true;
            break;
        }
    }
    try std.testing.expect(found_accent_pixel);
}

test "italic glyphs have separate cached rasters and leave upright faces unchanged" {
    setPreferredFamilies("", "");
    const color: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    for ([_]Font{ .manrope, .manrope_heavy }) |font| {
        for ([_]f32{ 1, 1.5 }) |scale| {
            const width = devicePixels(180, scale);
            const height = devicePixels(40, scale);
            const count: usize = @intCast(width * height);
            const upright = try std.testing.allocator.alloc(u32, count);
            defer std.testing.allocator.free(upright);
            const italic = try std.testing.allocator.alloc(u32, count);
            defer std.testing.allocator.free(italic);
            const again = try std.testing.allocator.alloc(u32, count);
            defer std.testing.allocator.free(again);
            @memset(upright, 0);
            @memset(italic, 0);
            @memset(again, 0);
            const rect: Rect = .{ .x = 6, .y = 0, .w = 165, .h = 40 };
            try drawOpts(upright, width, height, "12:59 AM", color, scale, font, 18, .{ .rect = rect });
            try drawOpts(italic, width, height, "12:59 AM", color, scale, font, 18, .{ .rect = rect, .italic = true });
            try drawOpts(again, width, height, "12:59 AM", color, scale, font, 18, .{ .rect = rect });
            try std.testing.expect(!std.mem.eql(u32, upright, italic));
            try std.testing.expectEqualSlices(u32, upright, again);
        }
    }
}

test "offsetAtX inverts measureWidthF and rounds to the nearer character edge" {
    setPreferredFamilies("", "");
    const value = "hello world";
    // Every boundary maps back to itself when probed at its own pen position.
    var index: usize = 0;
    while (index <= value.len) : (index += 1) {
        const pen = try measureWidthF(value[0..index], .manrope, 13, 1);
        try std.testing.expectEqual(index, try offsetAtX(value, .manrope, 13, 1, pen));
    }

    // Left of the run and past its end clamp rather than going out of bounds.
    try std.testing.expectEqual(@as(usize, 0), try offsetAtX(value, .manrope, 13, 1, -100));
    try std.testing.expectEqual(value.len, try offsetAtX(value, .manrope, 13, 1, 100_000));

    // Past a character's midpoint the caret belongs after it, not before:
    // this is what makes clicking the right half of a glyph feel right.
    const first = try measureWidthF(value[0..1], .manrope, 13, 1);
    try std.testing.expectEqual(@as(usize, 0), try offsetAtX(value, .manrope, 13, 1, first * 0.4));
    try std.testing.expectEqual(@as(usize, 1), try offsetAtX(value, .manrope, 13, 1, first * 0.6));
}

test "offsetAtX lands on codepoint boundaries in multi-byte text" {
    setPreferredFamilies("", "");
    const value = "aé漢";
    var seen: usize = 0;
    var x: f32 = 0;
    while (x < 60) : (x += 0.5) {
        const offset = try offsetAtX(value, .manrope, 13, 1, x);
        // 1, 3 and 6 are the only interior boundaries; anything else would be
        // a caret inside a codepoint.
        try std.testing.expect(offset == 0 or offset == 1 or offset == 3 or offset == 6);
        seen = @max(seen, offset);
    }
    try std.testing.expectEqual(value.len, seen);
}

test "lock revealed password never enters the text run cache" {
    const password = "private-lock-test-7é";
    const before = text.run_cache.count();
    _ = try measureSensitiveWidth(password, .manrope, 20, 1);
    var pixels: [400 * 50]u32 = @splat(0);
    try drawOpts(&pixels, 400, 50, password, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 1, .manrope, 20, .{ .rect = .{ .x = 0, .y = 0, .w = 400, .h = 50 }, .sensitive = true });
    try std.testing.expectEqual(before, text.run_cache.count());
}

test "ZWJ emoji sequence and flags stay one cluster" {
    const family = "👨‍👩‍👧";
    try std.testing.expectEqual(family.len, nextClusterEnd(family, 0));
    try std.testing.expectEqual(@as(usize, 1), nextClusterEnd("ab", 0));
    try std.testing.expectEqual(@as(usize, 2), nextClusterEnd("ab", 1));
    const flag = "🇺🇸";
    try std.testing.expectEqual(flag.len, nextClusterEnd(flag, 0));
    const acute = "e\u{0301}";
    try std.testing.expectEqual(acute.len, nextClusterEnd(acute, 0));
}

test "repeated draws of the same glyph match" {
    setPreferredFamilies("", "");
    var first: [56 * 26]u32 = @splat(0);
    var second: [56 * 26]u32 = @splat(0);
    const color = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const rect = Rect{ .x = 0, .y = 0, .w = 56, .h = 26 };
    try draw(&first, 56, 26, rect, "S", color, 1, .manrope_bold, 11.5);
    try draw(&second, 56, 26, rect, "S", color, 1, .manrope_bold, 11.5);
    try std.testing.expectEqualSlices(u32, &first, &second);
}

test "ASCII stays on the bundled face" {
    setPreferredFamilies("", "");
    const before = text.faces.items.len;
    const text_s = "Selected icon";
    const w = try measureWidth(text_s, .manrope_bold, 11.5, 1);
    try std.testing.expectEqual(before, text.faces.items.len);
    try std.testing.expectEqual(@intFromEnum(Font.manrope), primaryId(.manrope));
    try std.testing.expectEqual(@intFromEnum(Font.manrope_bold), primaryId(.manrope_bold));
    const slot = try ensureFace(.manrope_bold);
    try applySize(slot, size26(11.5, 1));
    const shaped = try shape(slot, text_s);
    defer shaped.deinit();
    const run = try uncachedRun(.manrope_bold, size26(11.5, 1), text_s);
    defer gpa.free(run.glyphs);
    try std.testing.expectEqual(shaped.width, run.width);
    try std.testing.expect(w > 0);
}

test "preferred family becomes primary when installed" {
    const cand = font_fallback.matchFamily(std.testing.allocator, "Noto Sans", 400) orelse return error.SkipZigTest;
    cand.deinit(std.testing.allocator);
    setPreferredFamilies("", "");
    defer setPreferredFamilies("", "");
    try std.testing.expectEqual(@intFromEnum(Font.manrope), primaryId(.manrope));
    setPreferredFamilies("Noto Sans", "");
    const id = primaryId(.manrope);
    try std.testing.expect(id != @intFromEnum(Font.manrope));
    const face = try ensureLoaded(id);
    const name = std.mem.span(face.ft_face.*.family_name);
    try std.testing.expect(std.mem.indexOf(u8, name, "Noto") != null);
}

test "color emoji fallback paints its own colours" {
    setPreferredFamilies("", "");
    const cand = font_fallback.findCovering(std.testing.allocator, "sans-serif", 400, 0x1F44B, true) orelse return error.SkipZigTest;
    cand.deinit(std.testing.allocator);

    var pixels: [200 * 40]u32 = @splat(0);
    try draw(&pixels, 200, 40, .{ .x = 2, .y = 2, .w = 196, .h = 36 }, "Hi 👋", .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 1, .manrope, 18);
    var colorful: usize = 0;
    var ink: usize = 0;
    for (pixels) |pixel| {
        const a = pixel >> 24;
        if (a == 0) continue;
        ink += 1;
        const r = (pixel >> 16) & 255;
        const g = (pixel >> 8) & 255;
        const b = pixel & 255;
        // Coverage glyphs tinted white are grayscale (r==g==b). Color emoji
        // is not: at least some pixels have unequal channels.
        if (!(r == g and g == b)) colorful += 1;
    }
    try std.testing.expect(ink > 20);
    try std.testing.expect(colorful > 8);
}

test "Arabic fallback produces ink when a covering font is installed" {
    setPreferredFamilies("", "");
    const cand = font_fallback.findCovering(std.testing.allocator, "sans-serif", 400, 0x0645, false) orelse return error.SkipZigTest;
    cand.deinit(std.testing.allocator);

    const latin = try measureWidth("Hi", .manrope, 16, 1);
    const mixed = try measureWidth("Hi مرحبا", .manrope, 16, 1);
    try std.testing.expect(mixed > latin);

    var pixels: [240 * 36]u32 = @splat(0);
    try draw(&pixels, 240, 36, .{ .x = 2, .y = 2, .w = 236, .h = 32 }, "مرحبا", .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 1, .manrope, 16);
    var ink: usize = 0;
    for (pixels) |pixel| ink += @intFromBool(pixel >> 24 > 0);
    try std.testing.expect(ink > 20);
}

test "visible label ink stays vertically centered at taskbar sizes and scales" {
    setPreferredFamilies("", "");
    var pixels: [240 * 168]u32 = undefined;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        for ([_]i32{ 20, 34, 54, 84 }) |logical_height| {
            const width = devicePixels(120, scale);
            const height = devicePixels(logical_height, scale);
            for ([_][]const u8{ "100%", "9%", "Files", "gyp", "12:34" }) |label| {
                @memset(&pixels, 0);
                try drawOpts(&pixels, width, height, label, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, scale, .manrope, 14, .{
                    .rect = .{ .x = 0, .y = 0, .w = 120, .h = logical_height },
                    .center_ink = true,
                });
                var top = height;
                var bottom: i32 = -1;
                for (0..@intCast(height)) |y| {
                    for (0..@intCast(width)) |x| {
                        if (pixels[y * @as(usize, @intCast(width)) + x] >> 24 == 0) continue;
                        top = @min(top, @as(i32, @intCast(y)));
                        bottom = @max(bottom, @as(i32, @intCast(y)));
                    }
                }
                try std.testing.expect(bottom >= top);
                try std.testing.expect(@abs(top + bottom + 1 - height) <= 1);
            }
        }
    }
}
