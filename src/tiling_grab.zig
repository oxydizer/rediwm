//! Tile moves are staged until release. Split and strip resizes are live,
//! with an owned tree or strip snapshot for cancellation; gestures retain
//! IDs, never borrowed nodes. A drag near the end of a scrolling display
//! scrolls its strip.
const std = @import("std");
const Input = @import("Input.zig");
const Top = @import("Toplevel.zig");
const layout = @import("auto_layout.zig");
const scroll = @import("scroll_layout.zig");
const scroll_motion = @import("scroll_motion.zig");
const tiling = @import("auto_tiling.zig");
const gpa = @import("main.zig").gpa;
const wlr = @import("wlroots");
const Self = @This();

id: u64,
workspace: u8,
kind: enum { move, resize },
button: u32,
start_x: f64,
start_y: f64,
last_x: f64,
last_y: f64,
moved: bool = false,
horizontal: ?layout.Split = null,
vertical: ?layout.Split = null,
snapshot: ?layout.Tree = null,
/// A strip resize: which edge along the strip (width) and across it
/// (height within the column) the pointer holds, the sizes and view it
/// started from, and the strip to restore on Escape.
strip: ?StripResize = null,
undo_snapshot: ?*@import("layout_undo.zig").Snapshot = null,
drop: ?tiling.Drop = null,

const StripResize = struct {
    snapshot: scroll.Strip,
    main: ?scroll.Side = null,
    cross: ?scroll.Side = null,
    main_size: i32 = 0,
    cross_size: i32 = 0,
    view: f64 = 0,
};

/// The edges a strip resize holds. A member alone in its column has no
/// neighbour to trade height with.
fn stripResize(strip: *const scroll.Strip, key: scroll.Key, e: wlr.Edges) ?StripResize {
    const rect = strip.rectangle(key) orelse return null;
    const horizontal = strip.direction == .horizontal;
    var session: StripResize = .{ .snapshot = .{}, .view = strip.view, .main_size = strip.columnSize(key) orelse return null };
    const lead_main = if (horizontal) e.left else e.top;
    const trail_main = if (horizontal) e.right else e.bottom;
    const lead_cross = if (horizontal) e.top else e.left;
    const trail_cross = if (horizontal) e.bottom else e.right;
    if (lead_main or trail_main) session.main = if (lead_main) .before else .after;
    if ((lead_cross or trail_cross) and strip.columnCount(key) > 1) session.cross = if (lead_cross) .before else .after;
    session.cross_size = if (horizontal) rect.height else rect.width;
    if (session.main == null and session.cross == null) return null;
    return session;
}

pub fn begin(input: *Input, top: *Top, edges: ?wlr.Edges, button: u32) bool {
    if (!input.server.world.workspaces.active or top.auto_target == null or top.minimized or top.fullscreen or top.maximized) return false;
    if (input.tiling_grab != null) input.finishTilingGrab(false);
    if (input.resize_session != null) input.cancelResize();
    input.server.world.workspaces.tiler.flushNow(input.server);
    if (top.auto_target == null) return false;
    const tree = &input.server.world.workspaces.tiler.trees[top.workspace_id - 1];
    var session: Self = .{ .id = top.id, .workspace = top.workspace_id, .kind = if (edges != null) .resize else .move, .button = button, .start_x = input.cursor.x, .start_y = input.cursor.y, .last_x = input.cursor.x, .last_y = input.cursor.y };
    if (edges) |e| {
        if (input.server.world.workspaces.layoutOf(top.workspace_id) == .scrolling) {
            const strip = &input.server.world.workspaces.tiler.strips[top.workspace_id - 1];
            var resize = stripResize(strip, tiling.key(top), e) orelse return true;
            resize.snapshot = strip.clone(gpa) catch return true;
            session.strip = resize;
            session.undo_snapshot = @import("layout_undo.zig").capture(input.server, &.{top.workspace_id});
        } else {
            if (e.left or e.right) session.horizontal = tree.splitFor(tiling.key(top), .horizontal);
            if (e.top or e.bottom) session.vertical = tree.splitFor(tiling.key(top), .vertical);
            if (session.horizontal == null and session.vertical == null) return true;
            session.snapshot = tree.clone(gpa) catch return true;
            session.undo_snapshot = @import("layout_undo.zig").capture(input.server, &.{top.workspace_id});
        }
    }
    top.pending_restore = null;
    input.tiling_grab = session;
    input.grabbed_toplevel = top;
    input.cursor_mode = if (edges != null) .resize else .move;
    if (edges != null) top.wakeCornerAccents();
    input.move_snap.preview.hide();
    input.setHover(null, null);
    input.seat.pointerClearFocus();
    input.pointer_constraints.sync();
    const sideways = session.horizontal != null or if (session.strip) |s| (if (input.server.world.workspaces.tiler.strips[top.workspace_id - 1].direction == .horizontal) s.main != null else s.cross != null) else false;
    const upright = session.vertical != null or if (session.strip) |s| (if (input.server.world.workspaces.tiler.strips[top.workspace_id - 1].direction == .horizontal) s.cross != null else s.main != null) else false;
    input.setNamedCursor(if (edges == null) "grabbing" else if (sideways and upright) "se-resize" else if (sideways) "e-resize" else "s-resize");
    return true;
}

