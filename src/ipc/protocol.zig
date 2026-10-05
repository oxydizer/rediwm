pub const commands = @import("commands.zig");
const std = @import("std");
const output_transform = @import("config").output_transform;

pub const parseOutputTransform = output_transform.parseName;
pub const outputTransformName = output_transform.name;

pub const BufferWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: BufferWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: BufferWriter, byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }

    pub fn print(self: BufferWriter, comptime fmt_str: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, fmt_str, args)) |formatted| {
            try self.list.appendSlice(self.allocator, formatted);
        } else |err| switch (err) {
            error.NoSpaceLeft => {
                const formatted = try std.fmt.allocPrint(self.allocator, fmt_str, args);
                defer self.allocator.free(formatted);
                try self.list.appendSlice(self.allocator, formatted);
            },
        }
    }
};

pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,

    pub fn stringify(self: RequestId, writer: anytype) !void {
        switch (self) {
            .integer => |i| try writer.print("{d}", .{i}),
            .string => |s| try writer.print("{f}", .{std.json.fmt(s, .{})}),
        }
    }
};

pub const ParsedEnvelope = struct {
    id: ?RequestId = null,
    request: Request,
};

pub const RectData = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

pub const WindowSandboxData = struct {
    engine: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    instance_id: ?[]const u8 = null,
};

pub const WindowData = struct {
    id: u64,
    zoom_percent: u8 = 100,
    title: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    sandbox: ?WindowSandboxData = null,
    pid: ?i32 = null,
    is_focused: bool,
    is_urgent: bool = false,
    is_minimized: bool,
    is_maximized: bool,
    workspace_id: ?u64 = null,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    backend: []const u8 = "xdg",
    x11_class: ?[]const u8 = null,
    x11_instance: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    description: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    placeholder: ?bool = null,
    tab_group: ?u64 = null,
    tab_active: bool = true,

    pub fn jsonStringify(self: WindowData, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("title");
        try jws.write(self.title);
        try jws.objectField("app_id");
        try jws.write(self.app_id);
        try jws.objectField("sandbox");
        try jws.write(self.sandbox);
        try jws.objectField("pid");
        try jws.write(self.pid);
        try jws.objectField("is_focused");
        try jws.write(self.is_focused);
        try jws.objectField("is_urgent");
        try jws.write(self.is_urgent);
        try jws.objectField("is_minimized");
        try jws.write(self.is_minimized);
        try jws.objectField("is_maximized");
        try jws.write(self.is_maximized);
        try jws.objectField("workspace_id");
        try jws.write(self.workspace_id);
        try jws.objectField("x");
        try jws.write(self.x);
        try jws.objectField("y");
        try jws.write(self.y);
        try jws.objectField("width");
        try jws.write(self.width);
        try jws.objectField("height");
        try jws.write(self.height);
        try jws.objectField("zoom_percent");
        try jws.write(self.zoom_percent);
        try jws.objectField("backend");
        try jws.write(self.backend);
        try jws.objectField("x11_class");
        try jws.write(self.x11_class);
        try jws.objectField("x11_instance");
        try jws.write(self.x11_instance);
        inline for (.{ "tag", "description", "content_type" }) |field| {
            if (@field(self, field)) |value| {
                try jws.objectField(field);
                try jws.write(value);
            }
        }
        if (self.tab_group) |group| {
            try jws.objectField("tab_group");
            try jws.write(group);
            try jws.objectField("tab_active");
            try jws.write(self.tab_active);
        }
        if (self.placeholder) |ph| {
            if (ph) {
                try jws.objectField("placeholder");
                try jws.write(true);
            }
        }
        try jws.endObject();
    }
};

pub const OutputData = struct {
    name: []const u8,
    make: ?[]const u8 = null,
    model: ?[]const u8 = null,
    enabled: bool,
    x: i32,
    y: i32,
    logical_width: i32,
    logical_height: i32,
    bottom_exclusion: i32 = 64,
    buffer_width: i32,
    buffer_height: i32,
    transform: []const u8,
    scale: f32,
    refresh_hz: f32,
    is_focused: bool,
};

pub const WorkspaceData = struct {
    id: u64,
    name: ?[]const u8 = null,
    is_focused: bool = false,
};

pub const ScreenshotParams = struct {
    output: ?[]const u8 = null,
    window_id: ?u64 = null,
    mode: ?[]const u8 = null,
    include_cursor: bool = false,
    path: ?[]const u8 = null,
    crop: ?RectData = null,
    crop_space: ?[]const u8 = null, // "logical" | "device"
};

pub const ScreenshotResult = struct {
    width: u32,
    height: u32,
    format: []const u8 = "png",
    data: ?[]const u8 = null,
    path: ?[]const u8 = null,
    output_name: []const u8,
    capture_mode: []const u8,
    frame_seq: u64,
    crop_applied: ?RectData = null,
};

pub const SinkInputData = struct {
    index: u32,
    name: []const u8,
    app_id: []const u8,
    pid: u32,
    volume: f32,
    muted: bool,
};

pub const AudioStateData = struct {
    master_volume: f32,
    master_muted: bool,
    default_sink: []const u8,
    streams: []const SinkInputData,
};

pub const PanelStatsData = struct {
    paints: u64,
    allocated_bytes: u64,
    reused_bytes: u64,
    paint_ns: u64,
};

pub const AnimationData = struct {
    site: []const u8,
    value: f32,
    velocity: f32,
    target: f32,
    settled: bool,
    curve: []const u8,
};

pub const CameraData = struct {
    x: i32,
    y: i32,
    max_x: i32,
    max_y: i32,
    zoom_percent: u16 = 100,
};

pub const PanelStateData = struct {
    state: []const u8, // "opening" | "open" | "closing"
    progress: f32 = 1.0,
    is_settled: bool = true,
    box: RectData = .{},
    search_text: ?[]const u8 = null,
    category: ?[]const u8 = null,
    selected_index: ?i32 = null,
    result_count: ?usize = null,
};

pub const ShellStateData = struct {
    polkit_dialog: ?PanelStateData = null,
    start_menu: ?PanelStateData = null,
    control_center: ?PanelStateData = null,
    power_menu: ?PanelStateData = null,
    taskbar_count: usize = 0,
};

pub const TaskbarChipData = struct {
    window_id: u64,
    title: []const u8,
    box: RectData,
    is_active: bool,
    is_urgent: bool = false,
};

pub const TaskbarItemData = struct {
    name: []const u8,
    visible: bool,
    box: ?RectData,
};

pub const TaskbarData = struct {
    output: []const u8,
    box: RectData,
    start_button_box: RectData,
    right_items: []const TaskbarItemData,
    app_tray: []const TaskbarItemData = &.{},
    tray_menu: ?RectData = null,
    chips: []const TaskbarChipData,
};

pub const ShellDetailResult = struct {
    polkit_dialog: ?PanelStateData = null,
    start_menu: ?PanelStateData = null,
    control_center: ?PanelStateData = null,
    power_menu: ?PanelStateData = null,
    taskbars: []const TaskbarData,
};

pub const ModifiersData = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
    caps_lock: bool = false,
};

pub const InputStateResult = struct {
    pointer_x: f64,
    pointer_y: f64,
    pointer_focused_window_id: ?u64 = null,
    keyboard_focused_window_id: ?u64 = null,
    modifiers: ModifiersData = .{},
    held_buttons: []const u32,
    held_keys: []const u32,
    cursor_mode: []const u8,
    cursor_source: []const u8 = "default",
    cursor_name: ?[]const u8 = "default",
    grabbed_window_id: ?u64 = null,
    resize_edges: ?[]const u8 = null,
    has_active_sequence: bool = false,
};

pub const HitTestResult = struct {
    target_type: []const u8,
    window_id: ?u64 = null,
    widget: ?[]const u8 = null,
    local_x: f64,
    local_y: f64,
    layout_x: f64,
    layout_y: f64,
    output: ?[]const u8 = null,
    occluded_by: ?[]const u8 = null,
};

pub const WindowDebugResult = struct {
    id: u64,
    title: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    pid: ?i32 = null,
    client_box: RectData,
    chrome_box: RectData,
    titlebar_height: i32,
    footer_height: i32,
    frame_border: i32,
    frame_radius: f32,
    decoration_mode: []const u8,
    minimized: bool,
    maximized: bool,
    fullscreen: bool,
    is_resizing: bool,
    zoom_percent: u8,
    effective_zoom: f64 = 1,
    zoom_boosted: bool = false,
    source_box: struct { x: f64, y: f64, width: f64, height: f64 },
    buffer_width: i32,
    buffer_height: i32,
    buffer_scale: f32,
    buffer_transform: []const u8,
    configure_serial: u32,
    ack_serial: u32,
    outputs: []const []const u8,
    skirt_fill: ?[4]f32 = null,
    edge_sample: []const u8 = "uninitialized",
};

pub const OpenRulesData = struct {
    output: ?[]const u8 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    center: ?bool = null,
    width: ?u32 = null,
    height: ?u32 = null,
    maximized: ?bool = null,
    fullscreen: ?bool = null,
    focus: ?bool = null,
    depth: ?u8 = null,
};

pub const LiveRulesData = struct {
    opacity: ?f32 = null,
    effective_opacity: ?f32 = null,
    decorations: ?[]const u8 = null,
    skip_taskbar: ?bool = null,
};

pub const GetWindowRulesResult = struct {
    window_id: u64,
    matched_rules: []const u32,
    open: OpenRulesData,
    live: LiveRulesData,
    resolved_before_app_id: bool,
};

pub const MatchWindowRulesResult = struct {
    matched_rules: []const u32,
    open: OpenRulesData,
    live: LiveRulesData,
};

pub const MatchWindowRulesParams = struct {
    app_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    x11_class: ?[]const u8 = null,
    x11_instance: ?[]const u8 = null,
    backend: ?[]const u8 = null,
    dialog: ?bool = null,
};

pub const SceneNodeData = struct {
    id: usize,
    role: []const u8,
    node_type: []const u8,
    enabled: bool,
    x: i32,
    y: i32,
    box: ?RectData = null,
    children_count: usize = 0,
};

pub const SceneTreeResult = struct {
    nodes: []const SceneNodeData,
    total_nodes: usize,
};

pub const LayerSurfaceData = struct {
    namespace: []const u8,
    output: []const u8,
    layer: []const u8,
    exclusive_zone: i32,
    keyboard_interactive: bool,
    mapped: bool,
    box: RectData,
};

pub const LayerSurfacesResult = struct {
    surfaces: []const LayerSurfaceData,
};

pub const WidgetNodeData = struct {
    id: usize,
    role: []const u8,
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    parent_index: ?usize = null,
    semantic_id: ?[]const u8 = null,
    label: ?[]const u8 = null,
    box: RectData,
    global_box: ?RectData = null,
    is_focused: bool = false,
    is_disabled: bool = false,
    visible: bool = true,
    clipped: bool = false,
    checked: ?bool = null,
    on: ?bool = null,
    value: ?f64 = null,
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    selected_index: ?usize = null,
    open: ?bool = null,
    selected: ?bool = null,
    text_length: ?usize = null,
    scroll_offset: ?f64 = null,
    content_size: ?f64 = null,
};

pub const WidgetTreeResult = struct {
    panel: []const u8,
    widgets: []const WidgetNodeData,
};

pub const PanelData = struct {
    name: []const u8,
    open: bool,
    box: ?RectData = null,
};

pub const ListPanelsResult = struct {
    panels: []const PanelData,
};

pub const FractionCoord = struct {
    x: f64 = 0.5,
    y: f64 = 0.5,
};

pub const ClickWidgetParams = struct {
    path: []const u8,
    button: ?u32 = null,
    at: FractionCoord = .{},
};

pub const HoverWidgetParams = struct {
    path: []const u8,
    at: FractionCoord = .{},
};

pub const PointData = struct {
    x: i32,
    y: i32,
};

pub const WidgetPointResult = struct {
    point: PointData,
    x: i32,
    y: i32,
};

pub const ConfigStatusResult = struct {
    config_path: ?[]const u8 = null,
    generation: u64,
    theme_path: ?[]const u8 = null,
    keybinds_count: usize,
    last_reload_result: []const u8,
    last_reload_error: ?[]const u8 = null,
};

pub const RuntimeInfoResult = struct {
    compositor: []const u8 = "rediwm",
    version: []const u8 = "0.1.0",
    wlroots_version: []const u8 = "0.20",
    backend: []const u8,
    renderer: []const u8,
    outputs_count: usize,
    audio_available: bool,
    session_id: []const u8,
    xwayland_display: ?[]const u8 = null,
    xwayland_enabled: bool = false,
    xwayland_native_scaling: bool = false,
    xwayland_scale: f64 = 1,
    xwayland_scale_pending: ?f64 = null,
    current_desktop: []const u8 = "rediwm",
    nested: bool = false,
};

pub const CommandDesc = struct {
    name: []const u8,
    kind: []const u8, // "query" | "action"
    description: []const u8,
    params_schema: []const u8,
    units: ?[]const u8 = null,
};

pub const DescribeIPCResult = struct {
    protocol_version: []const u8 = "1",
    build_version: []const u8 = "0.1.0",
    backend: []const u8,
    renderer: []const u8,
    commands: []const CommandDesc,
    unavailable_reasons: []const []const u8,
};

pub const GetStateResult = struct {
    seq: u64,
    session_id: []const u8,
    windows: []const WindowData,
    outputs: []const OutputData,
    camera: CameraData,
    focused_window_id: ?u64 = null,
    shell: ShellStateData,
    workspaces: []const WorkspaceData,
};

pub const ToastData = struct {
    id: u32,
    app_name: []const u8 = "",
    summary: []const u8 = "",
    body: []const u8 = "",
    app_icon: []const u8 = "",
    urgency: u8 = 1,
    resident: bool = false,
    transient: bool = false,
    expire_at_ms: ?i64 = null,
    paused: bool = false,
    closing: bool = false,
};

pub const NotificationRecordData = struct {
    id: u32,
    app_name: []const u8 = "",
    summary: []const u8 = "",
    body: []const u8 = "",
    app_icon: []const u8 = "",
    urgency: u8 = 1,
    time_ms: i64 = 0,
    closed: bool = false,
    close_reason: ?u32 = null,
};

