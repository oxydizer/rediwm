// Control center "Appearance" section: UI font, font size, and corner
// radius, all of which write back to REDIWM_THEME and hot-reload (design
// doc Part 3, Section 2), plus the apps' dark mode and the wallpaper, which
// are `[compositor] dark_mode` and `wallpaper` in config.toml.
//
// Widget callbacks carry their owning Section explicitly.
const std = @import("std");
const Server = @import("../../Server.zig");

const layout = @import("ui").layout;
const ui_slider = @import("ui").widgets.slider;
const theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const theme_presets = @import("ui").theme_presets;
const Widget = layout.Widget;
const main = @import("../../main.zig");
const panel = @import("../panel.zig");
const setting_save = @import("config").setting_save;
const settings_portal = @import("../../session/settings_portal.zig");
const loader = @import("config").loader;
const Taskbar = @import("../../Taskbar.zig");
const taskbar_items = @import("config").taskbar_items;
const cursor_theme = @import("../../cursor_theme.zig");
const wallpapers = @import("../../wallpapers.zig");
const wallpaper_strip = @import("../../wallpaper_strip.zig");
const folder_picker = @import("../folder_picker.zig");
const wl = @import("wayland").server.wl;
const actions = @import("../../config_runtime/actions.zig");
const anim = @import("ui").anim;
const ipc_animations = @import("../../ipc/animations.zig");

const segmented_width: f32 = 180;

const font_values = [3]f32{ 12, 13, 14 };
const font_labels = [_][]const u8{ "Small", "Medium", "Large" };
const radius_labels = [_][]const u8{ "Sharp", "Default", "Round" };
const shadow_size_values = [3]f32{ 0, 16, 32 };
const shadow_alpha_values = [3]f32{ 0, 0.28, 0.45 };
const shadow_labels = [_][]const u8{ "None", "Soft", "Strong" };
const anim_speed_values = [4]f32{ 0.5, 1.0, 1.5, 2.0 };
const anim_speed_labels = [_][]const u8{ "0.5×", "1.0×", "1.5×", "2.0×" };
const reduced_motion_values = [3]anim.ReducedMotion{ .auto, .on, .off };
const reduced_motion_labels = [_][]const u8{ "Auto", "On", "Off" };
const focus_zoom_labels = [_][]const u8{ "Keep zoom", "Boost window", "Focus camera" };
const focus_zoom_descriptions = [_][]const u8{
    "Pan to the selected window without changing zoom.",
    "Temporarily show the selected window at full size; keep desktop zoom.",
    "Zoom the desktop to the selected window's level; fade windows passed by the camera.",
};

fn indexOfReducedMotion(m: anim.ReducedMotion) usize {
    return switch (m) {
        .auto => 0,
        .on => 1,
        .off => 2,
    };
}

/// One "label + value" slider row (e.g. "Taskbar size ... 54px"), keyed by
/// index into `Section.px` below. Grouped into an array instead of one field
/// per control since the pixel sliders
/// are otherwise identical boilerplate.
const PxControl = struct {
    header_children: [2]Widget = undefined,
    group_children: [2]Widget = undefined,
    value_buf: [16]u8 = undefined,
};

const px_taskbar_size = 0;
const px_chip_gap = 1;
const px_start_button_gap = 2;
const px_start_icon_size = 3;
const px_menu_left = 4;
const px_menu_bottom = 5;
const px_icon_left = 6;
const px_icon_bottom = 7;
const px_scrollbar_width = 8;
const px_chip_width = 9;
const px_window_gap = 10;
const px_chrome_height = 11;
const px_chrome_control_gap = 12;

pub const Section = struct {
    cc: *panel.ControlCenter = undefined,
    root: Widget = undefined,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    presets: []const theme_presets.Preset = &.{},
    top_children: [2]Widget = undefined,
    font_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    font_families: ?[][]const u8 = null,
    /// Installed cursor themes, scanned once per section like the fonts.
    cursor_themes: ?[]cursor_theme.Theme = null,
    cursor_row_children: [2]Widget = undefined,
    family_row_children: [2]Widget = undefined,
    row_storage: [21]Widget = undefined,
    focus_zoom_children: [3]Widget = undefined,
    /// Rescanned on every build, so images added meanwhile show up.
    wallpapers: []const wallpapers.Entry = &.{},
    wallpaper_children: [3]Widget = undefined,
    /// What the wallpaper strip shows: the chosen folder's images, or
    /// the wallpaper directories'. Thumbnails decode on a worker.
    strip_entries: []const wallpapers.Entry = &.{},
    strip: ?*wallpaper_strip.Strip = null,
    strip_source: ?*wl.EventSource = null,
    /// `wallpaper_children[strip_index]` holds a scroll container to carry over.
    strip_built: bool = false,
    wallpaper_row_children: [2]Widget = undefined,
    wallpaper_footer_children: [2]Widget = undefined,
    theme_row_children: [2]Widget = undefined,
    dark_row_children: [2]Widget = undefined,
    dark_label_children: [2]Widget = undefined,
    splash_row_children: [2]Widget = undefined,
    splash_label_children: [2]Widget = undefined,
    dodge_row_children: [2]Widget = undefined,
    dodge_label_children: [2]Widget = undefined,
    anim_enabled_row_children: [2]Widget = undefined,
    anim_enabled_label_children: [2]Widget = undefined,
    anim_speed_row_children: [2]Widget = undefined,
    reduced_motion_row_children: [2]Widget = undefined,
    font_row_children: [2]Widget = undefined,
    radius_row_children: [2]Widget = undefined,
    shadow_row_children: [2]Widget = undefined,
    opacity_header_children: [2]Widget = undefined,
    opacity_group_children: [2]Widget = undefined,
    opacity_value_buf: [16]u8 = undefined,
    darkness_header_children: [2]Widget = undefined,
    darkness_group_children: [2]Widget = undefined,
    darkness_value_buf: [16]u8 = undefined,
    /// Chrome geometry and tint share one card.
    chrome_group_children: [4]Widget = undefined,
    tabs_children: [3]Widget = undefined,
    tabs_built: bool = false,
    tabs_scroll: @import("ui").layout.ScrollState = .{},
    inactive_opacity_header_children: [2]Widget = undefined,
    inactive_opacity_group_children: [2]Widget = undefined,
    inactive_opacity_value_buf: [16]u8 = undefined,
    px: [13]PxControl = undefined,
    taskbar_section_children: [8]Widget = undefined,
    taskbar_position_children: [2]Widget = undefined,
    items_children: [3]Widget = undefined,
    item_rows: [taskbar_items.count]Widget = undefined,
    item_controls: [taskbar_items.count][3]Widget = undefined,
    item_drag: ?struct { index: usize, press_y: f32, moved: bool = false, items: taskbar_items.Config } = null,
    item_focus: ?taskbar_items.Item = null,
    start_menu_section_children: [5]Widget = undefined,
};

fn indexOfNearest(values: []const f32, v: f32) usize {
    var best: usize = 0;
    var best_d = @abs(values[0] - v);
    for (values, 0..) |candidate, i| {
        const d = @abs(candidate - v);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

fn labelWidget(content: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = content, .font_size = 13, .weight = 600, .color = t.fg } } };
}

fn valueWidget(content: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = content, .font_size = 13, .color = t.dim } } };
}

/// The readout beside a slider, in a rounded label.
fn pillWidget(content: []const u8) Widget {
    return ui_slider.valuePill(content, 13, panel.palette().dim);
}

