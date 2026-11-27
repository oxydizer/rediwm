//! Toplevel layout: maximize, fullscreen, tiling and snapping.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const chrome = @import("../chrome.zig");
const tiling = @import("../snap.zig");
const events = @import("../ipc/events.zig");
const xdg = @import("../xdg.zig");
const scroll_tiling = @import("../scroll_tiling.zig");
const ConfigureWait = Toplevel.ConfigureWait;
const RestoreGeometry = Toplevel.RestoreGeometry;

pub fn setMaximizedOn(toplevel: *Toplevel, output: *Output) void {
    toplevel.clearZoomBoost();
    toplevel.finishZoomAnimation();
    toplevel.maximized = true;
    const in_strip = queueScrollingCover(toplevel);
    defer toplevel.syncXdgEdges();
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setMaximized(true),
        .xwayland => |*adapter| adapter.xsurface.setMaximized(true, true),
        .placeholder, .shell => {},
    }

    if (in_strip) {
        if (toplevel.maximize_restore == null) toplevel.maximize_restore = toplevel.floatingGeometry();
        toplevel.notifyLayoutChanged();
        return;
    }
    toplevel.scroll_cover = false;
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
    const in_strip = queueScrollingCover(toplevel);
    defer toplevel.syncXdgEdges();
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setFullscreen(true),
        .xwayland => |*adapter| adapter.xsurface.setFullscreen(true),
        .placeholder, .shell => {},
    }

    if (in_strip) {
        if (toplevel.fullscreen_restore == null) toplevel.fullscreen_restore = toplevel.floatingGeometry();
        toplevel.notifyLayoutChanged();
        toplevel.server.refreshTaskbars();
        return;
    }
    toplevel.scroll_cover = false;
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
        const was_maximized = toplevel.maximized;
        toplevel.maximized = false;
        const in_strip = was_maximized and queueScrollingCover(toplevel);
        defer toplevel.syncXdgEdges();
        switch (toplevel.backend) {
            .xdg => |*adapter| _ = adapter.xdg_toplevel.setMaximized(false),
            .xwayland => |*adapter| adapter.xsurface.setMaximized(false, false),
            .placeholder, .shell => {},
        }
        toplevel.maximize_target = null;
        const saved = toplevel.maximize_restore;
        toplevel.maximize_restore = null;
        if (in_strip) {
            if (!toplevel.fullscreen) releaseScrollingCover(toplevel, saved);
        } else if (saved) |geometry| {
            toplevel.restoreGeometry(geometry);
        }
        toplevel.syncForeign();
        if (toplevel.server.ipc) |ipc| {
            events.onWindowChanged(ipc, toplevel);
            ipc.wait_mgr.checkAll();
        }
        return;
    }

    const output = toplevel.currentOutput() orelse return;
    toplevel.setMaximizedOn(output);
}

fn queueScrollingCover(toplevel: *Toplevel) bool {
    if (toplevel.minimized or !scroll_tiling.managesCover(toplevel)) return false;
    // Place the strip before wlroots sends the configure for the new state.
    toplevel.server.world.workspaces.tiler.schedule(toplevel.server);
    return true;
}

fn releaseScrollingCover(toplevel: *Toplevel, saved: ?RestoreGeometry) void {
    toplevel.scroll_cover = false;
    // Force a size configure even if the tile returns to its old rectangle.
    toplevel.auto_target = null;
    toplevel.auto_restore = toplevel.auto_restore orelse saved;
}

