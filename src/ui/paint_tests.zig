//! UI paint tests.

const std = @import("std");
const layout = @import("layout.zig");
const Widget = layout.Widget;
const RectStyle = layout.RectStyle;
const TextStyle = layout.TextStyle;
const overPremultiplied = @import("paint_image.zig").overPremultiplied;
const boxSample = @import("paint_image.zig").boxSample;
const blendPremultipliedPixel = @import("paint_image.zig").blendPremultipliedPixel;
const paintButton = @import("paint_widgets.zig").paintButton;
const paintTextInput = @import("paint_widgets.zig").paintTextInput;
const intersectClip = @import("paint_widgets.zig").intersectClip;
const anim = @import("paint.zig").anim;
const text_mod = @import("paint.zig").text_mod;
const theme = @import("paint.zig").theme;
const ui_input = @import("paint.zig").ui_input;
const Dispatcher = @import("input.zig").Dispatcher;
const field_widget = @import("paint.zig").field_widget;
const ClipRect = @import("paint.zig").ClipRect;
const Image = @import("paint.zig").Image;
const RoundedFill = @import("paint.zig").RoundedFill;
const blendConstOver = @import("paint.zig").blendConstOver;
const Renderer = @import("paint.zig").Renderer;
const toColor = @import("paint.zig").toColor;
const blendPixel = @import("paint.zig").blendPixel;
const paint = @import("paint.zig").paint;
const paintTree = @import("paint.zig").paintTree;
const byte = @import("paint.zig").byte;

test "scroll underlay paints beneath rows, which skip their own fill when told to" {
    const Hook = struct {
        fn paint(_: ?*anyopaque, scroll: *const Widget, r: *Renderer) void {
            r.fillRect(scroll.computed_x, scroll.computed_y, scroll.computed_width, 10, .{ .color = .{ 1, 0, 0, 1 } });
        }
    };
    var pixels = @as([20 * 20]u32, @splat(0));
    var r = Renderer.init(&pixels, 20, 20, 1);
    var row = Widget{
        .kind = .{ .row = .{ .selected = true, .underlay = true } },
        .computed_x = 0,
        .computed_y = 0,
        .computed_width = 20,
        .computed_height = 20,
    };
    var kids = [_]Widget{row};
    var scroll = Widget{
        .kind = .{ .scroll_container = .{ .underlay = .{ .owner = null, .paint = Hook.paint } } },
        .children = &kids,
        .computed_x = 0,
        .computed_y = 0,
        .computed_width = 20,
        .computed_height = 20,
    };
    paintTree(&scroll, &r);
    // The underlay's red band survives; the underlay row drew nothing over it.
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[5 * 20 + 5]);
    // Below the band nothing was drawn: an ordinary selected row would have.
    try std.testing.expectEqual(@as(u32, 0), pixels[15 * 20 + 10]);
    // A sidebar rect uses the same hook without becoming a scroll viewport.
    scroll.kind = .{ .rect = .{ .color = .{ 0, 0, 1, 1 } } };
    scroll.underlay = .{ .owner = null, .paint = Hook.paint };
    @memset(&pixels, 0);
    paintTree(&scroll, &r);
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[5 * 20 + 5]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[15 * 20 + 10]);
    scroll.kind = .{ .scroll_container = .{ .underlay = scroll.underlay } };
    scroll.underlay = null;
    row.kind.row.underlay = false;
    kids[0] = row;
    @memset(&pixels, 0);
    paintTree(&scroll, &r);
    try std.testing.expect(pixels[15 * 20 + 10] != 0);
}

test "fillRect paints solid color inside a device-pixel buffer" {
    var pixels = @as([10 * 10]u32, @splat(0));
    var r = Renderer.init(&pixels, 10, 10, 1);
    r.fillRect(1, 1, 4, 4, .{ .color = .{ 1, 0, 0, 1 } });
    // Center of the fill should be fully opaque red; a corner outside it stays clear.
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[3 * 10 + 3]);
    try std.testing.expectEqual(@as(u32, 0), pixels[0]);
}

test "fillRect respects the active clip rect" {
    var pixels = @as([10 * 10]u32, @splat(0));
    var r = Renderer.init(&pixels, 10, 10, 1);
    r.clip = .{ .x = 0, .y = 0, .w = 5, .h = 10 };
    r.fillRect(0, 0, 10, 10, .{ .color = .{ 1, 1, 1, 1 } });
    try std.testing.expect(pixels[5 * 10 + 2] != 0); // column 2: inside the 5px-wide clip
    try std.testing.expectEqual(@as(u32, 0), pixels[5 * 10 + 7]); // column 7: outside it
}

test "replacement fills preserve alpha, rounded corners and damage clips" {
    for ([_]f32{ 1, 1.5 }) |scale| {
        var pixels = @as([30 * 30]u32, @splat(0xffeeeeee));
        var r = Renderer.init(&pixels, 30, 30, scale);
        const style: RectStyle = .{ .color = .{ 0.4, 0.2, 0.1, 0.5 }, .radius = 4, .replace = true };
        r.fillRect(2, 2, 16, 16, style);
        const centre: usize = @intFromFloat(10 * scale);
        try std.testing.expectEqual(@as(u32, 128), pixels[centre * 30 + centre] >> 24);
        try std.testing.expectEqual(@as(u32, 0xffeeeeee), pixels[0]);
        const corner: usize = @intFromFloat(2 * scale);
        try std.testing.expectEqual(@as(u32, 0xffeeeeee), pixels[corner * 30 + corner]);
        const expected = pixels;
        r.damage_clip = .{ .x = 8, .y = 8, .w = 4, .h = 4 };
        r.fillRect(2, 2, 16, 16, style);
        try std.testing.expectEqualSlices(u32, &expected, &pixels);
    }
}

