// Compositor config: TOML load/save, defaults, and hot-reload apply.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const xkb = @import("xkbcommon");

const theme_mod = @import("ui").theme;
const Theme = theme_mod.Theme;
const ui_wheel = @import("ui").wheel;
const keybinds = @import("keybinds.zig");
const Action = keybinds.Action;
const Keybind = keybinds.Keybind;
const default_file = @import("default.zig");
const types = @import("types.zig");
pub const window_rules = @import("window_rules.zig");
pub const WindowRule = window_rules.WindowRule;
pub const sandbox_allow = @import("sandbox_allow.zig");
pub const SandboxAllowRule = sandbox_allow.SandboxAllowRule;
const anim = @import("ui").anim;
const anim_cfg = @import("animations.zig");
const output_transform = @import("output_transform.zig");
pub const schedule_mod = @import("schedule.zig");
pub const ScheduleMode = schedule_mod.ScheduleMode;
pub const NightLightConfig = schedule_mod.NightLightConfig;
pub const AccelProfile = types.AccelProfile;
pub const PanModifier = types.PanModifier;
pub const AccelCurve = types.AccelCurve;

const log = std.log.scoped(.config);

pub const max_zoom_steps: u8 = 8;
const default_zoom_percents = [_]u8{ 100, 85, 70, 55 };

/// Browsers smooth wheel scrolling themselves (prefixes also cover their
/// installed web apps, e.g. `brave-<id>-Default`).
pub const default_smooth_scroll_exclude = [_][]const u8{
    "brave",   "chromium",  "google-chrome", "microsoft-edge", "vivaldi", "opera",
    "firefox", "librewolf", "floorp",        "zen",
};

pub const InputConfig = struct {
    xkb_layout: []const u8 = "",
    xkb_variant: []const u8 = "",
    xkb_options: []const u8 = "",
    xkb_model: []const u8 = "",
    natural_scroll: bool = true,
    // Compositor-side flip applied to every scroll axis event regardless of
    // device/backend support, unlike `natural_scroll` which only takes
    // effect when libinput's per-device natural-scroll toggle is available
    // (many plain mice report it unsupported). See `Input.processAxis`.
    invert_scroll: bool = true,
    pointer_speed: f32 = -0.3,
    pointer_speed_touchpad: f32 = -0.3,
    accel_profile: AccelProfile = .bezier,
    accel_p1: [2]f32 = .{ 0.0, 0.0 },
    accel_p2: [2]f32 = .{ 0.15, 1.0 },
    accel_max_speed: f32 = 10.0,
    // Multiplies camera-pan distance for modifier-drag and middle-drag panning;
    // 1.0 keeps the canvas glued 1:1 under the cursor (see Input.startPan).
    pan_speed: f32 = 2.0,
    // Modifiers that, held while the pointer moves, pan the canvas
    // (`Input.isPanModifierHeld`). Super+Alt+wheel zooms the whole desktop
    // whichever is chosen.
    pan_modifier: PanModifier = .super_alt,
    // Middle-mouse-button drag pans the canvas when true. Modifier-drag panning
    // is unaffected; disabling this only stops the middle button itself from
    // starting a pan, so it goes back to acting as an ordinary client button
    // (e.g. middle-click paste). See Input.processButton.
    middle_button_pan: bool = true,
    // Mouse-wheel acceleration, in shell panels and apps alike: fast runs of
    // notches move further per notch. 0 disables; see `ui/wheel.zig`.
    wheel_acceleration: f32 = 1.0,
    wheel_acceleration_max: f32 = 5.0,
    // App ids (prefix match) whose wheel notches are forwarded unscaled.
    wheel_acceleration_exclude: []const []const u8 = &.{},
    // Glide each wheel notch into apps as a run of small high-resolution
    // steps (`input/client_wheel.zig`). Apps that already smooth their own
    // wheel scrolling are excluded, so it is not smoothed twice.
    smooth_scroll: bool = false,
    smooth_scroll_exclude: []const []const u8 = &default_smooth_scroll_exclude,
    tap_to_click: bool = true,
    tap_drag: bool = true,
    disable_while_typing: bool = true,
    disable_while_typing_touchpad: bool = true,
    key_repeat_delay: u32 = 400,
    key_repeat_rate: u32 = 25,
    cursor_theme: []const u8 = "default",
    cursor_size: u32 = 32,
    /// Text-caret behaviour, beside the other typing settings. Appearance
    /// (`caret`, `caret_width`) is in `[theme]`. Applied through
    /// `ui.input.caret_config`; see its doc comment for the semantics of 0.
    caret_blink_ms: u32 = 1060,
    caret_blink_timeout: u32 = 10,
    caret_motion_ms: u32 = 80,
};

/// Personal shell clock/calendar preferences; system locale stays inherited.
pub const RegionConfig = struct {
    clock_24h: bool = false,
    first_day_of_week: enum { sunday, monday, tuesday, wednesday, thursday, friday, saturday } = .sunday,

    pub fn timeFormat(self: RegionConfig) [:0]const u8 {
        return if (self.clock_24h) "%H:%M" else "%l:%M %p";
    }
};

pub const TaskbarItems = @import("taskbar_items.zig").Config;

pub const CompositorConfig = struct {
    default_file_manager: []const u8 = "",
    default_terminal: []const u8 = "",
    taskbar_items: TaskbarItems = .{},
    taskbar_position: enum { top, bottom } = .bottom,
    /// App identities opted into compositor tabs. Only + launches join a group.
    window_tab_apps: []const []const u8 = &.{},
    focus_follows_mouse: bool = false,
    // Legacy pixel settings remain parseable; canvas dimensions now use screens.
    canvas_columns: u32 = 3,
    canvas_rows: u32 = 3,
    // Super+arrow desktop slide; see `anim.desktopSwitchCurve`.
    desktop_switch_ms: u32 = anim.default_desktop_switch_ms,
    desktop_icons_fixed: bool = true,
    mini_map_enabled: bool = true,
    mini_map_position: types.MiniMapPosition = .bottom_right,
    mini_map_hide_ms: u32 = 1500,
    canvas_width: u32 = 7680,
    canvas_height: u32 = 4320,
    zoom_steps: [max_zoom_steps]f32 = .{ 1.0, 0.85, 0.70, 0.55, 0, 0, 0, 0 },
    zoom_step_count: u8 = 4,
    zoom_percents: []const u8 = &default_zoom_percents,
    camera_zoom_min: f32 = 0.25,
    camera_zoom_max: f32 = 1.0,
    /// How explicit window switching brings a small window into focus.
    focus_zoom: types.FocusZoom = .boost,
    /// Space around and between half/quarter tiles (snap.tileRect).
    window_gap: u32 = 0,
    /// Dragging a window to an open screen edge tiles or maximizes it.
    snap_to_edges: bool = true,
    /// A file manager slides aside while a file is dragged out of it; see
    /// `input/drag_dodge.zig`.
    dodge_file_drags: bool = true,
    inactive_opacity: f32 = 1.0,
    switcher_opacity: f32 = 1.0,
    border_radius: u32 = 10,
    allow_tearing: bool = false,
    xwayland: bool = true,
    xwayland_native_scaling: bool = false,
    /// 0 follows the native-scaling policy; explicit factors require restart.
    xwayland_scale: f64 = 0,
    /// Colour scheme apps are told to prefer through the Settings portal
    /// (`session/settings_portal.zig`): dark when true, light when false.
    dark_mode: bool = false,
    /// Delay before showing a placeholder frame for an unmapped launch (ms).
    /// 0 disables the placeholder frame.
    placeholder_delay_ms: u32 = 0,
    /// Empty for RediWM's own, a file name in the wallpaper directories, or a
    /// path; see `wallpapers.zig`.
    wallpaper: []const u8 = "",
    sound_theme: []const u8 = "freedesktop",
    sound_enabled: bool = true,
    sound_disabled_events: []const []const u8 = &.{},
    /// What closing the laptop lid does; see `input/lid.zig`.
    lid_close: LidAction = .display_off,
    /// Lock before the system sleeps, however sleep was requested; logind
    /// waits until the lock is on screen (`session/power.zig`).
    lock_on_suspend: bool = true,
};

pub const LidAction = types.LidAction;

/// Per-output overrides matched against wlr_output.name. Omitted coordinates
/// retain automatic placement; scale-only entries do not pin an origin.
pub const OutputConfig = struct {
    width: ?i32 = null,
    height: ?i32 = null,
    refresh_mhz: ?i32 = null,
    name: []const u8 = "",
    x: ?i32 = null,
    y: ?i32 = null,
    /// null selects automatic density detection.
    scale: ?f32 = null,
    /// Keep the connector in the saved layout without enabling it.
    enabled: bool = true,
    /// Preferred fallback output for placement and desktop ownership.
    primary: bool = false,
    transform: output_transform.Transform = .normal,
    night_light: bool = true,
    gamma: f32 = 1.0,
};

pub const PolkitConfig = struct {
    enable: bool = true,
    helper_socket: []const u8 = "/run/polkit/agent-helper.socket",
};

pub const IdleConfig = struct {
    enabled: ?bool = null,
    blank_after_seconds: u32 = 600,
    suspend_after_seconds: u32 = 0,
};

pub const NotificationsConfig = struct {
    daemon: []const u8 = "", // Empty selects the built-in daemon; changes require restart.
    dnd: bool = false,
    default_timeout_ms: u32 = 5000,
};

pub const DesktopConfig = struct {
    /// Desktop icons and wallpaper drawn by the compositor. Unset follows
    /// `desktopEnabled`: configs from before this section enabled the
    /// desktop by autostarting the retired rediwm-desktop client.
    enabled: ?bool = null,
};

pub const IpcConfig = struct {
    /// Synthetic input, pixel reads, buffer dumps and screenshots over the IPC
    /// socket. Off by default so ordinary clients get Wayland's usual
    /// isolation; test setups turn it on. Read once at startup.
    automation: bool = false,
};

/// Whether the compositor draws the desktop. An empty config draws none, as
/// before: the old client only ran from the default template's autostart.
pub fn desktopEnabled(cfg: *const Config) bool {
    if (cfg.desktop.enabled) |enabled| return enabled;
    for (cfg.autostart) |cmd| if (isDesktopClient(cmd)) return true;
    return false;
}

/// An autostart command for the retired rediwm-desktop client.
pub fn isDesktopClient(cmd: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, cmd, " \t");
    const program = words.next() orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(program), "rediwm-desktop");
}

pub const NotificationRule = struct {
    app_name: ?[]const []const u8 = null,
    desktop_entry: ?[]const []const u8 = null,
    mute: ?bool = null,
    urgency: ?u8 = null,
    dnd_bypass: ?bool = null,
};

