//! Taskbar painting: the bar raster and its parts.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const sn = @import("../node.zig");
const chrome = @import("../chrome.zig");
const icon_service = @import("../icon_service.zig");
const battery = @import("../taskbar/battery.zig");
const battery_badge = @import("ui").widgets.battery;
const start_button = @import("../taskbar/start_button.zig");
const shape = @import("../taskbar/shape.zig");
const window_shape = @import("ui").window_shape;
const ui_theme = @import("ui").theme;
const ui_relief = @import("ui").relief;
const stats = @import("../ipc/stats.zig");
const log = std.log.scoped(.taskbar);
const bar_height = Taskbar.bar_height;
const icon_scale = Taskbar.icon_scale;
const tile_radius = Taskbar.tile_radius;
const tray_radius = Taskbar.tray_radius;
const paint_start = Taskbar.paint_start;
const paint_chips = Taskbar.paint_chips;
const paint_tray = Taskbar.paint_tray;
const paint_clock = Taskbar.paint_clock;
const paint_hover = Taskbar.paint_hover;
const paint_press = Taskbar.paint_press;
const paint_audio = Taskbar.paint_audio;
const TrayKind = Taskbar.TrayKind;
const ChipMemo = Taskbar.ChipMemo;
const ChipRasterKey = Taskbar.ChipRasterKey;
const battery_width = Taskbar.battery_width;
const Color = Taskbar.Color;
const BarBuffer = Taskbar.BarBuffer;
const Part = Taskbar.Part;
const ChipPaint = Taskbar.ChipPaint;
const barRadius = Taskbar.barRadius;
const chipSize = Taskbar.chipSize;
const tileSize = Taskbar.tileSize;
const chipPad = Taskbar.chipPad;
const trayHit = Taskbar.trayHit;
const buttonSize = Taskbar.buttonSize;
const startIconSize = Taskbar.startIconSize;
const clockColumnWidth = Taskbar.clockColumnWidth;
const trayItem = Taskbar.trayItem;
const tileStyle = Taskbar.tileStyle;
const gradientColor = Taskbar.gradientColor;
const glyphSd = Taskbar.glyphSd;
const edgeCoverage = Taskbar.edgeCoverage;
const fillChipColumns = Taskbar.fillChipColumns;
const repaintChipTitle = Taskbar.repaintChipTitle;
const drawPartText = Taskbar.drawPartText;

pub fn render(bar: *Taskbar, now_ms: i64, causes: u8) void {
    if (bar.box.width <= 0) return;
    bar.renderAppTray();
    const bh = bar.box.height;
    if (bar.background_dirty) {
        renderPart(bar, now_ms, .background, 0, 0, bar.box.width + bar.bleed.x, bh + bar.bleed.y, bar.buffer_node, null);
        bar.background_dirty = false;
    }
    bar.start_node.node.setEnabled(bar.itemShown(.start));
    if (bar.itemShown(.start) and bar.start_dirty) {
        renderPart(bar, now_ms, .start, bar.startX() - 2, 0, buttonSize() + 4, bh, bar.start_node, null);
        bar.start_dirty = false;
    }
    const positions = bar.trayPositions();
    for (positions, 0..) |x, i| {
        bar.tray_nodes[i].node.setEnabled(bar.itemShown(trayItem(i)));
        if (!bar.itemShown(trayItem(i)) or !bar.tray_dirty[i]) continue;
        const left: i32 = @as(i32, @intFromFloat(@floor(x))) - 2;
        renderPart(bar, now_ms, .{ .tray = i }, left, 0, trayHit() + 4, bh, bar.tray_nodes[i], null);
        if (i == @intFromEnum(TrayKind.volume) and (causes & paint_audio) != 0) stats.recordTaskbarAudioPaint();
        bar.tray_dirty[i] = false;
    }
    bar.clock_node.node.setEnabled(bar.itemShown(.clock));
    if (bar.itemShown(.clock) and bar.clock_dirty) {
        const left: i32 = @intFromFloat(@floor(bar.clockX()));
        renderPart(bar, now_ms, .clock, left, 0, @intFromFloat(@ceil(clockColumnWidth(bar))), bh, bar.clock_node, null);
        bar.clock_dirty = false;
    }
    if (bar.itemShown(.battery)) {
        const left: i32 = @intFromFloat(@floor(bar.batteryX()));
        // Keep the node aligned with the configured item order.
        bar.battery_node.node.setPosition(left, 0);
        if (bar.battery_dirty) {
            renderPart(bar, now_ms, .battery, left, 0, battery_width, bh, bar.battery_node, null);
            bar.battery_dirty = false;
        }
        bar.battery_node.node.setEnabled(true);
    } else bar.battery_node.node.setEnabled(false);
    if (bar.capturing()) {
        if (bar.capture_dirty) {
            const x = bar.captureX();
            const left: i32 = @as(i32, @intFromFloat(@floor(x))) - 2;
            renderPart(bar, now_ms, .capture, left, 0, bar.captureWidth() + 4, bh, bar.capture_node, null);
            bar.capture_node.node.setEnabled(true);
            bar.capture_dirty = false;
        }
    } else {
        bar.capture_node.node.setEnabled(false);
        bar.capture_dirty = false;
    }
    for (bar.chips.items) |*chip| if (chip.dirty) {
        const left: i32 = @as(i32, @intFromFloat(@round(chip.renderX(now_ms)))) - 2;
        const width: i32 = @as(i32, @intFromFloat(@ceil(chip.width))) + 4;
        const memo = ChipMemo.capture(bar, chip, now_ms);
        if (chip.buffer_node) |node| {
            const key = ChipRasterKey.capture(bar, now_ms, chip, left, width);
            if (!repaintChipTitle(bar, now_ms, chip, memo, key, bh, node))
                renderPart(bar, now_ms, .{ .chip = chip }, left, 0, width, bh, node, &chip.raster);
            chip.raster_key = key;
        }
        chip.painted = memo;
        chip.dirty = false;
    };
    if ((causes & paint_hover) != 0) stats.recordTaskbarHoverPaint();
    if ((causes & paint_press) != 0) stats.recordTaskbarPressPaint();
}

