const std = @import("std");
const theme = @import("ui").theme;
const window_chrome = @import("ui").window_chrome;
const Metrics = window_chrome.Metrics;
const title_inset = window_chrome.title_inset;
const title_icon_gap = window_chrome.title_icon_gap;
const ControlKind = window_chrome.ControlKind;
const controlRectScaled = window_chrome.controlRectScaled;
const chrome_mod = @import("chrome.zig");
const titlebarGlassMayHold = chrome_mod.titlebarGlassMayHold;
const ChromeState = chrome_mod.ChromeState;
const TitlebarMemo = chrome_mod.TitlebarMemo;
const controlSlot = chrome_mod.controlSlot;
const ChromeBuffer = chrome_mod.ChromeBuffer;
const ShadowMemo = chrome_mod.ShadowMemo;

test "titlebar glass holds only while the titlebar is at least 98% opaque" {
    const saved = theme.global.window_bg;
    defer theme.global.window_bg = saved;
    theme.global.window_bg[3] = 0.98;
    try std.testing.expect(titlebarGlassMayHold(1));
    try std.testing.expect(!titlebarGlassMayHold(0.9));
    theme.global.window_bg[3] = 250.0 / 255.0; // #rrggbbfa
    try std.testing.expect(titlebarGlassMayHold(1));
    theme.global.window_bg[3] = 0.97;
    try std.testing.expect(!titlebarGlassMayHold(1));
}

pub fn sampleTitlebarMemo() TitlebarMemo {
    return .{
        .width = 200,
        .title_ptr = null,
        .scale = 1,
        .hover = 0,
        .chip_pos = 0,
        .chip_alpha = 0,
        .maximized = false,
        .icon = null,
        .glass = .{ 0, 0, 0, 1 },
        .border = .{ 1, 1, 1, 0.09 },
        .border_soft = .{ 1, 1, 1, 0.06 },
        .fg = .{ 1, 1, 1, 1 },
        .dim = .{ 0.5, 0.5, 0.5, 1 },
        .border_hover = .{ 1, 1, 1, 0.22 },
        .surface_hover = .{ 1, 1, 1, 0.08 },
        .danger = .{ 1, 0, 0, 1 },
        .title_size = 13.5,
    };
}

test "TitlebarMemo.eql is true for identical inputs" {
    try std.testing.expect(sampleTitlebarMemo().eql(sampleTitlebarMemo()));
    const inactive = sampleTitlebarMemo();
    var active = inactive;
    active.active = true;
    try std.testing.expect(!inactive.eql(active));
    try std.testing.expect(inactive.reusableFor(active));
}

test "TitlebarMemo.eql compares the title pointer, not the string contents" {
    var a_buf = [_:0]u8{ 'h', 'e', 'l', 'l', 'o' };
    var b_buf = [_:0]u8{ 'h', 'e', 'l', 'l', 'o' };
    var left = sampleTitlebarMemo();
    var right = sampleTitlebarMemo();
    left.title_ptr = &a_buf;
    right.title_ptr = &b_buf;
    try std.testing.expect(!left.eql(right));
    right.title_ptr = &a_buf;
    try std.testing.expect(left.eql(right));
}

test "TitlebarMemo.eql compares icon identity by id, not pixel pointer" {
    var pixels_a = [_]u32{0xFF000000};
    var pixels_b = [_]u32{0xFF000000};
    var left = sampleTitlebarMemo();
    var right = sampleTitlebarMemo();

    // Same id, different backing pixel buffers: still the same icon.
    left.icon = .{ .id = 1, .pixels = &pixels_a, .size = 1 };
    right.icon = .{ .id = 1, .pixels = &pixels_b, .size = 1 };
    try std.testing.expect(left.eql(right));

    // Different id, even sharing a pixel buffer: a different icon. A raw
    // pointer comparison would get this wrong once eviction can free and
    // reuse a buffer's address for a different icon.
    right.icon = .{ .id = 2, .pixels = &pixels_a, .size = 1 };
    try std.testing.expect(!left.eql(right));
}

test "TitlebarMemo.eql detects font, title size and close control appearance" {
    var left = sampleTitlebarMemo();
    var right = sampleTitlebarMemo();
    right.font_generation +%= 1;
    try std.testing.expect(!left.eql(right));
    try std.testing.expect(!left.reusableFor(right));
    right = left;
    right.title_size = 14;
    try std.testing.expect(!left.eql(right));
    right = left;
    right.close_fg = .{ 0, 1, 0, 1 };
    try std.testing.expect(!left.eql(right));
    right = left;
    right.close_hover_alpha = 0.4;
    try std.testing.expect(!left.eql(right));
}

test "TitlebarMemo.capture reads title_size from theme.global" {
    const saved = theme.global;
    defer theme.global = saved;
    theme.global.title_size = 19.25;
    const memo = TitlebarMemo.capture(10, null, .{ .scale = 1 });
    try std.testing.expectEqual(@as(f32, 19.25), memo.title_size);
}

