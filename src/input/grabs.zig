//! Input move and resize grabs: snapping, settlement and title double-click.

const std = @import("std");
const Input = @import("../Input.zig");
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const Server = @import("../Server.zig");
const Toplevel = @import("../Toplevel.zig");
const chrome = @import("../chrome.zig");
const geometry = @import("../geometry.zig");
const glass = @import("../glass.zig");
const resize = @import("../resize.zig");
const snap = @import("../snap.zig");
const TitlePress = Input.TitlePress;

pub fn startMove(input: *Input, toplevel: *Toplevel) void {
    if (!@import("../workspaces.zig").visible(toplevel)) return;
    toplevel.finishZoomAnimation();
    toplevel.finishMoveAnimation();
    toplevel.finishSizeAnimation();
    if (@import("../tiling_grab.zig").begin(input, toplevel, null, 0x110)) {
        input.server.scheduleFrames();
        return;
    }
    toplevel.pending_restore = null;
    const snapped = toplevel.layout() != .floating and !toplevel.isFullscreen();
    input.move_snap.preview.hide();
    input.move_snap = .{
        .preview = input.move_snap.preview,
        .unsnap_from = if (snapped) .{ .x = input.cursor.x, .y = input.cursor.y } else null,
        .origin = if (toplevel.layout() == .floating) toplevel.rememberGeometry() else null,
    };
    // Cursor is in layout space; convert to world space to compute the grab
    // offset relative to the window origin (which lives in world space).
    const wx = input.server.world.toWorld(input.cursor.x, input.cursor.y).x;
    const wy = input.server.world.toWorld(input.cursor.x, input.cursor.y).y;
    const origin = geometry.toLocal(wx, wy, toplevel.x, toplevel.y);
    input.grabbed_toplevel = toplevel;
    input.cursor_mode = .move;
    @import("../effects/window_move.zig").start(toplevel);
    // The window is held until release; its client gets the pointer back
    // (and sets its own cursor) on the re-enter after the move.
    input.setHover(null, null);
    input.seat.pointerClearFocus();
    input.setNamedCursor("grabbing");
    input.grab_x = origin.x;
    input.grab_y = origin.y;
    input.server.scheduleFrames();
    // Snapshot current geometry for undo. Press folding: if a focus change
    // already fired on this press, begin() will inherit its focus id.
    const geom = toplevel.clientGeometry();
    if (!@import("../layout_undo.zig").beginGesture(input.server, toplevel.workspace_id)) input.server.undo.begin(.{
        .kind = .move,
        .press_seq = input.server.undo.press_seq,
        .at_ms = 0,
        .window = .{ .id = toplevel.id, .x = toplevel.x, .y = toplevel.y, .width = geom.width, .height = geom.height, .zoom_index = toplevel.zoom_index, .layout = toplevel.layout() },
    });
}

/// Ends a move grab, dropping the window into the snap zone under the
/// pointer when `apply_snap` (a button release rather than a cancel).
pub fn endMove(input: *Input, apply_snap: bool) void {
    @import("../effects/window_move.zig").stop(input.server);
    // The release frame refreshes a held titlebar blur (see heldGlass).
    input.server.scheduleFrames();
    const target = input.move_snap.target;
    const output = input.move_snap.output;
    const origin = input.move_snap.origin;
    input.move_snap.preview.hide();
    input.move_snap = .{ .preview = input.move_snap.preview };
    // Before snapping: setPositionAnimated jumps while a move grab is live.
    input.cursor_mode = .passthrough;
    const toplevel = input.grabbed_toplevel orelse {
        input.server.undo.drop();
        return;
    };
    input.grabbed_toplevel = null;
    if (apply_snap and input.server.world.workspaces.active) {
        const point = input.server.world.toLayout(@as(f64, @floatFromInt(toplevel.x)) + @as(f64, @floatFromInt(toplevel.chrome_width)) / 2, @as(f64, @floatFromInt(toplevel.y)) + @as(f64, @floatFromInt(toplevel.chrome_height)) / 2);
        if (if (target != null) output else @import("../Output.zig").atLayout(input.server, point.x, point.y)) |out| {
            @import("../layout_undo.zig").includeDestination(input.server, out.workspace_id);
            input.server.world.workspaces.placed(toplevel, out);
        }
    }
    if (apply_snap) if (target) |t| if (output) |out| toplevel.snapTo(out, t, origin);
    const geom = toplevel.clientGeometry();
    if (!@import("../layout_undo.zig").commitGesture(input.server, null)) input.server.undo.commit(Server.undoNowMs(), .{
        .window = .{
            .id = toplevel.id,
            .x = toplevel.x,
            .y = toplevel.y,
            .width = geom.width,
            .height = geom.height,
            .zoom_index = toplevel.zoom_index,
            .layout = toplevel.layout(),
        },
    });
}

