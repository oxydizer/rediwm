//! Appearance callbacks for fonts, chrome, motion, taskbar position and cursor.

const std = @import("std");
const theme = @import("ui").theme;
const main = @import("../../main.zig");
const setting_save = @import("config").setting_save;
const settings_portal = @import("../../session/settings_portal.zig");
const loader = @import("config").loader;
const cursor_theme = @import("../../cursor_theme.zig");
const anim = @import("ui").anim;
const ipc_animations = @import("../../ipc/animations.zig");
const applyThemeChange = @import("appearance_themes.zig").applyThemeChange;
const applyThemeChangeImpl = @import("appearance_themes.zig").applyThemeChangeImpl;
const section = @import("appearance_dock.zig").section;
const font_values = @import("appearance.zig").font_values;
const shadow_size_values = @import("appearance.zig").shadow_size_values;
const shadow_alpha_values = @import("appearance.zig").shadow_alpha_values;
const anim_speed_values = @import("appearance.zig").anim_speed_values;
const reduced_motion_values = @import("appearance.zig").reduced_motion_values;
const focus_zoom_labels = @import("appearance.zig").focus_zoom_labels;
const focus_zoom_descriptions = @import("appearance.zig").focus_zoom_descriptions;
const px_window_gap = @import("appearance.zig").px_window_gap;

pub fn ClockStyle(comptime key: []const u8) type {
    return struct {
        pub fn changed(owner: ?*anyopaque, _: usize, on: bool) void {
            const s = section(owner);
            const server = s.cc.server;
            if (theme.taskbar_override) |*chosen| {
                @field(chosen, key) = on;
                if (server.config.path.len > 0) loader.replaceTaskbarThemeSection(main.gpa, server.io, server.config.path, chosen.*);
                server.refreshTaskbarsGeometry();
                if (server.input.open_control_center) |cc| cc.refresh();
            } else {
                @field(theme.global, key) = on;
                applyThemeChangeImpl(s, true);
            }
        }
    };
}

pub fn onFontFamilyChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const s = section(owner);
    const families = s.font_families orelse return;
    if (index >= families.len or std.mem.eql(u8, theme.global.font, families[index])) return;
    // Theme strings outlive the panel, matching theme.parse's ownership.
    theme.global.font = s.cc.server.config.arena.allocator().dupe(u8, families[index]) catch return;
    applyThemeChangeImpl(section(owner), true);
    {
        const server = section(owner).cc.server;
        if (server.input.open_control_center) |cc| cc.refresh();
    }
}

pub fn onFontSizeChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const delta = font_values[index] - theme.global.font_size;
    theme.global.button_font_size = @max(1, theme.global.button_font_size + delta);
    theme.global.title_size = @max(1, theme.global.title_size + delta);
    theme.global.taskbar_title_size = @max(1, theme.global.taskbar_title_size + delta);
    theme.global.font_size = font_values[index];
    applyThemeChange(section(owner));
}

pub fn onRadiusChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    theme.applyRadiusPreset(&theme.global, @enumFromInt(index));
    applyThemeChange(section(owner));
}

pub fn onShadowChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    theme.global.shadow_size = shadow_size_values[index];
    theme.global.shadow[3] = shadow_alpha_values[index];
    applyThemeChange(section(owner));
}

pub fn onBorderGlowChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    if (theme.global.border_glow_enabled == on) return;
    theme.global.border_glow_enabled = on;
    applyThemeChange(section(owner));
}

pub fn onButtonHoverGlowChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    if (theme.global.button_hover_glow_enabled == on) return;
    theme.global.button_hover_glow_enabled = on;
    applyThemeChange(section(owner));
}

pub fn onChromeOpacityChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const clamped = std.math.clamp(value, 0.0, 1.0);
    theme.global.window_bg[3] = clamped;
    const formatted = std.fmt.bufPrint(&s.opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(clamped * 100.0)))}) catch "?";
    s.opacity_header_children[1].kind.text.content = formatted;
    s.opacity_header_children[1].markDirty();
    applyThemeChange(section(owner));
}

pub fn onChromeDarknessChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const clamped = std.math.clamp(value, 0.0, 1.0);
    theme.global.window_bg = theme.withChromeDarkness(theme.global.window_bg, clamped);
    const formatted = std.fmt.bufPrint(&s.darkness_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(clamped * 100.0)))}) catch "?";
    s.darkness_header_children[1].kind.text.content = formatted;
    s.darkness_header_children[1].markDirty();
    applyThemeChange(section(owner));
}

/// Live first, then saved: the windows ease to the new dim.
pub fn onInactiveDimChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const server = section(owner).cc.server;
    if (server.config.compositor.inactive_dim == on) return;
    server.config.compositor.inactive_dim = on;
    @import("../../config_runtime/apply.zig").applyWindowOpacity(server);
    server.scheduleFrames();
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "inactive_dim", on) catch |err| {
        std.log.warn("could not save inactive_dim: {}", .{err});
    };
}

