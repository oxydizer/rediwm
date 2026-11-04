//! First-session welcome, using the Settings host and shared controls.
const i18n = @import("i18n");
const std = @import("std");
const wl = @import("wayland").server.wl;
const ui = @import("ui");
const panel = @import("panel.zig");
const Server = @import("../Server.zig");
const gpa = @import("../main.zig").gpa;
const W = ui.layout.Widget;
const A = std.mem.Allocator;

pub const State = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    idle: ?*wl.EventSource = null,
    footer: W = .{ .kind = .container },
    action: enum { classic, tiling, scale, finish, settings } = .finish,
    scale: ?f32 = null,
    browsers: []const []const u8 = &.{},
    terminals: []const []const u8 = &.{},
    message: []const u8 = "",

    pub fn deinit(s: *State) void {
        if (s.idle) |source| source.remove();
        s.arena.deinit();
    }
};

/// Headless compositors have no interactive first launch. Never read or write
/// user state in the greeter, or take focus from a restored lock.
pub fn showOnce(server: *Server) void {
    if (server.greeter_mode or server.locker != null or server.input.open_control_center != null) return;
    const output = server.getDefaultOutput() orelse return;
    if (!output.wlr_output.isDrm() and !output.wlr_output.isWl()) return;
    const dir = (@import("../window_sizes.zig").resolveStateDir(gpa, server.environ) catch return) orelse return;
    defer gpa.free(dir);
    const path = std.fmt.allocPrint(gpa, "{s}/welcome-shown", .{dir}) catch return;
    defer gpa.free(path);
    if (std.Io.Dir.cwd().openFile(server.io, path, .{})) |file| {
        file.close(server.io);
        return;
    } else |err| {
        if (err != error.FileNotFound) return;
    }
    _ = panel.ControlCenter.createWelcome(server, output.wlr_output) catch |err| {
        std.log.warn("could not open welcome: {}", .{err});
        return;
    };
    // Record presentation, so closing the window also counts as seeing it.
    std.Io.Dir.cwd().createDirPath(server.io, dir) catch |err| {
        std.log.warn("could not create welcome state directory: {}", .{err});
        return;
    };
    const file = std.Io.Dir.cwd().createFile(server.io, path, .{ .exclusive = true }) catch |err| {
        std.log.warn("could not remember welcome screen: {}", .{err});
        return;
    };
    file.close(server.io);
}

pub fn compact(cc: *const panel.ControlCenter) bool {
    return cc.panel_box.height < 740;
}

fn text(value: []const u8, size: f32, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
}
fn group(a: A, direction: ui.layout.Direction, children: []const W) !W {
    return .{ .kind = .container, .direction = direction, .gap = 12, .@"align" = .stretch, .width = .{ .flex = 1 }, .children = try a.dupe(W, children) };
}
fn choice(cc: *panel.ControlCenter, a: A, tiling: bool) !W {
    const t = panel.palette();
    const selected = (cc.server.config.compositor.desktop_mode == .workspaces) == tiling;
    var result = try group(a, .column, &.{
        .{ .kind = .container, .height = .{ .fixed = if (compact(cc)) 76 else 126 }, .underlay = .{ .owner = cc, .paint = if (tiling) paintTiles else paintStack } },
        text(if (tiling) i18n.tr("Tiling") else i18n.tr("Classic (stacking)"), 18, false),
        text(if (tiling) i18n.tr("Arrange windows automatically.") else i18n.tr("Move, resize and overlap windows."), 13, true),
    });
    result.name = if (tiling) "welcome_tiling" else "welcome_classic";
    result.kind = .{ .row = .{
        .owner = cc,
        .id = @intFromBool(tiling),
        .on_click = layoutClicked,
        .selected = selected,
        .background = .{ .color = t.app_item, .radius = t.settings_card_radius, .border_width = if (selected) 2 else 1, .border_color = if (selected) t.accent else t.app_item_border, .relief = t.settings_card_relief },
        .hover_background = .{ .color = t.app_nav_selected, .radius = t.settings_card_radius, .border_width = 2, .border_color = t.accent },
    } };
    result.padding = ui.layout.Edges.all(if (compact(cc)) 12 else 18);
    result.gap = if (compact(cc)) 8 else 12;
    return result;
}

