//! Building the Appearance page's rows: themes and colours, motion and feedback, fonts and cursor, and window chrome.

const i18n = @import("i18n");
const std = @import("std");
const layout = @import("ui").layout;
const theme = @import("ui").theme;
const theme_presets = @import("config").theme_pack;
const Widget = layout.Widget;
const panel = @import("../panel.zig");
const loader = @import("config").loader;
const cursor_theme = @import("../../cursor_theme.zig");
const appearance_colors = @import("appearance_colors.zig");
const appearance_themes = @import("appearance_themes.zig");
const appearance_chrome = @import("appearance_chrome.zig");
const appColorsNote = appearance_colors.appColorsNote;
const onApplyAppColors = appearance_colors.onApplyAppColors;
const onThemePicked = appearance_themes.onThemePicked;
const onTaskbarThemePicked = appearance_themes.onTaskbarThemePicked;
const onFontFamilyChanged = appearance_chrome.onFontFamilyChanged;
const onFontSizeChanged = appearance_chrome.onFontSizeChanged;
const onRadiusChanged = appearance_chrome.onRadiusChanged;
const onShadowChanged = appearance_chrome.onShadowChanged;
const onBorderGlowChanged = appearance_chrome.onBorderGlowChanged;
const onButtonHoverGlowChanged = appearance_chrome.onButtonHoverGlowChanged;
const onChromeOpacityChanged = appearance_chrome.onChromeOpacityChanged;
const onChromeDarknessChanged = appearance_chrome.onChromeDarknessChanged;
const onInactiveDimChanged = appearance_chrome.onInactiveDimChanged;
const onInactiveOpacityChanged = appearance_chrome.onInactiveOpacityChanged;
const onTerminalOpacityChanged = appearance_chrome.onTerminalOpacityChanged;
const onFocusZoomChanged = appearance_chrome.onFocusZoomChanged;
const onDragFeedbackChanged = appearance_chrome.onDragFeedbackChanged;
const onDragScaleChanged = appearance_chrome.onDragScaleChanged;
const onAnimationsEnabledChanged = appearance_chrome.onAnimationsEnabledChanged;
const onAnimSpeedChanged = appearance_chrome.onAnimSpeedChanged;
const onReducedMotionChanged = appearance_chrome.onReducedMotionChanged;
const onCursorThemePicked = appearance_chrome.onCursorThemePicked;
const onDarkModeChanged = appearance_chrome.onDarkModeChanged;
const onSplashStartupChanged = appearance_chrome.onSplashStartupChanged;
const onDodgeFileDragsChanged = appearance_chrome.onDodgeFileDragsChanged;
const EffectToggle = appearance_chrome.EffectToggle;
const appearance = @import("appearance.zig");
const segmented_width = appearance.segmented_width;
const font_values = appearance.font_values;
const font_labels = appearance.font_labels;
const radius_labels = appearance.radius_labels;
const shadow_size_values = appearance.shadow_size_values;
const shadow_labels = appearance.shadow_labels;
const anim_speed_values = appearance.anim_speed_values;
const anim_speed_labels = appearance.anim_speed_labels;
const reduced_motion_labels = appearance.reduced_motion_labels;
const focus_zoom_labels = appearance.focus_zoom_labels;
const focus_zoom_descriptions = appearance.focus_zoom_descriptions;
const indexOfReducedMotion = appearance.indexOfReducedMotion;
const px_chrome_height = appearance.px_chrome_height;
const px_chrome_control_gap = appearance.px_chrome_control_gap;
const Section = appearance.Section;
const indexOfNearest = appearance.indexOfNearest;
const labelWidget = appearance.labelWidget;
const pillWidget = appearance.pillWidget;
const pxGroup = appearance.pxGroup;
const PxHandler = appearance.PxHandler;

