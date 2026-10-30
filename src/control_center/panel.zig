const i18n = @import("i18n");
// Compositor-drawn settings window, opened by the start-menu cog or IPC.
// It is an ordinary window (`Toplevel` backend `.shell`): the toplevel owns
// chrome, stacking, focus, minimize/maximize/resize and the taskbar chip;
// this draws the opaque body into the window's content tree. Shares the file
// manager's charcoal/sidebar styling and the retained shell widget renderer.
// Device and appearance actions reuse the existing sections.
const std = @import("std");
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const pixman = @import("pixman");

const gpa = @import("../main.zig").gpa;
const anim = @import("ui").anim;
const panel_buffer = @import("../panel_buffer.zig");
const panel_paint = @import("../panel_paint.zig");
const panel_present = @import("../panel_present.zig");
const scene_data = @import("../scene_data.zig");
const PanelBuffer = panel_buffer.PanelBuffer;
const Server = @import("../Server.zig");
const Toplevel = @import("../Toplevel.zig");
const ui = @import("ui");
const layout = ui.layout;
const Widget = layout.Widget;

const display_section = @import("sections/display.zig");
const sound_section = @import("sections/sound.zig");
const appearance_section = @import("sections/appearance.zig");
const shortcut_section = @import("sections/shortcuts.zig");
const default_apps_section = @import("sections/default_apps.zig");
const portal_section = @import("sections/portals.zig");
const desktop_section = @import("sections/desktop.zig");
const input_section = @import("sections/input.zig");
const services_section = @import("sections/services.zig");
const printers_section = @import("sections/printers.zig");
const systemd = @import("../systemd.zig");
const users_section = @import("sections/users.zig");
const bluetooth_section = @import("sections/bluetooth.zig");
const region_section = @import("sections/region.zig");
const network_section = @import("sections/network.zig");

const log = std.log.scoped(.control_center);
const welcome_section = @import("welcome.zig");
const settings_search = @import("search.zig");

/// Default content size; a saved size (window_sizes) or a rule wins.
pub const default_width = 960;
pub const default_height = 640;

// .glass-strong uses shared CSS palette and --r-lg.
const theme = @import("ui").theme;

pub const Page = @import("search_index.zig").Page;
pub const page_labels = [_]i18n.Message{ i18n.msg("General"), i18n.msg("Input"), i18n.msg("Displays"), i18n.msg("Audio"), i18n.msg("Network"), i18n.msg("Appearance"), i18n.msg("Keyboard Shortcuts"), i18n.msg("Desktop"), i18n.msg("Bluetooth"), i18n.msg("Region & Language"), i18n.msg("Users"), i18n.msg("Printers"), i18n.msg("Services"), i18n.msg("Power & Battery") };
/// Refreshed when a page rebuilds; storage outlives retained widget trees.
/// Each comptime descriptor list owns its own stable slice.
pub fn translatedLabels(comptime messages: []const i18n.Message) []const []const u8 {
    const Storage = struct {
        var labels: [messages.len][]const u8 = undefined;
    };
    inline for (messages, 0..) |message, i| Storage.labels[i] = message.get();
    return &Storage.labels;
}

/// Keep the default width in English, and reserve room for translated nav names.
pub fn sidebarWidth(cc: *const ControlCenter) f32 {
    if (cc.panel_box.width < 660) return 70;
    var width: f32 = 238;
    for (page_labels) |message| width = @max(width, ui.measure.textNatural(message.get(), .sans, 600, 14).w + 94);
    return @min(width, 340);
}

pub fn pageLabel(id: usize) []const u8 {
    return page_labels[id].get();
}

pub const page_names = [_][]const u8{ "general", "input", "displays", "audio", "network", "appearance", "shortcuts", "desktop", "bluetooth", "region", "users", "printers", "services", "power" };
pub const page_descriptions = [_]i18n.Message{
    i18n.msg("Everyday controls, all in one place."),                i18n.msg("Make your mouse and keyboard feel right."),
    i18n.msg("Arrangement, resolution, refresh rate and scaling."),  i18n.msg("Volume, microphones and output devices."),
    i18n.msg("Wired and wireless connections."),                     i18n.msg("Make your desktop your own."),
    i18n.msg("Choose the keys for your everyday actions."),          i18n.msg("Configure your desktop canvas and panning area."),
    i18n.msg("Connect and manage your Bluetooth devices."),          i18n.msg("Your language, regional formats and calendar preferences."),
    i18n.msg("Review login accounts and automatic-login settings."), i18n.msg("Printer status, jobs and connection diagnostics."),
    i18n.msg("Manage and analyze systemd services."),                i18n.msg("Screen, sleep and power-source preferences."),
};
pub const page_icons = [_]layout.IconId{ .settings, .mouse, .display, .music, .wifi, .settings, .keyboard, .squares, .bluetooth, .globe, .users, .print, .settings, .battery };
pub const max_devices = 16;

