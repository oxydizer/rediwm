//! Building the widget tree: the sidebar, page content, the General page and devices.

const i18n = @import("i18n");
const std = @import("std");
const gpa = @import("../main.zig").gpa;
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
const users_section = @import("sections/users.zig");
const bluetooth_section = @import("sections/bluetooth.zig");
const region_section = @import("sections/region.zig");
const network_section = @import("sections/network.zig");
const welcome_section = @import("welcome.zig");
const settings_search = @import("search.zig");
const theme = @import("ui").theme;
const Page = @import("search_index.zig").Page;
const panel = @import("panel.zig");
const page_labels = panel.page_labels;
const sidebarWidth = panel.sidebarWidth;
const page_names = panel.page_names;
const page_descriptions = panel.page_descriptions;
const page_icons = panel.page_icons;
const max_devices = panel.max_devices;
const palette = panel.palette;
const label = panel.label;
const sectionTitle = panel.sectionTitle;
const card = panel.card;
const restyle = panel.restyle;
const bodyColor = panel.bodyColor;
const pageClicked = panel.pageClicked;
const deviceClicked = panel.deviceClicked;
const brightnessChanged = panel.brightnessChanged;
const filesSingleClickChanged = panel.filesSingleClickChanged;
const ControlCenter = @import("ControlCenter.zig");
const paintNavHighlights = ControlCenter.paintNavHighlights;