pub const Config = struct {
    theme: Theme = .{},
    input: InputConfig = .{},
    input_method: struct { env: types.InputMethod = .none } = .{},
    keyboard_keymap: ?*xkb.Keymap = null,
    compositor: CompositorConfig = .{},
    region: RegionConfig = .{},
    polkit: PolkitConfig = .{},
    idle: IdleConfig = .{},
    night_light: NightLightConfig = .{},
    notifications: NotificationsConfig = .{},
    desktop: DesktopConfig = .{},
    ipc: IpcConfig = .{},
    outputs: []OutputConfig = &.{},
    keybinds: []Keybind = &.{},
    lookup: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    autostart: [][]const u8 = &.{},
    window_rules: []WindowRule = &.{},
    notification_rules: []NotificationRule = &.{},
    sandbox_allow: []SandboxAllowRule = &.{},
    animations: anim.Settings = .{},
    path: []const u8 = "",
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        if (self.keyboard_keymap) |map| map.unref();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn lookupKeybind(self: *const Config, mods: anytype, sym: xkb.Keysym) ?Action {
        return keybinds.lookupKey(self.keybinds, self.lookup, mods, sym);
    }

    pub fn sandboxAllowGroups(self: *const Config, app_id: ?[]const u8, engine: ?[]const u8) sandbox_allow.GroupSet {
        if (app_id == null) return sandbox_allow.GroupSet.initEmpty();
        var set = sandbox_allow.GroupSet.initEmpty();
        for (self.sandbox_allow) |rule| {
            if (rule.app_id.len > 0 and std.mem.eql(u8, rule.app_id, app_id.?)) {
                if (rule.engine == null or engine == null or std.mem.eql(u8, rule.engine.?, engine.?)) {
                    set.setUnion(rule.allow);
                }
            }
        }
        return set;
    }
};

pub fn default(allocator: Allocator) !Config {
    var cfg = try initEmpty(allocator);
    errdefer cfg.deinit();
    cfg.keyboard_keymap = try @import("keymap.zig").compile(allocator, cfg.input);
    try applyDefaultKeybinds(&cfg);
    return cfg;
}

pub const resolvePath = @import("path.zig").resolvePath;

/// Rewrites the `[theme]` section of `path` in place, preserving every other
/// section and any leading comments. Used by the control center so appearance
/// edits don't clobber keybinds/input.
pub fn replaceThemeSection(allocator: Allocator, io: Io, path: []const u8, t: Theme) void {
    const existing = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        theme_mod.writeInto(allocator, &buf, t) catch return;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch return;
        return;
    };
    defer allocator.free(existing);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var in_theme = false;
    var replaced = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            const is_theme = std.mem.startsWith(u8, trimmed, "[theme]");
            if (in_theme) {
                in_theme = false;
            }
            if (is_theme) {
                if (!replaced) {
                    theme_mod.writeInto(allocator, &out, t) catch return;
                    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
                        out.append(allocator, '\n') catch return;
                    }
                    replaced = true;
                }
                in_theme = true;
                continue;
            }
        }
        if (in_theme) continue;
        out.appendSlice(allocator, raw) catch return;
        out.append(allocator, '\n') catch return;
    }
    if (!replaced) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') out.append(allocator, '\n') catch return;
        theme_mod.writeInto(allocator, &out, t) catch return;
    }
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch |err| {
        log.warn("replaceThemeSection '{s}': {}", .{ path, err });
    };
}

pub fn generateDefault(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try Io.Dir.cwd().createDirPath(io, dir);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = default_file.source });
}

pub fn loadDefault(allocator: Allocator, io: Io, environ: std.process.Environ) !Config {
    const path = resolvePath(environ, allocator) catch |err| {
        log.warn("config path: {}, using built-in defaults", .{err});
        return default(allocator);
    };
    defer allocator.free(path);

    if (!fileExists(io, path)) {
        generateDefault(io, path) catch |err| {
            log.warn("could not write default config '{s}': {}", .{ path, err });
            return loadFromBytes(allocator, "", path, environ, io);
        };
        log.info("Generated default config at {s}", .{path});
    }

    return load(path, allocator, io, environ);
}

pub fn load(path: []const u8, allocator: Allocator, io: Io, environ: std.process.Environ) !Config {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| {
        log.warn("failed to read '{s}': {}", .{ path, err });
        return err;
    };
    defer allocator.free(bytes);
    return loadFromBytes(allocator, bytes, path, environ, io);
}

pub fn loadFromBytes(
    allocator: Allocator,
    bytes: []const u8,
    path: []const u8,
    environ: std.process.Environ,
    io: Io,
) !Config {
    var cfg = parse(allocator, bytes, path) catch |err| {
        log.warn("config '{s}': parse failed ({s}), keeping caller fallback", .{ path, @errorName(err) });
        return err;
    };
    errdefer cfg.deinit();

    if (theme_mod.resolvePath(environ)) |theme_path| {
        overlayThemeFile(cfg.arena.allocator(), io, &cfg.theme, theme_path) catch |err| {
            log.warn("REDIWM_THEME overlay '{s}': {}", .{ theme_path, err });
        };
    }
    finishCompositor(&cfg);
    return cfg;
}

