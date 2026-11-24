//! The tab that follows the pointer while it is dragged out of its window: a
//! small themed tile with the tab's title, on the overlay above everything, so
//! the drag reads as carrying the tab to another strip or out to a window of
//! its own. It exists only while `Drag.out` holds; no input ever reaches it.
const std = @import("std");
const sn = @import("node.zig");
const ui = @import("ui");
const Input = @import("Input.zig");
const Toplevel = @import("Toplevel.zig");
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const Self = @This();

const width = 200;
const height = 34;
node: ?*sn.Buffer = null,

fn ignoreInput(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}

/// Shows the ghost of `source`'s dragged tab under the pointer, making it
/// first if needed.
pub fn follow(self: *Self, input: *Input, source: *Toplevel) void {
    if (self.node == null) self.create(input, source);
    if (self.node) |node| node.node.setPosition(
        @intFromFloat(@floor(input.cursor.x - 24)),
        @intFromFloat(@floor(input.cursor.y - height / 2)),
    );
}

pub fn hide(self: *Self) void {
    if (self.node) |node| node.node.destroy();
    self.node = null;
}

fn create(self: *Self, input: *Input, source: *Toplevel) void {
    var storage: [@import("window_tabs.zig").max_tabs]@import("chrome_tabs.zig").Tab = undefined;
    const strip = source.tabStrip(&storage);
    const title = for (strip.tabs) |t| {
        if (t.id == source.tab_drag.id) break t.title;
    } else "";
    const scale = if (source.render_scale > 0) source.render_scale else 1;
    const buffer = PanelBuffer.create(width, height, scale) catch return;
    defer buffer.base.drop();
    const pal = ui.theme.shellPalette();
    var r = ui.paint.Renderer.init(buffer.pixels, buffer.width, buffer.height, scale);
    r.palette = pal;
    var bg = pal.window_bg;
    bg[3] = 0.95;
    r.fillRect(0, 0, width, height, .{ .color = bg, .radius = 10, .border_width = 1.5, .border_color = pal.accent });
    r.drawText(14, 0, width - 28, height, .{
        .content = title,
        .font_size = ui.theme.global.taskbar_title_size,
        .color = pal.window_fg,
    });
    const node = input.server.overlay_tree.createSceneBuffer(null) catch return;
    node.point_accepts_input = ignoreInput;
    node.setFilterMode(.bilinear);
    node.setBuffer(&buffer.base);
    node.setDestSize(width, height);
    node.node.raiseToTop();
    self.node = node;
}