pub fn buildTree(cc: *ControlCenter) void {
    if (cc.is_welcome) {
        ui.input.reset();
        cc.content_children[0] = welcome_section.build(cc);
        cc.body_children = .{ .{ .kind = .container }, .{ .kind = .{ .scroll_container = .{} }, .direction = .column, .@"align" = .stretch, .width = .{ .percent = 1 }, .height = .{ .flex = 1 }, .padding = layout.Edges.all(28), .children = cc.content_children[0..1] } };
        cc.body_children[1].padding = layout.Edges.all(if (welcome_section.compact(cc)) 20 else 28);
        cc.body_children[1].padding.bottom = 8;
        cc.root_children = .{ .{ .kind = .container, .direction = .column, .width = .{ .percent = 1 }, .height = .{ .flex = 1 }, .children = cc.body_children[1..2] }, cc.welcome.footer };
        cc.root = .{ .kind = .{ .rect = .{ .color = bodyColor() } }, .direction = .column, .width = .{ .fixed = @floatFromInt(cc.panel_box.width) }, .height = .{ .fixed = @floatFromInt(cc.panel_box.height) }, .children = &cc.root_children };
        cc.root.linkParents();
        cc.built_page = cc.page;
        cc.refresh_pending = false;
        releaseRetired(cc);
        return;
    }
    cc.search.capture();
    if (cc.search.empty() != cc.search.built_empty) {
        if (cc.search.empty()) {
            if (cc.body_children[1].kind == .scroll_container) cc.search.saved_scroll = cc.body_children[1].kind.scroll_container;
            cc.shortcuts.cancel();
            if (cc.page == .services) if (cc.systemd_client) |client| client.hide();
            if (cc.page == .printers) cc.printers.hide();
            if (cc.page == .bluetooth) if (cc.server.bluetooth) |manager| manager.closed();
        } else {
            cc.search.restore_scroll = true;
            if (cc.page == .bluetooth) if (cc.server.bluetooth) |manager| manager.opened();
        }
    }
    cc.services.capture();
    if (cc.page == .bluetooth and cc.built_page == .bluetooth) cc.bluetooth.capture();
    if (cc.page == .network and cc.built_page == .network) cc.network.captureFocus();
    if (cc.page == .printers and cc.built_page == .printers) cc.printers.capture();
    if (cc.page == .appearance) appearance_section.captureItemFocus(&cc.appearance);
    ui.input.reset();
    const has_services = if (cc.systemd_client) |client| client.available() else false;
    if (cc.page == .services and !has_services) cc.page = .general;
    const t = palette();
    if (!cc.search.empty()) {
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
    }
    const narrow = cc.panel_box.width < 660;
    var nav_count: usize = 0;
    for (page_names, 0..) |_, i| {
        const page: Page = @fromBackingInt(@intCast(i));
        if (page == .services and !has_services) continue;
        if (cc.search.active and cc.search.firstInPage(page) == null) continue;
        nav_count += 1;
    }
    const nav_gap: f32 = if (cc.panel_box.height < 550) 2 else 5;
    const nav_height = @min(52, @max(24, (@as(f32, @floatFromInt(cc.panel_box.height)) - 92 - (if (narrow and cc.search.expanded) @as(f32, 46) else 0) - nav_gap * @as(f32, @floatFromInt(nav_count -| 1))) / @as(f32, @floatFromInt(@max(1, nav_count)))));
    const nav_fg = theme.global.sidebarForeground();
    var nav_index: usize = 0;
    for (page_names, 0..) |_, i| {
        const page: Page = @fromBackingInt(@intCast(i));
        if (page == .services and !has_services) continue;
        if (cc.search.active and cc.search.firstInPage(page) == null) continue;
        const row = &cc.nav_rows[nav_index];
        const selected = page == cc.page;
        if (selected) {
            const position: f32 = @floatFromInt(nav_index);
            if (cc.nav_selection.to != position) cc.nav_selection.cancel(position);
        }
        cc.nav_children[nav_index] = .{
            .{ .kind = .{ .icon = .{ .id = page_icons[i], .color = if (selected) t.accent else nav_fg } }, .width = .{ .fixed = 22 }, .height = .{ .fixed = 22 } },
            label(if (page == .power and !cc.server.power_policy.state.present) i18n.tr("Power") else page_labels[i].get(), 14, false),
        };
        cc.nav_children[nav_index][1].kind.text.color = nav_fg;
        cc.nav_children[nav_index][1].width = .{ .flex = 1 };
        row.* = .{
            .name = page_names[i],
            .kind = .{ .row = .{ .owner = cc, .id = i, .selected = selected, .underlay = true, .on_click = pageClicked } },
            .width = .{ .percent = 1 },
            .height = .{ .fixed = nav_height },
            .padding = layout.Edges.xy(16, 0),
            .gap = 14,
            .@"align" = .center,
            .children = cc.nav_children[nav_index][0..if (narrow) @as(usize, 1) else 2],
        };
        nav_index += 1;
    }
    if (!cc.search.empty()) {
        cc.content_count = 0;
        var heading = label(if (cc.page == .power and !cc.server.power_policy.state.present) i18n.tr("Power") else page_labels[@backingInt(cc.page)].get(), 24, false);
        heading.kind.text.weight = 600;
        if (cc.page != .bluetooth) {
            cc.append(heading);
            cc.append(label(page_descriptions[@backingInt(cc.page)].get(), 13, true));
        }
        if (cc.search.unavailable) cc.append(label(i18n.tr("This setting is unavailable on this device or in the current mode."), t.settings_description_size, true));
        switch (cc.page) {
            .power => {
                @import("sections/power.zig").build(&cc.power_settings, cc);
                cc.append(cc.power_settings.root);
            },
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
            .printers => {
                printers_section.build(&cc.printers, cc);
                cc.append(cc.printers.root);
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
                cc.append(.{ .name = "power_settings_link", .kind = .{ .button = .{ .label = i18n.tr("Power and lid settings"), .owner = cc, .id = @backingInt(Page.power), .on_click = pageClicked } }, .height = .{ .fixed = 36 } });
            },
            .audio => {
                var audio_card = card(cc.sound.top_children[1].children);
                audio_card.name = "sound";
                cc.append(audio_card);
                cc.buildDevices();
                if (cc.device_count > 0) {
                    cc.device_title = .{ sectionTitle(i18n.tr("Audio output")), .{ .kind = .container, .direction = .column, .gap = 4, .children = cc.device_rows[0..cc.device_count] } };
                    var dev_card = card(&cc.device_title);
                    dev_card.name = "sound";
                    cc.append(dev_card);
                }
            },
            .appearance => for (&cc.appearance.group_cards) |*row| {
                var framed = card(row.children);
                framed.name = "appearance";
                framed.direction = row.direction;
                framed.justify = row.justify;
                framed.@"align" = if (row.direction == .column) .stretch else row.@"align";
                cc.append(framed);
            },
        }
    } else {
        cc.content_count = 0;
        cc.append(cc.search.noResults());
    }
    cc.search.buildToolbar(cc);
    cc.sidebar_children = .{
        if (narrow)
            .{ .name = "settings_search_open", .kind = .{ .button = .{ .icon = .search, .label = i18n.tr("Search settings"), .owner = cc, .on_click = settings_search.focusClicked } }, .height = .{ .fixed = 36 }, .width = .{ .percent = 1 } }
        else
            .{ .kind = .container, .height = .{ .fixed = 36 }, .width = .{ .percent = 1 }, .children = (&cc.search.toolbar)[0..1] },
        .{ .name = "nav", .kind = if (cc.panel_box.height < (if (narrow and cc.search.expanded) @as(i32, 486) else 440)) .{ .scroll_container = .{} } else .container, .direction = .column, .width = .{ .percent = 1 }, .height = .{ .flex = 1 }, .gap = nav_gap, .underlay = .{ .owner = cc, .paint = paintNavHighlights }, .children = cc.nav_rows[0..nav_count] },
    };
    cc.body_children = .{
        .{ .name = "settings_sidebar", .kind = .{ .rect = .{ .color = t.app_sidebar, .replace = t.app_sidebar[3] < 1, .radius = t.settings_sidebar_radius, .border_width = 1, .border_color = t.app_item_border } }, .direction = .column, .width = .{ .fixed = sidebarWidth(cc) }, .height = .{ .percent = 1 }, .padding = layout.Edges.all(8), .gap = 8, .children = &cc.sidebar_children },
        .{ .kind = .{ .scroll_container = .{} }, .direction = .column, .@"align" = .stretch, .width = .{ .flex = 1 }, .height = .{ .percent = 1 }, .padding = layout.Edges.all(12), .gap = 14, .children = cc.content_children[0..cc.content_count] },
    };
    if (cc.page == .services and !cc.search.empty()) {
        cc.body_children[1].kind = .container;
    } else {
        // Keep the scrollbar's full hover/drag gutter outside the cards.
        cc.body_children[1].padding.right += ui.widgets.scrollbar.gutter(theme.global.scrollbar_width);
    }
    cc.root_children[0] = .{ .kind = .container, .direction = .column, .padding = .{ .left = 16, .right = 16, .top = 10 }, .width = .{ .percent = 1 }, .height = .{ .fixed = 46 }, .children = (&cc.search.toolbar)[0..1] };
    cc.root_children[1] = .{ .kind = .container, .direction = .row, .padding = .{ .left = 16, .top = 16, .bottom = 16, .right = if (cc.page == .services) 16 else 6 }, .gap = 14, .width = .{ .percent = 1 }, .height = .{ .flex = 1 }, .children = &cc.body_children };
    // The content stays opaque; the sidebar replaces its background with
    // app_sidebar so translucent themes expose the scene beneath it.
    cc.root = .{
        .kind = .{ .rect = .{ .color = bodyColor() } },
        .direction = .column,
        .gap = 0,
        .width = .{ .fixed = @floatFromInt(cc.panel_box.width) },
        .height = .{ .fixed = @floatFromInt(cc.panel_box.height) },
        .children = cc.root_children[if (narrow and cc.search.expanded) @as(usize, 0) else 1..2],
    };
    cc.root.linkParents();
    if (!cc.search.empty() and cc.page == .services and cc.services.search_focus) {
        if (cc.services.search) |field| ui.input.current.focus(&cc.root, field);
    }
    if (!cc.search.empty() and cc.page == .users) {
        if (users_section.initialFormFocus(&cc.users)) |field| ui.input.current.focus(&cc.root, field);
    }
    if (cc.search.focused or cc.search.request_focus) {
        if (cc.search.initialized) ui.input.current.focus(&cc.root, &cc.search.field);
        cc.search.request_focus = false;
    }
    cc.search.reset_scroll = false;
    cc.search.built_empty = cc.search.empty();
    cc.built_page = cc.page;
    cc.refresh_pending = false;
    releaseRetired(cc);
}