pub fn parse(allocator: Allocator, bytes: []const u8, path: []const u8) !Config {
    var cfg = try initEmpty(allocator);
    errdefer cfg.deinit();
    cfg.path = try cfg.arena.allocator().dupe(u8, path);

    var seen_keybinds = false;
    var seen_frame_radius = false;
    var autostart_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var bind_list: std.ArrayListUnmanaged(Keybind) = .empty;
    var outputs_list: std.ArrayListUnmanaged(OutputConfig) = .empty;
    var current_output: OutputConfig = .{};
    var have_current_output = false;
    var rule_list: std.ArrayListUnmanaged(WindowRule) = .empty;
    var current_rule: WindowRule = .{};
    var have_current_rule = false;
    var notif_rule_list: std.ArrayListUnmanaged(NotificationRule) = .empty;
    var current_notif_rule: NotificationRule = .{};
    var have_current_notif_rule = false;
    var sandbox_allow_list: std.ArrayListUnmanaged(SandboxAllowRule) = .empty;
    var current_sandbox_allow: SandboxAllowRule = .{};
    var have_current_sandbox_allow = false;
    var section: Section = .none;
    var target_flags: [anim.Target.count]anim_cfg.TargetFlags = [_]anim_cfg.TargetFlags{.{}} ** anim.Target.count;
    var line_no: usize = 0;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = theme_mod.stripComment(std.mem.trim(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;

        if (line[0] == '[') {
            try flushArrayTables(&cfg, path, line_no, section, &outputs_list, &current_output, &have_current_output, &rule_list, &current_rule, &have_current_rule, &notif_rule_list, &current_notif_rule, &have_current_notif_rule, &sandbox_allow_list, &current_sandbox_allow, &have_current_sandbox_allow);
            section = parseSection(line) catch |err| {
                if (err == error.UnknownAnimationTarget) {
                    const close = std.mem.indexOfScalar(u8, line, ']') orelse line.len;
                    const name = if (line.len > 1 and close > 1) line[1..close] else line;
                    const target = if (std.mem.startsWith(u8, name, "animations.")) name["animations.".len..] else name;
                    fail(path, line_no, "unknown animation target '{s}'", .{target});
                } else {
                    fail(path, line_no, "invalid section header", .{});
                }
                return error.InvalidConfig;
            };
            if (section == .keybinds) seen_keybinds = true;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            fail(path, line_no, "expected key = value", .{});
            return error.InvalidConfig;
        };
        const key = unquoteKey(std.mem.trim(u8, line[0..eq], " \t"));
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        switch (section) {
            .none => {},
            .theme => {
                theme_mod.applyKey(cfg.arena.allocator(), &cfg.theme, key, value) catch |err| {
                    fail(path, line_no, "invalid theme field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
                if (std.mem.eql(u8, key, "radius_lg")) seen_frame_radius = true;
            },
            .input_method => {
                if (!std.mem.eql(u8, key, "env")) return error.InvalidConfig;
                const text = theme_mod.unquote(value) catch return error.InvalidConfig;
                cfg.input_method.env = std.meta.stringToEnum(types.InputMethod, text) orelse return error.InvalidConfig;
            },
            .input => applyInputKey(&cfg.input, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid input field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .compositor => applyCompositorKey(&cfg.compositor, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid compositor field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .region => {
                const known = applyField(&cfg.region, cfg.arena.allocator(), region_rules, key, value) catch return error.InvalidConfig;
                if (!known) return error.InvalidConfig;
            },
            .autostart => {
                if (std.mem.eql(u8, key, "cmd")) {
                    const cmd = parseString(cfg.arena.allocator(), value) catch {
                        fail(path, line_no, "autostart cmd must be a quoted string", .{});
                        return error.InvalidConfig;
                    };
                    autostart_list.append(cfg.arena.allocator(), cmd) catch {
                        return error.OutOfMemory;
                    };
                }
            },
            .outputs => {
                have_current_output = true;
                const known = applyField(&current_output, cfg.arena.allocator(), output_rules, key, value) catch {
                    fail(path, line_no, "outputs {s} must be {s}", .{ key, fieldHint(OutputConfig, output_rules, key) });
                    return error.InvalidConfig;
                };
                if (!known) {
                    fail(path, line_no, "unknown outputs field '{s}'", .{key});
                    return error.InvalidConfig;
                }
            },
            .window_rules => {
                have_current_rule = true;
                window_rules.applyRuleKey(&current_rule, cfg.arena.allocator(), key, value) catch |err| {
                    fail(path, line_no, "invalid window_rules field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
            .sandbox_allow => {
                have_current_sandbox_allow = true;
                sandbox_allow.applyKey(&current_sandbox_allow, cfg.arena.allocator(), key, value, path, line_no) catch |err| {
                    fail(path, line_no, "invalid sandbox_allow field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
            .polkit => applyPolkitKey(&cfg.polkit, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid polkit field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .idle => applyIdleKey(&cfg.idle, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid idle field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .desktop => applyDesktopKey(&cfg.desktop, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid desktop field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .ipc => applyIpcKey(&cfg.ipc, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid ipc field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .night_light => applyNightLightKey(&cfg.night_light, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid night_light field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .keybinds => {
                const spec = keybinds.parseKeybind(key) catch {
                    fail(path, line_no, "invalid keybind '{s}'", .{key});
                    return error.InvalidConfig;
                };
                const action_str = theme_mod.unquote(value) catch {
                    fail(path, line_no, "keybind action must be a quoted string", .{});
                    return error.InvalidConfig;
                };
                const action = keybinds.parseAction(action_str, cfg.arena.allocator()) catch {
                    fail(path, line_no, "invalid action '{s}'", .{action_str});
                    return error.InvalidConfig;
                };
                bind_list.append(cfg.arena.allocator(), .{
                    .modifiers = spec.modifiers,
                    .sym = spec.sym,
                    .action = action,
                }) catch return error.OutOfMemory;
            },
            .notifications => applyNotificationsKey(&cfg.notifications, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid notifications field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .notification_rules => {
                have_current_notif_rule = true;
                applyNotificationRuleKey(&current_notif_rule, cfg.arena.allocator(), key, value) catch |err| {
                    fail(path, line_no, "invalid notification_rules field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
            .animations => anim_cfg.applyGlobalKey(&cfg.animations, key, value) catch |err| {
                fail(path, line_no, "invalid animations field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .animation_target => |target| {
                anim_cfg.applyTargetKey(&cfg.animations, target, &target_flags[@intFromEnum(target)], key, value) catch |err| {
                    fail(path, line_no, "invalid animations.{s} field '{s}': {s}", .{ @tagName(target), key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
        }
    }

    // Legacy frame geometry is a fallback; theme numbers take precedence,
    // including a REDIWM_THEME overlay applied after this parse.
    if (!seen_frame_radius) cfg.theme.radius_lg = @floatFromInt(cfg.compositor.border_radius);

    try flushArrayTables(&cfg, path, line_no, section, &outputs_list, &current_output, &have_current_output, &rule_list, &current_rule, &have_current_rule, &notif_rule_list, &current_notif_rule, &have_current_notif_rule, &sandbox_allow_list, &current_sandbox_allow, &have_current_sandbox_allow);

    if (cfg.idle.blank_after_seconds > 0 and cfg.idle.suspend_after_seconds > 0 and cfg.idle.suspend_after_seconds <= cfg.idle.blank_after_seconds) {
        fail(path, line_no, "suspend_after_seconds must be greater than blank_after_seconds", .{});
        return error.InvalidConfig;
    }

    if (cfg.night_light.start == cfg.night_light.end) {
        fail(path, line_no, "night_light start cannot equal end", .{});
        return error.InvalidConfig;
    }

    const nl_night_span = @mod(@as(i32, cfg.night_light.end) - @as(i32, cfg.night_light.start) + 1440, 1440);
    const nl_day_span = 1440 - nl_night_span;
    if (cfg.night_light.transition_minutes >= nl_night_span or cfg.night_light.transition_minutes >= nl_day_span) {
        fail(path, line_no, "night_light transition_minutes must be shorter than both night and day spans", .{});
        return error.InvalidConfig;
    }

    if (cfg.night_light.schedule == .sun) {
        if (cfg.night_light.latitude == null or cfg.night_light.longitude == null) {
            fail(path, line_no, "night_light schedule 'sun' requires both latitude and longitude", .{});
            return error.InvalidConfig;
        }
    }

    if (seen_keybinds) {
        // Keep laptop controls, nested-session switching and the way out of
        // an inhibiting client available in existing configs too. Explicit
        // bindings (including noop) always take precedence over these defaults.
        const defaults = try parseKeybindsOnly(cfg.arena.allocator(), default_file.source);
        for (defaults) |bind| {
            const nested_switcher = bind.modifiers.ctrl and (bind.action == .focus_next or bind.action == .focus_prev);
            if (!keybinds.isHardwareAction(bind.action) and !nested_switcher and bind.action != .restore_shortcuts) continue;
            const key = keybinds.pack(bind.modifiers, bind.sym);
            var overridden = false;
            for (bind_list.items) |custom| {
                if (keybinds.pack(custom.modifiers, custom.sym) == key) {
                    overridden = true;
                    break;
                }
            }
            if (!overridden) try bind_list.append(cfg.arena.allocator(), bind);
        }
        cfg.keybinds = bind_list.items;
    } else {
        try applyDefaultKeybinds(&cfg);
    }
    cfg.autostart = autostart_list.items;
    cfg.outputs = outputs_list.items;
    var have_primary = false;
    for (cfg.outputs) |output| {
        if (!output.primary) continue;
        if (have_primary) {
            fail(path, line_no, "outputs may contain only one primary monitor", .{});
            return error.InvalidConfig;
        }
        have_primary = true;
    }
    cfg.window_rules = rule_list.items;
    cfg.notification_rules = notif_rule_list.items;
    cfg.sandbox_allow = sandbox_allow_list.items;
    try rebuildLookup(&cfg);
    finishCompositor(&cfg);
    // An explicit [animations.camera_desktop] table wins over the settings value.
    if (std.meta.eql(target_flags[@intFromEnum(anim.Target.camera_desktop)], anim_cfg.TargetFlags{})) {
        cfg.animations.targets[@intFromEnum(anim.Target.camera_desktop)].curve = anim.desktopSwitchCurve(cfg.compositor.desktop_switch_ms);
    }
    cfg.keyboard_keymap = @import("keymap.zig").compile(allocator, cfg.input) catch return error.InvalidConfig;
    return cfg;
}

const Section = union(enum) {
    none,
    theme,
    input,
    input_method,
    compositor,
    region,
    autostart,
    outputs,
    keybinds,
    polkit,
    idle,
    window_rules,
    sandbox_allow,
    night_light,
    notifications,
    notification_rules,
    desktop,
    ipc,
    animations,
    animation_target: anim.Target,
};

fn flushArrayTables(
    cfg: *Config,
    path: []const u8,
    line_no: usize,
    section: Section,
    outputs_list: *std.ArrayListUnmanaged(OutputConfig),
    current_output: *OutputConfig,
    have_current_output: *bool,
    rule_list: *std.ArrayListUnmanaged(WindowRule),
    current_rule: *WindowRule,
    have_current_rule: *bool,
    notif_rule_list: *std.ArrayListUnmanaged(NotificationRule),
    current_notif_rule: *NotificationRule,
    have_current_notif_rule: *bool,
    sandbox_allow_list: *std.ArrayListUnmanaged(SandboxAllowRule),
    current_sandbox_allow: *SandboxAllowRule,
    have_current_sandbox_allow: *bool,
) !void {
    if (section == .outputs and have_current_output.*) {
        if ((current_output.width == null) != (current_output.height == null) or
            (current_output.refresh_mhz != null and current_output.width == null)) return error.InvalidConfig;
        outputs_list.append(cfg.arena.allocator(), current_output.*) catch return error.OutOfMemory;
        current_output.* = .{};
        have_current_output.* = false;
    } else if (section == .window_rules and have_current_rule.*) {
        if (rule_list.items.len >= window_rules.max_rules) {
            fail(path, line_no, "too many window rules (max {d})", .{window_rules.max_rules});
            return error.InvalidConfig;
        }
        if (current_rule.hasMatchers() and !current_rule.hasProperties()) {
            log.warn("{s}:{d}: (warn): window rule has matchers but no properties", .{ path, line_no });
        }
        rule_list.append(cfg.arena.allocator(), current_rule.*) catch return error.OutOfMemory;
        current_rule.* = .{};
        have_current_rule.* = false;
    } else if (section == .notification_rules and have_current_notif_rule.*) {
        notif_rule_list.append(cfg.arena.allocator(), current_notif_rule.*) catch return error.OutOfMemory;
        current_notif_rule.* = .{};
        have_current_notif_rule.* = false;
    } else if (section == .sandbox_allow and have_current_sandbox_allow.*) {
        if (current_sandbox_allow.app_id.len == 0) {
            fail(path, line_no, "sandbox_allow requires app_id", .{});
            return error.InvalidConfig;
        }
        sandbox_allow_list.append(cfg.arena.allocator(), current_sandbox_allow.*) catch return error.OutOfMemory;
        current_sandbox_allow.* = .{};
        have_current_sandbox_allow.* = false;
    }
}

fn parseSection(line: []const u8) !Section {
    if (std.mem.startsWith(u8, line, "[[")) {
        inline for (.{ .autostart, .outputs, .window_rules, .notification_rules, .sandbox_allow }) |tag| {
            if (std.mem.eql(u8, line, "[[" ++ @tagName(tag) ++ "]]")) return tag;
        }
        return error.InvalidConfig;
    }
    const close = std.mem.indexOfScalar(u8, line, ']') orelse return error.InvalidConfig;
    const name = line[1..close];
    // Array tables and internal tags are deliberately not accepted here.
    inline for (.{ .theme, .input, .input_method, .compositor, .region, .keybinds, .polkit, .idle, .night_light, .notifications, .desktop, .ipc, .animations }) |tag| {
        if (std.mem.eql(u8, name, @tagName(tag))) return tag;
    }
    if (std.mem.startsWith(u8, name, "animations.")) {
        const rest = name["animations.".len..];
        return .{ .animation_target = anim.Target.parse(rest) orelse return error.UnknownAnimationTarget };
    }
    return .none;
}

fn initEmpty(allocator: Allocator) !Config {
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
}

fn applyDefaultKeybinds(cfg: *Config) !void {
    const parsed = try parseKeybindsOnly(cfg.arena.allocator(), default_file.source);
    cfg.keybinds = parsed;
    try rebuildLookup(cfg);
}

fn parseKeybindsOnly(allocator: Allocator, bytes: []const u8) ![]Keybind {
    var list: std.ArrayListUnmanaged(Keybind) = .empty;
    var in_keybinds = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = theme_mod.stripComment(std.mem.trim(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_keybinds = std.mem.eql(u8, line, "[keybinds]");
            continue;
        }
        if (!in_keybinds) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = unquoteKey(std.mem.trim(u8, line[0..eq], " \t"));
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const spec = try keybinds.parseKeybind(key);
        const action_str = try theme_mod.unquote(value);
        const action = try keybinds.parseAction(action_str, allocator);
        try list.append(allocator, .{
            .modifiers = spec.modifiers,
            .sym = spec.sym,
            .action = action,
        });
    }
    return list.items;
}

fn rebuildLookup(cfg: *Config) !void {
    cfg.lookup = .empty;
    const a = cfg.arena.allocator();
    for (cfg.keybinds, 0..) |bind, i| {
        const packed_key = keybinds.pack(bind.modifiers, bind.sym);
        try cfg.lookup.put(a, packed_key, i);
    }
}

fn finishCompositor(cfg: *Config) void {
    const count = @min(cfg.compositor.zoom_step_count, max_zoom_steps);
    cfg.compositor.zoom_step_count = @max(1, count);
    var percents: [max_zoom_steps]u8 = undefined;
    var i: u8 = 0;
    while (i < cfg.compositor.zoom_step_count) : (i += 1) {
        const step = std.math.clamp(cfg.compositor.zoom_steps[i], 0.01, 4.0);
        percents[i] = @intFromFloat(@round(step * 100.0));
        if (percents[i] == 0) percents[i] = 1;
    }
    cfg.compositor.zoom_percents = cfg.arena.allocator().dupe(u8, percents[0..cfg.compositor.zoom_step_count]) catch {
        cfg.compositor.zoom_percents = &default_zoom_percents;
        cfg.compositor.zoom_step_count = 4;
        return;
    };
}

fn overlayThemeFile(allocator: Allocator, io: Io, t: *Theme, path: []const u8) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(bytes);
    try theme_mod.overlay(allocator, t, bytes);
}

const FieldRule = union(enum) {
    taskbar_items,
    boolean,
    string,
    string_list,
    json_string_list,
    uint: struct { min: u32, max: u32 },
    int: struct { min: i32 = std.math.minInt(i32), max: i32 = std.math.maxInt(i32) },
    float: struct { min: f32, max: f32, exclusive_min: bool = false },
    output_scale,
    output_transform,
    zoom_steps,
    accel_profile,
    accel_point,
    /// A bare or quoted enum tag name.
    enumeration,
    derived,
};

// EnumFieldStruct requires a rule for every field, including derived fields
// that must never become independently configurable.
const input_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(InputConfig), FieldRule, null) = .{
    .xkb_layout = .string,
    .xkb_variant = .string,
    .xkb_options = .string,
    .xkb_model = .string,
    .natural_scroll = .boolean,
    .invert_scroll = .boolean,
    .pointer_speed = .{ .float = .{ .min = -1, .max = 1 } },
    .pointer_speed_touchpad = .{ .float = .{ .min = -1, .max = 1 } },
    .accel_profile = .accel_profile,
    .accel_p1 = .accel_point,
    .accel_p2 = .accel_point,
    .accel_max_speed = .{ .float = .{ .min = 0.0, .max = 10_000.0, .exclusive_min = true } },
    .pan_speed = .{ .float = .{ .min = 1.0, .max = 4.0 } },
    .pan_modifier = .enumeration,
    .middle_button_pan = .boolean,
    .wheel_acceleration = .{ .float = .{ .min = 0.0, .max = 4.0 } },
    .wheel_acceleration_max = .{ .float = .{ .min = 1.0, .max = 20.0 } },
    .wheel_acceleration_exclude = .string_list,
    .smooth_scroll = .boolean,
    .smooth_scroll_exclude = .string_list,
    .tap_to_click = .boolean,
    .tap_drag = .boolean,
    .disable_while_typing = .boolean,
    .disable_while_typing_touchpad = .boolean,
    .key_repeat_delay = .{ .uint = .{ .min = 1, .max = 5000 } },
    .key_repeat_rate = .{ .uint = .{ .min = 1, .max = 200 } },
    .cursor_theme = .string,
    .cursor_size = .{ .uint = .{ .min = 1, .max = 256 } },
    // 0 is meaningful for all three (blink off / never time out / no glide),
    // so these ranges start there rather than at 1.
    .caret_blink_ms = .{ .uint = .{ .min = 0, .max = 10_000 } },
    .caret_blink_timeout = .{ .uint = .{ .min = 0, .max = 3600 } },
    .caret_motion_ms = .{ .uint = .{ .min = 0, .max = 2000 } },
};

const region_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(RegionConfig), FieldRule, null) = .{
    .clock_24h = .boolean,
    .first_day_of_week = .enumeration,
};

const compositor_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(CompositorConfig), FieldRule, null) = .{
    .taskbar_items = .taskbar_items,
    .taskbar_position = .enumeration,
    .window_tab_apps = .json_string_list,
    .default_file_manager = .string,
    .default_terminal = .string,
    .focus_follows_mouse = .boolean,
    .canvas_columns = .{ .uint = .{ .min = 1, .max = 10 } },
    .canvas_rows = .{ .uint = .{ .min = 1, .max = 10 } },
    .desktop_switch_ms = .{ .uint = .{ .min = 100, .max = 3000 } },
    .desktop_icons_fixed = .boolean,
    .mini_map_enabled = .boolean,
    .mini_map_position = .enumeration,
    .mini_map_hide_ms = .{ .uint = .{ .min = 500, .max = 10000 } },
    .canvas_width = .{ .uint = .{ .min = 1, .max = 100_000 } },
    .canvas_height = .{ .uint = .{ .min = 1, .max = 100_000 } },
    .zoom_steps = .zoom_steps,
    .zoom_step_count = .derived,
    .zoom_percents = .derived,
    .camera_zoom_min = .{ .float = .{ .min = 0, .max = 8, .exclusive_min = true } },
    .camera_zoom_max = .{ .float = .{ .min = 0, .max = 8, .exclusive_min = true } },
    .focus_zoom = .enumeration,
    .window_gap = .{ .uint = .{ .min = 0, .max = 512 } },
    .snap_to_edges = .boolean,
    .dodge_file_drags = .boolean,
    .inactive_opacity = .{ .float = .{ .min = 0, .max = 1 } },
    .switcher_opacity = .{ .float = .{ .min = 0, .max = 1 } },
    .border_radius = .{ .uint = .{ .min = 0, .max = 128 } },
    .allow_tearing = .boolean,
    .xwayland = .boolean,
    .xwayland_native_scaling = .boolean,
    .xwayland_scale = .{ .float = .{ .min = 0, .max = 4 } },
    .dark_mode = .boolean,
    .placeholder_delay_ms = .{ .uint = .{ .min = 0, .max = 10_000 } },
    .wallpaper = .string,
    .sound_theme = .string,
    .sound_enabled = .boolean,
    .sound_disabled_events = .json_string_list,
    .lid_close = .enumeration,
    .lock_on_suspend = .boolean,
};

const idle_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(IdleConfig), FieldRule, null) = .{
    .enabled = .boolean,
    .blank_after_seconds = .{ .uint = .{ .min = 0, .max = std.math.maxInt(u32) } },
    .suspend_after_seconds = .{ .uint = .{ .min = 0, .max = std.math.maxInt(u32) } },
};

const desktop_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(DesktopConfig), FieldRule, null) = .{
    .enabled = .boolean,
};

const ipc_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(IpcConfig), FieldRule, null) = .{
    .automation = .boolean,
};

const output_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(OutputConfig), FieldRule, null) = .{
    .width = .{ .int = .{ .min = 1 } },
    .height = .{ .int = .{ .min = 1 } },
    .refresh_mhz = .{ .int = .{ .min = 1 } },
    .name = .string,
    .x = .{ .int = .{} },
    .y = .{ .int = .{} },
    .scale = .output_scale,
    .enabled = .boolean,
    .primary = .boolean,
    .transform = .output_transform,
    .night_light = .boolean,
    .gamma = .{ .float = .{ .min = 0.5, .max = 2.0 } },
};

/// Describes the values `rule` accepts, for "<field> must be ..." errors.
fn ruleHint(comptime rule: FieldRule) []const u8 {
    return switch (rule) {
        .boolean => "a boolean",
        .string => "a quoted string",
        .string_list => "a quoted string or an array of them",
        .json_string_list => "an array of quoted app IDs",
        .uint => |r| std.fmt.comptimePrint("an integer between {d} and {d}", .{ r.min, r.max }),
        .int => |r| if (r.min == 1 and r.max == std.math.maxInt(i32))
            "a positive integer"
        else if (r.min == std.math.minInt(i32) and r.max == std.math.maxInt(i32))
            "an integer"
        else
            std.fmt.comptimePrint("an integer between {d} and {d}", .{ r.min, r.max }),
        .float => |r| std.fmt.comptimePrint("a number between {d} and {d}", .{ r.min, r.max }),
        .output_scale => "a number between 1 and 3, or quoted auto",
        .output_transform => "normal, 90, 180, 270, flipped, flipped_90, flipped_180, or flipped_270",
        .enumeration => "a documented name",
        .taskbar_items, .zoom_steps, .accel_profile, .accel_point, .derived => "valid",
    };
}

fn enumHint(comptime T: type) []const u8 {
    const names = std.meta.fieldNames(T);
    var hint: []const u8 = "";
    for (names, 0..) |name, i| {
        const separator = if (i == 0) "" else if (i + 1 == names.len) " or " else ", ";
        hint = hint ++ separator ++ "\"" ++ name ++ "\"";
    }
    return hint;
}

fn fieldHint(comptime T: type, comptime rules: anytype, key: []const u8) []const u8 {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, key, field.name)) {
            if (comptime @field(rules, field.name) == .enumeration) return comptime enumHint(field.type);
            return comptime ruleHint(@field(rules, field.name));
        }
    }
    return "valid";
}

fn applyField(target: anytype, allocator: Allocator, comptime rules: anytype, key: []const u8, value: []const u8) !bool {
    inline for (std.meta.fields(@TypeOf(target.*))) |field| {
        const rule = comptime @field(rules, field.name);
        if (rule != .derived and std.mem.eql(u8, key, field.name)) {
            switch (comptime rule) {
                .taskbar_items => @field(target, field.name) = try TaskbarItems.parse(value),
                .boolean => @field(target, field.name) = try parseBool(value),
                .string => @field(target, field.name) = try parseString(allocator, value),
                .string_list => @field(target, field.name) = try window_rules.parseStringOrArray(allocator, value),
                .json_string_list => @field(target, field.name) = try std.json.parseFromSliceLeaky([]const []const u8, allocator, value, .{ .allocate = .alloc_always }),
                .uint => |range| @field(target, field.name) = try parseU32Range(value, range.min, range.max),
                .int => |range| @field(target, field.name) = try parseI32Range(value, range.min, range.max),
                .output_scale => @field(target, field.name) = try parseOutputScale(value),
                .output_transform => @field(target, field.name) = try output_transform.parse(value),
                .float => |range| {
                    const v = try std.fmt.parseFloat(field.type, value);
                    if (!std.math.isFinite(v) or v < range.min or v > range.max or
                        (range.exclusive_min and v == range.min)) return error.InvalidValue;
                    @field(target, field.name) = v;
                },
                .zoom_steps => try parseZoomSteps(target, value),
                .accel_profile => @field(target, field.name) = try parseAccelProfile(value),
                .accel_point => @field(target, field.name) = try parseVec2(value),
                .enumeration => @field(target, field.name) = try parseEnum(field.type, value),
                .derived => unreachable,
            }
            return true;
        }
    }
    return false;
}

fn applyInputKey(input: *InputConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    _ = try applyField(input, allocator, input_rules, key, value);
}

fn applyCompositorKey(c: *CompositorConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    _ = try applyField(c, allocator, compositor_rules, key, value);
    if (c.xwayland_scale > 0 and c.xwayland_scale < 1) return error.InvalidValue;
}

fn applyPolkitKey(config: *PolkitConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "enable")) {
        config.enable = try parseBool(value);
    } else if (std.mem.eql(u8, key, "helper_socket")) {
        const path = try parseString(allocator, value);
        if (path.len == 0 or path.len >= 108 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidValue;
        config.helper_socket = path;
    } else return error.InvalidField;
}

fn applyIdleKey(idle: *IdleConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    // Idle retains its stricter unknown-key policy.
    if (!try applyField(idle, allocator, idle_rules, key, value)) return error.InvalidField;
}

fn applyDesktopKey(desktop: *DesktopConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (!try applyField(desktop, allocator, desktop_rules, key, value)) return error.InvalidField;
}

fn applyIpcKey(ipc: *IpcConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (!try applyField(ipc, allocator, ipc_rules, key, value)) return error.InvalidField;
}

fn applyNightLightKey(nl: *NightLightConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "enabled")) {
        nl.enabled = try parseBool(value);
    } else if (std.mem.eql(u8, key, "schedule")) {
        const str = try parseString(allocator, value);
        if (std.mem.eql(u8, str, "fixed")) {
            nl.schedule = .fixed;
        } else if (std.mem.eql(u8, str, "sun")) {
            nl.schedule = .sun;
        } else if (std.mem.eql(u8, str, "always")) {
            nl.schedule = .always;
        } else {
            return error.InvalidValue;
        }
    } else if (std.mem.eql(u8, key, "temperature")) {
        nl.temperature = @intCast(try parseU32Range(value, 1700, 10000));
    } else if (std.mem.eql(u8, key, "day_temperature")) {
        nl.day_temperature = @intCast(try parseU32Range(value, 1700, 10000));
    } else if (std.mem.eql(u8, key, "start")) {
        const str = try parseString(allocator, value);
        nl.start = try schedule_mod.parseClock(str);
    } else if (std.mem.eql(u8, key, "end")) {
        const str = try parseString(allocator, value);
        nl.end = try schedule_mod.parseClock(str);
    } else if (std.mem.eql(u8, key, "transition_minutes")) {
        nl.transition_minutes = @intCast(try parseU32Range(value, 0, 180));
    } else if (std.mem.eql(u8, key, "latitude")) {
        const lat = try std.fmt.parseFloat(f64, value);
        if (!std.math.isFinite(lat) or lat < -90.0 or lat > 90.0) return error.InvalidValue;
        nl.latitude = lat;
    } else if (std.mem.eql(u8, key, "longitude")) {
        const lon = try std.fmt.parseFloat(f64, value);
        if (!std.math.isFinite(lon) or lon < -180.0 or lon > 180.0) return error.InvalidValue;
        nl.longitude = lon;
    } else {
        return error.InvalidField;
    }
}

fn applyNotificationsKey(n: *NotificationsConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "daemon")) {
        n.daemon = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "dnd")) {
        n.dnd = try parseBool(value);
    } else if (std.mem.eql(u8, key, "default_timeout_ms")) {
        n.default_timeout_ms = try parseU32Range(value, 0, std.math.maxInt(u32));
    } else {
        return error.InvalidField;
    }
}

fn applyNotificationRuleKey(rule: *NotificationRule, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "app_name") or std.mem.eql(u8, key, "app_id")) {
        rule.app_name = try window_rules.parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "desktop_entry")) {
        rule.desktop_entry = try window_rules.parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "mute")) {
        rule.mute = try parseBool(value);
    } else if (std.mem.eql(u8, key, "urgency")) {
        const u = try parseU32Range(value, 0, 2);
        rule.urgency = @intCast(u);
    } else if (std.mem.eql(u8, key, "dnd_bypass")) {
        rule.dnd_bypass = try parseBool(value);
    } else {
        return error.InvalidField;
    }
}

fn parseZoomSteps(c: *CompositorConfig, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.InvalidValue;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    var count: u8 = 0;
    if (inner.len > 0) {
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |part| {
            if (count >= max_zoom_steps) return error.InvalidValue;
            const n = try std.fmt.parseFloat(f32, std.mem.trim(u8, part, " \t"));
            if (!std.math.isFinite(n) or n <= 0 or n > 8) return error.InvalidValue;
            c.zoom_steps[count] = n;
            count += 1;
        }
    }
    if (count == 0) return error.InvalidValue;
    c.zoom_step_count = count;
}

fn parseEnum(comptime T: type, value: []const u8) !T {
    const trimmed = std.mem.trim(u8, value, " \t");
    const s = if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed;
    return std.meta.stringToEnum(T, s) orelse error.InvalidValue;
}

fn parseAccelProfile(value: []const u8) !AccelProfile {
    const trimmed = std.mem.trim(u8, value, " \t");
    const s = if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed;
    if (std.mem.eql(u8, s, "bezier")) return .bezier;
    if (std.mem.eql(u8, s, "flat")) return .flat;
    return error.InvalidValue;
}

fn parseVec2(value: []const u8) ![2]f32 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.InvalidValue;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    var it = std.mem.splitScalar(u8, inner, ',');
    const part0 = it.next() orelse return error.InvalidValue;
    const part1 = it.next() orelse return error.InvalidValue;
    if (it.next() != null) return error.InvalidValue;
    const x = std.fmt.parseFloat(f32, std.mem.trim(u8, part0, " \t")) catch return error.InvalidValue;
    const y = std.fmt.parseFloat(f32, std.mem.trim(u8, part1, " \t")) catch return error.InvalidValue;
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidValue;
    if (x < 0.0 or x > 1.0) return error.InvalidValue;
    if (y < 0.0 or y > 100.0) return error.InvalidValue;
    return .{ x, y };
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidValue;
}

fn parseU32Range(value: []const u8, min: u32, max: u32) !u32 {
    const n = try std.fmt.parseInt(u32, value, 10);
    if (n < min or n > max) return error.InvalidValue;
    return n;
}

fn parseI32Range(value: []const u8, min: i32, max: i32) !i32 {
    const n = try std.fmt.parseInt(i32, value, 10);
    if (n < min or n > max) return error.InvalidValue;
    return n;
}

/// A scale of 1-3 snapped to the 1/120 steps of wp_fractional_scale, or
/// quoted "auto" (null) for automatic density detection.
fn parseOutputScale(value: []const u8) !?f32 {
    if (std.mem.eql(u8, value, "\"auto\"")) return null;
    const scale = try std.fmt.parseFloat(f32, value);
    if (!std.math.isFinite(scale) or scale < 1 or scale > 3) return error.InvalidValue;
    return @round(scale * 120) / 120;
}

fn parseString(allocator: Allocator, value: []const u8) ![]const u8 {
    return allocator.dupe(u8, try theme_mod.unquote(value));
}

fn unquoteKey(key: []const u8) []const u8 {
    if (key.len >= 2 and key[0] == '"' and key[key.len - 1] == '"') return key[1 .. key.len - 1];
    return key;
}

fn fileExists(io: Io, path: []const u8) bool {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(1)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    std.heap.page_allocator.free(bytes);
    return true;
}

pub fn outputsLayoutEql(a: []const OutputConfig, b: []const OutputConfig) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or left.x != right.x or left.y != right.y or left.scale != right.scale or left.width != right.width or left.height != right.height or left.refresh_mhz != right.refresh_mhz or left.enabled != right.enabled or left.primary != right.primary or left.transform != right.transform) return false;
    }
    return true;
}

