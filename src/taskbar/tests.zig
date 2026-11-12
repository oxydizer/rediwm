//! Taskbar tests: sizing, chip rasters and battery artwork.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const geometry = @import("../geometry.zig");
const icon_service = @import("../icon_service.zig");
const battery = @import("../taskbar/battery.zig");
const taskbar_pointer = @import("../taskbar/pointer.zig");
const text = @import("ui").text;
const ui_theme = @import("ui").theme;
const default_bar_height = Taskbar.default_bar_height;
const bar_height = Taskbar.bar_height;
const min_bar_height = Taskbar.min_bar_height;
const base_chip_size = Taskbar.base_chip_size;
const max_chip_vertical_margin = Taskbar.max_chip_vertical_margin;
const min_chip_size = Taskbar.min_chip_size;
const min_tile_size = Taskbar.min_tile_size;
const min_tray_hit = Taskbar.min_tray_hit;
const AppKind = Taskbar.AppKind;
const ChipState = Taskbar.ChipState;
const Color = Taskbar.Color;
const ChipPaint = Taskbar.ChipPaint;
const chipVerticalMargin = Taskbar.chipVerticalMargin;
const chipSize = Taskbar.chipSize;
const tileSize = Taskbar.tileSize;
const chipPad = Taskbar.chipPad;
const trayHit = Taskbar.trayHit;
const buttonSize = Taskbar.buttonSize;
const startButtonGap = Taskbar.startButtonGap;
const startButtonLeft = Taskbar.startButtonLeft;
const startIconSize = Taskbar.startIconSize;
const firstChipX = Taskbar.firstChipX;
const paintBatteryPixel = Taskbar.paintBatteryPixel;
const chipPixelArgb = Taskbar.chipPixelArgb;
const paintChipPixel = Taskbar.paintChipPixel;
const fillChipColumns = Taskbar.fillChipColumns;
const chipTitleRect = Taskbar.chipTitleRect;
const drawChipTitle = Taskbar.drawChipTitle;
const paintChipTitleColumns = Taskbar.paintChipTitleColumns;

test "taskbar chip order looks up stable window IDs" {
    const order = [_]u64{ 42, 7, 19 };

    try std.testing.expectEqual(@as(?usize, 0), Taskbar.chipOrderIndex(&order, 42));
    try std.testing.expectEqual(@as(?usize, 1), Taskbar.chipOrderIndex(&order, 7));
    try std.testing.expectEqual(@as(?usize, 2), Taskbar.chipOrderIndex(&order, 19));
    try std.testing.expectEqual(@as(?usize, null), Taskbar.chipOrderIndex(&order, 99));
}

test "taskbar chip order moves forward and preserves other IDs" {
    var order = [_]u64{ 10, 20, 30, 40, 50 };

    try std.testing.expect(Taskbar.moveChipOrder(&order, 1, 4));
    try std.testing.expectEqualSlices(u64, &.{ 10, 30, 40, 50, 20 }, &order);
}

test "taskbar chip order moves backward and preserves other IDs" {
    var order = [_]u64{ 10, 20, 30, 40, 50 };

    try std.testing.expect(Taskbar.moveChipOrder(&order, 4, 1));
    try std.testing.expectEqualSlices(u64, &.{ 10, 50, 20, 30, 40 }, &order);
}

test "taskbar chip order ignores invalid and unchanged moves" {
    var order = [_]u64{ 10, 20, 30 };
    const original = order;

    try std.testing.expect(!Taskbar.moveChipOrder(&order, 1, 1));
    try std.testing.expect(!Taskbar.moveChipOrder(&order, 3, 0));
    try std.testing.expect(!Taskbar.moveChipOrder(&order, 0, 3));
    try std.testing.expectEqualSlices(u64, &original, &order);
}

test "taskbar drag insertion targets visible chip midpoints" {
    const chips = [_]taskbar_pointer.ChipSlot{
        .{ .id = 10, .x = 0, .width = 100 },
        .{ .id = 20, .x = 110, .width = 100 },
        .{ .id = 30, .x = 220, .width = 100 },
    };

    try std.testing.expectEqual(
        taskbar_pointer.InsertionTarget{ .neighbor_id = 20, .before = true },
        taskbar_pointer.insertionTarget(&chips, 10, 140).?,
    );
    try std.testing.expectEqual(
        taskbar_pointer.InsertionTarget{ .neighbor_id = 20, .before = false },
        taskbar_pointer.insertionTarget(&chips, 10, 180).?,
    );
    try std.testing.expectEqual(
        taskbar_pointer.InsertionTarget{ .neighbor_id = 30, .before = true },
        taskbar_pointer.insertionTarget(&chips, 10, 220).?,
    );
    try std.testing.expectEqual(
        taskbar_pointer.InsertionTarget{ .neighbor_id = 30, .before = false },
        taskbar_pointer.insertionTarget(&chips, 10, 400).?,
    );
}