test "chrome geometry changes invalidate retained titlebar pixels" {
    const saved = theme.global;
    defer theme.global = saved;
    const before = TitlebarMemo.capture(400, null, .{});
    theme.global.window_border_width = 2;
    try std.testing.expectEqual(@as(i32, 2), chrome_mod.frameBorder());
    try std.testing.expect(!before.reusableFor(TitlebarMemo.capture(400, null, .{})));
    theme.global = saved;
    theme.global.chrome_control_gap += 1;
    const spaced = TitlebarMemo.capture(400, null, .{});
    try std.testing.expect(!before.eql(spaced));
    try std.testing.expect(!before.reusableFor(spaced));
    theme.global.chrome_control_gap = saved.chrome_control_gap;
    theme.global.chrome_height += 1;
    const taller = TitlebarMemo.capture(400, null, .{});
    try std.testing.expect(!before.reusableFor(taller));
    theme.global.chrome_height = saved.chrome_height;
    theme.global.chrome_round_buttons = !saved.chrome_round_buttons;
    const round = TitlebarMemo.capture(400, null, .{});
    try std.testing.expect(!before.eql(round));
    try std.testing.expect(!before.reusableFor(round));
    theme.global = saved;
    theme.global.chrome_control_right_pad = 2;
    try std.testing.expect(!before.reusableFor(TitlebarMemo.capture(400, null, .{})));
    theme.global = saved;
    theme.global.chrome_control_offset_y = 5;
    try std.testing.expect(!before.reusableFor(TitlebarMemo.capture(400, null, .{})));
    theme.global = saved;
    theme.global.chrome_button_bevel = 7;
    try std.testing.expect(!before.reusableFor(TitlebarMemo.capture(400, null, .{})));
    inline for (.{ "window_title_plate_inset", "window_title_plate_bevel", "window_title_plate_slant", "window_title_plate_control_gap", "window_title_plate_text_padding" }) |field| {
        theme.global = saved;
        @field(theme.global, field) += 0.1;
        try std.testing.expect(!before.reusableFor(TitlebarMemo.capture(400, null, .{})));
    }
}

test "chrome controls fit and stay centered at every supported height and density" {
    const saved = theme.global;
    defer theme.global = saved;
    for ([_]f32{ 28, 55, 84 }) |height| {
        theme.global.chrome_height = height;
        for ([_]f32{ 1, 0.75 }) |density| {
            const m: Metrics = .{ .density = density };
            for ([_]f32{ 0, 4, 24 }) |gap| {
                theme.global.chrome_control_gap = gap;
                const min = controlRectScaled(400, .minimize, density);
                const max = controlRectScaled(400, .maximize, density);
                const close = controlRectScaled(400, .close, density);
                try std.testing.expectEqual(m.controlGap(), max.x - (min.x + min.w));
                try std.testing.expectEqual(m.controlGap(), close.x - (max.x + max.w));
                try std.testing.expect(min.y >= 0 and min.y + min.h < m.titlebarHeight());
                try std.testing.expect(@abs(2 * min.y + min.h - m.titlebarHeight()) <= 1);
                try std.testing.expect(m.iconSize() < min.h);
                try std.testing.expect(min.x > m.length(title_inset) + m.iconSize() + m.length(title_icon_gap));
            }
        }
    }
}

test "ShadowMemo.eql ignores geometry while the shadow is disabled" {
    const a = ShadowMemo{
        .width = 10,
        .height = 10,
        .radius = 0,
        .color = .{ 0, 0, 0, 0 },
        .softness = 0,
        .offset_y = 0,
        .scale = 1,
        .disabled = true,
        .shape = 0,
    };
    var b = a;
    b.width = 999;
    try std.testing.expect(a.eql(b));
    b.disabled = false;
    try std.testing.expect(!a.eql(b));
}

test "ShadowMemo.eql is false when softness changes" {
    const a = ShadowMemo{
        .width = 200,
        .height = 100,
        .radius = 10,
        .color = .{ 0, 0, 0, 0.35 },
        .softness = 24,
        .offset_y = 8,
        .scale = 1,
        .disabled = false,
        .shape = 0,
    };
    var b = a;
    try std.testing.expect(a.eql(b));
    b.softness = 32;
    try std.testing.expect(!a.eql(b));
}

test "cached chrome updates exactly match complete rasters across hover controls and scales" {
    const saved = theme.global;
    defer theme.global = saved;
    try checkCachedChromeUpdates();
    theme.global.window_title_plate = .{ 1, 0.9, 0, 1 };
    theme.global.window_title_plate_width = 310;
    theme.global.window_title_plate_fg = .{ 0, 0, 0, 1 };
    theme.global.chrome_control_right_pad = 2;
    theme.global.chrome_control_offset_y = 5;
    try checkCachedChromeUpdates();
}

