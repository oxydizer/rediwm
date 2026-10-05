const std = @import("std");

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");

const gpa = @import("main.zig").gpa;
const scene_data = @import("scene_data.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const Toplevel = @import("Toplevel.zig");

const Popup = @This();

const log = std.log.scoped(.popup);

xdg_popup: *wlr.XdgPopup,
server: *Server,

commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
destroy: wl.Listener(void) = .init(handleDestroy),

pub fn create(server: *Server, xdg_popup: *wlr.XdgPopup) !void {
    const xdg_surface = xdg_popup.base;

    // Safer than `.?`: a popup whose parent has already been destroyed must
    // be skipped rather than crashing the compositor.
    const parent_surface = xdg_popup.parent orelse {
        log.err("Popup.create: popup has no parent surface", .{});
        return error.PopupHasNoParent;
    };
    const parent = wlr.XdgSurface.tryFromWlrSurface(parent_surface) orelse {
        log.err("Popup.create: parent is not an xdg surface", .{});
        return error.PopupHasNoParent;
    };
    const parent_tree = scene_data.xdgSceneTree(parent) orelse {
        // The xdg surface user data could be left null due to allocation failure.
        log.err("Popup.create: parent has no scene tree", .{});
        return error.PopupHasNoParent;
    };
    const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch |err| {
        log.err("Popup.create: could not create scene tree: {}", .{err});
        return err;
    };
    errdefer scene_tree.node.destroy(); // gpa.create below must not leak the node

    const popup = gpa.create(Popup) catch |err| {
        log.err("Popup.create: could not allocate popup: {}", .{err});
        return err;
    };
    errdefer gpa.destroy(popup);

    popup.* = .{
        .xdg_popup = xdg_popup,
        .server = server,
    };
    scene_data.setXdgSceneTree(xdg_surface, scene_tree);

    xdg_surface.surface.events.commit.add(&popup.commit);
    xdg_popup.events.destroy.add(&popup.destroy);
}

/// Tell wlroots the usable screen area so its xdg-positioner constraint
/// logic (slide/flip/resize, per the client's positioner rules) can keep the
/// popup on screen. Without this a menu opened near an output edge — a
/// browser's right-click context menu is the common case — is placed at its
/// naive anchor position and runs off screen with no correction.
///
/// Must not run before the popup's initial commit: wlroots'
/// `wlr_xdg_popup_unconstrain_from_box` calls `wlr_xdg_surface_schedule_configure`
/// internally, which asserts `surface->initialized`. Calling this from
/// `create()` — before the client's first commit — aborted the whole
/// compositor on every single popup, which is why `handleCommit` is where
/// this runs instead.
///
/// Derives the popup's immediate parent from `xdg_popup.parent`, which may
/// itself be a popup (a submenu). `wlr_xdg_popup_unconstrain_from_box` wants
/// the box in the coordinate system of the *root* toplevel surface, so walk
/// up the parent chain to find it first.
fn unconstrainToOutput(server: *Server, xdg_popup: *wlr.XdgPopup) void {
    const parent_surface = xdg_popup.parent orelse return;
    const parent = wlr.XdgSurface.tryFromWlrSurface(parent_surface) orelse return;
    const root = findRootXdgSurface(parent);
    const root_tree = scene_data.xdgSceneTree(root) orelse return;
    var ox: i32 = 0;
    var oy: i32 = 0;
    _ = root_tree.node.coords(&ox, &oy);

    const box = (if (Toplevel.fromSurface(server, root.surface)) |toplevel|
        windowConstraintBox(server, toplevel, ox, oy)
    else
        layoutConstraintBox(server, ox, oy)) orelse return;
    xdg_popup.unconstrainFromBox(&box);
}

/// Popups of layer surfaces live in layout space, like the output box.
fn layoutConstraintBox(server: *Server, ox: i32, oy: i32) ?wlr.Box {
    const out = Output.atLayout(server, @floatFromInt(ox), @floatFromInt(oy)) orelse server.getDefaultOutput() orelse return null;
    const usable = out.usableBox();
    return .{
        .x = usable.x - ox,
        .y = usable.y - oy,
        .width = usable.width,
        .height = usable.height,
    };
}

/// The visible part of the output in the coordinates of a window popup's root
/// surface at (`ox`, `oy`) in the source tree. Window trees are in world space
/// and only the projection applies the camera and the window's own scale
/// (around the frame origin), so the layout box has to go back through both.
/// Using the layout box as is constrained popups to the world's first screen:
/// a window panned or zoomed into view from elsewhere had its menu slid to the
/// far left.
fn windowConstraintBox(server: *Server, toplevel: *Toplevel, ox: i32, oy: i32) ?wlr.Box {
    var frame_x: i32 = 0;
    var frame_y: i32 = 0;
    _ = toplevel.frame_tree.node.coords(&frame_x, &frame_y);
    const scale = toplevel.worldScale();
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    const fx: f64 = @floatFromInt(frame_x);
    const fy: f64 = @floatFromInt(frame_y);
    // The root surface's origin relative to the frame, in client units.
    const rx: f64 = @floatFromInt(ox - frame_x);
    const ry: f64 = @floatFromInt(oy - frame_y);

    // Where the root surface is on screen picks the output.
    const origin = server.world.toLayout(fx + rx * scale, fy + ry * scale);
    const out = Output.atLayout(server, origin.x, origin.y) orelse server.getDefaultOutput() orelse return null;
    const usable = out.usableBox();
    const lo = server.world.toWorld(@floatFromInt(usable.x), @floatFromInt(usable.y));
    const hi = server.world.toWorld(@floatFromInt(usable.x + usable.width), @floatFromInt(usable.y + usable.height));

    const left = @floor((lo.x - fx) / scale - rx);
    const top = @floor((lo.y - fy) / scale - ry);
    const right = @ceil((hi.x - fx) / scale - rx);
    const bottom = @ceil((hi.y - fy) / scale - ry);
    return .{
        .x = wireCoordinate(left),
        .y = wireCoordinate(top),
        .width = wireCoordinate(right - left),
        .height = wireCoordinate(bottom - top),
    };
}

/// Client-facing coordinates are 32-bit; extreme zoom must not trap.
fn wireCoordinate(value: f64) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(std.math.clamp(value, @as(f64, std.math.minInt(i32)), @as(f64, std.math.maxInt(i32))));
}

fn findRootXdgSurface(xdg_surface: *wlr.XdgSurface) *wlr.XdgSurface {
    var current = xdg_surface;
    while (current.role == .popup) {
        const p = current.role_data.popup orelse break;
        const parent_surface = p.parent orelse break;
        current = wlr.XdgSurface.tryFromWlrSurface(parent_surface) orelse break;
    }
    return current;
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const popup: *Popup = @fieldParentPtr("commit", listener);
    if (popup.xdg_popup.base.initial_commit) {
        unconstrainToOutput(popup.server, popup.xdg_popup);
        _ = popup.xdg_popup.base.scheduleConfigure();
    }
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const popup: *Popup = @fieldParentPtr("destroy", listener);

    popup.commit.link.remove();
    popup.destroy.link.remove();

    gpa.destroy(popup);
}
