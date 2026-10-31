const std = @import("std");

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");

const audio_mod = @import("audio/pipewire.zig");
const cursor_theme = @import("cursor_theme.zig");
const battery_mod = @import("taskbar/battery.zig");
const ImageBuffer = @import("ImageBuffer.zig");
const Input = @import("Input.zig");
const Output = @import("Output.zig");
const Shell = @import("Shell.zig");
const World = @import("World.zig");
const sn = @import("node.zig");
const icon_theme = @import("icon_theme.zig");
const icon_service_mod = @import("icon_service.zig");
const glass = @import("glass.zig");
const scene_output_mod = @import("scene_output.zig");
const scene_outputs_mod = @import("scene_outputs.zig");
const explicit_sync = @import("explicit_sync.zig");
const ipc_server = @import("ipc/server.zig");
const screenshot = @import("screenshot/capture.zig");
const capture = @import("capture/manager.zig");
const config_loader = @import("config").loader;
const watcher_mod = @import("config_runtime/watcher.zig");
const config_actions = @import("config_runtime/actions.zig");
const ui_theme = @import("ui").theme;
const idle_mod = @import("session/idle.zig");
const power_mod = @import("session/power.zig");
const power_profiles_mod = @import("power_profiles.zig");
const services_mod = @import("session/services.zig");
const layout_autosave_mod = @import("session/layout_autosave.zig");
const notifications_mod = @import("notifications/mod.zig");
const polkit_mod = @import("polkit/mod.zig");
const undo_mod = @import("undo.zig");

const VirtualInput = @import("input/virtual.zig").VirtualInput;
const applications = @import("start_menu/applications.zig");
const child_env = @import("child_env.zig");
const Xwayland = @import("Xwayland.zig");
const wallpaper_load = @import("wallpaper_load.zig");
const startup = @import("startup.zig");

const server_xwayland_scale = @import("server/xwayland_scale.zig");
const server_session = @import("server/session.zig");
const server_frame = @import("server/frame.zig");
const server_outputs = @import("server/outputs.zig");
const server_taskbars = @import("server/taskbars.zig");
const server_icons = @import("server/icons.zig");
const server_wakeups = @import("server/wakeups.zig");
const server_wallpaper = @import("server/wallpaper.zig");
const Server = @This();

const log = std.log.scoped(.compositor);

pub extern fn wl_display_set_default_max_buffer_size(display: *wl.Server, size: usize) void;

pub const CompositorError = error{
    ServerCreateFailed,
    BackendCreateFailed,
    BackendStartFailed,
    RendererInitFailed,
    AllocatorCreateFailed,
    ShmInitFailed,
    SceneCreateFailed,
    OutputLayoutCreateFailed,
    XdgOutputManagerCreateFailed,
    SeatCreateFailed,
    CursorCreateFailed,
    CursorShapeManagerCreateFailed,
    CursorSerialTrackerCreateFailed,
    XcursorCreateFailed,
    XdgShellCreateFailed,
    XdgDecorationCreateFailed,
    KdeDecorationCreateFailed,
    CompositorCreateFailed,
    SubcompositorCreateFailed,
    DataDeviceManagerCreateFailed,
    DataControlManagerCreateFailed,
    ActivationManagerCreateFailed,
    ExtraProtocolsCreateFailed,
    TextInputManagerCreateFailed,
    PrimarySelectionManagerCreateFailed,
    ViewporterCreateFailed,
    SinglePixelBufferManagerCreateFailed,
    FractionalScaleManagerCreateFailed,
    PresentationCreateFailed,
    KeyboardInitFailed,
    SocketCreateFailed,
    PointerGesturesCreateFailed,
    PointerConstraintsCreateFailed,
    ShortcutsInhibitCreateFailed,
};