/// Drag-to-restore: float a maximized or tiled window at its restore size,
/// keeping the grab at the same fraction of the frame width so the titlebar
/// stays under the pointer.
pub fn floatGrabbed(input: *Input, toplevel: *Toplevel) void {
    const restore = toplevel.tile_restore orelse toplevel.auto_restore orelse toplevel.maximize_restore;
    const ws = toplevel.worldScale();
    const old_w = @as(f64, @floatFromInt(@max(1, toplevel.chrome_width))) * ws;
    const fraction = std.math.clamp(input.grab_x / old_w, 0, 1);
    toplevel.leaveLayout();
    const geom = restore orelse return;
    _ = toplevel.requestSize(geom.width, geom.height);
    const new_w = @as(f64, @floatFromInt(geom.width + 2 * toplevel.borderWidth())) * ws;
    const title_h = @as(f64, @floatFromInt(@max(1, toplevel.titlebarHeight()))) * ws;
    input.grab_x = fraction * new_w;
    input.grab_y = @min(input.grab_y, title_h - 1);
}

pub fn updateSnapTarget(input: *Input, toplevel: *Toplevel) void {
    const found = input.snapTargetAt(toplevel);
    const target = if (found) |f| f.target else null;
    const output = if (found) |f| f.output else null;
    if (std.meta.eql(target, input.move_snap.target) and output == input.move_snap.output) return;
    input.move_snap.target = target;
    input.move_snap.output = output;
    if (found) |f| {
        const rect = snap.targetRect(f.output.usableBox(), f.target, input.server.config.compositor.windowGap());
        input.move_snap.preview.show(input.server.overlay_tree, rect);
    } else {
        input.move_snap.preview.hide();
    }
}

pub fn snapTargetAt(input: *Input, toplevel: *Toplevel) ?struct { target: snap.Target, output: *Output } {
    if (!input.server.config.compositor.snap_to_edges or toplevel.isFullscreen() or toplevel.parentWindow() != null) return null;
    const x = input.cursor.x;
    const y = input.cursor.y;
    const output = Output.atLayout(input.server, x, y) orelse return null;
    var box: wlr.Box = undefined;
    input.server.output_layout.getBox(output.wlr_output, &box);
    const left: f64 = @floatFromInt(box.x);
    const top: f64 = @floatFromInt(box.y);
    const right: f64 = @floatFromInt(box.x + box.width);
    const bottom: f64 = @floatFromInt(box.y + box.height);
    const open: snap.OpenEdges = .{
        .left = Output.atLayout(input.server, left - 1, y) == null,
        .right = Output.atLayout(input.server, right, y) == null,
        .top = Output.atLayout(input.server, x, top - 1) == null,
        .bottom = Output.atLayout(input.server, x, bottom) == null,
    };
    const target = snap.targetAt(x, y, box, output.usableBox(), open) orelse return null;
    return .{ .target = target, .output = output };
}

/// Records a titlebar press; true when it completes a double-click.
pub fn titleDoubleClick(input: *Input, toplevel: *Toplevel, time_msec: u32) bool {
    const press: TitlePress = .{ .press = input.presses, .toplevel_id = toplevel.id, .time_msec = time_msec, .x = input.cursor.x, .y = input.cursor.y };
    if (input.title_press) |prev| {
        if (prev.press + 1 == press.press and
            prev.toplevel_id == press.toplevel_id and
            press.time_msec -% prev.time_msec <= snap.double_click_ms and
            @abs(press.x - prev.x) <= snap.double_click_px and
            @abs(press.y - prev.y) <= snap.double_click_px)
        {
            input.title_press = null;
            return true;
        }
    }
    input.title_press = press;
    return false;
}

