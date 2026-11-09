//! Toplevel configure handshake with the client and backend identity.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const xscale = @import("../xwayland_scale.zig");
const wlr = @import("wlroots");
const chrome = @import("../chrome.zig");
const window_shape = @import("ui").window_shape;
const theme = @import("ui").theme;
const resize = @import("../resize.zig");
const scene_data = @import("../scene_data.zig");
const xdg = @import("../xdg.zig");
const ConfigureWait = Toplevel.ConfigureWait;
const surface = Toplevel.surface;
const nowMs = Toplevel.nowMs;

pub fn setResizing(toplevel: *Toplevel, resizing: bool) void {
    toplevel.wakeCornerAccents();
    switch (toplevel.backend) {
        .xdg => |*adapter| _ = adapter.xdg_toplevel.setResizing(resizing),
        .xwayland, .placeholder, .shell => {},
    }
}

pub fn requestSize(toplevel: *Toplevel, width: i32, height: i32) ConfigureWait {
    return switch (toplevel.backend) {
        .xdg => |*adapter| .{ .xdg_serial = adapter.xdg_toplevel.setSize(width, height) },
        .xwayland => |*adapter| blk: {
            const n = toplevel.surfaceScale();
            adapter.configure(
                xscale.surfacePosition((toplevel.x + toplevel.borderWidth()), n),
                xscale.surfacePosition((toplevel.y + toplevel.titlebarHeight()), n),
                xscale.surfaceLength(width, n),
                xscale.surfaceLength(height, n),
            );
            break :blk .x11_commit;
        },
        .placeholder => |*ph| {
            ph.client_width = width;
            ph.client_height = height;
            toplevel.syncChrome(true, nowMs()) catch {};
            return .none;
        },
        .shell => |*sw| {
            sw.client_width = @max(if (sw.control_center) |cc| cc.minimumWidth() else 1, width);
            sw.client_height = @max(if (sw.control_center) |cc| cc.minimumHeight() else 1, height);
            if (sw.control_center) |cc| cc.resize(sw.client_width, sw.client_height);
            toplevel.positionDuringResize();
            // Shell windows have no client commit to update their shadow.
            toplevel.syncChrome(true, nowMs()) catch {};
            return .none;
        },
    };
}

pub fn configureCompleted(toplevel: *const Toplevel, wait: ConfigureWait) bool {
    return switch (wait) {
        .none => true,
        .x11_commit => false,
        .xdg_serial => |serial| switch (toplevel.backend) {
            .xdg => |*adapter| adapter.xdg_toplevel.base.current.configure_serial >= serial,
            .xwayland, .placeholder, .shell => false,
        },
    };
}

pub fn scheduledSerial(toplevel: *const Toplevel) u32 {
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.base.scheduled_serial,
        .xwayland, .placeholder, .shell => 0,
    };
}

pub fn ackSerial(toplevel: *const Toplevel) u32 {
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.base.current.configure_serial,
        .xwayland, .placeholder, .shell => 0,
    };
}

pub fn backendName(toplevel: *const Toplevel) []const u8 {
    return switch (toplevel.backend) {
        .xdg => "xdg",
        .xwayland => "xwayland",
        .placeholder => "placeholder",
        .shell => "shell",
    };
}

pub fn x11Class(toplevel: *const Toplevel) ?[]const u8 {
    return switch (toplevel.backend) {
        .xdg, .placeholder, .shell => null,
        .xwayland => |*adapter| if (adapter.xsurface.class) |c| std.mem.span(c) else null,
    };
}

pub fn x11Instance(toplevel: *const Toplevel) ?[]const u8 {
    return switch (toplevel.backend) {
        .xdg, .placeholder, .shell => null,
        .xwayland => |*adapter| if (adapter.xsurface.instance) |c| std.mem.span(c) else null,
    };
}

/// Resolve the mapped owner live, for both native and X11 transient windows.
pub fn owner(toplevel: *Toplevel) ?*Toplevel {
    return toplevel.parentWindow();
}