pub fn onInactiveOpacityChanged(owner: ?*anyopaque, _: usize, value: f32) void {
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

/// Terminals read their alpha at launch, so this only reaches terminals opened
/// afterwards (`config/terminal_theme.zig`); nothing to apply live.
pub fn onTerminalOpacityChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const server = s.cc.server;
    const clamped = std.math.clamp(value, 0.0, 1.0);
    server.config.compositor.terminal_opacity = clamped;
    const formatted = std.fmt.bufPrint(&s.terminal_opacity_value_buf, "{d}%", .{@as(i32, @intFromFloat(@round(clamped * 100.0)))}) catch "?";
    s.terminal_opacity_header_children[1].kind.text.content = formatted;
    s.terminal_opacity_header_children[1].markDirty();
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "terminal_opacity", clamped) catch |err| {
        std.log.warn("could not save terminal_opacity: {}", .{err});
    };
}

/// Slider range only; the config accepts up to 512.
pub const max_window_gap = 64;

pub fn onWindowGapChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const server = section(owner).cc.server;
    const gap: u32 = @intFromFloat(std.math.clamp(@round(value), 0.0, max_window_gap));
    if (gap == server.config.compositor.windowGap()) return;
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
    server.world.workspaces.tiler.schedule(server);
}

pub fn onTaskbarPositionChanged(owner: ?*anyopaque, _: usize, index: usize) void {
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

pub fn onTaskbarAlignmentChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    if (index > 2) return;
    const s = section(owner);
    const server = s.cc.server;
    const alignment: @TypeOf(server.config.compositor.taskbar_alignment) = @enumFromInt(index);
    if (alignment == server.config.compositor.taskbar_alignment) return;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "taskbar_alignment", alignment) catch |err| {
        std.log.warn("could not save taskbar alignment: {}", .{err});
        s.taskbar_alignment_children[1].kind.segmented.selected = @intFromEnum(server.config.compositor.taskbar_alignment);
        s.taskbar_alignment_children[1].markDirty();
        return;
    };
    server.config.compositor.taskbar_alignment = alignment;
    server.refreshTaskbarsGeometry();
}

pub fn onFocusZoomChanged(owner: ?*anyopaque, _: usize, index: usize) void {
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
    s.focus_zoom_children[2].kind.text.content = focus_zoom_descriptions[index].get();
    s.focus_zoom_children[2].markDirty();
}

pub fn onDragFeedbackChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const server = section(owner).cc.server;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "drag_feedback", on) catch |err| {
        std.log.warn("could not save drag_feedback: {}", .{err});
        return;
    };
    server.config.compositor.drag_feedback = on;
    server.scheduleFrames();
}

pub fn onDragScaleChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s = section(owner);
    const server = s.cc.server;
    // The slider's f32 steps drift (1.0299999); keep the saved value to its step.
    const scale = std.math.clamp(@round(value * 1000) / 1000, loader.drag_scale_min, loader.drag_scale_max);
    server.config.compositor.drag_scale = scale;
    server.scheduleFrames();
    s.drag_scale_header_children[1].kind.text.content = std.fmt.bufPrint(&s.drag_scale_value_buf, "{d:.3}×", .{scale}) catch "?";
    s.drag_scale_header_children[1].markDirty();
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "drag_scale", scale) catch |err| {
        std.log.warn("could not save drag_scale: {}", .{err});
    };
}

pub fn onAnimationsEnabledChanged(owner: ?*anyopaque, _: usize, on: bool) void {
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

pub fn onAnimSpeedChanged(owner: ?*anyopaque, _: usize, index: usize) void {
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

pub fn onReducedMotionChanged(owner: ?*anyopaque, _: usize, index: usize) void {
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
pub fn onCursorThemePicked(owner: ?*anyopaque, _: usize, index: usize) void {
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
pub fn onDarkModeChanged(owner: ?*anyopaque, _: usize, on: bool) void {
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
pub fn onSplashStartupChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const server = section(owner).cc.server;
    const new_val: u32 = if (on) 100 else 0;
    if (server.config.compositor.placeholder_delay_ms == new_val) return;
    server.config.compositor.placeholder_delay_ms = new_val;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "placeholder_delay_ms", new_val) catch |err| {
        std.log.warn("could not save placeholder_delay_ms: {}", .{err});
    };
}

/// Live first, then saved, like the other toggles.
pub fn onDodgeFileDragsChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const server = section(owner).cc.server;
    if (server.config.compositor.dodge_file_drags == on) return;
    server.config.compositor.dodge_file_drags = on;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "dodge_file_drags", on) catch |err| {
        std.log.warn("could not save dodge_file_drags: {}", .{err});
    };
}