fn sectionLabel(content: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = content, .font_size = 12, .weight = 700, .color = t.dim } } };
}

/// Builds one "label ... value / slider" pixel-value row and formats its
/// initial value into `out.px[idx].value_buf`.
fn pxGroup(out: *Section, idx: usize, label_text: []const u8, value: f32, min: f32, max: f32, step: f32, on_change: *const fn (?*anyopaque, usize, f32) void) Widget {
    const formatted = std.fmt.bufPrint(&out.px[idx].value_buf, "{d}px", .{@as(i32, @intFromFloat(@round(value)))}) catch "?";
    out.px[idx].header_children = .{ labelWidget(label_text), pillWidget(formatted) };
    const header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.px[idx].header_children };
    const slider: Widget = .{ .kind = .{ .slider = .{ .value = value, .min = min, .max = max, .step = step, .owner = out, .on_change = on_change } } };
    out.px[idx].group_children = .{ header, slider };
    return .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.px[idx].group_children };
}

/// Comptime-specialized `on_change` handler for `Section.px[idx]`, writing
/// straight to `theme.global.<field>`. Each (idx, field) instantiation is a
/// distinct function; the callback owner identifies the section.
/// `taskbar_geometry` picks
/// which of applyThemeChange's two taskbar-refresh paths to use: the
/// fields that resize taskbar items (taskbar_size, chip_width, chip_gap,
/// start_button_gap, start_button_icon_size) need the full relayout since
/// they can change item sizes without changing `bar.box.height`, the only
/// thing the cheap height-guarded refresh notices; the start-menu-popup
/// padding fields don't touch taskbar geometry at all.
fn PxHandler(comptime idx: usize, comptime field: []const u8, comptime taskbar_geometry: bool) type {
    return struct {
        fn changed(owner: ?*anyopaque, _: usize, value: f32) void {
            const s = section(owner);
            @field(theme.global, field) = value;
            const formatted = std.fmt.bufPrint(&s.px[idx].value_buf, "{d}px", .{@as(i32, @intFromFloat(@round(value)))}) catch "?";
            s.px[idx].header_children[1].kind.text.content = formatted;
            s.px[idx].header_children[1].markDirty();
            applyThemeChangeImpl(section(owner), taskbar_geometry);
        }
    };
}