test "taskbar drag insertion ignores the dragged chip and handles a lone chip" {
    const chips = [_]taskbar_pointer.ChipSlot{
        .{ .id = 10, .x = 0, .width = 100 },
    };
    try std.testing.expectEqual(
        @as(?taskbar_pointer.InsertionTarget, null),
        taskbar_pointer.insertionTarget(&chips, 10, 50),
    );
}

test "chip/tile/tray sizing matches default theme" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};

    try std.testing.expectEqual(@as(i32, 38), chipSize());
    try std.testing.expectEqual(@as(i32, 21), tileSize());
    try std.testing.expectEqual(@as(i32, 8), chipPad());
    try std.testing.expectEqual(@as(i32, 31), trayHit());
    try std.testing.expectEqual(chipSize(), buttonSize());
}

test "shrinking the bar to its floor shrinks items without collapsing them" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};
    ui_theme.global.taskbar_size = @floatFromInt(min_bar_height);

    try std.testing.expect(chipSize() < base_chip_size);
    try std.testing.expect(chipSize() >= min_chip_size);
    try std.testing.expect(tileSize() >= min_tile_size);
    try std.testing.expect(trayHit() >= min_tray_hit);
    try std.testing.expect(chipPad() >= 0);
}

test "a large item gap grows the pill's vertical margin up to the cap" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};
    ui_theme.global.chip_gap = 1000;

    try std.testing.expectEqual(max_chip_vertical_margin, chipVerticalMargin());
    try std.testing.expect(chipSize() >= min_chip_size);
}

test "start button gap and icon size are theme-driven and icon is capped to the button" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};

    try std.testing.expectEqual(@as(i32, 4), startButtonGap());
    try std.testing.expectEqual(@as(i32, 4), startButtonLeft());
    try std.testing.expectEqual(@as(i32, 4 + buttonSize() + 4), firstChipX());
    try std.testing.expectEqual(@as(i32, 36), startIconSize());

    ui_theme.global.start_button_gap = 24;
    try std.testing.expectEqual(@as(i32, 24), startButtonLeft());
    try std.testing.expectEqual(@as(i32, 24 + buttonSize() + 24), firstChipX());
    ui_theme.global.start_button_gap = 16;

    // A configured icon size larger than the (shrunk) button must not
    // overflow the button it is centered in.
    ui_theme.global.taskbar_size = @floatFromInt(min_bar_height);
    ui_theme.global.start_button_icon_size = 42;
    try std.testing.expect(startIconSize() <= buttonSize());
}

test "chip flat-fill fast path is bit-identical to the full SDF raster" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};

    var icon_pixels: [64 * 64]u32 = undefined;
    for (&icon_pixels, 0..) |*p, i| p.* = if (i % 7 == 0) 0x80402010 else 0xff3366cc;
    const icon: icon_service.Entry = .{ .id = 1, .pixels = &icon_pixels, .size = 64 };

    var fast: usize = 0;
    var total: usize = 0;
    for ([_]f32{ 0, 0.5, 1, 5, 12 }) |radius| {
        ui_theme.global.radius = radius;
        for ([_]f32{ 0.75, 1, 1.25, 1.5, 2, 3 }) |scale| {
            for ([_]f32{ 78, 78.3, 366.5 }) |x| {
                for ([_]?icon_service.Entry{ null, icon }) |chip_icon| {
                    for ([_]AppKind{ .terminal, .browser }) |kind| {
                        const chip: ChipState = .{ .toplevel = undefined, .kind = kind, .icon = chip_icon, .width = 280.25 };
                        var paint: ChipPaint = .{
                            .chip = &chip,
                            .x = x,
                            .fill = Color.fromRgba(ui_theme.global.taskbar_hover),
                            .border = Color.fromRgba(ui_theme.global.taskbar_border).scaled(1.6),
                            .bar_height = default_bar_height,
                        };
                        paint.flat = .init(&paint, scale);
                        const origin_x = @round(x) - 2;
                        const width = geometry.devicePixels(@as(i32, @intFromFloat(@ceil(chip.width))) + 4, scale);
                        const height = geometry.devicePixels(default_bar_height, scale);
                        for (0..@intCast(height)) |dy| {
                            const py = (@as(f32, @floatFromInt(dy)) + 0.5) / scale;
                            for (0..@intCast(width)) |dx| {
                                const px = origin_x + (@as(f32, @floatFromInt(dx)) + 0.5) / scale;
                                const want = paintChipPixel(&paint, px, py, scale).argb();
                                try std.testing.expectEqual(want, chipPixelArgb(&paint, px, py, scale));
                                total += 1;
                                if (!paint.flat.tile.contains(px, py) and (!paint.flat.outer.contains(px, py) or
                                    paint.flat.band_h.contains(px, py) or paint.flat.band_v.contains(px, py))) fast += 1;
                            }
                        }
                    }
                }
            }
        }
    }
    // Guards against the fast path silently switching itself off.
    try std.testing.expect(fast * 10 > total * 8);
}

