//! Hand-written animation walker for `GetAnimations`. No global registry and
//! no allocation on the frame path: this runs only from the IPC handler.
const std = @import("std");

const Server = @import("../Server.zig");
const Toplevel = @import("../Toplevel.zig");
const anim = @import("ui").anim;
const protocol = @import("protocol.zig");

pub fn snapshot(server: *Server, allocator: std.mem.Allocator) ![]const protocol.AnimationData {
    var list: std.ArrayList(protocol.AnimationData) = .empty;
    errdefer list.deinit(allocator);
    const now_ms = anim.nowMs();

    var out_it = server.outputs.iterator(.forward);
    while (out_it.next()) |output| {
        if (output.taskbar) |bar| try bar.appendAnimations(allocator, &list, now_ms);
        if (output.start_menu) |menu| {
            try appendLive(allocator, &list, "start_menu.slide", menu.slide, now_ms);
            try appendLive(allocator, &list, "start_menu.selection", menu.sel_pos, now_ms);
            try appendLive(allocator, &list, "start_menu.hover", menu.hover_pos, now_ms);
            try appendLive(allocator, &list, "start_menu.hover_alpha", menu.hover_alpha, now_ms);
        }
        if (output.power_menu) |pm| try appendLive(allocator, &list, "power_menu.slide", pm.slide, now_ms);
        if (output.osd.state != null) {
            try appendLive(allocator, &list, "osd.level", output.osd.level_anim, now_ms);
        }
    }

    if (server.input.open_control_center) |cc| {
        try appendLive(allocator, &list, "control_center.selection", cc.nav_selection, now_ms);
        try appendLive(allocator, &list, "control_center.hover", cc.nav_hover.row, now_ms);
        try appendLive(allocator, &list, "control_center.hover_alpha", cc.nav_hover.alpha, now_ms);
    }

    if (server.switcher.active()) {
        try appendLive(allocator, &list, "switcher.scroll", server.switcher.scroll, now_ms);
    }

    if (server.notifications) |mgr| {
        for (mgr.toasts.items) |toast| {
            const slide_site = try std.fmt.allocPrint(allocator, "toast.{d}.slide", .{toast.id});
            try appendLive(allocator, &list, slide_site, toast.slide, now_ms);
            const flip_site = try std.fmt.allocPrint(allocator, "toast.{d}.flip", .{toast.id});
            try appendLive(allocator, &list, flip_site, toast.flip, now_ms);
        }
    }

    var win_it = server.world.toplevels.iterator(.forward);
    while (win_it.next()) |toplevel| {
        try appendWindow(allocator, &list, toplevel, now_ms);
    }
    var close_it = server.world.closing.iterator(.forward);
    while (close_it.next()) |toplevel| {
        try appendWindow(allocator, &list, toplevel, now_ms);
    }

    try appendLive(allocator, &list, "camera.pan_x", server.world.pan_x, now_ms);
    try appendLive(allocator, &list, "camera.pan_y", server.world.pan_y, now_ms);
    if (server.world.pinching) {
        try list.append(allocator, .{
            .site = "camera.zoom",
            .value = @floatCast(server.world.camera.zoom_value),
            .velocity = server.world.vel_z.velocity(now_ms),
            .target = @floatCast(server.world.camera.zoom_value),
            .settled = false,
            .curve = "off",
        });
    } else {
        try appendLive(allocator, &list, "camera.zoom", server.world.zoom_anim, now_ms);
    }

    return list.toOwnedSlice(allocator);
}

fn appendWindow(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(protocol.AnimationData),
    toplevel: *Toplevel,
    now_ms: i64,
) !void {
    const hover_site = try std.fmt.allocPrint(allocator, "window.{d}.hover", .{toplevel.id});
    try appendLive(allocator, list, hover_site, toplevel.hover_anim, now_ms);
    const chip_site = try std.fmt.allocPrint(allocator, "window.{d}.chip", .{toplevel.id});
    try appendLive(allocator, list, chip_site, toplevel.chip_pos, now_ms);
    const chip_fade_site = try std.fmt.allocPrint(allocator, "window.{d}.chip_fade", .{toplevel.id});
    try appendLive(allocator, list, chip_fade_site, toplevel.chip_alpha, now_ms);
    const zoom_site = try std.fmt.allocPrint(allocator, "window.{d}.zoom", .{toplevel.id});
    try appendLive(allocator, list, zoom_site, toplevel.zoom_anim, now_ms);
    const boost_site = try std.fmt.allocPrint(allocator, "window.{d}.zoom_boost", .{toplevel.id});
    try appendLive(allocator, list, boost_site, toplevel.zoom_boost, now_ms);
    const mix_site = try std.fmt.allocPrint(allocator, "window.{d}.peek_mix", .{toplevel.id});
    try appendLive(allocator, list, mix_site, toplevel.peek_mix, now_ms);
    const level_site = try std.fmt.allocPrint(allocator, "window.{d}.peek_level", .{toplevel.id});
    try appendLive(allocator, list, level_site, toplevel.peek_level, now_ms);
    const open_site = try std.fmt.allocPrint(allocator, "window.{d}.open", .{toplevel.id});
    try appendLive(allocator, list, open_site, toplevel.map_motion, now_ms);
    const fade_site = try std.fmt.allocPrint(allocator, "window.{d}.fade", .{toplevel.id});
    try appendLive(allocator, list, fade_site, toplevel.map_opacity, now_ms);
    const mx_site = try std.fmt.allocPrint(allocator, "window.{d}.move_x", .{toplevel.id});
    try appendLive(allocator, list, mx_site, toplevel.move_x, now_ms);
    const my_site = try std.fmt.allocPrint(allocator, "window.{d}.move_y", .{toplevel.id});
    try appendLive(allocator, list, my_site, toplevel.move_y, now_ms);
    const sw_site = try std.fmt.allocPrint(allocator, "window.{d}.size_w", .{toplevel.id});
    try appendLive(allocator, list, sw_site, toplevel.size_w, now_ms);
    const sh_site = try std.fmt.allocPrint(allocator, "window.{d}.size_h", .{toplevel.id});
    try appendLive(allocator, list, sh_site, toplevel.size_h, now_ms);
}

