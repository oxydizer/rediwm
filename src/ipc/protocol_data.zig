//! IPC v1 payload records: windows, outputs, shell, widgets, rules, toasts and notifications.

const std = @import("std");
const commands = @import("commands.zig");
const Request = @import("protocol.zig").Request;

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
    workspace_order: u64 = 0,
    placement: []const u8 = "floating",
    floating_override: ?bool = null,
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
    /// The window this one is a dialog of.
    parent_id: ?u64 = null,
    /// A dialog that holds its owner's input (xdg-dialog-v1, _NET_WM_STATE_MODAL).
    is_modal: bool = false,

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
        try jws.objectField("workspace_order");
        try jws.write(self.workspace_order);
        try jws.objectField("placement");
        try jws.write(self.placement);
        try jws.objectField("floating_override");
        try jws.write(self.floating_override);
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
        inline for (.{ "tag", "description", "content_type", "parent_id" }) |field| {
            if (@field(self, field)) |value| {
                try jws.objectField(field);
                try jws.write(value);
            }
        }
        if (self.is_modal) {
            try jws.objectField("is_modal");
            try jws.write(true);
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
    /// A game window here asks to tear and `allow_tearing` permits it.
    tearing_allowed: bool = false,
    /// The last committed buffer was flipped asynchronously.
    tearing_active: bool = false,
    /// Asynchronous flips are paused after a run of driver refusals.
    tearing_paused: bool = false,
    /// The last frame scanned a client buffer out directly.
    direct_scanout: bool = false,
    /// `[[outputs]] adaptive_sync`: "off", "auto" or "always".
    adaptive_sync: []const u8 = "auto",
    /// The display and driver can run at a variable refresh rate.
    adaptive_sync_supported: bool = false,
    /// The setting asks for variable refresh now (a game fills the output in
    /// "auto"), whether or not the display can.
    adaptive_sync_wanted: bool = false,
    /// Variable refresh is on.
    adaptive_sync_active: bool = false,
    /// The driver cannot switch it without a modeset, so "auto" leaves it.
    adaptive_sync_needs_modeset: bool = false,
    /// `[[outputs]] hdr`: "off" or "on".
    hdr: []const u8 = "off",
    /// The display and driver can take an HDR10 (PQ, BT.2020) signal.
    hdr_supported: bool = false,
    /// The output has committed an HDR image description.
    hdr_active: bool = false,
    /// The last frame blended in linear light (FP16), the HDR pipeline.
    hdr_linear: bool = false,
    /// The driver would not take the HDR10 signal in this mode.
    hdr_refused: bool = false,
    /// `[[outputs]] sdr_white`: SDR brightness on an HDR output, in nits.
    sdr_white: f32 = 203,
    /// `[[outputs]] scroll_direction`: "auto", "horizontal" or "vertical".
    scroll_direction: []const u8 = "auto",
    /// The direction a scrolling strip runs here, with "auto" resolved.
    scroll_direction_resolved: []const u8 = "horizontal",
};

pub const WorkspaceData = struct {
    is_visible: bool = true,
    output: ?[]const u8 = null,
    /// Whether the workspace tiles (split or scrolling); `layout` says how.
    automatic: bool = false,
    layout: []const u8 = "floating",
    window_gap: u32 = 0,
    nodes: []const @import("config").workspace_layout.Node = &.{},
    /// A scrolling strip: its columns, where it is scrolled to, and the
    /// direction it scrolls on its display ("horizontal" or "vertical").
    columns: []const @import("config").workspace_layout.Column = &.{},
    view: f64 = 0,
    direction: ?[]const u8 = null,
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
    floating: ?bool = null,
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
    /// Natural label advance in layout pixels (never editable/secret contents).
    text_width: ?f64 = null,
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