pub fn build(out: *Section, cc: *panel.ControlCenter) void {
    out.item_drag = null;
    out.cc = cc;
    if (out.tabs_built and out.tabs_children[2].kind == .scroll_container) out.tabs_scroll = out.tabs_children[2].kind.scroll_container;
    _ = out.arena.reset(.free_all);
    const t = theme.global;
    const arena = out.arena.allocator();

    out.presets = theme_presets.list(arena, out.cc.server.io, out.cc.server.config.path);
    var preset_labels: [][]const u8 = &.{};
    var matched_index: ?usize = null;
    if (arena.alloc([]const u8, out.presets.len)) |labels| {
        preset_labels = labels;
        for (out.presets, 0..) |preset, i| {
            preset_labels[i] = preset.name;
            if (matched_index != null) continue;
            const parsed = theme.parse(arena, preset.bytes) catch continue;
            if (loader.themeEql(parsed, t)) matched_index = i;
        }
    } else |_| {}
    out.theme_row_children = .{
        labelWidget("Theme"),
        .{
            .name = "theme",
            .kind = .{ .select = .{
                .labels = preset_labels,
                .selected = matched_index,
                .placeholder = "Custom",
                .disabled = preset_labels.len == 0,
                .owner = out,
                .on_change = &onThemePicked,
            } },
            .width = .{ .fixed = segmented_width },
        },
    };

    buildWallpaper(out, arena);

    const pal = panel.palette();
    const dark_mode = out.cc.server.config.compositor.dark_mode;
    out.dark_label_children = .{
        .{ .kind = .{ .text = .{ .content = "Dark mode", .font_size = 13, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = "Apps and web pages", .font_size = 12, .color = pal.dim } } },
    };
    out.dark_row_children = .{
        // Flex like the other rows' text labels: an auto-width column is only
        // as wide as its measured text, which fractional scales ellipsize.
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.dark_label_children },
        .{ .name = "dark_mode", .kind = .{ .toggle = .{ .on = dark_mode, .owner = out, .on_change = &onDarkModeChanged } } },
    };

    const splash_on = out.cc.server.config.compositor.placeholder_delay_ms > 0;
    out.splash_label_children = .{
        .{ .kind = .{ .text = .{ .content = "Show launch splash", .font_size = 13, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = "Brief placeholder while apps start", .font_size = 12, .color = pal.dim } } },
    };
    out.splash_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.splash_label_children },
        .{ .name = "launch_splash", .kind = .{ .toggle = .{ .on = splash_on, .owner = out, .on_change = &onSplashStartupChanged } } },
    };

    const dodge_on = out.cc.server.config.compositor.dodge_file_drags;
    out.dodge_label_children = .{
        .{ .kind = .{ .text = .{ .content = "Move file manager aside", .font_size = 13, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = "While dragging a file out of it", .font_size = 12, .color = pal.dim } } },
    };
    out.dodge_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.dodge_label_children },
        .{ .name = "dodge_file_drags", .kind = .{ .toggle = .{ .on = dodge_on, .owner = out, .on_change = &onDodgeFileDragsChanged } } },
    };

    const anim_enabled = out.cc.server.config.animations.enabled;
    out.anim_enabled_label_children = .{
        .{ .kind = .{ .text = .{ .content = "Animations", .font_size = 13, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = "Window and panel transitions", .font_size = 12, .color = pal.dim } } },
    };
    out.anim_enabled_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.anim_enabled_label_children },
        .{ .name = "animations", .kind = .{ .toggle = .{ .on = anim_enabled, .owner = out, .on_change = &onAnimationsEnabledChanged } } },
    };

    const anim_speed = out.cc.server.config.animations.speed;
    out.anim_speed_row_children = .{
        labelWidget("Animation speed"),
        .{
            .name = "anim_speed",
            .kind = .{ .segmented = .{ .labels = &anim_speed_labels, .selected = indexOfNearest(&anim_speed_values, anim_speed), .owner = out, .on_change = &onAnimSpeedChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };

    const reduced_motion = out.cc.server.config.animations.reduced_motion;
    out.reduced_motion_row_children = .{
        labelWidget("Reduced motion"),
        .{
            .name = "reduced_motion",
            .kind = .{ .segmented = .{ .labels = &reduced_motion_labels, .selected = indexOfReducedMotion(reduced_motion), .owner = out, .on_change = &onReducedMotionChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };

    const focus_zoom = out.cc.server.config.compositor.focus_zoom;
    out.focus_zoom_children = .{
        labelWidget("Window switching zoom"),
        .{ .name = "focus_zoom", .kind = .{ .segmented = .{ .labels = &focus_zoom_labels, .selected = @intFromEnum(focus_zoom), .owner = out, .on_change = &onFocusZoomChanged } }, .width = .{ .percent = 1 } },
        .{ .kind = .{ .text = .{ .content = focus_zoom_descriptions[@intFromEnum(focus_zoom)], .font_size = 12, .color = pal.dim } } },
    };

    if (out.font_families == null) {
        out.font_families = @import("ui").font_fallback.listFamilies(out.font_arena.allocator()) catch null;
    }
    const families = out.font_families orelse &.{};
    var family_index: ?usize = null;
    for (families, 0..) |family, i| {
        if (std.ascii.eqlIgnoreCase(family, t.font)) {
            family_index = i;
            break;
        }
    }
    out.family_row_children = .{
        labelWidget("UI font"),
        .{
            .name = "font",
            .kind = .{ .select = .{
                .labels = families,
                .selected = family_index,
                .placeholder = arena.dupe(u8, t.font) catch "Current font",
                .disabled = families.len == 0,
                .owner = out,
                .on_change = &onFontFamilyChanged,
            } },
            .width = .{ .fixed = segmented_width },
        },
    };
    if (out.cursor_themes == null) {
        out.cursor_themes = cursor_theme.list(out.font_arena.allocator(), out.cc.server.io) catch null;
    }
    const cursor_themes = out.cursor_themes orelse &.{};
    var cursor_labels: [][]const u8 = &.{};
    if (arena.alloc([]const u8, cursor_themes.len)) |labels| {
        for (cursor_themes, labels) |ct, *l| l.* = ct.label;
        cursor_labels = labels;
    } else |_| {}
    const active_cursor = out.cc.server.input.cursorThemeName();
    out.cursor_row_children = .{
        labelWidget("Cursor theme"),
        .{
            .name = "cursor_theme",
            .kind = .{ .select = .{
                .labels = cursor_labels,
                .selected = cursor_theme.indexOf(cursor_themes, active_cursor),
                .placeholder = arena.dupe(u8, active_cursor) catch "Current theme",
                .disabled = cursor_labels.len == 0,
                .owner = out,
                .on_change = &onCursorThemePicked,
            } },
            .width = .{ .fixed = segmented_width },
        },
    };
    out.font_row_children = .{
        labelWidget("Font size"),
        .{
            .name = "font_size",
            .kind = .{ .segmented = .{ .labels = &font_labels, .selected = indexOfNearest(&font_values, t.font_size), .owner = out, .on_change = &onFontSizeChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };
    out.radius_row_children = .{
        labelWidget("Radius"),
        .{
            .name = "radius",
            .kind = .{ .segmented = .{ .labels = &radius_labels, .selected = if (theme.radiusPreset(t)) |preset| @intFromEnum(preset) else radius_labels.len, .owner = out, .on_change = &onRadiusChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };
    out.shadow_row_children = .{
        labelWidget("Shadow"),
        .{
            .name = "shadow",
            .kind = .{ .segmented = .{ .labels = &shadow_labels, .selected = indexOfNearest(&shadow_size_values, t.shadow_size), .owner = out, .on_change = &onShadowChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };

    const opacity_val = std.math.clamp(t.window_bg[3], 0.0, 1.0);
    const opacity_formatted = std.fmt.bufPrint(&out.opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(opacity_val * 100.0)))}) catch "?";
    out.opacity_header_children = .{ labelWidget("Window chrome opacity"), pillWidget(opacity_formatted) };
    const opacity_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.opacity_header_children };
    const opacity_slider: Widget = .{
        .name = "chrome_opacity",
        .kind = .{ .slider = .{
            .value = opacity_val,
            .min = 0.0,
            .max = 1.0,
            .step = 0.01,
            .owner = out,
            .on_change = &onChromeOpacityChanged,
        } },
    };
    out.opacity_group_children = .{ opacity_header, opacity_slider };
    const opacity_row: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.opacity_group_children };

    const darkness_val = theme.chromeDarkness(t.window_bg);
    const darkness_formatted = std.fmt.bufPrint(&out.darkness_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(darkness_val * 100.0)))}) catch "?";
    out.darkness_header_children = .{ labelWidget("Window chrome darkness"), pillWidget(darkness_formatted) };
    const darkness_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.darkness_header_children };
    const darkness_slider: Widget = .{
        .name = "chrome_darkness",
        .kind = .{ .slider = .{
            .value = darkness_val,
            .min = 0.0,
            .max = 1.0,
            .step = 0.01,
            .owner = out,
            .on_change = &onChromeDarknessChanged,
        } },
    };
    out.darkness_group_children = .{ darkness_header, darkness_slider };
    const darkness_row: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.darkness_group_children };
    const chrome_height_row = pxGroup(out, px_chrome_height, "Window chrome height", t.chrome_height, 28, 84, 1, &PxHandler(px_chrome_height, "chrome_height", false).changed);
    out.px[px_chrome_height].group_children[1].name = "chrome_height";
    const chrome_gap_row = pxGroup(out, px_chrome_control_gap, "Window control gap", t.chrome_control_gap, 0, 24, 1, &PxHandler(px_chrome_control_gap, "chrome_control_gap", false).changed);
    out.px[px_chrome_control_gap].group_children[1].name = "chrome_control_gap";
    out.chrome_group_children = .{ chrome_height_row, chrome_gap_row, opacity_row, darkness_row };
    const chrome_row: Widget = .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.chrome_group_children };

    const inactive_val = std.math.clamp(out.cc.server.config.compositor.inactive_opacity, 0.0, 1.0);
    const inactive_formatted = std.fmt.bufPrint(&out.inactive_opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(inactive_val * 100.0)))}) catch "?";
    out.inactive_opacity_header_children = .{ labelWidget("Inactive window opacity"), pillWidget(inactive_formatted) };
    const inactive_opacity_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.inactive_opacity_header_children };
    const inactive_opacity_slider: Widget = .{
        .name = "inactive_opacity",
        .kind = .{ .slider = .{
            .value = inactive_val,
            .min = 0.0,
            .max = 1.0,
            .step = 0.01,
            .owner = out,
            .on_change = &onInactiveOpacityChanged,
        } },
    };
    out.inactive_opacity_group_children = .{ inactive_opacity_header, inactive_opacity_slider };
    const inactive_opacity_row: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.inactive_opacity_group_children };

    const gap_val: f32 = @floatFromInt(@min(out.cc.server.config.compositor.window_gap, max_window_gap));
    const window_gap_row = pxGroup(out, px_window_gap, "Snapped window gap", gap_val, 0, max_window_gap, 1, &onWindowGapChanged);

    out.taskbar_position_children = .{
        labelWidget("Taskbar position"),
        .{ .name = "taskbar_position", .kind = .{ .segmented = .{ .labels = &.{ "Top", "Bottom" }, .selected = @intFromEnum(out.cc.server.config.compositor.taskbar_position), .owner = out, .on_change = &onTaskbarPositionChanged } }, .width = .{ .fixed = segmented_width } },
    };
    const position_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.taskbar_position_children };
    const taskbar_min: f32 = @floatFromInt(Taskbar.min_bar_height);
    const taskbar_row = pxGroup(out, px_taskbar_size, "Taskbar size", std.math.clamp(t.taskbar_size, taskbar_min, 84.0), taskbar_min, 84, 2, &PxHandler(px_taskbar_size, "taskbar_size", true).changed);
    // Also sets each pill's top/bottom margin within the bar (capped) —
    // see Taskbar.chipVerticalMargin — so this one slider spaces chips on
    // every side at once instead of only widening the horizontal gap.
    const chip_width_row = pxGroup(out, px_chip_width, "Window item width", t.chip_width, 64, 400, 4, &PxHandler(px_chip_width, "chip_width", true).changed);
    const chip_gap_row = pxGroup(out, px_chip_gap, "Window item gap", std.math.clamp(t.chip_gap, 0.0, 24.0), 0, 24, 2, &PxHandler(px_chip_gap, "chip_gap", true).changed);
    const start_gap_row = pxGroup(out, px_start_button_gap, "Start button gap", std.math.clamp(t.start_button_gap, 0.0, 40.0), 0, 40, 2, &PxHandler(px_start_button_gap, "start_button_gap", true).changed);
    const start_icon_row = pxGroup(out, px_start_icon_size, "Start button icon size", std.math.clamp(t.start_button_icon_size, 16.0, 42.0), 16, 42, 2, &PxHandler(px_start_icon_size, "start_button_icon_size", true).changed);
    const items = out.cc.server.config.compositor.taskbar_items;
    inline for (0..taskbar_items.count) |i| {
        const item = items.order[i];
        out.item_controls[i] = .{
            .{ .kind = .{ .text = .{ .content = item.label(), .font_size = 13, .weight = 600, .color = pal.fg } }, .width = .{ .flex = 1 } },
            .{ .kind = .{ .button = .{ .label = "Drag to reorder", .icon = .drag_handle, .owner = out, .id = i } }, .width = .{ .fixed = 32 }, .height = .{ .fixed = 30 } },
            .{ .kind = .{ .toggle = .{ .on = items.shown(item), .owner = out, .on_change = &ItemToggle(i).changed } } },
        };
        out.item_rows[i] = .{ .kind = .container, .direction = .row, .gap = 8, .@"align" = .center, .children = &out.item_controls[i] };
    }
    out.items_children = .{
        labelWidget("Right-side items (left to right)"),
        .{ .kind = .{ .text = .{ .content = "Drag to reorder; toggle visibility. Battery appears when available.", .font_size = 12, .color = pal.dim } } },
        .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.item_rows },
    };
    const items_group: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.items_children };
    out.taskbar_section_children = .{ sectionLabel("TASKBAR"), position_row, taskbar_row, chip_width_row, chip_gap_row, start_gap_row, start_icon_row, items_group };
    const taskbar_section: Widget = .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.taskbar_section_children };

    const menu_left_row = pxGroup(out, px_menu_left, "Menu left padding", std.math.clamp(t.start_menu_left_pad, 0.0, 40.0), 0, 40, 2, &PxHandler(px_menu_left, "start_menu_left_pad", false).changed);
    const menu_bottom_row = pxGroup(out, px_menu_bottom, "Menu bottom padding", std.math.clamp(t.start_menu_bottom_pad, 0.0, 40.0), 0, 40, 2, &PxHandler(px_menu_bottom, "start_menu_bottom_pad", false).changed);
    const icon_left_row = pxGroup(out, px_icon_left, "Icon left padding", std.math.clamp(t.start_menu_icon_left_pad, 0.0, 32.0), 0, 32, 2, &PxHandler(px_icon_left, "start_menu_icon_left_pad", false).changed);
    const icon_bottom_row = pxGroup(out, px_icon_bottom, "Icon bottom padding", std.math.clamp(t.start_menu_icon_bottom_pad, 0.0, 24.0), 0, 24, 2, &PxHandler(px_icon_bottom, "start_menu_icon_bottom_pad", false).changed);
    out.start_menu_section_children = .{ sectionLabel("START MENU"), menu_left_row, menu_bottom_row, icon_left_row, icon_bottom_row };
    const start_menu_section: Widget = .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.start_menu_section_children };

    out.row_storage = .{
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.theme_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dark_row_children },
        .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.wallpaper_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.splash_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dodge_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.anim_enabled_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.anim_speed_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.reduced_motion_row_children },
        .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.focus_zoom_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.cursor_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.family_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.font_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.radius_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.shadow_row_children },
        chrome_row,
        buildWindowTabs(out),
        inactive_opacity_row,
        window_gap_row,
        pxGroup(out, px_scrollbar_width, "Scrollbar width", t.scrollbar_width, 4, 24, 1, &PxHandler(px_scrollbar_width, "scrollbar_width", false).changed),
        taskbar_section,
        start_menu_section,
    };
    out.top_children = .{
        .{ .kind = .{ .text = .{ .content = "APPEARANCE", .font_size = 12, .weight = 700, .color = pal.dim } } },
        .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.row_storage },
    };
    out.root = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.top_children };
}