pub fn appendLive(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(protocol.AnimationData),
    site: []const u8,
    a: anim.Anim,
    now_ms: i64,
) !void {
    if (!a.active()) return;
    try list.append(allocator, .{
        .site = site,
        .value = a.value(now_ms),
        .velocity = a.velocity(now_ms),
        .target = a.to,
        .settled = a.settled(now_ms),
        .curve = a.curveName(),
    });
}

/// Sample in-flight animations under the current globals, apply `settings`,
/// then continue each one from that sample with the new curve. Changing
/// speed first would jump the sample; this keeps position and velocity.
pub fn reloadSettings(server: *Server, settings: anim.Settings) void {
    const now_ms = anim.nowMs();
    const gpa = @import("../main.zig").gpa;
    const captured = captureLive(server, gpa, now_ms) catch {
        anim.applySettings(settings);
        server.scheduleFrames();
        return;
    };
    defer gpa.free(captured);
    anim.applySettings(settings);
    for (captured) |item| {
        item.ptr.continueFrom(now_ms, item.from, item.to, item.v0, anim.curveFor(item.target));
    }
    server.scheduleFrames();
}

fn captureLive(server: *Server, allocator: std.mem.Allocator, now_ms: i64) ![]anim.LiveCapture {
    var list: std.ArrayList(anim.LiveCapture) = .empty;
    errdefer list.deinit(allocator);

    var out_it = server.outputs.iterator(.forward);
    while (out_it.next()) |output| {
        if (output.taskbar) |bar| try bar.captureAnimations(allocator, &list, now_ms);
        if (output.start_menu) |menu| {
            try anim.captureIfLive(allocator, &list, &menu.slide, .panel_slide, now_ms);
            try anim.captureIfLive(allocator, &list, &menu.sel_pos, .start_glide, now_ms);
            try anim.captureIfLive(allocator, &list, &menu.hover_pos, .start_glide, now_ms);
            try anim.captureIfLive(allocator, &list, &menu.hover_alpha, .start_glide_fade, now_ms);
        }
        if (output.power_menu) |pm| try anim.captureIfLive(allocator, &list, &pm.slide, .panel_slide, now_ms);
        if (output.osd.state != null) {
            try anim.captureIfLive(allocator, &list, &output.osd.level_anim, .osd_level, now_ms);
        }
    }

    if (server.input.open_control_center) |cc| {
        try anim.captureIfLive(allocator, &list, &cc.nav_selection, .start_glide, now_ms);
        try anim.captureIfLive(allocator, &list, &cc.nav_hover.row, .start_glide, now_ms);
        try anim.captureIfLive(allocator, &list, &cc.nav_hover.alpha, .start_glide_fade, now_ms);
    }

    if (server.switcher.active()) {
        try anim.captureIfLive(allocator, &list, &server.switcher.scroll, .switcher_scroll, now_ms);
    }

    if (server.notifications) |mgr| {
        for (mgr.toasts.items) |toast| {
            try anim.captureIfLive(allocator, &list, &toast.slide, .toast_slide, now_ms);
            try anim.captureIfLive(allocator, &list, &toast.flip, .toast_flip, now_ms);
        }
    }

    var win_it = server.world.toplevels.iterator(.forward);
    while (win_it.next()) |toplevel| {
        try captureWindow(allocator, &list, toplevel, now_ms);
    }
    var close_it = server.world.closing.iterator(.forward);
    while (close_it.next()) |toplevel| {
        try captureWindow(allocator, &list, toplevel, now_ms);
    }

    try anim.captureIfLive(allocator, &list, &server.world.pan_x, server.world.pan_target, now_ms);
    try anim.captureIfLive(allocator, &list, &server.world.pan_y, server.world.pan_target, now_ms);
    try anim.captureIfLive(allocator, &list, &server.world.zoom_anim, .camera_zoom, now_ms);

    return list.toOwnedSlice(allocator);
}

fn captureWindow(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(anim.LiveCapture),
    toplevel: *Toplevel,
    now_ms: i64,
) !void {
    try anim.captureIfLive(allocator, list, &toplevel.hover_anim, .titlebar_hover, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.chip_pos, .titlebar_chip, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.chip_alpha, .titlebar_chip_fade, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.zoom_anim, .window_zoom, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.zoom_boost, .window_zoom, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.peek_mix, .window_peek, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.peek_level, .window_peek, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.map_motion, .window_open, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.map_opacity, if (toplevel.closing) .window_close else .window_open, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.move_x, .window_move, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.move_y, .window_move, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.size_w, .window_resize, now_ms);
    try anim.captureIfLive(allocator, list, &toplevel.size_h, .window_resize, now_ms);
}
