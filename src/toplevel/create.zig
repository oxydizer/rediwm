//! Toplevel construction: xdg and Xwayland windows, placeholders and shell windows.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const Child = @import("../session/child.zig");
const glass = @import("../glass.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const col = @import("../color.zig");
const Server = @import("../Server.zig");
const ControlCenter = @import("../control_center/panel.zig").ControlCenter;
const chrome = @import("../chrome.zig");
const resize = @import("../resize.zig");
const scene_data = @import("../scene_data.zig");
const projection = @import("../projection.zig");
const theme = @import("ui").theme;
const events = @import("../ipc/events.zig");
const xdg = @import("../xdg.zig");
const gpa = @import("../main.zig").gpa;
const window_rules = @import("config").window_rules;
const window_sizes = @import("../window_sizes.zig");
const placeholder_match = @import("../placeholder_match.zig");
const applications = @import("../start_menu/applications.zig");
const ChromeNodes = Toplevel.ChromeNodes;
const chromeAcceptsInput = Toplevel.chromeAcceptsInput;
const nowMs = Toplevel.nowMs;
const pickInitialPlacement = Toplevel.pickInitialPlacement;

pub fn createChromeNodes(server: *Server) !ChromeNodes {
    const frame_tree = try server.world.tree.createSceneTree();
    errdefer frame_tree.node.destroy();
    // Hidden until handleMapped. An X11 window gets titled, configured and
    // chrome-synced long before it maps, and some never map at all; a visible
    // frame would be a clickable ghost for a window not in world.toplevels.
    frame_tree.node.setEnabled(false);
    if (!@import("../projection.zig").setTreeZoom(&frame_tree.node, 1)) return error.OutOfMemory;

    // Input only: no buffer, so never drawn. Gives the edges their reach past
    // the frame without depending on the shadow (`shadow_size = 0`). It sits in
    // a tree of its own so that the window's shape, which cuts the corners off
    // everything else under the frame, does not cut its reach: that must accept
    // points the shape declines.
    const reach_tree = try frame_tree.createSceneTree();
    _ = @import("../projection.zig").setTreeUnclipped(&reach_tree.node, true);
    const resize_grab = try reach_tree.createSceneBuffer(null);
    resize_grab.point_accepts_input = chromeAcceptsInput;

    const shadow_tree = try frame_tree.createSceneTree();
    // The shadow is outside the shape by definition.
    _ = @import("../projection.zig").setTreeUnclipped(&shadow_tree.node, true);
    const shadow_node = try shadow_tree.createSceneBuffer(null);
    shadow_node.point_accepts_input = chromeAcceptsInput;

    const titlebar_buffer = try frame_tree.createSceneBuffer(null);
    const glass_effect = glass.Engine.attach(server.glass_engine, titlebar_buffer, &shadow_tree.node, .titlebar);
    titlebar_buffer.setFilterMode(.bilinear);

    // The titlebar backs the ring at the top with its fill. Carry that same
    // chrome under the ring beside and below the client.
    var frame_fills: [3]*sn.Rect = undefined;
    for (&frame_fills) |*rect| {
        rect.* = try col.createRect(frame_tree, 1, 1, chrome.fillColor());
    }
    const border_color = chrome.borderColor(0);
    var border_rects: [4]*sn.Rect = undefined;
    for (&border_rects) |*rect| {
        rect.* = try col.createRect(frame_tree, 1, 1, border_color);
    }

    const content_tree = try frame_tree.createSceneTree();
    return .{
        .frame_tree = frame_tree,
        .shadow_tree = shadow_tree,
        .shadow_node = shadow_node,
        .resize_grab = resize_grab,
        .glass_effect = glass_effect,
        .titlebar_buffer = titlebar_buffer,
        .frame_fills = frame_fills,
        .border_rects = border_rects,
        .content_tree = content_tree,
    };
}

pub fn finishCreate(toplevel: *Toplevel, nodes: ChromeNodes, scene_tree: *sn.Node) void {
    toplevel.frame_tree = nodes.frame_tree;
    toplevel.shadow_tree = nodes.shadow_tree;
    toplevel.shadow_node = nodes.shadow_node;
    toplevel.resize_grab = nodes.resize_grab;
    toplevel.glass_effect = nodes.glass_effect;
    toplevel.titlebar_buffer = nodes.titlebar_buffer;
    toplevel.frame_fills = nodes.frame_fills;
    toplevel.border_rects = nodes.border_rects;
    toplevel.content_tree = nodes.content_tree;
    toplevel.scene_tree = scene_tree;
    toplevel.attachSceneData();
    nodes.titlebar_buffer.point_accepts_input = chromeAcceptsInput;
}

pub fn create(server: *Server, xdg_toplevel: *wlr.XdgToplevel) !void {
    const xdg_surface = xdg_toplevel.base;

    const toplevel = try gpa.create(Toplevel);
    errdefer gpa.destroy(toplevel);

    const nodes = try createChromeNodes(server);
    errdefer nodes.frame_tree.node.destroy();
    const hosted = try nodes.content_tree.createSceneXdgSurface(xdg_surface);
    const scene_tree = &hosted.node;

    toplevel.* = .{
        .server = server,
        .id = server.next_toplevel_id,
        .backend = .{ .xdg = .{
            .window = toplevel,
            .xdg_toplevel = xdg_toplevel,
        } },
        .frame_tree = nodes.frame_tree,
        .shadow_tree = nodes.shadow_tree,
        .shadow_node = nodes.shadow_node,
        .resize_grab = nodes.resize_grab,
        .glass_effect = nodes.glass_effect,
        .titlebar_buffer = nodes.titlebar_buffer,
        .frame_fills = nodes.frame_fills,
        .border_rects = nodes.border_rects,
        .content_tree = nodes.content_tree,
        .scene_tree = scene_tree,
    };
    server.next_toplevel_id += 1;
    finishCreate(toplevel, nodes, scene_tree);
    scene_data.setXdgSceneTree(xdg_surface, hosted);
    server.shell.kde_decorations.attach(toplevel);
    switch (toplevel.backend) {
        .xdg => |*adapter| adapter.listen(),
        .xwayland, .placeholder, .shell => {},
    }
}

pub fn createXwayland(server: *Server, xsurface: *wlr.XwaylandSurface) !void {
    const toplevel = try gpa.create(Toplevel);
    errdefer gpa.destroy(toplevel);

    const nodes = try createChromeNodes(server);
    errdefer nodes.frame_tree.node.destroy();
    const scale_n = server.xwaylandScale();
    if (scale_n > 1) {
        _ = @import("../projection.zig").setTreeScale(&nodes.content_tree.node, 1.0 / scale_n);
    }
    const placeholder = try nodes.content_tree.createSceneTree();
    const scene_tree = &placeholder.node;

    toplevel.* = .{
        .server = server,
        .id = server.next_toplevel_id,
        .backend = .{ .xwayland = .{
            .window = toplevel,
            .xsurface = xsurface,
        } },
        .maximized = xsurface.maximized_horz and xsurface.maximized_vert,
        .fullscreen = xsurface.fullscreen,
        .frame_tree = nodes.frame_tree,
        .shadow_tree = nodes.shadow_tree,
        .shadow_node = nodes.shadow_node,
        .resize_grab = nodes.resize_grab,
        .glass_effect = nodes.glass_effect,
        .titlebar_buffer = nodes.titlebar_buffer,
        .frame_fills = nodes.frame_fills,
        .border_rects = nodes.border_rects,
        .content_tree = nodes.content_tree,
        .scene_tree = scene_tree,
    };
    server.next_toplevel_id += 1;
    finishCreate(toplevel, nodes, scene_tree);
    xsurface.data = toplevel;
    switch (toplevel.backend) {
        .xdg, .placeholder, .shell => {},
        .xwayland => |*adapter| adapter.listen(),
    }
}

pub fn handleDelayTimeout(toplevel: *Toplevel) c_int {
    if (toplevel.backend != .placeholder) return 0;
    const ph = &toplevel.backend.placeholder;
    if (ph.delay_timer) |t| {
        t.remove();
        ph.delay_timer = null;
    }
    if (!ph.matched and !ph.cancelled and toplevel.in_world) {
        toplevel.frame_tree.node.setEnabled(@import("../window_tabs.zig").visible(toplevel));
        toplevel.server.scheduleFrames();
    }
    return 0;
}

pub fn handleLaunchTimeout(toplevel: *Toplevel) c_int {
    if (toplevel.backend != .placeholder) return 0;
    const ph = &toplevel.backend.placeholder;
    if (ph.timeout_timer) |t| {
        t.remove();
        ph.timeout_timer = null;
    }
    if (!ph.matched and !ph.cancelled) {
        if (toplevel.server.ipc) |ipc| {
            events.onLaunchTimeout(ipc, ph.desktop_id, ph.pid);
        }
        toplevel.destroyNow();
    }
    return 0;
}

// The launched process exited. The watch only observes: services owns the
// child status, and the watch ends itself once this returns.
pub fn handleChildExit(owner: ?*anyopaque, _: *Child, _: ?u32) void {
    const toplevel: *Toplevel = @ptrCast(@alignCast(owner.?));
    if (toplevel.backend != .placeholder) return;
    const ph = &toplevel.backend.placeholder;
    ph.child = null;
    if (!ph.matched and !ph.cancelled) {
        if (toplevel.server.ipc) |ipc| events.onLaunchTimeout(ipc, ph.desktop_id, ph.pid);
        toplevel.destroyNow();
    }
}

pub fn createPlaceholder(
    server: *Server,
    entry: *const applications.AppEntry,
    token_str: ?[]const u8,
) !*Toplevel {
    const toplevel = try gpa.create(Toplevel);
    errdefer gpa.destroy(toplevel);

    const nodes = try createChromeNodes(server);
    errdefer nodes.frame_tree.node.destroy();
    const placeholder = try nodes.content_tree.createSceneTree();
    const scene_tree = &placeholder.node;

    var init_w: i32 = 640;
    var init_h: i32 = 480;
    if (window_sizes.load(server.io, server.environ, entry.id)) |saved| {
        init_w = saved.width;
        init_h = saved.height;
    }

    const synth_id: window_rules.WindowIdentity = .{
        .app_id = if (entry.startup_wm_class) |wmc| wmc else entry.id,
        .title = entry.name,
        .backend = .xdg,
        .dialog = false,
    };
    const resolved = window_rules.resolve(server.config.window_rules, synth_id);
    const open_rules = window_rules.OpenRules.fromResolved(resolved);
    const live_rules = window_rules.LiveRules.fromResolved(resolved);
    if (open_rules.width) |rw| init_w = @intCast(rw);
    if (open_rules.height) |rh| init_h = @intCast(rh);

    const body_color = col.Straight.fromRgba(theme.global.window_bg).premultiply();
    const body_rect = try col.createRect(nodes.content_tree, init_w, init_h, body_color);

    const desktop_id = try gpa.dupeSentinel(u8, entry.id, 0);
    errdefer gpa.free(desktop_id);
    const name = try gpa.dupeSentinel(u8, entry.name, 0);
    errdefer gpa.free(name);
    const app_id = try gpa.dupeSentinel(u8, if (entry.startup_wm_class) |wmc| wmc else entry.id, 0);
    errdefer gpa.free(app_id);
    const startup_wm_class = if (entry.startup_wm_class) |wmc| try gpa.dupeSentinel(u8, wmc, 0) else null;
    errdefer if (startup_wm_class) |wmc| gpa.free(wmc);
    const icon = if (entry.icon) |ico| try gpa.dupeSentinel(u8, ico, 0) else null;
    errdefer if (icon) |ico| gpa.free(ico);
    const token = if (token_str) |tok| try gpa.dupeSentinel(u8, tok, 0) else null;
    errdefer if (token) |tok| gpa.free(tok);

    toplevel.* = .{
        .server = server,
        .id = server.next_toplevel_id,
        .backend = .{ .placeholder = .{
            .desktop_id = desktop_id,
            .name = name,
            .app_id = app_id,
            .startup_wm_class = startup_wm_class,
            .icon = icon,
            .token = token,
            .pid = null,
            .client_width = init_w,
            .client_height = init_h,
            .body_rect = body_rect,
            .launch_time_ms = nowMs(),
        } },
        .open_rules = open_rules,
        .live_rules = live_rules,
        .matched_rules = resolved.matched_rules,
        .rules_resolved = true,
        .frame_tree = nodes.frame_tree,
        .shadow_tree = nodes.shadow_tree,
        .shadow_node = nodes.shadow_node,
        .resize_grab = nodes.resize_grab,
        .glass_effect = nodes.glass_effect,
        .titlebar_buffer = nodes.titlebar_buffer,
        .frame_fills = nodes.frame_fills,
        .border_rects = nodes.border_rects,
        .content_tree = nodes.content_tree,
        .scene_tree = scene_tree,
    };
    server.next_toplevel_id += 1;
    finishCreate(toplevel, nodes, scene_tree);

    const target_out = toplevel.resolveTargetOutput() orelse server.getDefaultOutput();
    if (open_rules.fullscreen orelse false) {
        toplevel.fullscreen = true;
        if (target_out) |out| {
            var box: wlr.Box = undefined;
            server.output_layout.getBox(out.wlr_output, &box);
            toplevel.backend.placeholder.client_width = box.width;
            toplevel.backend.placeholder.client_height = box.height;
            toplevel.setupInitialRestoreGeometry(out);
            toplevel.fullscreen_target = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
            toplevel.setPosition(box.x, box.y);
            toplevel.placed = true;
        }
    } else if (open_rules.maximized orelse false) {
        toplevel.maximized = true;
        if (target_out) |out| {
            const usable = out.usableBox();
            const footer = chrome.frameBorder();
            const mw = usable.width - 2 * chrome.frameBorder();
            const mh = usable.height - toplevel.titlebarHeight() - footer;
            toplevel.backend.placeholder.client_width = @max(1, mw);
            toplevel.backend.placeholder.client_height = @max(1, mh);
            toplevel.setupInitialRestoreGeometry(out);
            toplevel.maximize_target = .{ .x = usable.x, .y = usable.y, .width = @max(1, mw), .height = @max(1, mh) };
            toplevel.setPosition(usable.x, usable.y);
            toplevel.placed = true;
        }
    } else if (target_out) |out| {
        const footer = chrome.frameBorder();
        const natural_w = init_w + 2 * chrome.frameBorder();
        const natural_h = init_h + toplevel.titlebarHeight() + footer;
        const geom = pickInitialPlacement(server, out, open_rules, null, natural_w, natural_h);
        toplevel.setPosition(geom.x, geom.y);
        toplevel.placed = true;
    }

    try toplevel.syncChrome(true, nowMs());

    server.world.toplevels.prepend(toplevel);
    toplevel.in_world = true;
    toplevel.server.world.workspaces.mapped(toplevel);
    if (server.layout_autosave) |autosave| autosave.finishMapped(toplevel);
    server.world.focus(toplevel);
    server.refreshTaskbars();

    if (server.ipc) |ipc| {
        events.onWindowOpened(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }

    const delay_ms = server.config.compositor.placeholder_delay_ms;
    if (delay_ms > 0) {
        toplevel.frame_tree.node.setEnabled(false);
        toplevel.backend.placeholder.delay_timer = server.wl_server.getEventLoop().addTimer(
            *Toplevel,
            handleDelayTimeout,
            toplevel,
        ) catch null;
        if (toplevel.backend.placeholder.delay_timer) |t| {
            _ = t.timerUpdate(@intCast(delay_ms)) catch {};
        }
    } else {
        toplevel.frame_tree.node.setEnabled(@import("../window_tabs.zig").visible(toplevel));
    }

    toplevel.backend.placeholder.timeout_timer = server.wl_server.getEventLoop().addTimer(
        *Toplevel,
        handleLaunchTimeout,
        toplevel,
    ) catch null;
    if (toplevel.backend.placeholder.timeout_timer) |t| {
        _ = t.timerUpdate(10_000) catch {};
    }

    return toplevel;
}

/// A compositor-drawn window of `width`×`height` content, unmapped: the
/// caller fills `scene_tree` with the content, then calls `mapShell`.
pub fn createShell(server: *Server, cc: *ControlCenter, width: i32, height: i32) !*Toplevel {
    const toplevel = try gpa.create(Toplevel);
    errdefer gpa.destroy(toplevel);

    const nodes = try createChromeNodes(server);
    errdefer nodes.frame_tree.node.destroy();
    const placeholder = try nodes.content_tree.createSceneTree();
    const scene_tree = &placeholder.node;

    toplevel.* = .{
        .server = server,
        .id = server.next_toplevel_id,
        .backend = .{ .shell = .{
            .control_center = cc,
            .client_width = width,
            .client_height = height,
        } },
        .frame_tree = nodes.frame_tree,
        .shadow_tree = nodes.shadow_tree,
        .shadow_node = nodes.shadow_node,
        .resize_grab = nodes.resize_grab,
        .glass_effect = nodes.glass_effect,
        .titlebar_buffer = nodes.titlebar_buffer,
        .frame_fills = nodes.frame_fills,
        .border_rects = nodes.border_rects,
        .content_tree = nodes.content_tree,
        .scene_tree = scene_tree,
    };
    server.next_toplevel_id += 1;
    finishCreate(toplevel, nodes, scene_tree);
    return toplevel;
}

/// Maps a `createShell` window like a client's first map: rules, placement
/// (centred on the target output unless a rule places it), focus, taskbar,
/// foreign-toplevel handle and the open animation.
pub fn mapShell(toplevel: *Toplevel) void {
    toplevel.resolveInitialRules();
    if (toplevel.open_rules.center == null) toplevel.open_rules.center = true;
    if (toplevel.open_rules.width) |w| toplevel.backend.shell.client_width = @max(ControlCenter.min_width, @as(i32, @intCast(w)));
    if (toplevel.open_rules.height) |h| toplevel.backend.shell.client_height = @max(ControlCenter.min_height, @as(i32, @intCast(h)));
    if (toplevel.backend.shell.control_center) |cc| cc.resize(toplevel.backend.shell.client_width, toplevel.backend.shell.client_height);
    toplevel.handleMapped();
}

pub fn findMatchingPlaceholder(toplevel: *Toplevel) ?*Toplevel {
    var it = toplevel.server.world.toplevels.iterator(.forward);
    while (it.next()) |candidate| {
        if (candidate.backend != .placeholder) continue;
        const ph = &candidate.backend.placeholder;
        if (ph.matched or ph.cancelled) continue;

        if (toplevel.clientPid()) |cpid| {
            if (ph.pid) |ppid| {
                if (placeholder_match.matchesPidChain(cpid, ppid)) return candidate;
            }
        }

        const app_id = toplevel.appId();
        if (app_id.len > 0) {
            if (placeholder_match.matchesAppId(app_id, ph.startup_wm_class, ph.desktop_id)) {
                return candidate;
            }
        }
    }
    return null;
}

pub fn attachXwaylandScene(toplevel: *Toplevel, client_surface: *wlr.Surface) !void {
    const hosted = try toplevel.content_tree.createSceneSubsurfaceTree(client_surface);
    toplevel.scene_tree.destroy();
    toplevel.scene_tree = &hosted.node;
}

pub fn detachXwaylandScene(toplevel: *Toplevel) void {
    const placeholder = toplevel.content_tree.createSceneTree() catch return;
    toplevel.scene_tree.destroy();
    toplevel.scene_tree = &placeholder.node;
}

pub fn replaceDestroyedXwaylandScene(toplevel: *Toplevel) void {
    // The previous node is in its destroy signal and must not be touched.
    toplevel.scene_tree = &(toplevel.content_tree.createSceneTree() catch return).node;
}
