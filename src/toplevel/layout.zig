//! Toplevel layout: maximize, fullscreen, tiling and snapping.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const chrome = @import("../chrome.zig");
const tiling = @import("../snap.zig");
const events = @import("../ipc/events.zig");
const xdg = @import("../xdg.zig");
const ConfigureWait = Toplevel.ConfigureWait;
const RestoreGeometry = Toplevel.RestoreGeometry;

pub fn setMaximizedOn(toplevel: *Toplevel, output: *Output) void {
    toplevel.clearZoomBoost();
    toplevel.finishZoomAnimation();
    toplevel.maximized = true;
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setMaximized(true),
        .xwayland => |*adapter| adapter.xsurface.setMaximized(true, true),
        .placeholder, .shell => {},
    }

    const usable = output.usableBox();
    if (usable.width <= 0 or usable.height <= 0) return;

    const footer = if (toplevel.hasServerDecorations()) chrome.frameBorder() else 0;
    const scale = toplevel.zoom();
    const width = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(usable.width)) / scale))) - 2 * toplevel.borderWidth();
    const height = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(usable.height)) / scale))) - toplevel.titlebarHeight() - footer;
    if (width <= 0 or height <= 0) return;

    const point = toplevel.server.world.toWorld(@floatFromInt(usable.x), @floatFromInt(usable.y));
    const wx: i32 = @intFromFloat(@round(point.x));
    const wy: i32 = @intFromFloat(@round(point.y));
    if (toplevel.maximize_restore == null) {
        if (!toplevel.placed and !toplevel.in_world) {
            toplevel.setupInitialRestoreGeometry(output);
        } else {
            toplevel.maximize_restore = toplevel.floatingGeometry();
        }
    }
    toplevel.dropTile();
    toplevel.maximize_target = .{ .x = wx, .y = wy, .width = width, .height = height };
    _ = toplevel.requestSizeAnimated(width, height);
    toplevel.setPositionAnimated(wx, wy);
    toplevel.scheduleForcedGeometry();

    toplevel.syncForeign();

    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
}

pub fn setFullscreenOn(toplevel: *Toplevel, output: *Output) void {
    toplevel.clearZoomBoost();
    toplevel.finishZoomAnimation();
    toplevel.fullscreen = true;
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setFullscreen(true),
        .xwayland => |*adapter| adapter.xsurface.setFullscreen(true),
        .placeholder, .shell => {},
    }

    var box: wlr.Box = undefined;
    toplevel.server.output_layout.getBox(output.wlr_output, &box);
    if (box.width <= 0 or box.height <= 0) return;

    const scale = toplevel.zoom();
    const width = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(box.width)) / scale)));
    const height = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(box.height)) / scale)));
    if (width <= 0 or height <= 0) return;
    const point = toplevel.server.world.toWorld(@floatFromInt(box.x), @floatFromInt(box.y));
    const wx: i32 = @intFromFloat(@round(point.x));
    const wy: i32 = @intFromFloat(@round(point.y));
    if (toplevel.fullscreen_restore == null) {
        if (!toplevel.placed and !toplevel.in_world) {
            toplevel.setupInitialRestoreGeometry(output);
        } else {
            toplevel.fullscreen_restore = toplevel.rememberGeometry();
        }
    }
    toplevel.fullscreen_target = .{ .x = wx, .y = wy, .width = width, .height = height };
    _ = toplevel.requestSizeAnimated(width, height);
    toplevel.setPositionAnimated(wx, wy);
    toplevel.scheduleForcedGeometry();

    toplevel.syncForeign();

    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
    toplevel.server.refreshTaskbars();
}

