// Compositor config: TOML load/save, defaults, and hot-reload apply.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const xkb = @import("xkbcommon");

const theme_mod = @import("ui").theme;
const Theme = theme_mod.Theme;
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
const loader_edit = @import("loader_edit.zig");
const loader_fields = @import("loader_fields.zig");
const loader_compare = @import("loader_compare.zig");
pub const resolvePath = loader_edit.resolvePath;
pub const replaceThemeSection = loader_edit.replaceThemeSection;
pub const replaceThemeOverrides = loader_edit.replaceThemeOverrides;
pub const replaceTaskbarThemeSection = loader_edit.replaceTaskbarThemeSection;
pub const rewriteSection = loader_edit.rewriteSection;
pub const spliceSection = loader_edit.spliceSection;
pub const FieldRule = loader_fields.FieldRule;
pub const input_rules = loader_fields.input_rules;
pub const region_rules = loader_fields.region_rules;
pub const compositor_rules = loader_fields.compositor_rules;
pub const idle_rules = loader_fields.idle_rules;
pub const desktop_rules = loader_fields.desktop_rules;
pub const ipc_rules = loader_fields.ipc_rules;
pub const output_rules = loader_fields.output_rules;
pub const ruleHint = loader_fields.ruleHint;
pub const enumHint = loader_fields.enumHint;
pub const fieldHint = loader_fields.fieldHint;
pub const applyField = loader_fields.applyField;
pub const applyInputKey = loader_fields.applyInputKey;
pub const applyCompositorKey = loader_fields.applyCompositorKey;
pub const applyPolkitKey = loader_fields.applyPolkitKey;
pub const applyIdleKey = loader_fields.applyIdleKey;
pub const applyDesktopKey = loader_fields.applyDesktopKey;
pub const applyIpcKey = loader_fields.applyIpcKey;
pub const applyNightLightKey = loader_fields.applyNightLightKey;
pub const applyNotificationsKey = loader_fields.applyNotificationsKey;
pub const applyNotificationRuleKey = loader_fields.applyNotificationRuleKey;
pub const parseZoomSteps = loader_fields.parseZoomSteps;
pub const parseEnum = loader_fields.parseEnum;
pub const parseAccelProfile = loader_fields.parseAccelProfile;
pub const parseVec2 = loader_fields.parseVec2;
pub const parseBool = loader_fields.parseBool;
pub const parseU32Range = loader_fields.parseU32Range;
pub const parseI32Range = loader_fields.parseI32Range;
pub const parseOutputScale = loader_fields.parseOutputScale;
pub const parseString = loader_fields.parseString;
pub const unquoteKey = loader_fields.unquoteKey;
pub const outputsLayoutEql = loader_compare.outputsLayoutEql;
pub const outputsColorEql = loader_compare.outputsColorEql;
pub const outputsEql = loader_compare.outputsEql;
pub const nightLightEql = loader_compare.nightLightEql;
pub const wheelAccel = loader_compare.wheelAccel;
pub const inputEql = loader_compare.inputEql;
pub const themeEql = loader_compare.themeEql;

pub const log = std.log.scoped(.config);

pub const max_zoom_steps: u8 = 8;
pub const drag_scale_min: f32 = 1.0;
pub const drag_scale_max: f32 = 1.10;
pub const default_zoom_percents = [_]u8{ 100, 85, 70, 55 };

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
    // A wheel click against the run this soon after its last click is held
    // as a likely encoder bounce (`input/wheel_debounce.zig`). 0 disables.
    wheel_debounce_ms: u32 = 60,
    // Swap the primary and secondary buttons (libinput left-handed mode).
    left_handed: bool = false,
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

/// Personal session preferences. Empty strings inherit the login environment.
pub const RegionConfig = struct {
    timezone: []const u8 = "",
    language: []const u8 = "",
    formats: []const u8 = "",
    clock_24h: bool = false,
    clock_show_seconds: bool = false,
    clock_show_day: bool = true,
    first_day_of_week: enum { sunday, monday, tuesday, wednesday, thursday, friday, saturday } = .sunday,

    pub fn timeFormat(self: RegionConfig) [:0]const u8 {
        return if (self.clock_24h) "%H:%M" else "%l:%M %p";
    }

    pub fn taskbarTimeFormat(self: RegionConfig) [:0]const u8 {
        if (!self.clock_show_seconds) return self.timeFormat();
        return if (self.clock_24h) "%H:%M:%S" else "%l:%M:%S %p";
    }
};