pub fn palette() theme.Theme {
    // Settings paints app surfaces even though its host is compositor-owned.
    var t = theme.global.forApp();
    t.bg = t.window_bg;
    t.fg = t.window_fg;
    t.dim = t.window_dim;
    t.faint = t.window_dim;
    t.border = t.window_border;
    t.border_soft = t.window_divider;
    t.accent = t.shell_accent orelse t.start_menu_selected_marker;
    t.on_accent = t.shell_on_accent orelse t.window_fg;
    t.radius = t.settings_radius;
    t.start_menu_selected_bg = t.app_nav_selected;
    return t;
}

pub fn label(value: []const u8, size: f32, dim: bool) Widget {
    const t = palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
}

/// Build description lines once, with a UTF-8 fallback for an unbroken word.
/// Children belong to the host's rebuild arena, just like its other widgets.
pub fn paragraph(a: std.mem.Allocator, value: []const u8, width: f32, size: f32, dim: bool) !Widget {
    var lines: std.ArrayList(Widget) = .empty;
    var start: usize = 0;
    while (start < value.len) {
        var end = start;
        var last_space: ?usize = null;
        while (end < value.len) {
            const next = @min(value.len, end + (std.unicode.utf8ByteSequenceLength(value[end]) catch 1));
            if (ui.measure.textNatural(value[start..next], .sans, if (dim) 400 else 600, size).w > @max(64, width) and end > start) break;
            if (value[end] == ' ') last_space = end;
            end = next;
        }
        if (end < value.len) if (last_space) |space| {
            if (space > start) end = space;
        };
        try lines.append(a, label(value[start..end], size, dim));
        start = end;
        while (start < value.len and value[start] == ' ') : (start += 1) {}
    }
    return .{ .kind = .container, .direction = .column, .gap = 3, .width = .{ .percent = 1 }, .children = try lines.toOwnedSlice(a) };
}

/// A card or group title: larger and bolder than the semibold row labels.
pub fn sectionTitle(value: []const u8) Widget {
    const t = palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = t.settings_title_size, .weight = 700, .color = t.fg } } };
}

/// Stands in for a section whose widget tree could not be allocated; it
/// allocates nothing itself.
pub fn outOfMemory() Widget {
    return label(i18n.tr("Not enough memory to show this page."), 13, true);
}

pub fn card(children: []Widget) Widget {
    return .{
        .kind = .{ .rect = .{ .color = theme.global.app_item, .radius = theme.global.settings_card_radius, .border_width = 1, .border_color = theme.global.app_item_border } },
        .direction = .column,
        .padding = layout.Edges.all(14),
        .gap = 10,
        .@"align" = .stretch,
        .width = .{ .percent = 1 },
        .children = children,
    };
}

pub fn restyle(widget: *Widget) void {
    const pal = palette();
    switch (widget.kind) {
        .slider => |*data| data.style = .settings,
        .toggle => |*data| data.style = .settings,
        .text => |*t| {
            const is_bright = t.weight >= 600 or (t.color[0] >= 0.75 and t.color[1] >= 0.75 and t.color[2] >= 0.75);
            t.color = if (is_bright) pal.fg else pal.dim;
        },
        else => {},
    }
    if (widget.direction == .column) widget.@"align" = .stretch;
    var has_flex = false;
    for (widget.children) |child| {
        if (child.width == .flex) {
            has_flex = true;
            break;
        }
    }
    for (widget.children) |*child| {
        if (widget.direction == .row and child.kind == .text and child.width == .auto and !has_flex) {
            child.width = .{ .flex = 1 };
            has_flex = true;
        }
        restyle(child);
    }
}

pub const ControlCenter = @import("ControlCenter.zig");

// ---- Pointer/keyboard entry points, called from Input.zig/Keyboard.zig ----

pub fn pointerMotion(cc: *ControlCenter, sx: f64, sy: f64) void {
    if (cc.appearance.item_drag != null) {
        appearance_section.moveItemDrag(&cc.appearance, @floatCast(sy));
        return;
    }
    const revision = ui.layout.paint_revision;
    ui.input.pointerMotion(&cc.root, @floatCast(sx), @floatCast(sy));
    cc.syncNavHover();
    if (revision != ui.layout.paint_revision) cc.requestWidgetRepaint();
}