test "rounded fill spans match per-pixel shading at fractional scales" {
    const cases = [_]struct { w: f32, h: f32, radius: f32, border: f32 }{
        .{ .w = 44, .h = 24, .radius = 8, .border = 1 },
        .{ .w = 24, .h = 44, .radius = 8, .border = 1 },
        .{ .w = 44, .h = 24, .radius = 0, .border = 0 },
        .{ .w = 44, .h = 24, .radius = 8, .border = 0.5 },
        .{ .w = 44, .h = 24, .radius = 2, .border = 4 },
        .{ .w = 44, .h = 24, .radius = 80, .border = 1 },
        .{ .w = 3, .h = 4, .radius = 1.5, .border = 1 },
        .{ .w = 3, .h = 4, .radius = 2, .border = 3 },
    };
    var actual: [96 * 96]u32 = undefined;
    var expected: [96 * 96]u32 = undefined;
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        for ([_]f32{ 2, 2.3 }) |origin| {
            for (cases) |case| {
                for ([_]u32{ 0, 0xff182430, 0x80402010 }) |background| {
                    for ([_]f32{ 0.09, 0.78, 1 }) |alpha| {
                        @memset(&actual, background);
                        @memset(&expected, background);
                        var renderer = Renderer.init(&actual, 96, 96, scale);
                        renderer.clean = background == 0;
                        // Exercise both uncut corners and a clip through them.
                        if (origin != 2) renderer.clip = .{ .x = 5.2, .y = 3.7, .w = 33.1, .h = 35.4 };
                        const style: RectStyle = .{
                            .color = .{ 0.2, 0.6, 0.9, alpha },
                            .radius = case.radius,
                            .border_width = case.border,
                            .border_color = .{ 0.8, 0.1, 0.3, 0.35 },
                        };
                        renderer.fillRect(origin, origin, case.w, case.h, style);
                        const shape: RoundedFill = .{
                            .box_x = origin * scale,
                            .box_y = origin * scale,
                            .box_w = case.w * scale,
                            .box_h = case.h * scale,
                            .radius = case.radius * scale,
                            .border = case.border * scale,
                            .fg = toColor(style.color),
                            .border_color = toColor(style.border_color),
                        };
                        var clip = ClipRect{ .x = origin, .y = origin, .w = case.w, .h = case.h };
                        clip = intersectClip(renderer.clip, clip);
                        const x0: usize = @intFromFloat(@floor(clip.x * scale));
                        const y0: usize = @intFromFloat(@floor(clip.y * scale));
                        const x1: usize = @intFromFloat(@ceil((clip.x + clip.w) * scale));
                        const y1: usize = @intFromFloat(@ceil((clip.y + clip.h) * scale));
                        // Empty logical clips can have a nonempty rounded pixel
                        // extent; match fillRect's device clipping convention.
                        for (y0..y1) |y| {
                            for (x0..x1) |x| {
                                shape.shade(&expected, y * 96 + x, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
                            }
                        }
                        for (actual, expected) |got, want| {
                            // Integer source-over and the float reference can
                            // differ by one quantization level, as above.
                            for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                                const a: i32 = @intCast((got >> shift) & 255);
                                const b: i32 = @intCast((want >> shift) & 255);
                                try std.testing.expect(@abs(a - b) <= 1);
                            }
                            try std.testing.expect((got & 255) <= (got >> 24));
                            try std.testing.expect(((got >> 8) & 255) <= (got >> 24));
                            try std.testing.expect(((got >> 16) & 255) <= (got >> 24));
                        }
                    }
                }
            }
        }
    }
}

test "prototype button states retain neutral premultiplied fills" {
    const saved = theme.global;
    defer theme.global = saved;
    theme.global = .{};
    var pixels = @as([30 * 30]u32, @splat(0));
    var renderer = Renderer.init(&pixels, 30, 30, 1);
    const Callback = struct {
        fn call(_: ?*anyopaque, _: usize) void {}
    };
    const widget = Widget{ .kind = .container, .computed_width = 30, .computed_height = 30 };
    paintButton(&widget, .{ .label = "", .on_click = Callback.call }, &renderer);
    try std.testing.expectEqual(@as(u32, 0x0d0d0d0d), pixels[15 * 30 + 15]);
    @memset(&pixels, 0);
    paintButton(&widget, .{ .label = "", .on_click = Callback.call, .state = .hover }, &renderer);
    try std.testing.expectEqual(@as(u32, 0x14141414), pixels[15 * 30 + 15]);
    @memset(&pixels, 0);
    paintButton(&widget, .{ .variant = .ghost, .label = "", .on_click = Callback.call }, &renderer);
    try std.testing.expectEqual(@as(u32, 0), pixels[15 * 30 + 15]);
    @memset(&pixels, 0);
    paintButton(&widget, .{ .variant = .ghost, .label = "", .on_click = Callback.call, .state = .hover }, &renderer);
    try std.testing.expectEqual(@as(u32, 0x14141414), pixels[15 * 30 + 15]);
}