/// Takes over a replaced config that the open page may still point into, and
/// asks for the rebuild that drops those pointers. Rebuilding here would run
/// inside whatever widget callback reloaded the config.
pub fn retireConfig(cc: *ControlCenter, old: *@import("config").loader.Config) void {
    cc.retired_configs.append(gpa, old.*) catch {
        old.deinit();
        return;
    };
    cc.refresh();
}

pub fn releaseRetired(cc: *ControlCenter) void {
    for (cc.retired_configs.items) |*old| old.deinit();
    cc.retired_configs.clearRetainingCapacity();
}

pub fn append(cc: *ControlCenter, widget: Widget) void {
    const idx = cc.content_count;
    layout.appendRow(&cc.content_children, &cc.content_count, widget);
    if (idx < cc.content_count) {
        restyle(&cc.content_children[idx]);
    }
}

pub fn buildGeneral(cc: *ControlCenter) void {
    portal_section.build(&cc.portals, cc);
    cc.append(cc.portals.root);
    cc.general_volume = .{ sectionTitle(i18n.tr("Master volume")), if (cc.server.audio != null) cc.sound.body_children[1] else label(i18n.tr("Audio unavailable"), 13, true) };
    var vol_card = card(&cc.general_volume);
    vol_card.name = "sound";
    cc.append(vol_card);
    cc.brightness_children = .{ sectionTitle(i18n.tr("Brightness")), label(if (cc.server.brightness.failed) i18n.tr("No supported backlight") else i18n.tr("Checking backlight…"), 13, true) };
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
        sectionTitle(i18n.tr("Audio output")),
        label(if (cc.sound.output_desc_len > 0) cc.sound.output_desc_buf[0..cc.sound.output_desc_len] else i18n.tr("No audio device available"), 13, true),
    };
    cc.general_output = .{
        .{ .kind = .container, .direction = .column, .@"align" = .stretch, .width = .{ .flex = 1 }, .gap = 5, .children = &cc.general_output_text },
        .{ .kind = .{ .button = .{ .label = i18n.tr("Audio settings"), .owner = cc, .id = @backingInt(Page.audio), .on_click = pageClicked } }, .height = .{ .fixed = 32 } },
    };
    var output_card = card(&cc.general_output);
    output_card.direction = .row;
    output_card.@"align" = .center;
    cc.append(output_card);
    cc.general_display_text = .{ sectionTitle(i18n.tr("Display")), label(std.mem.span(cc.wlr_output.name), 13, true) };
    cc.general_display = .{
        .{ .kind = .container, .direction = .column, .@"align" = .stretch, .width = .{ .flex = 1 }, .gap = 5, .children = &cc.general_display_text },
        .{ .kind = .{ .button = .{ .label = i18n.tr("Display settings"), .owner = cc, .id = @backingInt(Page.displays), .on_click = pageClicked } }, .height = .{ .fixed = 32 } },
    };
    var display_card = card(&cc.general_display);
    display_card.direction = .row;
    display_card.@"align" = .center;
    cc.append(display_card);
    default_apps_section.build(&cc.default_apps, cc);
    cc.append(cc.default_apps.root);
    cc.general_files_text = .{
        label(i18n.tr("Single-click file and folder icons"), 14, false),
        label(i18n.tr("In Files, click an icon to open it in list or icons view. Click the name to select."), 12, true),
    };
    cc.general_files = .{
        .{ .kind = .container, .direction = .column, .gap = 5, .width = .{ .flex = 1 }, .children = &cc.general_files_text },
        .{ .name = "files_single_click_open", .kind = .{ .toggle = .{ .on = cc.server.config.compositor.files_single_click_open, .owner = cc, .on_change = filesSingleClickChanged } } },
    };
    var files_card = card(&cc.general_files);
    files_card.direction = .row;
    files_card.@"align" = .center;
    cc.append(files_card);
}

pub fn buildDevices(cc: *ControlCenter) void {
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
