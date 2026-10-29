//! Apply parsed configuration to the running compositor. Kept outside the config module.
const std = @import("std");
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const loader = @import("config").loader;
const Config = loader.Config;
const InputConfig = loader.InputConfig;
const window_rules = loader.window_rules;
const keybinds = @import("config").keybinds;
const actions = @import("actions.zig");
const libinput = @import("../libinput.zig");
const camera_mod = @import("../camera.zig");
const theme_mod = @import("ui").theme;
const ui_input = @import("ui").input;
const ui_wheel = @import("ui").wheel;
const anim = @import("ui").anim;
const log = std.log.scoped(.config);
const outputsLayoutEql = loader.outputsLayoutEql;
const outputsColorEql = loader.outputsColorEql;
const nightLightEql = loader.nightLightEql;
const inputEql = loader.inputEql;
const themeEql = loader.themeEql;
const wheelAccel = loader.wheelAccel;
pub const applyInactiveOpacity = applyWindowOpacity;
pub fn applyDiff(server: *Server, old: Config, new: Config) void {
    const pack_changed = !std.mem.eql(u8, old.theme_base, new.theme_base) or
        !std.mem.eql(u8, if (old.theme_pack) |p| p.root else "", if (new.theme_pack) |p| p.root else "") or
        !std.mem.eql(u8, if (old.theme_pack) |p| p.bytes else "", if (new.theme_pack) |p| p.bytes else "");
    server.world.workspaces.setMode(server, new.compositor.desktop_mode == .workspaces);
    server.window_tabs.reconfigure(server);
    if (old.compositor.window_gap != new.compositor.window_gap) server.world.workspaces.tiler.schedule(server);
    if (!std.meta.eql(old.region, new.region)) applyRegion(server);
    if (!std.mem.eql(u8, old.compositor.default_file_manager, new.compositor.default_file_manager) or
        !std.mem.eql(u8, old.compositor.default_terminal, new.compositor.default_terminal))
    {
        var output_it = server.outputs.iterator(.forward);
        while (output_it.next()) |output| output.dock.invalidate();
        if (server.input.open_control_center) |cc| cc.refresh();
    }
    if (server.ipc) |ipc| {
        ipc.checkSandboxAllowances();
    }
    if (old.ipc.automation != new.ipc.automation) log.warn("[ipc] automation = {} takes effect after restart", .{new.ipc.automation});
    if (old.polkit.enable != new.polkit.enable or !std.mem.eql(u8, old.polkit.helper_socket, new.polkit.helper_socket)) server.configurePolkit(new.polkit);
    if (!outputsLayoutEql(old.outputs, new.outputs)) {
        var output_it = server.outputs.iterator(.forward);
        while (output_it.next()) |output| output.applyConfig();
        @import("../Output.zig").syncLayout(server);
    }
    // Output enables and `lid_close` both decide whether a closed lid hides the panel.
    @import("../Output.zig").applyLid(server);
    if (server.power) |power| power.syncInhibitors();
    if (!outputsColorEql(old.outputs, new.outputs) or !nightLightEql(old.night_light, new.night_light)) {
        server.night_light.reconfigure(new.night_light);
    }
    @import("ui").shell_icons.configure(server.io, if (new.theme_pack) |p| p.root else "");
    if (pack_changed or !std.mem.eql(u8, old.compositor.icon_theme, new.compositor.icon_theme)) @import("theme_pack.zig").configureIcons(server);
    theme_mod.global = new.theme;
    theme_mod.taskbar_override = if (new.taskbar_theme) |chosen| theme_mod.taskbarTokens(chosen) else null;
    @import("ui").text.setPreferredFamilies(theme_mod.global.font, theme_mod.global.mono_font);
    camera_mod.zoom_levels = new.compositor.zoom_percents;

    // Clamp zoom indices to the new table without creating undo entries.
    {
        server.undo.applying = true;
        defer server.undo.applying = false;
        const max_index = camera_mod.zoom_levels.len - 1;
        if (server.world.camera.zoom_index > max_index) {
            server.world.setZoom(max_index, server.input.cursor.x, server.input.cursor.y);
        }
        var tops = server.world.toplevels.iterator(.forward);
        while (tops.next()) |t| {
            if (t.zoom_index > max_index) {
                t.setZoom(max_index, server.input.cursor.x, server.input.cursor.y);
            }
        }
    }

    if (!inputEql(old.input, new.input)) {
        applyInputConfig(server, new.input);
    }
    if (!@import("config").keymap.namesEqual(old.input, new.input)) {
        if (new.keyboard_keymap) |map| {
            var keyboards = server.input.keyboards.iterator(.forward);
            while (keyboards.next()) |kb| {
                if (server.virtual_input) |vi| if (kb.device == &vi.keyboard.wlr_kbd.base) continue;
                _ = kb.device.toKeyboard().setKeymap(map);
            }
        }
    }

    if (old.compositor.canvas_columns != new.compositor.canvas_columns or
        old.compositor.canvas_rows != new.compositor.canvas_rows)
    {
        @import("../Output.zig").recomputeWorldBounds(server);
        if (server.input.open_control_center) |cc| cc.refresh();
    }

    if (old.compositor.desktop_icons_fixed != new.compositor.desktop_icons_fixed) {
        server.scheduleFrames();
        if (server.input.open_control_center) |cc| cc.refresh();
    }

    if (old.compositor.mini_map_enabled != new.compositor.mini_map_enabled or
        old.compositor.mini_map_position != new.compositor.mini_map_position or
        old.compositor.mini_map_hide_ms != new.compositor.mini_map_hide_ms)
    {
        server.world.mini_map.reconfigure();
        server.scheduleFrames();
        if (server.input.open_control_center) |cc| cc.refresh();
    }
    server.world.workspaces.tiler.schedule(server);
    var any_taskbar_changed = false;
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (!toplevel.rules_resolved) continue;
        const prev_rules = toplevel.live_rules;
        const resolved = window_rules.resolve(new.window_rules, toplevel.currentIdentity());
        toplevel.live_rules = window_rules.LiveRules.fromResolved(resolved);
        toplevel.matched_rules = resolved.matched_rules;
        @import("../auto_tiling.zig").observe(toplevel);

        if (toplevel.live_rules.decorations != prev_rules.decorations) {
            if (toplevel.decoration) |d| d.applyMode();
            if (toplevel.kde_decoration) |d| d.applyMode(false);
            toplevel.syncChrome(true, @import("../Toplevel.zig").nowMs()) catch {};
        }
        if (toplevel.live_rules.skip_taskbar != prev_rules.skip_taskbar) {
            any_taskbar_changed = true;
        }
    }

    if (old.compositor.focus_zoom != new.compositor.focus_zoom) {
        server.world.refreshFocusZoom();
        if (server.input.open_control_center) |cc| cc.refresh();
    }
    applyWindowOpacity(server);
    if (old.compositor.drag_feedback != new.compositor.drag_feedback or
        old.compositor.drag_scale != new.compositor.drag_scale)
    {
        server.scheduleFrames();
        if (server.input.open_control_center) |cc| cc.refresh();
    }
    if (old.compositor.inactive_opacity != new.compositor.inactive_opacity or
        old.compositor.terminal_opacity != new.compositor.terminal_opacity)
    {
        if (server.input.open_control_center) |cc| cc.refresh();
    }
    if (old.compositor.inactive_dim != new.compositor.inactive_dim or
        old.compositor.inactive_dim_amount != new.compositor.inactive_dim_amount)
    {
        // The windows ease to the new dim; a hand edit while settings is open
        // must show in its toggle.
        server.scheduleFrames();
        if (server.input.open_control_center) |cc| cc.refresh();
    }

    if (server.idle) |im| {
        im.applyConfig(new.idle);
    }
    server.syncDesktop();

    if (!std.mem.eql(u8, old.notifications.daemon, new.notifications.daemon)) {
        log.warn("notification daemon selection changed; restart RediWM to apply it", .{});
    }
    if (server.notifications) |n| {
        n.dnd = new.notifications.dnd;
        n.default_timeout_ms = new.notifications.default_timeout_ms;
    }
    if (!std.mem.eql(u8, old.compositor.wallpaper, new.compositor.wallpaper) or pack_changed) server.reloadWallpaper();
    if (old.compositor.dark_mode != new.compositor.dark_mode) {
        @import("../session/settings_portal.zig").emitColorScheme(server);
        // A hand edit while settings is open: rebuild so the toggle agrees.
        if (server.input.open_control_center) |cc| cc.refresh();
    }

    if (!old.animations.eql(new.animations)) {
        const portal = @import("../session/settings_portal.zig");
        const old_served = anim.servedEnableAnimations(old.animations);
        @import("../ipc/animations.zig").reloadSettings(server, new.animations);
        const new_served = anim.servedEnableAnimations(new.animations);
        if (!std.meta.eql(old_served, new_served)) portal.emitEnableAnimations(server, new_served);
        if (server.input.open_control_center) |cc| cc.refresh();
    }

    const theme_changed = pack_changed or !themeEql(old.theme, new.theme) or old.compositor.border_radius != new.compositor.border_radius;
    const taskbar_theme_changed = !theme_mod.taskbarOverrideEql(old.taskbar_theme, new.taskbar_theme);
    if (theme_changed) {
        server.saveLoginTheme();
        if (server.notifications) |manager| manager.themeChanged();
        if (server.desktop) |desktop| desktop.app.themeChanged();
        if (server.locker) |lock| lock.themeChanged();
        server.refreshTaskbarsGeometry();
        var top_it = server.world.toplevels.iterator(.forward);
        while (top_it.next()) |toplevel| {
            toplevel.refreshTheme();
            if (toplevel.isMaximized()) {
                if (toplevel.resolveTargetOutput()) |out| toplevel.setMaximizedOn(out);
            }
        }
        // Widgets capture colors and metrics at construction time.
        if (server.input.open_control_center) |cc| cc.refresh();
        if (server.input.open_start_menu) |sm| {
            sm.buildTree();
            sm.relayout();
        }
    } else if (taskbar_theme_changed) {
        // Only the bar's colours moved; its picker in Appearance follows.
        server.refreshTaskbarsGeometry();
        if (server.input.open_control_center) |cc| cc.refresh();
    } else if (any_taskbar_changed) {
        server.refreshTaskbars();
    }

    if (!std.meta.eql(old.compositor.taskbar_items, new.compositor.taskbar_items) or
        old.compositor.taskbar_alignment != new.compositor.taskbar_alignment)
    {
        if (!theme_changed) server.refreshTaskbarsGeometry();
        if (server.input.open_control_center) |cc| cc.refresh();
    }

    // A docked dock keeps windows out of its strip: refit them as it comes, goes or moves.
    const dock = @import("../Dock.zig");
    const dock_strip_moved = (dock.reserves(&old.compositor) or dock.reserves(&new.compositor)) and
        (old.compositor.dock_enabled != new.compositor.dock_enabled or
            old.compositor.dock_auto_hide != new.compositor.dock_auto_hide or
            old.compositor.dock_position != new.compositor.dock_position or
            old.compositor.dock_height != new.compositor.dock_height);
    if (old.compositor.taskbar_position != new.compositor.taskbar_position or dock_strip_moved) server.applyTaskbarPosition();

    if (old.compositor.dock_enabled != new.compositor.dock_enabled) {
        server.scheduleFrames();
        if (server.input.open_control_center) |cc| cc.refresh();
    }

    if (old.compositor.dock_position != new.compositor.dock_position or
        old.compositor.dock_height != new.compositor.dock_height or
        old.compositor.dock_hover_zoom != new.compositor.dock_hover_zoom or
        old.compositor.dock_auto_hide != new.compositor.dock_auto_hide or
        !std.meta.eql(old.compositor.dock_opacity, new.compositor.dock_opacity) or
        old.compositor.dock_active_highlight != new.compositor.dock_active_highlight or
        old.compositor.dock_show_trash != new.compositor.dock_show_trash or
        !stringListsEql(old.compositor.dock_hidden_shortcuts, new.compositor.dock_hidden_shortcuts) or
        !stringListsEql(old.compositor.dock_pinned_apps, new.compositor.dock_pinned_apps))
    {
        if (server.input.window_menu.dock != null) server.input.window_menu.close();
        var output_it = server.outputs.iterator(.forward);
        while (output_it.next()) |output| output.dock.invalidate();
        // A parked dock schedules no frame of its own.
        if (old.compositor.dock_position != new.compositor.dock_position or old.compositor.dock_auto_hide != new.compositor.dock_auto_hide) server.scheduleFrames();
        if (old.compositor.dock_position != new.compositor.dock_position or old.compositor.dock_height != new.compositor.dock_height or old.compositor.dock_hover_zoom != new.compositor.dock_hover_zoom or old.compositor.dock_auto_hide != new.compositor.dock_auto_hide) {
            if (server.input.open_control_center) |cc| cc.refresh();
        }
    }

    logKeybindDiff(old, new);

    for (new.autostart) |cmd| {
        if (!containsCmd(old.autostart, cmd)) {
            log.info("autostart: spawning new '{s}'", .{cmd});
            actions.spawnAutostartCommand(server, cmd);
        }
    }
}