test "translucent interior blend matches the float path within a unit" {
    // The interior fast path and the edge/corner path meet along every fill's
    // border, so their results have to agree to the eye: check the integer
    // blend never drifts more than one 8-bit step from blendPixel's float.
    const alphas = [_]f32{ 0.06, 0.3, 0.5, 0.78, 0.95 };
    for (alphas) |a| {
        const color: text_mod.Color = .{ .r = 0.2, .g = 0.6, .b = 0.9, .a = a };
        const alpha8 = byte(color.a);
        const inv = 255 - alpha8;
        const premul = (alpha8 << 24) | (byte(color.r * color.a) << 16) |
            (byte(color.g * color.a) << 8) | byte(color.b * color.a);
        for ([_]u32{ 0x00000000, 0xff000000, 0xffffffff, 0x80402010, 0x7f7f7f7f }) |dst| {
            var reference = dst;
            blendPixel(&reference, color, 1);
            const fast = blendConstOver(dst, premul, inv);
            for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                const want: i32 = @intCast((reference >> shift) & 0xff);
                const got: i32 = @intCast((fast >> shift) & 0xff);
                try std.testing.expect(@abs(want - got) <= 1);
            }
        }
    }
}

test "premultiplied blit matches the float path within a unit" {
    for ([_]u32{ 0x00000000, 0x40201008, 0x80402010, 0xff3366aa, 0xffffffff }) |sample| {
        for ([_]u32{ 0x00000000, 0xff000000, 0xffffffff, 0x9a123456 }) |dst| {
            var reference = dst;
            blendPremultipliedPixel(&reference, sample, 1);
            const fast = overPremultiplied(dst, sample);
            for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                const want: i32 = @intCast((reference >> shift) & 0xff);
                const got: i32 = @intCast((fast >> shift) & 0xff);
                try std.testing.expect(@abs(want - got) <= 1);
            }
        }
    }
}

test "secret input widget never retains hidden or echo-on responses in run cache" {
    var bytes: [510]u8 = @splat(0);
    var field = @import("widgets/secret_input.zig").Input{ .storage = &bytes };
    defer field.clear();
    try std.testing.expect(field.insert("fixture-sensitive-response"));
    var pixels: [400 * 50]u32 = @splat(0);
    var renderer = Renderer.init(&pixels, 400, 50, 1);
    const before = text_mod.testingRunCacheCount();
    _ = field.paint(&renderer, 0, 0, 80, 42, 18, .{ .hidden = true, .caret = true, .placeholder = "" });
    _ = field.paint(&renderer, 0, 0, 80, 42, 18, .{ .hidden = false, .caret = true, .placeholder = "" });
    // And through the shared field, frame and all.
    _ = field_widget.paintSecret(&renderer, .{ .x = 0, .y = 0, .w = 400, .h = 50 }, .{ .size = .lg, .trailing = .reveal }, .{ .focused = true }, &field, "");
    _ = field_widget.paintSecret(&renderer, .{ .x = 0, .y = 0, .w = 400, .h = 50 }, .{ .size = .lg, .trailing = .reveal }, .{ .focused = true, .revealed = true }, &field, "");
    // Dotted masking: the caret keeps the field font's height, hidden or not.
    const box: field_widget.Rect = .{ .x = 0, .y = 0, .w = 400, .h = 50 };
    const dotted: field_widget.Options = .{ .size = .lg, .secret_dots = .{ .diameter = 0.46, .pitch = 1.05 } };
    const hidden = field_widget.paintSecret(&renderer, box, dotted, .{ .focused = true }, &field, "").caret.?;
    const clear = field_widget.paintSecret(&renderer, box, dotted, .{ .focused = true, .revealed = true }, &field, "").caret.?;
    try std.testing.expectEqual(clear.h, hidden.h);
    try std.testing.expectEqual(clear.y, hidden.y);
    try std.testing.expectEqual(before, text_mod.testingRunCacheCount());
}

// A partially scrolled row must retain the same glyph positions as the full row.
test "text clipping preserves layout at scroll edges" {
    // The accented query expands/folds to original UTF-8 boundaries.
    for ([_]f32{ 1, 1.5 }) |scale| {
        var full: [240 * 90]u32 = @splat(0);
        var clipped: [240 * 90]u32 = @splat(0);
        var r = Renderer.init(&full, 240, 90, scale);
        const style: TextStyle = .{ .content = "Cámara Straße", .highlight_query = "CAMARA STRASSE", .font_size = 16, .color = .{ 1, 1, 1, 1 } };
        r.drawText(4, 4, 140, 34, style);
        r.pixels = &clipped;
        r.clip = .{ .x = 18, .y = 20, .w = 90, .h = 12 };
        r.drawText(4, 4, 140, 34, style);
        const clip = r.textClip(r.clip).?;
        var ink: usize = 0;
        for (clipped, 0..) |pixel, i| {
            const x: i32 = @intCast(i % 240);
            const y: i32 = @intCast(i / 240);
            const inside = x >= clip.x and x < clip.x + clip.w and y >= clip.y and y < clip.y + clip.h;
            try std.testing.expectEqual(if (inside) full[i] else 0, pixel);
            if (pixel != 0) ink += 1;
        }
        try std.testing.expect(ink > 0);
    }
}

