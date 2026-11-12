//! Toplevel placement: remembered geometry, forced geometry and initial rules.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const Server = @import("../Server.zig");
const chrome = @import("../chrome.zig");
const xdg = @import("../xdg.zig");
const window_rules = @import("config").window_rules;
const RestoreGeometry = Toplevel.RestoreGeometry;

pub fn rememberGeometry(toplevel: *const Toplevel) RestoreGeometry {
    const client = toplevel.clientGeometry();
    return .{
        .x = toplevel.x,
        .y = toplevel.y,
        .width = client.width,
        .height = client.height,
    };
}

/// Immediate floating placement, with no deferred restore that can undo a drag.
pub fn restoreGeometryNow(toplevel: *Toplevel, saved: RestoreGeometry) void {
    toplevel.pending_restore = null;
    toplevel.finishSizeAnimation();
    var x = saved.x;
    var y = saved.y;
    if (@import("../workspaces.zig").outputFor(toplevel)) |output| {
        // A restore may have been captured before transfer or hot-unplug.
        // Keep its titlebar on the workspace's current output.
        const usable = output.usableBox();
        const width = saved.width +| (2 * toplevel.borderWidth());
        const height = saved.height +| toplevel.titlebarHeight() +| toplevel.footerHeight();
        x = std.math.clamp(x, usable.x, usable.x + @max(0, usable.width - width));
        y = std.math.clamp(y, usable.y, usable.y + @max(0, usable.height - height));
    }
    toplevel.setPosition(x, y);
    _ = toplevel.requestSize(saved.width, saved.height);
}

pub fn restoreGeometry(toplevel: *Toplevel, saved: RestoreGeometry) void {
    toplevel.pending_restore = saved;
    _ = toplevel.requestSizeAnimated(saved.width, saved.height);
    toplevel.setPositionAnimated(saved.x, saved.y);
    toplevel.scheduleForcedGeometry();
}

pub fn forcedGeometry(toplevel: *const Toplevel) ?RestoreGeometry {
    return toplevel.fullscreen_target orelse toplevel.maximize_target orelse toplevel.tile_target orelse toplevel.auto_target orelse toplevel.pending_restore;
}

pub fn applyForcedGeometry(toplevel: *Toplevel) c_int {
    const forced = toplevel.forcedGeometry() orelse return 0;
    if (toplevel.auto_target != null and !toplevel.maximized and !toplevel.fullscreen) {
        // Automatic frames must not inherit a size-animation endpoint computed
        // with the old maximized/fullscreen decorations before the xdg ack.
        toplevel.finishSizeAnimation();
        _ = toplevel.requestSize(forced.width, forced.height);
        toplevel.setPosition(forced.x, forced.y);
    } else {
        _ = toplevel.requestSizeAnimated(forced.width, forced.height);
        toplevel.setPositionAnimated(forced.x, forced.y);
    }
    toplevel.pending_restore = null;
    return 0;
}

pub fn scheduleForcedGeometry(toplevel: *Toplevel) void {
    if (toplevel.forced_geometry_timer == null) {
        toplevel.forced_geometry_timer = toplevel.server.wl_server.getEventLoop().addTimer(
            *Toplevel,
            applyForcedGeometry,
            toplevel,
        ) catch return;
    }
    toplevel.forced_geometry_timer.?.timerUpdate(25) catch {};
}

// Maximizing fits the window into its output's usable area (the full output
// minus the taskbar's exclusive strip), so it sits above the bar rather than
// under it. The compositor owns the position as well as the requested client
// size, so it also owns and restores both values on un-maximize.
pub fn toggleMaximize(toplevel: *Toplevel) void {
    toplevel.setMaximized(!toplevel.maximized);
}