pub const GetNotificationsResult = struct {
    toasts: []const ToastData = &.{},
    history: []const NotificationRecordData = &.{},
    dnd: bool = false,
};

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
    target: []const u8, // "titlebar", "skirt", "start_menu", "control_center", "power_menu", "taskbar"
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

pub const ConfigLoadedEvent = struct {
    seq: u64,
    generation: u64,
    failed: bool,
    error_name: ?[]const u8 = null,
};

pub const ThemeToken = struct { name: []const u8, color: ?[4]f32 = null, number: ?f32 = null, text: ?[]const u8 = null };
pub const ThemeTokens = struct {
    entries: []const ThemeToken,
    pub fn jsonStringify(self: ThemeTokens, jws: anytype) !void {
        try jws.beginObject();
        for (self.entries) |token| {
            try jws.objectField(token.name);
            if (token.color) |color| try jws.write(color) else if (token.number) |number| try jws.write(number) else try jws.write(token.text);
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

pub const Action = union(enum) {
    set_service_mode: struct { service: []const u8, mode: ServiceMode },
    play_sound: struct { event: []const u8 },
    set_wallpaper: struct { path: []const u8, persist: bool = true },
    set_accent_color: struct { color: [4]f32, persist: bool = true },
    set_night_light: struct { enabled: ?bool = null, temperature: ?u16 = null, persist: bool = true },
    switch_layout: LayoutTarget,
    open_appearance,
    focus_window: struct { id: u64 },
    close_window: struct { id: ?u64 = null },
    move_window_to: MoveWindowToParams,
    spawn: struct { argv: []const []const u8 },
    move_cursor: struct { x: i32, y: i32, output: ?[]const u8 = null },
    move_cursor_relative: struct { dx: i32, dy: i32 },
    pointer_button: struct { button: u32, pressed: bool },
    click: struct { button: u32 = 0x110 },
    scroll: struct { dx: f64, dy: f64 },
    pinch: struct {
        phase: GesturePhase,
        scale: f64 = 1,
        dx: f64 = 0,
        dy: f64 = 0,
        rotation: f64 = 0,
        fingers: u32 = 2,
        cancelled: bool = false,
    },
    swipe: struct {
        phase: GesturePhase,
        dx: f64 = 0,
        dy: f64 = 0,
        fingers: u32 = 2,
        cancelled: bool = false,
    },
    key: struct { keycode: u32, pressed: bool },
    key_press: struct { key: []const u8 },
    type_text: struct { text: []const u8 },
    drag: struct { from_x: i32, from_y: i32, to_x: i32, to_y: i32, button: u32 = 0x110, output: ?[]const u8 = null },
    screenshot: ScreenshotParams,
    stop_all_capture,
    get_camera,
    set_camera: struct { x: i32, y: i32 },
    reset_camera,
    set_zoom: struct { percent: u8 },
    set_master_volume: struct { volume: f32 },
    toggle_mute,
    set_app_volume: struct { index: u32, volume: f32 },
    set_app_mute: struct { index: u32, muted: bool },
    get_audio_state,
    get_panel_stats,
    get_animations,
    reset_panel_stats,
    set_anim_time: struct { ms: ?i64 },
    open_start_menu,
    open_control_center,
    open_power_menu,

    // Phase 1 waits
    wait_for: WaitForParams,
    wait_for_frame: WaitForFrameParams,

    // Phase 3 captures/stats
    dump_buffer: DumpBufferParams,
    sample_pixels: SamplePixelsParams,
    get_performance_stats,
    reset_performance_stats,
    get_idle_state,
    set_output_config: OutputConfigPatch,
    set_idle_config: struct { enabled: ?bool = null, blank_after_seconds: ?u32 = null, suspend_after_seconds: ?u32 = null },
    advance_idle_time: struct { seconds: u32 },

    // Phase 4 targeted actions
    maximize_window: struct { id: u64 },
    minimize_window: struct { id: u64 },
    restore_window: struct { id: u64 },
    fullscreen_window: struct { id: u64, output: ?[]const u8 = null },
    stop_xwayland,
    set_window_size: struct { id: u64, width: i32, height: i32 },
    set_window_zoom: struct { id: u64, percent: u8 },
    close_panel: struct { panel: []const u8 },
    reload_config,
    restart_shell,
    launch_app: struct { desktop_id: []const u8, uris: []const []const u8 = &.{} },
    get_night_light,
    set_night_light_clock: struct { unix_seconds: ?i64 = null },
    dismiss_notification: struct { id: u32, reason: ?u32 = null },
    invoke_notification_action: struct { id: u32, action_key: []const u8 },
    set_dnd: struct { enabled: bool },
    clear_notifications,
    undo,
    click_widget: ClickWidgetParams,
    hover_widget: HoverWidgetParams,
};

pub const Request = union(enum) {
    get_services,
    get_sounds,
    get_wallpaper,
    get_theme,
    get_processes,
    get_keyboard_layouts,
    version,
    capabilities,
    describe_ipc,
    windows,
    outputs,
    focused_window,
    event_stream,
    event_stream_filtered: EventFilter,
    workspaces,
    get_state,
    get_window_debug: struct { id: u64 },
    get_shell_state: struct { output: ?[]const u8 = null },
    get_input_state,
    get_text_input,
    hit_test: struct { x: i32, y: i32, output: ?[]const u8 = null },
    get_scene_tree: struct { max_depth: ?u32 = null },
    get_layer_surfaces,
    get_widget_tree: struct { panel: []const u8 },
    get_config_status,
    get_runtime_info,
    get_idle_state,
    get_capture_state,
    get_window_rules: struct { id: u64 },
    match_window_rules: MatchWindowRulesParams,
    get_night_light,
    get_notifications,
    list_panels,
    action: Action,
};

pub const TextInputResult = struct {
    input_method: struct { connected: bool = false, active: bool = false, keyboard_grab: bool = false, popup_count: usize = 0 } = .{},
    focused: ?struct {
        window_id: ?u64 = null,
        enabled: bool,
        features: u32,
        content_purpose: u32,
        content_hint: u32,
        cursor_rectangle: RectData,
        surrounding_bytes: usize,
        pending: bool,
    } = null,
    popups: []const struct { mapped: bool, visible: bool, x: i32, y: i32, width: i32, height: i32, output: ?[]const u8 } = &.{},
};

pub const ResponsePayload = union(enum) {
    services: ServicesResult,
    sounds: SoundsResult,
    wallpaper: WallpaperResult,
    theme: struct { tokens: ThemeTokens, path: ?[]const u8, dark_mode: bool },
    processes: ProcessesResult,
    service_mode: struct { accepted: bool = true, service: []const u8, mode: ServiceMode },
    sound_playback: struct { accepted: bool = true, event: []const u8, pid: ?i32 },
    version: []const u8,
    capabilities: []const []const u8,
    describe_ipc: DescribeIPCResult,
    windows: []const WindowData,
    outputs: []const OutputData,
    focused_window: ?WindowData,
    workspaces: []const WorkspaceData,
    screenshot: ScreenshotResult,
    camera: struct { x: i32, y: i32, max_x: i32, max_y: i32, zoom_percent: u16 = 100 },
    audio_state: AudioStateData,
    panel_stats: PanelStatsData,
    state: GetStateResult,
    wait_for: WaitForResult,
    wait_for_frame: WaitForFrameResult,
    window_debug: WindowDebugResult,
    shell_state: ShellDetailResult,
    input_state: InputStateResult,
    hit_test: HitTestResult,
    scene_tree: SceneTreeResult,
    layer_surfaces: LayerSurfacesResult,
    widget_tree: WidgetTreeResult,
    config_status: ConfigStatusResult,
    runtime_info: RuntimeInfoResult,
    dump_buffer: DumpBufferResult,
    sample_pixels: SamplePixelsResult,
    performance_stats: PerformanceStatsResult,
    idle_state: IdleStateResult,
    capture_state: CaptureStateResult,
    window_rules: GetWindowRulesResult,
    match_window_rules: MatchWindowRulesResult,
    night_light: NightLightResult,
    notifications: GetNotificationsResult,
    animations: []const AnimationData,
    handled,
    async_pending,
    text_input: TextInputResult,
    keyboard_layouts: KeyboardLayoutsData,
    list_panels: ListPanelsResult,
    click_widget: WidgetPointResult,
    hover_widget: WidgetPointResult,
};

pub const Response = union(enum) {
    ok: ResponsePayload,
    err: []const u8,
};

pub const StateSnapshot = struct {
    seq: u64,
    session_id: []const u8 = "",
    time_ms: i64 = 0,
    windows: []const WindowData,
    outputs: []const OutputData,
    workspaces: []const WorkspaceData,
    focused_window_id: ?u64 = null,
    camera: ?CameraData = null,
    shell: ?ShellStateData = null,
};

pub const PolkitPromptEvent = struct { seq: u64, time_ms: i64 = 0 };

pub const Event = union(enum) {
    window_urgency_changed: struct { seq: u64, id: u64, urgent: bool },
    keyboard_layouts_changed: struct { seq: u64, keyboard_layouts: KeyboardLayoutsData },
    keyboard_layout_switched: struct { seq: u64, idx: u32 },
    config_loaded: ConfigLoadedEvent,
    polkit_prompt_opened: PolkitPromptEvent,
    polkit_prompt_closed: PolkitPromptEvent,
    state_snapshot: StateSnapshot,
    window_opened: struct { seq: u64, time_ms: i64 = 0, session_id: []const u8 = "", window: WindowData },
    window_closed: struct { seq: u64, time_ms: i64 = 0, session_id: []const u8 = "", id: u64 },
    window_changed: struct { seq: u64, time_ms: i64 = 0, session_id: []const u8 = "", window: WindowData },
    window_focused: struct { seq: u64, time_ms: i64 = 0, session_id: []const u8 = "", id: ?u64 },
    window_moved: struct { seq: u64, time_ms: i64 = 0, session_id: []const u8 = "", id: u64, x: i32, y: i32 },
    output_added: struct { seq: u64, time_ms: i64 = 0, session_id: []const u8 = "", output: OutputData },
    output_changed: struct { seq: u64, time_ms: i64 = 0, session_id: []const u8 = "", output: OutputData },
    output_removed: struct { seq: u64, time_ms: i64 = 0, session_id: []const u8 = "", name: []const u8 },
    camera_changed: struct { seq: u64, time_ms: i64 = 0, session_id: []const u8 = "", x: i32, y: i32, max_x: i32, max_y: i32, zoom_percent: u16 = 100 },
    notification_shown: struct { seq: u64 = 0, time_ms: i64 = 0, session_id: []const u8 = "", id: u32, app_name: []const u8 = "", summary: []const u8 = "", urgency: u8 = 1 },
    notification_closed: struct { seq: u64 = 0, time_ms: i64 = 0, session_id: []const u8 = "", id: u32, reason: u32 = 0 },
    notification_action: struct { seq: u64 = 0, time_ms: i64 = 0, session_id: []const u8 = "", id: u32, action_key: []const u8 },
    launch_started: struct { seq: u64 = 0, time_ms: i64 = 0, session_id: []const u8 = "", desktop_id: []const u8 = "", pid: ?i32 = null, placeholder_id: ?u64 = null },
    launch_matched: struct { seq: u64 = 0, time_ms: i64 = 0, session_id: []const u8 = "", desktop_id: []const u8 = "", window_id: u64, pid: ?i32 = null },
    launch_timeout: struct { seq: u64 = 0, time_ms: i64 = 0, session_id: []const u8 = "", desktop_id: []const u8 = "", pid: ?i32 = null },
    widget_changed: struct {
        seq: u64 = 0,
        time_ms: i64 = 0,
        session_id: []const u8 = "",
        panel: []const u8,
        path: ?[]const u8 = null,
        name: ?[]const u8 = null,
        widget: WidgetNodeData,
    },
};

pub const ParseError = error{
    InvalidRequest,
    InvalidEnvelope,
    InvalidRequestId,
    OutOfMemory,
};

fn parseU64(val: std.json.Value) ParseError!u64 {
    return switch (val) {
        .integer => |i| if (i < 0) return error.InvalidRequest else @as(u64, @intCast(i)),
        else => error.InvalidRequest,
    };
}

fn parseOptU64(val: std.json.Value) ParseError!?u64 {
    return switch (val) {
        .null => null,
        .integer => |i| if (i < 0) return error.InvalidRequest else @as(u64, @intCast(i)),
        else => error.InvalidRequest,
    };
}

fn parseU32(val: std.json.Value) ParseError!u32 {
    return switch (val) {
        .integer => |i| if (i < 0 or i > std.math.maxInt(u32)) return error.InvalidRequest else @as(u32, @intCast(i)),
        else => error.InvalidRequest,
    };
}

fn parseOptU32(val: std.json.Value) ParseError!?u32 {
    return switch (val) {
        .null => null,
        .integer => |i| if (i < 0 or i > std.math.maxInt(u32)) return error.InvalidRequest else @as(u32, @intCast(i)),
        else => error.InvalidRequest,
    };
}

fn parseOptI64(val: std.json.Value) ParseError!?i64 {
    return switch (val) {
        .null => null,
        .integer => |i| i,
        else => error.InvalidRequest,
    };
}

fn parseI32(val: std.json.Value) ParseError!i32 {
    return switch (val) {
        .integer => |i| if (i < std.math.minInt(i32) or i > std.math.maxInt(i32)) return error.InvalidRequest else @as(i32, @intCast(i)),
        else => error.InvalidRequest,
    };
}

fn parseGesturePhase(val: std.json.Value) ParseError!GesturePhase {
    if (val != .string) return error.InvalidRequest;
    return std.meta.stringToEnum(GesturePhase, val.string) orelse error.InvalidRequest;
}

fn parseF64(val: std.json.Value) ParseError!f64 {
    const f: f64 = switch (val) {
        .float => |fl| fl,
        .integer => |i| @floatFromInt(i),
        else => return error.InvalidRequest,
    };
    if (!std.math.isFinite(f)) return error.InvalidRequest;
    return f;
}

fn parseFractionCoord(val: std.json.Value) ParseError!FractionCoord {
    switch (val) {
        .float, .integer => {
            const f = try parseF64(val);
            return .{ .x = f, .y = 0.5 };
        },
        .array => |arr| {
            if (arr.items.len != 2) return error.InvalidRequest;
            const x = try parseF64(arr.items[0]);
            const y = try parseF64(arr.items[1]);
            return .{ .x = x, .y = y };
        },
        .object => |obj| {
            const x_val = obj.get("x") orelse return error.InvalidRequest;
            const y_val = obj.get("y") orelse return error.InvalidRequest;
            const x = try parseF64(x_val);
            const y = try parseF64(y_val);
            return .{ .x = x, .y = y };
        },
        else => return error.InvalidRequest,
    }
}

fn parseVolume(val: std.json.Value) ParseError!f32 {
    const volume: f32 = switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => return error.InvalidRequest,
    };
    if (!std.math.isFinite(volume) or volume < 0 or volume > 1) return error.InvalidRequest;
    return volume;
}

fn parseRect(val: std.json.Value) ParseError!RectData {
    if (val != .object) return error.InvalidRequest;
    const x_val = val.object.get("x") orelse return error.InvalidRequest;
    const y_val = val.object.get("y") orelse return error.InvalidRequest;
    const w_val = val.object.get("width") orelse return error.InvalidRequest;
    const h_val = val.object.get("height") orelse return error.InvalidRequest;
    return .{
        .x = try parseI32(x_val),
        .y = try parseI32(y_val),
        .width = try parseI32(w_val),
        .height = try parseI32(h_val),
    };
}

pub fn parseRequest(allocator: std.mem.Allocator, json_text: []const u8) ParseError!Request {
    const env = try parseEnvelope(allocator, json_text);
    return env.request;
}

pub fn parseEnvelope(allocator: std.mem.Allocator, json_text: []const u8) ParseError!ParsedEnvelope {
    const trimmed = std.mem.trim(u8, json_text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidRequest;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();

    return parseEnvelopeValue(allocator, parsed.value);
}

// IPC v1 has exactly one request envelope and case-sensitive command names.
fn parseEnvelopeValue(allocator: std.mem.Allocator, val: std.json.Value) ParseError!ParsedEnvelope {
    if (val != .object) return error.InvalidEnvelope;
    const obj = val.object;
    for (obj.keys()) |key| {
        if (!std.mem.eql(u8, key, "version") and !std.mem.eql(u8, key, "command") and
            !std.mem.eql(u8, key, "params") and !std.mem.eql(u8, key, "id")) return error.InvalidEnvelope;
    }
    const version = obj.get("version") orelse return error.InvalidEnvelope;
    if (version != .integer or version.integer != 1) return error.InvalidEnvelope;
    const command = obj.get("command") orelse return error.InvalidEnvelope;
    if (command != .string) return error.InvalidEnvelope;
    var params: ?std.json.ObjectMap = null;
    if (obj.get("params")) |value| {
        if (value != .object) return error.InvalidRequest;
        params = value.object;
    }
    var id: ?RequestId = null;
    if (obj.get("id")) |value| {
        id = switch (value) {
            .integer => |n| if (n >= 0) .{ .integer = n } else return error.InvalidRequestId,
            .string => |str| if (str.len <= 256)
                .{ .string = allocator.dupe(u8, str) catch return error.OutOfMemory }
            else
                return error.InvalidRequestId,
            else => return error.InvalidRequestId,
        };
    }
    errdefer if (id) |request_id| switch (request_id) {
        .string => |str| allocator.free(str),
        .integer => {},
    };
    const request = if (commands.lookup(.query, command.string)) |tag|
        try parseQueryParams(allocator, tag, params)
    else if (commands.lookup(.action, command.string)) |tag|
        Request{ .action = try parseActionParams(allocator, tag, params) }
    else
        return error.InvalidRequest;
    return .{ .id = id, .request = request };
}

fn emptyAction(comptime name: []const u8) Action {
    if (@FieldType(Action, name) != void) @compileError("missing action parameter parser: " ++ name);
    return @unionInit(Action, name, {});
}

fn emptyRequest(comptime name: []const u8) Request {
    if (@hasField(Request, name)) {
        if (@FieldType(Request, name) != void) @compileError("missing query parameter parser: " ++ name);
        return @unionInit(Request, name, {});
    }
    return .{ .action = emptyAction(name) };
}

const wait_aliases = .{
    .menu_opened = &[_][]const u8{"start_menu_opened"},
    .menu_closed = &[_][]const u8{"start_menu_closed"},
};

fn waitNames(comptime name: []const u8) []const []const u8 {
    return &[_][]const u8{name} ++ if (@hasField(@TypeOf(wait_aliases), name)) @field(wait_aliases, name) else &[_][]const u8{};
}

comptime {
    @setEvalBranchQuota(20_000);
    for (std.meta.fields(@TypeOf(wait_aliases))) |f| {
        if (!@hasField(WaitCondition, f.name)) @compileError("unknown wait alias target: " ++ f.name);
    }
    var names: []const []const u8 = &.{};
    for (std.meta.fields(WaitCondition)) |field| {
        for (waitNames(field.name)) |name| {
            for (names) |previous| {
                if (std.mem.eql(u8, previous, name)) @compileError("duplicate wait name: " ++ name);
            }
            names = names ++ .{name};
        }
    }
}

fn parseWidgetStateValue(allocator: std.mem.Allocator, val: std.json.Value) ParseError!WidgetStateValue {
    switch (val) {
        .bool => |b| return .{ .boolean = b },
        .integer => |i| return .{ .number = @floatFromInt(i) },
        .float => |f| return .{ .number = f },
        .string => |s| {
            if (s.len > 4096) return error.InvalidRequest;
            const str = allocator.dupe(u8, s) catch return error.OutOfMemory;
            return .{ .string = str };
        },
        .null => return .null_value,
        else => return error.InvalidRequest,
    }
}

fn parseWaitCondition(allocator: std.mem.Allocator, val: std.json.Value) ParseError!WaitCondition {
    const Tag = std.meta.Tag(WaitCondition);
    var selected: ?Tag = null;
    var value: std.json.Value = .null;
    switch (val) {
        .string => |s| {
            inline for (std.meta.fields(WaitCondition)) |field| {
                if (field.type == void) {
                    inline for (comptime waitNames(field.name)) |name| {
                        if (std.mem.eql(u8, s, name)) return @unionInit(WaitCondition, field.name, {});
                    }
                }
            }
            return error.InvalidRequest;
        },
        .object => |obj| {
            // Historically all no-payload conditions take precedence over
            // payload conditions, independently of object insertion order.
            inline for (.{ true, false }) |no_payload| {
                inline for (std.meta.fields(WaitCondition)) |field| {
                    if ((field.type == void) == no_payload) {
                        inline for (comptime waitNames(field.name)) |name| {
                            if (selected == null) {
                                if (obj.get(name)) |v| {
                                    selected = @field(Tag, field.name);
                                    value = v;
                                }
                            }
                        }
                    }
                }
            }
        },
        else => return error.InvalidRequest,
    }
    switch (selected orelse return error.InvalidRequest) {
        .window_mapped => {
            const wm = value;
            var id: ?u64 = null;
            var app_id: ?[]const u8 = null;
            var title: ?[]const u8 = null;
            if (wm == .object) {
                if (wm.object.get("id")) |id_v| id = try parseOptU64(id_v);
                if (wm.object.get("app_id")) |app_v| {
                    if (app_v == .string) {
                        if (app_v.string.len > 256) return error.InvalidRequest;
                        app_id = allocator.dupe(u8, app_v.string) catch return error.OutOfMemory;
                    } else if (app_v != .null) return error.InvalidRequest;
                }
                if (wm.object.get("title")) |t_v| {
                    if (t_v == .string) {
                        if (t_v.string.len > 512) return error.InvalidRequest;
                        title = allocator.dupe(u8, t_v.string) catch return error.OutOfMemory;
                    } else if (t_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .window_mapped = .{ .id = id, .app_id = app_id, .title = title } };
        },
        .window_closed => {
            const wc = value;
            if (wc != .object) return error.InvalidRequest;
            const id_v = wc.object.get("id") orelse return error.InvalidRequest;
            return .{ .window_closed = .{ .id = try parseU64(id_v) } };
        },
        .window_focused => {
            const wf = value;
            var id: ?u64 = null;
            if (wf == .object) {
                if (wf.object.get("id")) |id_v| id = try parseOptU64(id_v);
            }
            return .{ .window_focused = .{ .id = id } };
        },
        .window_geometry_settled => {
            const wg = value;
            if (wg != .object) return error.InvalidRequest;
            const id_v = wg.object.get("id") orelse return error.InvalidRequest;
            return .{ .window_geometry_settled = .{ .id = try parseU64(id_v) } };
        },
        .output_frame => {
            const of = value;
            var out_name: ?[]const u8 = null;
            if (of == .object) {
                if (of.object.get("output")) |out_v| {
                    if (out_v == .string) {
                        if (out_v.string.len > 256) return error.InvalidRequest;
                        out_name = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                    } else if (out_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .output_frame = .{ .output = out_name } };
        },
        .notification_count => {
            const nc = value;
            var count: ?usize = null;
            var app_name: ?[]const u8 = null;
            var summary: ?[]const u8 = null;
            if (nc == .object) {
                if (nc.object.get("count")) |cnt_v| {
                    if (cnt_v == .integer and cnt_v.integer >= 0) {
                        count = @intCast(cnt_v.integer);
                    } else return error.InvalidRequest;
                }
                if (nc.object.get("app_name")) |app_v| {
                    if (app_v == .string) {
                        if (app_v.string.len > 256) return error.InvalidRequest;
                        app_name = allocator.dupe(u8, app_v.string) catch return error.OutOfMemory;
                    } else if (app_v != .null) return error.InvalidRequest;
                }
                if (nc.object.get("summary")) |sum_v| {
                    if (sum_v == .string) {
                        if (sum_v.string.len > 512) return error.InvalidRequest;
                        summary = allocator.dupe(u8, sum_v.string) catch return error.OutOfMemory;
                    } else if (sum_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .notification_count = .{ .count = count, .app_name = app_name, .summary = summary } };
        },
        .notification_closed => {
            const nc = value;
            if (nc != .object) return error.InvalidRequest;
            const id_v = nc.object.get("id") orelse return error.InvalidRequest;
            return .{ .notification_closed = .{ .id = try parseU32(id_v) } };
        },
        .notification_action => {
            const na = value;
            if (na != .object) return error.InvalidRequest;
            const id_v = na.object.get("id") orelse return error.InvalidRequest;
            var action_key: ?[]const u8 = null;
            if (na.object.get("action_key")) |ak_v| {
                if (ak_v == .string) {
                    if (ak_v.string.len > 256) return error.InvalidRequest;
                    action_key = allocator.dupe(u8, ak_v.string) catch return error.OutOfMemory;
                } else if (ak_v != .null) return error.InvalidRequest;
            }
            return .{ .notification_action = .{ .id = try parseU32(id_v), .action_key = action_key } };
        },
        .launch_started => {
            const ls = value;
            var desktop_id: ?[]const u8 = null;
            if (ls == .object) {
                if (ls.object.get("desktop_id")) |d_v| {
                    if (d_v == .string) {
                        if (d_v.string.len > 256) return error.InvalidRequest;
                        desktop_id = allocator.dupe(u8, d_v.string) catch return error.OutOfMemory;
                    } else if (d_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .launch_started = .{ .desktop_id = desktop_id } };
        },
        .launch_matched => {
            const lm = value;
            var desktop_id: ?[]const u8 = null;
            var window_id: ?u64 = null;
            if (lm == .object) {
                if (lm.object.get("desktop_id")) |d_v| {
                    if (d_v == .string) {
                        if (d_v.string.len > 256) return error.InvalidRequest;
                        desktop_id = allocator.dupe(u8, d_v.string) catch return error.OutOfMemory;
                    } else if (d_v != .null) return error.InvalidRequest;
                }
                if (lm.object.get("window_id")) |w_v| window_id = try parseOptU64(w_v);
            }
            return .{ .launch_matched = .{ .desktop_id = desktop_id, .window_id = window_id } };
        },
        .launch_timeout => {
            const lt = value;
            var desktop_id: ?[]const u8 = null;
            if (lt == .object) {
                if (lt.object.get("desktop_id")) |d_v| {
                    if (d_v == .string) {
                        if (d_v.string.len > 256) return error.InvalidRequest;
                        desktop_id = allocator.dupe(u8, d_v.string) catch return error.OutOfMemory;
                    } else if (d_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .launch_timeout = .{ .desktop_id = desktop_id } };
        },
        .widget_present => {
            var path: ?[]const u8 = null;
            if (value == .string) {
                if (value.string.len == 0 or value.string.len > 4096) return error.InvalidRequest;
                path = try allocator.dupe(u8, value.string);
            } else if (value == .object) {
                if (value.object.get("path")) |pv| {
                    if (pv == .string and pv.string.len > 0 and pv.string.len <= 4096) {
                        path = try allocator.dupe(u8, pv.string);
                    } else if (pv != .null) return error.InvalidRequest;
                }
            }
            return .{ .widget_present = .{ .path = path orelse return error.InvalidRequest } };
        },
        .widget_absent => {
            var path: ?[]const u8 = null;
            if (value == .string) {
                if (value.string.len == 0 or value.string.len > 4096) return error.InvalidRequest;
                path = try allocator.dupe(u8, value.string);
            } else if (value == .object) {
                if (value.object.get("path")) |pv| {
                    if (pv == .string and pv.string.len > 0 and pv.string.len <= 4096) {
                        path = try allocator.dupe(u8, pv.string);
                    } else if (pv != .null) return error.InvalidRequest;
                }
            }
            return .{ .widget_absent = .{ .path = path orelse return error.InvalidRequest } };
        },
        .widget_state => {
            if (value != .object) return error.InvalidRequest;
            const path_v = value.object.get("path") orelse return error.InvalidRequest;
            if (path_v != .string or path_v.string.len == 0 or path_v.string.len > 4096) return error.InvalidRequest;
            const field_v = value.object.get("field") orelse return error.InvalidRequest;
            if (field_v != .string or field_v.string.len == 0 or field_v.string.len > 256) return error.InvalidRequest;
            const eq_v = value.object.get("equals") orelse return error.InvalidRequest;
            const equals = try parseWidgetStateValue(allocator, eq_v);
            errdefer freeWidgetStateValue(allocator, equals);
            const path = allocator.dupe(u8, path_v.string) catch return error.OutOfMemory;
            errdefer allocator.free(path);
            const field = allocator.dupe(u8, field_v.string) catch return error.OutOfMemory;
            return .{ .widget_state = .{
                .path = path,
                .field = field,
                .equals = equals,
            } };
        },
        .panel_settled => {
            var panel: ?[]const u8 = null;
            if (value == .string) {
                if (value.string.len == 0 or value.string.len > 64) return error.InvalidRequest;
                panel = try allocator.dupe(u8, value.string);
            } else if (value == .object) {
                if (value.object.get("panel")) |pv| {
                    if (pv == .string and pv.string.len > 0 and pv.string.len <= 64) {
                        panel = try allocator.dupe(u8, pv.string);
                    } else if (pv != .null) return error.InvalidRequest;
                }
            }
            return .{ .panel_settled = .{ .panel = panel orelse return error.InvalidRequest } };
        },
        inline else => |tag| {
            if (@FieldType(WaitCondition, @tagName(tag)) != void)
                @compileError("missing wait parameter parser: " ++ @tagName(tag));
            return @unionInit(WaitCondition, @tagName(tag), {});
        },
    }
}

fn parseWaitForParams(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Action {
    const cond_val = obj.get("condition") orelse return error.InvalidRequest;
    const condition = try parseWaitCondition(allocator, cond_val);
    var timeout_ms: u64 = 5000;
    if (obj.get("timeout_ms")) |t_val| timeout_ms = try parseU64(t_val);
    return .{ .wait_for = .{ .condition = condition, .timeout_ms = timeout_ms } };
}

fn parseWaitForFrameParams(allocator: std.mem.Allocator, params: ?std.json.ObjectMap) ParseError!Action {
    var output: ?[]const u8 = null;
    var timeout_ms: u64 = 5000;
    if (params) |p| {
        if (p.get("output")) |out_v| {
            if (out_v == .string) {
                if (out_v.string.len > 256) return error.InvalidRequest;
                output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
            } else if (out_v != .null) return error.InvalidRequest;
        }
        if (p.get("timeout_ms")) |t_val| timeout_ms = try parseU64(t_val);
    }
    return .{ .wait_for_frame = .{ .output = output, .timeout_ms = timeout_ms } };
}

fn parseDumpBufferParams(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Action {
    const tgt_val = obj.get("target") orelse return error.InvalidRequest;
    if (tgt_val != .string or tgt_val.string.len > 64) return error.InvalidRequest;
    const target = allocator.dupe(u8, tgt_val.string) catch return error.OutOfMemory;
    var win_id: ?u64 = null;
    if (obj.get("window_id")) |win_v| win_id = try parseOptU64(win_v);
    var output: ?[]const u8 = null;
    if (obj.get("output")) |out_v| {
        if (out_v == .string) {
            if (out_v.string.len > 256) return error.InvalidRequest;
            output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
        } else if (out_v != .null) return error.InvalidRequest;
    }
    return .{ .dump_buffer = .{ .target = target, .window_id = win_id, .output = output } };
}

fn parseSamplePixelsParams(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Action {
    const x_val = obj.get("x") orelse return error.InvalidRequest;
    const y_val = obj.get("y") orelse return error.InvalidRequest;
    var output: ?[]const u8 = null;
    if (obj.get("output")) |out_v| {
        if (out_v == .string) {
            if (out_v.string.len > 256) return error.InvalidRequest;
            output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
        } else if (out_v != .null) return error.InvalidRequest;
    }
    var width: u32 = 1;
    var height: u32 = 1;
    if (obj.get("width")) |w_val| width = try parseU32(w_val);
    if (obj.get("height")) |h_val| height = try parseU32(h_val);
    if (width == 0 or width > 1024 or height == 0 or height > 1024) return error.InvalidRequest;
    return .{ .sample_pixels = .{
        .output = output,
        .x = try parseI32(x_val),
        .y = try parseI32(y_val),
        .width = width,
        .height = height,
    } };
}

fn parseMatchWindowRules(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Request {
    var params: MatchWindowRulesParams = .{};
    if (obj.get("app_id")) |v| {
        if (v == .string) params.app_id = allocator.dupe(u8, v.string) catch return error.OutOfMemory else if (v != .null) return error.InvalidRequest;
    }
    if (obj.get("title")) |v| {
        if (v == .string) params.title = allocator.dupe(u8, v.string) catch return error.OutOfMemory else if (v != .null) return error.InvalidRequest;
    }
    if (obj.get("x11_class") orelse obj.get("class")) |v| {
        if (v == .string) params.x11_class = allocator.dupe(u8, v.string) catch return error.OutOfMemory else if (v != .null) return error.InvalidRequest;
    }
    if (obj.get("x11_instance") orelse obj.get("instance")) |v| {
        if (v == .string) params.x11_instance = allocator.dupe(u8, v.string) catch return error.OutOfMemory else if (v != .null) return error.InvalidRequest;
    }
    if (obj.get("backend")) |v| {
        if (v == .string) params.backend = allocator.dupe(u8, v.string) catch return error.OutOfMemory else if (v != .null) return error.InvalidRequest;
    }
    if (obj.get("dialog")) |v| {
        if (v == .bool) params.dialog = v.bool else if (v != .null) return error.InvalidRequest;
    }
    return .{ .match_window_rules = params };
}

fn parseQueryParams(allocator: std.mem.Allocator, command_tag: commands.RouteTag(.query), params: ?std.json.ObjectMap) ParseError!Request {
    switch (command_tag) {
        .get_window_debug => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("window_id") orelse p.get("id") orelse return error.InvalidRequest;
            return .{ .get_window_debug = .{ .id = try parseU64(id_v) } };
        },
        .get_window_rules => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("window_id") orelse p.get("id") orelse return error.InvalidRequest;
            return .{ .get_window_rules = .{ .id = try parseU64(id_v) } };
        },
        .match_window_rules => {
            if (params) |p| {
                return parseMatchWindowRules(allocator, p);
            }
            return .{ .match_window_rules = .{} };
        },
        .get_shell_state => {
            var output: ?[]const u8 = null;
            if (params) |p| {
                if (p.get("output")) |out_v| {
                    if (out_v == .string) {
                        if (out_v.string.len > 256) return error.InvalidRequest;
                        output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                    } else if (out_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .get_shell_state = .{ .output = output } };
        },

        .hit_test => {
            const p = params orelse return error.InvalidRequest;
            const x_v = p.get("x") orelse return error.InvalidRequest;
            const y_v = p.get("y") orelse return error.InvalidRequest;
            var output: ?[]const u8 = null;
            if (p.get("output")) |out_v| {
                if (out_v == .string) {
                    if (out_v.string.len > 256) return error.InvalidRequest;
                    output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                } else if (out_v != .null) return error.InvalidRequest;
            }
            return .{ .hit_test = .{
                .x = try parseI32(x_v),
                .y = try parseI32(y_v),
                .output = output,
            } };
        },
        .get_scene_tree => {
            var max_depth: ?u32 = null;
            if (params) |p| {
                if (p.get("max_depth")) |md_v| max_depth = try parseOptU32(md_v);
            }
            return .{ .get_scene_tree = .{ .max_depth = max_depth } };
        },

        .get_widget_tree => {
            const p = params orelse return error.InvalidRequest;
            const panel_v = p.get("panel") orelse return error.InvalidRequest;
            if (panel_v != .string or panel_v.string.len > 64) return error.InvalidRequest;
            const panel = allocator.dupe(u8, panel_v.string) catch return error.OutOfMemory;
            return .{ .get_widget_tree = .{ .panel = panel } };
        },

        .list_panels => {
            return .list_panels;
        },

        .event_stream => {
            if (params) |p| {
                var filter = EventFilter{};
                if (p.get("window_id")) |win_v| filter.window_id = try parseOptU64(win_v);
                if (p.get("output")) |out_v| {
                    if (out_v == .string) {
                        if (out_v.string.len > 256) return error.InvalidRequest;
                        filter.output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                    } else if (out_v != .null) return error.InvalidRequest;
                }
                const ev_list_v = p.get("events") orelse p.get("kinds");
                if (ev_list_v) |k_v| {
                    if (k_v == .array) {
                        var kinds_list = std.ArrayList([]const u8).empty;
                        for (k_v.array.items) |item| {
                            if (item == .string) {
                                const str = allocator.dupe(u8, item.string) catch return error.OutOfMemory;
                                kinds_list.append(allocator, str) catch return error.OutOfMemory;
                            }
                        }
                        filter.events = kinds_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
                    }
                }
                return .{ .event_stream_filtered = filter };
            }
            return .event_stream;
        },
        inline else => |tag| return emptyRequest(@tagName(tag)),
    }
}

fn requiredText(allocator: std.mem.Allocator, p: std.json.ObjectMap, key: []const u8, max: usize) ParseError![]const u8 {
    const v = p.get(key) orelse return error.InvalidRequest;
    if (v != .string or v.string.len == 0 or v.string.len > max or std.mem.indexOfScalar(u8, v.string, 0) != null) return error.InvalidRequest;
    return allocator.dupe(u8, v.string);
}
fn persistParam(p: std.json.ObjectMap) ParseError!bool {
    const v = p.get("persist") orelse return true;
    if (v != .bool) return error.InvalidRequest;
    return v.bool;
}

fn parseActionParams(allocator: std.mem.Allocator, command_tag: commands.RouteTag(.action), params: ?std.json.ObjectMap) ParseError!Action {
    switch (command_tag) {
        .switch_layout => {
            const p = params orelse return error.InvalidRequest;
            const value = p.get("layout") orelse return error.InvalidRequest;
            const target: LayoutTarget = switch (value) {
                .string => |name| if (std.ascii.eqlIgnoreCase(name, "next")) .next else if (std.ascii.eqlIgnoreCase(name, "prev")) .prev else return error.InvalidRequest,
                .integer => |idx| .{ .index = std.math.cast(u32, idx) orelse return error.InvalidRequest },
                else => return error.InvalidRequest,
            };
            return .{ .switch_layout = target };
        },
        .focus_window => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            return .{ .focus_window = .{ .id = try parseU64(id_v) } };
        },
        .close_window => {
            var id: ?u64 = null;
            if (params) |p| {
                if (p.get("id")) |id_v| id = try parseOptU64(id_v);
                if (id == null) {
                    if (p.get("window_id")) |id_v| id = try parseOptU64(id_v);
                }
            }
            return .{ .close_window = .{ .id = id } };
        },
        .move_window_to => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            const x_v = p.get("x");
            const y_v = p.get("y");
            const output_v = p.get("output");
            if ((x_v == null) != (y_v == null) and output_v == null) return error.InvalidRequest;
            var output: ?[]const u8 = null;
            if (x_v == null) {
                if (output_v) |value| {
                    if (value != .string or value.string.len == 0) return error.InvalidRequest;
                    output = try allocator.dupe(u8, value.string);
                }
            }
            if (x_v == null and output == null) return error.InvalidRequest;
            return .{ .move_window_to = .{
                .id = try parseU64(id_v),
                .x = if (x_v) |value| try parseI32(value) else 0,
                .y = if (y_v) |value| try parseI32(value) else 0,
                .output = output,
            } };
        },
        .spawn => {
            const p = params orelse return error.InvalidRequest;
            const argv_val = p.get("argv") orelse return error.InvalidRequest;
            if (argv_val != .array or argv_val.array.items.len > 256) return error.InvalidRequest;
            var list = std.ArrayList([]const u8).empty;
            for (argv_val.array.items) |item| {
                if (item != .string or item.string.len > 4096) return error.InvalidRequest;
                const str = allocator.dupe(u8, item.string) catch return error.OutOfMemory;
                list.append(allocator, str) catch return error.OutOfMemory;
            }
            return .{ .spawn = .{ .argv = list.toOwnedSlice(allocator) catch return error.OutOfMemory } };
        },
        .move_cursor => {
            const p = params orelse return error.InvalidRequest;
            const x_v = p.get("x") orelse return error.InvalidRequest;
            const y_v = p.get("y") orelse return error.InvalidRequest;
            var output: ?[]const u8 = null;
            if (p.get("output")) |out_v| {
                if (out_v == .string) {
                    if (out_v.string.len > 256) return error.InvalidRequest;
                    output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                } else if (out_v != .null) return error.InvalidRequest;
            }
            return .{ .move_cursor = .{
                .x = try parseI32(x_v),
                .y = try parseI32(y_v),
                .output = output,
            } };
        },
        .move_cursor_relative => {
            const p = params orelse return error.InvalidRequest;
            const dx_v = p.get("dx") orelse return error.InvalidRequest;
            const dy_v = p.get("dy") orelse return error.InvalidRequest;
            return .{ .move_cursor_relative = .{
                .dx = try parseI32(dx_v),
                .dy = try parseI32(dy_v),
            } };
        },
        .pointer_button => {
            const p = params orelse return error.InvalidRequest;
            const b_v = p.get("button") orelse return error.InvalidRequest;
            const pr_v = p.get("pressed") orelse return error.InvalidRequest;
            if (pr_v != .bool) return error.InvalidRequest;
            return .{ .pointer_button = .{ .button = try parseU32(b_v), .pressed = pr_v.bool } };
        },
        .click => {
            var btn: u32 = 0x110;
            if (params) |p| {
                if (p.get("button")) |b_v| btn = try parseU32(b_v);
            }
            return .{ .click = .{ .button = btn } };
        },
        .scroll => {
            const p = params orelse return error.InvalidRequest;
            const dx_v = p.get("dx") orelse return error.InvalidRequest;
            const dy_v = p.get("dy") orelse return error.InvalidRequest;
            return .{ .scroll = .{ .dx = try parseF64(dx_v), .dy = try parseF64(dy_v) } };
        },
        .pinch => {
            const p = params orelse return error.InvalidRequest;
            const phase = try parseGesturePhase(p.get("phase") orelse return error.InvalidRequest);
            var scale: f64 = 1;
            var dx: f64 = 0;
            var dy: f64 = 0;
            var rotation: f64 = 0;
            var fingers: u32 = 2;
            var cancelled = false;
            if (p.get("scale")) |v| scale = try parseF64(v);
            if (p.get("dx")) |v| dx = try parseF64(v);
            if (p.get("dy")) |v| dy = try parseF64(v);
            if (p.get("rotation")) |v| rotation = try parseF64(v);
            if (p.get("fingers")) |v| fingers = try parseU32(v);
            if (p.get("cancelled")) |v| {
                if (v != .bool) return error.InvalidRequest;
                cancelled = v.bool;
            }
            return .{ .pinch = .{
                .phase = phase,
                .scale = scale,
                .dx = dx,
                .dy = dy,
                .rotation = rotation,
                .fingers = fingers,
                .cancelled = cancelled,
            } };
        },
        .swipe => {
            const p = params orelse return error.InvalidRequest;
            const phase = try parseGesturePhase(p.get("phase") orelse return error.InvalidRequest);
            var dx: f64 = 0;
            var dy: f64 = 0;
            var fingers: u32 = 2;
            var cancelled = false;
            if (p.get("dx")) |v| dx = try parseF64(v);
            if (p.get("dy")) |v| dy = try parseF64(v);
            if (p.get("fingers")) |v| fingers = try parseU32(v);
            if (p.get("cancelled")) |v| {
                if (v != .bool) return error.InvalidRequest;
                cancelled = v.bool;
            }
            return .{ .swipe = .{
                .phase = phase,
                .dx = dx,
                .dy = dy,
                .fingers = fingers,
                .cancelled = cancelled,
            } };
        },
        .key => {
            const p = params orelse return error.InvalidRequest;
            const kc_v = p.get("keycode") orelse return error.InvalidRequest;
            const pr_v = p.get("pressed") orelse return error.InvalidRequest;
            if (pr_v != .bool) return error.InvalidRequest;
            return .{ .key = .{ .keycode = try parseU32(kc_v), .pressed = pr_v.bool } };
        },
        .key_press => {
            const p = params orelse return error.InvalidRequest;
            const k_v = p.get("key") orelse return error.InvalidRequest;
            if (k_v != .string or k_v.string.len > 64) return error.InvalidRequest;
            const key = allocator.dupe(u8, k_v.string) catch return error.OutOfMemory;
            return .{ .key_press = .{ .key = key } };
        },
        .type_text => {
            const p = params orelse return error.InvalidRequest;
            const t_v = p.get("text") orelse return error.InvalidRequest;
            if (t_v != .string or t_v.string.len > 65536) return error.InvalidRequest;
            const text = allocator.dupe(u8, t_v.string) catch return error.OutOfMemory;
            return .{ .type_text = .{ .text = text } };
        },
        .drag => {
            const p = params orelse return error.InvalidRequest;
            const fx_val = p.get("from_x") orelse return error.InvalidRequest;
            const fy_val = p.get("from_y") orelse return error.InvalidRequest;
            const tx_val = p.get("to_x") orelse return error.InvalidRequest;
            const ty_val = p.get("to_y") orelse return error.InvalidRequest;
            var button: u32 = 0x110;
            if (p.get("button")) |b_val| button = try parseU32(b_val);
            var output: ?[]const u8 = null;
            if (p.get("output")) |out_v| {
                if (out_v == .string) {
                    if (out_v.string.len > 256) return error.InvalidRequest;
                    output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                } else if (out_v != .null) return error.InvalidRequest;
            }
            return .{ .drag = .{
                .from_x = try parseI32(fx_val),
                .from_y = try parseI32(fy_val),
                .to_x = try parseI32(tx_val),
                .to_y = try parseI32(ty_val),
                .button = button,
                .output = output,
            } };
        },
        .screenshot => {
            var output: ?[]const u8 = null;
            var window_id: ?u64 = null;
            var mode: ?[]const u8 = null;
            var include_cursor: bool = false;
            var path: ?[]const u8 = null;
            var crop: ?RectData = null;
            var crop_space: ?[]const u8 = null;

            if (params) |p| {
                if (p.get("output")) |out_v| {
                    if (out_v == .string) {
                        if (out_v.string.len > 256) return error.InvalidRequest;
                        output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                    } else if (out_v != .null) return error.InvalidRequest;
                }
                if (p.get("window_id")) |win_v| window_id = try parseOptU64(win_v);
                if (p.get("mode")) |m_v| {
                    if (m_v == .string) {
                        if (m_v.string.len > 64) return error.InvalidRequest;
                        mode = allocator.dupe(u8, m_v.string) catch return error.OutOfMemory;
                    } else if (m_v != .null) return error.InvalidRequest;
                }
                if (p.get("include_cursor")) |ic_v| {
                    if (ic_v == .bool) include_cursor = ic_v.bool else return error.InvalidRequest;
                }
                if (p.get("path")) |pv| {
                    if (pv == .string) {
                        if (pv.string.len > 4096) return error.InvalidRequest;
                        path = allocator.dupe(u8, pv.string) catch return error.OutOfMemory;
                    } else if (pv != .null) return error.InvalidRequest;
                }
                if (p.get("crop")) |cr_v| {
                    if (cr_v != .null) crop = try parseRect(cr_v);
                }
                if (p.get("crop_space")) |cs_v| {
                    if (cs_v == .string) {
                        if (cs_v.string.len > 64) return error.InvalidRequest;
                        crop_space = allocator.dupe(u8, cs_v.string) catch return error.OutOfMemory;
                    } else if (cs_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .screenshot = .{
                .output = output,
                .window_id = window_id,
                .mode = mode,
                .include_cursor = include_cursor,
                .path = path,
                .crop = crop,
                .crop_space = crop_space,
            } };
        },

        .set_camera => {
            const p = params orelse return error.InvalidRequest;
            const x_v = p.get("x") orelse return error.InvalidRequest;
            const y_v = p.get("y") orelse return error.InvalidRequest;
            return .{ .set_camera = .{
                .x = try parseI32(x_v),
                .y = try parseI32(y_v),
            } };
        },

        .set_zoom => {
            const p = params orelse return error.InvalidRequest;
            const pct_v = p.get("percent") orelse return error.InvalidRequest;
            if (pct_v != .integer) return error.InvalidRequest;
            if (pct_v.integer != 100 and pct_v.integer != 85 and pct_v.integer != 70 and pct_v.integer != 55) return error.InvalidRequest;
            return .{ .set_zoom = .{ .percent = @intCast(pct_v.integer) } };
        },
        .set_master_volume => {
            const p = params orelse return error.InvalidRequest;
            const vol_v = p.get("volume") orelse return error.InvalidRequest;
            return .{ .set_master_volume = .{ .volume = try parseVolume(vol_v) } };
        },

        .set_app_volume => {
            const p = params orelse return error.InvalidRequest;
            const idx_v = p.get("index") orelse return error.InvalidRequest;
            const vol_v = p.get("volume") orelse return error.InvalidRequest;
            return .{ .set_app_volume = .{
                .index = try parseU32(idx_v),
                .volume = try parseVolume(vol_v),
            } };
        },
        .set_app_mute => {
            const p = params orelse return error.InvalidRequest;
            const idx_v = p.get("index") orelse return error.InvalidRequest;
            const m_v = p.get("muted") orelse return error.InvalidRequest;
            if (m_v != .bool) return error.InvalidRequest;
            return .{ .set_app_mute = .{
                .index = try parseU32(idx_v),
                .muted = m_v.bool,
            } };
        },

        .set_anim_time => {
            const p = params orelse return error.InvalidRequest;
            const ms_val = p.get("ms") orelse return error.InvalidRequest;
            const ms: ?i64 = switch (ms_val) {
                .integer => |i| i,
                .null => null,
                else => return error.InvalidRequest,
            };
            return .{ .set_anim_time = .{ .ms = ms } };
        },

        .wait_for => {
            return parseWaitForParams(allocator, params orelse return error.InvalidRequest);
        },
        .wait_for_frame => {
            return parseWaitForFrameParams(allocator, params);
        },
        .dump_buffer => {
            return parseDumpBufferParams(allocator, params orelse return error.InvalidRequest);
        },
        .sample_pixels => {
            return parseSamplePixelsParams(allocator, params orelse return error.InvalidRequest);
        },

        .set_output_config => {
            const p = params orelse return error.InvalidRequest;
            const name = p.get("output") orelse return error.InvalidRequest;
            if (name != .string or name.string.len == 0) return error.InvalidRequest;
            var patch = OutputConfigPatch{ .output = try allocator.dupe(u8, name.string) };
            inline for (.{ "width", "height", "refresh_mhz", "x", "y" }) |field| {
                if (p.get(field)) |value| @field(patch, field) = try parseI32(value);
            }
            if (p.get("scale")) |value| {
                if (value == .string and std.mem.eql(u8, value.string, "auto")) {
                    patch.auto_scale = true;
                } else {
                    const scale = try parseF64(value);
                    if (scale < 1 or scale > 3) return error.InvalidRequest;
                    patch.scale = @floatCast(scale);
                }
            }
            if (p.get("position")) |value| {
                if (value != .string or !std.mem.eql(u8, value.string, "auto")) return error.InvalidRequest;
                patch.auto_position = true;
            }
            if (p.get("enabled")) |value| {
                if (value != .bool) return error.InvalidRequest;
                patch.enabled = value.bool;
            }
            if (p.get("primary")) |value| {
                if (value != .bool) return error.InvalidRequest;
                patch.primary = value.bool;
            }
            if (p.get("transform")) |value| {
                if (value != .string) return error.InvalidRequest;
                patch.transform = output_transform.parseName(value.string) catch return error.InvalidRequest;
            }
            patch.validate() catch return error.InvalidRequest;
            return .{ .set_output_config = patch };
        },
        .set_idle_config => {
            const p = params orelse return error.InvalidRequest;
            var enabled: ?bool = null;
            var blank: ?u32 = null;
            var suspend_sec: ?u32 = null;
            if (p.get("enabled")) |ev| {
                if (ev == .bool) enabled = ev.bool else return error.InvalidRequest;
            }
            if (p.get("blank_after_seconds")) |bv| blank = try parseU32(bv);
            if (p.get("suspend_after_seconds")) |sv| suspend_sec = try parseU32(sv);
            return .{ .set_idle_config = .{
                .enabled = enabled,
                .blank_after_seconds = blank,
                .suspend_after_seconds = suspend_sec,
            } };
        },
        .advance_idle_time => {
            const p = params orelse return error.InvalidRequest;
            const sec_v = p.get("seconds") orelse return error.InvalidRequest;
            return .{ .advance_idle_time = .{ .seconds = try parseU32(sec_v) } };
        },
        .set_service_mode => {
            const p = params orelse return error.InvalidRequest;
            const service = try requiredText(allocator, p, "service", 255);
            if (!std.mem.endsWith(u8, service, ".service") or std.mem.indexOfAny(u8, service, "/\\\n\r") != null or service[0] == '-') return error.InvalidRequest;
            const mode = p.get("mode") orelse return error.InvalidRequest;
            if (mode != .string) return error.InvalidRequest;
            return .{ .set_service_mode = .{ .service = service, .mode = std.meta.stringToEnum(ServiceMode, mode.string) orelse return error.InvalidRequest } };
        },
        .play_sound => {
            const p = params orelse return error.InvalidRequest;
            return .{ .play_sound = .{ .event = try requiredText(allocator, p, "event", 128) } };
        },
        .set_wallpaper => {
            const p = params orelse return error.InvalidRequest;
            const value = p.get("path") orelse return error.InvalidRequest;
            if (value != .string or value.string.len > 4096 or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.InvalidRequest;
            return .{ .set_wallpaper = .{ .path = try allocator.dupe(u8, value.string), .persist = try persistParam(p) } };
        },
        .set_accent_color => {
            const p = params orelse return error.InvalidRequest;
            const value = p.get("color") orelse return error.InvalidRequest;
            if (value != .string or (value.string.len != 7 and value.string.len != 9) or value.string[0] != '#') return error.InvalidRequest;
            var color: [4]f32 = .{ 0, 0, 0, 1 };
            for (0..(value.string.len - 1) / 2) |i| {
                const channel = std.fmt.parseInt(u8, value.string[1 + i * 2 .. 3 + i * 2], 16) catch return error.InvalidRequest;
                color[i] = @as(f32, @floatFromInt(channel)) / 255;
            }
            return .{ .set_accent_color = .{ .color = color, .persist = try persistParam(p) } };
        },
        .set_night_light => {
            const p = params orelse return error.InvalidRequest;
            var enabled: ?bool = null;
            var temperature: ?u16 = null;
            if (p.get("enabled")) |v| {
                if (v != .bool) return error.InvalidRequest;
                enabled = v.bool;
            }
            if (p.get("temperature")) |v| {
                const n = try parseU32(v);
                if (n < 1700 or n > 10000) return error.InvalidRequest;
                temperature = @intCast(n);
            }
            if (enabled == null and temperature == null) return error.InvalidRequest;
            return .{ .set_night_light = .{ .enabled = enabled, .temperature = temperature, .persist = try persistParam(p) } };
        },
        .set_night_light_clock => {
            var sec: ?i64 = null;
            if (params) |p| {
                if (p.get("unix_seconds")) |sv| sec = try parseOptI64(sv);
            }
            return .{ .set_night_light_clock = .{ .unix_seconds = sec } };
        },
        .maximize_window => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            return .{ .maximize_window = .{ .id = try parseU64(id_v) } };
        },
        .minimize_window => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            return .{ .minimize_window = .{ .id = try parseU64(id_v) } };
        },
        .restore_window => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            return .{ .restore_window = .{ .id = try parseU64(id_v) } };
        },
        .fullscreen_window => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            var output: ?[]const u8 = null;
            if (p.get("output")) |out_v| {
                if (out_v == .string) {
                    if (out_v.string.len > 256) return error.InvalidRequest;
                    output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                } else if (out_v != .null) return error.InvalidRequest;
            }
            return .{ .fullscreen_window = .{ .id = try parseU64(id_v), .output = output } };
        },

        .set_window_size => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            const w_v = p.get("width") orelse return error.InvalidRequest;
            const h_v = p.get("height") orelse return error.InvalidRequest;
            return .{ .set_window_size = .{
                .id = try parseU64(id_v),
                .width = try parseI32(w_v),
                .height = try parseI32(h_v),
            } };
        },
        .set_window_zoom => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            const p_v = p.get("percent") orelse return error.InvalidRequest;
            if (p_v != .integer) return error.InvalidRequest;
            if (p_v.integer != 100 and p_v.integer != 85 and p_v.integer != 70 and p_v.integer != 55) return error.InvalidRequest;
            return .{ .set_window_zoom = .{
                .id = try parseU64(id_v),
                .percent = @intCast(p_v.integer),
            } };
        },
        .close_panel => {
            const p = params orelse return error.InvalidRequest;
            const p_v = p.get("panel") orelse return error.InvalidRequest;
            if (p_v != .string or p_v.string.len > 64) return error.InvalidRequest;
            const panel = allocator.dupe(u8, p_v.string) catch return error.OutOfMemory;
            return .{ .close_panel = .{ .panel = panel } };
        },

        .launch_app => {
            const p = params orelse return error.InvalidRequest;
            const d_val = p.get("desktop_id") orelse return error.InvalidRequest;
            if (d_val != .string or d_val.string.len > 256) return error.InvalidRequest;
            const desktop_id = allocator.dupe(u8, d_val.string) catch return error.OutOfMemory;
            var uris: []const []const u8 = &.{};
            if (p.get("uris")) |values| {
                if (values != .array or values.array.items.len > 128) return error.InvalidRequest;
                const list = try allocator.alloc([]const u8, values.array.items.len);
                for (values.array.items, list) |value, *item| {
                    if (value != .string or value.string.len > 8192) return error.InvalidRequest;
                    item.* = try allocator.dupe(u8, value.string);
                }
                uris = list;
            }
            return .{ .launch_app = .{ .desktop_id = desktop_id, .uris = uris } };
        },
        .dismiss_notification => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse return error.InvalidRequest;
            var reason: ?u32 = null;
            if (p.get("reason")) |r_v| reason = try parseOptU32(r_v);
            return .{ .dismiss_notification = .{ .id = try parseU32(id_v), .reason = reason } };
        },
        .invoke_notification_action => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse return error.InvalidRequest;
            const key_v = p.get("action_key") orelse return error.InvalidRequest;
            if (key_v != .string or key_v.string.len > 256) return error.InvalidRequest;
            const action_key = allocator.dupe(u8, key_v.string) catch return error.OutOfMemory;
            return .{ .invoke_notification_action = .{ .id = try parseU32(id_v), .action_key = action_key } };
        },
        .set_dnd => {
            const p = params orelse return error.InvalidRequest;
            const en_v = p.get("enabled") orelse return error.InvalidRequest;
            if (en_v != .bool) return error.InvalidRequest;
            return .{ .set_dnd = .{ .enabled = en_v.bool } };
        },
        .click_widget => {
            const p = params orelse return error.InvalidRequest;
            const path_val = p.get("path") orelse return error.InvalidRequest;
            if (path_val != .string or path_val.string.len == 0) return error.InvalidRequest;
            const path = allocator.dupe(u8, path_val.string) catch return error.OutOfMemory;

            var button: ?u32 = null;
            if (p.get("button")) |b_v| {
                if (b_v != .null) button = try parseU32(b_v);
            }

            var at = FractionCoord{};
            if (p.get("at")) |at_v| {
                if (at_v != .null) at = try parseFractionCoord(at_v);
            }

            return .{ .click_widget = .{
                .path = path,
                .button = button,
                .at = at,
            } };
        },
        .hover_widget => {
            const p = params orelse return error.InvalidRequest;
            const path_val = p.get("path") orelse return error.InvalidRequest;
            if (path_val != .string or path_val.string.len == 0) return error.InvalidRequest;
            const path = allocator.dupe(u8, path_val.string) catch return error.OutOfMemory;

            var at = FractionCoord{};
            if (p.get("at")) |at_v| {
                if (at_v != .null) at = try parseFractionCoord(at_v);
            }

            return .{ .hover_widget = .{
                .path = path,
                .at = at,
            } };
        },
        inline else => |tag| return emptyAction(@tagName(tag)),
    }
}

pub fn stringifyResponse(response: Response, writer: anytype) !void {
    try stringifyResponseWithId(null, response, writer);
}

pub fn stringifyResponseWithId(id: ?RequestId, response: Response, writer: anytype) !void {
    try writer.writeByte('{');
    if (id) |i| {
        try writer.writeAll("\"id\":");
        try i.stringify(writer);
        try writer.writeByte(',');
    }
    switch (response) {
        .ok => |payload| {
            try writer.writeAll("\"Ok\":");
            try stringifyResponsePayload(payload, writer);
        },
        .err => |msg| {
            try writer.writeAll("\"Err\":");
            try writer.print("{f}", .{std.json.fmt(msg, .{})});
        },
    }
    try writer.writeAll("}\n");
}

fn stringifyResponsePayload(payload: ResponsePayload, writer: anytype) !void {
    switch (payload) {
        .version => |v| {
            try writer.writeAll("{\"Version\":");
            try writer.print("{f}", .{std.json.fmt(v, .{})});
            try writer.writeByte('}');
        },
        .keyboard_layouts => |layouts| {
            try writer.print("{{\"KeyboardLayouts\":{f}}}", .{std.json.fmt(layouts, .{})});
        },
        .capabilities => |caps| {
            try writer.writeAll("{\"Capabilities\":");
            try writer.print("{f}", .{std.json.fmt(caps, .{})});
            try writer.writeByte('}');
        },
        .describe_ipc => |d| {
            try writer.writeAll("{\"DescribeIPC\":");
            try writer.print("{f}", .{std.json.fmt(d, .{})});
            try writer.writeByte('}');
        },
        .windows => |wins| {
            try writer.writeAll("{\"Windows\":");
            try writer.print("{f}", .{std.json.fmt(wins, .{})});
            try writer.writeByte('}');
        },
        .outputs => |outs| {
            try writer.writeAll("{\"Outputs\":");
            try stringifyOutputs(outs, writer);
            try writer.writeByte('}');
        },
        .focused_window => |fw| {
            try writer.writeAll("{\"FocusedWindow\":");
            if (fw) |win| {
                try writer.print("{f}", .{std.json.fmt(win, .{})});
            } else {
                try writer.writeAll("null");
            }
            try writer.writeByte('}');
        },
        .workspaces => |ws| {
            try writer.writeAll("{\"Workspaces\":");
            try stringifyWorkspaces(ws, writer);
            try writer.writeByte('}');
        },
        .screenshot => |sr| {
            try writer.writeAll("{\"Screenshot\":");
            try stringifyScreenshotResult(sr, writer);
            try writer.writeByte('}');
        },
        .text_input => |data| {
            try writer.print("{{\"TextInput\":{f}}}", .{std.json.fmt(data, .{})});
        },
        .camera => |cam| {
            try writer.print("{{\"Camera\":{{\"x\":{d},\"y\":{d},\"max_x\":{d},\"max_y\":{d},\"zoom_percent\":{d}}}}}", .{ cam.x, cam.y, cam.max_x, cam.max_y, cam.zoom_percent });
        },
        .audio_state => |a| {
            try writer.writeAll("{\"AudioState\":");
            try stringifyAudioState(a, writer);
            try writer.writeByte('}');
        },
        .panel_stats => |s| {
            try writer.print("{{\"PanelStats\":{{\"paints\":{d},\"allocated_bytes\":{d},\"reused_bytes\":{d},\"paint_ns\":{d}}}}}", .{
                s.paints, s.allocated_bytes, s.reused_bytes, s.paint_ns,
            });
        },
        .animations => |items| {
            try writer.writeAll("{\"Animations\":");
            try stringifyAnimations(items, writer);
            try writer.writeByte('}');
        },
        .state => |st| {
            try writer.writeAll("{\"State\":");
            try stringifyGetState(st, writer);
            try writer.writeByte('}');
        },
        .wait_for => |wf| {
            try writer.writeAll("{\"WaitFor\":");
            try writer.print("{f}", .{std.json.fmt(wf, .{})});
            try writer.writeByte('}');
        },
        .wait_for_frame => |wff| {
            try writer.writeAll("{\"WaitForFrame\":");
            try writer.print("{f}", .{std.json.fmt(wff, .{})});
            try writer.writeByte('}');
        },
        .window_debug => |wd| {
            try writer.writeAll("{\"WindowDebug\":");
            try stringifyWindowDebug(wd, writer);
            try writer.writeByte('}');
        },
        .shell_state => |ss| {
            try writer.writeAll("{\"ShellState\":");
            try stringifyShellDetail(ss, writer);
            try writer.writeByte('}');
        },
        .input_state => |is| {
            try writer.writeAll("{\"InputState\":");
            try writer.print("{f}", .{std.json.fmt(is, .{})});
            try writer.writeByte('}');
        },
        .hit_test => |ht| {
            try writer.writeAll("{\"HitTest\":");
            try writer.print("{f}", .{std.json.fmt(ht, .{})});
            try writer.writeByte('}');
        },
        .scene_tree => |st| {
            try writer.writeAll("{\"SceneTree\":");
            try writer.print("{f}", .{std.json.fmt(st, .{})});
            try writer.writeByte('}');
        },
        .layer_surfaces => |ls| {
            try writer.writeAll("{\"LayerSurfaces\":");
            try writer.print("{f}", .{std.json.fmt(ls, .{})});
            try writer.writeByte('}');
        },
        .widget_tree => |wt| {
            try writer.writeAll("{\"WidgetTree\":");
            try writer.print("{f}", .{std.json.fmt(wt, .{})});
            try writer.writeByte('}');
        },
        .config_status => |cs| {
            try writer.writeAll("{\"ConfigStatus\":");
            try writer.print("{f}", .{std.json.fmt(cs, .{})});
            try writer.writeByte('}');
        },
        .runtime_info => |ri| {
            try writer.writeAll("{\"RuntimeInfo\":");
            try writer.print("{f}", .{std.json.fmt(ri, .{})});
            try writer.writeByte('}');
        },
        .dump_buffer => |db| {
            try writer.writeAll("{\"DumpBuffer\":");
            try stringifyDumpBuffer(db, writer);
            try writer.writeByte('}');
        },
        .sample_pixels => |sp| {
            try writer.writeAll("{\"SamplePixels\":");
            try writer.print("{f}", .{std.json.fmt(sp, .{})});
            try writer.writeByte('}');
        },
        .performance_stats => |ps| {
            try writer.writeAll("{\"PerformanceStats\":");
            try stringifyPerformanceStats(ps, writer);
            try writer.writeByte('}');
        },
        .idle_state => |idls| {
            try writer.writeAll("{\"IdleState\":");
            try writer.print("{f}", .{std.json.fmt(idls, .{})});
            try writer.writeByte('}');
        },
        .capture_state => |cs| {
            try writer.writeAll("{\"CaptureState\":");
            try writer.print("{f}", .{std.json.fmt(cs, .{})});
            try writer.writeByte('}');
        },
        .window_rules => |wr| {
            try writer.writeAll("{\"WindowRules\":");
            try stringifyWindowRules(wr, writer);
            try writer.writeByte('}');
        },
        .match_window_rules => |mwr| {
            try writer.writeAll("{\"MatchWindowRules\":");
            try stringifyMatchWindowRules(mwr, writer);
            try writer.writeByte('}');
        },
        .services => |value| {
            try writer.writeAll("{\"Services\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .sounds => |value| {
            try writer.writeAll("{\"Sounds\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .wallpaper => |value| {
            try writer.writeAll("{\"Wallpaper\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .theme => |value| {
            try writer.writeAll("{\"Theme\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .processes => |value| {
            try writer.writeAll("{\"Processes\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .service_mode => |value| {
            try writer.writeAll("{\"ServiceMode\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .sound_playback => |value| {
            try writer.writeAll("{\"SoundPlayback\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .night_light => |nl| {
            try writer.writeAll("{\"NightLight\":");
            try writer.print("{f}", .{std.json.fmt(nl, .{})});
            try writer.writeByte('}');
        },
        .notifications => |n| {
            try writer.writeAll("{\"Notifications\":");
            try stringifyNotifications(n, writer);
            try writer.writeByte('}');
        },
        .handled => {
            try writer.writeAll("\"Handled\"");
        },
        .async_pending => {
            try writer.writeAll("\"Handled\"");
        },
        .list_panels => |lp| {
            try writer.print("{{\"ListPanels\":{f}}}", .{std.json.fmt(lp, .{})});
        },
        .click_widget => |cw| {
            try writer.print("{{\"ClickWidget\":{f}}}", .{std.json.fmt(cw, .{})});
        },
        .hover_widget => |hw| {
            try writer.print("{{\"HoverWidget\":{f}}}", .{std.json.fmt(hw, .{})});
        },
    }
}

fn stringifySinkInput(si: SinkInputData, writer: anytype) !void {
    try writer.print("{{\"index\":{d},\"name\":{f},\"app_id\":{f},\"pid\":{d},\"volume\":{d},\"muted\":", .{
        si.index, std.json.fmt(si.name, .{}), std.json.fmt(si.app_id, .{}), si.pid, si.volume,
    });
    try writer.writeAll(if (si.muted) "true}" else "false}");
}

fn stringifyAnimations(items: []const AnimationData, writer: anytype) !void {
    try writer.writeByte('[');
    for (items, 0..) |a, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"site\":{f},\"value\":{d},\"velocity\":{d},\"target\":{d},\"settled\":{},\"curve\":{f}}}", .{
            std.json.fmt(a.site, .{}),
            a.value,
            a.velocity,
            a.target,
            a.settled,
            std.json.fmt(a.curve, .{}),
        });
    }
    try writer.writeByte(']');
}

fn stringifyAudioState(a: AudioStateData, writer: anytype) !void {
    try writer.print("{{\"master_volume\":{d},\"master_muted\":", .{a.master_volume});
    try writer.writeAll(if (a.master_muted) "true" else "false");
    try writer.print(",\"default_sink\":{f},\"streams\":[", .{std.json.fmt(a.default_sink, .{})});
    for (a.streams, 0..) |si, i| {
        if (i > 0) try writer.writeByte(',');
        try stringifySinkInput(si, writer);
    }
    try writer.writeAll("]}");
}

fn stringifyScreenshotResult(sr: ScreenshotResult, writer: anytype) !void {
    try writer.print("{{\"width\":{d},\"height\":{d},\"format\":{f},\"data\":", .{ sr.width, sr.height, std.json.fmt(sr.format, .{}) });
    if (sr.data) |d| {
        try writer.print("{f}", .{std.json.fmt(d, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"path\":");
    if (sr.path) |p| {
        try writer.print("{f}", .{std.json.fmt(p, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"output_name\":{f},\"capture_mode\":{f},\"frame_seq\":{d}", .{
        std.json.fmt(sr.output_name, .{}),
        std.json.fmt(sr.capture_mode, .{}),
        sr.frame_seq,
    });
    if (sr.crop_applied) |cr| {
        try writer.print(",\"crop_applied\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ cr.x, cr.y, cr.width, cr.height });
    }
    try writer.writeByte('}');
}

fn stringifyPanelState(ps: PanelStateData, writer: anytype) !void {
    try writer.print("{{\"state\":{f},\"progress\":{d},\"is_settled\":{},\"box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{
        std.json.fmt(ps.state, .{}), ps.progress, ps.is_settled, ps.box.x, ps.box.y, ps.box.width, ps.box.height,
    });
    try writer.writeAll(",\"search_text\":");
    if (ps.search_text) |st| try writer.print("{f}", .{std.json.fmt(st, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"category\":");
    if (ps.category) |c| try writer.print("{f}", .{std.json.fmt(c, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"selected_index\":");
    if (ps.selected_index) |idx| try writer.print("{d}", .{idx}) else try writer.writeAll("null");
    try writer.writeAll(",\"result_count\":");
    if (ps.result_count) |cnt| try writer.print("{d}", .{cnt}) else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn stringifyShellState(res: ShellStateData, writer: anytype) !void {
    try writer.writeAll("{\"start_menu\":");
    if (res.start_menu) |sm| try stringifyPanelState(sm, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"control_center\":");
    if (res.control_center) |cc| try stringifyPanelState(cc, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"power_menu\":");
    if (res.power_menu) |pm| try stringifyPanelState(pm, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"polkit_dialog\":");
    if (res.polkit_dialog) |dialog| try stringifyPanelState(dialog, writer) else try writer.writeAll("null");
    try writer.print(",\"taskbar_count\":{d}}}", .{res.taskbar_count});
}

fn stringifyGetState(res: GetStateResult, writer: anytype) !void {
    try writer.print("{{\"seq\":{d},\"session_id\":{f},\"focused_window_id\":", .{ res.seq, std.json.fmt(res.session_id, .{}) });
    if (res.focused_window_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
    try writer.writeAll(",\"windows\":");
    try writer.print("{f}", .{std.json.fmt(res.windows, .{})});
    try writer.writeAll(",\"outputs\":");
    try stringifyOutputs(res.outputs, writer);
    try writer.print(",\"camera\":{{\"x\":{d},\"y\":{d},\"max_x\":{d},\"max_y\":{d},\"zoom_percent\":{d}}}", .{
        res.camera.x, res.camera.y, res.camera.max_x, res.camera.max_y, res.camera.zoom_percent,
    });
    try writer.writeAll(",\"shell\":");
    try stringifyShellState(res.shell, writer);
    try writer.writeAll(",\"workspaces\":");
    try stringifyWorkspaces(res.workspaces, writer);
    try writer.writeByte('}');
}

fn stringifyWindowDebug(res: WindowDebugResult, writer: anytype) !void {
    try writer.print("{{\"id\":{d},\"title\":", .{res.id});
    if (res.title) |t| try writer.print("{f}", .{std.json.fmt(t, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"app_id\":");
    if (res.app_id) |a| try writer.print("{f}", .{std.json.fmt(a, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"pid\":");
    if (res.pid) |p| try writer.print("{d}", .{p}) else try writer.writeAll("null");
    try writer.print(",\"client_box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ res.client_box.x, res.client_box.y, res.client_box.width, res.client_box.height });
    try writer.print(",\"chrome_box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ res.chrome_box.x, res.chrome_box.y, res.chrome_box.width, res.chrome_box.height });
    try writer.print(",\"titlebar_height\":{d},\"footer_height\":{d},\"frame_border\":{d},\"frame_radius\":{d}", .{ res.titlebar_height, res.footer_height, res.frame_border, res.frame_radius });
    try writer.print(",\"decoration_mode\":{f}", .{std.json.fmt(res.decoration_mode, .{})});
    try writer.print(",\"minimized\":{},\"maximized\":{},\"fullscreen\":{},\"is_resizing\":{},\"zoom_percent\":{d}", .{ res.minimized, res.maximized, res.fullscreen, res.is_resizing, res.zoom_percent });
    try writer.print(",\"effective_zoom\":{d},\"zoom_boosted\":{}", .{ res.effective_zoom, res.zoom_boosted });
    try writer.print(",\"source_box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ res.source_box.x, res.source_box.y, res.source_box.width, res.source_box.height });
    try writer.print(",\"buffer_width\":{d},\"buffer_height\":{d},\"buffer_scale\":{d},\"buffer_transform\":{f}", .{ res.buffer_width, res.buffer_height, res.buffer_scale, std.json.fmt(res.buffer_transform, .{}) });
    try writer.print(",\"configure_serial\":{d},\"ack_serial\":{d},\"outputs\":[", .{ res.configure_serial, res.ack_serial });
    for (res.outputs, 0..) |out_name, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{f}", .{std.json.fmt(out_name, .{})});
    }
    try writer.writeAll("],\"skirt_fill\":");
    if (res.skirt_fill) |fill| {
        try writer.print("[{d},{d},{d},{d}]", .{ fill[0], fill[1], fill[2], fill[3] });
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"edge_sample\":{f}", .{std.json.fmt(res.edge_sample, .{})});
    try writer.writeByte('}');
}

fn stringifyOpenRules(open: OpenRulesData, writer: anytype) !void {
    try writer.writeAll("{\"output\":");
    if (open.output) |o| try writer.print("{f}", .{std.json.fmt(o, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"x\":");
    if (open.x) |x| try writer.print("{d}", .{x}) else try writer.writeAll("null");
    try writer.writeAll(",\"y\":");
    if (open.y) |y| try writer.print("{d}", .{y}) else try writer.writeAll("null");
    try writer.writeAll(",\"center\":");
    if (open.center) |c| try writer.print("{}", .{c}) else try writer.writeAll("null");
    try writer.writeAll(",\"width\":");
    if (open.width) |w| try writer.print("{d}", .{w}) else try writer.writeAll("null");
    try writer.writeAll(",\"height\":");
    if (open.height) |h| try writer.print("{d}", .{h}) else try writer.writeAll("null");
    try writer.writeAll(",\"maximized\":");
    if (open.maximized) |m| try writer.print("{}", .{m}) else try writer.writeAll("null");
    try writer.writeAll(",\"fullscreen\":");
    if (open.fullscreen) |f| try writer.print("{}", .{f}) else try writer.writeAll("null");
    try writer.writeAll(",\"focus\":");
    if (open.focus) |fc| try writer.print("{}", .{fc}) else try writer.writeAll("null");
    try writer.writeAll(",\"depth\":");
    if (open.depth) |d| try writer.print("{d}", .{d}) else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn stringifyLiveRules(live: LiveRulesData, writer: anytype) !void {
    try writer.writeAll("{\"opacity\":");
    if (live.opacity) |op| try writer.print("{d}", .{op}) else try writer.writeAll("null");
    try writer.writeAll(",\"effective_opacity\":");
    if (live.effective_opacity) |eo| try writer.print("{d}", .{eo}) else try writer.writeAll("null");
    try writer.writeAll(",\"decorations\":");
    if (live.decorations) |d| try writer.print("{f}", .{std.json.fmt(d, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"skip_taskbar\":");
    if (live.skip_taskbar) |st| try writer.print("{}", .{st}) else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn stringifyWindowRules(res: GetWindowRulesResult, writer: anytype) !void {
    try writer.print("{{\"window_id\":{d},\"matched_rules\":[", .{res.window_id});
    for (res.matched_rules, 0..) |rule_idx, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{d}", .{rule_idx});
    }
    try writer.writeAll("],\"open\":");
    try stringifyOpenRules(res.open, writer);
    try writer.writeAll(",\"live\":");
    try stringifyLiveRules(res.live, writer);
    try writer.print(",\"resolved_before_app_id\":{}}}", .{res.resolved_before_app_id});
}

fn stringifyMatchWindowRules(res: MatchWindowRulesResult, writer: anytype) !void {
    try writer.writeAll("{\"matched_rules\":[");
    for (res.matched_rules, 0..) |rule_idx, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{d}", .{rule_idx});
    }
    try writer.writeAll("],\"open\":");
    try stringifyOpenRules(res.open, writer);
    try writer.writeAll(",\"live\":");
    try stringifyLiveRules(res.live, writer);
    try writer.writeByte('}');
}

fn stringifyShellDetail(res: ShellDetailResult, writer: anytype) !void {
    try writer.writeAll("{\"start_menu\":");
    if (res.start_menu) |sm| try stringifyPanelState(sm, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"control_center\":");
    if (res.control_center) |cc| try stringifyPanelState(cc, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"power_menu\":");
    if (res.power_menu) |pm| try stringifyPanelState(pm, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"polkit_dialog\":");
    if (res.polkit_dialog) |dialog| try stringifyPanelState(dialog, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"taskbars\":[");
    for (res.taskbars, 0..) |tb, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"output\":{f},\"box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}},\"start_button_box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}},\"chips\":[", .{
            std.json.fmt(tb.output, .{}), tb.box.x, tb.box.y, tb.box.width, tb.box.height, tb.start_button_box.x, tb.start_button_box.y, tb.start_button_box.width, tb.start_button_box.height,
        });
        for (tb.chips, 0..) |chip, ci| {
            if (ci > 0) try writer.writeByte(',');
            try writer.print("{{\"window_id\":{d},\"title\":{f},\"box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}},\"is_active\":{},\"is_urgent\":{}}}", .{
                chip.window_id, std.json.fmt(chip.title, .{}), chip.box.x, chip.box.y, chip.box.width, chip.box.height, chip.is_active, chip.is_urgent,
            });
        }
        try writer.print("],\"right_items\":{f},\"app_tray\":{f},\"tray_menu\":{f}}}", .{ std.json.fmt(tb.right_items, .{}), std.json.fmt(tb.app_tray, .{}), std.json.fmt(tb.tray_menu, .{}) });
    }
    try writer.writeAll("]}");
}

fn stringifyDumpBuffer(res: DumpBufferResult, writer: anytype) !void {
    try writer.print("{{\"target\":{f},\"width\":{d},\"height\":{d},\"stride\":{d},\"format\":{f},\"scale\":{d},\"premultiplied\":{},\"data\":", .{
        std.json.fmt(res.target, .{}), res.width, res.height, res.stride, std.json.fmt(res.format, .{}), res.scale, res.premultiplied,
    });
    if (res.data) |d| try writer.print("{f}", .{std.json.fmt(d, .{})}) else try writer.writeAll("null");
    try writer.writeByte('}');
}

// Split across two `print` calls: a single call tops out at 32 format
// arguments (see std.Io.Writer), and this response has grown past that.
fn stringifyPerformanceStats(res: PerformanceStatsResult, writer: anytype) !void {
    try writer.writeAll("{");
    if (res.screenshot_selection) |selection| {
        try writer.print("\"screenshot_selection\":{f},", .{std.json.fmt(selection, .{})});
    }
    if (res.frame_work) |work| {
        try writer.print("\"frame_work\":{f},", .{std.json.fmt(work, .{})});
    }
    if (res.desktop) |desktop| {
        try writer.print("\"desktop\":{f},", .{std.json.fmt(desktop, .{})});
    }
    if (res.output_skipped_commits) |skipped| {
        try writer.print("\"output_skipped_commits\":{d},", .{skipped});
    }
    try writer.print("\"output_commits\":{d},\"output_failed_commits\":{d},\"fps\":{d:.1},\"frame_time_ms\":{d:.1},\"missed_frames\":{d},\"refresh_hz\":{d:.1},\"titlebar_paints\":{d},\"footer_paints\":{d},\"edge_samples_attempted\":{d},\"edge_samples_succeeded\":{d},\"edge_samples_skipped\":{d},\"edge_sample_ns\":{d},\"panel_paints\":{d},\"panel_allocated_bytes\":{d},\"panel_reused_bytes\":{d},\"icon_cache_hits\":{d},\"icon_cache_misses\":{d},\"icon_decode_ns\":{d},\"icon_decode_count\":{d},\"icon_decoded_bytes\":{d},\"icon_queue_depth_max\":{d},", .{
        res.output_commits,
        res.output_failed_commits,
        res.fps,
        res.frame_time_ms,
        res.missed_frames,
        res.refresh_hz,
        res.titlebar_paints,
        res.footer_paints,
        res.edge_samples_attempted,
        res.edge_samples_succeeded,
        res.edge_samples_skipped,
        res.edge_sample_ns,
        res.panel_paints,
        res.panel_allocated_bytes,
        res.panel_reused_bytes,
        res.icon_cache_hits,
        res.icon_cache_misses,
        res.icon_decode_ns,
        res.icon_decode_count,
        res.icon_decoded_bytes,
        res.icon_queue_depth_max,
    });
    try writer.print("\"taskbar_paints\":{d},\"taskbar_paint_ns\":{d},\"taskbar_raster_pixels\":{d},\"taskbar_clock_frame_requests\":{d},\"taskbar_clock_paints\":{d},\"taskbar_start_paints\":{d},\"taskbar_chip_paints\":{d},\"taskbar_tray_paints\":{d},\"taskbar_hover_paints\":{d},\"taskbar_press_paints\":{d},\"taskbar_audio_paints\":{d},\"recent_errors_count\":{d},\"anim_frames_scheduled\":{d},\"anim_wasted_wakeups\":{d},\"anim_longest_ms\":{d},\"anim_speed\":{d},\"anim_enabled\":{},\"anim_reduced_motion\":{}", .{
        res.taskbar_paints,
        res.taskbar_paint_ns,
        res.taskbar_raster_pixels,
        res.taskbar_clock_frame_requests,
        res.taskbar_clock_paints,
        res.taskbar_start_paints,
        res.taskbar_chip_paints,
        res.taskbar_tray_paints,
        res.taskbar_hover_paints,
        res.taskbar_press_paints,
        res.taskbar_audio_paints,
        res.recent_errors_count,
        res.anim_frames_scheduled,
        res.anim_wasted_wakeups,
        res.anim_longest_ms,
        res.anim_speed,
        res.anim_enabled,
        res.anim_reduced_motion,
    });
    if (res.startup) |st| {
        try writer.writeAll(",\"startup\":");
        try stringifyStartup(st, writer);
    }
    try writer.writeByte('}');
}

fn stringifyStartup(st: StartupStats, writer: anytype) !void {
    try writer.print("{{\"build_mode\":{f},\"renderer\":{f},\"scale\":{d:.2},\"output_count\":{d},\"catalog_entries\":{d},\"autostart_count\":{d},\"catalog_state\":{f},\"wallpaper_state\":{f},\"catalog_provisional\":{},\"catalog_loading\":{},\"catalog_generation\":{d},", .{
        std.json.fmt(st.build_mode, .{}),
        std.json.fmt(st.renderer, .{}),
        st.scale,
        st.output_count,
        st.catalog_entries,
        st.autostart_count,
        std.json.fmt(st.catalog_state, .{}),
        std.json.fmt(st.wallpaper_state, .{}),
        st.catalog_provisional,
        st.catalog_loading,
        st.catalog_generation,
    });
    try writer.print("\"renderer_ready_ns\":{d},\"config_ready_ns\":{d},\"catalog_cache_read_ns\":{d},\"catalog_scan_ns\":{d},\"wallpaper_decode_ns\":{d},\"socket_ready_ns\":{d},\"ipc_ready_ns\":{d},\"session_ready_ns\":{d},\"session_clients_started_ns\":{d},\"xwayland_ready_ns\":{d},\"first_presented_ns\":{d},\"first_ipc_ns\":{d},\"first_input_ns\":{d},\"catalog_published_ns\":{d},\"wallpaper_presented_ns\":{d},\"catalog_cache_read_duration_ns\":{d},\"catalog_scan_duration_ns\":{d},\"wallpaper_decode_duration_ns\":{d}}}", .{
        st.renderer_ready_ns,
        st.config_ready_ns,
        st.catalog_cache_read_ns,
        st.catalog_scan_ns,
        st.wallpaper_decode_ns,
        st.socket_ready_ns,
        st.ipc_ready_ns,
        st.session_ready_ns,
        st.session_clients_started_ns,
        st.xwayland_ready_ns,
        st.first_presented_ns,
        st.first_ipc_ns,
        st.first_input_ns,
        st.catalog_published_ns,
        st.wallpaper_presented_ns,
        st.catalog_cache_read_duration_ns,
        st.catalog_scan_duration_ns,
        st.wallpaper_decode_duration_ns,
    });
}

fn stringifyNotifications(n: GetNotificationsResult, writer: anytype) !void {
    try writer.writeAll("{\"toasts\":[");
    for (n.toasts, 0..) |toast, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"app_name\":{f},\"summary\":{f},\"body\":{f},\"app_icon\":{f},\"urgency\":{d},\"resident\":{},\"transient\":{},\"expire_at_ms\":", .{
            toast.id,
            std.json.fmt(toast.app_name, .{}),
            std.json.fmt(toast.summary, .{}),
            std.json.fmt(toast.body, .{}),
            std.json.fmt(toast.app_icon, .{}),
            toast.urgency,
            toast.resident,
            toast.transient,
        });
        if (toast.expire_at_ms) |exp| {
            try writer.print("{d}", .{exp});
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"paused\":{},\"closing\":{}}}", .{ toast.paused, toast.closing });
    }
    try writer.writeAll("],\"history\":[");
    for (n.history, 0..) |rec, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"app_name\":{f},\"summary\":{f},\"body\":{f},\"app_icon\":{f},\"urgency\":{d},\"time_ms\":{d},\"closed\":{},\"close_reason\":", .{
            rec.id,
            std.json.fmt(rec.app_name, .{}),
            std.json.fmt(rec.summary, .{}),
            std.json.fmt(rec.body, .{}),
            std.json.fmt(rec.app_icon, .{}),
            rec.urgency,
            rec.time_ms,
            rec.closed,
        });
        if (rec.close_reason) |cr| {
            try writer.print("{d}", .{cr});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.print("],\"dnd\":{}}}", .{n.dnd});
}

pub fn stringifyEvent(event: Event, writer: anytype) !void {
    switch (event) {
        inline .window_urgency_changed, .keyboard_layouts_changed, .keyboard_layout_switched, .config_loaded => |ev, tag| {
            const name = comptime switch (tag) {
                .window_urgency_changed => "WindowUrgencyChanged",
                .keyboard_layouts_changed => "KeyboardLayoutsChanged",
                .keyboard_layout_switched => "KeyboardLayoutSwitched",
                .config_loaded => "ConfigLoaded",
                else => unreachable,
            };
            try writer.print("{{\"{s}\":{f}}}\n", .{ name, std.json.fmt(ev, .{}) });
        },
        .polkit_prompt_opened, .polkit_prompt_closed => |ev| {
            const name = if (event == .polkit_prompt_opened) "PolkitPromptOpened" else "PolkitPromptClosed";
            try writer.print("{{\"{s}\":{{\"seq\":{d},\"time_ms\":{d}}}}}\n", .{ name, ev.seq, ev.time_ms });
        },
        .state_snapshot => |snap| {
            try writer.print("{{\"StateSnapshot\":{{\"seq\":{d}", .{snap.seq});
            if (snap.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(snap.session_id, .{})});
            if (snap.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{snap.time_ms});
            try writer.writeAll(",\"windows\":");
            try writer.print("{f}", .{std.json.fmt(snap.windows, .{})});
            try writer.writeAll(",\"outputs\":");
            try stringifyOutputs(snap.outputs, writer);
            try writer.writeAll(",\"workspaces\":");
            try stringifyWorkspaces(snap.workspaces, writer);
            try writer.writeAll(",\"focused_window_id\":");
            if (snap.focused_window_id) |id| {
                try writer.print("{d}", .{id});
            } else {
                try writer.writeAll("null");
            }
            if (snap.camera) |cam| {
                try writer.print(",\"camera\":{{\"x\":{d},\"y\":{d},\"max_x\":{d},\"max_y\":{d},\"zoom_percent\":{d}}}", .{ cam.x, cam.y, cam.max_x, cam.max_y, cam.zoom_percent });
            }
            if (snap.shell) |sh| {
                try writer.writeAll(",\"shell\":");
                try stringifyShellState(sh, writer);
            }
            try writer.writeAll("}}\n");
        },
        .window_opened => |ev| {
            try writer.print("{{\"WindowOpened\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.writeAll(",\"window\":");
            try writer.print("{f}", .{std.json.fmt(ev.window, .{})});
            try writer.writeAll("}}\n");
        },
        .window_closed => |ev| {
            try writer.print("{{\"WindowClosed\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"id\":{d}}}}}\n", .{ev.id});
        },
        .window_changed => |ev| {
            try writer.print("{{\"WindowChanged\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.writeAll(",\"window\":");
            try writer.print("{f}", .{std.json.fmt(ev.window, .{})});
            try writer.writeAll("}}\n");
        },
        .window_focused => |ev| {
            try writer.print("{{\"WindowFocused\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.writeAll(",\"id\":");
            if (ev.id) |id| {
                try writer.print("{d}", .{id});
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll("}}\n");
        },
        .window_moved => |ev| {
            try writer.print("{{\"WindowMoved\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"id\":{d},\"x\":{d},\"y\":{d}}}}}\n", .{ ev.id, ev.x, ev.y });
        },
        .output_added => |ev| {
            try writer.print("{{\"OutputAdded\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.writeAll(",\"output\":");
            try stringifyOutput(ev.output, writer);
            try writer.writeAll("}}\n");
        },
        .output_changed => |ev| {
            try writer.print("{{\"OutputChanged\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.writeAll(",\"output\":");
            try stringifyOutput(ev.output, writer);
            try writer.writeAll("}}\n");
        },
        .output_removed => |ev| {
            try writer.print("{{\"OutputRemoved\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"name\":{f}}}}}\n", .{std.json.fmt(ev.name, .{})});
        },
        .camera_changed => |ev| {
            try writer.print("{{\"CameraChanged\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"x\":{d},\"y\":{d},\"max_x\":{d},\"max_y\":{d},\"zoom_percent\":{d}}}}}\n", .{
                ev.x, ev.y, ev.max_x, ev.max_y, ev.zoom_percent,
            });
        },
        .notification_shown => |ev| {
            try writer.print("{{\"NotificationShown\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"id\":{d},\"app_name\":{f},\"summary\":{f},\"urgency\":{d}}}}}\n", .{
                ev.id,
                std.json.fmt(ev.app_name, .{}),
                std.json.fmt(ev.summary, .{}),
                ev.urgency,
            });
        },
        .notification_closed => |ev| {
            try writer.print("{{\"NotificationClosed\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"id\":{d},\"reason\":{d}}}}}\n", .{ ev.id, ev.reason });
        },
        .notification_action => |ev| {
            try writer.print("{{\"NotificationAction\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"id\":{d},\"action_key\":{f}}}}}\n", .{ ev.id, std.json.fmt(ev.action_key, .{}) });
        },
        .launch_started => |ev| {
            try writer.print("{{\"LaunchStarted\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"desktop_id\":{f}", .{std.json.fmt(ev.desktop_id, .{})});
            if (ev.pid) |pid| try writer.print(",\"pid\":{d}", .{pid}) else try writer.writeAll(",\"pid\":null");
            if (ev.placeholder_id) |phid| try writer.print(",\"placeholder_id\":{d}", .{phid}) else try writer.writeAll(",\"placeholder_id\":null");
            try writer.writeAll("}}\n");
        },
        .launch_matched => |ev| {
            try writer.print("{{\"LaunchMatched\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"desktop_id\":{f},\"window_id\":{d}", .{ std.json.fmt(ev.desktop_id, .{}), ev.window_id });
            if (ev.pid) |pid| try writer.print(",\"pid\":{d}", .{pid}) else try writer.writeAll(",\"pid\":null");
            try writer.writeAll("}}\n");
        },
        .launch_timeout => |ev| {
            try writer.print("{{\"LaunchTimeout\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"desktop_id\":{f}", .{std.json.fmt(ev.desktop_id, .{})});
            if (ev.pid) |pid| try writer.print(",\"pid\":{d}", .{pid}) else try writer.writeAll(",\"pid\":null");
            try writer.writeAll("}}\n");
        },
        .widget_changed => |ev| {
            try writer.print("{{\"WidgetChanged\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"panel\":{f}", .{std.json.fmt(ev.panel, .{})});
            if (ev.path) |p| try writer.print(",\"path\":{f}", .{std.json.fmt(p, .{})}) else try writer.writeAll(",\"path\":null");
            if (ev.name) |n| try writer.print(",\"name\":{f}", .{std.json.fmt(n, .{})}) else try writer.writeAll(",\"name\":null");
            try writer.writeAll(",\"widget\":");
            try writer.print("{f}", .{std.json.fmt(ev.widget, .{})});
            try writer.writeAll("}}\n");
        },
    }
}

// Keep f32 formatting here: std.json widens f32 before printing, changing
// decoded values (for example 1.23456 to 1.2345600128173828).
fn stringifyOutput(out: OutputData, writer: anytype) !void {
    try writer.writeAll("{\"name\":");
    try writer.print("{f}", .{std.json.fmt(out.name, .{})});
    try writer.writeAll(",\"make\":");
    if (out.make) |m| try writer.print("{f}", .{std.json.fmt(m, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"model\":");
    if (out.model) |m| try writer.print("{f}", .{std.json.fmt(m, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"enabled\":");
    try writer.writeAll(if (out.enabled) "true" else "false");
    try writer.print(",\"x\":{d},\"y\":{d},\"logical_width\":{d},\"logical_height\":{d},\"buffer_width\":{d},\"buffer_height\":{d},\"transform\":", .{ out.x, out.y, out.logical_width, out.logical_height, out.buffer_width, out.buffer_height });
    try writer.print("{f}", .{std.json.fmt(out.transform, .{})});
    try writer.print(",\"bottom_exclusion\":{d}", .{out.bottom_exclusion});
    try writer.print(",\"scale\":{d},\"refresh_hz\":{d},\"is_focused\":", .{ out.scale, out.refresh_hz });
    try writer.writeAll(if (out.is_focused) "true" else "false");
    try writer.writeByte('}');
}

fn stringifyOutputs(outs: []const OutputData, writer: anytype) !void {
    try writer.writeByte('[');
    for (outs, 0..) |out, i| {
        if (i > 0) try writer.writeByte(',');
        try stringifyOutput(out, writer);
    }
    try writer.writeByte(']');
}

fn stringifyWorkspaces(ws: []const WorkspaceData, writer: anytype) !void {
    try writer.print("{f}", .{std.json.fmt(ws, .{})});
}