fn stringListsEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

pub fn applyInputConfig(server: *Server, cfg: InputConfig) void {
    // The UI engine keeps its own copy so `ui/` need not import this file;
    // pushing it here means a hot reload retimes the caret with everything
    // else, without a second change-detection path.
    ui_input.caret_config = .{
        .blink_ms = cfg.caret_blink_ms,
        .blink_timeout_s = cfg.caret_blink_timeout,
        .motion_ms = cfg.caret_motion_ms,
    };
    ui_wheel.accel = wheelAccel(cfg);

    server.input.applyCursorTheme(cfg.cursor_theme, cfg.cursor_size);
    server.input.updateAccel(cfg.accel_profile, cfg.accel_p1, cfg.accel_p2, cfg.accel_max_speed);

    var pit = server.input.pointers.iterator(.forward);
    while (pit.next()) |pointer| applyPointerDevice(pointer.device, cfg);

    var kit = server.input.keyboards.iterator(.forward);
    while (kit.next()) |kb| {
        kb.device.toKeyboard().setRepeatInfo(@intCast(cfg.key_repeat_rate), @intCast(cfg.key_repeat_delay));
    }
}

pub fn applyPointerDevice(device: *wlr.InputDevice, cfg: InputConfig) void {
    if (libinput.isTouchpad(device)) {
        libinput.setPointerSpeed(device, cfg.pointer_speed_touchpad);
        libinput.setDisableWhileTyping(device, cfg.disable_while_typing_touchpad);
    } else {
        libinput.setPointerSpeed(device, cfg.pointer_speed);
        libinput.setDisableWhileTyping(device, cfg.disable_while_typing);
    }
    libinput.setNaturalScroll(device, cfg.natural_scroll);
    libinput.setLeftHanded(device, cfg.left_handed);
    libinput.setTapToClick(device, cfg.tap_to_click);
    libinput.setTapDrag(device, cfg.tap_drag);
}

