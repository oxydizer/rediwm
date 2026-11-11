pub const commands = @import("commands.zig");
const std = @import("std");
const output_transform = @import("config").output_transform;

pub const parseOutputTransform = output_transform.parseName;
pub const outputTransformName = output_transform.name;
const protocol_data = @import("protocol_data.zig");
const protocol_results = @import("protocol_results.zig");
const protocol_parse = @import("protocol_parse.zig");
const protocol_wait = @import("protocol_wait.zig");
const protocol_params = @import("protocol_params.zig");
const protocol_stringify = @import("protocol_stringify.zig");
pub const BufferWriter = protocol_data.BufferWriter;
pub const RequestId = protocol_data.RequestId;
pub const ParsedEnvelope = protocol_data.ParsedEnvelope;
pub const RectData = protocol_data.RectData;
pub const WindowSandboxData = protocol_data.WindowSandboxData;
pub const WindowData = protocol_data.WindowData;
pub const OutputData = protocol_data.OutputData;
pub const WorkspaceData = protocol_data.WorkspaceData;
pub const ScreenshotParams = protocol_data.ScreenshotParams;
pub const ScreenshotResult = protocol_data.ScreenshotResult;
pub const SinkInputData = protocol_data.SinkInputData;
pub const AudioStateData = protocol_data.AudioStateData;
pub const PanelStatsData = protocol_data.PanelStatsData;
pub const AnimationData = protocol_data.AnimationData;
pub const CameraData = protocol_data.CameraData;
pub const PanelStateData = protocol_data.PanelStateData;
pub const ShellStateData = protocol_data.ShellStateData;
pub const TaskbarChipData = protocol_data.TaskbarChipData;
pub const TaskbarItemData = protocol_data.TaskbarItemData;
pub const TaskbarData = protocol_data.TaskbarData;
pub const ShellDetailResult = protocol_data.ShellDetailResult;
pub const ModifiersData = protocol_data.ModifiersData;
pub const InputStateResult = protocol_data.InputStateResult;
pub const HitTestResult = protocol_data.HitTestResult;
pub const WindowDebugResult = protocol_data.WindowDebugResult;
pub const OpenRulesData = protocol_data.OpenRulesData;
pub const LiveRulesData = protocol_data.LiveRulesData;
pub const GetWindowRulesResult = protocol_data.GetWindowRulesResult;
pub const MatchWindowRulesResult = protocol_data.MatchWindowRulesResult;
pub const MatchWindowRulesParams = protocol_data.MatchWindowRulesParams;
pub const SceneNodeData = protocol_data.SceneNodeData;
pub const SceneTreeResult = protocol_data.SceneTreeResult;
pub const LayerSurfaceData = protocol_data.LayerSurfaceData;
pub const LayerSurfacesResult = protocol_data.LayerSurfacesResult;
pub const WidgetNodeData = protocol_data.WidgetNodeData;
pub const WidgetTreeResult = protocol_data.WidgetTreeResult;
pub const PanelData = protocol_data.PanelData;
pub const ListPanelsResult = protocol_data.ListPanelsResult;
pub const FractionCoord = protocol_data.FractionCoord;
pub const ClickWidgetParams = protocol_data.ClickWidgetParams;
pub const HoverWidgetParams = protocol_data.HoverWidgetParams;
pub const PointData = protocol_data.PointData;
pub const WidgetPointResult = protocol_data.WidgetPointResult;
pub const ConfigStatusResult = protocol_data.ConfigStatusResult;
pub const RuntimeInfoResult = protocol_data.RuntimeInfoResult;
pub const CommandDesc = protocol_data.CommandDesc;
pub const DescribeIPCResult = protocol_data.DescribeIPCResult;
pub const GetStateResult = protocol_data.GetStateResult;
pub const ToastData = protocol_data.ToastData;
pub const NotificationRecordData = protocol_data.NotificationRecordData;
pub const GetNotificationsResult = protocol_data.GetNotificationsResult;
pub const WidgetStateValue = protocol_results.WidgetStateValue;
pub const freeWidgetStateValue = protocol_results.freeWidgetStateValue;
pub const WaitCondition = protocol_results.WaitCondition;
pub const WaitForParams = protocol_results.WaitForParams;
pub const WaitForResult = protocol_results.WaitForResult;
pub const WaitForFrameParams = protocol_results.WaitForFrameParams;
pub const WaitForFrameResult = protocol_results.WaitForFrameResult;
pub const DumpBufferParams = protocol_results.DumpBufferParams;
pub const DumpBufferResult = protocol_results.DumpBufferResult;
pub const SamplePixelsParams = protocol_results.SamplePixelsParams;
pub const SamplePixelsResult = protocol_results.SamplePixelsResult;
pub const ScreenshotSelectionStats = protocol_results.ScreenshotSelectionStats;
pub const PerformanceStatsResult = protocol_results.PerformanceStatsResult;
pub const DesktopStats = protocol_results.DesktopStats;
pub const StartupStats = protocol_results.StartupStats;
pub const InhibitorData = protocol_results.InhibitorData;
pub const IdleStateResult = protocol_results.IdleStateResult;
pub const CaptureSessionData = protocol_results.CaptureSessionData;
pub const CaptureIndicatorData = protocol_results.CaptureIndicatorData;
pub const CaptureStateResult = protocol_results.CaptureStateResult;
pub const EventFilter = protocol_results.EventFilter;
pub const NightLightPhase = protocol_results.NightLightPhase;
pub const NightLightOutputStatus = protocol_results.NightLightOutputStatus;
pub const NightLightOutputData = protocol_results.NightLightOutputData;
pub const NightLightResult = protocol_results.NightLightResult;
pub const GesturePhase = protocol_results.GesturePhase;
pub const OutputConfigPatch = protocol_results.OutputConfigPatch;
pub const MoveWindowToParams = protocol_results.MoveWindowToParams;
pub const KeyboardLayoutsData = protocol_results.KeyboardLayoutsData;
pub const InputSourcesData = protocol_results.InputSourcesData;
pub const InputSourceData = protocol_results.InputSourceData;
pub const LayoutTarget = protocol_results.LayoutTarget;
pub const ConfigLoadedEvent = protocol_results.ConfigLoadedEvent;
pub const ThemeToken = protocol_results.ThemeToken;
pub const ThemeTokens = protocol_results.ThemeTokens;
pub const ServiceMode = protocol_results.ServiceMode;
pub const ServiceData = protocol_results.ServiceData;
pub const ServicesResult = protocol_results.ServicesResult;
pub const SoundEventData = protocol_results.SoundEventData;
pub const SoundsResult = protocol_results.SoundsResult;
pub const WallpaperResult = protocol_results.WallpaperResult;
pub const ProcessData = protocol_results.ProcessData;
pub const ProcessesResult = protocol_results.ProcessesResult;
pub const ParseError = protocol_parse.ParseError;
pub const parseU64 = protocol_parse.parseU64;
pub const parseOptU64 = protocol_parse.parseOptU64;
pub const parseU32 = protocol_parse.parseU32;
pub const parseOptU32 = protocol_parse.parseOptU32;
pub const parseOptI64 = protocol_parse.parseOptI64;
pub const parseI32 = protocol_parse.parseI32;
pub const parseGesturePhase = protocol_parse.parseGesturePhase;
pub const parseF64 = protocol_parse.parseF64;
pub const parseFractionCoord = protocol_parse.parseFractionCoord;
pub const parseVolume = protocol_parse.parseVolume;
pub const parseRect = protocol_parse.parseRect;
pub const parseRequest = protocol_parse.parseRequest;
pub const parseEnvelope = protocol_parse.parseEnvelope;
pub const parseEnvelopeValue = protocol_parse.parseEnvelopeValue;
pub const emptyAction = protocol_parse.emptyAction;
pub const emptyRequest = protocol_parse.emptyRequest;
pub const wait_aliases = protocol_wait.wait_aliases;
pub const waitNames = protocol_wait.waitNames;
pub const parseWidgetStateValue = protocol_wait.parseWidgetStateValue;
pub const parseWaitCondition = protocol_wait.parseWaitCondition;
pub const parseWaitForParams = protocol_params.parseWaitForParams;
pub const parseWaitForFrameParams = protocol_params.parseWaitForFrameParams;
pub const parseDumpBufferParams = protocol_params.parseDumpBufferParams;
pub const parseSamplePixelsParams = protocol_params.parseSamplePixelsParams;
pub const parseMatchWindowRules = protocol_params.parseMatchWindowRules;
pub const parseQueryParams = protocol_params.parseQueryParams;
pub const requiredText = protocol_params.requiredText;
pub const persistParam = protocol_params.persistParam;
pub const parseActionParams = protocol_params.parseActionParams;
pub const stringifyResponse = protocol_stringify.stringifyResponse;
pub const stringifyResponseWithId = protocol_stringify.stringifyResponseWithId;
pub const stringifyResponsePayload = protocol_stringify.stringifyResponsePayload;
pub const stringifySinkInput = protocol_stringify.stringifySinkInput;
pub const stringifyAnimations = protocol_stringify.stringifyAnimations;
pub const stringifyAudioState = protocol_stringify.stringifyAudioState;
pub const stringifyScreenshotResult = protocol_stringify.stringifyScreenshotResult;
pub const stringifyPanelState = protocol_stringify.stringifyPanelState;
pub const stringifyShellState = protocol_stringify.stringifyShellState;
pub const stringifyGetState = protocol_stringify.stringifyGetState;
pub const stringifyWindowDebug = protocol_stringify.stringifyWindowDebug;
pub const stringifyOpenRules = protocol_stringify.stringifyOpenRules;
pub const stringifyLiveRules = protocol_stringify.stringifyLiveRules;
pub const stringifyWindowRules = protocol_stringify.stringifyWindowRules;
pub const stringifyMatchWindowRules = protocol_stringify.stringifyMatchWindowRules;
pub const stringifyShellDetail = protocol_stringify.stringifyShellDetail;
pub const stringifyDumpBuffer = protocol_stringify.stringifyDumpBuffer;
pub const stringifyPerformanceStats = protocol_stringify.stringifyPerformanceStats;
pub const stringifyStartup = protocol_stringify.stringifyStartup;
pub const stringifyNotifications = protocol_stringify.stringifyNotifications;
pub const stringifyEvent = protocol_stringify.stringifyEvent;
pub const stringifyOutput = protocol_stringify.stringifyOutput;
pub const stringifyOutputs = protocol_stringify.stringifyOutputs;
pub const stringifyWorkspaces = protocol_stringify.stringifyWorkspaces;

