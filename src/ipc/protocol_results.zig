//! IPC v1 results and parameters for waits, buffers, stats, capture, night light, services and processes.

const std = @import("std");
const RectData = @import("protocol_data.zig").RectData;

pub const WidgetStateValue = union(enum) {
    boolean: bool,
    number: f64,
    string: []const u8,
    null_value,
};

pub fn freeWidgetStateValue(allocator: std.mem.Allocator, val: WidgetStateValue) void {
    switch (val) {
        .string => |s| allocator.free(s),
        else => {},
    }
}

pub const WaitCondition = union(enum) {
    menu_opened,
    menu_closed,
    control_center_opened,
    control_center_closed,
    power_menu_opened,
    power_menu_closed,
    window_mapped: struct { id: ?u64 = null, app_id: ?[]const u8 = null, title: ?[]const u8 = null },
    window_closed: struct { id: u64 },
    window_focused: struct { id: ?u64 = null },
    window_geometry_settled: struct { id: u64 },
    output_frame: struct { output: ?[]const u8 = null },
    catalog_published,
    wallpaper_presented,
    notification_count: struct { count: ?usize = null, app_name: ?[]const u8 = null, summary: ?[]const u8 = null },
    notification_closed: struct { id: u32 },
    notification_action: struct { id: u32, action_key: ?[]const u8 = null },
    launch_started: struct { desktop_id: ?[]const u8 = null },
    launch_matched: struct { desktop_id: ?[]const u8 = null, window_id: ?u64 = null },
    launch_timeout: struct { desktop_id: ?[]const u8 = null },
    widget_present: struct { path: []const u8 },
    widget_absent: struct { path: []const u8 },
    widget_state: struct { path: []const u8, field: []const u8, equals: WidgetStateValue },
    panel_settled: struct { panel: []const u8 },
};

pub const WaitForParams = struct {
    condition: WaitCondition,
    timeout_ms: u64 = 5000,
};

pub const WaitForResult = struct {
    condition: []const u8,
    elapsed_ms: u64,
    state: ?[]const u8 = null,
};

pub const WaitForFrameParams = struct {
    output: ?[]const u8 = null,
    timeout_ms: u64 = 5000,
};

pub const WaitForFrameResult = struct {
    output: []const u8,
    frame_seq: u64,
    elapsed_ms: u64,
};

pub const DumpBufferParams = struct {
    target: []const u8, // "titlebar", "start_menu", "control_center", "power_menu", "taskbar"
    window_id: ?u64 = null,
    output: ?[]const u8 = null,
};

pub const DumpBufferResult = struct {
    target: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    format: []const u8 = "argb8888",
    scale: f32,
    premultiplied: bool = true,
    data: ?[]const u8 = null,
};

pub const SamplePixelsParams = struct {
    output: ?[]const u8 = null,
    x: i32,
    y: i32,
    width: u32 = 1,
    height: u32 = 1,
};

pub const SamplePixelsResult = struct {
    output: []const u8,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    pixels: []const u32,
    gpu_readback: bool,
};

pub const ScreenshotSelectionStats = struct {
    motion_events: u64 = 0,
    updates: u64 = 0,
    update_ns: u64 = 0,
    toolbar_paints: u64 = 0,
    label_paints: u64 = 0,
    scene_nodes_created: u64 = 0,
};