const strip_index = 1;
const tile_w: f32 = wallpaper_strip.thumb_width / 2;
const tile_h: f32 = wallpaper_strip.thumb_height / 2;
const tile_pad: f32 = 3;
const tile_extent = tile_w + 2 * tile_pad;
const strip_gap: f32 = 8;
const check_size: f32 = 18;

/// A folder picked with "Choose folder" this session, gpa-owned.
var chosen_dir: ?[]u8 = null;

/// The folder the strip shows: the chosen one, else where a wallpaper set by
/// path lives. Null means the wallpaper directories' own images.
fn stripFolder(arena: std.mem.Allocator, io: std.Io, configured: []const u8) ?[]const u8 {
    if (chosen_dir) |dir| return dir;
    if (!wallpapers.isPath(configured)) return null;
    const path = wallpapers.resolve(arena, io, configured) catch return null;
    const dir = std.fs.path.dirname(path) orelse return null;
    for ([_]?[]const u8{ wallpapers.userDir(arena) catch null, wallpapers.bundledDir(arena, io) catch null }) |own| {
        if (own) |o| if (std.mem.eql(u8, o, dir)) return null;
    }
    return dir;
}

/// `/home/me/x` as `~/x`.
fn tildePath(arena: std.mem.Allocator, path: []const u8) []const u8 {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    if (home.len > 1 and std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/')
        return std.fmt.allocPrint(arena, "~{s}", .{path[home.len..]}) catch path;
    return path;
}

fn stopStrip(out: *Section) void {
    if (out.strip_source) |source| source.remove();
    out.strip_source = null;
    if (out.strip) |strip| strip.deinit();
    out.strip = null;
}

pub fn deinit(out: *Section) void {
    stopStrip(out);
}

/// Thumbnails arrive one by one; the panel repaints for each.
fn stripWake(_: c_int, _: wl.EventMask, out: *Section) c_int {
    if (out.strip) |strip| strip.drain();
    {
        const server = out.cc.server;
        if (server.input.open_control_center) |cc| cc.refresh();
    }
    return 0;
}

fn restartStrip(out: *Section, server: *@import("../../Server.zig")) void {
    stopStrip(out);
    if (out.strip_entries.len == 0) return;
    const strip = wallpaper_strip.Strip.start(main.gpa, server.io, out.strip_entries) catch |err| {
        std.log.warn("wallpaper strip: {}", .{err});
        return;
    };
    out.strip = strip;
    out.strip_source = server.wl_server.getEventLoop().addFd(*Section, strip.wakeFd(), .{ .readable = true }, stripWake, out) catch |err| {
        std.log.warn("could not register wallpaper strip wake fd: {}", .{err});
        stopStrip(out);
        return;
    };
}

/// A strip of the images to choose from and the folder chooser.
fn buildWallpaper(out: *Section, arena: std.mem.Allocator) void {
    const pal = panel.palette();
    const server = out.cc.server;
    out.wallpapers = wallpapers.list(arena, server.io) catch &.{};
    const configured = server.config.compositor.wallpaper;
    var labels: [][]const u8 = &.{};
    if (arena.alloc([]const u8, out.wallpapers.len)) |l| {
        for (out.wallpapers, l) |entry, *dst| dst.* = entry.label;
        labels = l;
    } else |_| {}
    out.wallpaper_row_children = .{
        labelWidget("Wallpaper"),
        .{
            .name = "wallpaper",
            .kind = .{
                .select = .{
                    .labels = labels,
                    .selected = wallpapers.indexOf(out.wallpapers, configured),
                    // A path outside the wallpaper directories.
                    .placeholder = if (configured.len > 0) std.fs.path.basename(configured) else "RediWM",
                    .disabled = labels.len == 0,
                    .owner = out,
                    .on_change = &onWallpaperPicked,
                },
            },
            .width = .{ .fixed = segmented_width },
        },
    };

    const folder: ?[]const u8 = stripFolder(arena, server.io, configured);
    out.strip_entries = if (folder) |dir| (wallpapers.listDir(arena, server.io, dir) catch &.{}) else out.wallpapers;
    var fresh = false;
    if (out.strip == null or !out.strip.?.matches(out.strip_entries)) {
        restartStrip(out, server);
        fresh = true;
    }
    const resolved = wallpapers.resolve(arena, server.io, configured) catch "";
    var current_tile: ?usize = null;
    for (out.strip_entries, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.path, resolved)) current_tile = i;
    }
    var state: layout.ScrollState = .{};
    if (!fresh and out.strip_built and out.wallpaper_children[strip_index].kind == .scroll_container) {
        const prev = out.wallpaper_children[strip_index].kind.scroll_container;
        state.scroll_offset = prev.scroll_offset;
        state.glide = prev.glide;
        state.bar = prev.bar;
        state.bar_observed = prev.bar_observed;
    } else if (current_tile) |i| {
        // Show the current one, with a couple of its neighbours before it.
        state.scroll_offset = @max(0, (@as(f32, @floatFromInt(i)) - 2) * (tile_extent + strip_gap));
    }
    const bar = scrollbar.gutter(theme.global.scrollbar_width);
    out.wallpaper_children[strip_index] = buildStrip(out, arena, pal, current_tile, state, bar);
    out.strip_built = true;

    const dir = wallpapers.userDir(arena) catch "";
    const hint = if (folder) |f|
        std.fmt.allocPrint(arena, "Images in {s}", .{tildePath(arena, f)}) catch "Images in the chosen folder"
    else
        std.fmt.allocPrint(arena, "Add your own images to {s}", .{tildePath(arena, dir)}) catch "Add your own images";
    out.wallpaper_footer_children = .{
        .{ .kind = .{ .text = .{ .content = hint, .font_size = 12, .color = pal.dim } }, .width = .{ .flex = 1 } },
        .{
            .name = "wallpaper_folder",
            .kind = .{ .button = .{ .label = "Choose folder", .owner = out, .on_click = &onChooseWallpaperFolder, .state = if (folder_picker.running()) .disabled else .idle } },
            .width = .{ .fixed = 124 },
            .height = .{ .fixed = 30 },
        },
    };
    out.wallpaper_children[0] = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.wallpaper_row_children };
    out.wallpaper_children[2] = .{ .kind = .container, .direction = .row, .gap = 8, .@"align" = .center, .children = &out.wallpaper_footer_children };
}

