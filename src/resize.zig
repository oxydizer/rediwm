const std = @import("std");
const wlr = @import("wlroots");

pub const Edges = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    pub fn isNone(self: Edges) bool {
        return !self.top and !self.bottom and !self.left and !self.right;
    }

    pub fn fromWlr(wlr_edges: wlr.Edges) Edges {
        return .{
            .top = wlr_edges.top,
            .bottom = wlr_edges.bottom,
            .left = wlr_edges.left,
            .right = wlr_edges.right,
        };
    }

    pub fn toWlr(self: Edges) wlr.Edges {
        return .{
            .top = self.top,
            .bottom = self.bottom,
            .left = self.left,
            .right = self.right,
        };
    }

    pub fn cursorName(self: Edges) [*:0]const u8 {
        if (self.top and self.left) return "nw-resize";
        if (self.top and self.right) return "ne-resize";
        if (self.bottom and self.left) return "sw-resize";
        if (self.bottom and self.right) return "se-resize";
        if (self.top) return "n-resize";
        if (self.bottom) return "s-resize";
        if (self.left) return "w-resize";
        if (self.right) return "e-resize";
        return "default";
    }
};

pub const ResizeSnapshot = struct {
    initial_cursor_x: f64,
    initial_cursor_y: f64,
    initial_frame_x: i32,
    initial_frame_y: i32,
    initial_client_width: i32,
    initial_client_height: i32,
    titlebar_height: i32,
    frame_border: i32,
    footer_height: i32,
    fixed_client_left: i32,
    fixed_client_right: i32,
    fixed_client_top: i32,
    fixed_client_bottom: i32,
    edges: Edges,
};

pub fn createSnapshot(
    cursor_x: f64,
    cursor_y: f64,
    frame_x: i32,
    frame_y: i32,
    client_width: i32,
    client_height: i32,
    titlebar_height: i32,
    frame_border: i32,
    footer_height: i32,
    edges: Edges,
) ResizeSnapshot {
    const fixed_left = frame_x + frame_border;
    const fixed_right = frame_x + frame_border + client_width;
    const fixed_top = frame_y + titlebar_height;
    const fixed_bottom = frame_y + titlebar_height + client_height;
    return .{
        .initial_cursor_x = cursor_x,
        .initial_cursor_y = cursor_y,
        .initial_frame_x = frame_x,
        .initial_frame_y = frame_y,
        .initial_client_width = client_width,
        .initial_client_height = client_height,
        .titlebar_height = titlebar_height,
        .frame_border = frame_border,
        .footer_height = footer_height,
        .fixed_client_left = fixed_left,
        .fixed_client_right = fixed_right,
        .fixed_client_top = fixed_top,
        .fixed_client_bottom = fixed_bottom,
        .edges = edges,
    };
}

pub const SizeConstraints = struct {
    min_width: i32 = 0,
    max_width: i32 = 0, // 0 = unbounded
    min_height: i32 = 0,
    max_height: i32 = 0, // 0 = unbounded
    control_min_width: i32 = 0,
};

pub const ClientSize = struct { width: i32, height: i32 };

pub fn computeDesiredClientSize(
    snapshot: ResizeSnapshot,
    cursor_x: f64,
    cursor_y: f64,
    constraints: SizeConstraints,
) ClientSize {
    const dx = cursor_x - snapshot.initial_cursor_x;
    const dy = cursor_y - snapshot.initial_cursor_y;

    var target_w: i32 = snapshot.initial_client_width;
    if (snapshot.edges.left) {
        target_w = snapshot.initial_client_width - @as(i32, @intFromFloat(@round(dx)));
    } else if (snapshot.edges.right) {
        target_w = snapshot.initial_client_width + @as(i32, @intFromFloat(@round(dx)));
    }

    var target_h: i32 = snapshot.initial_client_height;
    if (snapshot.edges.top) {
        target_h = snapshot.initial_client_height - @as(i32, @intFromFloat(@round(dy)));
    } else if (snapshot.edges.bottom) {
        target_h = snapshot.initial_client_height + @as(i32, @intFromFloat(@round(dy)));
    }

    var min_w: i32 = @max(1, constraints.min_width);
    const min_h: i32 = @max(1, constraints.min_height);

    if (constraints.control_min_width > min_w) {
        if (constraints.max_width == 0 or constraints.control_min_width <= constraints.max_width) {
            min_w = constraints.control_min_width;
        }
    }

    target_w = @max(target_w, min_w);
    target_h = @max(target_h, min_h);

    if (constraints.max_width > 0) {
        target_w = @min(target_w, constraints.max_width);
    }
    if (constraints.max_height > 0) {
        target_h = @min(target_h, constraints.max_height);
    }

    return .{ .width = target_w, .height = target_h };
}