pub const PerformanceStatsResult = struct {
    screenshot_selection: ?ScreenshotSelectionStats = null,
    // Optional for older in-process producers; the live handler always supplies it.
    frame_work: ?@import("frame_metrics.zig").FrameWork = null,
    output_commits: u64,
    output_failed_commits: u64,
    fps: f64 = 0,
    frame_time_ms: f64 = 0,
    missed_frames: u64 = 0,
    refresh_hz: f64 = 0,
    titlebar_paints: u64,
    footer_paints: u64,
    edge_samples_attempted: u64,
    edge_samples_succeeded: u64,
    edge_samples_skipped: u64,
    edge_sample_ns: u64,
    panel_paints: u64,
    panel_allocated_bytes: u64,
    panel_reused_bytes: u64,
    icon_cache_hits: u64,
    icon_cache_misses: u64,
    icon_decode_ns: u64,
    icon_decode_count: u64,
    icon_decoded_bytes: u64,
    icon_queue_depth_max: u64,
    taskbar_paints: u64,
    taskbar_paint_ns: u64,
    taskbar_raster_pixels: u64,
    taskbar_clock_frame_requests: u64,
    taskbar_clock_paints: u64,
    taskbar_start_paints: u64,
    taskbar_chip_paints: u64,
    taskbar_tray_paints: u64,
    taskbar_hover_paints: u64,
    taskbar_press_paints: u64,
    taskbar_audio_paints: u64,
    recent_errors_count: usize,
    anim_frames_scheduled: u64 = 0,
    anim_wasted_wakeups: u64 = 0,
    anim_longest_ms: u64 = 0,
    anim_speed: f32 = 1.0,
    anim_enabled: bool = true,
    anim_reduced_motion: bool = false,
    startup: ?StartupStats = null,
    desktop: ?DesktopStats = null,
    // Optional so older producers and fixtures omit it.
    output_skipped_commits: ?u64 = null,
    /// Glass blurs re-taken by the output pass (stage 5c), all outputs.
    glass_reblurs: ?u64 = null,
};

/// The compositor-drawn desktop's repaint work since the last reset.
pub const DesktopStats = struct {
    /// Canvas repaints, and the logical area they covered.
    paints: u64 = 0,
    damage_pixels: u64 = 0,
    /// Tiles handed to the scene, and how many of those needed a new texture
    /// rather than an in-place update.
    tile_presents: u64 = 0,
    texture_uploads: u64 = 0,
};

pub const StartupStats = struct {
    build_mode: []const u8 = "",
    renderer: []const u8 = "",
    scale: f32 = 1,
    output_count: u32 = 0,
    catalog_entries: u32 = 0,
    autostart_count: u32 = 0,
    catalog_state: []const u8 = "pending",
    wallpaper_state: []const u8 = "solid",
    catalog_provisional: bool = false,
    catalog_loading: bool = false,
    catalog_generation: u64 = 0,
    renderer_ready_ns: u64 = 0,
    config_ready_ns: u64 = 0,
    catalog_cache_read_ns: u64 = 0,
    catalog_scan_ns: u64 = 0,
    wallpaper_decode_ns: u64 = 0,
    socket_ready_ns: u64 = 0,
    ipc_ready_ns: u64 = 0,
    session_ready_ns: u64 = 0,
    session_clients_started_ns: u64 = 0,
    xwayland_ready_ns: u64 = 0,
    first_presented_ns: u64 = 0,
    first_ipc_ns: u64 = 0,
    first_input_ns: u64 = 0,
    catalog_published_ns: u64 = 0,
    wallpaper_presented_ns: u64 = 0,
    catalog_cache_read_duration_ns: u64 = 0,
    catalog_scan_duration_ns: u64 = 0,
    wallpaper_decode_duration_ns: u64 = 0,
    backend_start_ns: u64 = 0,
    backend_ready_ns: u64 = 0,
    input_ready_ns: u64 = 0,
    first_visible_ns: u64 = 0,
    services_started_ns: u64 = 0,
    login_to_compositor_ns: u64 = 0,
    login_to_visible_ns: u64 = 0,
    reveal_done_ns: u64 = 0,
};

pub const InhibitorData = struct {
    surface_ptr: usize,
    window_id: ?u64 = null,
    app_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    is_active: bool,
    reason: ?[]const u8 = null,
};

pub const IdleStateResult = struct {
    enabled: bool,
    state: []const u8,
    blank_after_seconds: u32,
    suspend_after_seconds: u32,
    idle_ms: i64,
    is_inhibited: bool,
    inhibitor_count: usize,
    inhibitors: []const InhibitorData,
    suspend_request_count: u32,
};

pub const CaptureSessionData = struct {
    output: ?[]const u8 = null,
    window_id: ?u64 = null,
};

pub const CaptureIndicatorData = struct {
    output: []const u8,
    box: RectData = .{},
};

pub const CaptureStateResult = struct {
    supported: bool,
    active_sessions: usize,
    sessions: []const CaptureSessionData,
    last_failure: ?[]const u8 = null,
    indicator: ?CaptureIndicatorData = null,
};

pub const EventFilter = struct {
    events: ?[]const []const u8 = null,
    window_id: ?u64 = null,
    output: ?[]const u8 = null,
};