/// A dragged window's nearly opaque titlebar keeps its blur until release.
pub fn heldGlass(input: *const Input) ?*glass.Effect {
    if (input.cursor_mode != .move) return null;
    const toplevel = input.grabbed_toplevel orelse return null;
    if (!chrome.titlebarGlassMayHold(toplevel.titlebar_buffer.opacity)) return null;
    return toplevel.glass_effect;
}

pub fn startResize(
    input: *Input,
    toplevel: *Toplevel,
    wlr_edges: wlr.Edges,
    initiating_device: ?*wlr.InputDevice,
    initiating_button: u32,
) void {
    if (!@import("../workspaces.zig").visible(toplevel)) return;
    if (@import("../tiling_grab.zig").begin(input, toplevel, wlr_edges, initiating_button)) return;
    const edges = resize.Edges.fromWlr(wlr_edges);
    if (edges.isNone()) return;

    if (toplevel.minimized or
        toplevel.isMaximized() or
        toplevel.isFullscreen() or
        !toplevel.isMapped())
    {
        return;
    }

    if (input.resize_session != null) {
        input.cancelResize();
    }

    // Resizing a tile makes it an ordinary window of the tile's geometry.
    const layout_before = toplevel.layout();
    const layout_gesture = @import("../layout_undo.zig").beginGesture(input.server, toplevel.workspace_id);
    toplevel.leaveLayout();
    input.server.world.focus(toplevel);
    toplevel.finishZoomAnimation();
    toplevel.finishMoveAnimation();
    toplevel.finishSizeAnimation();
    input.setHover(null, null);

    input.cursor_mode = .resize;
    input.grabbed_toplevel = toplevel;
    input.seat.pointerClearFocus();

    input.setNamedCursor(edges.cursorName());

    const geom = toplevel.clientGeometry();
    const client_w = if (geom.width > 0) geom.width else 100;
    const client_h = if (geom.height > 0) geom.height else 100;
    const footer = toplevel.footerHeight();

    // Resize deltas are measured in unscaled client units.
    const cursor_wx = input.server.world.toWorld(input.cursor.x, input.cursor.y).x / toplevel.worldScale();
    const cursor_wy = input.server.world.toWorld(input.cursor.x, input.cursor.y).y / toplevel.worldScale();

    const snapshot = resize.createSnapshot(
        cursor_wx,
        cursor_wy,
        toplevel.x,
        toplevel.y,
        client_w,
        client_h,
        toplevel.titlebarHeight(),
        toplevel.borderWidth(),
        footer,
        edges,
    );

    const gen = input.next_session_generation;
    input.next_session_generation += 1;

    const pacing_output = Output.atLayout(input.server, input.cursor.x, input.cursor.y);

    input.resize_session = .{
        .toplevel = toplevel,
        .generation = gen,
        .initiating_device = initiating_device,
        .initiating_button = initiating_button,
        .edges = edges,
        .snapshot = snapshot,
        .latest_desired_size = .{ .width = client_w, .height = client_h },
        .dirty = false,
        .pacing_output = pacing_output,
    };
    @import("../effects/window_move.zig").startResize(toplevel);

    toplevel.setResizing(true);
    const wait = toplevel.requestSize(client_w, client_h);
    if (input.resize_session) |*sess| {
        sess.outstanding_configure = wait;
        sess.last_sent_width = client_w;
        sess.last_sent_height = client_h;
    }
    // Snapshot current geometry for undo at the start of the resize.
    if (!layout_gesture) input.server.undo.begin(.{
        .kind = .resize,
        .press_seq = input.server.undo.press_seq,
        .at_ms = 0,
        .window = .{ .id = toplevel.id, .x = toplevel.x, .y = toplevel.y, .width = client_w, .height = client_h, .zoom_index = toplevel.zoom_index, .layout = layout_before },
    });
}