pub fn currentIdentity(toplevel: *Toplevel) window_rules.WindowIdentity {
    return switch (toplevel.backend) {
        .xdg => |*adapter| .{
            .tag = @import("../extra_protocols.zig").tag(toplevel.surface(), false) orelse "",
            .app_id = if (adapter.xdg_toplevel.app_id) |s| std.mem.span(s) else "",
            .title = if (adapter.xdg_toplevel.title) |s| std.mem.span(s) else "",
            .backend = .xdg,
            .dialog = toplevel.parentWindow() != null or adapter.xdg_toplevel.parent != null,
        },
        .xwayland => |*adapter| .{
            .app_id = "",
            .title = if (adapter.xsurface.title) |s| std.mem.span(s) else "",
            .x11_class = if (adapter.xsurface.class) |s| std.mem.span(s) else "",
            .x11_instance = if (adapter.xsurface.instance) |s| std.mem.span(s) else "",
            .backend = .xwayland,
            .dialog = toplevel.parentWindow() != null or adapter.xsurface.parent != null,
        },
        .shell => .{
            .app_id = toplevel.appId(),
            .title = toplevel.title(),
            .backend = .xdg,
            .dialog = false,
        },
        .placeholder => |*ph| .{
            .app_id = ph.app_id,
            .title = ph.name,
            .backend = .xdg,
            .dialog = false,
        },
    };
}

pub fn resolveTargetOutput(toplevel: *const Toplevel) ?*Output {
    if (toplevel.open_rules.getOutput()) |name| {
        if (toplevel.server.findOutputByName(name)) |out| {
            return out;
        }
    }
    return toplevel.server.getDefaultOutput();
}

/// The output the window's center currently sits over, falling back to its
/// resolved target output (e.g. before it has ever been placed in the
/// layout). Used to decide which output's taskbar a fullscreen window
/// should suppress.
pub fn currentOutput(toplevel: *const Toplevel) ?*Output {
    if (@import("../workspaces.zig").outputFor(toplevel)) |output| return output;
    const center = toplevel.frameWorld(@floatFromInt(@divTrunc(toplevel.chrome_width, 2)), @floatFromInt(@divTrunc(toplevel.chrome_height, 2)));
    const layout_center = toplevel.server.world.toLayout(center.x, center.y);
    return Output.atLayout(toplevel.server, layout_center.x, layout_center.y) orelse toplevel.resolveTargetOutput();
}

pub fn resolveInitialRules(toplevel: *Toplevel) void {
    if (toplevel.rules_resolved) return;
    toplevel.rules_resolved = true;
    const id = toplevel.currentIdentity();
    if (id.app_id.len == 0 and toplevel.backend == .xdg) {
        toplevel.resolved_before_app_id = true;
    }
    const resolved = window_rules.resolve(toplevel.server.config.window_rules, id);
    toplevel.open_rules = window_rules.OpenRules.fromResolved(resolved);
    toplevel.live_rules = window_rules.LiveRules.fromResolved(resolved);
    toplevel.matched_rules = resolved.matched_rules;
}

pub fn pickInitialPlacement(
    server: *Server,
    output: *Output,
    open_rules: window_rules.OpenRules,
    parent: ?*Toplevel,
    w: i32,
    h: i32,
) RestoreGeometry {
    const usable = output.usableBox();
    var rx: i32 = undefined;
    var ry: i32 = undefined;

    if (open_rules.center orelse false) {
        const lx = usable.x + @divTrunc(usable.width - w, 2);
        const ly = usable.y + @divTrunc(usable.height - h, 2);
        const pt = server.world.toWorld(@floatFromInt(lx), @floatFromInt(ly));
        rx = @intFromFloat(@round(pt.x));
        ry = @intFromFloat(@round(pt.y));
    } else if (open_rules.x != null or open_rules.y != null) {
        const lx = usable.x + (open_rules.x orelse 0);
        const ly = usable.y + (open_rules.y orelse 0);
        const pt = server.world.toWorld(@floatFromInt(lx), @floatFromInt(ly));
        rx = @intFromFloat(@round(pt.x));
        ry = @intFromFloat(@round(pt.y));
    } else if (parent) |p| {
        rx = p.x + 30;
        ry = p.y + 30;
    } else {
        const cascade = @mod(@as(i32, @intCast(server.world.toplevels.length())) * 30, 240);
        const pt = server.world.toWorld(@floatFromInt(usable.x + 50 + cascade), @floatFromInt(usable.y + 50 + cascade));
        rx = @intFromFloat(@round(pt.x));
        ry = @intFromFloat(@round(pt.y));
    }

    return .{ .x = rx, .y = ry, .width = w, .height = h };
}