pub fn build(cc: *panel.ControlCenter) W {
    _ = cc.welcome.arena.reset(.retain_capacity);
    cc.welcome.footer = .{ .kind = .container };
    return tree(cc, cc.welcome.arena.allocator()) catch panel.outOfMemory();
}
fn tree(cc: *panel.ControlCenter, a: A) !W {
    const narrow = cc.panel_box.width < 680;
    const small = compact(cc);
    var logo: W = .{ .kind = .container, .width = .{ .fixed = 52 }, .height = .{ .fixed = 52 } };
    if (@import("../icon_cache.zig").get(cc.server.icon_theme_cfg, cc.server.io, "builtin:redi-logo", @intFromFloat(@ceil(52 * cc.toplevel.render_scale)))) |entry| {
        logo.kind = .{ .image = .{ .pixels = entry.pixels, .width = entry.size, .height = entry.size, .fallback_icon = null } };
    }
    var heading = try group(a, .row, &.{ logo, try group(a, .column, &.{ text(i18n.tr("Welcome to RediWM"), if (narrow) 24 else if (small) 26 else 30, false), text(i18n.tr("Choose how your desktop works."), 14, true) }) });
    heading.@"align" = .center;
    heading.gap = 20;
    heading.children[1].gap = if (small) 4 else 12;
    var apps = try group(a, if (narrow) .column else .row, &.{ try appSelect(cc, a, true), try appSelect(cc, a, false) });
    apps.gap = 20;
    const scale_labels = panel.translatedLabels(&.{ i18n.msg("System default"), i18n.msg("100%"), i18n.msg("125%"), i18n.msg("150%"), i18n.msg("175%"), i18n.msg("200%"), i18n.msg("250%"), i18n.msg("300%") });
    var scale_index: ?usize = 0;
    for (cc.server.config.outputs) |config| {
        if (!std.mem.eql(u8, config.name, std.mem.span(cc.wlr_output.name))) continue;
        if (config.scale) |factor| {
            scale_index = null;
            for (scales, 1..) |scale, i| if (@abs(scale - factor) < 0.001) {
                scale_index = i;
                break;
            };
        }
    }
    var scale = try group(a, .column, &.{
        text(i18n.tr("Interface scale"), 13, true),
        .{ .name = "welcome_scale", .kind = .{ .select = .{ .labels = scale_labels, .selected = scale_index, .placeholder = i18n.tr("Custom"), .disabled = cc.server.scale_override != null, .owner = cc, .on_change = scaleChanged } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 38 } },
    });
    scale.gap = if (small) 6 else 12;
    scale.width = .{ .percent = if (narrow) 1 else 0.48 };
    var footer = try group(a, if (narrow) .column else .row, &.{
        .{ .name = "welcome_settings", .kind = .{ .button = .{ .label = i18n.tr("More settings"), .leading_icon = .settings, .variant = .ghost, .owner = cc, .id = 1, .on_click = finishClicked } }, .width = .{ .fixed = 170 }, .height = .{ .fixed = 42 } },
        .{ .name = "welcome_start", .kind = .{ .button = .{ .label = i18n.tr("Start using RediWM"), .variant = .primary, .owner = cc, .on_click = finishClicked } }, .width = .{ .fixed = 218 }, .height = .{ .fixed = 42 } },
    });
    footer.justify = .space_between;
    cc.welcome.footer = try group(a, .column, &.{ text(if (cc.welcome.message.len > 0) cc.welcome.message else i18n.tr("You can change these later in Settings."), 13, true), footer });
    cc.welcome.footer.width = .{ .percent = 1 };
    cc.welcome.footer.gap = if (small) 8 else 12;
    cc.welcome.footer.padding = .{ .left = if (small) 20 else 28, .right = if (small) 20 else 28, .top = 8, .bottom = if (small) 16 else 24 };
    var root = try group(a, .column, &.{
        heading,
        text(i18n.tr("Choose your window layout"), 18, false),
        try group(a, if (narrow) .column else .row, &.{ try choice(cc, a, false), try choice(cc, a, true) }),
        .{ .kind = .{ .rect = .{ .color = panel.palette().border_soft } }, .height = .{ .fixed = 1 } },
        text(i18n.tr("Default apps"), 18, false),
        apps,
        scale,
        .{ .kind = .{ .rect = .{ .color = panel.palette().border_soft } }, .height = .{ .fixed = 1 } },
    });
    root.width = .{ .percent = 1 };
    root.gap = if (small) 10 else 18;
    return root;
}