wl_server: *wl.Server,
backend: *wlr.Backend,
renderer: *wlr.Renderer,
// GPU timestamps cost three context switches and a flush on every frame, so
// the timer starts with the first performance-stats request and stops again
// once requests stop (see ensureGpuTimer/expireGpuTimer).
gpu_timer: ?*@import("gpu_timing.zig").Timer = null,
gpu_timer_tried: bool = false,
gpu_timer_used_ns: u64 = 0,
/// Late rendering needs the GPU's elapsed times too: it keeps the timer alive
/// while it schedules (`keepGpuTimer`) and reads this ring of recent samples.
gpu_timer_sched_ns: u64 = 0,
gpu_recent: @import("output/late_render.zig").PeakRing(32) = .{},
allocator: *wlr.Allocator,
/// What each output keeps besides the output itself (scene_outputs.h).
scene_outputs: *scene_outputs_mod.SceneOutputs,
/// The compositor's own scene: its layers are the trees below, bottom to top.
nodes: *sn.Scene,
glass_engine: ?*glass.Engine = null,
output_renderer: *scene_output_mod.Renderer = undefined,
// Set when wp_linux_drm_syncobj_v1 is advertised: release points for client
// buffers the glass and window capture passes read (see explicit_sync.c).
read_fence: ?*explicit_sync.ReadFence = null,

output_layout: *wlr.OutputLayout,
new_output: wl.Listener(*wlr.Output) = .init(newOutput),

shell: Shell,
background_tree: *sn.Tree,
desktop_tree: *sn.Tree,
world_desktop_tree: *sn.Tree,
new_layer: wl.Listener(*wlr.LayerSurfaceV1) = .init(newLayer),
wallpaper: ?*ImageBuffer = null,
world: World,
taskbar_tree: *sn.Tree,
// While > 0 `refreshTaskbars` only records the request; see `holdTaskbars`.
taskbar_hold: u32 = 0,
taskbar_hold_pending: bool = false,
overlay_tree: *sn.Tree,
ime_tree: *sn.Tree,
lock_tree: *sn.Tree,
brightness: @import("brightness.zig") = .{},
keyboard_brightness: @import("brightness.zig") = .{ .kind = .keyboard },
power_policy: @import("session/power_policy.zig") = .{},
switcher: @import("Switcher.zig") = .{},
night_light: @import("night_light/NightLight.zig").NightLight = .{},
locker: ?*@import("session/lock.zig").Lock = null,
/// `rediwm --greeter`: rediwm-dm's greeter, locked for its whole life.
greeter_mode: bool = false,
outputs: wl.list.Head(Output, .link) = undefined,
layer_surfaces: wl.list.Head(@import("LayerSurface.zig"), .link) = undefined,

input: Input,
activation: @import("input/activation.zig") = .{},
extra_protocols: ?*@import("extra_protocols.zig").Protocols = null,
launch_feedback: @import("launch_feedback.zig") = .{},
window_tabs: @import("window_tabs.zig") = .{},
text_input: ?*@import("input/text_input.zig") = null,
virtual_input: ?*VirtualInput = null,
compositor: *wlr.Compositor = undefined,
xdg_output_manager: ?*wlr.XdgOutputManagerV1 = null,
xwayland: ?*Xwayland = null,
idle: ?*idle_mod.IdleManager = null,
shutting_down: bool = false,

// Optional: PipeWire/PulseAudio may not be running (see audio/pipewire.zig's
// module doc comment on the two-tier lock/wait discipline this owns).
// `null` means audio control is disabled — every consumer (control center's
// Sound section, the taskbar volume tray, the `SetMasterVolume`-family IPC
// actions) already treats that as "unsupported", not a crash.
audio: ?*audio_mod.AudioManager = null,
audio_wake_source: ?*wl.EventSource = null,

// Kernel power_supply uevents (see taskbar/battery.zig). Without them the
// taskbar still picks up plug changes on its minute tick.
battery_uevent_fd: ?std.posix.fd_t = null,
battery_uevent_source: ?*wl.EventSource = null,
battery_warning: battery_mod.Warning = .{},
battery_warning_id: ?u32 = null,

