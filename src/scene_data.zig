// Typed identity stored in `Node.data` (and the matching xdg-surface
// user pointer used to parent popups).
//
// Invariant: every non-null `Node.data` of a window, shell panel or layer is a
// `*SceneData`. Hit-testing must go through `fromNode` / `hitTest` rather than
// casting the opaque pointer to a window or widget type.
const wlr = @import("wlroots");
const sn = @import("node.zig");

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
        dock: *@import("Dock.zig"),
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

    pub fn attach(data: *SceneData, node: *sn.Node) void {
        node.data = data;
    }

    pub fn fromNode(node: *sn.Node) ?*SceneData {
        const ptr = node.data orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn fromNodeOrParents(node: *sn.Node) ?*SceneData {
        var current: ?*sn.Node = node;
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
    dock: struct { dock: *@import("Dock.zig"), sx: f64, sy: f64 },
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
pub fn toNodeLocal(node: *sn.Node, lx: f64, ly: f64) geometry.Vec2 {
    var ox: i32 = 0;
    var oy: i32 = 0;
    _ = node.coords(&ox, &oy);
    return geometry.toLocal(lx, ly, ox, oy);
}

/// What an own node of the shell is, from its role.
fn shellHit(data: *SceneData, lx: f64, ly: f64) Hit {
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
            .dock => |dock| blk: {
                const local = toNodeLocal(&dock.tree.?.node, lx, ly);
                break :blk .{ .dock = .{ .dock = dock, .sx = local.x, .sy = local.y } };
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

pub fn hitTest(server: *@import("Server.zig"), lx: f64, ly: f64) Hit {
    server.world.syncPresentationForInput();
    const projection = server.world.projection;
    var hit = projection.nodeAt(lx, ly) orelse return .none;

    // Let the latched preview receive input through other dimmed windows.
    // Shell UI and layers keep their normal priority, as do points outside
    // the selected window's input region. Pick among the selected window's own
    // leaves, so subsurfaces, popups, chrome and client input regions retain their
    // normal semantics.
    if (server.world.peekTarget()) |selected| {
        if (SceneData.fromNodeOrParents(hit.own)) |data| {
            const owner: ?*Toplevel = switch (data.role) {
                .toplevel => |t| t,
                .chrome => |t| t,
                else => null,
            };
            if (owner != null and owner != selected) {
                if (projection.nodeAtIn(&selected.frame_tree.node, lx, ly)) |picked| hit = picked;
            }
        }
    }
    const nx = hit.x;
    const ny = hit.y;

    // A client's surface: the role is the window, layer or X11 menu it is a part of.
    if (hit.own.buffer()) |buffer| if (buffer.surface) |scene_surface| {
        const surface = scene_surface.surface;
        if (wlr.InputPopupSurfaceV2.tryFromWlrSurface(surface.getRootSurface()) != null) {
            return .{ .input_popup = .{ .surface = surface, .sx = nx, .sy = ny } };
        }
        const data = SceneData.fromNodeOrParents(hit.own) orelse return .none;
        return switch (data.role) {
            .toplevel => |toplevel| .{ .surface = .{ .toplevel = toplevel, .surface = surface, .sx = nx, .sy = ny } },
            .layer => |owner| .{ .layer = .{ .owner = owner, .surface = surface, .sx = nx, .sy = ny } },
            .xwayland_unmanaged => |owner| .{ .xwayland_unmanaged = .{ .owner = owner, .surface = surface, .sx = nx, .sy = ny } },
            else => .none,
        };
    };

    // An own node of the shell: its role says what it is.
    const data = SceneData.fromNodeOrParents(hit.own) orelse return .none;
    return shellHit(data, lx, ly);
}

/// xdg_surface.data holds the scene tree created for that surface so popups
/// can parent themselves without walking the compositor's own objects.
pub fn setXdgSceneTree(xdg_surface: *wlr.XdgSurface, tree: *sn.Tree) void {
    xdg_surface.data = tree;
}

pub fn xdgSceneTree(xdg_surface: *wlr.XdgSurface) ?*sn.Tree {
    const ptr = xdg_surface.data orelse return null;
    return @ptrCast(@alignCast(ptr));
}