pub const TaskbarItems = @import("taskbar_items.zig").Config;

pub const DesktopMode = enum { canvas, workspaces };
pub const dock_height_min: u32 = 48;
pub const dock_height_max: u32 = 96;
pub const dock_height_default: u32 = 68;
pub const dock_hover_zoom_max: f32 = 1.5;

pub const CompositorConfig = struct {
    desktop_mode: DesktopMode = .canvas,
    floating_apps: []const []const u8 = &.{},
    default_file_manager: []const u8 = "",
    default_terminal: []const u8 = "",
    dock_enabled: bool = false,
    dock_position: types.DockPosition = .bottom,
    dock_height: u32 = dock_height_default,
    dock_hover_zoom: f32 = 1.05,
    dock_auto_hide: bool = false,
    /// Alpha of the dock's background. Unset keeps the theme's own (`dock_bg`).
    dock_opacity: ?f32 = null,
    /// A rectangle behind the focused application's icon; the running pill shows regardless.
    dock_active_highlight: bool = false,
    /// A Trash icon at the dock's far end (right, or bottom on a side dock).
    dock_show_trash: bool = true,
    dock_hidden_shortcuts: []const []const u8 = &.{},
    dock_pinned_apps: []const []const u8 = &.{},
    taskbar_items: TaskbarItems = .{},
    taskbar_position: types.TaskbarPosition = .bottom,
    taskbar_alignment: types.TaskbarAlignment = .center,
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
    /// Explicit space around/between tiles. Unset uses the active mode's default.
    window_gap: ?u32 = null,
    /// Dragging a window to an open screen edge tiles or maximizes it.
    snap_to_edges: bool = true,
    /// Soft presentation-only lift while moving a window.
    drag_feedback: bool = true,
    drag_scale: f32 = 1.002,
    /// A file manager slides aside while a file is dragged out of it; see
    /// `input/drag_dodge.zig`.
    dodge_file_drags: bool = true,
    /// Files opens an item with one click on its icon; names still select.
    files_single_click_open: bool = true,
    inactive_opacity: f32 = 1.0,
    /// Background alpha handed to Foot, kitty, Alacritty, Ghostty and WezTerm at launch (`config/terminal_theme.zig`).
    /// Unset keeps the `alpha` of the user's own Foot configuration.
    terminal_opacity: ?f32 = null,
    /// A window that is not the focus loses `inactive_dim_amount` of its
    /// brightness and of its colour (`Toplevel.applyDim`).
    inactive_dim: bool = true,
    inactive_dim_amount: f32 = 0.08,
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
    icon_theme: []const u8 = "",
    sound_theme: []const u8 = "freedesktop",
    sound_enabled: bool = true,
    sound_disabled_events: []const []const u8 = &.{},
    /// What closing the laptop lid does; see `input/lid.zig`.
    lid_close: LidAction = .display_off,
    /// Lock before the system sleeps, however sleep was requested; logind
    /// waits until the lock is on screen (`session/power.zig`).
    lock_on_suspend: bool = true,

    pub fn windowGap(self: CompositorConfig) u32 {
        return self.window_gap orelse if (self.desktop_mode == .workspaces) 8 else 0;
    }
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
    theme_base: []const u8 = "",
    theme_defaults: Theme = .{},
    /// Effective config layer before REDIWM_THEME, for saving a small overlay.
    theme_config: Theme = .{},
    theme_pack: ?@import("theme_pack.zig").Pack = null,
    /// `[taskbar_theme]`: the taskbar's own colours over the main theme's.
    /// Null (no section) follows the main theme. Only taskbar tokens are set.
    taskbar_theme: ?Theme = null,
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
    workspace_keybinds: []Keybind = &.{},
    workspace_lookup: std.AutoHashMapUnmanaged(u64, usize) = .empty,
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
        if (self.compositor.desktop_mode == .workspaces) return keybinds.lookupKey(self.workspace_keybinds, self.workspace_lookup, mods, sym);
        return keybinds.lookupKey(self.keybinds, self.lookup, mods, sym);
    }

    pub fn activeKeybinds(self: *const Config) []Keybind {
        return if (self.compositor.desktop_mode == .workspaces) self.workspace_keybinds else self.keybinds;
    }

    pub fn sandboxAllowGroups(self: *const Config, app_id: ?[]const u8, engine: ?[]const u8) sandbox_allow.GroupSet {
        if (app_id == null) return sandbox_allow.GroupSet.empty;
        var set = sandbox_allow.GroupSet.empty;
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
    try applyWorkspaceKeybinds(&cfg, .empty);
    return cfg;
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

    if (cfg.theme_base.len > 0) {
        const a = cfg.arena.allocator();
        cfg.theme_pack = @import("theme_pack.zig").find(a, io, environ, path, cfg.theme_base) catch null;
        if (cfg.theme_pack) |p| {
            cfg.theme_defaults = p.tokens;
            cfg.theme = p.tokens;
            try theme_mod.overlay(a, &cfg.theme, bytes);
            if (cfg.taskbar_theme == null) cfg.taskbar_theme = p.taskbar;
            p.layout.apply(&cfg.compositor);
            if (p.color_scheme) |dark| cfg.compositor.dark_mode = dark;
            if (p.cursor_theme.len > 0) {
                cfg.input.cursor_theme = if (std.mem.eql(u8, p.cursor_theme, "pack"))
                    try std.fmt.allocPrint(a, "rediwm-{s}-cursors", .{p.id})
                else
                    p.cursor_theme;
            }
        } else log.warn("theme pack '{s}' is missing or invalid; using defaults", .{cfg.theme_base});
    }
    cfg.theme_config = cfg.theme;
    if (theme_mod.resolvePath(environ)) |theme_path| {
        overlayThemeFile(cfg.arena.allocator(), io, &cfg.theme, theme_path) catch |err| {
            log.warn("REDIWM_THEME overlay '{s}': {}", .{ theme_path, err });
        };
    }
    if (cfg.theme_pack != null) {
        var section: []const u8 = "";
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = theme_mod.stripComment(std.mem.trim(u8, raw, " \t\r"));
            if (line.len == 0) continue;
            if (line[0] == '[') {
                section = line;
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, section, "[compositor]") and std.mem.eql(u8, key, "dark_mode")) cfg.compositor.dark_mode = std.mem.eql(u8, value, "true");
            if (std.mem.eql(u8, section, "[compositor]")) {
                inline for (@import("theme_pack.zig").Layout.keys) |layout_key| {
                    if (std.mem.eql(u8, key, layout_key)) try applyCompositorKey(&cfg.compositor, cfg.arena.allocator(), key, value);
                }
            }
            if (std.mem.eql(u8, section, "[input]") and std.mem.eql(u8, key, "cursor_theme")) cfg.input.cursor_theme = try cfg.arena.allocator().dupe(u8, try theme_mod.unquote(value));
        }
    }
    finishCompositor(&cfg);
    return cfg;
}

const loader_parse = @import("loader_parse.zig");
pub const parse = loader_parse.parse;
pub const Section = loader_parse.Section;
pub const flushArrayTables = loader_parse.flushArrayTables;
pub const parseSection = loader_parse.parseSection;
pub const initEmpty = loader_parse.initEmpty;
pub const applyDefaultKeybinds = loader_parse.applyDefaultKeybinds;
pub const parseKeybindsOnly = loader_parse.parseKeybindsOnly;
pub const applyWorkspaceKeybinds = loader_parse.applyWorkspaceKeybinds;
pub const rebuildLookup = loader_parse.rebuildLookup;
pub const finishCompositor = loader_parse.finishCompositor;
pub const fail = loader_parse.fail;

pub fn overlayThemeFile(allocator: Allocator, io: Io, t: *Theme, path: []const u8) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(bytes);
    try theme_mod.overlay(allocator, t, bytes);
}

pub fn fileExists(io: Io, path: []const u8) bool {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(1)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    std.heap.page_allocator.free(bytes);
    return true;
}

test {
    _ = @import("loader_tests.zig");
}