// Optional for the same reason `audio` is: a spawn/eventfd failure just
// means every consumer's `server.iconLookup(...)` reports `.missing`
// forever, matching how a themeless/iconless desktop already renders (the
// hand-drawn fallback tiles in Taskbar.zig, no icon in the titlebar).
icon_service: ?*icon_service_mod.IconService = null,
theme_job: ?*@import("config_runtime/theme_job.zig").Job = null,
icon_wake_source: ?*wl.EventSource = null,

scale_override: ?f32 = null,
icon_theme_cfg: icon_theme.Config = .{ .theme_name = "", .base_dirs = &.{} },
startup_warmup: @import("startup_warmup.zig") = .{},
session_startup: @import("session/startup.zig") = .{},
startup_tasks: @import("startup_tasks.zig") = .{},
reveal: @import("reveal.zig") = .{},
/// The compositor-drawn desktop, while `[desktop] enabled`.
desktop: ?*@import("desktop/embedded.zig").Desktop = null,
io: std.Io,
environ: std.process.Environ,
/// Original argv, for `restart_shell`'s re-exec (see config/actions.zig).
/// Points into process-owned memory that outlives the whole program, so
/// this is just a borrowed slice of pointers, not an owned copy.
argv: []const [*:0]const u8 = &.{},
restart_requested: bool = false,
theme_path: ?[]const u8 = null,
config: config_loader.Config = undefined,
config_watcher: ?watcher_mod.ConfigWatcher = null,
config_generation: u64 = 1,
config_reload_error: ?[]const u8 = null,
layout_keyboard: ?*@import("Keyboard.zig") = null,
start_menu_catalog: *applications.Catalog,
launcher_history: @import("start_menu/history.zig").History = .{},
/// Memoizes `iconNameForAppId`, which is three linear scans over the whole
/// desktop-entry catalog (~400 entries here). `syncChrome` calls `iconLookup`
/// on every client surface commit, so without this the compositor ran those
/// scans ~60 times a second per damaging window purely to re-derive a constant.
icon_names: IconNameCache = .{},
catalog_wake_source: ?*wl.EventSource = null,
systemd_client: ?*@import("systemd.zig").Client = null,
wallpaper_displayed_path: ?[]u8 = null,
wallpaper_failed: bool = false,
wallpaper_loader: ?*wallpaper_load.Loader = null,
wallpaper_wake_source: ?*wl.EventSource = null,
/// The file shown or being loaded for `[compositor] wallpaper` (gpa-owned);
/// null after a load failed, so choosing it again retries.
wallpaper_source: ?[]u8 = null,
/// The Appearance page's preview of `wallpaper` (gpa-owned).
wallpaper_thumb: ?wallpaper_load.Thumb = null,
/// User-owned public snapshot directory, provisioned by rediwm-dm.
login_appearance_dir: ?[]u8 = null,