test "typing reveals text behind the gliding caret and preserves the suffix" {
    const saved_dispatcher = ui_input.active_dispatcher;
    defer ui_input.active_dispatcher = saved_dispatcher;
    const saved_config = ui_input.caret_config;
    defer ui_input.caret_config = saved_config;
    defer anim.setNowMs(null);
    ui_input.caret_config = .{ .motion_ms = 80 };

    for ([_]f32{ 1, 1.5 }) |scale| {
        for ([_][]const u8{ "ab", "abcd" }) |value| {
            var widget = Widget{ .kind = .{ .text_input = .{
                .value = try std.testing.allocator.dupe(u8, if (value.len == 2) "a" else "acd"),
                .placeholder = "",
                .cursor_pos = 1,
                .on_change = struct {
                    fn changed(_: ?*anyopaque, _: usize, _: []const u8) void {}
                }.changed,
            } }, .computed_width = 150, .computed_height = 40 };
            defer std.testing.allocator.free(widget.kind.text_input.value);
            var dispatcher = ui_input.Dispatcher{ .focused = &widget };
            ui_input.active_dispatcher = &dispatcher;
            var background: [240 * 90]u32 = @splat(0);
            var first = background;
            var middle = background;
            var complete = background;
            var r = Renderer.init(&background, 240, 90, scale);
            // Hide only the caret's ink so the comparison isolates the text.
            r.palette = theme.Theme{ .caret = .{ 0, 0, 0, 0 } };
            const frame = field_widget.paintFrame(&r, .{ .x = 0, .y = 0, .w = 150, .h = 40 }, .{}, .{ .focused = true });
            const start = try text_mod.measureWidthF("a", .manrope, frame.font_size, scale);
            const target = try text_mod.measureWidthF("ab", .manrope, frame.font_size, scale);
            dispatcher.caret.track(0, start);

            anim.setNowMs(1000);
            _ = try dispatcher.keyEvent(std.testing.allocator, .{ .char = "b" }, .{});
            r.pixels = &first;
            paintTextInput(&widget, widget.kind.text_input, &r);
            try std.testing.expect(dispatcher.caret.moving(1000));
            anim.setNowMs(1020);
            r.pixels = &middle;
            paintTextInput(&widget, widget.kind.text_input, &r);
            const mid = dispatcher.caret.offset(1020);
            try std.testing.expect(mid > start and mid < target);
            anim.setNowMs(1080);
            r.pixels = &complete;
            paintTextInput(&widget, widget.kind.text_input, &r);

            var hidden_ink: usize = 0;
            var suffix_ink: usize = 0;
            const suffix_x = @ceil(frame.text.x + target) * scale;
            for (complete, 0..) |pixel, i| {
                const x: f32 = @floatFromInt(i % 240);
                const start_x = @ceil(@floor(frame.text.x + start) * scale);
                const mid_x = @ceil(@floor(frame.text.x + mid) * scale);
                if (x >= start_x and x < suffix_x) {
                    try std.testing.expectEqual(background[i], first[i]);
                    if (pixel != background[i]) hidden_ink += 1;
                }
                if (x >= mid_x and x < suffix_x)
                    try std.testing.expectEqual(background[i], middle[i]);
                if (x >= suffix_x) {
                    try std.testing.expectEqual(pixel, first[i]);
                    try std.testing.expectEqual(pixel, middle[i]);
                    if (pixel != background[i]) suffix_ink += 1;
                }
            }
            try std.testing.expect(hidden_ink > 0);
            if (value.len > 2) try std.testing.expect(suffix_ink > 0);

            // Navigation cancels the reveal: existing text stays visible.
            dispatcher.caret.noteEdit(1100);
            try std.testing.expect(!dispatcher.caret.revealing);
        }
    }
}

test "smooth image sampling is exact at one to one, blends between pixels and shrinks flat colour unchanged" {
    const black: u32 = 0xff000000;
    const white: u32 = 0xffffffff;
    const checker = [_]u32{ black, white, white, black };
    const image: Image = .{ .pixels = &checker, .width = 2, .height = 2 };
    // Centred on a source pixel, one pixel wide: that pixel, untouched.
    try std.testing.expectEqual(black, boxSample(image, 0.5, 0.5, 1));
    try std.testing.expectEqual(white, boxSample(image, 1.5, 0.5, 1));
    // Halfway between two columns: an even mix (bilinear).
    try std.testing.expectEqual(@as(u32, 0xff808080), boxSample(image, 1.0, 0.5, 1));
    // The whole image averages to mid grey whatever the footprint around its centre.
    try std.testing.expectEqual(@as(u32, 0xff808080), boxSample(image, 1.0, 1.0, 2));

    // Shrinking a flat translucent image by 1.3 keeps its premultiplied colour,
    // also at the edge, where the footprint leaves the image.
    const flat = @as([16]u32, @splat(0x80402010));
    const small: Image = .{ .pixels = &flat, .width = 4, .height = 4 };
    for ([_]f32{ 0.1, 0.5, 2, 3.9 }) |at| try std.testing.expectEqual(@as(u32, 0x80402010), boxSample(small, at, at, 1.3));

    // Placed 1:1 on a pixel boundary it reproduces the image.
    var pixels = @as([16]u32, @splat(0));
    var r = Renderer.init(&pixels, 4, 4, 1);
    r.drawImageSmooth(1, 1, 2, 2, 0, image);
    try std.testing.expectEqual(black, pixels[1 * 4 + 1]);
    try std.testing.expectEqual(white, pixels[1 * 4 + 2]);
    try std.testing.expectEqual(white, pixels[2 * 4 + 1]);
    try std.testing.expectEqual(black, pixels[2 * 4 + 2]);
}

/// A theme with relief on: depth 4, softness 6, light at the upper left, and
/// opaque shadows so the pixel checks below are unambiguous.
fn reliefTheme() theme.Theme {
    var t: theme.Theme = .{};
    t.relief_depth = 4;
    t.relief_softness = 6;
    t.relief_light_angle = 135;
    t.relief_dark = .{ 0, 0, 0, 1 };
    t.relief_light = .{ 1, 1, 1, 1 };
    return t;
}

const button_widget = @import("widgets/button.zig");

