//! Small, immutable corner rasters above the client, clipped by the same frame
//! outline. No full-window overlay, timers, or work on unchanged client commits.
const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const sn = @import("../node.zig");
const chrome = @import("../chrome.zig");
const PanelBuffer = @import("../panel_buffer.zig").PanelBuffer;
const ui = @import("ui");

/// What every corner's raster is painted from, besides its own part of the outline.
const Memo = struct {
    scale: f32,
    density: f32,
    color: [4]f32,
    // Device-independent side of each corner's square, in logical px.
    extent: i32,
    stroke: f32,
    inset: f32,
    end_padding: f32,
};

/// What the last sync saw: an unchanged client commit stops at comparing it.
const Seen = struct { memo: Memo, width: i32, height: i32, radius: f32, shape: u64, opacity: f32 };

pub const State = struct {
    nodes: [4]?*sn.Buffer = @splat(null),
    memo: ?Seen = null,
    // What each corner's raster shows of the outline (`cornerKey`): a resize
    // moves the corners without painting them again.
    keys: [4]u64 = @splat(0),
    extension: ui.anim.Anim = .{},
};

fn enabled(t: *const Toplevel) bool {
    const palette = ui.theme.global;
    return chrome.shapes and !t.minimized and !t.closing and t.hasServerDecorations() and !t.isMaximized() and !t.isFullscreen() and
        palette.window_corner_accent[3] > 0 and palette.window_corner_extent > 0 and palette.window_corner_width > 0;
}

/// Start feedback even if a held pointer or an unresponsive client never
/// changes the geometry. Release/cancel gets its first frame the same way.
pub fn wakeCornerAccents(t: *Toplevel) void {
    if (enabled(t) and ui.theme.global.window_corner_resize_extra > 0) t.server.scheduleFrames();
}

fn retarget(t: *Toplevel, now_ms: i64) void {
    const input = &t.server.input;
    // The grab, rather than pending client configure acknowledgements, owns
    // the feedback. This also includes automatic-tile split resizing.
    const resizing = input.cursor_mode == .resize and input.grabbed_toplevel == t;
    const target: f32 = if (resizing) ui.theme.global.window_corner_resize_extra else 0;
    const palette = ui.theme.global;
    const curve: ui.anim.Curve = .{ .duration = .{
        .ms = @intFromFloat(if (resizing) palette.window_corner_resize_ms else palette.window_corner_restore_ms),
        .ease = std.meta.stringToEnum(ui.anim.Ease, palette.window_corner_resize_ease) orelse .out_cubic,
    } };
    const extension = &t.corner_accents.extension;
    // An instant transition must stay at its endpoint if reduced motion or
    // disabled animations are subsequently turned off.
    if (extension.active() and extension.completesInstantly()) extension.cancel(extension.to);
    if (extension.to == target) {
        if (extension.settled(now_ms) or std.meta.eql(extension.curve, curve)) return;
        // Apply timing/easing edits during a drag without restarting its length.
        extension.continueFrom(now_ms, extension.value(now_ms), target, extension.velocity(now_ms), curve);
    } else extension.retargetTo(now_ms, target, curve);
    if (extension.completesInstantly()) extension.cancel(target);
    t.server.scheduleFrames();
}

pub fn tickCornerAccents(t: *Toplevel, now_ms: i64) bool {
    const state = &t.corner_accents;
    if (!enabled(t)) {
        if (state.memo != null) t.syncCornerAccents() catch {};
        state.extension.cancel(0);
        return false;
    }
    retarget(t, now_ms);
    if (state.extension.sampleChanged(now_ms, 1 / t.chromeDensity())) {
        t.syncCornerAccents() catch |err| std.log.scoped(.chrome).warn("corner accents: {}", .{err});
    }
    return !state.extension.settled(now_ms);
}