ipc: ?*ipc_server.Server = null,
ipc_socket_path: ?[]const u8 = null,
wl_server_socket_name: ?[]const u8 = null,
next_toplevel_id: u64 = 1,
undo: undo_mod.Undo = .{},
screenshot_mgr: ?*screenshot.Manager = null,
screenshot_selector: @import("screenshot/selector.zig") = .{},
capture_mgr: ?*capture.Manager = null,
/// wlr-foreign-toplevel-management; not advertised by the greeter.
foreign_toplevels: ?*wlr.ForeignToplevelManagerV1 = null,
/// wlr-output-management; not advertised by the greeter.
output_management: ?*@import("output_management.zig").Manager = null,
/// wlr-output-power-management; not advertised by the greeter.
output_power: ?*@import("output_power.zig").Manager = null,
/// ext-session-lock; the greeter is itself a lock and never advertises it.
session_lock: ?*@import("session/client_lock.zig").Manager = null,
/// wp-security-context-v1; not advertised by the greeter.
security_context: ?*wlr.SecurityContextManagerV1 = null,
security_context_destroy: wl.Listener(void) = .init(handleSecurityContextDestroy),
security_context_commit: wl.Listener(*wlr.SecurityContextManagerV1.event.Commit) = .init(handleSecurityContextCommit),
notifications: ?*notifications_mod.Manager = null,
polkit: ?*polkit_mod.Agent = null,
polkit_dialog: ?*@import("polkit/dialog.zig").Dialog = null,
tray: ?*@import("tray.zig").Tray = null,
power: ?*power_mod.Manager = null,
power_profiles: ?*power_profiles_mod.Manager = null,
/// Moves launched apps into their own systemd scopes; null in the greeter
/// and nested sessions.
app_scopes: ?*@import("session/app_scope.zig").Scopes = null,
network: ?*@import("network/manager.zig").Manager = null,
bluetooth: ?*@import("bluetooth.zig").Manager = null,
services: ?*services_mod.Manager = null,
qt_app_colors: bool = false,
pending_launches: std.ArrayList(*@import("start_menu/launch.zig").Pending) = .empty,
layout_autosave: ?*layout_autosave_mod.Autosave = null,
session: ?*wlr.Session = null,
session_active: wl.Listener(void) = .init(handleSessionActive),

pub fn findToplevelById(server: *Server, id: u64) ?*@import("Toplevel.zig") {
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (toplevel.id == id) return toplevel;
    }
    return null;
}

/// Raw CLOCK_MONOTONIC milliseconds for the undo coalescing window.
/// Must NOT use anim.nowMs() — integration tests pin that clock to a fixed
/// value, which would coalesce every zoom step into the first one forever.
pub fn undoNowMs() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000),
        else => return 0,
    }
}

/// Resolves an `ext_foreign_toplevel_handle_v1` back to the live `Toplevel`
/// that published it (`capture/manager.zig`'s `new_request` handler needs
/// this; the handle carries no back-pointer of its own).
pub fn findToplevelByForeignHandle(server: *Server, handle: *wlr.ExtForeignToplevelHandleV1) ?*@import("Toplevel.zig") {
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (toplevel.foreign_handle == handle) return toplevel;
    }
    return null;
}

pub fn findOutputByName(server: *Server, name: []const u8) ?*Output {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        const out_name = std.mem.span(output.wlr_output.name);
        if (std.mem.eql(u8, out_name, name)) return output;
    }
    return null;
}

pub fn initIpc(server: *Server, wayland_display: []const u8) !void {
    server.wl_server_socket_name = wayland_display;
    const ipc = try ipc_server.Server.create(server, wayland_display, @import("main.zig").gpa);
    server.ipc = ipc;
    server.ipc_socket_path = ipc.socket_path;
    log.info("IPC listening on REDIWM_SOCKET={s}", .{ipc.socket_path});
}

pub fn deinitIpc(server: *Server) void {
    if (server.ipc) |ipc| {
        ipc.deinit();
        server.ipc = null;
        server.ipc_socket_path = null;
    }
}

pub fn getDefaultOutput(server: *Server) ?*Output {
    if (Output.atLayout(server, server.input.cursor.x, server.input.cursor.y)) |output| {
        if (output.isAvailable()) return output;
    }
    if (server.effectivePrimaryOutput()) |output| return output;
    return firstAvailableOutput(server);
}

pub fn preferredPrimaryOutput(server: *Server) ?*Output {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (!output.isLogicallyEnabled()) continue;
        if (Output.configured(server, output.wlr_output)) |config| {
            if (config.primary) return output;
        }
    }
    return null;
}

pub fn effectivePrimaryOutput(server: *Server) ?*Output {
    if (server.preferredPrimaryOutput()) |output| if (output.isAvailable()) return output;
    return server.firstAvailableOutput();
}

pub fn firstAvailableOutput(server: *Server) ?*Output {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.isAvailable()) return output;
    }
    return null;
}