pub fn setupInitialRestoreGeometry(toplevel: *Toplevel, output: *Output) void {
    const rw: i32 = @intCast(toplevel.open_rules.width orelse 640);
    const rh: i32 = @intCast(toplevel.open_rules.height orelse 480);
    const geom = pickInitialPlacement(toplevel.server, output, toplevel.open_rules, toplevel.parentWindow(), rw, rh);
    if (toplevel.maximize_restore == null) toplevel.maximize_restore = geom;
    if (toplevel.fullscreen_restore == null) toplevel.fullscreen_restore = geom;
}

pub fn configureInitialXdgState(toplevel: *Toplevel) void {
    const adapter = switch (toplevel.backend) {
        .xdg => |*a| a,
        .xwayland, .placeholder, .shell => return,
    };

    const maybe_ph = toplevel.placeholder_source orelse toplevel.findMatchingPlaceholder();
    if (maybe_ph) |ph_top| {
        toplevel.placeholder_source = ph_top;
        ph_top.backend.placeholder.matched = true;
        const is_dialog = toplevel.parentWindow() != null or adapter.xdg_toplevel.parent != null;
        if (!is_dialog) {
            const ph = &ph_top.backend.placeholder;
            if (ph_top.isMaximized()) {
                _ = adapter.xdg_toplevel.setMaximized(true);
                toplevel.maximized = true;
                _ = adapter.xdg_toplevel.setSize(ph.client_width, ph.client_height);
                toplevel.maximize_target = ph_top.maximize_target;
                toplevel.maximize_restore = ph_top.maximize_restore;
                toplevel.placed = true;
                return;
            } else if (ph_top.isFullscreen()) {
                _ = adapter.xdg_toplevel.setFullscreen(true);
                toplevel.fullscreen = true;
                _ = adapter.xdg_toplevel.setSize(ph.client_width, ph.client_height);
                toplevel.fullscreen_target = ph_top.fullscreen_target;
                toplevel.fullscreen_restore = ph_top.fullscreen_restore;
                toplevel.placed = true;
                return;
            } else {
                _ = adapter.xdg_toplevel.setSize(ph.client_width, ph.client_height);
                toplevel.setPosition(ph_top.x, ph_top.y);
                toplevel.placed = true;
                return;
            }
        }
    }

    const target_out = toplevel.resolveTargetOutput();
    const rule_fs = toplevel.open_rules.fullscreen;
    const rule_max = toplevel.open_rules.maximized;

    const want_fs = if (rule_fs) |v| v else adapter.xdg_toplevel.requested.fullscreen;
    const want_max = if (want_fs) false else (if (rule_max) |v| v else adapter.xdg_toplevel.requested.maximized);

    if (want_fs) {
        _ = adapter.xdg_toplevel.setFullscreen(true);
        toplevel.fullscreen = true;
        if (target_out) |out| {
            var box: wlr.Box = undefined;
            toplevel.server.output_layout.getBox(out.wlr_output, &box);
            _ = adapter.xdg_toplevel.setSize(box.width, box.height);
            toplevel.setupInitialRestoreGeometry(out);
            toplevel.fullscreen_target = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        }
    } else if (want_max) {
        _ = adapter.xdg_toplevel.setMaximized(true);
        toplevel.maximized = true;
        if (target_out) |out| {
            const usable = out.usableBox();
            const footer = if (toplevel.hasServerDecorations()) chrome.frameBorder() else 0;
            const mw = usable.width - 2 * toplevel.borderWidth();
            const mh = usable.height - toplevel.titlebarHeight() - footer;
            _ = adapter.xdg_toplevel.setSize(@max(1, mw), @max(1, mh));
            toplevel.setupInitialRestoreGeometry(out);
            toplevel.maximize_target = .{ .x = usable.x, .y = usable.y, .width = @max(1, mw), .height = @max(1, mh) };
        }
    } else {
        if (rule_max != null and !rule_max.?) {
            _ = adapter.xdg_toplevel.setMaximized(false);
        }
        if (rule_fs != null and !rule_fs.?) {
            _ = adapter.xdg_toplevel.setFullscreen(false);
        }
        const w: i32 = @intCast(toplevel.open_rules.width orelse 0);
        const h: i32 = @intCast(toplevel.open_rules.height orelse 0);
        _ = adapter.xdg_toplevel.setSize(w, h);
    }
}