/// The pointer is over something else: the scrollbar thumb stops being hovered.
pub fn pointerLeave(cc: *ControlCenter) void {
    const revision = ui.layout.paint_revision;
    ui.input.pointerLeave(&cc.root);
    if (cc.nav_hover.target != null) {
        cc.nav_hover.setTarget(anim.nowMs(), null);
        cc.scheduleFrame();
    }
    if (revision != ui.layout.paint_revision) cc.requestWidgetRepaint();
}

/// Over a taskbar item row, which drags from anywhere but its toggle.
pub fn overDraggable(cc: *ControlCenter, sx: f64, sy: f64) bool {
    return cc.page == .appearance and appearance_section.itemHandle(&cc.appearance, @floatCast(sx), @floatCast(sy)) != null;
}

pub fn pointerButtonDown(cc: *ControlCenter, sx: f64, sy: f64) void {
    if (!cc.is_welcome and sx >= cc.body_children[1].computed_x) settings_search.dismiss(cc);
    cc.pointer_down = true;
    if (cc.page == .appearance and appearance_section.beginItemDrag(&cc.appearance, @floatCast(sx), @floatCast(sy))) return;
    ui.input.pointerButtonDown(&cc.root, @floatCast(sx), @floatCast(sy));
    cc.requestRepaint();
}

pub fn pointerButtonUp(cc: *ControlCenter, sx: f64, sy: f64) void {
    if (!cc.pointer_down) return;
    if (cc.appearance.item_drag != null) {
        appearance_section.moveItemDrag(&cc.appearance, @floatCast(sy));
        appearance_section.endItemDrag(&cc.appearance, true);
    } else ui.input.pointerButtonUp(&cc.root, @floatCast(sx), @floatCast(sy));
    cc.pointer_down = false;
    cc.applyPending();
    cc.requestRepaint();
}

/// `notch` is a detented wheel click, which glides; see `Dispatcher.scrollWheel`.
pub fn scrollWheel(cc: *ControlCenter, sx: f64, sy: f64, delta_px: f32, notch: bool) void {
    if (cc.appearance.item_drag != null) return;
    const revision = ui.layout.paint_revision;
    if (ui.input.scrollWheel(&cc.root, @floatCast(sx), @floatCast(sy), delta_px, if (notch) anim.nowMs() else null)) {
        cc.scroll_gliding = true;
        cc.scheduleFrame();
    }
    if (revision != ui.layout.paint_revision) cc.requestWidgetRepaint();
}

/// The settings body colour: the theme's app content background, opaque.
pub fn bodyColor() [4]f32 {
    const bg = theme.global.app_bg;
    return .{ bg[0], bg[1], bg[2], 1 };
}

pub fn pageClicked(owner: ?*anyopaque, id: usize) void {
    const cc: *ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (cc.search.active) {
        cc.search.pending_result = cc.search.firstInPage(@fromBackingInt(@intCast(id)));
        return;
    }
    cc.search.unavailable = false;
    cc.search.destination = null;
    cc.search.focused = false;
    cc.search.request_focus = false;
    cc.pending_page = @fromBackingInt(@intCast(id));
}

pub fn deviceClicked(owner: ?*anyopaque, id: usize) void {
    const cc: *ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (id >= cc.device_count) return;
    if (cc.server.audio) |mgr| mgr.setDefaultSink(cc.device_names[id][0..cc.device_name_lens[id]]);
}

pub fn brightnessChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const cc: *ControlCenter = @ptrCast(@alignCast(owner orelse return));
    const server = cc.server;
    server.brightness.set(server, value);
    cc.brightness_row[2].kind.text.content = std.fmt.bufPrint(&cc.brightness_percent, "{d}%", .{@as(i32, @intFromFloat(@round(value * 100)))}) catch "";
    cc.brightness_row[2].markDirty();
}

pub fn filesSingleClickChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const cc: *ControlCenter = @ptrCast(@alignCast(owner orelse return));
    @import("config").setting_save.saveCompositor(gpa, cc.server.io, cc.server.config.path, "files_single_click_open", on) catch |err| {
        std.log.warn("could not save Files single-click setting: {}", .{err});
        cc.default_apps.message = i18n.tr("Could not save the Files setting.");
        cc.refresh();
        return;
    };
    cc.server.config.compositor.files_single_click_open = on;
}