pub fn finishResize(input: *Input) void {
    const session = &(input.resize_session orelse return);
    const toplevel = session.toplevel;
    @import("../effects/window_move.zig").stop(input.server);
    input.server.scheduleFrames();

    toplevel.setResizing(false);
    const final_size = session.latest_desired_size;
    const shown = @import("../effects/window_move.zig").resizeSize(toplevel, Toplevel.nowMs(), final_size);
    session.dirty = !std.meta.eql(shown, final_size);
    if (!session.dirty) {
        session.outstanding_configure = toplevel.requestSize(final_size.width, final_size.height);
        session.last_sent_width = final_size.width;
        session.last_sent_height = final_size.height;
    }

    input.cursor_mode = .passthrough;
    input.grabbed_toplevel = null;
    session.settling = true;

    // Commit the resize undo entry now that the final geometry is known.
    if (!@import("../layout_undo.zig").commitGesture(input.server, .{ .id = toplevel.id, .width = final_size.width, .height = final_size.height })) input.server.undo.commit(Server.undoNowMs(), .{
        .window = .{
            .id = toplevel.id,
            .x = toplevel.x,
            .y = toplevel.y,
            .width = final_size.width,
            .height = final_size.height,
            .zoom_index = toplevel.zoom_index,
            .layout = toplevel.layout(),
        },
    });

    // Compositor-owned windows have already applied the final size and
    // position; no client commit will arrive to finish their resize session.
    if (!session.dirty and session.outstanding_configure == .none) input.finishSettlement(session.generation);
    input.processCursorMotion(0);
}

pub fn cancelResize(input: *Input) void {
    const session = input.resize_session orelse return;
    const toplevel = session.toplevel;
    @import("../effects/window_move.zig").cancelFor(input.server, toplevel.id);

    input.resize_session = null;
    input.cursor_mode = .passthrough;
    input.grabbed_toplevel = null;
    // Cancelled resize: discard the in-flight undo entry.
    input.server.undo.drop();

    if (toplevel.isMapped()) {
        toplevel.setResizing(false);
        const geom = toplevel.clientGeometry();
        if (geom.width > 0 and geom.height > 0) {
            _ = toplevel.requestSize(geom.width, geom.height);
        }
    }
    input.processCursorMotion(0);
}

pub fn flushResizeConfigure(input: *Input, output: *Output) void {
    const session = &(input.resize_session orelse return);
    if (session.pacing_output != null and session.pacing_output != output) return;
    if (!session.dirty) return;
    if (session.outstanding_configure != .none) return;

    const toplevel = session.toplevel;
    const desired = @import("../effects/window_move.zig").resizeSize(toplevel, Toplevel.nowMs(), session.latest_desired_size);
    const following = !std.meta.eql(desired, session.latest_desired_size);

    if (desired.width == session.last_sent_width and desired.height == session.last_sent_height) {
        session.dirty = following;
        if (session.settling and !following) input.finishSettlement(session.generation);
        return;
    }

    session.outstanding_configure = toplevel.requestSize(desired.width, desired.height);
    session.last_sent_width = desired.width;
    session.last_sent_height = desired.height;
    session.dirty = following;
    if (session.settling and !following and session.outstanding_configure == .none) input.finishSettlement(session.generation);
}

pub fn finishSettlement(input: *Input, generation: u64) void {
    if (input.resize_session) |session| {
        if (session.generation == generation) {
            const toplevel = session.toplevel;
            input.resize_session = null;
            toplevel.syncChrome(false, Toplevel.nowMs()) catch {};
        }
    }
}

pub fn clearGrab(input: *Input) void {
    if (input.tiling_grab != null) input.finishTilingGrab(false);
    input.server.world.mini_map.hide();
    if (input.resize_session != null) {
        input.cancelResize();
    } else if (input.cursor_mode == .pan) {
        input.endPan();
    } else {
        if (input.cursor_mode == .move) {
            input.endMove(false);
            input.setDefaultCursor();
        }
        input.cursor_mode = .passthrough;
        input.grabbed_toplevel = null;
    }
}
