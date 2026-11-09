//! Small, immutable corner rasters above the client, clipped by the same frame
//! outline. No full-window overlay, timers, or work on unchanged client commits.
const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const sn = @import("../node.zig");
const chrome = @import("../chrome.zig");
const PanelBuffer = @import("../panel_buffer.zig").PanelBuffer;
const ui = @import("ui");

const Memo = struct {
    width: i32,
    height: i32,
    scale: f32,
    density: f32,
    radius: f32,
    shape: u64,
    color: [4]f32,
    extent: f32,
    stroke: f32,
    inset: f32,
    end_padding: f32,
};

pub const State = struct {
    nodes: [4]?*sn.Buffer = @splat(null),
    memo: ?Memo = null,
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
    const memo: Memo = .{
        .width = t.chrome_width,
        .height = t.chrome_height,
        .scale = t.render_scale,
        .density = density,
        .radius = t.cornerRadius(),
        .shape = t.shapeKey(),
        .color = palette.window_corner_accent,
        // The small raster's bounds are whole logical pixels. Memoize those
        // same lengths so subpixel animation changes cannot reraster a held bar.
        .extent = @ceil((palette.window_corner_extent + state.extension.value(now_ms)) * density) / density,
        .stroke = palette.window_corner_width,
        .inset = palette.window_corner_inset,
        .end_padding = palette.window_corner_end_padding,
    };
    if (state.memo) |previous| if (std.meta.eql(previous, memo)) return;
    const extent: i32 = @intFromFloat(@ceil(@min(memo.extent * memo.density, @as(f32, @floatFromInt(@min(memo.width, memo.height))) / 2)));
    if (extent <= 0) return;
    const polygon = t.shapePolygon(memo.width, memo.height);
    for (&state.nodes, 0..) |*slot, i| {
        const x = if (i % 2 == 0) 0 else memo.width - extent;
        const y = if (i < 2) 0 else memo.height - extent;
        const buffer = try PanelBuffer.createUnpooled(extent, extent, memo.scale);
        defer buffer.base.drop();
        paint(buffer, memo, polygon, x, y, extent);
        if (slot.* == null) {
            const node = try t.frame_tree.createSceneBuffer(null);
            node.point_accepts_input = struct {
                fn accepts(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
                    return false;
                }
            }.accepts;
            node.setFilterMode(.bilinear);
            slot.* = node;
        }
        const node = slot.*.?;
        node.node.setPosition(x, y);
        node.setDestSize(extent, extent);
        node.setBuffer(&buffer.base);
        node.setOpacity(t.shape_opacity);
        node.node.setEnabled(true);
    }
    state.memo = memo;
}

fn paint(buffer: *PanelBuffer, memo: Memo, polygon: ?ui.window_shape.Resolved, x: i32, y: i32, extent: i32) void {
    const color = memo.color;
    const inset = @as(f32, @floatFromInt(chrome.frame_border)) + memo.inset * memo.density;
    for (0..@intCast(buffer.height)) |dy| {
        const py = (@as(f32, @floatFromInt(dy)) + 0.5) / memo.scale;
        for (0..@intCast(buffer.width)) |dx| {
            const px = (@as(f32, @floatFromInt(dx)) + 0.5) / memo.scale;
            const wx = px + @as(f32, @floatFromInt(x));
            const wy = py + @as(f32, @floatFromInt(y));
            const distance: f32 = if (polygon) |p| @floatCast(ui.window_shape.sdPolygon(p, wx, wy)) else ui.sdf.sdRoundedBox(wx, wy, 0, 0, @floatFromInt(memo.width), @floatFromInt(memo.height), memo.radius);
            // Leave the output pass's one-pixel ring untouched. This stroke is
            // just inside it; all pixels still inherit frame opacity and clipping.
            const coverage = ui.sdf.coverage((distance + inset) * memo.scale) *
                ui.sdf.coverage((-distance - inset - memo.stroke * memo.density) * memo.scale);
            const along_x = if (x == 0) px else @as(f32, @floatFromInt(extent)) - px;
            const along_y = if (y == 0) py else @as(f32, @floatFromInt(extent)) - py;
            const end = ui.sdf.coverage((@max(along_x, along_y) - @as(f32, @floatFromInt(extent)) + memo.end_padding * memo.density) * memo.scale);
            ui.text.blendPixel(&buffer.pixels[dy * @as(usize, @intCast(buffer.width)) + dx], .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] }, coverage * end);
        }
    }
}