fn adaptiveButtonPixels(palette: theme.Theme, state: button_widget.State) [80 * 60]u32 {
    var pixels: [80 * 60]u32 = @splat(0xff808080);
    var renderer = Renderer.init(&pixels, 80, 60, 1);
    renderer.palette = palette;
    button_widget.paint(
        &renderer,
        .{ .x = 20, .y = 20, .w = 40, .h = 24 },
        .{ .variant = .secondary, .label = "" },
        state,
    );
    return pixels;
}

test "adaptive button relief transitions inset, lifts raised, and leaves flat and protected states unchanged" {
    var inset = reliefTheme();
    inset.button_relief = .inset;

    const inset_rest = adaptiveButtonPixels(inset, .{ .pointer = .hover, .hover_elevation = 0 });
    const inset_hover = adaptiveButtonPixels(inset, .{ .pointer = .hover, .hover_elevation = 1 });
    try std.testing.expect(!std.mem.eql(u32, &inset_rest, &inset_hover));

    var raised = inset;
    raised.button_relief = .raised;
    const raised_rest = adaptiveButtonPixels(raised, .{ .pointer = .hover, .hover_elevation = 0 });
    const raised_hover = adaptiveButtonPixels(raised, .{ .pointer = .hover, .hover_elevation = 1 });
    try std.testing.expect(!std.mem.eql(u32, &raised_rest, &raised_hover));

    var flat = inset;
    flat.button_relief = .flat;
    const flat_rest = adaptiveButtonPixels(flat, .{ .pointer = .hover, .hover_elevation = 0 });
    const flat_hover = adaptiveButtonPixels(flat, .{ .pointer = .hover, .hover_elevation = 1 });
    try std.testing.expectEqualSlices(u32, &flat_rest, &flat_hover);

    // Focus, selection, press and disabled treatments do not inherit elevation.
    const focused_rest = adaptiveButtonPixels(inset, .{ .pointer = .hover, .focused = true, .hover_elevation = 0 });
    const focused_hover = adaptiveButtonPixels(inset, .{ .pointer = .hover, .focused = true, .hover_elevation = 1 });
    try std.testing.expectEqualSlices(u32, &focused_rest, &focused_hover);

    const selected_rest = adaptiveButtonPixels(inset, .{ .pointer = .hover, .selected = true, .hover_elevation = 0 });
    const selected_hover = adaptiveButtonPixels(inset, .{ .pointer = .hover, .selected = true, .hover_elevation = 1 });
    try std.testing.expectEqualSlices(u32, &selected_rest, &selected_hover);

    const pressed_rest = adaptiveButtonPixels(inset, .{ .pointer = .press, .hover_elevation = 0 });
    const pressed_hover = adaptiveButtonPixels(inset, .{ .pointer = .press, .hover_elevation = 1 });
    try std.testing.expectEqualSlices(u32, &pressed_rest, &pressed_hover);

    const disabled_rest = adaptiveButtonPixels(inset, .{ .pointer = .disabled, .hover_elevation = 0 });
    const disabled_hover = adaptiveButtonPixels(inset, .{ .pointer = .disabled, .hover_elevation = 1 });
    try std.testing.expectEqualSlices(u32, &disabled_rest, &disabled_hover);
}

test "relief draws nothing while the theme's relief_depth is zero" {
    var with_relief = @as([40 * 40]u32, @splat(0xff808080));
    var without = with_relief;
    var a = Renderer.init(&with_relief, 40, 40, 1);
    a.palette = .{};
    a.fillRect(10, 10, 20, 20, .{ .color = .{ 1, 0, 0, 1 }, .radius = 4, .relief = .raised });
    var b = Renderer.init(&without, 40, 40, 1);
    b.fillRect(10, 10, 20, 20, .{ .color = .{ 1, 0, 0, 1 }, .radius = 4 });
    try std.testing.expectEqualSlices(u32, &without, &with_relief);
}

test "a raised fill casts its dark shadow away from the light and a light one toward it" {
    var pixels = @as([60 * 60]u32, @splat(0xff808080));
    var r = Renderer.init(&pixels, 60, 60, 1);
    r.palette = reliefTheme();
    r.fillRect(20, 20, 20, 20, .{ .color = .{ 0.5, 0.5, 0.5, 1 }, .radius = 4, .relief = .raised });
    // Light from the upper left: shadow below and right of the box, glow above and left.
    try std.testing.expect((pixels[41 * 60 + 41] & 0xff) < 0x80);
    try std.testing.expect((pixels[18 * 60 + 18] & 0xff) > 0x80);
    // The fill and the surface far from it are untouched.
    try std.testing.expectEqual(@as(u32, 0xff808080), pixels[30 * 60 + 30]);
    try std.testing.expectEqual(@as(u32, 0xff808080), pixels[2 * 60 + 2]);
}

test "an inset fill shades the edge facing the light and lights the opposite one" {
    var pixels = @as([60 * 60]u32, @splat(0xff808080));
    var r = Renderer.init(&pixels, 60, 60, 1);
    r.palette = reliefTheme();
    r.fillRect(20, 20, 20, 20, .{ .color = .{ 0.5, 0.5, 0.5, 1 }, .radius = 4, .relief = .inset });
    // Just inside the top edge it is dark, just inside the bottom edge light.
    try std.testing.expect((pixels[22 * 60 + 30] & 0xff) < 0x80);
    try std.testing.expect((pixels[37 * 60 + 30] & 0xff) > 0x80);
    // Neither the middle nor the surface outside the box is touched.
    try std.testing.expectEqual(@as(u32, 0xff808080), pixels[30 * 60 + 30]);
    try std.testing.expectEqual(@as(u32, 0xff808080), pixels[30 * 60 + 15]);
}