extern fn g_app_info_get_default_for_type(content_type: [*:0]const u8, must_support_uris: c_int) ?*anyopaque;
extern fn g_app_info_get_id(app: *anyopaque) ?[*:0]const u8;
extern fn g_app_info_get_display_name(app: *anyopaque) [*:0]const u8;
extern fn g_desktop_app_info_new(id: [*:0]const u8) ?*anyopaque;
extern fn g_app_info_set_as_default_for_type(app: *anyopaque, content_type: [*:0]const u8, err: ?*?*anyopaque) c_int;
extern fn g_object_unref(object: *anyopaque) void;

fn appSelect(cc: *panel.ControlCenter, a: A, browser: bool) !W {
    const snapshot = cc.server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    const current_app = if (browser) g_app_info_get_default_for_type("x-scheme-handler/https", 0) else null;
    defer if (current_app) |app| g_object_unref(app);
    const selected = if (current_app) |app| (if (g_app_info_get_id(app)) |id| std.mem.span(id) else "") else if (browser) "" else cc.server.config.compositor.default_terminal;
    var labels: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const u8) = .empty;
    // Keep the inherited browser as an explicit choice: selecting a browser
    // really changes the system's HTTP/HTTPS associations.
    try labels.append(a, if (current_app) |app| try a.dupe(u8, std.mem.span(g_app_info_get_display_name(app))) else i18n.tr("System default"));
    try values.append(a, try a.dupe(u8, if (browser) selected else ""));
    var selected_index: usize = 0;
    for (snapshot.entries) |entry| {
        var matches = false;
        var categories = std.mem.splitScalar(u8, entry.categories, ';');
        while (categories.next()) |category| if (std.mem.eql(u8, category, if (browser) "WebBrowser" else "TerminalEmulator")) {
            matches = true;
            break;
        };
        if (!matches or (browser and std.mem.eql(u8, entry.id, selected))) continue;
        try labels.append(a, try a.dupe(u8, entry.name));
        try values.append(a, try a.dupe(u8, entry.id));
        if (std.mem.eql(u8, entry.id, selected)) selected_index = values.items.len - 1;
    }
    if (!browser and selected.len > 0 and selected_index == 0) {
        try labels.append(a, try i18n.allocPrint(a, i18n.tr("Unavailable: {name}"), .{ .name = selected }));
        try values.append(a, try a.dupe(u8, selected));
        selected_index = values.items.len - 1;
    }
    if (browser) cc.welcome.browsers = values.items else cc.welcome.terminals = values.items;
    var field = try group(a, .column, &.{
        text(if (browser) i18n.tr("Browser") else i18n.tr("Terminal"), 13, true),
        .{ .name = if (browser) "welcome_browser" else "welcome_terminal", .kind = .{ .select = .{ .labels = labels.items, .selected = selected_index, .owner = cc, .id = @intFromBool(browser), .on_change = appChanged } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 38 } },
    });
    field.gap = if (compact(cc)) 6 else 12;
    return field;
}
fn appChanged(owner: ?*anyopaque, id: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    saveApp(cc, id == 1, index) catch |err| {
        std.log.warn("could not save welcome application: {}", .{err});
        cc.welcome.message = i18n.tr("Could not save the default app. Please try again.");
        cc.refresh();
        return;
    };
    cc.welcome.message = i18n.tr("Saved. You can change these later in Settings.");
    cc.refresh();
}
fn saveApp(cc: *panel.ControlCenter, browser: bool, index: usize) !void {
    const values = if (browser) cc.welcome.browsers else cc.welcome.terminals;
    if (index >= values.len) return;
    const value = values[index];
    if (browser) {
        if (value.len == 0) return;
        const id = try gpa.dupeSentinel(u8, value, 0);
        defer gpa.free(id);
        const app = g_desktop_app_info_new(id) orelse return error.ApplicationUnavailable;
        defer g_object_unref(app);
        for ([_][*:0]const u8{ "x-scheme-handler/http", "x-scheme-handler/https", "text/html" }) |mime| {
            if (g_app_info_set_as_default_for_type(app, mime, null) == 0) return error.AssociationFailed;
        }
    } else {
        const server = cc.server;
        const owned = try server.config.arena.allocator().dupe(u8, value);
        try @import("config").setting_save.saveCompositor(gpa, server.io, server.config.path, "default_terminal", value);
        server.config.compositor.default_terminal = owned;
    }
}

