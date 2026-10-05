//! Slides a file manager out of the way of a file drag that leaves it.
//!
//! Dragging a file from a file manager that sits on top of the app you want to
//! drop it on (a browser's upload area, say) means first rearranging the
//! windows. Instead, once the pointer has left the file manager's frame while
//! it covers another window, the frame slides sideways, away from the pointer,
//! until only a strip of it is left at the edge of the screen. When the drag
//! ends, dropped or cancelled, it slides back.
//!
//! The move is presentation only (`Toplevel.setDodge`): the window's position,
//! the canvas bounds, saved layouts and IPC never change, so nothing needs
//! undoing if the compositor or the window goes away mid-drag. It is one way
//! per drag: a pointer that wanders back over the old spot does not pull the
//! window back, so a drop near the edge of the frame cannot make it jitter.
//! Everything is in world units, so zoom and panning do not matter.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Input = @import("../Input.zig");
const Toplevel = @import("../Toplevel.zig");
const scene_data = @import("../scene_data.zig");

const Self = @This();

/// How far the pointer must be outside the frame, in screen pixels, before the
/// window moves, so grazing the edge does not send it away.
const leave_margin: f64 = 12;
/// How much of the frame stays on screen, in screen pixels: enough to see
/// where the window went, little enough to uncover what is behind it.
const peek: f64 = 48;

/// App ids of file managers. Matching is exact and case-insensitive: a
/// browser dragging a link, or any other app, keeps its window where it is.
const file_managers = [_][]const u8{
    "rediwm-files",
    "org.gnome.nautilus",
    "thunar",
    "org.kde.dolphin",
    "nemo",
    "pcmanfm",
    "pcmanfm-qt",
    "caja",
};

input: *Input,
/// The file manager whose drag is under way, until the drag ends or the
/// window goes away.
source: ?*Toplevel = null,
/// True once `source` has been slid aside.
displaced: bool = false,
/// True while `drag_destroy` is on the drag's signal.
watching: bool = false,
drag_destroy: wl.Listener(*wlr.Drag) = .init(dragDestroyed),

pub fn init(self: *Self, input: *Input) void {
    self.* = .{ .input = input };
}

pub fn deinit(self: *Self) void {
    // Shutting down: the windows go with the compositor, so nothing slides back.
    if (self.watching) self.drag_destroy.link.remove();
    self.watching = false;
    self.source = null;
    self.displaced = false;
}

/// A drag started. Watches it when a file manager started it and the setting
/// is on.
pub fn begin(self: *Self, drag: *wlr.Drag) void {
    self.finish();
    const input = self.input;
    if (!input.server.config.compositor.dodge_file_drags) return;
    if (drag.grab_type != .keyboard_pointer) return;
    const toplevel = sourceWindow(input, drag) orelse return;
    self.source = toplevel;
    drag.events.destroy.add(&self.drag_destroy);
    self.watching = true;
}

/// The pointer moved during a drag; slides the window aside the first time it
/// is clear of it.
pub fn motion(self: *Self) void {
    const toplevel = self.source orelse return;
    if (self.displaced) return;
    if (!toplevel.in_world or toplevel.closing or toplevel.minimized or toplevel.tab_hidden) return;
    const input = self.input;
    const world = &input.server.world;
    const zoom = world.camera.zoom();
    const frame = frameRect(toplevel);
    const cursor = world.toWorld(input.cursor.x, input.cursor.y);
    if (frame.inflated(leave_margin / zoom).contains(cursor.x, cursor.y)) return;
    if (!coversWindow(toplevel, frame)) return;

    var box: wlr.Box = undefined;
    input.server.output_layout.getBox(null, &box);
    const top_left = world.toWorld(@floatFromInt(box.x), @floatFromInt(box.y));
    const bottom_right = world.toWorld(@floatFromInt(box.x + box.width), @floatFromInt(box.y + box.height));
    const area: Rect = .{ .x = top_left.x, .y = top_left.y, .w = bottom_right.x - top_left.x, .h = bottom_right.y - top_left.y };
    const dx = slide(frame, area, cursor.x, peek / zoom);
    if (dx == 0) return;
    toplevel.setDodge(@floatCast(dx), 0);
    self.displaced = true;
}

/// `toplevel` is being unmapped or destroyed; it has already dropped its own
/// displacement, so only the reference goes.
pub fn detach(self: *Self, toplevel: *Toplevel) void {
    if (self.source != toplevel) return;
    self.source = null;
    self.displaced = false;
}

fn dragDestroyed(listener: *wl.Listener(*wlr.Drag), _: *wlr.Drag) void {
    const self: *Self = @fieldParentPtr("drag_destroy", listener);
    self.finish();
}

/// Ends the watch, sliding the window back if it was moved.
fn finish(self: *Self) void {
    if (self.watching) {
        self.drag_destroy.link.remove();
        self.watching = false;
    }
    if (self.source) |toplevel| {
        if (self.displaced) toplevel.setDodge(0, 0);
    }
    self.source = null;
    self.displaced = false;
}

