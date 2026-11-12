//! Toplevel accessors: surface, title, app id, client geometry and basic state.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const xscale = @import("../xwayland_scale.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const Server = @import("../Server.zig");
const ControlCenter = @import("../control_center/panel.zig").ControlCenter;
const chrome = @import("../chrome.zig");
const window_shape = @import("ui").window_shape;
const geometry = @import("../geometry.zig");
const resize = @import("../resize.zig");
const scene_data = @import("../scene_data.zig");
const events = @import("../ipc/events.zig");
const protocol = @import("../ipc/protocol.zig");
const xdg = @import("../xdg.zig");
const xwayland_surface = @import("../xwayland_surface.zig");
const settings_app_id = Toplevel.settings_app_id;
const welcome_app_id = Toplevel.welcome_app_id;

/// Window that owns `surface`, walking xdg popup parents and subsurface roots.
pub fn fromSurface(server: *Server, candidate: *wlr.Surface) ?*Toplevel {
    var current: *wlr.Surface = candidate;
    var guard: usize = 0;
    while (guard < 32) : (guard += 1) {
        var it = server.world.toplevels.iterator(.forward);
        while (it.next()) |toplevel| {
            if (toplevel.surface()) |owned| {
                if (owned == current) return toplevel;
            }
        }
        if (wlr.XdgSurface.tryFromWlrSurface(current)) |xdg_surface| {
            if (xdg_surface.role == .popup) {
                if (xdg_surface.role_data.popup) |popup| {
                    if (popup.parent) |parent| {
                        current = parent;
                        continue;
                    }
                }
            }
        }
        if (wlr.XwaylandSurface.tryFromWlrSurface(current)) |xs| {
            var xit = server.world.toplevels.iterator(.forward);
            while (xit.next()) |toplevel| {
                switch (toplevel.backend) {
                    .xwayland => |*adapter| if (adapter.xsurface == xs) return toplevel,
                    .xdg, .placeholder, .shell => {},
                }
            }
            if (xs.parent) |parent| {
                if (parent.surface) |ps| {
                    current = ps;
                    continue;
                }
            }
        }
        const root = current.getRootSurface();
        if (root != current) {
            current = root;
            continue;
        }
        return null;
    }
    return null;
}

pub fn surface(toplevel: *const Toplevel) ?*wlr.Surface {
    if (toplevel.backend_gone) return null;
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.base.surface,
        .xwayland => |*adapter| adapter.xsurface.surface,
        .placeholder, .shell => null,
    };
}

pub fn title(toplevel: *const Toplevel) []const u8 {
    return titleOrNull(toplevel) orelse "";
}

pub fn titleOrNull(toplevel: *const Toplevel) ?[]const u8 {
    const ptr = titlePtr(toplevel) orelse return null;
    return std.mem.span(ptr);
}

pub fn titlePtr(toplevel: *const Toplevel) ?[*:0]const u8 {
    if (toplevel.backend_gone) return null;
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.title,
        .xwayland => |*adapter| adapter.xsurface.title,
        .placeholder => |*ph| ph.name.ptr,
        .shell => |shell| if (shell.welcome) @import("i18n").trZ("Welcome to RediWM").ptr else @import("i18n").trZ("RediWM Settings").ptr,
    };
}

pub fn appId(toplevel: *const Toplevel) []const u8 {
    return appIdOrNull(toplevel) orelse "";
}

pub fn appIdOrNull(toplevel: *const Toplevel) ?[]const u8 {
    return std.mem.span(toplevel.appIdPtr() orelse return null);
}

pub fn appIdPtr(toplevel: *const Toplevel) ?[*:0]const u8 {
    if (toplevel.backend_gone) return null;
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.app_id,
        .xwayland => |*adapter| adapter.xsurface.class orelse adapter.xsurface.instance,
        .placeholder => |*ph| ph.app_id.ptr,
        .shell => |shell| if (shell.welcome) welcome_app_id.ptr else settings_app_id.ptr,
    };
}

pub fn surfaceScale(toplevel: *const Toplevel) f64 {
    return switch (toplevel.backend) {
        .xwayland => toplevel.server.xwaylandScale(),
        else => 1,
    };
}

pub fn clientSurfaceGeometry(toplevel: *const Toplevel) wlr.Box {
    if (toplevel.backend_gone) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.base.geometry,
        .xwayland => |*adapter| blk: {
            if (adapter.xsurface.surface) |s| {
                if (s.current.width > 0 and s.current.height > 0) {
                    break :blk .{ .x = 0, .y = 0, .width = s.current.width, .height = s.current.height };
                }
            }
            break :blk .{
                .x = 0,
                .y = 0,
                .width = @intCast(adapter.xsurface.width),
                .height = @intCast(adapter.xsurface.height),
            };
        },
        .placeholder => |*ph| .{
            .x = 0,
            .y = 0,
            .width = ph.client_width,
            .height = ph.client_height,
        },
        .shell => |*sw| .{
            .x = 0,
            .y = 0,
            .width = sw.client_width,
            .height = sw.client_height,
        },
    };
}