/// The theme and taskbar theme pickers; returns the matched preset.
pub fn buildThemeRows(out: *Section, arena: std.mem.Allocator) ?usize {
    out.presets = theme_presets.list(arena, out.cc.server.io, out.cc.server.environ, out.cc.server.config.path) catch &.{};
    var preset_labels: [][]const u8 = &.{};
    var matched_index: ?usize = null;
    if (arena.alloc([]const u8, out.presets.len)) |labels| {
        preset_labels = labels;
        for (out.presets, 0..) |preset, i| {
            preset_labels[i] = preset.name;
            if (std.mem.eql(u8, preset.id, out.cc.server.config.theme_base)) matched_index = i;
        }
    } else |_| {}
    out.theme_row_children = .{
        labelWidget(i18n.tr("Theme")),
        .{
            .name = "theme",
            .kind = .{ .select = .{
                .labels = preset_labels,
                .selected = matched_index,
                .placeholder = i18n.tr("Custom"),
                .disabled = preset_labels.len == 0,
                .owner = out,
                .on_change = &onThemePicked,
            } },
            .width = .{ .fixed = segmented_width },
        },
    };

    // The same presets for the taskbar alone, led by a choice that follows
    // the theme above. Its tokens are compared, not the whole theme.
    var taskbar_labels: [][]const u8 = &.{};
    var taskbar_selected: ?usize = null;
    if (arena.alloc([]const u8, out.presets.len + 1)) |labels| {
        taskbar_labels = labels;
        labels[0] = i18n.tr("Same as theme");
        if (theme.taskbar_override == null) taskbar_selected = 0;
        for (out.presets, 1..) |preset, i| {
            labels[i] = preset.name;
            const chosen = theme.taskbar_override orelse continue;
            if (taskbar_selected != null) continue;
            const parsed = preset.tokens;
            if (theme.taskbarTokensEql(parsed, chosen)) taskbar_selected = i;
        }
    } else |_| {}
    out.taskbar_theme_row_children = .{
        labelWidget(i18n.tr("Taskbar theme")),
        .{
            .name = "taskbar_theme",
            .kind = .{ .select = .{
                .labels = taskbar_labels,
                .selected = taskbar_selected,
                .placeholder = i18n.tr("Custom"),
                .disabled = taskbar_labels.len == 0,
                .owner = out,
                .on_change = &onTaskbarThemePicked,
            } },
            .width = .{ .fixed = segmented_width },
        },
    };
    return matched_index;
}

/// The app colour buttons and the dark mode toggle.
pub fn buildColorRows(out: *Section, arena: std.mem.Allocator, pal: theme.Theme) void {
    out.app_colors_buttons = .{
        .{ .name = "apply_gtk_colors", .kind = .{ .button = .{ .label = i18n.tr("Apply GTK colors"), .owner = out, .id = 0, .on_click = &onApplyAppColors, .state = if (out.app_colors_job != null) .disabled else .idle } }, .width = .{ .flex = 1 }, .height = .{ .fixed = 32 } },
        .{ .name = "apply_qt_colors", .kind = .{ .button = .{ .label = i18n.tr("Apply Qt colors"), .owner = out, .id = 1, .on_click = &onApplyAppColors, .state = if (out.app_colors_job != null) .disabled else .idle } }, .width = .{ .flex = 1 }, .height = .{ .fixed = 32 } },
    };
    out.app_colors_children = .{
        labelWidget(i18n.tr("App colors")),
        .{ .kind = .container, .direction = .row, .gap = 8, .children = &out.app_colors_buttons },
        appColorsNote(out, arena, pal.dim),
    };
    const dark_mode = out.cc.server.config.compositor.dark_mode;
    out.dark_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Dark mode"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Apps and web pages"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.dark_row_children = .{
        // Flex like the other rows' text labels: an auto-width column is only
        // as wide as its measured text, which fractional scales ellipsize.
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.dark_label_children },
        .{ .name = "dark_mode", .kind = .{ .toggle = .{ .on = dark_mode, .owner = out, .on_change = &onDarkModeChanged } } },
    };
}