pub const Action = union(enum) {
    theme_apply: struct { id: []const u8 },
    theme_install: struct { path: []const u8, replace: bool = false },
    set_service_mode: struct { service: []const u8, mode: ServiceMode },
    play_sound: struct { event: []const u8 },
    set_wallpaper: struct { path: []const u8, persist: bool = true },
    set_accent_color: struct { color: [4]f32, persist: bool = true },
    set_night_light: struct { enabled: ?bool = null, temperature: ?u16 = null, persist: bool = true },
    switch_layout: LayoutTarget,
    switch_input_source: LayoutTarget,
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
    set_desktop_mode: struct { mode: @import("config").loader.DesktopMode, persist: bool = true },
    set_workspace_layout: struct { workspace: u8, automatic: bool },
    switch_workspace: struct { workspace: u8 },
    move_to_workspace: struct { id: u64, workspace: u8 },
    set_window_gap: struct { gap: u32, persist: bool = true },
    set_floating_apps: struct { apps: []const []const u8, persist: bool = true },
    tiling_action: struct { action: @import("config").keybinds.TilingAction, id: ?u64 = null },
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
    theme_list,
    get_services,
    get_sounds,
    get_wallpaper,
    get_theme,
    get_processes,
    get_keyboard_layouts,
    get_input_sources,
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
    theme_packs: struct { active: []const u8, packs: []const struct { id: []const u8, name: []const u8, version: []const u8, user_installed: bool } },
    theme_job: struct { id: []const u8, message: []const u8 },
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
    input_sources: InputSourcesData,
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
    input_source_changed: struct { seq: u64, input_sources: InputSourcesData },
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