pub fn outputsColorEql(a: []const OutputConfig, b: []const OutputConfig) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or left.night_light != right.night_light or left.gamma != right.gamma) return false;
    }
    return true;
}

pub fn outputsEql(a: []const OutputConfig, b: []const OutputConfig) bool {
    return outputsLayoutEql(a, b);
}

pub fn nightLightEql(a: NightLightConfig, b: NightLightConfig) bool {
    return a.enabled == b.enabled and
        a.schedule == b.schedule and
        a.temperature == b.temperature and
        a.day_temperature == b.day_temperature and
        a.start == b.start and
        a.end == b.end and
        a.transition_minutes == b.transition_minutes and
        a.latitude == b.latitude and
        a.longitude == b.longitude;
}

pub fn wheelAccel(cfg: InputConfig) ui_wheel.Accel {
    return .{ .gain = cfg.wheel_acceleration, .max = cfg.wheel_acceleration_max };
}

pub fn inputEql(a: InputConfig, b: InputConfig) bool {
    inline for (std.meta.fields(InputConfig)) |field| {
        const left = @field(a, field.name);
        const right = @field(b, field.name);
        switch (field.type) {
            []const u8 => if (!std.mem.eql(u8, left, right)) return false,
            []const []const u8 => {
                if (left.len != right.len) return false;
                for (left, right) |l, r| if (!std.mem.eql(u8, l, r)) return false;
            },
            bool, u32, f32 => if (left != right) return false,
            AccelProfile, PanModifier => if (left != right) return false,
            [2]f32 => if (left[0] != right[0] or left[1] != right[1]) return false,
            else => @compileError("no input equality for " ++ field.name),
        }
    }
    return true;
}

