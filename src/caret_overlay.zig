//! The blinking, gliding caret of a hand-laid secret field (the lock, the
//! polkit dialog) as its own tiny scene buffer over the screen that painted
//! the field. Those screens rasterize one whole-output or whole-dialog
//! buffer; re-rastering that for every blink phase and glide frame would
//! upload it again each time. Here a glide frame is a few hundred pixels and
//! a blink is a node toggle.
//!
//! Motion and blink come from `ui.input.Caret`, the start menu's caret, so
//! both feel the same. The screen reports where its field put the caret after
//! each paint (`update`); its output's frame handler calls `frame`.
const std = @import("std");
const wlr = @import("wlroots");

const anim = @import("ui").anim;
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const ui = @import("ui");
const CaretPlace = ui.widgets.secret_input.Input.CaretPlace;

pub const CaretOverlay = struct {
    node: *wlr.SceneBuffer,
    caret: ui.input.Caret = .{},
    placed: ?Placed = null,
    /// What the node's buffer shows, so a frame that lands on the same device
    /// pixels (most blink frames, a settled caret) rasterizes nothing.
    shown: ?Raster = null,

    /// A caret place in a painter's logical units, and how those map into the
    /// parent tree: `x_tree = origin_x + x * factor`.
    pub const Placed = struct {
        caret: CaretPlace,
        origin_x: f32,
        origin_y: f32,
        factor: f32,
        scale: f32,
        color: [4]f32,
    };

    const Raster = struct {
        /// Node position in the parent tree, whole logical pixels.
        x: i32,
        y: i32,
        /// Sub-pixel phase of the caret inside the buffer, in device pixels
        /// quantized to 1/8.
        phase_x: i32,
        phase_y: i32,
        w: f32,
        h: f32,
        scale: f32,
        color: [4]f32,

        fn eql(a: Raster, b: Raster) bool {
            return std.meta.eql(a, b);
        }
    };

    /// Above everything already in `parent`: create it after the buffer
    /// holding the field.
    pub fn create(parent: *wlr.SceneTree) !CaretOverlay {
        const node = try parent.createSceneBuffer(null);
        node.node.setEnabled(false);
        return .{ .node = node };
    }

    pub fn destroy(self: *CaretOverlay) void {
        self.node.node.destroy();
    }

    /// After a paint: the field's caret belongs at `placed`, or nowhere (the
    /// field lost focus or is disabled). `edit_ms` is the owner's last edit,
    /// which restarts the blink phase with the caret held solid.
    pub fn update(self: *CaretOverlay, now_ms: i64, placed: ?Placed, edit_ms: i64) void {
        const next = placed orelse {
            self.hide();
            return;
        };
        if (self.placed) |prev| {
            // Scrolling moves the text under the caret, which keeps its place
            // on screen; a glide would sweep in from a character away.
            if (prev.caret.scroll != next.caret.scroll or prev.factor != next.factor or prev.scale != next.scale) self.caret.snap = true;
        } else {
            // Appearing (the screen opening, focus returning): no glide in,
            // and a fresh blink window, as a focused start menu field gets.
            self.caret.snap = true;
            self.caret.last_edit_ms = now_ms;
        }
        self.caret.last_edit_ms = @max(self.caret.last_edit_ms, edit_ms);
        self.caret.track(now_ms, next.caret.offset);
        self.placed = next;
    }

    pub fn hide(self: *CaretOverlay) void {
        self.placed = null;
        self.caret.snap = true;
        self.node.node.setEnabled(false);
    }

    /// Positions and blinks the caret for `now_ms`. Returns whether it still
    /// wants frames (mid-glide, or blinking before the blink timeout).
    pub fn frame(self: *CaretOverlay, now_ms: i64) bool {
        const p = self.placed orelse return false;
        const visible = self.caret.visible(now_ms);
        if (visible != self.node.node.enabled) {
            self.node.node.setEnabled(visible);
            anim.observeNoteChanged();
        }
        if (visible) self.present(p, now_ms);
        const animating = self.caret.animating(now_ms);
        if (animating) anim.observeNoteActive(self.caret.last_edit_ms, now_ms);
        return animating;
    }

    fn present(self: *CaretOverlay, p: Placed, now_ms: i64) void {
        const x = p.origin_x + (p.caret.origin_x + self.caret.offset(now_ms)) * p.factor;
        const y = p.origin_y + p.caret.y * p.factor;
        const node_x = @floor(x);
        const node_y = @floor(y);
        const want = Raster{
            .x = @intFromFloat(node_x),
            .y = @intFromFloat(node_y),
            .phase_x = @intFromFloat(@round((x - node_x) * p.scale * 8)),
            .phase_y = @intFromFloat(@round((y - node_y) * p.scale * 8)),
            .w = p.caret.w * p.factor,
            .h = p.caret.h * p.factor,
            .scale = p.scale,
            .color = p.color,
        };
        if (self.shown) |have| if (have.eql(want)) return;
        const raster = rasterize(want) orelse return;
        defer raster.base.drop();
        const w: i32 = @intFromFloat(@ceil(1 + want.w));
        const h: i32 = @intFromFloat(@ceil(1 + want.h));
        raster.publish(self.node, want.scale, null);
        self.node.setDestSize(w, h);
        self.node.node.setPosition(want.x, want.y);
        self.shown = want;
        anim.observeNoteChanged();
    }

    /// The caret alone, antialiased at its sub-pixel phase in a buffer one
    /// logical pixel larger than it on each axis.
    fn rasterize(want: Raster) ?*PanelBuffer {
        const w: i32 = @intFromFloat(@ceil(1 + want.w));
        const h: i32 = @intFromFloat(@ceil(1 + want.h));
        const buf = PanelBuffer.createUnpooled(w, h, want.scale) catch return null;
        var r = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, want.scale);
        r.clean = true;
        const px = @as(f32, @floatFromInt(want.phase_x)) / (8 * want.scale);
        const py = @as(f32, @floatFromInt(want.phase_y)) / (8 * want.scale);
        r.fillRect(px, py, want.w, want.h, .{ .color = want.color });
        return buf;
    }
};