pub fn clientGeometry(toplevel: *const Toplevel) wlr.Box {
    var geom = toplevel.clientSurfaceGeometry();
    const n = toplevel.surfaceScale();
    if (n > 1) {
        if (geom.width > 0) geom.width = xscale.worldLength(geom.width, n);
        if (geom.height > 0) geom.height = xscale.worldLength(geom.height, n);
    }
    return geom;
}

pub fn clientPid(toplevel: *const Toplevel) ?i32 {
    return switch (toplevel.backend) {
        .xdg => {
            const owned = surface(toplevel) orelse return null;
            return owned.resource.getClient().getCredentials().pid;
        },
        .xwayland => |*adapter| adapter.xsurface.pid,
        .placeholder => |*ph| ph.pid,
        .shell => null,
    };
}

pub fn waylandClient(toplevel: *const Toplevel) ?*wl.Client {
    return switch (toplevel.backend) {
        .xdg => {
            const owned = surface(toplevel) orelse return null;
            return owned.resource.getClient();
        },
        .xwayland, .placeholder, .shell => null,
    };
}

pub fn sandboxInfo(toplevel: *const Toplevel) ?protocol.WindowSandboxData {
    const client = toplevel.waylandClient() orelse return null;
    const sc_mgr = toplevel.server.security_context orelse return null;
    const state = sc_mgr.lookupClient(client) orelse return null;
    return .{
        .engine = if (state.sandbox_engine) |s| std.mem.span(s) else null,
        .app_id = if (state.app_id) |s| std.mem.span(s) else null,
        .instance_id = if (state.instance_id) |s| std.mem.span(s) else null,
    };
}

/// Urgency requests never raise, restore or move a window. Focus acknowledges
/// attention; repeat requests with the same effective state are silent.
pub fn setUrgent(toplevel: *Toplevel, urgent: bool) void {
    if (!toplevel.in_world or toplevel.closing or toplevel.backend_gone) return;
    const focused = if (toplevel.server.input.seat.keyboard_state.focused_surface) |surface_ptr|
        fromSurface(toplevel.server, surface_ptr) == toplevel
    else
        false;
    const wanted = urgent and !focused;
    if (toplevel.backend == .xwayland) toplevel.backend.xwayland.setDemandsAttention(wanted);
    if (toplevel.needs_attention == wanted) return;
    toplevel.needs_attention = wanted;
    toplevel.server.refreshTaskbars();
    if (toplevel.server.ipc) |ipc| events.onWindowUrgencyChanged(ipc, toplevel.id, wanted);
}

pub fn isMapped(toplevel: *const Toplevel) bool {
    if (toplevel.closing or toplevel.backend_gone) return false;
    if (toplevel.backend == .shell) return true;
    const owned = surface(toplevel) orelse return false;
    return owned.mapped;
}

pub fn isMaximized(toplevel: *const Toplevel) bool {
    if (toplevel.backend_gone) return toplevel.maximized;
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.current.maximized,
        .xwayland, .placeholder, .shell => toplevel.maximized,
    };
}

pub fn isFullscreen(toplevel: *const Toplevel) bool {
    if (toplevel.backend_gone) return toplevel.fullscreen;
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.current.fullscreen,
        .xwayland, .placeholder, .shell => toplevel.fullscreen,
    };
}

pub fn isInitialized(toplevel: *const Toplevel) bool {
    return switch (toplevel.backend) {
        .xdg => |*adapter| adapter.xdg_toplevel.base.initialized,
        // Not just `xsurface.surface != null`: that flips true as soon as the
        // X11 window is associated with a wl_surface, but scene_tree isn't a
        // tracked subsurface tree (wlr_scene_subsurface_tree_create) until
        // attachXwaylandScene actually runs — and a scene_destroy in between
        // (replaceDestroyedXwaylandScene) can drop back to an untracked plain
        // tree while the surface stays associated. `scene_attached` is the
        // precise, current state of scene_tree itself.
        .xwayland => |*adapter| adapter.scene_attached,
        .placeholder, .shell => true,
    };
}

pub fn parentWindow(toplevel: *Toplevel) ?*Toplevel {
    switch (toplevel.backend) {
        .xdg => |*adapter| {
            const parent_xdg = adapter.xdg_toplevel.parent orelse return null;
            var it = toplevel.server.world.toplevels.iterator(.forward);
            while (it.next()) |other| {
                switch (other.backend) {
                    .xdg => |*other_adapter| {
                        if (other_adapter.xdg_toplevel == parent_xdg) return other;
                    },
                    .xwayland, .placeholder, .shell => {},
                }
            }
            return null;
        },
        .xwayland => |*adapter| {
            const parent_xs = adapter.xsurface.parent orelse return null;
            var it = toplevel.server.world.toplevels.iterator(.forward);
            while (it.next()) |other| {
                switch (other.backend) {
                    .xwayland => |*other_adapter| {
                        if (other_adapter.xsurface == parent_xs) return other;
                    },
                    .xdg, .placeholder, .shell => {},
                }
            }
            return null;
        },
        .placeholder, .shell => return null,
    }
}