pub fn themeEql(a: Theme, b: Theme) bool {
    inline for (std.meta.fields(Theme)) |field| {
        const left = @field(a, field.name);
        const right = @field(b, field.name);
        if (field.type == []const u8) {
            if (!std.mem.eql(u8, left, right)) return false;
        } else if (!std.meta.eql(left, right)) return false;
    }
    return true;
}

fn fail(path: []const u8, line: usize, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    log.warn("{s}:{d}: {s}", .{ path, line, msg });
}

test "empty config keeps built-in zoom steps and default keybinds" {
    var cfg = try parse(std.testing.allocator, "", "mem");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 4), cfg.compositor.zoom_step_count);
    try std.testing.expectEqual(@as(u8, 100), cfg.compositor.zoom_percents[0]);
    try std.testing.expect(cfg.autostart.len == 0);
    try std.testing.expect(cfg.keybinds.len > 0);
    const spec = try keybinds.parseKeybind("super+t");
    const action = cfg.lookupKeybind(spec.modifiers, spec.sym) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("default-terminal", action.spawn);
}

test "the desktop follows its section, then a legacy rediwm-desktop autostart" {
    var empty = try parse(std.testing.allocator, "", "empty");
    defer empty.deinit();
    try std.testing.expect(!desktopEnabled(&empty));
    var legacy = try parse(std.testing.allocator, "[[autostart]]\ncmd = \"/usr/local/bin/rediwm-desktop --verbose\"\n", "legacy");
    defer legacy.deinit();
    try std.testing.expect(desktopEnabled(&legacy));
    var off = try parse(std.testing.allocator, "[[autostart]]\ncmd = \"rediwm-desktop\"\n[desktop]\nenabled = false\n", "off");
    defer off.deinit();
    try std.testing.expect(!desktopEnabled(&off));
    try std.testing.expect(!isDesktopClient("rediwm-desktop-helper"));
}

test "documented default parses all sections" {
    var cfg = try parse(std.testing.allocator, default_file.source, "default");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 5), cfg.compositor.zoom_step_count);
    try std.testing.expectEqual(@as(u8, 40), cfg.compositor.zoom_percents[4]);
    try std.testing.expectEqual(@as(usize, 0), cfg.autostart.len);
    try std.testing.expect(desktopEnabled(&cfg));
    try std.testing.expect(cfg.input.natural_scroll);
    try std.testing.expectEqual(@as(u32, 400), cfg.input.key_repeat_delay);
    try std.testing.expectEqual(AccelProfile.bezier, cfg.input.accel_profile);
    try std.testing.expectEqual([2]f32{ 0.0, 0.0 }, cfg.input.accel_p1);
    try std.testing.expectEqual([2]f32{ 0.15, 1.0 }, cfg.input.accel_p2);
    try std.testing.expectEqual(@as(f32, 10.0), cfg.input.accel_max_speed);
    try std.testing.expectEqual(@as(u32, 10), cfg.compositor.border_radius);
    try std.testing.expect(cfg.compositor.xwayland);
    try std.testing.expectEqualStrings("Manrope", cfg.theme.font);

    const q = try keybinds.parseKeybind("super+q");
    try std.testing.expectEqual(Action.close_window, cfg.lookupKeybind(q.modifiers, q.sym).?);

    const depth = try keybinds.parseKeybind("super+3");
    try std.testing.expectEqual(@as(u8, 2), cfg.lookupKeybind(depth.modifiers, depth.sym).?.set_depth);
}

