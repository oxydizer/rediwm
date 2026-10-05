// Compositor-drawn settings window, opened by the start-menu cog or IPC.
// It is an ordinary window (`Toplevel` backend `.shell`): the toplevel owns
// chrome, stacking, focus, minimize/maximize/resize and the taskbar chip;
// this draws the opaque body into the window's content tree. Shares the file
// manager's charcoal/sidebar styling and the retained shell widget renderer.
// Device and appearance actions reuse the existing sections.
const std = @import("std");
const wlr = @import("wlroots");
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
const systemd = @import("../systemd.zig");
const users_section = @import("sections/users.zig");
const bluetooth_section = @import("sections/bluetooth.zig");
const region_section = @import("sections/region.zig");
const network_section = @import("sections/network.zig");

const log = std.log.scoped(.control_center);

/// Default content size; a saved size (window_sizes) or a rule wins.
const default_width = 960;
const default_height = 640;

// .glass-strong uses shared CSS palette and --r-lg.
const theme = @import("ui").theme;

pub const Page = enum { general, input, displays, audio, network, appearance, shortcuts, desktop, bluetooth, region, users, services };
const page_labels = [_][]const u8{ "General", "Input", "Displays", "Audio", "Network", "Appearance", "Keyboard Shortcuts", "Desktop", "Bluetooth", "Region & Language", "Users", "Services" };
const page_names = [_][]const u8{ "general", "input", "displays", "audio", "network", "appearance", "shortcuts", "desktop", "bluetooth", "region", "users", "services" };
const page_descriptions = [_][]const u8{
    "Everyday controls, all in one place.",                "Make your mouse and keyboard feel right.",
    "Arrangement, resolution, refresh rate and scaling.",  "Volume, microphones and output devices.",
    "Wired and wireless connections.",                     "Make your desktop your own.",
    "Choose the keys for your everyday actions.",          "Configure your desktop canvas and panning area.",
    "Connect and manage your Bluetooth devices.",          "Your language, regional formats and calendar preferences.",
    "Review login accounts and automatic-login settings.", "Manage and analyze systemd services.",
};
const page_icons = [_]layout.IconId{ .settings, .mouse, .display, .music, .wifi, .settings, .keyboard, .squares, .bluetooth, .globe, .users, .settings };
const max_devices = 16;