pub fn computeFramePosition(
    snapshot: ResizeSnapshot,
    committed_client_width: i32,
    committed_client_height: i32,
) struct { x: i32, y: i32 } {
    var frame_x = snapshot.initial_frame_x;
    if (snapshot.edges.left) {
        frame_x = snapshot.fixed_client_right - committed_client_width - snapshot.frame_border;
    }

    var frame_y = snapshot.initial_frame_y;
    if (snapshot.edges.top) {
        frame_y = snapshot.fixed_client_bottom - committed_client_height - snapshot.titlebar_height;
    }

    return .{ .x = frame_x, .y = frame_y };
}

pub fn selectEdgesFromQuadrant(
    cursor_x: f64,
    cursor_y: f64,
    frame_x: i32,
    frame_y: i32,
    frame_width: i32,
    frame_height: i32,
) Edges {
    const mid_x = @as(f64, @floatFromInt(frame_x)) + @as(f64, @floatFromInt(frame_width)) / 2.0;
    const mid_y = @as(f64, @floatFromInt(frame_y)) + @as(f64, @floatFromInt(frame_height)) / 2.0;
    return .{
        .left = cursor_x < mid_x,
        .right = cursor_x >= mid_x,
        .top = cursor_y < mid_y,
        .bottom = cursor_y >= mid_y,
    };
}

/// How far a grab reaches past the frame, over the drop shadow. Only pixels a
/// chrome buffer covers can be hit, so this never exceeds the shadow margin
/// in practice (smallest preset is 16).
pub const reach_outside: f64 = 10.0;
/// How far it reaches into the frame, where chrome (titlebar, footer skirt)
/// is exposed. Beside the client the frame border is 1 px and the client
/// surface is above it, so `inside_client` keeps those pixels the client's.
pub const reach_inside: f64 = 4.0;

pub fn detectResizeEdges(
    fx: f64,
    fy: f64,
    frame_width: i32,
    frame_height: i32,
    titlebar_height: i32,
    frame_border: i32,
    footer_height: i32,
    has_control_at_point: bool,
) ?Edges {
    if (has_control_at_point) return null;

    const fw = @as(f64, @floatFromInt(frame_width));
    const fh = @as(f64, @floatFromInt(frame_height));

    if (fx < -reach_outside or fx > fw + reach_outside or fy < -reach_outside or fy > fh + reach_outside) {
        return null;
    }

    const corner_w = @min(16.0, fw / 2.0);
    const corner_h = @min(16.0, fh / 2.0);

    const tb_h = @as(f64, @floatFromInt(titlebar_height));
    const fb = @as(f64, @floatFromInt(frame_border));
    const foot_h = @as(f64, @floatFromInt(footer_height));

    const inside_client = (fx >= fb and fx < fw - fb and fy >= tb_h and fy < fh - foot_h);
    if (inside_client) return null;

    var edges = Edges{};

    const is_nw = (fx < corner_w and fy < corner_h);
    const is_ne = (fx >= fw - corner_w and fy < corner_h);
    const is_sw = (fx < corner_w and fy >= fh - corner_h);
    const is_se = (fx >= fw - corner_w and fy >= fh - corner_h);

    if (is_nw) {
        edges.top = true;
        edges.left = true;
    } else if (is_ne) {
        edges.top = true;
        edges.right = true;
    } else if (is_sw) {
        edges.bottom = true;
        edges.left = true;
    } else if (is_se) {
        edges.bottom = true;
        edges.right = true;
    } else if (fy < reach_inside) {
        edges.top = true;
    } else if (fy >= fh - @max(foot_h, reach_inside)) {
        edges.bottom = true;
    } else if (fx < reach_inside) {
        edges.left = true;
    } else if (fx >= fw - reach_inside) {
        edges.right = true;
    }

    if (edges.isNone()) return null;
    return edges;
}