/// One scrolling row: each image with a tick box inside it, ticked for the
/// wallpaper in use. A tile and its box both select it.
fn buildStrip(out: *Section, arena: std.mem.Allocator, pal: theme.Theme, current_tile: ?usize, state: layout.ScrollState, bar: f32) Widget {
    const n = out.strip_entries.len;
    if (n == 0) {
        const note = arena.alloc(Widget, 1) catch return .{ .kind = .container };
        note[0] = .{ .kind = .{ .text = .{ .content = "No images in this folder", .font_size = 12, .color = pal.dim } } };
        return .{ .name = "wallpaper_strip_empty", .kind = .container, .direction = .row, .children = note };
    }
    const tiles = arena.alloc(Widget, n) catch return .{ .kind = .container };
    const images = arena.alloc([1]Widget, n) catch return .{ .kind = .container };
    const checks = arena.alloc([1]Widget, n) catch return .{ .kind = .container };
    const none: [4]f32 = .{ 0, 0, 0, 0 };
    for (0..n) |i| {
        const is_current = current_tile == i;
        const ring: layout.RectStyle = .{ .color = none, .radius = 8, .border_width = 2, .border_color = pal.accent };
        const hover: layout.RectStyle = .{ .color = none, .radius = 8, .border_width = 2, .border_color = pal.border_soft };
        images[i] = .{.{
            .kind = .{ .image = .{
                .pixels = if (out.strip) |strip| strip.thumb(i) else null,
                .width = wallpaper_strip.thumb_width,
                .height = wallpaper_strip.thumb_height,
                .radius = 6,
                .fallback_color = pal.bg,
                .fallback_icon = null,
            } },
            .width = .{ .fixed = tile_w },
            .height = .{ .fixed = tile_h },
            .padding = layout.Edges.all(8),
            .justify = .end,
            .@"align" = .end,
            .children = &checks[i],
        }};
        checks[i] = .{.{
            .name = std.fmt.allocPrint(arena, "wallpaper_check_{d}", .{i}) catch "wallpaper_check",
            .kind = .{ .checkbox = .{ .label = "", .checked = is_current, .owner = out, .on_change = &onStripCheck, .id = i } },
            .width = .{ .fixed = check_size },
            .height = .{ .fixed = check_size },
        }};
        tiles[i] = .{
            .name = std.fmt.allocPrint(arena, "wallpaper_tile_{d}", .{i}) catch "wallpaper_tile",
            .kind = .{ .row = .{
                .background = if (is_current) ring else .{ .color = none },
                .hover_background = if (is_current) ring else hover,
                .press_background = if (is_current) ring else hover,
                .selected = is_current,
                .owner = out,
                .on_click = &onStripTile,
                .id = i,
            } },
            .padding = layout.Edges.all(tile_pad),
            .width = .{ .fixed = tile_extent },
            .height = .{ .fixed = tile_h + 2 * tile_pad },
            .children = &images[i],
        };
    }
    return .{
        .name = "wallpaper_strip",
        .kind = .{ .scroll_container = state },
        .direction = .row,
        .gap = strip_gap,
        .padding = .{ .bottom = bar },
        .width = .{ .percent = 1 },
        .height = .{ .fixed = tile_h + 2 * tile_pad + bar },
        .children = tiles,
    };
}

fn onStripTile(owner: ?*anyopaque, id: usize) void {
    pickStripEntry(section(owner), id);
}

fn onStripCheck(owner: ?*anyopaque, id: usize, _: bool) void {
    pickStripEntry(section(owner), id);
}

fn pickStripEntry(s: *Section, index: usize) void {
    if (index >= s.strip_entries.len) return;
    applyWallpaper(s, s.strip_entries[index]);
    // Moves the tick, and re-ticks a box that was just unticked.
    {
        const server = s.cc.server;
        if (server.input.open_control_center) |cc| cc.refresh();
    }
}

/// Live first, then saved: the config watcher's reload then finds the same
/// wallpaper and loads nothing. The bundled default saves as "", so a moved
/// install keeps finding it.
fn onWallpaperPicked(owner: ?*anyopaque, _: usize, index: usize) void {
    const s = section(owner);
    if (index >= s.wallpapers.len) return;
    applyWallpaper(section(owner), s.wallpapers[index]);
}