const paintSlider = @import("paint_widgets.zig").paintSlider;
const paintSegmented = @import("paint_widgets.zig").paintSegmented;
const paintSwatch = @import("paint_widgets.zig").paintSwatch;
const paintRow = @import("paint_widgets.zig").paintRow;

/// The blue channel at (`x`, `y`): shadows are black and highlights white, so
/// it is enough to tell them from the mid-grey page.
fn channel(pixels: []const u32, width: usize, x: usize, y: usize) u32 {
    return pixels[y * width + x] & 0xff;
}

/// Inset: the edge facing the light is in shadow, the far one lit.
fn expectInsetShading(flat: []const u32, cut: []const u32, width: usize, x: usize, top: usize, bottom: usize) !void {
    try std.testing.expect(channel(cut, width, x, top) < channel(flat, width, x, top));
    try std.testing.expect(channel(cut, width, x, bottom) > channel(flat, width, x, bottom));
}

/// A shaded toggle on a mid-grey page, painted with `palette`.
fn shadedToggle(palette: theme.Theme, on: bool) [80 * 60]u32 {
    var pixels = @as([80 * 60]u32, @splat(0xff808080));
    var r = Renderer.init(&pixels, 80, 60, 1);
    r.palette = palette;
    @import("widgets/toggle.zig").paint(&r, .{ .x = 20, .y = 20, .w = 36, .h = 20 }, .{ .on = on });
    return pixels;
}

test "shaded toggles take the relief keys and are untouched while they are flat" {
    var flat = reliefTheme();
    flat.toggle_shaded = true;
    var stock: theme.Theme = .{};
    stock.toggle_shaded = true;
    // Relief on in the theme but off for the control: pixel for pixel as before.
    try std.testing.expectEqualSlices(u32, &shadedToggle(stock, false), &shadedToggle(flat, false));

    // Off, the knob rests at the left: 22.8 to 37.2 across and down the track.
    const base = shadedToggle(flat, false);
    var raised = flat;
    raised.toggle_thumb_relief = .raised;
    const lit = shadedToggle(raised, false);
    // Light from the upper left: a shadow lower right of the knob, a glow upper left.
    try std.testing.expect(channel(&lit, 80, 39, 33) < channel(&base, 80, 39, 33));
    try std.testing.expect(channel(&lit, 80, 21, 30) > channel(&base, 80, 21, 30));
    // The knob's shadows never leave the track.
    try std.testing.expectEqual(@as(u32, 0xff808080), lit[42 * 80 + 30]);

    var groove = flat;
    groove.toggle_track_relief = .inset;
    const cut = shadedToggle(groove, false);
    try expectInsetShading(&base, &cut, 80, 40, 21, 38);
    // The groove's shadows skip the knob.
    try std.testing.expectEqual(base[30 * 80 + 30], cut[30 * 80 + 30]);
}

/// A shaded slider at half on a mid-grey page: the disc is 16 across, centred
/// on (60, 22), in a box from (10, 10) that is 100 by 24.
fn shadedSlider(palette: theme.Theme) [130 * 50]u32 {
    var pixels = @as([130 * 50]u32, @splat(0xff808080));
    var r = Renderer.init(&pixels, 130, 50, 1);
    r.palette = palette;
    const widget = Widget{
        .kind = .{ .slider = .{
            .style = .standard,
            .value = 0.5,
            .min = 0,
            .max = 1,
            .feel = .{},
            .on_change = struct {
                fn call(_: ?*anyopaque, _: usize, _: f32) void {}
            }.call,
        } },
        .computed_x = 10,
        .computed_y = 10,
        .computed_width = 100,
        .computed_height = 24,
    };
    paintSlider(&widget, widget.kind.slider, &r);
    return pixels;
}

fn shadedSliderTheme(track_height: f32) theme.Theme {
    var t = reliefTheme();
    t.slider_shaded = true;
    t.slider_thumb_size = 16;
    t.slider_track_height = track_height;
    return t;
}

test "shaded sliders take the relief keys, off the thumb and inside their box" {
    var flat = shadedSliderTheme(6);
    var stock: theme.Theme = .{};
    stock.slider_shaded = true;
    stock.slider_thumb_size = 16;
    stock.slider_track_height = 6;
    try std.testing.expectEqualSlices(u32, &shadedSlider(stock), &shadedSlider(flat));

    const base = shadedSlider(flat);
    flat.slider_thumb_relief = .raised;
    const lit = shadedSlider(flat);
    try std.testing.expect(channel(&lit, 130, 68, 26) < channel(&base, 130, 68, 26));
    try std.testing.expect(channel(&lit, 130, 51, 17) > channel(&base, 130, 51, 17));
    // Below the box (it ends at y = 34) the page is untouched.
    try std.testing.expectEqual(@as(u32, 0xff808080), lit[36 * 130 + 60]);

    // A rail tall enough for the groove's two shadows not to meet.
    var groove = shadedSliderTheme(14);
    const wide = shadedSlider(groove);
    groove.slider_track_relief = .inset;
    const cut = shadedSlider(groove);
    try expectInsetShading(&wide, &cut, 130, 90, 16, 27);
    // The groove's shadows skip the disc.
    try std.testing.expectEqual(wide[22 * 130 + 60], cut[22 * 130 + 60]);
}