/// A live strip resize from where it started: the width along the strip
/// and the height within the column. From the leading edge, the view moves
/// so the trailing edge stays under the pointer's side.
fn resizeStrip(input: *Input, session: *Self, top: *Top, dx: f64, dy: f64) void {
    const resize = session.strip.?;
    const strip = &input.server.world.workspaces.tiler.strips[session.workspace - 1];
    const horizontal = strip.direction == .horizontal;
    const along: i32 = @intFromFloat(@round(if (horizontal) dx else dy));
    const across: i32 = @intFromFloat(@round(if (horizontal) dy else dx));
    const key = tiling.key(top);
    if (resize.main) |edge| {
        const size = @max(1, resize.main_size + if (edge == .after) along else -along);
        strip.setWidthPixels(key, size);
        if (edge == .before) strip.view = @max(0, resize.view + @as(f64, @floatFromInt(size - resize.main_size)));
    }
    if (resize.cross) |edge| strip.setCrossSize(key, resize.cross_size + if (edge == .after) across else -across);
    input.server.world.workspaces.tiler.schedule(input.server);
}

pub fn motion(input: *Input) void {
    const session = &(input.tiling_grab orelse return);
    if (input.cursor.x == session.last_x and input.cursor.y == session.last_y) return;
    session.last_x = input.cursor.x;
    session.last_y = input.cursor.y;
    const top = input.server.findToplevelById(session.id) orelse {
        input.finishTilingGrab(false);
        return;
    };
    const dx = input.cursor.x - session.start_x;
    const dy = input.cursor.y - session.start_y;
    if (!session.moved and @abs(dx) < @import("snap.zig").unsnap_px and @abs(dy) < @import("snap.zig").unsnap_px) return;
    session.moved = true;
    input.title_press = null;
    if (session.kind == .resize and session.strip != null) return resizeStrip(input, session, top, dx, dy);
    if (session.kind == .resize) {
        const tree = &input.server.world.workspaces.tiler.trees[session.workspace - 1];
        if (session.horizontal) |split| tree.setRatio(tiling.key(top), .horizontal, split.ratio + dx / @as(f64, @floatFromInt(split.span)));
        if (session.vertical) |split| tree.setRatio(tiling.key(top), .vertical, split.ratio + dy / @as(f64, @floatFromInt(split.span)));
        input.server.world.workspaces.tiler.schedule(input.server);
        return;
    }
    scroll_motion.dragEdge(input.server, input.cursor.x, input.cursor.y);
    updatePreview(input, session, top, false);
}

/// Membership/constraint changes can move a target even if the pointer is still.
pub fn refreshPreview(input: *Input) void {
    const session = &(input.tiling_grab orelse return);
    if (session.kind != .move or !session.moved) return;
    const top = input.server.findToplevelById(session.id) orelse return;
    updatePreview(input, session, top, true);
}

fn updatePreview(input: *Input, session: *Self, top: *Top, force: bool) void {
    const drop = tiling.dropAt(top, input.cursor.x, input.cursor.y);
    if (!force and std.meta.eql(drop, session.drop) and (drop == null or input.server.world.workspaces.tiles(drop.?.workspace))) return;
    session.drop = drop;
    input.move_snap.preview.hide();
    const target = drop orelse return;
    var prepared = (tiling.prepareDrop(top, target) catch return) orelse return;
    defer prepared.deinit();
    input.move_snap.preview.show(input.server.overlay_tree, prepared.rect);
    input.server.scheduleFrames();
}

pub fn finish(input: *Input, commit: bool) void {
    var session = input.tiling_grab orelse return;
    input.tiling_grab = null;
    input.cursor_mode = .passthrough;
    input.grabbed_toplevel = null;
    input.move_snap.preview.hide();
    scroll_motion.stopEdges(input.server);
    defer {
        if (session.snapshot) |*tree| tree.deinit(gpa);
        if (session.strip) |*resize| resize.snapshot.deinit(gpa);
        if (session.undo_snapshot) |snapshot| snapshot.destroy();
        input.setDefaultCursor();
        input.pointer_constraints.sync();
        input.server.scheduleFrames();
    }
    if (!commit) {
        if (session.snapshot) |tree| {
            const current = &input.server.world.workspaces.tiler.trees[session.workspace - 1];
            current.deinit(gpa);
            current.* = tree;
            session.snapshot = null;
            // Reconcile live membership: a closed window must never reappear.
            input.server.world.workspaces.tiler.schedule(input.server);
        }
        if (session.strip) |*resize| {
            const current = &input.server.world.workspaces.tiler.strips[session.workspace - 1];
            current.deinit(gpa);
            current.* = resize.snapshot;
            resize.snapshot = .{};
            input.server.world.workspaces.tiler.schedule(input.server);
        }
        return;
    }
    if (!session.moved) return;
    if (session.kind == .resize) {
        @import("layout_undo.zig").record(input.server, session.undo_snapshot);
        session.undo_snapshot = null;
        return;
    }
    const top = input.server.findToplevelById(session.id) orelse return;
    const drop = tiling.dropAt(top, input.cursor.x, input.cursor.y) orelse return;
    var prepared = (tiling.prepareDrop(top, drop) catch return) orelse return;
    defer prepared.deinit();
    const floating = !input.server.world.workspaces.tiles(drop.workspace);
    tiling.commitDrop(top, drop, &prepared);
    if (floating) {
        top.clearAutoTile(true);
        top.setPosition(prepared.rect.x, prepared.rect.y);
    }
}