pub fn sizeConstraints(toplevel: *const Toplevel) resize.SizeConstraints {
    switch (toplevel.backend) {
        .xdg => |*adapter| {
            const current = &adapter.xdg_toplevel.current;
            const pending = &adapter.xdg_toplevel.pending;
            return .{
                .min_width = if (pending.min_width > 0) pending.min_width else current.min_width,
                .max_width = if (pending.max_width > 0) pending.max_width else current.max_width,
                .min_height = if (pending.min_height > 0) pending.min_height else current.min_height,
                .max_height = if (pending.max_height > 0) pending.max_height else current.max_height,
                .control_min_width = 100,
            };
        },
        .xwayland => |*adapter| {
            const hints: ?*const xwayland_surface.SizeHints = if (adapter.xsurface.size_hints) |ptr|
                @ptrCast(@alignCast(ptr))
            else
                null;
            var c = xwayland_surface.sizeConstraintsOf(hints);
            const n = toplevel.surfaceScale();
            if (n > 1) {
                if (c.min_width > 0) c.min_width = xscale.worldLength(c.min_width, n);
                if (c.min_height > 0) c.min_height = xscale.worldLength(c.min_height, n);
                if (c.max_width > 0) c.max_width = xscale.worldFloor(c.max_width, n);
                if (c.max_height > 0) c.max_height = xscale.worldFloor(c.max_height, n);
            }
            return c;
        },
        .placeholder => return .{
            .min_width = 100,
            .max_width = 0,
            .min_height = 100,
            .max_height = 0,
            .control_min_width = 100,
        },
        .shell => |sw| return .{
            .min_width = if (sw.control_center) |cc| cc.minimumWidth() else ControlCenter.min_width,
            .max_width = 0,
            .min_height = if (sw.control_center) |cc| cc.minimumHeight() else ControlCenter.min_height,
            .max_height = 0,
            .control_min_width = 100,
        },
    }
}

// A point is the frame's only if it falls inside the window's shape. The
// coordinates are frame-local.
pub fn insideFrame(toplevel: *Toplevel, px: f32, py: f32) bool {
    if (!toplevel.hasServerDecorations()) return false;
    const width = toplevel.chrome_width;
    const height = toplevel.chrome_height;
    if (width <= 0 or height <= 0) return false;

    if (toplevel.shapePolygon(width, height)) |polygon| {
        return chrome.coverage(@floatCast(window_shape.sdPolygon(polygon, px, py))) != 0;
    }
    const radius: f32 = toplevel.cornerRadius();
    return chrome.coverage(chrome.sdRoundedBox(
        px,
        py,
        0,
        0,
        @floatFromInt(width),
        @floatFromInt(height),
        radius,
    )) != 0;
}

pub fn isResizing(toplevel: *Toplevel) bool {
    const session = toplevel.server.input.resize_session orelse return false;
    return session.includes(toplevel);
}

pub fn isGeometrySettled(toplevel: *Toplevel, now_ms: i64) bool {
    if (toplevel.isResizing()) return false;
    return toplevel.move_x.settled(now_ms) and toplevel.move_y.settled(now_ms) and
        toplevel.size_w.settled(now_ms) and toplevel.size_h.settled(now_ms) and
        toplevel.drag_lift.settled(now_ms) and
        toplevel.switch_x.settled(now_ms) and toplevel.switch_y.settled(now_ms) and
        (toplevel.launch_origin == null or toplevel.map_motion.settled(now_ms));
}

pub fn chromeAcceptsInput(buffer: *sn.Buffer, sx: *f64, sy: *f64) callconv(.c) bool {
    const data = scene_data.SceneData.fromNode(&buffer.node) orelse return false;
    if (data.role == .chrome and data.role.chrome.closing) return false;
    const toplevel = switch (data.role) {
        .chrome => |t| t,
        else => return false,
    };
    var ox: i32 = 0;
    var oy: i32 = 0;
    _ = buffer.node.coords(&ox, &oy);
    var fx: i32 = 0;
    var fy: i32 = 0;
    _ = toplevel.frame_tree.node.coords(&fx, &fy);
    const local = geometry.toLocal(@as(f64, @floatFromInt(ox)) + sx.*, @as(f64, @floatFromInt(oy)) + sy.*, fx, fy);
    const has_control = toplevel.controlAt(local.x, local.y) != null or toplevel.tabAt(local.x, local.y) != .none;
    if (resize.detectResizeEdges(local.x, local.y, toplevel.chrome_width, toplevel.chrome_height, toplevel.titlebarHeight(), chrome.frameBorder(), chrome.frameBorder(), has_control) != null) {
        return true;
    }

    const px = @as(f32, @floatCast(local.x)) + 0.5;
    const py = @as(f32, @floatCast(local.y)) + 0.5;
    if (!toplevel.insideFrame(px, py)) return false;

    return local.y < @as(f64, @floatFromInt(toplevel.titlebarHeight()));
}