test "the overlay caret rasterizes once per device-pixel phase and matches the drawn caret" {
    const want = CaretOverlay.Raster{ .x = 10, .y = 4, .phase_x = 4, .phase_y = 0, .w = 1.5, .h = 12, .scale = 2, .color = .{ 1, 0, 0, 1 } };
    const buf = CaretOverlay.rasterize(want) orelse return error.OutOfMemory;
    defer buf.base.drop();
    // 1.5 logical px is 3 device px at 2x; from a half-pixel phase (4/8) it
    // covers half of pixel 0, all of 1 and 2, and half of 3.
    try std.testing.expectEqual(@as(i32, 6), buf.width);
    const row = buf.pixels[@intCast(buf.width * 4)..][0..@intCast(buf.width)];
    for ([_]usize{ 0, 3 }) |i| try std.testing.expect(row[i] >> 24 > 0x60 and row[i] >> 24 < 0xa0);
    for (row[1..3]) |pixel| try std.testing.expectEqual(@as(u32, 0xffff0000), pixel);
    for (row[4..]) |pixel| try std.testing.expectEqual(@as(u32, 0), pixel);
}

test "the overlay caret appears, glides, blinks, goes solid and hides on a real scene" {
    const saved = ui.input.caret_config;
    defer ui.input.caret_config = saved;
    ui.input.caret_config = .{ .blink_ms = 1000, .blink_timeout_s = 10, .motion_ms = 80 };
    const scene = try wlr.Scene.create();
    defer scene.tree.node.destroy();
    var overlay = try CaretOverlay.create(&scene.tree);
    defer overlay.destroy();

    const place = CaretOverlay.Placed{
        .caret = .{ .origin_x = 10, .offset = 20, .y = 5, .w = 1.5, .h = 16, .scroll = 0 },
        .origin_x = 100,
        .origin_y = 50,
        .factor = 1,
        .scale = 1,
        .color = .{ 1, 0, 0, 1 },
    };
    const node = &overlay.node.node;
    overlay.update(1000, place, 1000);
    try std.testing.expect(overlay.frame(1000));
    try std.testing.expect(node.enabled and overlay.node.buffer != null);
    try std.testing.expectEqual(@as(c_int, 130), node.x);
    try std.testing.expectEqual(@as(c_int, 55), node.y);

    // An isolated edit glides across in `motion_ms`.
    var moved = place;
    moved.caret.offset = 30;
    overlay.update(2000, moved, 2000);
    _ = overlay.frame(2016);
    try std.testing.expect(node.x > 130 and node.x < 140);
    _ = overlay.frame(2080);
    try std.testing.expectEqual(@as(c_int, 140), node.x);

    // The off half of the blink hides it, and after the timeout it stays on
    // and stops asking for frames.
    try std.testing.expect(overlay.frame(2600));
    try std.testing.expect(!node.enabled);
    try std.testing.expect(!overlay.frame(2000 + 10_000));
    try std.testing.expect(node.enabled);

    // Scrolling snaps: the text moved, the caret keeps its place.
    var scrolled = moved;
    scrolled.caret.offset = 25;
    scrolled.caret.scroll = 5;
    overlay.update(13_000, scrolled, 13_000);
    _ = overlay.frame(13_000);
    try std.testing.expectEqual(@as(c_int, 135), node.x);

    overlay.update(14_000, null, 14_000);
    try std.testing.expect(!node.enabled);
    try std.testing.expect(!overlay.frame(14_000));

    // Reappearing blinks afresh even when nothing was typed since (a lock
    // screen that just opened), as a focused start menu field does.
    overlay.update(30_000, place, 0);
    try std.testing.expect(overlay.frame(30_000));
    try std.testing.expect(!overlay.frame(30_000 + 10_000));
}
