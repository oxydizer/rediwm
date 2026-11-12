//! Continuous inner frame ring. Four disjoint strips keep its raster storage
//! proportional to the perimeter; no full-window buffer or idle repainting.
const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const sn = @import("../node.zig");
const chrome = @import("../chrome.zig");
const PanelBuffer = @import("../panel_buffer.zig").PanelBuffer;
const ui = @import("ui");
const Rect = ui.window_chrome.Rect;

const Memo = struct {
    width: i32,
    height: i32,
    scale: f32,
    radius: f32,
    shape: u64,
    maximized: bool,
    outer: i32,
    inner: i32,
    color: [4]f32,
};

pub const State = struct {
    nodes: [4]?*sn.Buffer = @splat(null),
    memo: ?Memo = null,
};

pub fn syncInnerBorder(t: *Toplevel) !void {
    const state = &t.inner_border;
    const color = ui.theme.global.window_inner_border;
    if (!chrome.shapes or !t.hasServerDecorations() or chrome.innerBorder() == 0 or color[3] <= 0) {
        for (state.nodes) |node| if (node) |n| n.node.setEnabled(false);
        state.memo = null;
        return;
    }
    const memo: Memo = .{
        .width = t.chrome_width,
        .height = t.chrome_height,
        .scale = t.render_scale,
        .radius = t.cornerRadius(),
        .shape = t.shapeKey(),
        .maximized = t.isMaximized(),
        .outer = chrome.outerBorder(),
        .inner = chrome.innerBorder(),
        .color = color,
    };
    const repaint = if (state.memo) |previous| !std.meta.eql(previous, memo) else true;
    if (repaint) {
        const polygon = t.shapePolygon(memo.width, memo.height);
        const boxes = strips(memo, polygon);
        for (&state.nodes, boxes) |*slot, box| {
            if (box.w <= 0 or box.h <= 0) {
                if (slot.*) |node| node.node.setEnabled(false);
                continue;
            }
            if (slot.* == null) {
                const node = try t.frame_tree.createSceneBuffer(null);
                node.point_accepts_input = struct {
                    fn accepts(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
                        return false;
                    }
                }.accepts;
                node.setFilterMode(.bilinear);
                // Even when enabled after the accents, the continuous band
                // belongs below their yellow ink and above the client's edge.
                node.node.placeAbove(&t.content_tree.node);
                slot.* = node;
            }
            const node = slot.*.?;
            const buffer = try PanelBuffer.createUnpooled(box.w, box.h, memo.scale);
            defer buffer.base.drop();
            paint(buffer, memo, polygon, box);
            node.setBuffer(&buffer.base);
            node.setDestSize(box.w, box.h);
            node.node.setPosition(box.x, box.y);
            node.node.setEnabled(true);
        }
        state.memo = memo;
    }
    for (state.nodes) |node| if (node) |n| n.setOpacity(t.shape_opacity);
}

fn strips(memo: Memo, polygon: ?ui.window_shape.Resolved) [4]Rect {
    const w: f64 = @floatFromInt(memo.width);
    const h: f64 = @floatFromInt(memo.height);
    var reach: f64 = @min(memo.radius, @min(w, h) / 2);
    if (polygon) |p| {
        reach = 0;
        for (p.points[0..p.count], 0..) |a, i| {
            const b = p.points[(i + 1) % p.count];
            // Every edge is wholly in at least one strip, even a concave
            // title step. Grow that strip by the ring width and AA fringe.
            const edge_reach = @min(@max(a[0], b[0]), @max(w - a[0], w - b[0]), @max(a[1], b[1]), @max(h - a[1], h - b[1]));
            reach = @max(reach, edge_reach);
        }
    }
    const band: i32 = @intFromFloat(@ceil(reach + @as(f64, @floatFromInt(memo.outer + memo.inner)) + 1));
    const sx = @min(band, @divTrunc(memo.width + 1, 2));
    const sy = @min(band, @divTrunc(memo.height + 1, 2));
    const right = @min(band, memo.width - sx);
    const bottom = @min(band, memo.height - sy);
    return .{
        .{ .x = 0, .y = 0, .w = memo.width, .h = sy },
        .{ .x = 0, .y = memo.height - bottom, .w = memo.width, .h = bottom },
        .{ .x = 0, .y = sy, .w = sx, .h = memo.height - sy - bottom },
        .{ .x = memo.width - right, .y = sy, .w = right, .h = memo.height - sy - bottom },
    };
}

fn paint(buffer: *PanelBuffer, memo: Memo, polygon: ?ui.window_shape.Resolved, box: Rect) void {
    const color: ui.text.Color = .{ .r = memo.color[0], .g = memo.color[1], .b = memo.color[2], .a = memo.color[3] };
    const outer: f32 = @floatFromInt(memo.outer);
    const inner: f32 = @floatFromInt(memo.inner);
    const stride: usize = @intCast(buffer.width);
    for (0..@intCast(buffer.height)) |dy| {
        const py = (@as(f32, @floatFromInt(dy)) + 0.5) / memo.scale + @as(f32, @floatFromInt(box.y));
        var dx: usize = 0;
        while (dx < stride) : (dx += 1) {
            const px = (@as(f32, @floatFromInt(dx)) + 0.5) / memo.scale + @as(f32, @floatFromInt(box.x));
            const distance: f32 = if (polygon) |p| @floatCast(ui.window_shape.sdPolygon(p, px, py)) else ui.sdf.sdRoundedBox(px, py, 0, 0, @floatFromInt(memo.width), @floatFromInt(memo.height), memo.radius);
            const band_distance = (@abs(distance + outer + inner / 2) - inner / 2) * memo.scale;
            const run = @min(ui.window_shape.saturatedRun(band_distance), stride - dx - 1);
            const coverage = ui.sdf.coverage(band_distance);
            if (coverage > 0) {
                for (dx..dx + run + 1) |x| ui.text.blendPixel(&buffer.pixels[dy * stride + x], color, coverage);
            }
            dx += run;
        }
    }
}