fn applyWallpaper(s: *Section, entry: wallpapers.Entry) void {
    const server = s.cc.server;
    const value = if (entry.bundled and std.mem.eql(u8, entry.name, wallpapers.default_name)) "" else entry.name;
    if (std.mem.eql(u8, server.config.compositor.wallpaper, value)) return;
    // Config strings live in its arena, freed with it on the next reload.
    server.config.compositor.wallpaper = server.config.arena.allocator().dupe(u8, value) catch return;
    server.reloadWallpaper();
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "wallpaper", value) catch |err| {
        std.log.warn("could not save wallpaper: {}", .{err});
    };
}

/// Opens Files as a folder chooser, starting in the folder the strip shows
/// (or the user's wallpaper directory, created if needed).
fn onChooseWallpaperFolder(owner: ?*anyopaque, _: usize) void {
    const server = section(owner).cc.server;
    var scratch = std.heap.ArenaAllocator.init(main.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const start = stripFolder(a, server.io, server.config.compositor.wallpaper) orelse blk: {
        const dir = wallpapers.userDir(a) catch break :blk "";
        std.Io.Dir.cwd().createDirPath(server.io, dir) catch |err| {
            std.log.warn("could not create {s}: {}", .{ dir, err });
            break :blk "";
        };
        break :blk dir;
    };
    folder_picker.start(server, "Choose wallpaper folder", start, server, &onFolderChosen) catch |err| {
        std.log.warn("could not open the folder chooser: {}", .{err});
        return;
    };
    // The button reads as busy until the chooser closes.
    if (server.input.open_control_center) |cc| cc.refresh();
}

fn onFolderChosen(owner: ?*anyopaque, path: ?[]const u8) void {
    if (path) |picked| pick: {
        // A folder path is saved as a plain TOML string (setting_save.zig).
        if (std.mem.indexOfAny(u8, picked, "\"\\\n\r") != null) break :pick;
        const copy = main.gpa.dupe(u8, picked) catch break :pick;
        if (chosen_dir) |old| main.gpa.free(old);
        chosen_dir = copy;
    }
    const server: *Server = @ptrCast(@alignCast(owner orelse return));
    if (server.input.open_control_center) |cc| cc.refresh();
}

/// Persists the mutated `theme.global` to REDIWM_THEME (if configured) and
/// re-parses it through the normal load path — the same "log and fall back
/// rather than crash" handling a malformed hand-edit would hit — then
/// refreshes every taskbar (chip accent) and this panel.
fn applyThemeChange(s: *Section) void {
    applyThemeChangeImpl(s, false);
}

/// Shared by every Appearance control. `taskbar_geometry` selects
/// `refreshTaskbarsGeometry` (unconditional relayout) over the plain
/// `refreshTaskbars` (relayouts only when `bar.box.height` itself changed):
/// most fields here (colors, font size, radius, shadow) don't resize taskbar
/// items, so forcing a full taskbar raster on every one of those would waste
/// a repaint pass on each slider tick; see `PxHandler`'s doc comment
/// for which fields need the full path.
fn applyThemeChangeImpl(s: *Section, taskbar_geometry: bool) void {
    const server = s.cc.server;
    if (server.theme_path) |path| {
        theme.save(main.gpa, server.io, path, theme.global);
        theme.loadGlobal(main.gpa, server.io, path);
    } else if (server.config.path.len > 0) {
        @import("config").loader.replaceThemeSection(main.gpa, server.io, server.config.path, theme.global);
    }
    refreshTheme(server, taskbar_geometry);
}

pub fn refreshTheme(server: *@import("../../Server.zig"), taskbar_geometry: bool) void {
    if (server.desktop) |desktop| desktop.app.themeChanged();
    @import("ui").text.setPreferredFamilies(theme.global.font, theme.global.mono_font);
    if (taskbar_geometry) server.refreshTaskbarsGeometry() else server.refreshTaskbars();
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        toplevel.refreshTheme();
        if (toplevel.isMaximized()) {
            if (toplevel.resolveTargetOutput()) |out| toplevel.setMaximizedOn(out);
        }
    }
    if (server.input.open_start_menu) |sm| {
        sm.buildTree();
        sm.relayout();
    }
    if (server.input.open_control_center) |cc| cc.refresh();
}

/// Replaces every `[theme]` field at once from the picked preset. Reads the
/// preset bytes before mutating anything, and parses with `main.gpa` rather
/// than the panel's per-open arena: `theme.global`'s string fields must
/// outlive this build, and `applyThemeChange` below may trigger a repaint
/// that resets the arena.
fn onThemePicked(owner: ?*anyopaque, _: usize, index: usize) void {
    const s = section(owner);
    if (index >= s.presets.len) return;
    const bytes = s.presets[index].bytes;
    const parsed = theme.parse(main.gpa, bytes) catch |err| {
        std.log.warn("theme preset '{s}' failed to parse: {}", .{ s.presets[index].name, err });
        return;
    };
    theme.global = parsed;
    // A preset replaces geometry and every retained taskbar colour too.
    applyThemeChangeImpl(section(owner), true);
    {
        const server = section(owner).cc.server;
        if (server.input.open_control_center) |cc| cc.refresh();
    }
}

fn onFontFamilyChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const s = section(owner);
    const families = s.font_families orelse return;
    if (index >= families.len or std.mem.eql(u8, theme.global.font, families[index])) return;
    // Theme strings outlive the panel, matching theme.parse's ownership.
    theme.global.font = main.gpa.dupe(u8, families[index]) catch return;
    applyThemeChangeImpl(section(owner), true);
    {
        const server = section(owner).cc.server;
        if (server.input.open_control_center) |cc| cc.refresh();
    }
}

fn onFontSizeChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const delta = font_values[index] - theme.global.font_size;
    theme.global.button_font_size = @max(1, theme.global.button_font_size + delta);
    theme.global.title_size = @max(1, theme.global.title_size + delta);
    theme.global.taskbar_title_size = @max(1, theme.global.taskbar_title_size + delta);
    theme.global.font_size = font_values[index];
    applyThemeChange(section(owner));
}

fn onRadiusChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    theme.applyRadiusPreset(&theme.global, @enumFromInt(index));
    applyThemeChange(section(owner));
}

fn onShadowChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    theme.global.shadow_size = shadow_size_values[index];
    theme.global.shadow[3] = shadow_alpha_values[index];
    applyThemeChange(section(owner));
}

fn onChromeOpacityChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const clamped = std.math.clamp(value, 0.0, 1.0);
    theme.global.window_bg[3] = clamped;
    const formatted = std.fmt.bufPrint(&s.opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(clamped * 100.0)))}) catch "?";
    s.opacity_header_children[1].kind.text.content = formatted;
    s.opacity_header_children[1].markDirty();
    applyThemeChange(section(owner));
}

fn onChromeDarknessChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const clamped = std.math.clamp(value, 0.0, 1.0);
    theme.global.window_bg = theme.withChromeDarkness(theme.global.window_bg, clamped);
    const formatted = std.fmt.bufPrint(&s.darkness_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(clamped * 100.0)))}) catch "?";
    s.darkness_header_children[1].kind.text.content = formatted;
    s.darkness_header_children[1].markDirty();
    applyThemeChange(section(owner));
}