/// Launch splash, file-drag dodge, inactive dimming, animations, focus zoom and drag feedback.
pub fn buildBehaviorRows(out: *Section, pal: theme.Theme) void {
    const splash_on = out.cc.server.config.compositor.placeholder_delay_ms > 0;
    out.splash_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Show launch splash"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Brief placeholder while apps start"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.splash_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.splash_label_children },
        .{ .name = "launch_splash", .kind = .{ .toggle = .{ .on = splash_on, .owner = out, .on_change = &onSplashStartupChanged } } },
    };

    const dodge_on = out.cc.server.config.compositor.dodge_file_drags;
    out.dodge_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Move file manager aside"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("While dragging a file out of it"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.dodge_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.dodge_label_children },
        .{ .name = "dodge_file_drags", .kind = .{ .toggle = .{ .on = dodge_on, .owner = out, .on_change = &onDodgeFileDragsChanged } } },
    };

    out.dim_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Dim inactive windows"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Slightly darken and mute windows that are not focused"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.dim_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.dim_label_children },
        .{ .name = "inactive_dim", .kind = .{ .toggle = .{ .on = out.cc.server.config.compositor.inactive_dim, .owner = out, .on_change = &onInactiveDimChanged } } },
    };

    const anim_enabled = out.cc.server.config.animations.enabled;
    out.anim_enabled_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Animations"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Window and panel transitions"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.anim_enabled_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.anim_enabled_label_children },
        .{ .name = "animations", .kind = .{ .toggle = .{ .on = anim_enabled, .owner = out, .on_change = &onAnimationsEnabledChanged } } },
    };

    const anim_speed = out.cc.server.config.animations.speed;
    out.anim_speed_row_children = .{
        labelWidget(i18n.tr("Animation speed")),
        .{
            .name = "anim_speed",
            .kind = .{ .segmented = .{ .labels = &anim_speed_labels, .selected = indexOfNearest(&anim_speed_values, anim_speed), .owner = out, .on_change = &onAnimSpeedChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };

    const reduced_motion = out.cc.server.config.animations.reduced_motion;
    out.reduced_motion_row_children = .{
        labelWidget(i18n.tr("Reduced motion")),
        .{
            .name = "reduced_motion",
            .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&reduced_motion_labels), .selected = indexOfReducedMotion(reduced_motion), .owner = out, .on_change = &onReducedMotionChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };

    const focus_zoom = out.cc.server.config.compositor.focus_zoom;
    out.focus_zoom_children = .{
        labelWidget(i18n.tr("Window switching zoom")),
        .{ .name = "focus_zoom", .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&focus_zoom_labels), .selected = @intFromEnum(focus_zoom), .owner = out, .on_change = &onFocusZoomChanged } }, .width = .{ .percent = 1 } },
        .{ .kind = .{ .text = .{ .content = focus_zoom_descriptions[@intFromEnum(focus_zoom)].get(), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };

    out.switcher_style_children = .{
        labelWidget(i18n.tr("Window switcher")),
        .{
            .name = "switcher_style",
            .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&.{ i18n.msg("Linear"), i18n.msg("Circular") }), .selected = @intFromEnum(out.cc.server.config.compositor.switcher_style), .owner = out, .on_change = &appearance_chrome.onSwitcherStyleChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };

    out.drag_feedback_children = .{
        labelWidget(i18n.tr("Drag feedback")),
        .{ .name = "drag_feedback", .kind = .{ .toggle = .{ .on = out.cc.server.config.compositor.drag_feedback, .owner = out, .on_change = &onDragFeedbackChanged } } },
    };
    const drag_scale = out.cc.server.config.compositor.drag_scale;
    const drag_formatted = std.fmt.bufPrint(&out.drag_scale_value_buf, "{d:.3}×", .{drag_scale}) catch "?";
    out.drag_scale_header_children = .{ labelWidget(i18n.tr("Drag lift scale")), pillWidget(drag_formatted) };
    out.drag_scale_children = .{
        .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.drag_scale_header_children },
        .{ .name = "drag_scale", .kind = .{ .slider = .{
            .value = drag_scale,
            .min = loader.drag_scale_min,
            .max = loader.drag_scale_max,
            .step = 0.001,
            .owner = out,
            .on_change = &onDragScaleChanged,
        } } },
    };
}

/// Optional flame effects: three independent toggles, off by default. They
/// only run while Animations are on (and Reduced motion is not).
pub fn buildEffectRows(out: *Section, pal: theme.Theme) void {
    const effects = out.cc.server.config.effects;
    const rows = .{
        .{ "effect_window_move", i18n.msg("Flames while moving windows"), effects.window_move.enabled, &EffectToggle(.window_move).changed },
        .{ "effect_window_resize", i18n.msg("Flames while resizing windows"), effects.resize().enabled, &EffectToggle(.window_resize).changed },
        .{ "effect_window_minimize", i18n.msg("Flames when minimizing windows"), effects.minimize().enabled, &EffectToggle(.window_minimize).changed },
    };
    inline for (rows, 0..) |row, i| {
        out.effect_label_children[i] = .{
            .{ .kind = .{ .text = .{ .content = row[1].get(), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
            .{ .kind = .{ .text = .{ .content = i18n.tr("Needs Animations to be on"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
        };
        out.effect_row_children[i] = .{
            .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.effect_label_children[i] },
            .{ .name = row[0], .kind = .{ .toggle = .{ .on = row[2], .owner = out, .on_change = row[3] } } },
        };
    }
}

/// The UI font, cursor theme, font size, radius, shadow, edge glow and button hover glow rows.
pub fn buildFontRows(out: *Section, arena: std.mem.Allocator, t: theme.Theme, pal: theme.Theme) void {
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
        labelWidget(i18n.tr("UI font")),
        .{
            .name = "font",
            .kind = .{ .select = .{
                .labels = families,
                .selected = family_index,
                .placeholder = arena.dupe(u8, t.font) catch i18n.tr("Current font"),
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
        labelWidget(i18n.tr("Cursor theme")),
        .{
            .name = "cursor_theme",
            .kind = .{ .select = .{
                .labels = cursor_labels,
                .selected = cursor_theme.indexOf(cursor_themes, active_cursor),
                .placeholder = arena.dupe(u8, active_cursor) catch i18n.tr("Current theme"),
                .disabled = cursor_labels.len == 0,
                .owner = out,
                .on_change = &onCursorThemePicked,
            } },
            .width = .{ .fixed = segmented_width },
        },
    };
    out.font_row_children = .{
        labelWidget(i18n.tr("Font size")),
        .{
            .name = "font_size",
            .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&font_labels), .selected = indexOfNearest(&font_values, t.font_size), .owner = out, .on_change = &onFontSizeChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };
    out.radius_row_children = .{
        labelWidget(i18n.tr("Radius")),
        .{
            .name = "radius",
            .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&radius_labels), .selected = if (theme.radiusPreset(t)) |preset| @intFromEnum(preset) else radius_labels.len, .owner = out, .on_change = &onRadiusChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };
    out.shadow_row_children = .{
        labelWidget(i18n.tr("Shadow")),
        .{
            .name = "shadow",
            .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&shadow_labels), .selected = indexOfNearest(&shadow_size_values, t.shadow_size), .owner = out, .on_change = &onShadowChanged } },
            .width = .{ .fixed = segmented_width },
        },
    };

    out.glow_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Edge glow"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Light the active window's edge near the pointer"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.glow_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.glow_label_children },
        .{ .name = "border_glow", .kind = .{ .toggle = .{ .on = t.border_glow_enabled, .owner = out, .on_change = &onBorderGlowChanged } } },
    };

    out.button_hover_glow_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Button hover glow"), .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Light button edges near the pointer"), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    out.button_hover_glow_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.button_hover_glow_label_children },
        .{ .name = "button_hover_glow", .kind = .{ .toggle = .{ .on = t.button_hover_glow_enabled, .owner = out, .on_change = &onButtonHoverGlowChanged } } },
    };
}

/// Window chrome height, control gap, opacity and darkness.
pub fn buildChromeRow(out: *Section, t: theme.Theme) Widget {
    const opacity_val = std.math.clamp(t.window_bg[3], 0.0, 1.0);
    const opacity_formatted = std.fmt.bufPrint(&out.opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(opacity_val * 100.0)))}) catch "?";
    out.opacity_header_children = .{ labelWidget(i18n.tr("Window chrome opacity")), pillWidget(opacity_formatted) };
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
    out.darkness_header_children = .{ labelWidget(i18n.tr("Window chrome darkness")), pillWidget(darkness_formatted) };
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
    const chrome_height_row = pxGroup(out, px_chrome_height, i18n.tr("Window chrome height"), t.chrome_height, 28, 84, 1, &PxHandler(px_chrome_height, "chrome_height", false).changed);
    out.px[px_chrome_height].group_children[1].name = "chrome_height";
    const chrome_gap_row = pxGroup(out, px_chrome_control_gap, i18n.tr("Window control gap"), t.chrome_control_gap, 0, 24, 1, &PxHandler(px_chrome_control_gap, "chrome_control_gap", false).changed);
    out.px[px_chrome_control_gap].group_children[1].name = "chrome_control_gap";
    out.chrome_group_children = .{ chrome_height_row, chrome_gap_row, opacity_row, darkness_row };
    const chrome_row: Widget = .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.chrome_group_children };
    return chrome_row;
}

