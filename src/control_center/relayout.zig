//! Applying pending changes, rebuilding the tree and relayout on resize.

const std = @import("std");
const gpa = @import("../main.zig").gpa;
const anim = @import("ui").anim;
const ui = @import("ui");
const layout = ui.layout;
const display_section = @import("sections/display.zig");
const appearance_section = @import("sections/appearance.zig");
const services_section = @import("sections/services.zig");
const bluetooth_section = @import("sections/bluetooth.zig");
const network_section = @import("sections/network.zig");
const log = std.log.scoped(.control_center);
const welcome_section = @import("welcome.zig");
const settings_search = @import("search.zig");
const Page = @import("search_index.zig").Page;
const panel = @import("panel.zig");
const sidebarWidth = panel.sidebarWidth;
const ControlCenter = @import("ControlCenter.zig");

pub fn applyOutputPatch(cc: *ControlCenter, output: *@import("../Output.zig"), patch: @import("config").output_config.Patch) void {
    cc.display.failed = false;
    cc.display.save_failed = false;
    output.applyAndPersist(patch) catch |err| {
        log.warn("could not apply display settings: {}", .{err});
        if (err == error.OutputSaveFailed) cc.display.save_failed = true else cc.display.failed = true;
    };
}

pub fn applyPending(cc: *ControlCenter) void {
    if (cc.search.pending_result != null) {
        settings_search.apply(cc);
        return;
    }
    if (cc.page == .services) services_section.apply(&cc.services, cc);
    cc.shortcuts.apply(cc);
    if (cc.page == .power) @import("sections/power.zig").apply(cc);
    if (cc.page == .displays) {
        const arranged = display_section.pendingArrangement(&cc.display);
        if (arranged) |placements| {
            cc.display.failed = false;
            cc.display.save_failed = false;
            @import("../Output.zig").arrange(cc.server, placements) catch |err| {
                log.warn("could not arrange displays: {}", .{err});
                if (err == error.OutputSaveFailed) cc.display.save_failed = true else cc.display.failed = true;
            };
        }
        const picked = display_section.pendingArrangementSelection(&cc.display);
        if (picked) |name| cc.selectDisplayOutput(name);
        if (arranged != null or picked != null) {
            cc.relayout();
            cc.requestRepaint();
            return;
        }
        if (display_section.pendingMakeMain(&cc.display)) {
            const output = @import("../Output.zig").fromWlr(cc.selectedDisplayOutput() orelse return) orelse return;
            cc.applyOutputPatch(output, .{ .primary = true });
            cc.relayout();
            cc.requestRepaint();
            return;
        }
        if (display_section.pendingScale(&cc.display)) |change| {
            const Output = @import("../Output.zig");
            const output = Output.fromWlr(cc.selectedDisplayOutput() orelse return) orelse return;
            const configured: ?f32 = switch (change) {
                .auto => null,
                .factor => |factor| factor,
            };
            cc.applyOutputPatch(output, .{ .scale = configured, .auto_scale = configured == null });
            cc.relayout();
            cc.requestRepaint();
            return;
        }
        if (display_section.pendingXwaylandScale(&cc.display)) |factor| {
            cc.display.failed = false;
            cc.display.save_failed = false;
            @import("config").setting_save.saveCompositor(gpa, cc.server.io, cc.server.config.path, "xwayland_scale", factor) catch |err| {
                log.warn("could not save Xwayland scale: {}", .{err});
                cc.display.save_failed = true;
            };
            if (!cc.display.save_failed) @import("../config_runtime/watcher.zig").reloadConfig(cc.server);
            cc.relayout();
            cc.requestRepaint();
            return;
        }
        if (display_section.pendingMode(&cc.display, cc.selectedDisplayOutput() orelse return)) |mode| {
            const output = @import("../Output.zig").fromWlr(cc.selectedDisplayOutput() orelse return) orelse return;
            cc.applyOutputPatch(output, .{ .width = mode.width, .height = mode.height, .refresh_mhz = mode.refresh });
            cc.relayout();
            cc.requestRepaint();
            return;
        }

        if (display_section.pendingTransform(&cc.display)) |transform| {
            const output = @import("../Output.zig").fromWlr(cc.selectedDisplayOutput() orelse return) orelse return;
            cc.applyOutputPatch(output, .{ .transform = transform });
            cc.relayout();
            cc.requestRepaint();
        }
    }
    if (cc.pending_page) |page| {
        cc.pending_page = null;
        cc.selectPage(page);
    }
}

/// `buildTree`, keeping each slider's hover and feedback look and each
/// switch's slide across it when the page is the same: a theme slider's save
/// rebuilds the page the moment the button is released, under a pointer that
/// is still on it, and a switch's change rebuilds before its knob has moved.
pub fn rebuildTree(cc: *ControlCenter) void {
    const hovered_nav = if (cc.nav_hover.target) |cell| blk: {
        const row: usize = @intCast(cell.row);
        break :blk if (row < cc.sidebar_children[1].children.len) cc.nav_rows[row].kind.row.id else null;
    } else null;
    const same_page = cc.built_page == cc.page;
    const bluetooth_scroll: ?layout.ScrollState = if (same_page and cc.page == .bluetooth and !cc.search.empty() and !cc.search.built_empty) cc.body_children[1].kind.scroll_container else null;
    var saved: ui.widgets.slider.Saved = .{};
    var knobs: ui.widgets.toggle.Saved = .{};
    var menu: ui.widgets.select.Saved = .{};
    if (same_page) {
        ui.widgets.slider.capture(&cc.root, &saved);
        ui.widgets.toggle.capture(&cc.root, &knobs);
        if (!cc.search.request_focus) ui.widgets.select.capture(&cc.root, &menu, ui.input.current.focused);
    }
    cc.buildTree();
    if (hovered_nav) |id| {
        if (cc.navIndex(@fromBackingInt(@intCast(id)))) |row| {
            cc.nav_hover.setTarget(anim.nowMs(), .{ .col = 0, .row = @intCast(row) });
            cc.nav_rows[row].kind.row.state = .hover;
            ui.input.adoptHover(&cc.root, &cc.nav_rows[row]);
        } else cc.nav_hover.setTarget(anim.nowMs(), null);
    }
    if (bluetooth_scroll) |state| cc.body_children[1].kind.scroll_container = state;
    if (same_page) {
        if (ui.widgets.slider.restore(&cc.root, &saved)) |hovered| ui.input.adoptHover(&cc.root, hovered);
        ui.widgets.toggle.restore(&cc.root, &knobs);
        if (ui.widgets.select.restore(&cc.root, &menu)) |widget| ui.input.current.focus(&cc.root, widget);
    }
}