test "title-only chip repaints exactly match complete chip rasters" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};

    var icon_pixels: [64 * 64]u32 = undefined;
    for (&icon_pixels, 0..) |*p, i| p.* = if (i % 7 == 0) 0x80402010 else 0xff3366cc;
    const icon: icon_service.Entry = .{ .id = 1, .pixels = &icon_pixels, .size = 64 };
    const titles = [_][]const u8{
        "Terminal",
        "Working \u{2801}",
        "Working \u{28c0}",
        "Working \u{28ff}",
        "\u{280b} Working on a task that is long enough to be ellipsized in the chip",
        "",
        "\u{2819} Working \u{2014} claude",
        "A",
    };
    const color: text.Color = .{ .r = 0.9, .g = 0.92, .b = 0.95, .a = 1 };
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        for ([_]f32{ 78, 78.3, 366.5 }) |x| {
            for ([_]f32{ 152, 280.25 }) |chip_width| {
                const chip: ChipState = .{ .toplevel = undefined, .kind = .browser, .icon = icon, .width = chip_width };
                var paint: ChipPaint = .{
                    .chip = &chip,
                    .x = x,
                    .fill = Color.fromRgba(ui_theme.global.taskbar_hover),
                    .border = Color.fromRgba(ui_theme.global.taskbar_border).scaled(1.6),
                    .bar_height = default_bar_height,
                };
                paint.flat = .init(&paint, scale);
                const cx: i32 = @intFromFloat(@round(x));
                const origin_x = cx - 2;
                const width = geometry.devicePixels(@as(i32, @intFromFloat(@ceil(chip_width))) + 4, scale);
                const height = geometry.devicePixels(default_bar_height, scale);
                const len: usize = @intCast(width * height);
                const rect = chipTitleRect(cx, default_bar_height, chip_width, origin_x, 0).?;
                const previous = try std.testing.allocator.alloc(u32, len);
                defer std.testing.allocator.free(previous);
                const expected = try std.testing.allocator.alloc(u32, len);
                defer std.testing.allocator.free(expected);
                const updated = try std.testing.allocator.alloc(u32, len);
                defer std.testing.allocator.free(updated);
                for (titles, 0..) |before, i| {
                    const after = titles[(i + 1) % titles.len];
                    // Full rasters, as renderPart paints a chip with an icon.
                    fillChipColumns(&paint, previous, width, height, origin_x, 0, 0, @intCast(width), scale);
                    drawChipTitle(previous, width, height, rect, before, color, scale);
                    fillChipColumns(&paint, expected, width, height, origin_x, 0, 0, @intCast(width), scale);
                    drawChipTitle(expected, width, height, rect, after, color, scale);
                    @memcpy(updated, previous);
                    paintChipTitleColumns(&paint, updated, width, height, origin_x, rect, after, color, scale);
                    try std.testing.expectEqualSlices(u32, expected, updated);
                    if (std.mem.startsWith(u8, before, "Working ") and std.mem.startsWith(u8, after, "Working ")) {
                        // Changing spinner bounds must not move the unchanged words.
                        const left: usize = @intCast(geometry.devicePixels(rect.x, scale));
                        const prefix_width = try text.measureWidthF("Working", .manrope, ui_theme.global.taskbar_title_size, scale);
                        const right = left + @as(usize, @intFromFloat(@floor(prefix_width * scale)));
                        const stride: usize = @intCast(width);
                        for (0..@intCast(height)) |row| {
                            try std.testing.expectEqualSlices(u32, previous[row * stride + left .. row * stride + right], updated[row * stride + left .. row * stride + right]);
                        }
                    }
                }
            }
        }
    }
}

test "battery artwork remains centered as taskbar height and item gap change" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    for ([_]i32{ 36, 54, 84 }) |height| {
        for ([_]f32{ 0, 8, 24 }) |gap| {
            ui_theme.global = .{ .taskbar_size = @floatFromInt(height), .chip_gap = gap };
            var bar: Taskbar = undefined;
            bar.box.height = height;
            bar.battery_state = .{ .percent = 100, .plugged = true };
            for ([_]f32{ 1, 1.5, 2 }) |scale| {
                const h = geometry.devicePixels(height, scale);
                var top = h;
                var bottom: i32 = -1;
                for (0..@intCast(h)) |row| {
                    const y = (@as(f32, @floatFromInt(row)) + 0.5) / scale;
                    const pixel = paintBatteryPixel(&bar, 20, y, scale, 1);
                    if (pixel.g > 0.5 and pixel.r < 0.2) {
                        top = @min(top, @as(i32, @intCast(row)));
                        bottom = @max(bottom, @as(i32, @intCast(row)));
                    }
                }
                try std.testing.expect(bottom >= top);
                try std.testing.expect(@abs(top + bottom + 1 - h) <= 1);
            }
        }
    }
}