const setup = @import("server/setup.zig");
pub fn init(server: *Server, scale: ?f32, icon_theme_cfg: icon_theme.Config, io: std.Io, environ: std.process.Environ, theme_path: ?[]const u8, argv: []const [*:0]const u8, greeter: bool) CompositorError!void {
    return setup.init(server, scale, icon_theme_cfg, io, environ, theme_path, argv, greeter);
}

/// The greeter never writes a config: REDIWM_CONFIG, else the administrator's
/// /etc/rediwm/greeter.toml, else built-in defaults.
pub fn loadGreeterConfig(io: std.Io, environ: std.process.Environ) !config_loader.Config {
    const allocator = @import("main.zig").gpa;
    const path = if (environ.getPosix("REDIWM_CONFIG")) |p| (if (p.len > 0) p else null) else null;
    const system = "/etc/rediwm/greeter.toml";
    if (path) |p| return parseGreeterFile(p, allocator, io);
    std.Io.Dir.cwd().access(io, system, .{}) catch return config_loader.default(allocator);
    return parseGreeterFile(system, allocator, io);
}

pub fn executeAction(server: *Server, action: config_actions.Action) void {
    config_actions.executeAction(server, action);
}

pub fn spawnAutostart(server: *Server) void {
    config_actions.spawnAutostart(server);
}

pub fn applyChildEnv(server: *Server, map: *child_env.Map) !void {
    try server.applyChildEnvWithToken(map, null);
}

pub fn applyChildEnvWithToken(server: *Server, map: *child_env.Map, token: ?[]const u8) !void {
    const allocator = @import("main.zig").gpa;
    const dir = try std.process.executableDirPathAlloc(server.io, allocator);
    defer allocator.free(dir);
    const inherited_path = map.get("PATH") orelse "";
    const path = if (inherited_path.len == 0) try allocator.dupe(u8, dir) else try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ dir, std.fs.path.delimiter, inherited_path });
    defer allocator.free(path);
    try map.put("PATH", path);

    try child_env.apply(map, .{
        .qt_app_colors = !server.greeter_mode and server.qt_app_colors,
        .region = server.config.region,
        .input_method = server.config.input_method.env,
        .app_scopes = server.app_scopes != null,
        .wayland_display = server.wl_server_socket_name,
        .ipc_socket = server.ipc_socket_path,
        .x11_display = if (server.xwayland) |xw| xw.displayName() else null,
        .activation_token = token,
        .cursor_theme = cursor_theme.managerTheme(server.config.input.cursor_theme),
        .cursor_size = server.config.input.cursor_size,
        .cursor_path = cursor_theme.childSearchPath(),
    });
}

// server/xwayland_scale.zig
pub const configuredXwaylandNativeScaling = server_xwayland_scale.configuredXwaylandNativeScaling;
pub const computeXwaylandScale = server_xwayland_scale.computeXwaylandScale;
pub const xwaylandScale = server_xwayland_scale.xwaylandScale;
pub const xwaylandScalePending = server_xwayland_scale.xwaylandScalePending;

// server/session.zig
pub const terminate = server_session.terminate;
pub const deactivateSession = server_session.deactivateSession;
pub const reactivateSession = server_session.reactivateSession;
pub const handleSessionActive = server_session.handleSessionActive;
pub const handleSecurityContextDestroy = server_session.handleSecurityContextDestroy;
pub const handleSecurityContextCommit = server_session.handleSecurityContextCommit;
pub const getSystemd = server_session.getSystemd;
pub const startDesktopService = server_session.startDesktopService;

const teardown = @import("server/teardown.zig");
pub fn deinit(server: *Server) void {
    teardown.deinit(server);
}

// server/frame.zig
pub const buildOutputState = server_frame.buildOutputState;
pub const sendFrameDone = server_frame.sendFrameDone;
pub const beginRenderPass = server_frame.beginRenderPass;
pub const maxOutputScale = server_frame.maxOutputScale;