pub fn applyWindowOpacity(server: *Server) void {
    const now_ms = @import("ui").anim.nowMs();
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |t| t.applyOpacity(now_ms);
}

pub fn applyZoomTable(server: *Server) void {
    camera_mod.zoom_levels = server.config.compositor.zoom_percents;
}

fn containsCmd(list: []const []const u8, cmd: []const u8) bool {
    for (list) |c| if (std.mem.eql(u8, c, cmd)) return true;
    return false;
}

fn logKeybindDiff(old: Config, new: Config) void {
    var buf: [64]u8 = undefined;
    for (new.keybinds) |bind| {
        const key = keybinds.pack(bind.modifiers, bind.sym);
        const prev = old.lookup.get(key);
        if (prev == null) {
            log.debug("keybind added: {s}", .{keybinds.describeAction(bind.action, &buf)});
        }
    }
    for (old.keybinds) |bind| {
        const key = keybinds.pack(bind.modifiers, bind.sym);
        if (new.lookup.get(key) == null) {
            log.debug("keybind removed: {s}", .{keybinds.describeAction(bind.action, &buf)});
        }
    }
}

/// Called by both Settings and config reload; no new clock timers.
pub fn applyRegion(server: *Server) void {
    if (server.greeter_mode) return;
    const locale_tag = @import("i18n").resolve(server.config.region.language, server.environ);
    const language_changed = @import("i18n").setLanguage(locale_tag);
    server.start_menu_catalog.setLocale(locale_tag) catch |err| log.warn("could not update application language: {}", .{err});
    if (server.polkit) |agent| agent.setLocale(locale_tag) catch |err| log.warn("could not update authentication language: {}", .{err});
    @import("region.zig").applyTimezone(@import("../main.zig").gpa, server.config.region.timezone, server.environ.getPosix("TZ")) catch |err| {
        log.warn("could not apply personal timezone: {}", .{err});
    };
    if (server.desktop) |desktop| {
        updateDesktopEnv(server, desktop) catch |err| log.warn("could not update desktop launch environment: {}", .{err});
    }
    var outputs = server.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (output.taskbar) |bar| bar.refreshClockSettings();
        if (output.calendar) |calendar| calendar.refresh();
        if (language_changed) {
            if (output.start_menu) |menu| menu.refreshCatalog();
            if (output.power_menu) |menu| menu.refreshCapabilities();
            if (output.battery_popup) |popup| popup.refresh();
            if (output.wifi_popup) |popup| popup.refresh();
            output.dock.invalidate();
        }
    }
    if (language_changed) {
        var tops = server.world.toplevels.iterator(.forward);
        while (tops.next()) |top| if (top.backend == .shell) {
            top.syncChrome(true, @import("../Toplevel.zig").nowMs()) catch {};
            top.syncForeign();
            if (server.ipc) |ipc| @import("../ipc/events.zig").onWindowChanged(ipc, top);
        };
        server.refreshTaskbars();
    }
    if (server.locker) |lock| lock.themeChanged();
    if (server.input.open_control_center) |cc| cc.refresh();
}

fn updateDesktopEnv(server: *Server, desktop: *@import("../desktop/embedded.zig").Desktop) !void {
    var env = try server.environ.createMap(std.heap.c_allocator);
    errdefer env.deinit();
    try server.applyChildEnv(&env);
    desktop.worker.updateChildEnv(env);
}