pub fn syncCornerAccents(t: *Toplevel) !void {
    const palette = ui.theme.global;
    const state = &t.corner_accents;
    if (!enabled(t)) {
        for (state.nodes) |node| if (node) |n| n.node.setEnabled(false);
        state.memo = null;
        state.extension.cancel(0);
        return;
    }
    const now_ms = Toplevel.nowMs();
    retarget(t, now_ms);
    const density = t.chromeDensity();
    const width = t.chrome_width;
    const height = t.chrome_height;
    // The small raster's bounds are whole logical pixels, so subpixel animation
    // changes cannot reraster a held bar.
    const wanted = @ceil((palette.window_corner_extent + state.extension.value(now_ms)) * density);
    const extent: i32 = @intFromFloat(@ceil(@min(wanted, @as(f32, @floatFromInt(@min(width, height))) / 2)));
    const seen: Seen = .{
        .memo = .{
            .scale = t.render_scale,
            .density = density,
            .color = palette.window_corner_accent,
            .extent = extent,
            .stroke = palette.window_corner_width,
            .inset = palette.window_corner_inset,
            .end_padding = palette.window_corner_end_padding,
        },
        .width = width,
        .height = height,
        .radius = t.cornerRadius(),
        .shape = t.shapeKey(),
        .opacity = t.shape_opacity,
    };
    if (state.memo) |previous| if (std.meta.eql(previous, seen)) return;
    if (extent <= 0) return;
    const memo = seen.memo;
    const repaint = if (state.memo) |previous| !std.meta.eql(previous.memo, memo) else true;
    const polygon = t.shapePolygon(width, height);
    for (&state.nodes, 0..) |*slot, i| {
        const x = if (i % 2 == 0) 0 else width - extent;
        const y = if (i < 2) 0 else height - extent;
        const key = cornerKey(memo, polygon, seen.radius, x, y, width, height);
        if (slot.* == null) {
            const node = try t.frame_tree.createSceneBuffer(null);
            node.point_accepts_input = struct {
                fn accepts(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
                    return false;
                }
            }.accepts;
            node.setFilterMode(.bilinear);
            slot.* = node;
            state.keys[i] = ~key;
        }
        const node = slot.*.?;
        if (repaint or state.keys[i] != key) {
            const buffer = try PanelBuffer.createUnpooled(extent, extent, memo.scale);
            defer buffer.base.drop();
            paint(buffer, memo, polygon, seen.radius, x, y, width, height);
            node.setBuffer(&buffer.base);
            node.setDestSize(extent, extent);
            state.keys[i] = key;
        }
        node.node.setPosition(x, y);
        node.setOpacity(seen.opacity);
        node.node.setEnabled(true);
    }
    state.memo = seen;
}

/// How far from the outline the stroke's ink can lie, in logical px.
fn reach(memo: Memo) f32 {
    return @as(f32, @floatFromInt(chrome.frame_border)) + (memo.inset + memo.stroke) * memo.density + 1;
}

/// What the corner whose square starts at (`x`, `y`) shows of the outline. A
/// rounded frame's corner depends on its radius alone (capped by a small frame).
fn cornerKey(memo: Memo, polygon: ?ui.window_shape.Resolved, radius: f32, x: i32, y: i32, width: i32, height: i32) u64 {
    if (polygon) |p| return ui.window_shape.localKey(p, @floatFromInt(x), @floatFromInt(y), @floatFromInt(memo.extent), @floatFromInt(memo.extent), reach(memo)) | 1;
    const capped: u32 = @bitCast(@min(radius, @as(f32, @floatFromInt(@min(width, height))) / 2));
    return @as(u64, capped) << 1;
}

fn paint(buffer: *PanelBuffer, memo: Memo, polygon: ?ui.window_shape.Resolved, radius: f32, x: i32, y: i32, width: i32, height: i32) void {
    const color: ui.text.Color = .{ .r = memo.color[0], .g = memo.color[1], .b = memo.color[2], .a = memo.color[3] };
    const extent: f32 = @floatFromInt(memo.extent);
    const inset = @as(f32, @floatFromInt(chrome.frame_border)) + memo.inset * memo.density;
    const stroke = memo.stroke * memo.density;
    // The stroke is the band `inset` to `inset + stroke` inside the outline.
    // Its ink ends half a device pixel beyond either side.
    const centre = -(inset + stroke / 2);
    const half = stroke / 2 + 0.5 / memo.scale;
    const stride: usize = @intCast(buffer.width);
    // A raster outlives a resize, so it must not depend on where the frame's far
    // edges were when it was painted: the polygon is measured in f64, and a
    // rounded corner in a box of its own, by how far in from the frame's edges
    // a pixel is.
    const capped = @min(radius, @as(f32, @floatFromInt(@min(width, height))) / 2);
    const box = 2 * @max(extent, capped) + 2;
    for (0..@intCast(buffer.height)) |dy| {
        const py = (@as(f32, @floatFromInt(dy)) + 0.5) / memo.scale;
        const wy = @as(f64, py) + @as(f64, @floatFromInt(y));
        const along_y = if (y == 0) py else extent - py;
        var dx: usize = 0;
        while (dx < stride) : (dx += 1) {
            const px = (@as(f32, @floatFromInt(dx)) + 0.5) / memo.scale;
            const along_x = if (x == 0) px else extent - px;
            const distance: f32 = if (polygon) |p| @floatCast(ui.window_shape.sdPolygon(p, @as(f64, px) + @as(f64, @floatFromInt(x)), wy)) else ui.sdf.sdRoundedBox(along_x, along_y, 0, 0, box, box, capped);
            // Most of the square is clear of the band, and a distance changes by
            // at most one per pixel: skip to where the band can next be.
            const clear = (@abs(distance - centre) - half) * memo.scale - 1e-3;
            if (clear >= 0) {
                dx += @intFromFloat(clear);
                continue;
            }
            // Leave the output pass's one-pixel ring untouched. This stroke is
            // just inside it; all pixels still inherit frame opacity and clipping.
            const coverage = ui.sdf.coverage((distance + inset) * memo.scale) *
                ui.sdf.coverage((-distance - inset - stroke) * memo.scale);
            const end = ui.sdf.coverage((@max(along_x, along_y) - extent + memo.end_padding * memo.density) * memo.scale);
            if (coverage * end > 0) ui.text.blendPixel(&buffer.pixels[dy * stride + dx], color, coverage * end);
        }
    }
}