// server/outputs.zig
pub const newOutput = server_outputs.newOutput;

// server/taskbars.zig
pub const refreshTaskbars = server_taskbars.refreshTaskbars;
pub const holdTaskbars = server_taskbars.holdTaskbars;
pub const releaseTaskbars = server_taskbars.releaseTaskbars;
pub const refreshTaskbarsGeometry = server_taskbars.refreshTaskbarsGeometry;
pub const applyTaskbarPosition = server_taskbars.applyTaskbarPosition;
pub const updateTaskbarFullscreenVisibility = server_taskbars.updateTaskbarFullscreenVisibility;

/// Starts or stops the compositor-drawn desktop to match `[desktop] enabled`.
pub fn syncDesktop(server: *Server) void {
    if (config_loader.desktopEnabled(&server.config) == (server.desktop != null)) return;
    if (server.desktop) |desktop| {
        desktop.destroy();
        server.desktop = null;
        server.scheduleFrames();
        return;
    }
    server.desktop = @import("desktop/embedded.zig").Desktop.create(server) catch |err| blk: {
        log.err("desktop: {}", .{err});
        break :blk null;
    };
    if (server.desktop) |desktop| desktop.app.worker.updateTheme(server.icon_theme_cfg);
}

/// Shows the control center's Appearance page on the output under the cursor.
pub fn openAppearance(server: *Server) void {
    const output = server.getDefaultOutput() orelse return;
    output.toggleControlCenter();
    if (server.input.open_control_center) |cc| {
        cc.selectPage(.appearance);
        cc.requestRepaint();
    }
}

pub fn scheduleFrames(server: *Server) void {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.wlr_output.scheduleFrame();
}

// server/icons.zig
pub const iconLookup = server_icons.iconLookup;
pub const iconNameForAppId = server_icons.iconNameForAppId;
pub const iconAcquire = server_icons.iconAcquire;
pub const iconRelease = server_icons.iconRelease;
pub const iconPrefetch = server_icons.iconPrefetch;
pub const iconCancelSpeculative = server_icons.iconCancelSpeculative;
pub const iconInvalidateAll = server_icons.iconInvalidateAll;

/// Small direct-mapped memo for resolved icon names, keyed by app_id and
/// invalidated wholesale whenever the catalog publishes a new generation.
/// Names or app_ids longer than `max_len` simply bypass it and rescan.
pub const IconNameCache = struct {
    pub const capacity = 32;
    pub const max_len = 96;

    pub const Entry = struct {
        app_id: [max_len]u8 = undefined,
        app_id_len: u8 = 0,
        name: [max_len]u8 = undefined,
        name_len: u8 = 0,
        filled: bool = false,
    };

    entries: [capacity]Entry = @splat(.{}),
    generation: u64 = 0,
    primed: bool = false,

    pub fn slot(app_id: []const u8) usize {
        return std.hash.Wyhash.hash(0, app_id) % capacity;
    }

    /// The returned slice is owned by the cache (stable until the entry is
    /// replaced) or borrowed from `snap` on the uncached path, so callers must
    /// keep `snap` retained for the rest of the call either way.
    pub fn resolve(self: *IconNameCache, snap: *applications.Snapshot, app_id: []const u8) []const u8 {
        if (!self.primed or self.generation != snap.generation) {
            self.generation = snap.generation;
            self.primed = true;
            for (&self.entries) |*e| e.filled = false;
        }
        if (app_id.len == 0 or app_id.len > max_len) return iconNameForAppId(snap, app_id);

        const index = slot(app_id);
        const entry = &self.entries[index];
        if (entry.filled and std.mem.eql(u8, entry.app_id[0..entry.app_id_len], app_id)) {
            return entry.name[0..entry.name_len];
        }

        const resolved = iconNameForAppId(snap, app_id);
        if (resolved.len > max_len) return resolved;
        entry.app_id_len = @intCast(app_id.len);
        @memcpy(entry.app_id[0..app_id.len], app_id);
        entry.name_len = @intCast(resolved.len);
        @memcpy(entry.name[0..resolved.len], resolved);
        entry.filled = true;
        return entry.name[0..entry.name_len];
    }
};