pub fn setMaximized(toplevel: *Toplevel, maximizing: bool) void {
    if (!maximizing) {
        toplevel.maximized = false;
        switch (toplevel.backend) {
            .xdg => |*adapter| _ = adapter.xdg_toplevel.setMaximized(false),
            .xwayland => |*adapter| adapter.xsurface.setMaximized(false, false),
            .placeholder, .shell => {},
        }
        toplevel.maximize_target = null;
        if (toplevel.maximize_restore) |saved| {
            toplevel.maximize_restore = null;
            toplevel.restoreGeometry(saved);
        }
        toplevel.syncForeign();
        if (toplevel.server.ipc) |ipc| {
            events.onWindowChanged(ipc, toplevel);
            ipc.wait_mgr.checkAll();
        }
        return;
    }

    const geometry_box = toplevel.clientGeometry();
    const center = toplevel.frameWorld(@floatFromInt(toplevel.borderWidth() + @divTrunc(geometry_box.width, 2)), @floatFromInt(toplevel.titlebarHeight() + @divTrunc(geometry_box.height, 2)));
    const layout_center = toplevel.server.world.toLayout(center.x, center.y);
    const output = Output.atLayout(toplevel.server, layout_center.x, layout_center.y) orelse toplevel.resolveTargetOutput() orelse return;
    toplevel.setMaximizedOn(output);
}

/// Where the compositor has put the window: undo records this and keyboard
/// tiling steps from it. `maximized`, not isMaximized(): an xdg client acks
/// maximize a commit later.
pub fn layout(toplevel: *const Toplevel) tiling.Layout {
    if (toplevel.maximized) return .maximized;
    if (toplevel.tile) |tile| return .{ .tiled = tile };
    if (toplevel.auto_target != null) return .automatic;
    return .floating;
}

/// The geometry to return to when leaving maximize or a tile.
pub fn floatingGeometry(toplevel: *const Toplevel) RestoreGeometry {
    return toplevel.tile_restore orelse toplevel.auto_restore orelse toplevel.rememberGeometry();
}

pub fn setTiled(toplevel: *Toplevel, tile: tiling.Tile) void {
    const output = toplevel.currentOutput() orelse return;
    toplevel.setTiledOn(output, tile);
}

/// Fit the frame to `tile` of the output's usable area. A maximized window
/// hands its restore geometry to the tile.
pub fn setTiledOn(toplevel: *Toplevel, output: *Output, tile: tiling.Tile) void {
    toplevel.clearZoomBoost();
    if (!toplevel.in_world or toplevel.isFullscreen()) return;
    toplevel.finishZoomAnimation();
    const usable = output.usableBox();
    if (usable.width <= 0 or usable.height <= 0) return;

    const rect = tiling.tileRect(usable, tile, toplevel.server.config.compositor.windowGap());
    // cornerRadius() still reads maximized until an xdg client acks leaving it.
    const footer = if (toplevel.hasServerDecorations()) chrome.frameBorder() else 0;
    const scale = toplevel.zoom();
    const width = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(rect.width)) / scale))) - 2 * toplevel.borderWidth();
    const height = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(rect.height)) / scale))) - toplevel.titlebarHeight() - footer;
    if (width <= 0 or height <= 0) return;

    const point = toplevel.server.world.toWorld(@floatFromInt(rect.x), @floatFromInt(rect.y));
    const wx: i32 = @intFromFloat(@round(point.x));
    const wy: i32 = @intFromFloat(@round(point.y));
    if (toplevel.maximized or toplevel.isMaximized()) {
        toplevel.tile_restore = toplevel.maximize_restore orelse toplevel.tile_restore;
        toplevel.clearMaximized();
    } else if (toplevel.tile_restore == null) {
        toplevel.tile_restore = toplevel.rememberGeometry();
    }
    @import("../auto_tiling.zig").setFloating(toplevel, true);
    toplevel.tile = tile;
    toplevel.tile_target = .{ .x = wx, .y = wy, .width = width, .height = height };
    toplevel.sendTiled(tiling.tiledEdges(tile));
    _ = toplevel.requestSizeAnimated(width, height);
    toplevel.setPositionAnimated(wx, wy);
    toplevel.scheduleForcedGeometry();
    toplevel.notifyLayoutChanged();
}