/// `retain`, when given, keeps a reference to the new raster there (replacing
/// the one it held) instead of leaving the scene node as its only owner.
pub fn renderPart(bar: *Taskbar, now_ms: i64, part: Part, origin_x: i32, origin_y: i32, logical_width: i32, logical_height: i32, node: *sn.Buffer, retain: ?*?*BarBuffer) void {
    const started = stats.nowNs();
    const scale = bar.wlr_output.scale;
    const buf = BarBuffer.create(logical_width, logical_height, scale) catch |err| {
        log.err("renderPart: could not create taskbar buffer: {}", .{err});
        // What is retained no longer matches the screen.
        if (retain) |slot| if (slot.*) |old| {
            old.base.drop();
            slot.* = null;
        };
        return;
    };
    const stride: usize = @intCast(buf.width);
    // Animation easing and theme resolution are constant across this raster.
    // In particular, renderX solves a Bezier curve during FLIP: doing that
    // for every device pixel stalls the input loop on fractional-scale bars.
    const chip_paint: ?ChipPaint = switch (part) {
        .chip => |chip| ChipPaint.init(bar, now_ms, chip),
        else => null,
    };
    const sampled_start: start_button.Paint = if (part == .start) .init(bar.start, now_ms) else .{ .hover = 0, .open_amt = 0 };
    const hover = switch (part) {
        .tray => |i| bar.tray[i].hover.value(now_ms),
        .capture => bar.capture_hover.value(now_ms),
        else => 0,
    };
    const press = switch (part) {
        .tray => |i| bar.tray[i].press.value(now_ms),
        .capture => bar.capture_press.value(now_ms),
        else => 1,
    };
    // Layout measures the clock text. Never repeat it for each raster pixel.
    const part_x: f32 = switch (part) {
        .tray => |i| bar.trayPositions()[i],
        .capture => bar.captureX(),
        .battery => @floor(bar.batteryX()),
        else => 0,
    };
    const battery_progress = if (part == .battery) bar.battery_shimmer.sweep.value(now_ms) else 1;
    const part_width: f32 = if (part == .capture) @floatFromInt(bar.captureWidth()) else @floatFromInt(trayHit());
    // A polygon bar: the rows are filled in runs, and only the pixels near an edge
    // pay for a distance (`shape.paintPolygon`).
    const polygon: ?window_shape.Resolved = if (part == .background and Taskbar.hasPolygon())
        shape.polygon(ui_theme.global.taskbar_shape, @floatFromInt(bar.box.width), @floatFromInt(bar.box.height))
    else
        null;
    if (polygon) |poly| {
        // The raster reaches no further than the bar's own box.
        shape.paintPolygon(Color, .{ .pixels = buf.pixels, .stride = stride, .width = @intCast(buf.width), .height = @intCast(buf.height), .scale = scale }, poly, ui_theme.global.taskbar_outline_width, Color.bar_fill(), Color.outline());
    } else if (chip_paint) |*paint| fillChipColumns(paint, buf.pixels, buf.width, buf.height, origin_x, origin_y, 0, stride, scale) else for (0..@intCast(buf.height)) |dy| {
        const py = @as(f32, @floatFromInt(origin_y)) + (@as(f32, @floatFromInt(dy)) + 0.5) / scale;
        for (0..stride) |dx| {
            const px = @as(f32, @floatFromInt(origin_x)) + (@as(f32, @floatFromInt(dx)) + 0.5) / scale;
            buf.pixels[dy * stride + dx] = if (part == .battery)
                paintBatteryPixel(bar, px - part_x, py, scale, battery_progress).argb()
            else
                paintPartPixel(bar, sampled_start, hover, press, part_x, part_width, part, px, py, scale).argb();
        }
    }
    if (part == .tray) {
        const i = part.tray;
        const alert = switch (@as(TrayKind, @enumFromInt(i))) {
            .volume => bar.audio_muted,
            .wifi, .wired => bar.network_offline,
            .power => false,
        };
        const color = if (alert) blk: {
            var danger = Color.fromRgba(ui_theme.taskbar(.danger));
            if ((@as(TrayKind, @enumFromInt(i)) == .wifi or @as(TrayKind, @enumFromInt(i)) == .wired) and bar.blink_dim) danger.a *= 0.25;
            break :blk danger;
        } else Color.lerp(Color.tray_icon(), Color.tray_icon_hover(), hover);
        const size = 20 * press;
        var renderer = @import("ui").paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        renderer.drawIcon(bar.trayPositions()[i] + @as(f32, @floatFromInt(trayHit())) / 2 - size / 2 - @as(f32, @floatFromInt(origin_x)), @as(f32, @floatFromInt(bar.box.height)) / 2 - size / 2 - @as(f32, @floatFromInt(origin_y)), size, size, .{ .id = switch (@as(TrayKind, @enumFromInt(i))) {
            .wifi => .wifi,
            .wired => .ethernet,
            .volume => if (bar.audio_muted) .volume_muted else .volume,
            .power => .power,
        }, .color = .{ color.r, color.g, color.b, color.a } });
    }
    drawPartText(bar, now_ms, part, buf, origin_x, origin_y);
    node.node.setPosition(origin_x, origin_y);
    node.setBuffer(&buf.base);
    node.setDestSize(logical_width, logical_height);
    if (retain) |slot| {
        if (slot.*) |old| old.base.drop();
        slot.* = buf;
    } else buf.base.drop();
    stats.recordTaskbarPaint(stats.nowNs() -% started, @as(u64, @intCast(buf.width)) * @as(u64, @intCast(buf.height)), switch (part) {
        .background => 0,
        .start => paint_start,
        .clock => paint_clock,
        .chip => paint_chips,
        .tray => paint_tray,
        .capture => 0,
        .battery => paint_tray,
    });
}