// server/wakeups.zig
pub const createAudioWakeFd = server_wakeups.createAudioWakeFd;
pub const handleAudioWake = server_wakeups.handleAudioWake;
pub const handleBatteryUevent = server_wakeups.handleBatteryUevent;
pub const updateBatteryWarning = server_wakeups.updateBatteryWarning;
pub const ensureGpuTimer = server_wakeups.ensureGpuTimer;
pub const keepGpuTimer = server_wakeups.keepGpuTimer;
pub const observingStats = server_wakeups.observingStats;
pub const expireGpuTimer = server_wakeups.expireGpuTimer;

pub const gpu_timer_idle_ns: u64 = 5 * 60 * std.time.ns_per_s;

// server/wallpaper.zig
pub const themeColorArgb = server_wallpaper.themeColorArgb;
pub const applyDecodedWallpaper = server_wallpaper.applyDecodedWallpaper;
pub const handleCatalogWake = server_wallpaper.handleCatalogWake;
pub const reloadWallpaper = server_wallpaper.reloadWallpaper;
pub const saveLoginTheme = server_wallpaper.saveLoginTheme;
pub const loadWallpaper = server_wallpaper.loadWallpaper;
pub const stopWallpaperLoad = server_wallpaper.stopWallpaperLoad;
pub const forgetWallpaperSource = server_wallpaper.forgetWallpaperSource;
pub const handleWallpaperWake = server_wallpaper.handleWallpaperWake;
pub const handleIconWake = server_wallpaper.handleIconWake;

pub fn newLayer(listener: *wl.Listener(*wlr.LayerSurfaceV1), layer: *wlr.LayerSurfaceV1) void {
    const server: *Server = @fieldParentPtr("new_layer", listener);
    @import("LayerSurface.zig").create(server, layer) catch {
        layer.destroy();
    };
}

pub fn configurePolkit(server: *Server, config: config_loader.PolkitConfig) void {
    if (server.polkit == null and config.enable) {
        server.polkit = polkit_mod.Agent.create(@import("main.zig").gpa, server.wl_server.getEventLoop(), server.environ, server, polkitState) catch |err| {
            log.warn("could not create polkit agent: {}", .{err});
            polkitState(server, .unavailable);
            return;
        };
        if (server.polkit) |agent| {
            agent.setLocale(@import("i18n").resolve(server.config.region.language, server.environ)) catch |err| log.warn("could not set authentication language: {}", .{err});
            agent.conversation = .{ .owner = server, .opened = @import("polkit/dialog.zig").Dialog.opened, .event = @import("polkit/dialog.zig").Dialog.event };
            if (server.locker != null) agent.pauseForLock();
        }
    }
    if (server.polkit) |agent| agent.configure(config.enable, config.helper_socket) catch |err| {
        log.warn("could not configure polkit agent: {}", .{err});
        polkitState(server, .unavailable);
    };
}

pub fn polkitState(owner: ?*anyopaque, state: polkit_mod.Agent.State) void {
    if (state != .unavailable) return;
    const server: *Server = @ptrCast(@alignCast(owner.?));
    if (server.notifications) |mgr| {
        _ = mgr.postNotification("Authentication", 0, "", "Authentication agent unavailable", "Could not register with polkit. Another authentication agent may already be running.", &.{}, 1, false, true, 6000, "", null) catch {};
    }
}

pub fn parseGreeterFile(path: []const u8, a: std.mem.Allocator, io: std.Io) !config_loader.Config {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    defer a.free(bytes);
    return config_loader.parse(a, bytes, path);
}

pub fn enablePolygons(context: *anyopaque) bool {
    const server: *Server = @ptrCast(@alignCast(context));
    return server.output_renderer.enablePolygons();
}