/// Arbitrary automatic frame rectangle. Only changed targets configure a client;
/// replies to an earlier configure never trigger another layout pass.
/// `animate` glides the frame to the tile like other compositor-owned geometry;
/// a window still opening takes its first tile at once.
pub fn setAutoTile(toplevel: *Toplevel, rect: wlr.Box, animate: bool) void {
    if (!toplevel.in_world or toplevel.fullscreen or toplevel.maximized) return;
    const footer = if (toplevel.hasServerDecorations()) chrome.frameBorder() else 0;
    const target: RestoreGeometry = .{
        .x = rect.x,
        .y = rect.y,
        .width = @max(1, rect.width - 2 * toplevel.borderWidth()),
        .height = @max(1, rect.height - toplevel.titlebarHeight() - footer),
    };
    // An unchanged tile keeps a glide in flight (an earlier reflow, a restore).
    if (toplevel.auto_target) |previous| if (std.meta.eql(previous, target)) return;
    const was_tiled = toplevel.auto_target != null;
    const glide = animate and (was_tiled or !toplevel.map_motion.active());
    if (!glide) toplevel.finishSizeAnimation();
    if (toplevel.auto_restore == null) toplevel.auto_restore = toplevel.rememberGeometry();
    toplevel.auto_target = target;
    toplevel.pending_restore = null;
    toplevel.clearZoomBoost();
    if (!was_tiled) toplevel.sendTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    const moved = toplevel.x != target.x or toplevel.y != target.y;
    // X11 sends position and size together: commitPosition uses auto_target,
    // never the old client buffer size, and already configures a moved window.
    if (glide) toplevel.setPositionAnimated(target.x, target.y) else toplevel.setPosition(target.x, target.y);
    const wait: ConfigureWait = if (toplevel.backend != .xwayland or !moved) toplevel.requestSize(target.width, target.height) else .x11_commit;
    if (glide) toplevel.animateChromeSize(target.width, target.height, wait);
    toplevel.notifyLayoutChanged();
}

pub fn clearAutoTile(toplevel: *Toplevel, restore_floating: bool) void {
    if (toplevel.auto_target == null) return;
    const saved = toplevel.auto_restore;
    toplevel.auto_target = null;
    toplevel.auto_restore = null;
    if (toplevel.tile == null) toplevel.sendTiled(.{});
    if (restore_floating and !toplevel.fullscreen and !toplevel.maximized) {
        if (saved) |geom| {
            var floating = geom;
            const constraints = toplevel.sizeConstraints();
            floating.width = @max(floating.width, @max(1, constraints.min_width));
            floating.height = @max(floating.height, @max(1, constraints.min_height));
            if (constraints.max_width > 0) floating.width = @min(floating.width, constraints.max_width);
            if (constraints.max_height > 0) floating.height = @min(floating.height, constraints.max_height);
            toplevel.restoreGeometryNow(floating);
        }
    }
    toplevel.notifyLayoutChanged();
}

/// Return a tiled window to its floating geometry.
pub fn untile(toplevel: *Toplevel) void {
    if (toplevel.auto_target != null) {
        const saved = toplevel.auto_restore;
        @import("../auto_tiling.zig").setFloating(toplevel, true);
        if (saved) |geom| toplevel.restoreGeometry(geom);
        return;
    }
    if (toplevel.tile == null) return;
    const saved = toplevel.tile_restore;
    toplevel.dropTile();
    if (saved) |geom| toplevel.restoreGeometry(geom);
    toplevel.notifyLayoutChanged();
}

/// Leave maximize or a tile without moving; the caller places the window
/// (a drag carrying it off, an interactive resize, undo).
pub fn leaveLayout(toplevel: *Toplevel) void {
    @import("../auto_tiling.zig").setFloating(toplevel, true);
    if (!toplevel.maximized and !toplevel.isMaximized() and toplevel.tile == null) return;
    toplevel.clearMaximized();
    toplevel.dropTile();
    toplevel.notifyLayoutChanged();
}