pub fn setScrollingCover(toplevel: *Toplevel, rect: wlr.Box, animate: bool) void {
    const horizontal = if (toplevel.fullscreen) 0 else 2 * toplevel.borderWidth();
    const vertical = if (toplevel.fullscreen) 0 else toplevel.titlebarHeight() + toplevel.footerHeight();
    const target: RestoreGeometry = .{
        .x = rect.x,
        .y = rect.y,
        .width = @max(1, rect.width - horizontal),
        .height = @max(1, rect.height - vertical),
    };
    const geometry = if (toplevel.fullscreen) &toplevel.fullscreen_target else &toplevel.maximize_target;
    const previous = geometry.*;
    geometry.* = target;
    toplevel.scroll_cover = true;
    toplevel.pending_restore = null;
    const resized = if (previous) |old| old.width != target.width or old.height != target.height else true;
    const moved = toplevel.x != target.x or toplevel.y != target.y;
    if (moved) {
        if (animate) toplevel.setPositionAnimated(target.x, target.y) else toplevel.setPosition(target.x, target.y);
    }
    if (resized) {
        const wait: ConfigureWait = if (toplevel.backend == .xwayland and moved) .x11_commit else toplevel.requestSize(target.width, target.height);
        if (animate) toplevel.animateChromeSize(target.width, target.height, wait) else toplevel.finishSizeAnimation();
    }
    if (moved or resized) toplevel.notifyLayoutChanged();
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
    toplevel.syncXdgEdges();
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
    defer toplevel.syncXdgEdges();
    const footer = if (toplevel.hasServerDecorations()) chrome.frameBorder() else 0;
    const target: RestoreGeometry = .{
        .x = rect.x,
        .y = rect.y,
        .width = @max(1, rect.width - 2 * toplevel.borderWidth()),
        .height = @max(1, rect.height - toplevel.titlebarHeight() - footer),
    };
    // An unchanged tile keeps a glide in flight (an earlier reflow, a restore).
    if (toplevel.auto_target) |previous| {
        if (std.meta.eql(previous, target)) return;
        // Only moved, as when a strip scrolls: the client hears nothing (X11
        // gets its new position through commitPosition, as on a canvas pan).
        if (previous.width == target.width and previous.height == target.height) {
            toplevel.auto_target = target;
            toplevel.pending_restore = null;
            // Already a tile, so it glides even while its open animation's
            // tail runs, as split tiles do: columns opening or closing beside
            // a window that just opened push it aside smoothly.
            if (animate) toplevel.setPositionAnimated(target.x, target.y) else toplevel.setPosition(target.x, target.y);
            toplevel.notifyLayoutChanged();
            return;
        }
    }
    const was_tiled = toplevel.auto_target != null;
    const glide = animate and (was_tiled or !toplevel.map_motion.active());
    if (!glide) toplevel.finishSizeAnimation();
    if (toplevel.auto_restore == null) toplevel.auto_restore = toplevel.rememberGeometry();
    toplevel.auto_target = target;
    toplevel.pending_restore = null;
    toplevel.clearZoomBoost();
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
    toplevel.syncXdgEdges();
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
    clearManualLayout(toplevel);
}

/// Release fullscreen, maximize and snap before the strip places the window.
/// Keep its origin until then so the reflow carries its dialogs by the same distance.
pub fn prepareAutoTile(toplevel: *Toplevel) void {
    const saved = toplevel.auto_restore orelse toplevel.tile_restore orelse toplevel.maximize_restore orelse toplevel.fullscreen_restore;
    if (toplevel.fullscreen) leaveFullscreen(toplevel, false);
    clearManualLayout(toplevel);
    toplevel.auto_restore = saved;
}

fn clearManualLayout(toplevel: *Toplevel) void {
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
    if (toplevel.scroll_cover and !toplevel.fullscreen) releaseScrollingCover(toplevel, toplevel.maximize_restore);
    toplevel.syncXdgEdges();
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
    if (was_tiled) toplevel.syncXdgEdges();
}

pub fn syncXdgEdges(toplevel: *Toplevel) void {
    if (toplevel.backend != .xdg or toplevel.backend_gone) return;
    const top = toplevel.backend.xdg.xdg_toplevel;
    const all: wlr.Edges = .{ .top = true, .bottom = true, .left = true, .right = true };
    const tiled: wlr.Edges = if (toplevel.tile) |tile| tiling.tiledEdges(tile) else if (toplevel.auto_target != null) all else .{};
    var constrained = tiled;
    if (toplevel.maximized or toplevel.fullscreen) {
        constrained = all;
    } else if (toplevel.auto_target != null and toplevel.workspace_id != 0 and toplevel.tile == null) {
        const tree = &toplevel.server.world.workspaces.tiler.trees[toplevel.workspace_id - 1];
        const edges = tree.outerEdges(@import("../auto_tiling.zig").key(toplevel));
        constrained = .{ .top = edges.contains(.up), .bottom = edges.contains(.down), .left = edges.contains(.left), .right = edges.contains(.right) };
    }
    if (!std.meta.eql(top.scheduled.tiled, tiled)) _ = top.setTiled(tiled);
    if (!std.meta.eql(top.scheduled.constrained, constrained)) _ = top.setConstrained(constrained);
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
    if (toplevel.fullscreen) {
        leaveFullscreen(toplevel, true);
        return;
    }

    const output = toplevel.currentOutput() orelse return;
    toplevel.setFullscreenOn(output);
}

fn leaveFullscreen(toplevel: *Toplevel, restore: bool) void {
    toplevel.fullscreen = false;
    const in_strip = restore and queueScrollingCover(toplevel);
    defer toplevel.syncXdgEdges();
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setFullscreen(false),
        .xwayland => |*adapter| adapter.xsurface.setFullscreen(false),
        .placeholder, .shell => {},
    }
    toplevel.fullscreen_target = null;
    const saved = toplevel.fullscreen_restore;
    toplevel.fullscreen_restore = null;
    if (in_strip) {
        if (toplevel.maximized) {
            // The client size still reflects the fullscreen configure.
            toplevel.maximize_target = null;
        } else releaseScrollingCover(toplevel, saved);
    } else {
        toplevel.scroll_cover = false;
        if (restore) if (saved) |geometry| toplevel.restoreGeometry(geometry);
    }
    toplevel.notifyLayoutChanged();
    toplevel.server.refreshTaskbars();
}

pub fn beginMove(toplevel: *Toplevel) void {
    toplevel.server.input.startMove(toplevel);
}
