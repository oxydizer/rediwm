// Typed identity stored in `wlr.SceneNode.data` (and the matching xdg-surface
// user pointer used to parent popups).
//
// Invariant: every non-null `SceneNode.data` in this compositor is a
// `*SceneData`. Hit-testing must go through `fromNode` / `hitTest` rather than
// casting the opaque pointer to a window or widget type.
const wlr = @import("wlroots");

const ControlCenter = @import("control_center/panel.zig").ControlCenter;
const StartMenu = @import("start_menu/panel.zig").StartMenu;
const PowerMenu = @import("power_menu.zig").PowerMenu;
const Taskbar = @import("Taskbar.zig");
const Toplevel = @import("Toplevel.zig");
const geometry = @import("geometry.zig");

pub const SceneData = struct {
    role: Role,

    pub const Role = union(enum) {
        /// Frame tree of a window; walking parents from a client surface lands here.
        toplevel: *Toplevel,
        layer: *@import("LayerSurface.zig"),
        /// Titlebar, footer, or border rect belonging to a window.
        chrome: *Toplevel,
        /// Taskbar strip for one output.
        taskbar: *Taskbar,
        calendar: *@import("calendar.zig").Calendar,
        battery_popup: *@import("battery_popup.zig").Popup,
        wifi_popup: *@import("network/popup.zig").Popup,
        /// Control center panel opened from the taskbar's R button.
        control_center: *ControlCenter,
        /// Start menu panel opened from the taskbar's start button.
        start_menu: *StartMenu,
        /// Centered session-actions modal opened from the start menu's power button.
        power_menu: *PowerMenu,
        /// Notification toast card.
        toast: *@import("notifications/toast.zig").Toast,
        /// Override-redirect X11 window (menu/tooltip). No chrome.
        xwayland_unmanaged: *@import("xwayland_unmanaged.zig"),
        mini_map: *@import("mini_map.zig"),
        /// A tile of the compositor-drawn desktop.
        desktop: *@import("desktop/embedded.zig").Desktop,
    };

    pub fn attach(data: *SceneData, node: *wlr.SceneNode) void {
        node.data = data;
    }

    pub fn fromNode(node: *wlr.SceneNode) ?*SceneData {
        const ptr = node.data orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn fromNodeOrParents(node: *wlr.SceneNode) ?*SceneData {
        var current: ?*wlr.SceneNode = node;
        while (current) |n| {
            if (fromNode(n)) |data| return data;
            current = if (n.parent) |tree| &tree.node else null;
        }
        return null;
    }
};

pub const Hit = union(enum) {
    none,
    input_popup: struct { surface: *wlr.Surface, sx: f64, sy: f64 },
    layer: struct { owner: *@import("LayerSurface.zig"), surface: *wlr.Surface, sx: f64, sy: f64 },
    chrome: Chrome,
    surface: Surface,
    taskbar: TaskbarHit,
    wifi_popup: struct { popup: *@import("network/popup.zig").Popup, sx: f64, sy: f64 },
    battery_popup: struct { popup: *@import("battery_popup.zig").Popup, sx: f64, sy: f64 },
    calendar: struct { calendar: *@import("calendar.zig").Calendar, sx: f64, sy: f64 },
    control_center: ControlCenterHit,
    start_menu: StartMenuHit,
    power_menu: PowerMenuHit,
    toast: ToastHit,
    xwayland_unmanaged: UnmanagedHit,
    mini_map: *@import("mini_map.zig"),
    /// Desktop-local logical coordinates, already mapped through the camera.
    desktop: struct { desktop: *@import("desktop/embedded.zig").Desktop, x: f64, y: f64 },

    pub const ToastHit = struct {
        toast: *@import("notifications/toast.zig").Toast,
        sx: f64,
        sy: f64,
    };

    pub const Chrome = struct {
        toplevel: *Toplevel,
        sx: f64,
        sy: f64,
    };

    pub const Surface = struct {
        toplevel: *Toplevel,
        surface: *wlr.Surface,
        sx: f64,
        sy: f64,
    };

    pub const TaskbarHit = struct {
        bar: *Taskbar,
        sx: f64,
        sy: f64,
    };

    pub const ControlCenterHit = struct {
        cc: *ControlCenter,
        sx: f64,
        sy: f64,
    };

    pub const StartMenuHit = struct {
        menu: *StartMenu,
        sx: f64,
        sy: f64,
    };

    pub const PowerMenuHit = struct {
        menu: *PowerMenu,
        sx: f64,
        sy: f64,
    };

    pub const UnmanagedHit = struct {
        owner: *@import("xwayland_unmanaged.zig"),
        surface: *wlr.Surface,
        sx: f64,
        sy: f64,
    };
};

/// Layout point relative to an output-local shell node. Window frames use
/// Toplevel.frameLocal, and projected client buffers map through projection.c.
pub fn toNodeLocal(node: *wlr.SceneNode, lx: f64, ly: f64) geometry.Vec2 {
    var ox: i32 = 0;
    var oy: i32 = 0;
    _ = node.coords(&ox, &oy);
    return geometry.toLocal(lx, ly, ox, oy);
}

pub fn hitTest(server: *@import("Server.zig"), lx: f64, ly: f64) Hit {
    server.world.syncPresentation();
    const root = &server.scene.tree.node;
    var nx: f64 = undefined;
    var ny: f64 = undefined;
    const displayed = root.at(lx, ly, &nx, &ny) orelse return .none;
    var node = @import("projection.zig").source(displayed);

    // Let the latched preview receive input through other dimmed windows.
    // Shell UI and layers keep their normal priority, as do points outside
    // the selected window's input region. Reuse scene picking so subsurfaces,
    // popups, chrome and client input regions retain their normal semantics.
    if (server.world.peekTarget()) |selected| {
        if (SceneData.fromNodeOrParents(node)) |data| {
            const owner: ?*Toplevel = switch (data.role) {
                .toplevel => |t| t,
                .chrome => |t| t,
                else => null,
            };
            if (owner != null and owner != selected) {
                const local = selected.frameLocal(lx, ly);
                const frame = &selected.frame_tree.node;
                var sx: f64 = undefined;
                var sy: f64 = undefined;
                if (frame.at(local.x + @as(f64, @floatFromInt(frame.x)), local.y + @as(f64, @floatFromInt(frame.y)), &sx, &sy)) |picked| {
                    node = picked;
                    nx = sx;
                    ny = sy;
                }
            }
        }
    }

    if (SceneData.fromNode(node)) |data| {
        return switch (data.role) {
            .wifi_popup => |popup| blk: {
                const local = toNodeLocal(&popup.buffer_node.node, lx, ly);
                break :blk .{ .wifi_popup = .{ .popup = popup, .sx = local.x, .sy = local.y } };
            },
            .battery_popup => |popup| blk: {
                const local = toNodeLocal(&popup.buffer_node.node, lx, ly);
                break :blk .{ .battery_popup = .{ .popup = popup, .sx = local.x, .sy = local.y } };
            },
            .calendar => |calendar| blk: {
                const local = toNodeLocal(&calendar.buffer_node.node, lx, ly);
                break :blk .{ .calendar = .{ .calendar = calendar, .sx = local.x, .sy = local.y } };
            },
            .taskbar => |bar| blk: {
                const local = toNodeLocal(&bar.buffer_node.node, lx, ly);
                break :blk .{ .taskbar = .{ .bar = bar, .sx = local.x, .sy = local.y } };
            },
            .chrome => |toplevel| blk: {
                const local = toplevel.frameLocal(lx, ly);
                break :blk .{ .chrome = .{ .toplevel = toplevel, .sx = local.x, .sy = local.y } };
            },
            .control_center => |cc| blk: {
                const local = cc.localPoint(lx, ly);
                break :blk .{ .control_center = .{ .cc = cc, .sx = local.x, .sy = local.y } };
            },
            .start_menu => |menu| blk: {
                const local = toNodeLocal(&menu.buffer_node.node, lx, ly);
                break :blk .{ .start_menu = .{ .menu = menu, .sx = local.x, .sy = local.y } };
            },
            .power_menu => |menu| blk: {
                const local = toNodeLocal(&menu.buffer_node.node, lx, ly);
                break :blk .{ .power_menu = .{ .menu = menu, .sx = local.x, .sy = local.y } };
            },
            .toast => |t| blk: {
                const local = toNodeLocal(&t.buffer_node.node, lx, ly);
                break :blk .{ .toast = .{ .toast = t, .sx = local.x, .sy = local.y } };
            },
            .mini_map => |map| .{ .mini_map = map },
            .desktop => |desktop| blk: {
                const local = desktop.localPoint(lx, ly);
                // Points the desktop declines (icon-only input) are empty world.
                if (!desktop.accepts(local.x, local.y)) break :blk .none;
                break :blk .{ .desktop = .{ .desktop = desktop, .x = local.x, .y = local.y } };
            },
            // The frame tree itself is not a pickable leaf.
            .toplevel, .layer, .xwayland_unmanaged => .none,
        };
    }

    if (node.type != .buffer) return .none;
    const scene_surface = wlr.SceneSurface.tryFromBuffer(wlr.SceneBuffer.fromNode(node)) orelse return .none;
    if (wlr.InputPopupSurfaceV2.tryFromWlrSurface(scene_surface.surface.getRootSurface()) != null) {
        return .{ .input_popup = .{ .surface = scene_surface.surface, .sx = nx, .sy = ny } };
    }
    const data = SceneData.fromNodeOrParents(node) orelse return .none;
    return switch (data.role) {
        .toplevel => |toplevel| .{ .surface = .{
            .toplevel = toplevel,
            .surface = scene_surface.surface,
            .sx = nx,
            .sy = ny,
        } },
        .layer => |owner| .{ .layer = .{ .owner = owner, .surface = scene_surface.surface, .sx = nx, .sy = ny } },
        .xwayland_unmanaged => |owner| .{ .xwayland_unmanaged = .{
            .owner = owner,
            .surface = scene_surface.surface,
            .sx = nx,
            .sy = ny,
        } },
        else => .none,
    };
}

/// xdg_surface.data holds the scene tree created for that surface so popups
/// can parent themselves without walking the compositor's own objects.
pub fn setXdgSceneTree(xdg_surface: *wlr.XdgSurface, tree: *wlr.SceneTree) void {
    xdg_surface.data = tree;
}

pub fn xdgSceneTree(xdg_surface: *wlr.XdgSurface) ?*wlr.SceneTree {
    const ptr = xdg_surface.data orelse return null;
    return @ptrCast(@alignCast(ptr));
}