fn onInactiveOpacityChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const server = section(owner).cc.server;
    const clamped = std.math.clamp(value, 0.0, 1.0);
    server.config.compositor.inactive_opacity = clamped;
    @import("../../config_runtime/apply.zig").applyInactiveOpacity(server);
    server.scheduleFrames();
    const formatted = std.fmt.bufPrint(&s.inactive_opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(clamped * 100.0)))}) catch "?";
    s.inactive_opacity_header_children[1].kind.text.content = formatted;
    s.inactive_opacity_header_children[1].markDirty();
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "inactive_opacity", clamped) catch |err| {
        std.log.warn("could not save inactive_opacity: {}", .{err});
    };
}

/// Slider range only; the config accepts up to 512.
const max_window_gap = 64;

fn onWindowGapChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const server = section(owner).cc.server;
    const gap: u32 = @intFromFloat(std.math.clamp(@round(value), 0.0, max_window_gap));
    if (gap == server.config.compositor.window_gap) return;
    server.config.compositor.window_gap = gap;
    const formatted = std.fmt.bufPrint(&s.px[px_window_gap].value_buf, "{d}px", .{gap}) catch "?";
    s.px[px_window_gap].header_children[1].kind.text.content = formatted;
    s.px[px_window_gap].header_children[1].markDirty();
    // Windows already snapped follow the new gap.
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        const tile = toplevel.tile orelse continue;
        if (!toplevel.in_world) continue;
        const output = toplevel.currentOutput() orelse continue;
        toplevel.setTiledOn(output, tile);
    }
    server.scheduleFrames();
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "window_gap", gap) catch |err| {
        std.log.warn("could not save window_gap: {}", .{err});
    };
}

fn onTaskbarPositionChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    if (index > 1) return;
    const s = section(owner);
    const server = s.cc.server;
    const position: @TypeOf(server.config.compositor.taskbar_position) = @enumFromInt(index);
    if (position == server.config.compositor.taskbar_position) return;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "taskbar_position", position) catch |err| {
        std.log.warn("could not save taskbar position: {}", .{err});
        s.taskbar_position_children[1].kind.segmented.selected = @intFromEnum(server.config.compositor.taskbar_position);
        s.taskbar_position_children[1].markDirty();
        return;
    };
    server.config.compositor.taskbar_position = position;
    server.applyTaskbarPosition();
}

fn onFocusZoomChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    if (index >= focus_zoom_labels.len) return;
    const s = section(owner);
    const server = section(owner).cc.server;
    const mode: @import("../../camera.zig").FocusZoom = @enumFromInt(index);
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "focus_zoom", mode) catch |err| {
        std.log.warn("could not save focus_zoom: {}", .{err});
        return;
    };
    server.config.compositor.focus_zoom = mode;
    server.world.refreshFocusZoom();
    s.focus_zoom_children[2].kind.text.content = focus_zoom_descriptions[index];
    s.focus_zoom_children[2].markDirty();
}

fn onAnimationsEnabledChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const server = section(owner).cc.server;
    if (server.config.animations.enabled == on) return;
    const old_served = anim.servedEnableAnimations(server.config.animations);
    server.config.animations.enabled = on;
    ipc_animations.reloadSettings(server, server.config.animations);
    const new_served = anim.servedEnableAnimations(server.config.animations);
    if (!std.meta.eql(old_served, new_served)) settings_portal.emitEnableAnimations(server, new_served);
    setting_save.saveAnimations(main.gpa, server.io, server.config.path, "enabled", on) catch |err| {
        std.log.warn("could not save animations enabled: {}", .{err});
    };
}

fn onAnimSpeedChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const server = section(owner).cc.server;
    if (index >= anim_speed_values.len) return;
    const speed = anim_speed_values[index];
    if (server.config.animations.speed == speed) return;
    server.config.animations.speed = speed;
    ipc_animations.reloadSettings(server, server.config.animations);
    setting_save.saveAnimations(main.gpa, server.io, server.config.path, "speed", speed) catch |err| {
        std.log.warn("could not save animations speed: {}", .{err});
    };
}

fn onReducedMotionChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const server = section(owner).cc.server;
    if (index >= reduced_motion_values.len) return;
    const motion = reduced_motion_values[index];
    if (server.config.animations.reduced_motion == motion) return;
    const old_served = anim.servedEnableAnimations(server.config.animations);
    server.config.animations.reduced_motion = motion;
    ipc_animations.reloadSettings(server, server.config.animations);
    const new_served = anim.servedEnableAnimations(server.config.animations);
    if (!std.meta.eql(old_served, new_served)) settings_portal.emitEnableAnimations(server, new_served);
    setting_save.saveAnimations(main.gpa, server.io, server.config.path, "reduced_motion", motion) catch |err| {
        std.log.warn("could not save animations reduced_motion: {}", .{err});
    };
}

/// Live first, then saved; the config reload that follows updates what
/// spawned clients are told (XCURSOR_THEME).
fn onCursorThemePicked(owner: ?*anyopaque, _: usize, index: usize) void {
    const s = section(owner);
    const server = section(owner).cc.server;
    const themes = s.cursor_themes orelse return;
    if (index >= themes.len) return;
    const id = themes[index].id;
    if (std.mem.eql(u8, id, server.input.cursorThemeName())) return;
    server.input.applyCursorTheme(id, server.config.input.cursor_size);
    setting_save.saveInput(main.gpa, server.io, server.config.path, "cursor_theme", id) catch |err| {
        std.log.warn("could not save cursor_theme: {}", .{err});
    };
}

/// Live first, then saved: the config watcher's reload then finds nothing
/// changed and emits no second SettingChanged.
fn onDarkModeChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const server = section(owner).cc.server;
    if (server.config.compositor.dark_mode == on) return;
    server.config.compositor.dark_mode = on;
    settings_portal.emitColorScheme(server);
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dark_mode", on) catch |err| {
        std.log.warn("could not save dark_mode: {}", .{err});
    };
}

/// Enables or disables the launch-placeholder splash. On → 100 ms delay;
/// the splash only becomes visible if the app has not mapped within that
/// window — fast apps never show it. Off → 0 (disabled). Applied live so
/// new launches immediately reflect the change; then persisted to config.toml.
fn onSplashStartupChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const server = section(owner).cc.server;
    const new_val: u32 = if (on) 100 else 0;
    if (server.config.compositor.placeholder_delay_ms == new_val) return;
    server.config.compositor.placeholder_delay_ms = new_val;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "placeholder_delay_ms", new_val) catch |err| {
        std.log.warn("could not save placeholder_delay_ms: {}", .{err});
    };
}

/// Live first, then saved, like the other toggles.
fn onDodgeFileDragsChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const server = section(owner).cc.server;
    if (server.config.compositor.dodge_file_drags == on) return;
    server.config.compositor.dodge_file_drags = on;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dodge_file_drags", on) catch |err| {
        std.log.warn("could not save dodge_file_drags: {}", .{err});
    };
}

fn saveItems(s: *Section, items: taskbar_items.Config) void {
    const server = s.cc.server;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "taskbar_items", items) catch |err| {
        std.log.warn("could not save taskbar items: {}", .{err});
        if (server.input.open_control_center) |cc| cc.refresh();
        return;
    };
    server.config.compositor.taskbar_items = items;
    server.refreshTaskbarsGeometry();
    if (server.input.open_control_center) |cc| cc.refresh();
}

pub fn itemHandle(s: *Section, x: f32, y: f32) ?usize {
    const ui = @import("ui");
    const hit = ui.input.hitTest(&s.cc.root, x, y) orelse return null;
    for (&s.item_controls, 0..) |*controls, i| {
        if (hit == &controls[1]) return i;
    }
    return null;
}