fn checkCachedChromeUpdates() !void {
    for ([_]i32{ 20, 200, 640 }) |width| {
        for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
            for ([_]f32{ 1, 0.75, 1.0 / 1.7 }) |density| {
                var state: ChromeState = .{ .density = density, .scale = scale, .title = "Cached window title" };
                var previous = try ChromeBuffer.create(width, state);
                defer previous.base.drop();
                // Titles change alone and together with hover and
                // controls: growing, shrinking, ellipsized, fallback
                // glyphs (a terminal spinner) and empty.
                const titles = [_][]const u8{
                    "Cached window title",
                    "\u{280b} Working on a task that is long enough to be ellipsized before the controls",
                    "Short",
                    "Short",
                    "",
                    "\u{2819} Working \u{2014} claude",
                };
                var step: usize = 0;
                for ([_]f32{ 0.35, 1, 0 }) |hover| {
                    for ([_]?ControlKind{ .minimize, .maximize, .close, null }) |control| {
                        const previous_title = state.title;
                        state.hover = hover;
                        state.chip_pos = if (control) |kind| controlSlot(kind) else 0.5;
                        state.chip_alpha = if (control == null) 0.35 else 1;
                        state.title = titles[step % titles.len];
                        state.active = step % 2 == 0;
                        state.workspace_focus = step % 3 == 0;
                        step += 1;
                        const expected = try ChromeBuffer.create(width, state);
                        defer expected.base.drop();
                        const updated = try ChromeBuffer.createUpdated(previous, state, !std.mem.eql(u8, previous_title, state.title));
                        errdefer updated.base.drop();
                        try std.testing.expectEqualSlices(u32, expected.pixels, updated.pixels);
                        previous.base.drop();
                        previous = updated;
                    }
                }
            }
        }
    }
}

test "tab title updates preserve neighbouring pixels and match a full raster" {
    const Tab = @import("chrome_tabs.zig").Tab;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const before = [_]Tab{ .{ .id = 1, .title = "A longer title", .active = true, .attention = false }, .{ .id = 2, .title = "Untouched", .active = false, .attention = false } };
        var state: ChromeState = .{ .scale = scale, .tabs = .{ .tabs = &before } };
        const old = try ChromeBuffer.create(600, state);
        defer old.base.drop();
        var after = before;
        after[0].title = "Short";
        state.tabs.tabs = &after;
        const updated = try ChromeBuffer.createUpdated(old, state, true);
        defer updated.base.drop();
        const full = try ChromeBuffer.create(600, state);
        defer full.base.drop();
        try std.testing.expectEqualSlices(u32, full.pixels, updated.pixels);
        const geom = @import("chrome_tabs.zig").geometry(600, 1, state.tabs);
        const untouched = geom.tab(1);
        for (0..@intCast(old.height)) |y| {
            const start: usize = y * @as(usize, @intCast(old.width)) + @as(usize, @intFromFloat(@ceil(untouched.x * scale)));
            const end: usize = y * @as(usize, @intCast(old.width)) + @as(usize, @intFromFloat(@floor((untouched.x + untouched.w) * scale)));
            try std.testing.expectEqualSlices(u32, old.pixels[start..end], updated.pixels[start..end]);
        }
    }
}

test "control glyphs have no coverage beyond the reach the raster gives them" {
    const chrome_paint = @import("chrome_paint.zig");
    for ([_]f32{ 1, 0.75, 1.0 / 1.7, 1.3 }) |density| {
        for ([_]f32{ 1, 1.5, 2, 3 }) |scale| {
            for ([_]bool{ false, true }) |maximized| {
                const m: Metrics = .{ .density = density };
                const btn = [_]window_chrome.Rect{ controlRectScaled(400, .minimize, density), controlRectScaled(400, .maximize, density), controlRectScaled(400, .close, density) };
                const controls = chrome_paint.Controls.init(btn[0], btn[1], btn[2], 0, 0, std.math.sqrt1_2, scale, m.contentScale(), maximized);
                const g = controls.glyph_scale;
                var py: f32 = 0;
                while (py < @as(f32, @floatFromInt(m.titlebarHeight()))) : (py += 0.25 / scale) {
                    var px: f32 = @floatFromInt(btn[0].x - 10);
                    while (px < @as(f32, @floatFromInt(btn[2].x + btn[2].w + 10))) : (px += 0.25 / scale) {
                        for (btn, 0..) |b, kind| {
                            if (@abs(px - b.centerX()) <= controls.glyph_reach and @abs(py - b.centerY()) <= controls.glyph_reach) continue;
                            const gx = b.centerX() + (px - b.centerX()) / g;
                            const gy = b.centerY() + (py - b.centerY()) / g;
                            const cov = switch (kind) {
                                0 => chrome_paint.minimizeIconCoverage(gx, gy, b, scale * g),
                                1 => chrome_paint.maximizeIconCoverage(gx, gy, b, scale * g, maximized),
                                else => chrome_paint.closeIconCoverage(gx, gy, b, std.math.sqrt1_2, scale * g),
                            };
                            try std.testing.expect(cov <= 0);
                        }
                    }
                }
            }
        }
    }
}