test "syntax error returns InvalidConfig" {
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[input]
        \\pointer_speed = 4.0
    , "bad"));
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[keybinds]
        \\"super+t" = "nope"
    , "bad"));
}

test "xwayland config defaults on and can be disabled" {
    var on = try parse(std.testing.allocator, "", "mem");
    defer on.deinit();
    try std.testing.expect(on.compositor.xwayland);

    var off = try parse(std.testing.allocator,
        \\[compositor]
        \\xwayland = false
    , "off");
    defer off.deinit();
    try std.testing.expect(!off.compositor.xwayland);
}

test "inline comments do not break values" {
    var cfg = try parse(std.testing.allocator,
        \\[input]
        \\pointer_speed = 0.5  # comment
        \\natural_scroll = false
    , "comments");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 0.5), cfg.input.pointer_speed);
    try std.testing.expect(!cfg.input.natural_scroll);
}

test "accel config parses bezier and flat sections" {
    var bezier_cfg = try parse(std.testing.allocator,
        \\[input]
        \\accel_profile = "bezier"
        \\accel_p1 = [0.1, 0.2]
        \\accel_p2 = [0.3, 0.9]
        \\accel_max_speed = 15.0
    , "bezier");
    defer bezier_cfg.deinit();
    try std.testing.expectEqual(AccelProfile.bezier, bezier_cfg.input.accel_profile);
    try std.testing.expectEqual([2]f32{ 0.1, 0.2 }, bezier_cfg.input.accel_p1);
    try std.testing.expectEqual([2]f32{ 0.3, 0.9 }, bezier_cfg.input.accel_p2);
    try std.testing.expectEqual(@as(f32, 15.0), bezier_cfg.input.accel_max_speed);

    var flat_cfg = try parse(std.testing.allocator,
        \\[input]
        \\accel_profile = "flat"
    , "flat");
    defer flat_cfg.deinit();
    try std.testing.expectEqual(AccelProfile.flat, flat_cfg.input.accel_profile);
}

test "idle config parsing and validation" {
    var def = try parse(std.testing.allocator, "", "mem");
    defer def.deinit();
    try std.testing.expectEqual(@as(?bool, null), def.idle.enabled);
    try std.testing.expectEqual(@as(u32, 600), def.idle.blank_after_seconds);
    try std.testing.expectEqual(@as(u32, 0), def.idle.suspend_after_seconds);

    var custom = try parse(std.testing.allocator,
        \\[idle]
        \\enabled = true
        \\blank_after_seconds = 300
        \\suspend_after_seconds = 600
    , "custom");
    defer custom.deinit();
    try std.testing.expectEqual(@as(?bool, true), custom.idle.enabled);
    try std.testing.expectEqual(@as(u32, 300), custom.idle.blank_after_seconds);
    try std.testing.expectEqual(@as(u32, 600), custom.idle.suspend_after_seconds);

    // Validation: suspend must be strictly greater than blank when both are non-zero
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[idle]
        \\blank_after_seconds = 600
        \\suspend_after_seconds = 600
    , "equal"));

    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[idle]
        \\blank_after_seconds = 600
        \\suspend_after_seconds = 300
    , "less"));

    // Negative values fail parsing
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[idle]
        \\blank_after_seconds = -1
    , "negative"));
}

test "input and theme reload detect every field and compare strings by content" {
    const original_theme = Theme{};
    inline for (std.meta.fields(Theme)) |field| {
        var changed = original_theme;
        @field(changed, field.name) = switch (field.type) {
            f32 => @field(original_theme, field.name) + 1,
            []const u8 => "another theme",
            [4]f32 => .{ 0.1, 0.2, 0.3, 0.4 },
            ?[4]f32 => .{ 0.1, 0.2, 0.3, 0.4 },
            else => @compileError("add a theme change fixture for " ++ field.name),
        };
        try std.testing.expect(!themeEql(original_theme, changed));
        try std.testing.expect(!themeEql(changed, original_theme));
    }
    var theme_copy = original_theme;
    theme_copy.font = try std.testing.allocator.dupe(u8, original_theme.font);
    defer std.testing.allocator.free(theme_copy.font);
    try std.testing.expect(themeEql(original_theme, theme_copy));
    const original = InputConfig{};
    inline for (std.meta.fields(InputConfig)) |field| {
        var changed = original;
        @field(changed, field.name) = switch (field.type) {
            bool => !@field(original, field.name),
            f32, u32 => @field(original, field.name) + 1,
            []const u8 => "another theme",
            []const []const u8 => if (@field(original, field.name).len == 0) &.{"another"} else &.{},
            AccelProfile => switch (@field(original, field.name)) {
                .bezier => .flat,
                .flat => .bezier,
            },
            PanModifier => switch (@field(original, field.name)) {
                .super => .super_alt,
                .super_alt => .super,
            },
            [2]f32 => .{ @field(original, field.name)[0] + 0.1, @field(original, field.name)[1] + 0.1 },
            else => @compileError("add an input change fixture for " ++ field.name),
        };
        try std.testing.expect(!inputEql(original, changed));
        try std.testing.expect(!inputEql(changed, original));
    }
    var copy = original;
    copy.cursor_theme = try std.testing.allocator.dupe(u8, original.cursor_theme);
    defer std.testing.allocator.free(copy.cursor_theme);
    try std.testing.expect(inputEql(original, copy));
}

test "config field parsing preserves ranges and derived zoom state" {
    var input = InputConfig{};
    const a = std.testing.allocator;
    inline for (.{
        .{ "key_repeat_delay", "1", "5000", "0", "5001" },
        .{ "key_repeat_rate", "1", "200", "0", "201" },
        .{ "cursor_size", "1", "256", "0", "257" },
    }) |fixture| {
        try applyInputKey(&input, a, fixture[0], fixture[1]);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, fixture[1], 10), @field(input, fixture[0]));
        try applyInputKey(&input, a, fixture[0], fixture[2]);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, fixture[2], 10), @field(input, fixture[0]));
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, fixture[0], fixture[3]));
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, fixture[0], fixture[4]));
    }
    try applyInputKey(&input, a, "pointer_speed", "-1");
    try std.testing.expectEqual(@as(f32, -1), input.pointer_speed);
    try applyInputKey(&input, a, "pointer_speed", "1");
    try std.testing.expectEqual(@as(f32, 1), input.pointer_speed);
    try applyInputKey(&input, a, "pointer_speed_touchpad", "-1");
    try std.testing.expectEqual(@as(f32, -1), input.pointer_speed_touchpad);
    try applyInputKey(&input, a, "pointer_speed_touchpad", "1");
    try std.testing.expectEqual(@as(f32, 1), input.pointer_speed_touchpad);
    try applyInputKey(&input, a, "disable_while_typing_touchpad", "true");
    try std.testing.expect(input.disable_while_typing_touchpad);
    try applyInputKey(&input, a, "disable_while_typing_touchpad", "false");
    try std.testing.expect(!input.disable_while_typing_touchpad);
    inline for (.{ "-1.01", "1.01", "nan", "inf" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "pointer_speed", v));
    }
    inline for (.{ "-1.01", "1.01", "nan", "inf" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "pointer_speed_touchpad", v));
    }
    inline for (.{ "natural_scroll", "invert_scroll", "tap_to_click", "tap_drag", "disable_while_typing" }) |key| {
        try applyInputKey(&input, a, key, "false");
        try std.testing.expect(!@field(input, key));
        try applyInputKey(&input, a, key, "true");
        try std.testing.expect(@field(input, key));
    }
    try applyInputKey(&input, a, "cursor_theme", "\"custom\"");
    defer a.free(input.cursor_theme);
    try std.testing.expectEqualStrings("custom", input.cursor_theme);

    try applyInputKey(&input, a, "accel_profile", "\"flat\"");
    try std.testing.expectEqual(AccelProfile.flat, input.accel_profile);
    try applyInputKey(&input, a, "accel_profile", "bezier");
    try std.testing.expectEqual(AccelProfile.bezier, input.accel_profile);
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_profile", "\"nope\""));

    try applyInputKey(&input, a, "accel_p1", "[0.0, 0.0]");
    try std.testing.expectEqual([2]f32{ 0.0, 0.0 }, input.accel_p1);
    try applyInputKey(&input, a, "accel_p2", "[ 0.15 , 1.0 ]");
    try std.testing.expectEqual([2]f32{ 0.15, 1.0 }, input.accel_p2);
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[-0.1, 0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[1.1, 0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[0.0, 0.0, 0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "bad"));

    try applyInputKey(&input, a, "accel_max_speed", "10.0");
    try std.testing.expectEqual(@as(f32, 10.0), input.accel_max_speed);
    try applyInputKey(&input, a, "accel_max_speed", "25.5");
    try std.testing.expectEqual(@as(f32, 25.5), input.accel_max_speed);
    inline for (.{ "0", "-1", "nan", "inf" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_max_speed", v));
    }

    var c = CompositorConfig{};
    inline for (.{
        .{ "canvas_width", "1", "100000", "0", "100001" },
        .{ "canvas_height", "1", "100000", "0", "100001" },
        .{ "window_gap", "0", "512", "513", "514" },
        .{ "border_radius", "0", "128", "129", "130" },
    }) |fixture| {
        try applyCompositorKey(&c, a, fixture[0], fixture[1]);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, fixture[1], 10), @field(c, fixture[0]));
        try applyCompositorKey(&c, a, fixture[0], fixture[2]);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, fixture[2], 10), @field(c, fixture[0]));
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, fixture[0], fixture[3]));
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, fixture[0], fixture[4]));
    }
    inline for (.{ "camera_zoom_min", "camera_zoom_max", "inactive_opacity" }) |key| {
        try applyCompositorKey(&c, a, key, "0.5");
        try std.testing.expectEqual(@as(f32, 0.5), @field(c, key));
        inline for (.{ "nan", "inf", "-0.1", "8.1" }) |v| {
            try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, key, v));
        }
    }
    inline for (.{ "camera_zoom_min", "camera_zoom_max" }) |key| {
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, key, "0"));
        try applyCompositorKey(&c, a, key, "8");
        try std.testing.expectEqual(@as(f32, 8), @field(c, key));
    }
    try applyCompositorKey(&c, a, "inactive_opacity", "0");
    try std.testing.expectEqual(@as(f32, 0), c.inactive_opacity);
    try applyCompositorKey(&c, a, "inactive_opacity", "1");
    try std.testing.expectEqual(@as(f32, 1), c.inactive_opacity);
    try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "inactive_opacity", "1.01"));
    try applyCompositorKey(&c, a, "focus_follows_mouse", "true");
    try std.testing.expect(c.focus_follows_mouse);
    try applyCompositorKey(&c, a, "xwayland", "false");
    try std.testing.expect(!c.xwayland);
    try applyCompositorKey(&c, a, "zoom_steps", "[1, 0.75]");
    try std.testing.expectEqual(@as(u8, 2), c.zoom_step_count);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0.75 }, c.zoom_steps[0..2]);
    try applyCompositorKey(&c, a, "zoom_step_count", "7");
    try applyCompositorKey(&c, a, "zoom_percents", "[20]");
    try std.testing.expectEqual(@as(u8, 2), c.zoom_step_count);
    try std.testing.expectEqualSlices(u8, &default_zoom_percents, c.zoom_percents);
    try applyInputKey(&input, a, "unknown", "ignored");
    try applyCompositorKey(&c, a, "unknown", "ignored");
}