const scales = [_]f32{ 1, 1.25, 1.5, 1.75, 2, 2.5, 3 };
fn scaleChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (index > scales.len) return;
    cc.welcome.scale = if (index == 0) null else scales[index - 1];
    cc.welcome.action = .scale;
    schedule(cc);
}
fn layoutClicked(owner: ?*anyopaque, id: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    cc.welcome.action = if (id == 0) .classic else .tiling;
    schedule(cc);
}
fn finishClicked(owner: ?*anyopaque, id: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    cc.welcome.action = if (id == 0) .finish else .settings;
    schedule(cc);
}
fn schedule(cc: *panel.ControlCenter) void {
    if (cc.welcome.idle != null) return;
    cc.welcome.idle = cc.server.wl_server.getEventLoop().addIdle(*panel.ControlCenter, apply, cc) catch {
        cc.welcome.message = i18n.tr("Could not apply this choice. Please try again.");
        cc.refresh();
        return;
    };
}
fn apply(cc: *panel.ControlCenter) void {
    cc.welcome.idle = null;
    switch (cc.welcome.action) {
        .finish, .settings => {
            const settings = cc.welcome.action == .settings;
            const server = cc.server;
            const output = cc.wlr_output;
            cc.close();
            if (settings) _ = panel.ControlCenter.create(server, output) catch |err| {
                std.log.warn("could not open Settings: {}", .{err});
            };
            return;
        },
        .classic, .tiling => @import("../config_runtime/workspace_controls.zig").mode(cc.server, if (cc.welcome.action == .tiling) .workspaces else .canvas, true) catch |err| {
            std.log.warn("could not save welcome layout: {}", .{err});
            cc.welcome.message = i18n.tr("Could not save your layout. Please try again.");
        },
        .scale => {
            const output = @import("../Output.zig").fromWlr(cc.wlr_output) orelse return;
            output.applyAndPersist(.{ .scale = cc.welcome.scale, .auto_scale = cc.welcome.scale == null }) catch |err| {
                std.log.warn("could not save welcome scale: {}", .{err});
                cc.welcome.message = i18n.tr("Could not apply or save the display scale.");
            };
        },
    }
    cc.refresh();
}

// Illustrations are artwork inside shared selectable rows, not controls.
fn miniWindow(r: *ui.paint.Renderer, x: f32, y: f32, w: f32, h: f32, active: bool) void {
    const t = panel.palette();
    r.fillRect(x, y, w, h, .{ .color = t.app_bg, .radius = 5, .border_width = 1, .border_color = if (active) t.accent else t.border });
    r.fillRect(x + 6, y + 7, w - 12, 8, .{ .color = if (active) t.accent else t.app_item_border, .radius = 2 });
    r.fillRect(x + 7, y + 23, w * 0.24, h - 31, .{ .color = t.app_sidebar, .radius = 2 });
    for (0..3) |i| r.fillRect(x + w * 0.36, y + 25 + @as(f32, @floatFromInt(i)) * 12, (w - w * 0.43) * (1 - @as(f32, @floatFromInt(i)) * 0.17), 4, .{ .color = t.app_item_border, .radius = 1 });
}
fn paintStack(_: ?*anyopaque, widget: *const W, renderer: *ui.paint.Renderer) void {
    const factor = widget.computed_height / 126;
    var scaled = renderer.zoomed(factor);
    const r = &scaled;
    const w = @min(widget.computed_width / factor, 300);
    const x = widget.computed_x / factor + (widget.computed_width / factor - w) / 2;
    const y = widget.computed_y / factor;
    miniWindow(r, x + w * 0.25, y, w * 0.64, 82, false);
    miniWindow(r, x, y + 22, w * 0.62, 84, false);
    miniWindow(r, x + w * 0.34, y + 40, w * 0.66, 86, true);
}
fn paintTiles(_: ?*anyopaque, widget: *const W, renderer: *ui.paint.Renderer) void {
    const factor = widget.computed_height / 126;
    var scaled = renderer.zoomed(factor);
    const r = &scaled;
    const w = @min(widget.computed_width / factor, 300);
    const x = widget.computed_x / factor + (widget.computed_width / factor - w) / 2;
    const y = widget.computed_y / factor;
    miniWindow(r, x, y, w * 0.43, 126, false);
    miniWindow(r, x + w * 0.43 + 7, y, w * 0.57 - 7, 60, true);
    miniWindow(r, x + w * 0.43 + 7, y + 67, w * 0.57 - 7, 59, false);
}