/// Bilinear sample of an icon raster. `x`/`y` are logical offsets from the
/// icon's top-left and `logical` its logical size, so a raster made at the
/// output's device size lands exactly on its texels when the placement is
/// aligned, and is filtered (not snapped) when fractional scales shift it.
/// Texels outside the raster are transparent, which keeps the edge smooth.
pub fn sampleIcon(icon: icon_service.Entry, x: f32, y: f32, logical: f32) Color {
    const ratio = @as(f32, @floatFromInt(icon.size)) / logical;
    const fx = x * ratio - 0.5;
    const fy = y * ratio - 0.5;
    const x0: i32 = @intFromFloat(@floor(fx));
    const y0: i32 = @intFromFloat(@floor(fy));
    const tx = fx - @as(f32, @floatFromInt(x0));
    const ty = fy - @as(f32, @floatFromInt(y0));
    var sum = [4]f32{ 0, 0, 0, 0 };
    inline for (.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |corner| {
        const cx = x0 + corner[0];
        const cy = y0 + corner[1];
        if (cx >= 0 and cx < icon.size and cy >= 0 and cy < icon.size) {
            const weight = (if (corner[0] == 1) tx else 1 - tx) * (if (corner[1] == 1) ty else 1 - ty);
            const texel = icon.pixels[@intCast(cy * icon.size + cx)];
            sum[0] += weight * @as(f32, @floatFromInt((texel >> 16) & 0xff));
            sum[1] += weight * @as(f32, @floatFromInt((texel >> 8) & 0xff));
            sum[2] += weight * @as(f32, @floatFromInt(texel & 0xff));
            sum[3] += weight * @as(f32, @floatFromInt((texel >> 24) & 0xff));
        }
    }
    const a = sum[3] / 255.0;
    if (a <= 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    return .{ .r = sum[0] / 255.0 / a, .g = sum[1] / 255.0 / a, .b = sum[2] / 255.0 / a, .a = a };
}

pub fn paintPartPixel(bar: *Taskbar, sampled_start: start_button.Paint, hover: f32, press: f32, part_x: f32, part_width: f32, part: Part, px: f32, py: f32, scale: f32) Color {
    switch (part) {
        .background => return shape.background(Color, .{
            .width = @floatFromInt(bar.box.width),
            .height = @floatFromInt(bar.box.height),
            .radius = barRadius(),
            .outline = ui_theme.global.taskbar_outline_width,
            .flush = bar.flush,
            .top = bar.server.config.compositor.taskbar_position == .top,
        }, px, py, scale, Color.bar_fill(), Color.outline()),
        .start => {
            const btn_size = buttonSize();
            var color = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
            if (start_button.paintPixel(sampled_start, px, py, bar.box.height, scale, bar.startX(), btn_size)) |sb| color = (Color{ .r = sb.r, .g = sb.g, .b = sb.b, .a = sb.a }).over(color);
            if (bar.start_logo) |icon| {
                const mapped = start_button.mapPoint(sampled_start, px, py, bar.box.height, bar.startX(), btn_size);
                const pad: f32 = @floatFromInt(@divTrunc(btn_size - startIconSize(), 2));
                const logical: f32 = @floatFromInt(startIconSize());
                const ix = mapped.x - (mapped.box_x + pad);
                const iy = mapped.y - (mapped.box_y + pad);
                if (ix > -1 and iy > -1 and ix < logical + 1 and iy < logical + 1) {
                    var sample = sampleIcon(icon, ix, iy, logical);
                    if (ui_theme.global.start_button_icon.len == 0) {
                        if (ui_theme.taskbar(.start_button_logo_color)) |tint| sample = Color.fromRgba(tint).scaled(sample.a);
                    }
                    color = sample.over(color);
                }
            }
            return color;
        },
        .battery => unreachable, // Animation sampled once per raster.
        .clock => return .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .chip => unreachable, // Prepared once by renderPart.
        .tray => return paintTrayPixel(bar, hover, press, part_x, px, py, scale),
        .capture => return paintCapturePixel(bar, hover, press, part_x, part_width, px, py, scale),
    }
}

// The badge artwork is `ui.widgets.battery`'s; this only places it in the bar.
// `x` is measured from the badge's left edge, `py` from the bar's top.
pub fn paintBatteryPixel(bar: *Taskbar, x: f32, py: f32, scale: f32, progress: f32) Color {
    const trh: f32 = @floatFromInt(trayHit());
    const c = battery_badge.sample(x, py - @as(f32, @floatFromInt(bar.box.height - trayHit())) / 2, scale, .{
        .percent = bar.battery_state.percent orelse 0,
        .plugged = bar.battery_state.plugged,
        .shimmer = progress,
        .height = trh,
    }, battery_badge.Colors.taskbar());
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

pub fn paintCapturePixel(bar: *Taskbar, hover: f32, press: f32, tx: f32, tw: f32, px: f32, py: f32, scale: f32) Color {
    const tray_y: f32 = @floatFromInt(@divTrunc(bar.box.height - trayHit(), 2));
    const bcx = tx + tw / 2;
    const bcy = tray_y + @as(f32, @floatFromInt(trayHit())) / 2;
    const lx = (px - bcx) / press + bcx;
    const ly = (py - bcy) / press + bcy;
    var color = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const cov = edgeCoverage(chrome.sdRoundedBox(lx, ly, tx, tray_y, tw, @floatFromInt(trayHit()), tray_radius), scale);
    if (cov > 0) {
        const fill = Color.lerp(Color.fromRgba(ui_theme.taskbar(.danger)), Color.fromRgba(ui_theme.taskbar(.window_close_hover)), hover);
        color = fill.scaled(cov).over(color);
    }
    return color;
}

pub fn chipPixelArgb(paint: *const ChipPaint, px: f32, py: f32, scale: f32) u32 {
    const flat = &paint.flat;
    if (flat.enabled and !flat.tile.contains(px, py)) {
        if (!flat.outer.contains(px, py)) return 0;
        if (flat.band_h.contains(px, py) or flat.band_v.contains(px, py)) return flat.fill;
    }
    return paintChipPixel(paint, px, py, scale).argb();
}

/// Relief shading inside a chip's edge, over its body. A raster is only a few
/// px wider than its chip, so there is no room for outside shadows: `inset`
/// is the groove, `raised` the same shading with the two lights swapped.
fn chipRelief(body: Color, kind: ui_theme.Relief, x: f32, y: f32, w: f32, h: f32, px: f32, py: f32, scale: f32) Color {
    const spec = ui_relief.Spec.from(ui_theme.global, scale);
    if (!spec.enabled()) return body;
    const shape_box: ui_relief.Shape = .{ .x = x * scale, .y = y * scale, .w = w * scale, .h = h * scale, .radius = ui_theme.global.radius * scale };
    const pair = ui_relief.inset(spec, shape_box, px * scale, py * scale);
    const shade_dark = if (kind == .inset) spec.dark else spec.light;
    const shade_light = if (kind == .inset) spec.light else spec.dark;
    var color = body;
    color = (Color{ .r = shade_dark[0], .g = shade_dark[1], .b = shade_dark[2], .a = shade_dark[3] * pair.dark }).over(color);
    color = (Color{ .r = shade_light[0], .g = shade_light[1], .b = shade_light[2], .a = shade_light[3] * pair.light }).over(color);
    return color;
}

pub fn paintChipPixel(paint: *const ChipPaint, px: f32, py: f32, scale: f32) Color {
    const chip = paint.chip;
    const cx = paint.x;
    const chip_y: f32 = @floatFromInt(@divTrunc(paint.bar_height - chipSize(), 2));
    const lx = px;
    const ly = py;
    var color = @import("../taskbar/chip_style.zig").pixel(Color, lx, ly, cx, chip_y, chip.width, @floatFromInt(chipSize()), ui_theme.global.radius, scale, paint.fill, paint.border);
    if (paint.relief != .flat) color = chipRelief(color, paint.relief, cx, chip_y, chip.width, @floatFromInt(chipSize()), lx, ly, scale);
    const tile_x = cx + @as(f32, @floatFromInt(chipPad()));
    const tile_y = chip_y + @as(f32, @floatFromInt(chipPad()));
    const tile_cov = edgeCoverage(chrome.sdRoundedBox(lx, ly, tile_x, tile_y, @floatFromInt(tileSize()), @floatFromInt(tileSize()), tile_radius), scale);
    if (tile_cov == 0) return color;
    if (chip.icon) |icon| {
        const logical: f32 = @floatFromInt(tileSize());
        color = sampleIcon(icon, lx - tile_x, ly - tile_y, logical).scaled(tile_cov).over(color);
    } else {
        const style = tileStyle(chip.kind);
        const fill = switch (style.fill) {
            .solid => |v| v,
            .gradient => |g| gradientColor(g.a, g.b, lx, ly, tile_x, tile_y, @floatFromInt(tileSize()), @floatFromInt(tileSize())),
        };
        color = fill.scaled(tile_cov).over(color);
        if (style.hairline) {
            const stroke = edgeCoverage(@abs(chrome.sdRoundedBox(lx, ly, tile_x, tile_y, @floatFromInt(tileSize()), @floatFromInt(tileSize()), tile_radius)) - 0.6, scale);
            if (stroke > 0) color = Color.hairline().scaled(stroke).over(color);
        }
        if (glyphSd(chip.kind, (lx - tile_x - @as(f32, @floatFromInt(tileSize())) / 2) / icon_scale, (ly - tile_y - @as(f32, @floatFromInt(tileSize())) / 2) / icon_scale)) |sd| {
            const glyph_cov = edgeCoverage(sd * icon_scale, scale);
            if (glyph_cov > 0) color = Color.glyph.scaled(glyph_cov).over(color);
        }
    }
    return color;
}

pub fn paintTrayPixel(bar: *Taskbar, hover: f32, press: f32, tx: f32, px: f32, py: f32, scale: f32) Color {
    const tray_y: f32 = @floatFromInt(@divTrunc(bar.box.height - trayHit(), 2));
    const bcx = tx + @as(f32, @floatFromInt(trayHit())) / 2;
    const bcy = tray_y + @as(f32, @floatFromInt(trayHit())) / 2;
    const lx = (px - bcx) / press + bcx;
    const ly = (py - bcy) / press + bcy;
    var color = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (hover > 0) {
        const cov = edgeCoverage(chrome.sdRoundedBox(lx, ly, tx, tray_y, @floatFromInt(trayHit()), @floatFromInt(trayHit()), tray_radius), scale);
        if (cov > 0) color = Color.hover_fill().scaled(hover * cov).over(color);
    }
    // SVG glyphs are painted once after this background raster.
    return color;
}