test "idle field rules preserve optional enabled and strict unknown keys" {
    const a = std.testing.allocator;
    var idle = IdleConfig{};
    try std.testing.expectEqual(@as(?bool, null), idle.enabled);
    try applyIdleKey(&idle, a, "enabled", "false");
    try std.testing.expectEqual(@as(?bool, false), idle.enabled);
    try applyIdleKey(&idle, a, "enabled", "true");
    try std.testing.expectEqual(@as(?bool, true), idle.enabled);
    try std.testing.expectError(error.InvalidValue, applyIdleKey(&idle, a, "enabled", "null"));
    inline for (.{ "blank_after_seconds", "suspend_after_seconds" }) |key| {
        try applyIdleKey(&idle, a, key, "0");
        try std.testing.expectEqual(@as(u32, 0), @field(idle, key));
        try applyIdleKey(&idle, a, key, "4294967295");
        try std.testing.expectEqual(std.math.maxInt(u32), @field(idle, key));
        try std.testing.expectError(error.Overflow, applyIdleKey(&idle, a, key, "4294967296"));
    }
    try std.testing.expectError(error.InvalidField, applyIdleKey(&idle, a, "unknown", "ignored"));
}

test "window_rules TOML parsing and validation" {
    const toml =
        \\[[window_rules]]
        \\app_id = "org.telegram.desktop"
        \\exclude_title = "Media viewer"
        \\output = "DP-2"
        \\center = true
        \\width = 900
        \\height = 700
        \\
        \\[[window_rules]]
        \\app_id = ["firefox", "chromium"]
        \\title = "Picture-in-Picture"
        \\opacity = 0.9
        \\skip_taskbar = true
        \\focus = false
        \\
        \\[[window_rules]]
        \\x11_class = "Steam"
        \\dialog = false
        \\maximized = true
        \\
        \\[[window_rules]]
        \\app_id = "foot"
        \\decorations = "client"
    ;

    var cfg = try parse(std.testing.allocator, toml, "rules_test");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 4), cfg.window_rules.len);

    const r0 = cfg.window_rules[0];
    try std.testing.expectEqualStrings("org.telegram.desktop", r0.app_id.?[0]);
    try std.testing.expectEqualStrings("Media viewer", r0.exclude_title.?[0]);
    try std.testing.expectEqualStrings("DP-2", r0.output.?);
    try std.testing.expectEqual(@as(?bool, true), r0.center);
    try std.testing.expectEqual(@as(?u32, 900), r0.width);
    try std.testing.expectEqual(@as(?u32, 700), r0.height);

    const r1 = cfg.window_rules[1];
    try std.testing.expectEqual(@as(usize, 2), r1.app_id.?.len);
    try std.testing.expectEqualStrings("firefox", r1.app_id.?[0]);
    try std.testing.expectEqualStrings("chromium", r1.app_id.?[1]);
    try std.testing.expectEqualStrings("Picture-in-Picture", r1.title.?[0]);
    try std.testing.expectEqual(@as(?f32, 0.9), r1.opacity);
    try std.testing.expectEqual(@as(?bool, true), r1.skip_taskbar);
    try std.testing.expectEqual(@as(?bool, false), r1.focus);

    const r2 = cfg.window_rules[2];
    try std.testing.expectEqualStrings("Steam", r2.x11_class.?[0]);
    try std.testing.expectEqual(@as(?bool, false), r2.dialog);
    try std.testing.expectEqual(@as(?bool, true), r2.maximized);

    const r3 = cfg.window_rules[3];
    try std.testing.expectEqualStrings("foot", r3.app_id.?[0]);
    try std.testing.expectEqual(window_rules.DecorationMode.client, r3.decorations.?);

    // Conflict error in TOML
    const bad_toml =
        \\[[window_rules]]
        \\center = true
        \\x = 100
    ;
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, bad_toml, "bad_rule"));

    // Unknown field error
    const bad_key =
        \\[[window_rules]]
        \\unknown_field = "value"
    ;
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, bad_key, "bad_key"));
}

test "existing configs inherit laptop controls and can override or disable them" {
    var cfg = try parse(std.testing.allocator,
        \\[keybinds]
        \\"super+t" = "spawn foot"
        \\"XF86AudioMute" = "noop"
    , "hardware");
    defer cfg.deinit();
    const up = try keybinds.parseKeybind("XF86AudioRaiseVolume");
    try std.testing.expectEqual(Action.volume_up, cfg.lookupKeybind(up.modifiers, up.sym).?);
    const mute = try keybinds.parseKeybind("XF86AudioMute");
    try std.testing.expectEqual(Action.noop, cfg.lookupKeybind(mute.modifiers, mute.sym).?);
}

test "night_light config parsing and defaults" {
    var def = try default(std.testing.allocator);
    defer def.deinit();

    try std.testing.expectEqual(true, def.night_light.enabled);
    try std.testing.expectEqual(ScheduleMode.always, def.night_light.schedule);
    try std.testing.expectEqual(@as(u32, 5000), def.night_light.temperature);
    try std.testing.expectEqual(@as(u32, 6500), def.night_light.day_temperature);
    try std.testing.expectEqual(@as(u16, 21 * 60), def.night_light.start);
    try std.testing.expectEqual(@as(u16, 7 * 60), def.night_light.end);
    try std.testing.expectEqual(@as(u16, 30), def.night_light.transition_minutes);
    try std.testing.expectEqual(@as(?f64, null), def.night_light.latitude);
    try std.testing.expectEqual(@as(?f64, null), def.night_light.longitude);

    // Snapshot survives deinit (holds only scalars)
    var snapshot: NightLightConfig = undefined;
    {
        var custom = try parse(std.testing.allocator,
            \\[night_light]
            \\enabled = true
            \\schedule = "fixed"
            \\temperature = 3400
            \\day_temperature = 6000
            \\start = "22:00"
            \\end = "06:30"
            \\transition_minutes = 45
            \\
            \\[[outputs]]
            \\name = "DP-2"
            \\night_light = false
            \\gamma = 1.2
        , "custom");
        snapshot = custom.night_light;
        try std.testing.expectEqual(true, custom.outputs[0].night_light == false);
        try std.testing.expectApproxEqAbs(@as(f32, 1.2), custom.outputs[0].gamma, 0.001);
        custom.deinit();
    }
    try std.testing.expectEqual(true, snapshot.enabled);
    try std.testing.expectEqual(ScheduleMode.fixed, snapshot.schedule);
    try std.testing.expectEqual(@as(u32, 3400), snapshot.temperature);
    try std.testing.expectEqual(@as(u32, 6000), snapshot.day_temperature);
    try std.testing.expectEqual(@as(u16, 22 * 60), snapshot.start);
    try std.testing.expectEqual(@as(u16, 6 * 60 + 30), snapshot.end);
    try std.testing.expectEqual(@as(u16, 45), snapshot.transition_minutes);
}

test "output policy parses enabled and unique primary" {
    var cfg = try parse(std.testing.allocator,
        \\[[outputs]]
        \\name = "DP-1"
        \\primary = true
        \\enabled = false
        \\
        \\[[outputs]]
        \\name = "DP-2"
    , "output_policy");
    defer cfg.deinit();
    try std.testing.expectEqual(false, cfg.outputs[0].enabled);
    try std.testing.expectEqual(true, cfg.outputs[0].primary);
    try std.testing.expectEqual(true, cfg.outputs[1].enabled);
    try std.testing.expectEqual(false, cfg.outputs[1].primary);

    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[[outputs]]
        \\name = "DP-1"
        \\primary = true
        \\
        \\[[outputs]]
        \\name = "DP-2"
        \\primary = true
    , "ambiguous_primary"));
}

test "outputs fields parse through the rule table" {
    const a = std.testing.allocator;
    var cfg = try parse(a,
        \\[[outputs]]
        \\name = "DP-1"
        \\width = 2560
        \\height = 1440
        \\refresh_mhz = 144000
        \\x = -2560
        \\y = 0
        \\scale = 1.33
        \\transform = "flipped_90"
        \\night_light = false
        \\gamma = 1.2
        \\
        \\[[outputs]]
        \\name = "DP-2"
        \\scale = "auto"
    , "outputs_fields");
    defer cfg.deinit();
    const o = cfg.outputs[0];
    try std.testing.expectEqualStrings("DP-1", o.name);
    try std.testing.expectEqual(@as(?i32, 2560), o.width);
    try std.testing.expectEqual(@as(?i32, 1440), o.height);
    try std.testing.expectEqual(@as(?i32, 144000), o.refresh_mhz);
    try std.testing.expectEqual(@as(?i32, -2560), o.x);
    try std.testing.expectEqual(@as(?i32, 0), o.y);
    try std.testing.expectEqual(@as(?f32, 160.0 / 120.0), o.scale);
    try std.testing.expectEqual(output_transform.Transform.flipped_90, o.transform);
    try std.testing.expectEqual(false, o.night_light);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), o.gamma, 0.001);
    try std.testing.expectEqual(@as(?f32, null), cfg.outputs[1].scale);

    inline for (.{
        "width = 0",       "height = -1",        "refresh_mhz = 1.5", "x = 1.5",
        "scale = 0.9",     "scale = 3.1",        "scale = \"nan\"",   "scale = auto",
        "transform = 45",  "transform = \"45\"", "enabled = 1",       "name = DP-1",
        "unknown_key = 1",
    }) |line| {
        try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\n" ++ line ++ "\n", "err"));
    }
    try std.testing.expectEqualStrings("a positive integer", fieldHint(OutputConfig, output_rules, "width"));
    try std.testing.expectEqualStrings("an integer", fieldHint(OutputConfig, output_rules, "x"));
    try std.testing.expectEqualStrings("a number between 0.5 and 2", fieldHint(OutputConfig, output_rules, "gamma"));
}

test "night_light sun and always schedules" {
    var sun_cfg = try parse(std.testing.allocator,
        \\[night_light]
        \\enabled = true
        \\schedule = "sun"
        \\latitude = 51.51
        \\longitude = -0.13
    , "sun");
    defer sun_cfg.deinit();
    try std.testing.expectEqual(ScheduleMode.sun, sun_cfg.night_light.schedule);
    try std.testing.expectApproxEqAbs(@as(f64, 51.51), sun_cfg.night_light.latitude.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -0.13), sun_cfg.night_light.longitude.?, 0.001);

    var always_cfg = try parse(std.testing.allocator,
        \\[night_light]
        \\enabled = true
        \\schedule = "always"
        \\temperature = 2700
    , "always");
    defer always_cfg.deinit();
    try std.testing.expectEqual(ScheduleMode.always, always_cfg.night_light.schedule);
    try std.testing.expectEqual(@as(u32, 2700), always_cfg.night_light.temperature);
}