/// Keyboard tiling and undo: go to `target` from wherever the window is.
pub fn applyLayout(toplevel: *Toplevel, target: tiling.Layout) void {
    if (toplevel.isFullscreen() or toplevel.layout().eql(target)) return;
    switch (target) {
        .floating => if (toplevel.maximized) toplevel.setMaximized(false) else toplevel.untile(),
        .maximized => toplevel.setMaximized(true),
        .tiled => |tile| toplevel.setTiled(tile),
        .automatic => {
            toplevel.clearMaximized();
            toplevel.dropTile();
            @import("../auto_tiling.zig").setFloating(toplevel, false);
        },
    }
}

/// Drop a dragged window into `target` on `output`. `floating` is its
/// geometry from before the drag, so leaving the snap returns it there.
pub fn snapTo(toplevel: *Toplevel, output: *Output, target: tiling.Target, floating: ?RestoreGeometry) void {
    if (toplevel.layout() == .floating) {
        if (floating) |geom| toplevel.tile_restore = geom;
    }
    switch (target) {
        .maximize => toplevel.setMaximizedOn(output),
        .tile => |tile| toplevel.setTiledOn(output, tile),
    }
}

pub fn clearMaximized(toplevel: *Toplevel) void {
    if (!toplevel.maximized and !toplevel.isMaximized()) return;
    toplevel.maximized = false;
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setMaximized(false),
        .xwayland => |*adapter| adapter.xsurface.setMaximized(false, false),
        .placeholder, .shell => {},
    }
    toplevel.maximize_target = null;
    toplevel.maximize_restore = null;
}

/// Forget the tile (and any restore hint) without moving the window.
pub fn dropTile(toplevel: *Toplevel) void {
    const was_tiled = toplevel.tile != null;
    toplevel.tile = null;
    toplevel.tile_target = null;
    toplevel.tile_restore = null;
    if (was_tiled) toplevel.sendTiled(.{});
}

pub fn sendTiled(toplevel: *Toplevel, edges: wlr.Edges) void {
    if (toplevel.backend_gone) return;
    switch (toplevel.backend) {
        // wlroots asserts an xdg_wm_base of version 2 or later (Shell.zig).
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setTiled(edges),
        .xwayland, .placeholder, .shell => {},
    }
}

pub fn notifyLayoutChanged(toplevel: *Toplevel) void {
    toplevel.syncForeign();
    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
}

pub fn setFullscreen(toplevel: *Toplevel, fullscreen: bool) void {
    if (toplevel.fullscreen != fullscreen) {
        toplevel.toggleFullscreen();
    }
}

pub fn toggleFullscreen(toplevel: *Toplevel) void {
    // Use compositor intent: a second toggle may precede the client ack.
    const next = !toplevel.fullscreen;
    if (!next) {
        toplevel.fullscreen = false;
        switch (toplevel.backend) {
            .xdg => |*adapter| _ = adapter.xdg_toplevel.setFullscreen(false),
            .xwayland => |*adapter| adapter.xsurface.setFullscreen(false),
            .placeholder, .shell => {},
        }
        toplevel.fullscreen_target = null;
        if (toplevel.fullscreen_restore) |saved| {
            toplevel.fullscreen_restore = null;
            toplevel.restoreGeometry(saved);
        }
        toplevel.syncForeign();
        if (toplevel.server.ipc) |ipc| {
            events.onWindowChanged(ipc, toplevel);
            ipc.wait_mgr.checkAll();
        }
        toplevel.server.refreshTaskbars();
        return;
    }

    const center = toplevel.frameWorld(@floatFromInt(@divTrunc(toplevel.chrome_width, 2)), @floatFromInt(@divTrunc(toplevel.chrome_height, 2)));
    const layout_center = toplevel.server.world.toLayout(center.x, center.y);
    const output = Output.atLayout(toplevel.server, layout_center.x, layout_center.y) orelse toplevel.resolveTargetOutput() orelse return;
    toplevel.setFullscreenOn(output);
}

pub fn beginMove(toplevel: *Toplevel) void {
    toplevel.server.input.startMove(toplevel);
}