/// The file manager window the drag came from, when it is one that may move:
/// under the pointer, owned by the client that started the drag, and laid out
/// freely (maximized, fullscreen and tiled windows own their geometry).
fn sourceWindow(input: *Input, drag: *wlr.Drag) ?*Toplevel {
    const toplevel = switch (scene_data.hitTest(input.server, input.cursor.x, input.cursor.y)) {
        .surface => |hit| hit.toplevel,
        .chrome => |hit| hit.toplevel,
        else => return null,
    };
    if (!toplevel.in_world or toplevel.closing or toplevel.minimized or toplevel.tab_hidden) return null;
    if (toplevel.layout() != .floating or toplevel.isFullscreen() or toplevel.forcedGeometry() != null) return null;
    if ((toplevel.waylandClient() orelse return null) != drag.seat_client.client) return null;
    const app_id = switch (toplevel.backend) {
        .xdg => |*adapter| if (adapter.xdg_toplevel.app_id) |id| std.mem.span(id) else return null,
        else => return null,
    };
    return if (isFileManager(app_id)) toplevel else null;
}

fn isFileManager(app_id: []const u8) bool {
    for (file_managers) |id| if (std.ascii.eqlIgnoreCase(app_id, id)) return true;
    return false;
}

fn frameRect(toplevel: *const Toplevel) Rect {
    const origin = toplevel.frameWorld(0, 0);
    const far = toplevel.frameWorld(@floatFromInt(toplevel.chrome_width), @floatFromInt(toplevel.chrome_height));
    return .{ .x = origin.x, .y = origin.y, .w = far.x - origin.x, .h = far.y - origin.y };
}

/// True when a window stacked below `toplevel` overlaps `frame`: only then is
/// there anything to uncover.
fn coversWindow(toplevel: *Toplevel, frame: Rect) bool {
    const parent = toplevel.frame_tree.node.parent orelse return false;
    // Siblings run bottom to top, so everything before this window is below it.
    var it = parent.children.iterator(.forward);
    while (it.next()) |node| {
        if (node == &toplevel.frame_tree.node) return false;
        const data = scene_data.SceneData.fromNode(node) orelse continue;
        if (data.role != .toplevel) continue;
        const other = data.role.toplevel;
        if (!other.in_world or other.tab_hidden or other.minimized or other.closing or other.backend_gone) continue;
        if (frameRect(other).intersects(frame)) return true;
    }
    return false;
}

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    fn inflated(self: Rect, by: f64) Rect {
        return .{ .x = self.x - by, .y = self.y - by, .w = self.w + 2 * by, .h = self.h + 2 * by };
    }

    fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.x + other.w and other.x < self.x + self.w and
            self.y < other.y + other.h and other.y < self.y + self.h;
    }
};

/// How far to move `frame` sideways so that only `strip` of it stays inside
/// `area`: to the right when the pointer is left of the frame's middle, else to
/// the left, so the window always leaves in the direction opposite the
/// pointer. Zero when it is already there.
pub fn slide(frame: Rect, area: Rect, pointer_x: f64, strip: f64) f64 {
    const keep = @min(strip, frame.w / 2);
    if (pointer_x < frame.x + frame.w / 2) return @max(0, area.x + area.w - keep - frame.x);
    return @min(0, area.x + keep - (frame.x + frame.w));
}

test "slide leaves in the direction opposite the pointer" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const frame: Rect = .{ .x = 100, .y = 50, .w = 600, .h = 500 };
    // Pointer right of the middle: the frame goes left until 48 of it is left.
    try std.testing.expectEqual(@as(f64, -652), slide(frame, area, 900, 48));
    // Pointer left of the middle: the frame goes right until 48 of it is left.
    try std.testing.expectEqual(@as(f64, 1772), slide(frame, area, 50, 48));
}

test "slide does nothing when the window is already at the edge" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    // Mostly off the left edge already, with the pointer to its right.
    try std.testing.expectEqual(@as(f64, 0), slide(.{ .x = -560, .y = 0, .w = 600, .h = 500 }, area, 900, 48));
    // And off the right edge, with the pointer to its left.
    try std.testing.expectEqual(@as(f64, 0), slide(.{ .x = 1880, .y = 0, .w = 600, .h = 500 }, area, 50, 48));
}

test "slide keeps at most half of a narrow window" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    // A 60 wide window keeps 30, not the 48 asked for.
    try std.testing.expectEqual(@as(f64, -230), slide(.{ .x = 200, .y = 0, .w = 60, .h = 100 }, area, 500, 48));
}

test "slide honours an area that does not start at the origin" {
    const area: Rect = .{ .x = -1920, .y = 0, .w = 3840, .h = 1080 };
    const frame: Rect = .{ .x = 100, .y = 0, .w = 600, .h = 500 };
    try std.testing.expectEqual(@as(f64, -2572), slide(frame, area, 900, 48));
    try std.testing.expectEqual(@as(f64, 1772), slide(frame, area, 50, 48));
}

test "rectangles" {
    const rect: Rect = .{ .x = 10, .y = 10, .w = 100, .h = 50 };
    try std.testing.expect(rect.contains(10, 10));
    try std.testing.expect(!rect.contains(110, 10));
    try std.testing.expect(rect.inflated(12).contains(-1, 70));
    try std.testing.expect(rect.intersects(.{ .x = 100, .y = 40, .w = 50, .h = 50 }));
    try std.testing.expect(!rect.intersects(.{ .x = 110, .y = 10, .w = 50, .h = 50 }));
}

test "file managers are matched by exact app id" {
    try std.testing.expect(isFileManager("rediwm-files"));
    try std.testing.expect(isFileManager("org.gnome.Nautilus"));
    try std.testing.expect(isFileManager("Thunar"));
    try std.testing.expect(!isFileManager("brave-browser"));
    try std.testing.expect(!isFileManager("rediwm-files-extra"));
    try std.testing.expect(!isFileManager(""));
}