pub const NightLightPhase = enum {
    off,
    day,
    to_night,
    night,
    to_day,
};

pub const NightLightOutputStatus = enum {
    neutral,
    pending,
    applied,
    unsupported,
    rejected,
    disabled,
};

pub const NightLightOutputData = struct {
    name: []const u8,
    gamma_size: usize,
    night_light: bool,
    gamma: f32,
    temperature: u16,
    status: NightLightOutputStatus,
};

pub const NightLightResult = struct {
    enabled: bool,
    schedule: []const u8,
    phase: NightLightPhase,
    temperature: u16,
    next_change_unix: ?i64 = null,
    clock_overridden: bool,
    outputs: []const NightLightOutputData,
};

pub const GesturePhase = enum { begin, update, end };

pub const OutputConfigPatch = @import("config").output_config.Patch;

pub const MoveWindowToParams = struct {
    id: u64,
    x: i32 = 0,
    y: i32 = 0,
    output: ?[]const u8 = null,

    pub fn jsonStringify(self: MoveWindowToParams, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("x");
        try jws.write(self.x);
        try jws.objectField("y");
        try jws.write(self.y);
        if (self.output) |output| {
            try jws.objectField("output");
            try jws.write(output);
        }
        try jws.endObject();
    }
};

pub const KeyboardLayoutsData = struct {
    names: []const []const u8 = &.{},
    current_idx: ?u32 = null,
};

pub const LayoutTarget = union(enum) { next, prev, index: u32 };

/// One keyboard layout ("xkb") or Fcitx input method ("fcitx").
pub const InputSourceData = struct {
    kind: []const u8,
    id: []const u8,
    name: []const u8,
    label: []const u8,
};

pub const InputSourcesData = struct {
    sources: []const InputSourceData = &.{},
    active: ?u32 = null,
    /// The active keyboard layout's index among the sources.
    active_layout: ?u32 = null,
    fcitx_running: bool = false,
};

pub const ConfigLoadedEvent = struct {
    seq: u64,
    generation: u64,
    failed: bool,
    error_name: ?[]const u8 = null,
};

pub const ThemeToken = struct { name: []const u8, color: ?[4]f32 = null, number: ?f32 = null, text: ?[]const u8 = null, boolean: ?bool = null };
pub const ThemeTokens = struct {
    entries: []const ThemeToken,
    pub fn jsonStringify(self: ThemeTokens, jws: anytype) !void {
        try jws.beginObject();
        for (self.entries) |token| {
            try jws.objectField(token.name);
            if (token.color) |color| try jws.write(color) else if (token.number) |number| try jws.write(number) else if (token.boolean) |boolean| try jws.write(boolean) else try jws.write(token.text);
        }
        try jws.endObject();
    }
};

pub const ServiceMode = enum { on, deferred, @"on-demand", disabled };
pub const ServiceData = struct {
    name: []const u8,
    description: []const u8,
    active: []const u8,
    sub: []const u8,
    startup: []const u8,
    trigger: []const u8,
    activation_us: ?u64,
    editable: bool,
};
pub const ServicesResult = struct {
    available: bool,
    loading: bool,
    analyzing: bool,
    timing_available: bool,
    action_pending: bool,
    boot_us: ?u64,
    status: []const u8,
    supported_modes: []const []const u8 = &.{ "on", "on-demand", "disabled" },
    services: []const ServiceData,
};
pub const SoundEventData = struct { name: []const u8, enabled: bool, available: bool, path: ?[]const u8 };
pub const SoundsResult = struct { theme: []const u8, enabled: bool, player_available: bool, events: []const SoundEventData };
pub const WallpaperResult = struct {
    configured: []const u8,
    resolved_path: ?[]const u8,
    displayed_path: ?[]const u8,
    loading: bool,
    failed: bool,
    width: ?u32,
    height: ?u32,
};
pub const ProcessData = struct {
    pid: i32,
    app_id: []const u8,
    window_ids: []const u64,
    running: bool = false,
    start_ticks: ?u64 = null,
    cpu_percent: ?f64 = null,
    rss_bytes: ?u64 = null,
};
pub const ProcessesResult = struct {
    scope: []const u8 = "window_apps",
    sample_ms: u32 = 200,
    cpu_convention: []const u8 = "100 percent per logical CPU",
    processes: []const ProcessData,
};
