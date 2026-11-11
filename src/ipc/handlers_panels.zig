//! IPC panel registry: the shell panels widget queries can resolve.

const std = @import("std");
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const ControlCenter = @import("../control_center/panel.zig").ControlCenter;
const protocol = @import("protocol.zig");
const ui = @import("ui");

pub const ClipRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn intersect(a: ClipRect, b: ClipRect) ClipRect {
        const x1 = @max(a.x, b.x);
        const y1 = @max(a.y, b.y);
        const x2 = @min(a.x + a.width, b.x + b.width);
        const y2 = @min(a.y + a.height, b.y + b.height);
        return .{
            .x = x1,
            .y = y1,
            .width = @max(0, x2 - x1),
            .height = @max(0, y2 - y1),
        };
    }
};

pub const PanelRoot = struct {
    root: *ui.layout.Widget,
    box: wlr.Box,
};

pub const PanelRegistryEntry = struct {
    name: []const u8,
    resolve: *const fn (*Output) ?PanelRoot,
};

pub fn resolveStartMenu(out: *Output) ?PanelRoot {
    const sm = out.start_menu orelse return null;
    return .{ .root = &sm.root, .box = sm.panel_box };
}

pub fn resolveControlCenter(out: *Output) ?PanelRoot {
    const cc = out.server.input.open_control_center orelse return null;
    return .{ .root = &cc.root, .box = cc.screenBox() };
}

pub fn controlCenterState(cc: *const ControlCenter, now: i64) protocol.PanelStateData {
    const box = cc.screenBox();
    const toplevel = cc.toplevel;
    const opened = toplevel.map_motion.settled(now) and toplevel.map_opacity.settled(now);
    return .{
        .state = if (toplevel.minimized) "minimized" else "open",
        .progress = toplevel.map_opacity.value(now),
        .is_settled = opened and cc.settled(),
        .box = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height },
        .category = @tagName(cc.page),
    };
}

pub fn resolvePowerMenu(out: *Output) ?PanelRoot {
    const pm = out.power_menu orelse return null;
    return .{ .root = &pm.root, .box = pm.panel_box };
}

pub fn resolveDock(output: *Output) ?PanelRoot {
    if (!output.dock.visible) return null;
    return .{ .root = &output.dock.root, .box = output.dock.box };
}

pub fn resolveWindowPicker(output: *Output) ?PanelRoot {
    const menu = &output.server.input.window_menu;
    if (menu.output != output or menu.node == null or menu.window_ids.len == 0) return null;
    return .{ .root = &menu.picker_root, .box = menu.box };
}

/// The taskbar's input source list: rows `source_<n>` and `input_settings`.
pub fn resolveInputSources(output: *Output) ?PanelRoot {
    const menu = &output.server.input.window_menu;
    if (menu.output != output or menu.node == null or !menu.sources) return null;
    return .{ .root = &menu.picker_root, .box = menu.box };
}

pub const panel_registry = [_]PanelRegistryEntry{
    .{ .name = "dock", .resolve = resolveDock },
    .{ .name = "window_picker", .resolve = resolveWindowPicker },
    .{ .name = "input_sources", .resolve = resolveInputSources },
    .{ .name = "start_menu", .resolve = resolveStartMenu },
    .{ .name = "control_center", .resolve = resolveControlCenter },
    .{ .name = "power_menu", .resolve = resolvePowerMenu },
};