pub fn cornerRadius(toplevel: *const Toplevel) f32 {
    return if (toplevel.isMaximized() or toplevel.isFullscreen()) 0 else chrome.frameRadius() * toplevel.chromeDensity();
}

/// The window's polygon outline for a frame of `width` x `height` (the theme's
/// `window_shape`), or null for the rounded rectangle: maximized and fullscreen
/// windows are square, and an outline that does not parse or cannot be drawn is
/// ignored (the theme loader refuses one that does not parse).
pub fn shapePolygon(toplevel: *const Toplevel, width: i32, height: i32) ?window_shape.Resolved {
    if (!chrome.polygons or toplevel.isMaximized() or toplevel.isFullscreen() or width <= 0 or height <= 0) return null;
    const outline = (window_shape.parse(theme.global.window_shape) catch return null) orelse return null;
    const resolved = window_shape.resolve(outline, @floatFromInt(width), @floatFromInt(height), toplevel.chromeDensity());
    return if (window_shape.usable(resolved)) resolved else null;
}

/// What the window's polygon depends on beyond its size, for memos: the outline's
/// text and the density its px coordinates scale with. 0 without a polygon.
pub fn shapeKey(toplevel: *const Toplevel) u64 {
    if (theme.global.window_shape.len == 0) return 0;
    const density: u32 = @bitCast(toplevel.chromeDensity());
    return std.hash.Wyhash.hash(density, theme.global.window_shape) | 1;
}

/// How far the titlebar's icon and controls keep in from the left and right of a
/// polygon outline's slanted or cut ends (zero for the rounded rectangle), over the
/// rows they occupy. The titlebar raster, the control hit tests and the tab strip
/// all lay out against the frame less these.
pub fn controlInsets(toplevel: *const Toplevel) window_shape.Insets {
    const polygon = toplevel.shapePolygon(toplevel.chrome_width, toplevel.chrome_height) orelse return .{};
    const density = toplevel.chromeDensity();
    const bar: f64 = @floatFromInt(toplevel.titlebarHeight());
    const band: f64 = @floatFromInt((chrome.Metrics{ .density = density }).length(34));
    var insets = window_shape.rowInsets(polygon, @floatFromInt(toplevel.chrome_width), @max(0, (bar - band) / 2), @min(bar, (bar + band) / 2));
    if (theme.global.chrome_control_offset_y == 0) return insets;
    // The icon stays centred while controls may sit lower under a cut corner.
    const control = chrome.controlRectScaled(toplevel.chrome_width, .close, density);
    insets.right = window_shape.rowInsets(polygon, @floatFromInt(toplevel.chrome_width), @floatFromInt(control.y), @floatFromInt(control.y + control.h)).right;
    return insets;
}

pub fn ownsSurface(toplevel: *const Toplevel, candidate: *wlr.Surface) bool {
    const owned = surface(toplevel) orelse return false;
    if (owned == candidate) return true;
    return candidate.getRootSurface() == owned;
}

pub fn attachSceneData(toplevel: *Toplevel) void {
    toplevel.frame_data = .{ .role = .{ .toplevel = toplevel } };
    toplevel.chrome_data = .{ .role = .{ .chrome = toplevel } };
    scene_data.SceneData.attach(&toplevel.frame_data, &toplevel.frame_tree.node);
    scene_data.SceneData.attach(&toplevel.chrome_data, &toplevel.shadow_tree.node);
    scene_data.SceneData.attach(&toplevel.chrome_data, &toplevel.shadow_node.node);
    scene_data.SceneData.attach(&toplevel.chrome_data, &toplevel.resize_grab.node);
    scene_data.SceneData.attach(&toplevel.chrome_data, &toplevel.titlebar_buffer.node);
    for (toplevel.frame_fills) |rect| {
        scene_data.SceneData.attach(&toplevel.chrome_data, &rect.node);
    }
    for (toplevel.border_rects) |rect| {
        scene_data.SceneData.attach(&toplevel.chrome_data, &rect.node);
    }
}