pub fn beginItemDrag(s: *Section, x: f32, y: f32) bool {
    const index = itemHandle(s, x, y) orelse return false;
    // Keep the rows still if the handle was grabbed during a wheel glide.
    const scroll = &s.cc.body_children[1].kind.scroll_container;
    scroll.glide.cancel(scroll.scroll_offset);
    s.item_drag = .{ .index = index, .press_y = y, .items = s.cc.server.config.compositor.taskbar_items };
    @import("ui").input.reset();
    previewItems(s);
    return true;
}

fn previewItems(s: *Section) void {
    const drag = s.item_drag;
    const items = if (drag) |d| d.items else s.cc.server.config.compositor.taskbar_items;
    for (&s.item_controls, items.order, 0..) |*controls, item, i| {
        controls[0].kind.text.content = item.label();
        controls[1].kind.button.state = if (drag != null and drag.?.index == i) .press else .idle;
        controls[1].kind.button.variant = if (drag != null and drag.?.index == i) .primary else .secondary;
        controls[2].kind.toggle.on = items.shown(item);
        for (controls) |*control| control.markDirty();
    }
    s.cc.requestRepaint();
}

pub fn moveItemDrag(s: *Section, y: f32) void {
    const drag = if (s.item_drag) |*d| d else return;
    if (!drag.moved and @abs(y - drag.press_y) < 4) return;
    drag.moved = true;
    var target = drag.index;
    // Cross the neighbouring row's centre before shifting it out of the way.
    while (target + 1 < taskbar_items.count and y > s.item_rows[target + 1].computed_y + s.item_rows[target + 1].computed_height / 2) target += 1;
    while (target > 0 and y < s.item_rows[target - 1].computed_y + s.item_rows[target - 1].computed_height / 2) target -= 1;
    if (target == drag.index) return;
    while (drag.index != target) {
        const down = target > drag.index;
        drag.items.move(drag.index, down);
        if (down) drag.index += 1 else drag.index -= 1;
    }
    previewItems(s);
}

pub fn endItemDrag(s: *Section, commit: bool) void {
    const drag = s.item_drag orelse return;
    s.item_drag = null;
    s.item_focus = drag.items.order[drag.index];
    if (commit and !std.meta.eql(drag.items.order, s.cc.server.config.compositor.taskbar_items.order)) {
        // A config reload during the grab can change visibility independently.
        var items = s.cc.server.config.compositor.taskbar_items;
        items.order = drag.items.order;
        saveItems(s, items);
    }
    previewItems(s);
    if (!s.cc.refresh_pending) restoreItemFocus(s);
}

pub fn restoreItemFocus(s: *Section) void {
    const item = s.item_focus orelse return;
    for (s.cc.server.config.compositor.taskbar_items.order, 0..) |candidate, i| {
        if (item == candidate) @import("ui").input.current.focus(&s.cc.root, &s.item_controls[i][1]);
    }
    s.item_focus = null;
}

pub fn captureItemFocus(s: *Section) void {
    if (s.item_focus != null) return;
    const focused = @import("ui").input.current.focused orelse return;
    for (&s.item_controls) |*controls| {
        if (focused != &controls[1]) continue;
        for (std.enums.values(taskbar_items.Item)) |item| {
            if (std.mem.eql(u8, controls[0].kind.text.content, item.label())) s.item_focus = item;
        }
        return;
    }
}

pub fn itemKey(s: *Section, key: @import("ui").input.Key) bool {
    if (s.item_drag != null) {
        if (key == .escape) endItemDrag(s, false);
        return true;
    }
    if (key != .up and key != .down) return false;
    const focused = @import("ui").input.current.focused orelse return false;
    for (&s.item_controls, 0..) |*controls, i| {
        if (focused != &controls[1]) continue;
        var items = s.cc.server.config.compositor.taskbar_items;
        s.item_focus = items.order[i];
        items.move(i, key == .down);
        saveItems(s, items);
        return true;
    }
    return false;
}

fn ItemToggle(comptime index: usize) type {
    return struct {
        fn changed(owner: ?*anyopaque, _: usize, on: bool) void {
            const server = section(owner).cc.server;
            var items = server.config.compositor.taskbar_items;
            items.visible[@intFromEnum(items.order[index])] = on;
            saveItems(section(owner), items);
        }
    };
}

fn buildWindowTabs(out: *Section) Widget {
    const list = @import("ui").widgets.checkbox_list;
    const tabs = @import("../../window_tabs.zig");
    const a = out.arena.allocator();
    var items: std.ArrayList(list.Item) = .empty;
    {
        const server = out.cc.server;
        server.window_tabs.loadKnown(server);
        for (server.config.compositor.window_tab_apps) |id| _ = server.window_tabs.remember(id);
        const snapshot = server.start_menu_catalog.retainSnapshot();
        defer snapshot.release();
        for (server.window_tabs.known.items, 0..) |id, index| {
            const app = tabs.entry(snapshot.entries, id);
            var icon: @import("ui").layout.ImageData = .{};
            switch (server.iconLookup(id, 32)) {
                .ready => |image| {
                    icon = .{ .pixels = a.dupe(u32, image.pixels) catch null, .width = image.size, .height = image.size };
                },
                else => {},
            }
            items.append(a, .{
                .id = index,
                .name = std.fmt.allocPrint(a, "window_tabs:{s}", .{id}) catch id,
                .label = a.dupe(u8, if (app) |e| e.name else id) catch id,
                .icon = icon,
                .checked = tabs.enabled(server, id),
            }) catch break;
        }
    }
    std.mem.sort(list.Item, items.items, {}, struct {
        fn less(_: void, x: list.Item, y: list.Item) bool {
            return std.ascii.lessThanIgnoreCase(x.label, y.label);
        }
    }.less);
    out.tabs_children = .{
        labelWidget("Enable window tabs for these apps"),
        valueWidget(if (items.items.len == 0) "Open an app with RediWM chrome once to list it here." else "Use + in a window’s title bar to open another window as a tab."),
        list.build(a, items.items, out, onWindowTabsChanged, out.tabs_scroll) catch .{ .kind = .container },
    };
    out.tabs_built = true;
    return .{ .name = "window_tabs", .kind = .container, .direction = .column, .gap = 8, .children = &out.tabs_children };
}

fn onWindowTabsChanged(owner: ?*anyopaque, index: usize, checked: bool) void {
    const server = section(owner).cc.server;
    if (index >= server.window_tabs.known.items.len) return;
    const id = server.window_tabs.known.items[index];
    var arena = std.heap.ArenaAllocator.init(main.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var enabled: std.ArrayList([]const u8) = .empty;
    for (server.config.compositor.window_tab_apps) |app| {
        if (!std.mem.eql(u8, @import("../../window_tabs.zig").identity(app), id)) enabled.append(a, app) catch return;
    }
    if (checked) enabled.append(a, id) catch return;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "window_tab_apps", @as([]const []const u8, enabled.items)) catch |err| {
        std.log.warn("could not save window tabs: {}", .{err});
        return;
    };
    const owned = server.config.arena.allocator().alloc([]const u8, enabled.items.len) catch return;
    for (enabled.items, owned) |app, *dest| dest.* = server.config.arena.allocator().dupe(u8, app) catch return;
    server.config.compositor.window_tab_apps = owned;
    server.window_tabs.reconfigure(server);
}

fn section(owner: ?*anyopaque) *Section {
    return @ptrCast(@alignCast(owner.?));
}