test "night_light validation errors" {
    const a = std.testing.allocator;

    // Unknown field
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nunknown = 1\n", "err"));

    // Temperature outside 1700-10000
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\ntemperature = 1600\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\ntemperature = 10500\n", "err"));

    // Day temperature outside 1700-10000
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nday_temperature = 1500\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nday_temperature = 11000\n", "err"));

    // Start equals end
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nstart = \"08:00\"\nend = \"08:00\"\n", "err"));

    // Transition minutes > 180
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\ntransition_minutes = 200\n", "err"));

    // Transition minutes not shorter than night or day span (e.g. night span 30m, transition 30m)
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nstart = \"23:00\"\nend = \"23:30\"\ntransition_minutes = 30\n", "err"));

    // Sun schedule missing coordinates
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\nlatitude = 50.0\n", "err"));

    // Sun schedule coordinates out of range
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\nlatitude = 95.0\nlongitude = 0.0\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\nlatitude = 0.0\nlongitude = -190.0\n", "err"));

    // Output gamma outside 0.5-2.0 or not finite
    try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\nname = \"DP-1\"\ngamma = 0.4\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\nname = \"DP-1\"\ngamma = 2.5\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\nname = \"DP-1\"\ngamma = \"nan\"\n", "err"));
}

test "animations config defaults and overlay" {
    var empty = try parse(std.testing.allocator, "", "mem");
    defer empty.deinit();
    try std.testing.expect(empty.animations.enabled);
    try std.testing.expectEqual(@as(f32, 1.0), empty.animations.speed);
    try std.testing.expectEqual(anim.ReducedMotion.auto, empty.animations.reduced_motion);
    const panel = empty.animations.targets[@intFromEnum(anim.Target.panel_slide)];
    try std.testing.expectEqual(anim.springs.panel_slide.stiffness, panel.curve.spring.stiffness);

    var cfg = try parse(std.testing.allocator,
        \\[animations]
        \\enabled = true
        \\speed = 0.5
        \\reduced_motion = "on"
        \\
        \\[animations.panel_slide]
        \\spring = { damping_ratio = 0.9, stiffness = 400, epsilon = 0.001 }
        \\
        \\[animations.taskbar_press]
        \\duration_ms = 120
        \\ease = "flip_bezier"
        \\
        \\[animations.camera_pan]
        \\spring = { damping_ratio = 1.0, stiffness = 300 }
        \\decay_rate = 0.99
        \\
        \\[animations.window_open]
        \\off = true
    , "anim");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 0.5), cfg.animations.speed);
    try std.testing.expectEqual(anim.ReducedMotion.on, cfg.animations.reduced_motion);
    const slide = cfg.animations.targets[@intFromEnum(anim.Target.panel_slide)].curve.spring;
    try std.testing.expectEqual(@as(f32, 0.9), slide.damping_ratio);
    try std.testing.expectEqual(@as(f32, 400), slide.stiffness);
    try std.testing.expectEqual(@as(f32, 0.001), slide.epsilon);
    const press = cfg.animations.targets[@intFromEnum(anim.Target.taskbar_press)].curve.duration;
    try std.testing.expectEqual(@as(i64, 120), press.ms);
    try std.testing.expectEqual(anim.Ease.flip_bezier, press.ease);
    const pan = cfg.animations.targets[@intFromEnum(anim.Target.camera_pan)];
    try std.testing.expectEqual(@as(f32, 300), pan.curve.spring.stiffness);
    try std.testing.expectEqual(@as(f32, 0.5), pan.curve.spring.epsilon);
    try std.testing.expectEqual(@as(f32, 0.99), pan.decay.rate);
    try std.testing.expect(cfg.animations.targets[@intFromEnum(anim.Target.window_open)].curve == .off);
}

test "animations config rejects unknown targets and illegal combinations" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.window_opne]\nspring = { stiffness = 800 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations]\nspeed = -1\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations]\nreduced_motion = \"maybe\"\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.panel_slide]\nspring = { damping_ratio = 1.0, stiffness = 900 }\nduration_ms = 90\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.panel_slide]\noff = true\nspring = { stiffness = 800 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.panel_slide]\nspring = { wobble = 1 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.camera_pan]\nspring = { damping_ratio = 1.0, stiffness = 500, epsilon = 0.0001 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations]\nunknown = true\n", "err"));
}

test "documented default still parses with commented animations block" {
    var cfg = try parse(std.testing.allocator, default_file.source, "default");
    defer cfg.deinit();
    try std.testing.expect(cfg.animations.enabled);
    try std.testing.expectEqual(anim.ReducedMotion.auto, cfg.animations.reduced_motion);
}

test "polkit defaults and strict configuration validation" {
    var defaults_cfg = try parse(std.testing.allocator, "", "polkit-defaults");
    defer defaults_cfg.deinit();
    try std.testing.expect(defaults_cfg.polkit.enable);
    try std.testing.expectEqualStrings("/run/polkit/agent-helper.socket", defaults_cfg.polkit.helper_socket);
    var custom = try parse(std.testing.allocator, "[polkit]\nenable = false\nhelper_socket = \"/tmp/test-helper\"\n", "polkit-custom");
    defer custom.deinit();
    try std.testing.expect(!custom.polkit.enable);
    try std.testing.expectEqualStrings("/tmp/test-helper", custom.polkit.helper_socket);
    for ([_][]const u8{ "enable = 1", "enabled = true", "helper_socket = \"\"", "helper_socket = \"relative/path\"", "unknown = false" }) |line| {
        const content = try std.fmt.allocPrint(std.testing.allocator, "[polkit]\n{s}\n", .{line});
        defer std.testing.allocator.free(content);
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, content, "polkit-invalid"));
    }
    const long_path = "[polkit]\nhelper_socket = \"/" ++ ("a" ** 107) ++ "\"\n";
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, long_path, "polkit-overlong"));
}

test "canvas screen counts default to three and reject values outside one to ten" {
    const a = std.testing.allocator;
    var defaults = try parse(a, "", "mem");
    defer defaults.deinit();
    try std.testing.expectEqual(@as(u32, 3), defaults.compositor.canvas_columns);
    try std.testing.expectEqual(@as(u32, 3), defaults.compositor.canvas_rows);
    var rectangular = try parse(a, "[compositor]\ncanvas_columns = 10\ncanvas_rows = 1\n", "mem");
    defer rectangular.deinit();
    try std.testing.expectEqual(@as(u32, 10), rectangular.compositor.canvas_columns);
    try std.testing.expectEqual(@as(u32, 1), rectangular.compositor.canvas_rows);
    inline for (.{ "canvas_columns", "canvas_rows" }) |key| {
        inline for (.{ "0", "11", "-1", "1.5" }) |value| {
            try std.testing.expectError(error.InvalidConfig, parse(a, "[compositor]\n" ++ key ++ " = " ++ value ++ "\n", "err"));
        }
    }
}

test "desktop switch duration sets the camera_desktop curve unless animations override it" {
    const a = std.testing.allocator;
    const idx = @intFromEnum(anim.Target.camera_desktop);
    var defaults = try parse(a, "", "mem");
    defer defaults.deinit();
    try std.testing.expectEqual(anim.desktopSwitchCurve(anim.default_desktop_switch_ms), defaults.animations.targets[idx].curve);
    var slow = try parse(a, "[compositor]\ndesktop_switch_ms = 1500\n", "mem");
    defer slow.deinit();
    try std.testing.expectEqual(anim.desktopSwitchCurve(1500), slow.animations.targets[idx].curve);
    var explicit = try parse(a, "[compositor]\ndesktop_switch_ms = 1500\n[animations.camera_desktop]\nduration_ms = 300\n", "mem");
    defer explicit.deinit();
    try std.testing.expectEqual(@as(i64, 300), explicit.animations.targets[idx].curve.duration.ms);
    inline for (.{ "99", "3001" }) |value| {
        try std.testing.expectError(error.InvalidConfig, parse(a, "[compositor]\ndesktop_switch_ms = " ++ value ++ "\n", "err"));
    }
}

test "input method environment validates supported names" {
    for ([_][]const u8{ "none", "fcitx", "ibus" }) |name| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "[input_method]\nenv = \"{s}\"\n", .{name});
        defer std.testing.allocator.free(source);
        var cfg = try parse(std.testing.allocator, source, "ime-env");
        defer cfg.deinit();
        try std.testing.expectEqualStrings(name, @tagName(cfg.input_method.env));
    }
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[input_method]\nenv = \"unknown\"", "bad-ime-env"));
}

test "sandbox_allow TOML parsing and resolution" {
    const toml =
        \\[[sandbox_allow]]
        \\app_id = "com.obsproject.Studio"
        \\engine = "org.flatpak"
        \\allow = ["capture", "windows"]
        \\
        \\[[sandbox_allow]]
        \\app_id = "org.example.App"
        \\allow = ["clipboard", "unknown_group"]
    ;
    var cfg = try parse(std.testing.allocator, toml, "sandbox-test");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.sandbox_allow.len);

    const obs = cfg.sandboxAllowGroups("com.obsproject.Studio", "org.flatpak");
    try std.testing.expect(obs.contains(.capture));
    try std.testing.expect(obs.contains(.windows));
    try std.testing.expect(!obs.contains(.clipboard));

    const obs_wrong_engine = cfg.sandboxAllowGroups("com.obsproject.Studio", "other.engine");
    try std.testing.expect(obs_wrong_engine.count() == 0);

    const app = cfg.sandboxAllowGroups("org.example.App", "any.engine");
    try std.testing.expect(app.contains(.clipboard));
    try std.testing.expect(!app.contains(.capture));

    try std.testing.expect(cfg.sandboxAllowGroups(null, null).count() == 0);

    const bad_toml =
        \\[[sandbox_allow]]
        \\allow = ["clipboard"]
    ;
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, bad_toml, "bad-sandbox"));
}

test "mini map defaults and validated configuration" {
    const a = std.testing.allocator;
    var defaults = try parse(a, "", "mem");
    defer defaults.deinit();
    try std.testing.expect(defaults.compositor.mini_map_enabled);
    try std.testing.expectEqual(.bottom_right, defaults.compositor.mini_map_position);
    try std.testing.expectEqual(@as(u32, 1500), defaults.compositor.mini_map_hide_ms);
    var custom = try parse(a, "[compositor]\nmini_map_enabled = false\nmini_map_position = \"bottom_center\"\nmini_map_hide_ms = 2000\n", "mem");
    defer custom.deinit();
    try std.testing.expect(!custom.compositor.mini_map_enabled);
    try std.testing.expectEqual(.bottom_center, custom.compositor.mini_map_position);
    try std.testing.expectEqual(@as(u32, 2000), custom.compositor.mini_map_hide_ms);
    inline for (.{ "mini_map_position = \"top\"", "mini_map_hide_ms = 0", "mini_map_hide_ms = 10001", "mini_map_enabled = 1" }) |line| {
        try std.testing.expectError(error.InvalidConfig, parse(a, "[compositor]\n" ++ line ++ "\n", "invalid"));
    }
}