fn paintedSegmented(palette: theme.Theme) [80 * 60]u32 {
    var pixels = @as([80 * 60]u32, @splat(0xff808080));
    var r = Renderer.init(&pixels, 80, 60, 1);
    r.palette = palette;
    const widget = Widget{
        .kind = .{ .segmented = .{ .labels = &.{}, .selected = 0, .on_change = struct {
            fn call(_: ?*anyopaque, _: usize, _: usize) void {}
        }.call } },
        .computed_x = 20,
        .computed_y = 20,
        .computed_width = 40,
        .computed_height = 24,
    };
    paintSegmented(&widget, widget.kind.segmented, &r);
    return pixels;
}

fn paintedSwatch(palette: theme.Theme) [80 * 60]u32 {
    var pixels = @as([80 * 60]u32, @splat(0xff808080));
    var r = Renderer.init(&pixels, 80, 60, 1);
    r.palette = palette;
    const widget = Widget{
        .kind = .{ .swatch = .{ .color = .{ 0.5, 0.5, 0.5, 1 }, .selected = false, .on_select = struct {
            fn call(_: ?*anyopaque, _: usize, _: [4]f32) void {}
        }.call } },
        .computed_x = 20,
        .computed_y = 20,
        .computed_width = 24,
        .computed_height = 24,
    };
    paintSwatch(&widget, widget.kind.swatch, &r);
    return pixels;
}

fn paintedRow(palette: theme.Theme, data: layout.RowData) [80 * 60]u32 {
    var pixels = @as([80 * 60]u32, @splat(0xff808080));
    var r = Renderer.init(&pixels, 80, 60, 1);
    r.palette = palette;
    const widget = Widget{ .kind = .{ .row = data }, .computed_x = 10, .computed_y = 10, .computed_width = 40, .computed_height = 30 };
    paintRow(&widget, data, &r);
    return pixels;
}

test "segmented frames, swatches and rows take their own relief keys" {
    const stock: theme.Theme = .{};
    const flat = reliefTheme();
    // Relief on in the theme, every key flat: the same pixels as a theme without it.
    try std.testing.expectEqualSlices(u32, &paintedSegmented(stock), &paintedSegmented(flat));
    try std.testing.expectEqualSlices(u32, &paintedSwatch(stock), &paintedSwatch(flat));
    try std.testing.expectEqualSlices(u32, &paintedRow(stock, .{ .selected = true }), &paintedRow(flat, .{ .selected = true }));

    var inset = flat;
    inset.segmented_relief = .inset;
    try expectInsetShading(&paintedSegmented(flat), &paintedSegmented(inset), 80, 40, 21, 42);

    var raised = flat;
    raised.swatch_relief = .raised;
    const base = paintedSwatch(flat);
    const lit = paintedSwatch(raised);
    // The swatch is 20 to 44 across and down: shadow to its lower right, glow upper left.
    try std.testing.expect(channel(&lit, 80, 45, 33) < channel(&base, 80, 45, 33));
    try std.testing.expect(channel(&lit, 80, 18, 33) > channel(&base, 80, 18, 33));

    var rows = flat;
    rows.row_selected_relief = .inset;
    try expectInsetShading(&paintedRow(flat, .{ .selected = true }), &paintedRow(rows, .{ .selected = true }), 80, 35, 11, 38);
    rows.row_hover_relief = .inset;
    try expectInsetShading(&paintedRow(flat, .{ .state = .hover }), &paintedRow(rows, .{ .state = .hover }), 80, 35, 11, 38);
}


test "dispatcher proximity illuminates raised and inset buttons" {
    for ([_]layout.Relief{ .raised, .inset }) |button_relief| {
        var children = [_]Widget{.{
            .kind = .{ .button = .{ .variant = .secondary } },
            .computed_x = 20,
            .computed_y = 20,
            .computed_width = 40,
            .computed_height = 24,
        }};
        var root: Widget = .{
            .kind = .container,
            .computed_width = 80,
            .computed_height = 60,
            .children = &children,
        };
        root.linkParents();

        var dispatcher: Dispatcher = .{};
        dispatcher.pointerMotion(&root, 40, 16);

        const button = &root.children[0];
        const sampled = button.kind.button;
        try std.testing.expectEqual(@as(f32, 4), sampled.proximity_distance);

        var palette = reliefTheme();
        palette.button_relief = button_relief;
        palette.button_hover_glow_enabled = true;
        palette.border_glow = .{ 1, 0, 0, 0.60 };
        palette.border_glow_enabled = false;
        palette.border_glow_reach = 56;
        palette.border_glow_length = 72;
        palette.border_glow_depth = 3;

        var pixels: [80 * 60]u32 = @splat(0xff808080);
        var renderer = Renderer.init(&pixels, 80, 60, 1);
        renderer.palette = palette;
        paintButton(button, sampled, &renderer);
        const illuminated = pixels;

        var without_proximity = sampled;
        without_proximity.proximity_distance = std.math.inf(f32);
        @memset(&pixels, 0xff808080);
        paintButton(button, without_proximity, &renderer);

        try std.testing.expect(!std.mem.eql(u32, &illuminated, &pixels));
    }
}

