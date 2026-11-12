//! Appearance themes: applying and saving, start logo, packs, import and export.

const i18n = @import("i18n");
const std = @import("std");
const Server = @import("../../Server.zig");
const theme = @import("ui").theme;
const theme_presets = @import("config").theme_pack;
const main = @import("../../main.zig");
const setting_save = @import("config").setting_save;
const loader = @import("config").loader;
const folder_picker = @import("../folder_picker.zig");
const section = @import("appearance_dock.zig").section;
const Section = @import("appearance.zig").Section;

/// Persists the mutated `theme.global` to REDIWM_THEME (if configured) and
/// re-parses it through the normal load path — the same "log and fall back
/// rather than crash" handling a malformed hand-edit would hit — then
/// refreshes every taskbar (chip accent) and this panel.
pub fn applyThemeChange(s: *Section) void {
    applyThemeChangeImpl(s, false);
}

/// Shared by every Appearance control. `taskbar_geometry` selects
/// `refreshTaskbarsGeometry` (unconditional relayout) over the plain
/// `refreshTaskbars` (relayouts only when `bar.box.height` itself changed):
/// most fields here (colors, font size, radius, shadow) don't resize taskbar
/// items, so forcing a full taskbar raster on every one of those would waste
/// a repaint pass on each slider tick; see `PxHandler`'s doc comment
/// for which fields need the full path.
pub fn applyThemeChangeImpl(s: *Section, taskbar_geometry: bool) void {
    saveThemeChange(s.cc.server, taskbar_geometry);
}

pub fn saveThemeChange(server: *Server, taskbar_geometry: bool) void {
    if (server.theme_path) |path| {
        theme.saveOverlay(main.gpa, server.io, path, theme.global, server.config.theme_config) catch |err| {
            themeFailure(server, err);
            return;
        };
        const loaded = loader.load(server.config.path, main.gpa, server.io, server.environ) catch |err| {
            themeFailure(server, err);
            return;
        };
        @import("../../config_runtime/watcher.zig").applyLoadedConfig(server, loaded);
    } else if (server.config.path.len > 0) {
        @import("config").loader.replaceThemeOverrides(main.gpa, server.io, server.config.path, theme.global, server.config.theme_defaults, server.config.theme_base);
    }
    refreshTheme(server, taskbar_geometry);
}

pub fn onChooseStartLogo(owner: ?*anyopaque, _: usize) void {
    const s = section(owner);
    const server = s.cc.server;
    s.start_logo_error = null;
    folder_picker.startWithOptions(server, .{
        .title = i18n.tr("Choose Start button logo"),
        .accept_label = i18n.tr("Use logo"),
        .current_folder = std.fs.path.dirname(theme.global.start_button_icon) orelse "",
        .filters = &.{.{ .name = i18n.tr("PNG and SVG images"), .rules = &.{ .{ .kind = 0, .value = "*.png" }, .{ .kind = 0, .value = "*.svg" } } }},
    }, server, &onStartLogoChosen) catch |err| {
        std.log.warn("could not open the logo chooser: {}", .{err});
        s.start_logo_error = i18n.tr("Could not open the file chooser.");
    };
    s.cc.refresh();
}

pub fn onStartLogoChosen(owner: ?*anyopaque, path: ?[]const u8) void {
    // The server outlives the chooser, including when Settings is closed.
    const server: *Server = @ptrCast(@alignCast(owner orelse return));
    if (path) |picked| {
        // Theme strings use a literal, double-quoted TOML dialect.
        if (!std.fs.path.isAbsolute(picked) or std.mem.indexOfAny(u8, picked, "\"\\\n\r\t") != null) {
            if (server.input.open_control_center) |cc| {
                cc.appearance.start_logo_error = i18n.tr("Choose a path without quotes, backslashes or control characters.");
                cc.refresh();
            }
            return;
        }
        theme.global.start_button_icon = server.config.arena.allocator().dupe(u8, picked) catch return;
        saveThemeChange(server, false);
    } else if (server.input.open_control_center) |cc| cc.refresh();
}

/// Hands the menu's size back to the output: 0 is "automatic".
pub fn onAutoMenuSize(owner: ?*anyopaque, _: usize) void {
    const s = section(owner);
    theme.global.start_menu_width = 0;
    theme.global.start_menu_max_height = 0;
    applyThemeChange(s);
}

pub fn onResetStartLogo(owner: ?*anyopaque, _: usize) void {
    const s = section(owner);
    s.start_logo_error = null;
    theme.global.start_button_icon = "";
    applyThemeChange(s);
}