pub fn relayout(cc: *ControlCenter) void {
    cc.layout_pending = false;
    if (cc.panel_box.width <= 0 or cc.panel_box.height <= 0) return;
    cc.rebuildTree();
    cc.layoutContent();
    cc.scheduleFrame();
}

pub fn layoutContent(cc: *ControlCenter) void {
    cc.background.invalidate();
    const width: f32 = @floatFromInt(cc.panel_box.width);
    const height: f32 = @floatFromInt(cc.panel_box.height);
    if (cc.search.restore_scroll and cc.body_children[1].kind == .scroll_container) {
        cc.body_children[1].kind.scroll_container = cc.search.saved_scroll;
        cc.search.restore_scroll = false;
    }
    ui.measure.measure(&cc.root, width, height);
    ui.arrange.arrange(&cc.root, 0, 0, width, height);
    if (!cc.search.empty() and ui.input.current.focused != &cc.search.field) {
        if (cc.page == .appearance) appearance_section.restoreItemFocus(&cc.appearance);
        if (cc.page == .network) network_section.restoreFocus(&cc.network, cc);
        if (cc.page == .bluetooth) bluetooth_section.restoreFocus(&cc.bluetooth, cc);
        if (cc.page == .printers) cc.printers.restoreFocus(cc);
    }
    settings_search.reveal(cc);
    cc.dirty = true;
}

/// Only structural breakpoints need a new tree. Ordinary resize frames
/// retain fields, scroll positions and settings data (including filesystem lists).
pub fn resizeNeedsTree(cc: *const ControlCenter) bool {
    if (cc.is_welcome) return (cc.root.computed_width < 680) != (cc.panel_box.width < 680) or (cc.root.computed_height < 740) != welcome_section.compact(cc);
    const old = cc.root.computed_width;
    if ((old < 660) != (cc.panel_box.width < 660)) return true;
    const width: f32 = @floatFromInt(cc.panel_box.width);
    const nav_height_limit: f32 = if (width < 660 and cc.search.expanded) 486 else 440;
    if ((cc.root.computed_height < nav_height_limit) != (@as(f32, @floatFromInt(cc.panel_box.height)) < nav_height_limit)) return true;
    const thresholds: []const f32 = switch (cc.page) {
        .shortcuts => &.{660},
        .desktop => &.{760},
        .bluetooth => &.{ 900, 1000 },
        .network => &.{1000},
        .printers => &.{ 660, 760 },
        .region => &.{900},
        .services => &.{ 660, 752, 928, 1040 },
        else => &.{},
    };
    for (thresholds) |at| if ((old < at) != (width < at)) return true;
    return false;
}

pub fn resizeLayout(cc: *ControlCenter) void {
    if (cc.is_welcome) {
        cc.root.width = .{ .fixed = @floatFromInt(cc.panel_box.width) };
        cc.root.height = .{ .fixed = @floatFromInt(cc.panel_box.height) };
        return;
    }
    const narrow = cc.panel_box.width < 660;
    const nav_count = cc.sidebar_children[1].children.len;
    const gap: f32 = if (cc.panel_box.height < 550) 2 else 5;
    const height = @min(52, @max(24, (@as(f32, @floatFromInt(cc.panel_box.height)) - 92 - (if (narrow and cc.search.expanded) @as(f32, 46) else 0) - gap * @as(f32, @floatFromInt(nav_count -| 1))) / @as(f32, @floatFromInt(@max(1, nav_count)))));
    cc.body_children[0].width = .{ .fixed = sidebarWidth(cc) };
    cc.sidebar_children[1].gap = gap;
    for (cc.nav_rows[0..nav_count], 0..) |*row, i| {
        row.height = .{ .fixed = height };
        row.children = cc.nav_children[i][0..if (narrow) @as(usize, 1) else 2];
    }
    if (cc.page == .network) if (cc.network.list) |list| {
        list.height = .{ .fixed = @max(220, @as(f32, @floatFromInt(cc.panel_box.height)) - 345) };
    };
    if (cc.page == .bluetooth) if (cc.bluetooth.list) |list| {
        list.height = .{ .fixed = if (cc.panel_box.width < 1000) 220 else @max(240, @as(f32, @floatFromInt(cc.panel_box.height)) - 270) };
    };
    cc.root.width = .{ .fixed = @floatFromInt(cc.panel_box.width) };
    cc.root.height = .{ .fixed = @floatFromInt(cc.panel_box.height) };
    cc.root.linkParents();
}

pub fn navIndex(cc: *const ControlCenter, page: Page) ?usize {
    if (cc.is_welcome) return null;
    for (cc.sidebar_children[1].children, 0..) |row, i| {
        if (row.kind.row.id == @backingInt(page)) return i;
    }
    return null;
}