test "resize geometry calculation for all 8 directions" {
    const titlebar_height: i32 = 61;
    const frame_border: i32 = 1;
    const footer_height: i32 = 10;
    const init_client_w: i32 = 800;
    const init_client_h: i32 = 600;
    const init_frame_x: i32 = 100;
    const init_frame_y: i32 = 100;

    const constraints = SizeConstraints{
        .min_width = 100,
        .max_width = 1600,
        .min_height = 100,
        .max_height = 1200,
    };

    // 1. Right resize
    {
        const edges = Edges{ .right = true };
        const snap = createSnapshot(
            200.0,
            200.0,
            init_frame_x,
            init_frame_y,
            init_client_w,
            init_client_h,
            titlebar_height,
            frame_border,
            footer_height,
            edges,
        );
        const sz = computeDesiredClientSize(snap, 250.0, 200.0, constraints);
        try std.testing.expectEqual(@as(i32, 850), sz.width);
        try std.testing.expectEqual(@as(i32, 600), sz.height);

        const pos = computeFramePosition(snap, sz.width, sz.height);
        try std.testing.expectEqual(@as(i32, 100), pos.x);
        try std.testing.expectEqual(@as(i32, 100), pos.y);
    }

    // 2. Left resize (fixed right edge)
    {
        const edges = Edges{ .left = true };
        const snap = createSnapshot(
            100.0,
            200.0,
            init_frame_x,
            init_frame_y,
            init_client_w,
            init_client_h,
            titlebar_height,
            frame_border,
            footer_height,
            edges,
        );
        const sz = computeDesiredClientSize(snap, 50.0, 200.0, constraints);
        try std.testing.expectEqual(@as(i32, 850), sz.width);
        try std.testing.expectEqual(@as(i32, 600), sz.height);

        const pos = computeFramePosition(snap, sz.width, sz.height);
        try std.testing.expectEqual(@as(i32, 50), pos.x);
        try std.testing.expectEqual(@as(i32, 100), pos.y);
    }

    // 3. Top-Left resize (fixed bottom-right)
    {
        const edges = Edges{ .top = true, .left = true };
        const snap = createSnapshot(
            100.0,
            100.0,
            init_frame_x,
            init_frame_y,
            init_client_w,
            init_client_h,
            titlebar_height,
            frame_border,
            footer_height,
            edges,
        );
        const sz = computeDesiredClientSize(snap, 80.0, 60.0, constraints);
        try std.testing.expectEqual(@as(i32, 820), sz.width);
        try std.testing.expectEqual(@as(i32, 640), sz.height);

        const pos = computeFramePosition(snap, sz.width, sz.height);
        try std.testing.expectEqual(@as(i32, 80), pos.x);
        try std.testing.expectEqual(@as(i32, 60), pos.y);
    }
}

test "quadrant selection for Alt + right-drag" {
    const fx: i32 = 100;
    const fy: i32 = 100;
    const fw: i32 = 400;
    const fh: i32 = 300;

    const nw = selectEdgesFromQuadrant(150.0, 150.0, fx, fy, fw, fh);
    try std.testing.expect(nw.top and nw.left and !nw.bottom and !nw.right);

    const se = selectEdgesFromQuadrant(350.0, 300.0, fx, fy, fw, fh);
    try std.testing.expect(se.bottom and se.right and !se.top and !se.left);
}

test "detect resize edges and corners with margin" {
    const fw: i32 = 200;
    const fh: i32 = 150;
    const tb: i32 = 61;
    const fb: i32 = 1;
    const foot: i32 = 10;

    if (detectResizeEdges(-3.0, -3.0, fw, fh, tb, fb, foot, false)) |edges| {
        try std.testing.expect(edges.top and edges.left);
    } else {
        return error.ExpectedHit;
    }

    try std.testing.expect(detectResizeEdges(100.0, 100.0, fw, fh, tb, fb, foot, false) == null);
    try std.testing.expect(detectResizeEdges(180.0, 10.0, fw, fh, tb, fb, foot, true) == null);

    // Straight edges are reachable across the whole outside reach and a few
    // pixels into the titlebar, but never into the client beside it.
    const fwf: f64 = @floatFromInt(fw);
    const fhf: f64 = @floatFromInt(fh);
    const mid_y: f64 = 100.0;
    const mid_x: f64 = 100.0;
    const left = detectResizeEdges(-9.0, mid_y, fw, fh, tb, fb, foot, false) orelse return error.ExpectedHit;
    try std.testing.expect(left.left and !left.top and !left.bottom and !left.right);
    try std.testing.expect(detectResizeEdges(-11.0, mid_y, fw, fh, tb, fb, foot, false) == null);
    const right = detectResizeEdges(fwf + 9.0, mid_y, fw, fh, tb, fb, foot, false) orelse return error.ExpectedHit;
    try std.testing.expect(right.right and !right.left);
    const top = detectResizeEdges(mid_x, -9.0, fw, fh, tb, fb, foot, false) orelse return error.ExpectedHit;
    try std.testing.expect(top.top and !top.left and !top.right);
    const title_top = detectResizeEdges(mid_x, 3.0, fw, fh, tb, fb, foot, false) orelse return error.ExpectedHit;
    try std.testing.expect(title_top.top);
    try std.testing.expect(detectResizeEdges(mid_x, 8.0, fw, fh, tb, fb, foot, false) == null);
    const title_left = detectResizeEdges(3.0, 30.0, fw, fh, tb, fb, foot, false) orelse return error.ExpectedHit;
    try std.testing.expect(title_left.left and !title_left.top);
    try std.testing.expect(detectResizeEdges(3.0, mid_y, fw, fh, tb, fb, foot, false) == null);
    const bottom = detectResizeEdges(mid_x, fhf + 9.0, fw, fh, tb, fb, foot, false) orelse return error.ExpectedHit;
    try std.testing.expect(bottom.bottom and !bottom.left and !bottom.right);
}