pub fn refreshTheme(server: *@import("../../Server.zig"), taskbar_geometry: bool) void {
    @import("../../config_runtime/app_colors.zig").sync(server);
    server.saveLoginTheme();
    if (server.desktop) |desktop| desktop.themeChanged();
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

/// Explicitly discard personal appearance overrides of the current pack.
pub fn onResetTheme(owner: ?*anyopaque, _: usize) void {
    const server = section(owner).cc.server;
    if (server.config.theme_base.len == 0) {
        theme.global = .{};
        saveThemeChange(server, true);
        return;
    }
    @import("../../config_runtime/theme_pack.zig").reset(server, server.config.theme_base) catch |err| themeFailure(server, err);
}
pub fn themeFailure(server: *Server, err: anyerror) void {
    if (server.input.open_control_center) |cc| {
        cc.appearance.theme_message = i18n.fmt(&cc.appearance.theme_message_buf, i18n.tr("Theme operation failed: {reason}"), .{ .reason = @errorName(err) }) catch i18n.tr("Theme operation failed.");
        cc.refresh();
    }
}
pub fn onInstallTheme(owner: ?*anyopaque, _: usize) void {
    const server = section(owner).cc.server;
    folder_picker.startWithOptions(server, .{ .title = i18n.tr("Install theme"), .accept_label = i18n.tr("Install"), .filters = &.{.{ .name = i18n.tr("Theme packs"), .rules = &.{ .{ .kind = 0, .value = "*.rediwm-theme" }, .{ .kind = 0, .value = "*.zip" } } }} }, server, themeFileChosen) catch |err| themeFailure(server, err);
}
pub fn themeFileChosen(owner: ?*anyopaque, path: ?[]const u8) void {
    const server: *Server = @ptrCast(@alignCast(owner orelse return));
    const picked = path orelse return;
    if (server.input.open_control_center) |cc| {
        if (cc.appearance.theme_pending_path) |old| main.gpa.free(old);
        cc.appearance.theme_pending_path = main.gpa.dupe(u8, picked) catch return;
    }
    @import("../../config_runtime/theme_job.zig").start(server, &.{ "install", picked }, null, null) catch |err| themeFailure(server, err);
}
pub fn onReplaceTheme(owner: ?*anyopaque, _: usize) void {
    const s = section(owner);
    const path = s.theme_pending_path orelse return;
    @import("../../config_runtime/theme_job.zig").start(s.cc.server, &.{ "install", path, "--replace" }, null, null) catch |err| themeFailure(s.cc.server, err);
}
pub fn onRemoveTheme(owner: ?*anyopaque, _: usize) void {
    const s = section(owner);
    const server = s.cc.server;
    const id = main.gpa.dupe(u8, server.config.theme_base) catch return;
    defer main.gpa.free(id);
    var permitted = false;
    for (s.presets) |p| if (std.mem.eql(u8, p.id, id) and p.user_installed) {
        permitted = true;
    };
    if (!permitted) return;
    @import("../../config_runtime/theme_pack.zig").apply(server, "rediwm-dark") catch |err| {
        themeFailure(server, err);
        return;
    };
    @import("../../config_runtime/theme_job.zig").start(server, &.{ "remove", id }, null, null) catch |err| themeFailure(server, err);
}
pub fn onExportTheme(owner: ?*anyopaque, _: usize) void {
    const server = section(owner).cc.server;
    folder_picker.startWithOptions(server, .{ .mode = .save, .title = i18n.tr("Save current look as theme"), .current_name = "my-theme.rediwm-theme", .accept_label = i18n.tr("Save") }, server, exportFileChosen) catch |err| themeFailure(server, err);
}
pub fn exportFileChosen(owner: ?*anyopaque, path: ?[]const u8) void {
    const server: *Server = @ptrCast(@alignCast(owner orelse return));
    const picked = path orelse return;
    const filename = std.fs.path.basename(picked);
    const id = filename[0 .. std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len];
    if (!theme_presets.validId(id)) {
        themeFailure(server, error.InvalidPackId);
        return;
    }
    @import("../../config_runtime/theme_job.zig").start(server, &.{ "share", id, server.config.path, server.wallpaper_source orelse "", theme.global.start_button_icon, picked }, null, null) catch |err| themeFailure(server, err);
}
pub fn onIconThemePicked(owner: ?*anyopaque, _: usize, index: usize) void {
    const s = section(owner);
    const labels = s.icon_theme_names;
    if (index >= labels.len) return;
    setting_save.saveCompositor(main.gpa, s.cc.server.io, s.cc.server.config.path, "icon_theme", labels[index]) catch return;
    @import("../../config_runtime/watcher.zig").reloadConfig(s.cc.server);
}

pub fn onThemePicked(owner: ?*anyopaque, _: usize, index: usize) void {
    const s = section(owner);
    if (index >= s.presets.len) return;
    @import("../../config_runtime/theme_pack.zig").apply(s.cc.server, s.presets[index].id) catch |err| {
        std.log.warn("apply theme pack: {s}", .{@errorName(err)});
    };
}

/// Gives the taskbar the colours and clock style of the picked preset (index 0 hands it back
/// to the main theme). Only the bar changes: `theme.global` keeps whatever the
/// theme row above chose, and so does the saved `[theme]` section.
pub fn onTaskbarThemePicked(owner: ?*anyopaque, _: usize, index: usize) void {
    const s = section(owner);
    const server = s.cc.server;
    if (index == 0) {
        theme.taskbar_override = null;
    } else {
        if (index > s.presets.len) return;
        const preset = s.presets[index - 1];
        // Only the colour tokens are kept, so nothing outlives this arena.
        var scratch: std.heap.ArenaAllocator = .init(main.gpa);
        defer scratch.deinit();
        const parsed = preset.tokens;
        theme.taskbar_override = theme.taskbarTokens(parsed);
    }
    if (server.config.path.len > 0) loader.replaceTaskbarThemeSection(main.gpa, server.io, server.config.path, theme.taskbar_override);
    server.refreshTaskbarsGeometry();
    if (server.input.open_control_center) |cc| cc.refresh();
}