test "button hover glow is independent of window edge glow and stays rounded and clipped" {
    const sample = struct {
        fn pixel(pixels: []const u32, width: i32, scale: f32, x: f32, y: f32) u32 {
            const px: usize = @intFromFloat(@floor(x * scale));
            const py: usize = @intFromFloat(@floor(y * scale));
            return pixels[py * @as(usize, @intCast(width)) + px];
        }

        fn luma(pixel_value: u32) u32 {
            const red = (pixel_value >> 16) & 0xff;
            const green = (pixel_value >> 8) & 0xff;
            const blue = pixel_value & 0xff;
            return red * 212 + green * 715 + blue * 72;
        }
    };

    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        var pixels: [256 * 192]u32 = @splat(0xff808080);
        const width: i32 = @intFromFloat(128 * scale);
        const height: i32 = @intFromFloat(96 * scale);
        var renderer = Renderer.init(&pixels, width, height, scale);
        var palette: theme.Theme = .{};
        palette.border_glow = .{ 1, 0, 0, 0.60 };
        palette.border_glow_enabled = false;
        palette.button_hover_glow_enabled = true;
        palette.border_glow_reach = 56;
        palette.border_glow_length = 72;
        palette.border_glow_depth = 3;
        renderer.palette = palette;
        renderer.clip = .{ .x = 40, .y = 20, .w = 40, .h = 34 };

        const widget = Widget{
            .kind = .container,
            .computed_x = 20,
            .computed_y = 20,
            .computed_width = 80,
            .computed_height = 34,
        };
        paintButton(&widget, .{
            .variant = .ghost,
            .proximity_distance = 4,
            .proximity_x = 40,
            .proximity_y = -4,
        }, &renderer);

        const near = sample.pixel(&pixels, width, scale, 60.5, 20.5);
        const opposite = sample.pixel(&pixels, width, scale, 60.5, 53.5);
        const centre = sample.pixel(&pixels, width, scale, 60.5, 37.5);
        const rounded_corner = sample.pixel(&pixels, width, scale, 20.5, 20.5);
        const outside_clip = sample.pixel(&pixels, width, scale, 30.5, 30.5);

        try std.testing.expect((near >> 16) & 0xff > 0x80);
        try std.testing.expect(sample.luma(opposite) < sample.luma(0xff808080));
        try std.testing.expect((near >> 16) & 0xff > (centre >> 16) & 0xff);
        try std.testing.expectEqual(@as(u32, 0xff808080), rounded_corner);
        try std.testing.expectEqual(@as(u32, 0xff808080), outside_clip);

        // Window-edge glow being off must not suppress button glow.
        @memset(&pixels, 0xff808080);
        palette.border_glow_enabled = true;
        palette.button_hover_glow_enabled = false;
        renderer.palette = palette;
        paintButton(&widget, .{
            .variant = .ghost,
            .proximity_distance = 4,
            .proximity_x = 40,
            .proximity_y = -4,
        }, &renderer);
        const button_glow_disabled = sample.pixel(&pixels, width, scale, 60.5, 20.5);
        try std.testing.expectEqual(@as(u32, 0xff808080), button_glow_disabled);

        // An absent proximity sample must never paint a stale highlight.
        @memset(&pixels, 0xff808080);
        palette.button_hover_glow_enabled = true;
        renderer.palette = palette;
        paintButton(&widget, .{
            .variant = .ghost,
            .proximity_distance = std.math.inf(f32),
            .proximity_x = 40,
            .proximity_y = -4,
        }, &renderer);
        const no_proximity = sample.pixel(&pixels, width, scale, 60.5, 20.5);
        try std.testing.expectEqual(@as(u32, 0xff808080), no_proximity);
    }
}

test "button hover glow lights adjacent and independently reachable edges" {
    const sample = struct {
        fn red(pixels: []const u32, x: usize, y: usize) u32 {
            return (pixels[y * 200 + x] >> 16) & 0xff;
        }
    };

    var pixels: [200 * 160]u32 = @splat(0xff808080);
    var renderer = Renderer.init(&pixels, 200, 160, 1);
    var palette: theme.Theme = .{};
    palette.button_hover_glow_enabled = true;
    palette.border_glow = .{ 1, 0, 0, 0.60 };
    palette.border_glow_reach = 56;
    palette.border_glow_length = 72;
    palette.border_glow_depth = 3;
    renderer.palette = palette;

    // Above and to the right: both adjoining edges receive their own glow.
    button_widget.paint(
        &renderer,
        .{ .x = 20, .y = 20, .w = 80, .h = 34 },
        .{ .variant = .ghost },
        .{ .proximity_distance = 4, .proximity_x = 84, .proximity_y = -4 },
    );
    try std.testing.expect(sample.red(&pixels, 92, 20) > 0x80);
    try std.testing.expect(sample.red(&pixels, 99, 28) > 0x80);

    // Inside a larger button, only the nearby top and left edges light.
    @memset(&pixels, 0xff808080);
    button_widget.paint(
        &renderer,
        .{ .x = 20, .y = 20, .w = 140, .h = 120 },
        .{ .variant = .ghost },
        .{ .proximity_distance = 0, .proximity_x = 5, .proximity_y = 5 },
    );
    try std.testing.expect(sample.red(&pixels, 25, 20) > 0x80);
    try std.testing.expect(sample.red(&pixels, 20, 25) > 0x80);

    // Inside a small button, all four edges are within reach and illuminate.
    @memset(&pixels, 0xff808080);
    button_widget.paint(
        &renderer,
        .{ .x = 20, .y = 20, .w = 80, .h = 34 },
        .{ .variant = .ghost },
        .{ .proximity_distance = 0, .proximity_x = 40, .proximity_y = 17 },
    );
    try std.testing.expect(sample.red(&pixels, 60, 20) > 0x80);
    try std.testing.expect(sample.red(&pixels, 99, 37) > 0x80);
    try std.testing.expect(sample.red(&pixels, 60, 53) > 0x80);
    try std.testing.expect(sample.red(&pixels, 20, 37) > 0x80);
}