/// The inactive window opacity slider.
pub fn inactiveOpacityRow(out: *Section) Widget {
    const inactive_val = std.math.clamp(out.cc.server.config.compositor.inactive_opacity, 0.0, 1.0);
    const inactive_formatted = std.fmt.bufPrint(&out.inactive_opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(inactive_val * 100.0)))}) catch "?";
    out.inactive_opacity_header_children = .{ labelWidget(i18n.tr("Inactive window opacity")), pillWidget(inactive_formatted) };
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
    return inactive_opacity_row;
}

/// The terminal opacity slider for new windows.
pub fn terminalOpacityRow(out: *Section) Widget {
    // Unset means a terminal keeps its own alpha; the slider then shows opaque.
    const terminal_val = std.math.clamp(out.cc.server.config.compositor.terminal_opacity orelse 1.0, 0.0, 1.0);
    const terminal_formatted = std.fmt.bufPrint(&out.terminal_opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(terminal_val * 100.0)))}) catch "?";
    out.terminal_opacity_header_children = .{ labelWidget(i18n.tr("Terminal opacity (new windows)")), pillWidget(terminal_formatted) };
    const terminal_opacity_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.terminal_opacity_header_children };
    const terminal_opacity_slider: Widget = .{
        .name = "terminal_opacity",
        .kind = .{ .slider = .{
            .value = terminal_val,
            .min = 0.0,
            .max = 1.0,
            .step = 0.01,
            .owner = out,
            .on_change = &onTerminalOpacityChanged,
        } },
    };
    out.terminal_opacity_group_children = .{ terminal_opacity_header, terminal_opacity_slider };
    const terminal_opacity_row: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.terminal_opacity_group_children };
    return terminal_opacity_row;
}