pub fn palette() theme.Theme {
    var t = theme.global;
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

fn label(value: []const u8, size: f32, dim: bool) Widget {
    const t = palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
}

/// Stands in for a section whose widget tree could not be allocated; it
/// allocates nothing itself.
pub fn outOfMemory() Widget {
    return label("Not enough memory to show this page.", 13, true);
}

fn card(children: []Widget) Widget {
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

fn restyle(widget: *Widget) void {
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

pub const ControlCenter = struct {
    server: *Server,
    /// The output settings opened on: the Displays page's default and the
    /// frame clock for `tick`. Moved to another output if it goes away.
    wlr_output: *wlr.Output,
    toplevel: *Toplevel,
    selected_output_name: [128]u8 = undefined,
    selected_output_name_len: usize = 0,
    buffer_node: *wlr.SceneBuffer,
    node_data: scene_data.SceneData = undefined,

    dirty: bool = true,
    /// A resize waits for the next frame, so a drag relayouts once per frame.
    layout_pending: bool = false,
    /// Scale of the pixels on `buffer_node`; a new render scale repaints.
    painted_scale: f32 = 0,
    /// A wheel glide is in flight somewhere in `root` (`stepGlides`).
    scroll_gliding: bool = false,
    /// Scrollbar feedback still to play out (`stepBars`): `active` is a widening
    /// or fade in flight, `deadline` the end of the hold after a scroll.
    bars: ui.widgets.scroll_container.BarStep = .{},
    /// Row-index positions outlive page rebuilds and follow resized rows.
    nav_selection: anim.Anim = .{},
    nav_selected_row: f32 = 0,
    nav_hover: ui.hover_glide.Glide = .{},
    background: panel_paint.Background = .{},
    /// Content size; x/y stay 0 (see `screenBox`).
    panel_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    page: Page = .general,
    /// The page `root` was last built for; null until the first build, when
    /// `root` is still undefined.
    built_page: ?Page = null,
    pending_page: ?Page = null,
    refresh_pending: bool = false,
    pointer_down: bool = false,
    /// The window is activated; keys arrive only with `hasKeyboardFocus`.
    focused: bool = false,
    root: Widget = undefined,
    root_children: [1]Widget = undefined,
    body_children: [2]Widget = undefined,
    nav_rows: [page_names.len]Widget = undefined,
    nav_children: [page_names.len][2]Widget = undefined,
    // Sized for the worst case across all pages: 2 (heading + description)
    // plus the larger of the Input and Appearance pages.
    content_children: [
        2 + @max(
            @typeInfo(@FieldType(input_section.Section, "row_storage")).array.len,
            @typeInfo(@FieldType(appearance_section.Section, "row_storage")).array.len,
        )
    ]Widget = undefined,
    content_count: usize = 0,
    general_volume: [2]Widget = undefined,
    general_output: [2]Widget = undefined,
    general_output_text: [2]Widget = undefined,
    general_display: [2]Widget = undefined,
    general_display_text: [2]Widget = undefined,
    brightness_children: [2]Widget = undefined,
    brightness_row: [3]Widget = undefined,
    brightness_percent: [8]u8 = undefined,
    device_title: [2]Widget = undefined,
    device_rows: [max_devices]Widget = undefined,
    device_children: [max_devices][2]Widget = undefined,
    device_names: [max_devices][256]u8 = undefined,
    device_name_lens: [max_devices]usize = undefined,
    device_labels: [max_devices][128]u8 = undefined,
    device_count: usize = 0,
    display: display_section.Section = .{},
    sound: sound_section.Section = .{},
    appearance: appearance_section.Section = .{},
    shortcuts: shortcut_section.Section = .{},
    desktop: desktop_section.Section = .{},
    region: region_section.Section = .{},
    portals: portal_section.Section = .{},
    default_apps: default_apps_section.Section = .{},
    input: input_section.Section = undefined,
    users: users_section.Section = .{},
    network: network_section.Section = .{},
    bluetooth: bluetooth_section.Section = .{},
    services: services_section.Section = .{},
    systemd_client: ?*systemd.Client = null,

    pub const min_width = 420;
    pub const min_height = 320;

    pub fn minimumWidth(cc: *const ControlCenter) i32 {
        return if (cc.page == .services) 1040 else min_width;
    }

    pub fn minimumHeight(cc: *const ControlCenter) i32 {
        return if (cc.page == .services) 640 else min_height;
    }

    /// Creates the settings window on `wlr_output` and maps it focused.
    pub fn create(server: *Server, wlr_output: *wlr.Output) !*ControlCenter {
        const cc = try gpa.create(ControlCenter);
        errdefer gpa.destroy(cc);

        var width: i32 = default_width;
        var height: i32 = default_height;
        if (@import("../window_sizes.zig").load(server.io, server.environ, Toplevel.settings_app_id)) |saved| {
            width = saved.width;
            height = saved.height;
        }
        var box: wlr.Box = undefined;
        server.output_layout.getBox(wlr_output, &box);
        if (box.width > 0 and box.height > 0) {
            // Leave room for the frame and the taskbar on small outputs.
            width = @min(width, box.width - 48);
            height = @min(height, box.height - 140);
        }
        width = @max(min_width, width);
        height = @max(min_height, height);

        const toplevel = try Toplevel.createShell(server, cc, width, height);
        errdefer {
            toplevel.backend.shell.control_center = null;
            toplevel.destroy();
        }
        const buffer_node = try toplevel.scene_tree.createSceneBuffer(null);
        // Window zoom and fractional scales change the destination rounding;
        // interpolate glyph coverage instead of dropping rows/columns.
        buffer_node.setFilterMode(.bilinear);

        cc.* = .{
            .server = server,
            .wlr_output = wlr_output,
            .toplevel = toplevel,
            .buffer_node = buffer_node,
            .panel_box = .{ .x = 0, .y = 0, .width = width, .height = height },
        };
        const host_name = std.mem.span(wlr_output.name);
        cc.selected_output_name_len = @min(host_name.len, cc.selected_output_name.len);
        @memcpy(cc.selected_output_name[0..cc.selected_output_name_len], host_name[0..cc.selected_output_name_len]);
        cc.node_data = .{ .role = .{ .control_center = cc } };
        scene_data.SceneData.attach(&cc.node_data, &buffer_node.node);

        server.input.open_control_center = cc;
        cc.server.brightness.query(server);
        if (!server.greeter_mode) cc.systemd_client = server.getSystemd() catch null;
        toplevel.mapShell();
        cc.relayout();
        return cc;
    }

    /// Closes the window: the content goes now, the frame animates out.
    pub fn close(cc: *ControlCenter) void {
        cc.destroy();
    }

    pub fn destroy(cc: *ControlCenter) void {
        // Dispatcher holds raw pointers into this tree. Drop them before the
        // allocation goes away so a later reopen's first motion doesn't
        // switch on a freed WidgetKind tag.
        ui.input.reset();
        @import("../Keyboard.zig").forgetShellTarget(cc.server, cc);
        if (cc.server.input.open_control_center == cc) cc.server.input.open_control_center = null;
        cc.shortcuts.cancel();
        if (cc.systemd_client) |client| client.detachSettings();
        cc.services.deinit();
        cc.network.deinit();
        if (cc.page == .bluetooth) if (cc.server.bluetooth) |m| m.closed();
        cc.bluetooth.deinit();
        users_section.deinit(cc);
        cc.shortcuts.arena.deinit();
        cc.desktop.arena.deinit();
        cc.region.arena.deinit();
        cc.portals.arena.deinit();
        cc.default_apps.arena.deinit();
        cc.display.arena.deinit();
        appearance_section.deinit(&cc.appearance);
        cc.appearance.arena.deinit();
        cc.appearance.font_arena.deinit();
        cc.background.deinit(gpa);
        // The buffer node belongs to the window's tree and may outlive this
        // in the close animation's snapshot pass: unhook it from us first.
        cc.buffer_node.node.data = null;
        const toplevel = cc.toplevel;
        toplevel.backend.shell.control_center = null;
        toplevel.destroy();
        PanelBuffer.drainPool();
        if (cc.server.ipc) |ipc| ipc.wait_mgr.checkAll();
        gpa.destroy(cc);
    }

    /// The window was activated or deactivated (`Toplevel.setActivated`).
    pub fn setActivated(cc: *ControlCenter, activated: bool) void {
        if (cc.focused == activated) return;
        cc.focused = activated;
        if (!activated) {
            cc.shortcuts.cancel();
            cc.requestWidgetRepaint();
        }
    }

    /// Keys go to settings only while its window is the active one and no
    /// surface (layer shell, desktop, popup) took the keyboard since.
    pub fn hasKeyboardFocus(cc: *const ControlCenter) bool {
        if (!cc.focused) return false;
        const toplevel = cc.toplevel;
        if (!toplevel.in_world or toplevel.minimized) return false;
        if (cc.server.world.toplevels.first() != toplevel) return false;
        if (cc.server.input.seat.keyboard_state.focused_surface != null) return false;
        if (cc.server.desktop) |desktop| if (desktop.keyboard_focused) return false;
        return true;
    }

    /// Raises and focuses the window, restoring it if minimized.
    pub fn present(cc: *ControlCenter) void {
        const toplevel = cc.toplevel;
        if (toplevel.minimized) toplevel.restore() else cc.server.world.focus(toplevel);
        const Output = @import("../Output.zig");
        if (Output.fromWlr(cc.wlr_output)) |output| cc.server.world.navigateTo(toplevel, output);
        cc.server.scheduleFrames();
    }

    /// Frames come from `wlr_output`, or from any output while it is off
    /// (see Output.handleFrame).
    pub fn scheduleFrame(cc: *ControlCenter) void {
        if (cc.wlr_output.enabled) cc.wlr_output.scheduleFrame() else cc.server.scheduleFrames();
    }

    /// The window moves to `output` when its own output goes away.
    pub fn adoptOutput(cc: *ControlCenter, output: *wlr.Output) void {
        cc.wlr_output = output;
        cc.refresh();
    }

    /// The content's on-screen box in layout coordinates, for IPC.
    pub fn screenBox(cc: *const ControlCenter) wlr.Box {
        const toplevel = cc.toplevel;
        const origin = toplevel.frameWorld(@floatFromInt(toplevel.borderWidth()), @floatFromInt(toplevel.titlebarHeight()));
        const layout_origin = cc.server.world.toLayout(origin.x, origin.y);
        return .{
            .x = @intFromFloat(@round(layout_origin.x)),
            .y = @intFromFloat(@round(layout_origin.y)),
            .width = cc.panel_box.width,
            .height = cc.panel_box.height,
        };
    }

    /// Content-local coordinates of layout point (lx, ly).
    pub fn localPoint(cc: *const ControlCenter, lx: f64, ly: f64) struct { x: f64, y: f64 } {
        const toplevel = cc.toplevel;
        const local = toplevel.frameLocal(lx, ly);
        return .{
            .x = local.x - @as(f64, @floatFromInt(toplevel.borderWidth())),
            .y = local.y - @as(f64, @floatFromInt(toplevel.titlebarHeight())),
        };
    }

    /// Nothing left to lay out, paint or glide.
    pub fn settled(cc: *const ControlCenter) bool {
        return !cc.dirty and !cc.refresh_pending and !cc.layout_pending and !cc.scroll_gliding and !cc.bars.active and
            cc.nav_selection.settled(anim.nowMs()) and !cc.nav_hover.animating(anim.nowMs());
    }

    /// The window's content size changed (`Toplevel.requestSize`).
    pub fn resize(cc: *ControlCenter, width: i32, height: i32) void {
        if (cc.panel_box.width == width and cc.panel_box.height == height) return;
        cc.panel_box.width = width;
        cc.panel_box.height = height;
        cc.layout_pending = true;
        cc.scheduleFrame();
    }

    fn buildTree(cc: *ControlCenter) void {
        cc.services.capture();
        if (cc.page == .bluetooth and cc.built_page == .bluetooth) cc.bluetooth.capture();
        if (cc.page == .network and cc.built_page == .network) cc.network.captureFocus();
        if (cc.page == .appearance) appearance_section.captureItemFocus(&cc.appearance);
        ui.input.reset();
        const has_services = if (cc.systemd_client) |client| client.available() else false;
        if (cc.page == .services and !has_services) cc.page = .general;
        const selected_row: f32 = @floatFromInt(@intFromEnum(cc.page));
        if (cc.nav_selection.to != selected_row) cc.nav_selection.cancel(selected_row);
        const t = palette();
        if (cc.page == .displays) {
            const selected = cc.selectedDisplayOutput() orelse cc.wlr_output;
            display_section.build(&cc.display, cc, selected);
        }
        if (cc.page == .general or cc.page == .audio) {
            sound_section.build(&cc.sound, cc.server.audio);
            restyle(&cc.sound.root);
        }
        if (cc.page == .appearance) {
            appearance_section.build(&cc.appearance, cc);
            restyle(&cc.appearance.root);
        }
        if (cc.page == .input) {
            input_section.build(&cc.input, &cc.server.input);
            restyle(&cc.input.root);
        }
        if (cc.page == .displays) restyle(&cc.display.root);
        if (cc.page == .users) {
            users_section.build(&cc.users, cc);
            restyle(&cc.users.root);
        }

        const narrow = cc.panel_box.width < 660;
        const nav_count = page_names.len - @as(usize, @intFromBool(!has_services));
        const nav_gap: f32 = if (cc.panel_box.height < 550) 2 else 5;
        const nav_height = @min(52, @max(24, (@as(f32, @floatFromInt(cc.panel_box.height)) - 48 - nav_gap * @as(f32, @floatFromInt(nav_count - 1))) / @as(f32, @floatFromInt(nav_count))));
        for (cc.nav_rows[0..nav_count], 0..) |*row, i| {
            const selected = i == @intFromEnum(cc.page);
            cc.nav_children[i] = .{
                .{ .kind = .{ .icon = .{ .id = page_icons[i], .color = if (selected) t.accent else t.fg } }, .width = .{ .fixed = 22 }, .height = .{ .fixed = 22 } },
                label(page_labels[i], 14, false),
            };
            cc.nav_children[i][1].width = .{ .flex = 1 };
            row.* = .{
                .name = page_names[i],
                .kind = .{ .row = .{ .owner = cc, .id = i, .selected = selected, .underlay = true, .on_click = pageClicked } },
                .width = .{ .percent = 1 },
                .height = .{ .fixed = nav_height },
                .padding = layout.Edges.xy(16, 0),
                .gap = 14,
                .@"align" = .center,
                .children = cc.nav_children[i][0..if (narrow) @as(usize, 1) else 2],
            };
        }
        cc.content_count = 0;
        var heading = label(page_labels[@intFromEnum(cc.page)], 24, false);
        heading.kind.text.weight = 600;
        if (cc.page != .bluetooth) {
            cc.append(heading);
            cc.append(label(page_descriptions[@intFromEnum(cc.page)], 13, true));
        }
        switch (cc.page) {
            .desktop => {
                desktop_section.build(&cc.desktop, cc);
                cc.append(cc.desktop.root);
            },
            .region => {
                region_section.build(&cc.region, cc);
                cc.append(cc.region.root);
            },
            .users => cc.append(cc.users.root),
            .services => {
                services_section.build(&cc.services, cc);
                cc.append(cc.services.root);
            },
            .shortcuts => {
                shortcut_section.build(&cc.shortcuts, cc);
                for (cc.shortcuts.groups[0..cc.shortcuts.group_count]) |widget| cc.append(widget);
            },
            .general => cc.buildGeneral(),
            .bluetooth => {
                bluetooth_section.build(&cc.bluetooth, cc);
                cc.append(cc.bluetooth.root);
            },
            .network => {
                network_section.build(&cc.network, cc);
                cc.append(cc.network.root);
            },
            .input => for (cc.input.row_storage[0..cc.input.row_count]) |*row| {
                var framed = card(row.children);
                framed.name = "input";
                framed.direction = row.direction;
                framed.justify = row.justify;
                framed.@"align" = if (row.direction == .column) .stretch else row.@"align";
                cc.append(framed);
            },
            .displays => {
                if (cc.display.has_arrangement) {
                    var arrangement_card = card(&cc.display.arrangement_children);
                    arrangement_card.name = "displays";
                    cc.append(arrangement_card);
                }
                var display_card = card(&cc.display.row_storage);
                display_card.name = "displays";
                cc.append(display_card);
                cc.append(cc.display.top_children[2]);
                cc.append(cc.display.xwayland_hint);
                var nl_card = card(&cc.display.nl_group_children);
                nl_card.name = "displays";
                cc.append(nl_card);
                if (cc.display.has_lid) {
                    var lid_card = card(&cc.display.lid_group_children);
                    lid_card.name = "displays";
                    cc.append(lid_card);
                }
            },
            .audio => {
                var audio_card = card(cc.sound.top_children[1].children);
                audio_card.name = "sound";
                cc.append(audio_card);
                cc.buildDevices();
                if (cc.device_count > 0) {
                    cc.device_title = .{ label("Audio output", 16, false), .{ .kind = .container, .direction = .column, .gap = 4, .children = cc.device_rows[0..cc.device_count] } };
                    var dev_card = card(&cc.device_title);
                    dev_card.name = "sound";
                    cc.append(dev_card);
                }
            },
            .appearance => for (&cc.appearance.row_storage) |*row| {
                var framed = card(row.children);
                framed.name = "appearance";
                framed.direction = row.direction;
                framed.justify = row.justify;
                framed.@"align" = if (row.direction == .column) .stretch else row.@"align";
                cc.append(framed);
            },
        }
        cc.body_children = .{
            .{ .name = "nav", .kind = .{ .rect = .{ .color = t.app_sidebar, .radius = t.settings_sidebar_radius, .border_width = 1, .border_color = t.app_item_border } }, .direction = .column, .width = .{ .fixed = if (narrow) 70 else 238 }, .height = .{ .percent = 1 }, .padding = layout.Edges.all(8), .gap = nav_gap, .underlay = .{ .owner = cc, .paint = paintNavHighlights }, .children = cc.nav_rows[0..nav_count] },
            .{ .kind = .{ .scroll_container = .{} }, .direction = .column, .@"align" = .stretch, .width = .{ .flex = 1 }, .height = .{ .percent = 1 }, .padding = layout.Edges.all(12), .gap = 14, .children = cc.content_children[0..cc.content_count] },
        };
        if (cc.page == .services) {
            cc.body_children[1].kind = .container;
        } else {
            // Keep the scrollbar's full hover/drag gutter outside the cards.
            cc.body_children[1].padding.right += ui.widgets.scrollbar.gutter(theme.global.scrollbar_width);
        }
        cc.root_children = .{
            .{ .kind = .container, .direction = .row, .padding = .{ .left = 16, .top = 16, .bottom = 16, .right = if (cc.page == .services) 16 else 6 }, .gap = 14, .width = .{ .percent = 1 }, .height = .{ .flex = 1 }, .children = &cc.body_children },
        };
        // Opaque like a client's content: only the window chrome is glass.
        cc.root = .{
            .kind = .{ .rect = .{ .color = bodyColor() } },
            .direction = .column,
            .gap = 0,
            .width = .{ .fixed = @floatFromInt(cc.panel_box.width) },
            .height = .{ .fixed = @floatFromInt(cc.panel_box.height) },
            .children = &cc.root_children,
        };
        cc.root.linkParents();
        if (cc.page == .services and cc.services.search_focus) {
            if (cc.services.search) |field| ui.input.current.focus(&cc.root, field);
        }
        if (cc.page == .users) {
            if (users_section.initialFormFocus(&cc.users)) |field| ui.input.current.focus(&cc.root, field);
        }
        cc.built_page = cc.page;
        cc.refresh_pending = false;
    }

    fn append(cc: *ControlCenter, widget: Widget) void {
        const idx = cc.content_count;
        layout.appendRow(&cc.content_children, &cc.content_count, widget);
        if (idx < cc.content_count) {
            restyle(&cc.content_children[idx]);
        }
    }

    fn buildGeneral(cc: *ControlCenter) void {
        portal_section.build(&cc.portals, cc);
        cc.append(cc.portals.root);
        cc.general_volume = .{ label("Master volume", 16, false), if (cc.server.audio != null) cc.sound.body_children[1] else label("Audio unavailable", 13, true) };
        var vol_card = card(&cc.general_volume);
        vol_card.name = "sound";
        cc.append(vol_card);
        cc.brightness_children = .{ label("Brightness", 16, false), label(if (cc.server.brightness.failed) "No supported backlight" else "Checking backlight…", 13, true) };
        if (cc.server.brightness.level) |level| {
            cc.brightness_row = .{
                .{ .kind = .{ .icon = .{ .id = .brightness, .color = palette().fg } }, .width = .{ .fixed = 24 }, .height = .{ .fixed = 24 } },
                .{ .name = "brightness", .kind = .{ .slider = .{ .style = .settings, .value = level, .min = 0.01, .max = 1, .step = 0.01, .owner = cc, .on_change = brightnessChanged } }, .width = .{ .flex = 1 } },
                ui.widgets.slider.valuePill(std.fmt.bufPrint(&cc.brightness_percent, "{d}%", .{@as(i32, @intFromFloat(@round(level * 100)))}) catch "", 13, palette().dim),
            };
            cc.brightness_row[2].width = .{ .fixed = 52 };
            cc.brightness_children[1] = .{ .kind = .container, .direction = .row, .gap = 12, .@"align" = .center, .children = &cc.brightness_row };
        }
        cc.append(card(&cc.brightness_children));
        cc.general_output_text = .{
            label("Audio output", 16, false),
            label(if (cc.sound.output_desc_len > 0) cc.sound.output_desc_buf[0..cc.sound.output_desc_len] else "No audio device available", 13, true),
        };
        cc.general_output = .{
            .{ .kind = .container, .direction = .column, .@"align" = .stretch, .width = .{ .flex = 1 }, .gap = 5, .children = &cc.general_output_text },
            .{ .kind = .{ .button = .{ .label = "Audio settings", .owner = cc, .id = @intFromEnum(Page.audio), .on_click = pageClicked } }, .height = .{ .fixed = 32 } },
        };
        var output_card = card(&cc.general_output);
        output_card.direction = .row;
        output_card.@"align" = .center;
        cc.append(output_card);
        cc.general_display_text = .{ label("Display", 16, false), label(std.mem.span(cc.wlr_output.name), 13, true) };
        cc.general_display = .{
            .{ .kind = .container, .direction = .column, .@"align" = .stretch, .width = .{ .flex = 1 }, .gap = 5, .children = &cc.general_display_text },
            .{ .kind = .{ .button = .{ .label = "Display settings", .owner = cc, .id = @intFromEnum(Page.displays), .on_click = pageClicked } }, .height = .{ .fixed = 32 } },
        };
        var display_card = card(&cc.general_display);
        display_card.direction = .row;
        display_card.@"align" = .center;
        cc.append(display_card);
        default_apps_section.build(&cc.default_apps, cc);
        cc.append(cc.default_apps.root);
    }

    fn buildDevices(cc: *ControlCenter) void {
        cc.device_count = 0;
        const mgr = cc.server.audio orelse return;
        mgr.lock();
        defer mgr.unlock();
        for (mgr.sinks.items) |sink| {
            if (std.mem.startsWith(u8, sink.name, "rediwm.bass.")) continue;
            if (cc.device_count == max_devices) break;
            const i = cc.device_count;
            // Never offer a truncated identifier to the audio backend.
            if (sink.name.len >= cc.device_names[i].len) continue;
            @memcpy(cc.device_names[i][0..sink.name.len], sink.name);
            cc.device_name_lens[i] = sink.name.len;
            const len = @min(sink.description.len, cc.device_labels[i].len);
            @memcpy(cc.device_labels[i][0..len], sink.description[0..len]);
            cc.device_children[i] = .{
                .{ .kind = .{ .icon = .{ .id = if (sink.is_default) .checkmark else .volume, .color = palette().fg } }, .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } },
                label(cc.device_labels[i][0..len], 13, false),
            };
            cc.device_children[i][1].width = .{ .flex = 1 };
            cc.device_rows[i] = .{ .kind = .{ .row = .{ .selected = sink.is_default, .owner = cc, .id = i, .on_click = deviceClicked } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 44 }, .padding = layout.Edges.xy(12, 0), .gap = 12, .@"align" = .center, .children = &cc.device_children[i] };
            cc.device_count += 1;
        }
    }

    pub fn selectPage(cc: *ControlCenter, page: Page) void {
        cc.shortcuts.cancel();
        if (cc.page == .network and page != .network) cc.network.clearForm();
        if (cc.page == .bluetooth and page != .bluetooth) {
            if (cc.server.bluetooth) |m| m.closed();
            cc.bluetooth.clearPin();
        }
        if (cc.page != page) cc.nav_selection.retargetTo(anim.nowMs(), @floatFromInt(@intFromEnum(page)), anim.curveFor(.start_glide));
        cc.page = page;
        if (page == .bluetooth and !cc.server.greeter_mode) {
            if (cc.panel_box.width == default_width) _ = cc.toplevel.requestSize(1120, cc.panel_box.height);
            if (cc.server.bluetooth) |m| m.opened() else cc.server.bluetooth = @import("../bluetooth.zig").Manager.create(cc.server) catch null;
        }
        if (page == .network) {
            // Start wide enough for the two columns; narrower resized windows
            // stack them and keep the same controls accessible.
            if (cc.panel_box.width == default_width) _ = cc.toplevel.requestSize(1120, cc.panel_box.height);
            if (cc.server.network) |manager| manager.opened();
        }
        if (cc.panel_box.width < cc.minimumWidth() or cc.panel_box.height < cc.minimumHeight()) {
            _ = cc.toplevel.requestSize(@max(cc.panel_box.width, cc.minimumWidth()), @max(cc.panel_box.height, cc.minimumHeight()));
        }
        cc.relayout();
        cc.scheduleFrame();
    }

    pub fn refresh(cc: *ControlCenter) void {
        cc.refresh_pending = true;
        cc.scheduleFrame();
    }

    pub fn selectDisplayOutput(cc: *ControlCenter, name: []const u8) void {
        cc.selected_output_name_len = @min(name.len, cc.selected_output_name.len);
        @memcpy(cc.selected_output_name[0..cc.selected_output_name_len], name[0..cc.selected_output_name_len]);
        cc.refresh();
    }

    fn selectedDisplayOutput(cc: *ControlCenter) ?*wlr.Output {
        if (cc.selected_output_name_len > 0) {
            const name = cc.selected_output_name[0..cc.selected_output_name_len];
            if (cc.server.findOutputByName(name)) |output| return output.wlr_output;
        }
        return cc.wlr_output;
    }

    /// Route select keys before panel-level Escape. Tab cycles display fields.
    pub fn selectKey(cc: *ControlCenter, key: ui.input.Key, shift: bool) bool {
        if (cc.page != .displays and cc.page != .appearance and cc.page != .desktop and cc.page != .general and cc.page != .users and cc.page != .services and cc.page != .network and cc.page != .bluetooth and cc.page != .region) return false;
        const dispatcher = &ui.input.current;
        if (cc.page == .appearance) {
            if (appearance_section.itemKey(&cc.appearance, key)) return true;
            if (key == .tab) {
                _ = dispatcher.focusNext(&cc.root, shift);
                cc.requestWidgetRepaint();
                return true;
            }
            if (dispatcher.focused) |widget| {
                if (widget.kind == .checkbox and (key == .enter or (key == .char and std.mem.eql(u8, key.char, " ")))) {
                    @import("ui").widgets.checkbox.toggle(widget);
                    cc.requestWidgetRepaint();
                    return true;
                }
            }
        }
        if (cc.page == .users or cc.page == .services or cc.page == .network or cc.page == .bluetooth or cc.page == .region) {
            const focused = dispatcher.focused;
            if (cc.page == .bluetooth and bluetooth_section.key(cc, key)) return true;
            if (cc.page == .network and (focused == null or focused.?.kind != .select or !focused.?.kind.select.open)) {
                if (network_section.key(cc, key)) return true;
            }
            if (key == .tab) {
                if (focused) |widget| {
                    if (widget.kind == .select and widget.kind.select.open) {
                        _ = dispatcher.keyEvent(gpa, key, .{ .shift = shift }) catch return true;
                    }
                }
                _ = dispatcher.focusNext(&cc.root, shift);
                cc.requestWidgetRepaint();
                return true;
            }
            if (cc.page == .users and key == .escape and cc.users.form != .none) {
                if (focused) |widget| {
                    if (widget.kind == .select and widget.kind.select.open) {
                        _ = dispatcher.keyEvent(gpa, key, .{ .shift = shift }) catch return true;
                        cc.requestWidgetRepaint();
                        return true;
                    }
                }
                if (users_section.escapeForm(cc)) return true;
            }
            if (focused) |widget| {
                const activate = key == .enter or (key == .char and std.mem.eql(u8, key.char, " "));
                if (activate and widget.kind == .button) {
                    const button = widget.kind.button;
                    if (button.state == .disabled) return true;
                    if (button.on_click) |callback| callback(button.owner, button.id);
                    cc.requestWidgetRepaint();
                    return true;
                }
                if (activate and widget.kind == .row) {
                    const row = widget.kind.row;
                    if (row.state != .disabled) if (row.on_click) |callback| callback(row.owner, row.id);
                    cc.applyPending();
                    cc.requestWidgetRepaint();
                    return true;
                }
                if (activate and widget.kind == .checkbox) {
                    if (widget.kind.checkbox.disabled) return true;
                    widget.kind.checkbox.checked = !widget.kind.checkbox.checked;
                    const data = widget.kind.checkbox;
                    widget.markDirty();
                    data.on_change(data.owner, data.id, data.checked);
                    cc.requestWidgetRepaint();
                    return true;
                }
                if (activate and widget.kind == .toggle) {
                    ui.widgets.toggle.toggle(widget);
                    cc.requestWidgetRepaint();
                    return true;
                }
                if (widget.kind == .text_input or widget.kind == .secret_input) {
                    _ = dispatcher.keyEvent(gpa, key, .{ .shift = shift }) catch return true;
                    cc.requestWidgetRepaint();
                    return true;
                }
                if (widget.kind == .select and widget.kind.select.open) {
                    _ = dispatcher.keyEvent(gpa, key, .{ .shift = shift }) catch return true;
                    cc.applyPending();
                    cc.requestWidgetRepaint();
                    return true;
                }
            }
            if (focused) |widget| {
                if (widget.kind != .select) return false;
            } else return false;
        }
        if (key == .tab and cc.page == .displays) {
            var index: usize = if (shift) 0 else 4;
            for (0..5) |i| {
                if (dispatcher.focused == &cc.display.row_children[i][1]) index = i;
            }
            for (0..5) |_| {
                index = if (shift) (index + 4) % 5 else (index + 1) % 5;
                const next = &cc.display.row_children[index][1];
                if (next.kind == .select and !next.kind.select.disabled) {
                    dispatcher.focus(&cc.root, next);
                    break;
                }
            }
            cc.requestWidgetRepaint();
            return true;
        }
        const focused = dispatcher.focused orelse return false;
        if (focused.kind != .select) return false;
        if (key == .escape and !focused.kind.select.open) return false;
        _ = dispatcher.keyEvent(gpa, key, .{ .shift = shift }) catch return true;
        cc.applyPending();
        cc.requestWidgetRepaint();
        return true;
    }

    fn applyOutputPatch(cc: *ControlCenter, output: *@import("../Output.zig"), patch: @import("config").output_config.Patch) void {
        cc.display.failed = false;
        cc.display.save_failed = false;
        output.applyAndPersist(patch) catch |err| {
            log.warn("could not apply display settings: {}", .{err});
            if (err == error.OutputSaveFailed) cc.display.save_failed = true else cc.display.failed = true;
        };
    }

    fn applyPending(cc: *ControlCenter) void {
        if (cc.page == .services) services_section.apply(&cc.services, cc);
        cc.shortcuts.apply(cc);
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
            if (display_section.pendingLidAction(&cc.display)) |action| {
                cc.display.initial_lid = @intFromEnum(action);
                cc.display.save_failed = false;
                @import("config").setting_save.saveCompositor(gpa, cc.server.io, cc.server.config.path, "lid_close", action) catch |err| {
                    log.warn("could not save lid_close: {}", .{err});
                    cc.display.save_failed = true;
                };
                // The reload applies it (`Output.applyLid`) and rebuilds this page.
                if (!cc.display.save_failed) @import("../config_runtime/watcher.zig").reloadConfig(cc.server);
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

    /// `buildTree`, keeping each slider's hover and feedback look across it
    /// when the page is the same: a theme slider's save rebuilds the page the
    /// moment the button is released, under a pointer that is still on it.
    fn rebuildTree(cc: *ControlCenter) void {
        const hovered_nav = cc.nav_hover.target;
        const same_page = cc.built_page == cc.page;
        const bluetooth_scroll: ?layout.ScrollState = if (same_page and cc.page == .bluetooth) cc.body_children[1].kind.scroll_container else null;
        var saved: ui.widgets.slider.Saved = .{};
        if (same_page) ui.widgets.slider.capture(&cc.root, &saved);
        cc.buildTree();
        if (hovered_nav) |cell| {
            const index: usize = @intCast(cell.row);
            if (index < cc.body_children[0].children.len) {
                cc.nav_rows[index].kind.row.state = .hover;
                ui.input.adoptHover(&cc.root, &cc.nav_rows[index]);
            } else cc.nav_hover.setTarget(anim.nowMs(), null);
        }
        if (bluetooth_scroll) |state| cc.body_children[1].kind.scroll_container = state;
        if (same_page) {
            if (ui.widgets.slider.restore(&cc.root, &saved)) |hovered| ui.input.adoptHover(&cc.root, hovered);
        }
    }

    pub fn relayout(cc: *ControlCenter) void {
        cc.layout_pending = false;
        if (cc.panel_box.width <= 0 or cc.panel_box.height <= 0) return;
        cc.rebuildTree();
        cc.layoutContent();
        cc.scheduleFrame();
    }

    fn layoutContent(cc: *ControlCenter) void {
        cc.background.invalidate();
        const width: f32 = @floatFromInt(cc.panel_box.width);
        const height: f32 = @floatFromInt(cc.panel_box.height);
        ui.measure.measure(&cc.root, width, height);
        ui.arrange.arrange(&cc.root, 0, 0, width, height);
        if (cc.page == .appearance) appearance_section.restoreItemFocus(&cc.appearance);
        if (cc.page == .network) network_section.restoreFocus(&cc.network, cc);
        if (cc.page == .bluetooth) bluetooth_section.restoreFocus(&cc.bluetooth, cc);
        cc.dirty = true;
    }

    /// Only structural breakpoints need a new tree. Ordinary resize frames
    /// retain fields, scroll positions and settings data (including filesystem lists).
    fn resizeNeedsTree(cc: *const ControlCenter) bool {
        const old = cc.root.computed_width;
        const width: f32 = @floatFromInt(cc.panel_box.width);
        const thresholds: []const f32 = switch (cc.page) {
            .shortcuts => &.{660},
            .desktop => &.{760},
            .bluetooth => &.{ 900, 1000 },
            .network => &.{1000},
            .region => &.{900},
            .services => &.{ 660, 752, 928, 1040 },
            else => &.{},
        };
        for (thresholds) |at| if ((old < at) != (width < at)) return true;
        return false;
    }

    fn resizeLayout(cc: *ControlCenter) void {
        const narrow = cc.panel_box.width < 660;
        const nav_count = cc.body_children[0].children.len;
        const gap: f32 = if (cc.panel_box.height < 550) 2 else 5;
        const height = @min(52, @max(24, (@as(f32, @floatFromInt(cc.panel_box.height)) - 48 - gap * @as(f32, @floatFromInt(nav_count - 1))) / @as(f32, @floatFromInt(nav_count))));
        cc.body_children[0].width = .{ .fixed = if (narrow) 70 else 238 };
        cc.body_children[0].gap = gap;
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

    /// Runs once per frame of `wlr_output` while anything is pending.
    /// Returns whether another frame should be scheduled.
    pub fn tick(cc: *ControlCenter, now_ms: i64) bool {
        const rebuild = cc.refresh_pending and !cc.pointer_down and ui.input.openSelect(&cc.root) == null;
        if ((cc.layout_pending or rebuild) and cc.panel_box.width > 0 and cc.panel_box.height > 0) {
            cc.layout_pending = false;
            const body = if (cc.body_children[1].kind == .scroll_container) cc.body_children[1].kind.scroll_container else null;
            if (rebuild or cc.resizeNeedsTree()) cc.rebuildTree();
            cc.resizeLayout();
            // Keep a wheel glide going across the rebuild.
            if (cc.body_children[1].kind == .scroll_container) {
                if (body) |state| cc.body_children[1].kind.scroll_container = state;
            }
            cc.layoutContent();
        }
        if (cc.scroll_gliding) {
            const revision = ui.layout.paint_revision;
            cc.scroll_gliding = ui.widgets.scroll_container.stepGlides(&cc.root, now_ms, anim.rasterPixelQuantum(cc.toplevel.render_scale));
            if (revision != ui.layout.paint_revision) cc.dirty = true;
        }
        {
            const revision = ui.layout.paint_revision;
            cc.bars = ui.widgets.scroll_container.stepBars(&cc.root, now_ms);
            if (revision != ui.layout.paint_revision) cc.dirty = true;
        }
        if (cc.painted_scale != cc.toplevel.render_scale) {
            cc.background.invalidate();
            cc.dirty = true;
        }
        if (cc.stepNavHighlights(now_ms)) cc.dirty = true;
        if (cc.dirty) cc.paintContent();
        const selection_moving = anim.observeUnsettled(cc.nav_selection, now_ms);
        const hover_moving = anim.observeUnsettled(cc.nav_hover.row, now_ms);
        const hover_fading = anim.observeUnsettled(cc.nav_hover.alpha, now_ms);
        const nav_moving = selection_moving or hover_moving or hover_fading;
        return cc.dirty or cc.layout_pending or ((cc.scroll_gliding or cc.bars.pending() or nav_moving) and !anim.clockOverridden());
    }

    fn syncNavHover(cc: *ControlCenter) void {
        const cell: ?ui.hover_glide.Cell = if (ui.input.current.hovered) |widget| switch (widget.kind) {
            .row => |data| if (data.owner == @as(?*anyopaque, cc) and data.on_click == pageClicked)
                .{ .col = 0, .row = @intCast(data.id) }
            else
                null,
            else => null,
        } else null;
        if (std.meta.eql(cc.nav_hover.target, cell)) return;
        cc.nav_hover.setTarget(anim.nowMs(), cell);
        cc.scheduleFrame();
    }

    fn stepNavHighlights(cc: *ControlCenter, now_ms: i64) bool {
        const list = &cc.body_children[0];
        if (list.children.len == 0) return false;
        const pitch = @max(1, list.children[0].computed_height + list.gap);
        const q = anim.rasterPixelQuantum(cc.toplevel.render_scale) / pitch;
        const pos = cc.nav_selection.value(now_ms);
        const selected = if (cc.nav_selection.settled(now_ms)) pos else @round(pos / q) * q;
        const hover_changed = cc.nav_hover.step(now_ms, 1, q);
        if (selected == cc.nav_selected_row and !hover_changed) return false;
        cc.nav_selected_row = selected;
        list.markPaintDirty();
        anim.observeNoteChanged();
        return true;
    }

    /// Paint once beneath the rows so the fills can move through their gaps.
    fn paintNavHighlights(owner: ?*anyopaque, list: *const Widget, renderer: *ui.paint.Renderer) void {
        const cc: *ControlCenter = @ptrCast(@alignCast(owner orelse return));
        if (list.children.len == 0) return;
        const t = renderer.palette orelse palette();
        const hover = cc.nav_hover.frame;
        const apart = std.math.clamp(@abs(hover.row - cc.nav_selected_row), 0, 1);
        const alpha = std.math.clamp(hover.alpha, 0, 1) * apart;
        if (alpha > 0) {
            const box = navRowBox(list, hover.row);
            renderer.fillRect(box.x, box.y, box.w, box.h, .{
                .color = scaleAlpha(t.surface_hover, alpha),
                .radius = t.radius,
                .border_width = 1,
                .border_color = scaleAlpha(t.border_soft, alpha),
            });
        }
        const box = navRowBox(list, cc.nav_selected_row);
        renderer.fillRect(box.x, box.y, box.w, box.h, .{
            .color = t.start_menu_selected_bg,
            .radius = t.radius,
            .border_width = 1,
            .border_color = t.start_menu_selected_border,
        });
        const marker_h = @max(10, box.h - 18);
        renderer.fillRect(box.x + 3, box.y + (box.h - marker_h) / 2, 3, marker_h, .{
            .color = t.start_menu_selected_marker,
            .radius = 1.5,
        });
    }

    fn navRowBox(list: *const Widget, pos: f32) ui.paint.ClipRect {
        const clamped = std.math.clamp(pos, 0, @as(f32, @floatFromInt(list.children.len - 1)));
        const lo: usize = @intFromFloat(@floor(clamped));
        const a = &list.children[lo];
        const b = &list.children[@min(lo + 1, list.children.len - 1)];
        const f = clamped - @as(f32, @floatFromInt(lo));
        return .{ .x = a.computed_x, .y = a.computed_y + (b.computed_y - a.computed_y) * f, .w = a.computed_width, .h = a.computed_height };
    }

    fn scaleAlpha(color: [4]f32, alpha: f32) [4]f32 {
        return .{ color[0], color[1], color[2], color[3] * alpha };
    }

    fn requestWidgetRepaint(cc: *ControlCenter) void {
        cc.dirty = true;
        cc.scheduleFrame();
    }

    pub fn requestRepaint(cc: *ControlCenter) void {
        cc.background.invalidate();
        cc.dirty = true;
        cc.scheduleFrame();
    }

    fn paintContent(cc: *ControlCenter) void {
        if (cc.panel_box.width <= 0 or cc.panel_box.height <= 0) return;
        // The window's chrome raster scale: the highest output scale it touches.
        const scale = cc.toplevel.render_scale;
        if (cc.painted_scale != scale) cc.background.invalidate();
        const buf = PanelBuffer.createUninitialized(cc.panel_box.width, cc.panel_box.height, scale) catch |err| {
            log.err("ControlCenter.paintContent: could not create panel buffer: {}", .{err});
            return;
        };

        const t0 = panel_present.nowNs();
        var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        renderer.palette = palette();
        cc.background.paintIncremental(gpa, &cc.root, &renderer);
        const elapsed_ns = panel_present.nowNs() -| t0;

        // A world node reaches its projected view only with the damage we
        // report (AGENTS.md, "Damage and retained pixels"); buffer-local, at the real raster scale.
        var region: pixman.Region32 = undefined;
        region.init();
        defer region.deinit();
        const full = cc.painted_scale != scale or cc.background.damage == null;
        if (cc.background.damage) |box| {
            const x: i32 = @intFromFloat(@floor(box.x * scale));
            const y: i32 = @intFromFloat(@floor(box.y * scale));
            const right: i32 = @intFromFloat(@ceil((box.x + box.w) * scale));
            const bottom: i32 = @intFromFloat(@ceil((box.y + box.h) * scale));
            _ = region.unionRect(&region, x, y, @intCast(@max(0, right - x)), @intCast(@max(0, bottom - y)));
        }
        _ = cc.server.world.projection.presentOwned(cc.buffer_node, cc.server.renderer, &buf.base, if (full) null else &region);
        cc.buffer_node.setDestSize(cc.panel_box.width, cc.panel_box.height);
        buf.base.drop();
        panel_present.addPaint(elapsed_ns);
        cc.painted_scale = scale;
        cc.dirty = false;
    }
};

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

pub fn pointerButtonDown(cc: *ControlCenter, sx: f64, sy: f64) void {
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

fn pageClicked(owner: ?*anyopaque, id: usize) void {
    const cc: *ControlCenter = @ptrCast(@alignCast(owner orelse return));
    cc.pending_page = @enumFromInt(id);
}

fn deviceClicked(owner: ?*anyopaque, id: usize) void {
    const cc: *ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (id >= cc.device_count) return;
    if (cc.server.audio) |mgr| mgr.setDefaultSink(cc.device_names[id][0..cc.device_name_lens[id]]);
}

fn brightnessChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const cc: *ControlCenter = @ptrCast(@alignCast(owner orelse return));
    const server = cc.server;
    server.brightness.set(server, value);
    cc.brightness_row[2].kind.text.content = std.fmt.bufPrint(&cc.brightness_percent, "{d}%", .{@as(i32, @intFromFloat(@round(value * 100)))}) catch "";
    cc.brightness_row[2].markDirty();
}
