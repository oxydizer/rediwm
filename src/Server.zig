const std = @import("std");

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");

const audio_mod = @import("audio/pipewire.zig");
const cursor_theme = @import("cursor_theme.zig");
const battery_mod = @import("taskbar/battery.zig");
const ImageBuffer = @import("ImageBuffer.zig");
const Input = @import("Input.zig");
const Output = @import("Output.zig");
const Taskbar = @import("Taskbar.zig");
const Shell = @import("Shell.zig");
const World = @import("World.zig");
const geometry = @import("geometry.zig");
const icon_theme = @import("icon_theme.zig");
const icon_service_mod = @import("icon_service.zig");
const glass = @import("glass.zig");
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
const wallpapers = @import("wallpapers.zig");
const startup = @import("startup.zig");
const png = @import("png.zig");

const Server = @This();

const log = std.log.scoped(.compositor);

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
allocator: *wlr.Allocator,
scene: *wlr.Scene,
glass_engine: ?*glass.Engine = null,
// Set when wp_linux_drm_syncobj_v1 is advertised: release points for client
// buffers the glass and window capture passes read (see explicit_sync.c).
read_fence: ?*explicit_sync.ReadFence = null,

output_layout: *wlr.OutputLayout,
scene_output_layout: *wlr.SceneOutputLayout,
new_output: wl.Listener(*wlr.Output) = .init(newOutput),

shell: Shell,
background_tree: *wlr.SceneTree,
desktop_tree: *wlr.SceneTree,
world_desktop_tree: *wlr.SceneTree,
new_layer: wl.Listener(*wlr.LayerSurfaceV1) = .init(newLayer),
wallpaper: ?*ImageBuffer = null,
world: World,
taskbar_tree: *wlr.SceneTree,
// While > 0 `refreshTaskbars` only records the request; see `holdTaskbars`.
taskbar_hold: u32 = 0,
taskbar_hold_pending: bool = false,
overlay_tree: *wlr.SceneTree,
ime_tree: *wlr.SceneTree,
lock_tree: *wlr.SceneTree,
brightness: @import("brightness.zig") = .{},
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

// Optional for the same reason `audio` is: a spawn/eventfd failure just
// means every consumer's `server.iconLookup(...)` reports `.missing`
// forever, matching how a themeless/iconless desktop already renders (the
// hand-drawn fallback tiles in Taskbar.zig, no icon in the titlebar).
icon_service: ?*icon_service_mod.IconService = null,
icon_wake_source: ?*wl.EventSource = null,

scale_override: ?f32 = null,
icon_theme_cfg: icon_theme.Config = .{ .theme_name = "", .base_dirs = &.{} },
startup_warmup: @import("startup_warmup.zig") = .{},
session_startup: @import("session/startup.zig") = .{},
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

fn firstAvailableOutput(server: *Server) ?*Output {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.isAvailable()) return output;
    }
    return null;
}

pub fn init(server: *Server, scale: ?f32, icon_theme_cfg: icon_theme.Config, io: std.Io, environ: std.process.Environ, theme_path: ?[]const u8, argv: []const [*:0]const u8, greeter: bool) CompositorError!void {
    const wl_server = wl.Server.create() catch return error.ServerCreateFailed;
    errdefer wl_server.destroy();

    var session: ?*wlr.Session = null;
    const backend = wlr.Backend.autocreate(wl_server.getEventLoop(), &session) catch return error.BackendCreateFailed;
    errdefer backend.destroy();

    const renderer = wlr.Renderer.autocreate(backend) catch return error.RendererInitFailed;
    errdefer renderer.destroy();
    const renderer_name: []const u8 = if (renderer.isGles2()) "gles2" else if (renderer.isPixman()) "pixman" else "unknown";
    startup.markRendererReady(renderer_name, scale orelse 1);

    const wlr_allocator = wlr.Allocator.autocreate(backend, renderer) catch return error.AllocatorCreateFailed;
    errdefer wlr_allocator.destroy();

    const output_layout = wlr.OutputLayout.create(wl_server) catch return error.OutputLayoutCreateFailed;
    errdefer output_layout.destroy();

    const scene = wlr.Scene.create() catch return error.SceneCreateFailed;
    errdefer scene.tree.node.destroy();
    // The world source tree stays disabled: projection renders its copies.
    // wlroots would lower each mapped X11 source as if it were hidden,
    // undoing our raise after the map listener runs. Toplevel owns X11
    // stacking alongside its scene ordering instead.
    scene.restack_xwayland_surfaces = false;

    const background_tree = scene.tree.createSceneTree() catch return error.SceneCreateFailed;
    const desktop_tree = scene.tree.createSceneTree() catch return error.SceneCreateFailed;
    const world_tree = scene.tree.createSceneTree() catch return error.SceneCreateFailed;
    const world_desktop_tree = world_tree.createSceneTree() catch return error.SceneCreateFailed;
    const world_view = scene.tree.createSceneTree() catch return error.SceneCreateFailed;
    const taskbar_tree = scene.tree.createSceneTree() catch return error.SceneCreateFailed;
    const overlay_tree = scene.tree.createSceneTree() catch return error.SceneCreateFailed;
    const ime_tree = scene.tree.createSceneTree() catch return error.SceneCreateFailed;
    const lock_tree = scene.tree.createSceneTree() catch return error.SceneCreateFailed;
    const scene_output_layout = scene.attachOutputLayout(output_layout) catch return error.SceneCreateFailed;

    const catalog = applications.Catalog.init(@import("main.zig").gpa, io, environ, !greeter) catch return error.ServerCreateFailed;
    errdefer catalog.deinit();

    var config_load_error: ?[]const u8 = null;
    var loaded = (if (greeter) loadGreeterConfig(io, environ) else config_loader.loadDefault(@import("main.zig").gpa, io, environ)) catch |err| blk: {
        config_load_error = @errorName(err);
        log.warn("config load failed: {}, using defaults", .{err});
        break :blk config_loader.default(@import("main.zig").gpa) catch return error.ServerCreateFailed;
    };
    errdefer loaded.deinit();
    if (greeter) {
        // The greeter shows no windows or desktop and speaks for no one on
        // the session bus; X11 and the authentication agent have no role.
        loaded.compositor.xwayland = false;
        loaded.desktop.enabled = false;
        loaded.polkit.enable = false;
    }
    ui_theme.global = loaded.theme;
    ui_theme.taskbar_override = if (loaded.taskbar_theme) |chosen| ui_theme.taskbarTokens(chosen) else null;
    @import("ui").text.setPreferredFamilies(ui_theme.global.font, ui_theme.global.mono_font);
    // Caret timings are process-wide UI-engine state, like the theme, and the
    // panels paint before any input device exists to carry them in.
    @import("ui").input.caret_config = .{
        .blink_ms = loaded.input.caret_blink_ms,
        .blink_timeout_s = loaded.input.caret_blink_timeout,
        .motion_ms = loaded.input.caret_motion_ms,
    };
    @import("ui").wheel.accel = config_loader.wheelAccel(loaded.input);
    @import("ui").anim.applySettings(loaded.animations);
    @import("camera.zig").zoom_levels = loaded.compositor.zoom_percents;
    startup.markConfigReady(@intCast(loaded.autostart.len));

    server.* = .{
        .wl_server = wl_server,
        .backend = backend,
        .renderer = renderer,
        .allocator = wlr_allocator,
        .scene = scene,
        .background_tree = background_tree,
        .desktop_tree = desktop_tree,
        .world_desktop_tree = world_desktop_tree,
        .taskbar_tree = taskbar_tree,
        .overlay_tree = overlay_tree,
        .ime_tree = ime_tree,
        .lock_tree = lock_tree,
        .output_layout = output_layout,
        .scene_output_layout = scene_output_layout,
        .shell = undefined,
        .world = undefined,
        .input = undefined,
        .scale_override = scale,
        .icon_theme_cfg = icon_theme_cfg,
        .io = io,
        .environ = environ,
        .argv = argv,
        .theme_path = theme_path,
        .config = loaded,
        .config_reload_error = config_load_error,
        .start_menu_catalog = catalog,
        .session = session,
        .greeter_mode = greeter,
    };

    if (!greeter) @import("config_runtime/region.zig").applyTimezone(@import("main.zig").gpa, loaded.region.timezone, environ.getPosix("TZ")) catch |err| {
        log.warn("could not apply personal timezone: {}", .{err});
    };

    // The syncobj global itself is created with the other globals below.
    // REDIWM_NO_EXPLICIT_SYNC=1 withholds it, to tell driver sync bugs apart.
    if (environ.getPosix("REDIWM_NO_EXPLICIT_SYNC") == null and explicit_sync.supported(renderer, backend)) {
        server.read_fence = explicit_sync.ReadFence.create(renderer, wl_server.getEventLoop());
    }
    errdefer explicit_sync.ReadFence.destroy(server.read_fence);

    // REDIWM_NO_GLASS=1 skips the backdrop blur for A/B frame-cost
    // measurements; every glass call already accepts a null engine.
    server.glass_engine = if (environ.getPosix("REDIWM_NO_GLASS") != null) null else glass.Engine.create(renderer, wlr_allocator, scene, server.read_fence);
    errdefer glass.Engine.destroy(server.glass_engine);
    server.outputs.init();
    server.layer_surfaces.init();
    try server.world.init(server, world_tree, world_view);
    errdefer server.world.deinit();
    try server.shell.init(server);
    errdefer server.shell.deinit();
    try server.input.init(server);
    errdefer server.input.deinit();
    if (!greeter) server.extra_protocols = @import("extra_protocols.zig").create(server) orelse return error.ExtraProtocolsCreateFailed;
    errdefer @import("extra_protocols.zig").rediwm_protocols_destroy(server.extra_protocols);
    server.activation.init(server) catch return error.ActivationManagerCreateFailed;
    errdefer server.activation.deinit();
    server.launch_feedback.init(server);
    errdefer server.launch_feedback.deinit();
    server.text_input = @import("input/text_input.zig").create(server) catch return error.TextInputManagerCreateFailed;
    errdefer if (server.text_input) |relay| relay.destroy();

    server.idle = idle_mod.IdleManager.create(server, server.config.idle) catch |err| blk: {
        log.warn("init: could not create idle manager: {}", .{err});
        break :blk null;
    };
    errdefer if (server.idle) |im| im.destroy();

    try server.night_light.init(server, server.config.night_light);
    errdefer server.night_light.deinit();

    if (server.config.path.len > 0 and !greeter) {
        server.config_watcher = watcher_mod.init(server.config.path, server) catch |err| blk: {
            log.warn("config watcher: {}", .{err});
            break :blk null;
        };
    }

    server.virtual_input = VirtualInput.create(server, @import("main.zig").gpa) catch |err| blk: {
        log.err("init: could not create virtual input: {}", .{err});
        break :blk null;
    };

    server.screenshot_mgr = screenshot.Manager.create(server, @import("main.zig").gpa) catch |err| blk: {
        log.err("init: could not create screenshot manager: {}", .{err});
        break :blk null;
    };

    if (!greeter) server.notifications = notifications_mod.Manager.create(server, @import("main.zig").gpa) catch |err| blk: {
        log.warn("init: could not create notifications manager: {}", .{err});
        break :blk null;
    };

    server.power = power_mod.Manager.create(server, @import("main.zig").gpa) catch |err| blk: {
        log.warn("init: could not create power manager: {}", .{err});
        break :blk null;
    };

    server.power_profiles = power_profiles_mod.Manager.create(server, @import("main.zig").gpa) catch |err| blk: {
        log.warn("init: could not create power profiles manager: {}", .{err});
        break :blk null;
    };

    if (!greeter) server.network = @import("network/manager.zig").Manager.create(server) catch null;
    if (!greeter and @import("session/app_scope.zig").enabled(environ))
        server.app_scopes = @import("session/app_scope.zig").Scopes.create(@import("main.zig").gpa, server.wl_server.getEventLoop(), environ) catch null;

    server.configurePolkit(server.config.polkit);

    if (!greeter) server.services = services_mod.Manager.create(server, @import("main.zig").gpa) catch |err| blk: {
        log.warn("init: could not create services manager: {}", .{err});
        break :blk null;
    };

    if (!greeter) server.layout_autosave = layout_autosave_mod.Autosave.create(server) catch |err| blk: {
        log.warn("init: could not create layout autosave: {}", .{err});
        break :blk null;
    };

    if (!greeter) server.audio = audio_mod.AudioManager.createAsync(@import("main.zig").gpa) catch |err| blk: {
        log.warn("init: PipeWire/PulseAudio not available, audio control disabled: {}", .{err});
        break :blk null;
    };
    if (server.audio) |mgr| {
        if (createAudioWakeFd()) |fd| {
            mgr.setWakeFd(fd);
            server.audio_wake_source = server.wl_server.getEventLoop().addFd(*Server, fd, .{ .readable = true }, handleAudioWake, server) catch |err| blk: {
                log.warn("init: could not register audio wake fd: {}", .{err});
                break :blk null;
            };
        } else {
            log.warn("init: could not create audio wake eventfd; taskbar/UI may lag behind external volume changes", .{});
        }
    }

    if (battery_mod.openUeventSocket()) |fd| {
        server.battery_uevent_fd = fd;
        server.battery_uevent_source = server.wl_server.getEventLoop().addFd(*Server, fd, .{ .readable = true }, handleBatteryUevent, server) catch |err| blk: {
            log.warn("init: could not register power_supply uevent fd: {}", .{err});
            break :blk null;
        };
    } else {
        log.warn("init: no kernel uevent socket; taskbar battery updates once a minute", .{});
    }

    server.icon_service = icon_service_mod.IconService.create(@import("main.zig").gpa, server.icon_theme_cfg, io) catch |err| blk: {
        log.warn("init: could not start icon service, icons disabled: {}", .{err});
        break :blk null;
    };
    if (server.icon_service) |svc| {
        server.icon_wake_source = server.wl_server.getEventLoop().addFd(*Server, svc.wakeFd(), .{ .readable = true }, handleIconWake, server) catch |err| blk: {
            log.warn("init: could not register icon wake fd: {}", .{err});
            break :blk null;
        };
    }

    server.wallpaper = ImageBuffer.createSolid(1, 1, themeColorArgb(ui_theme.global.bg)) catch |err| blk: {
        log.warn("init: failed to create solid wallpaper: {}", .{err});
        break :blk null;
    };
    errdefer if (server.wallpaper) |image| image.base.drop();

    const loop = server.wl_server.getEventLoop();
    server.catalog_wake_source = loop.addFd(*Server, catalog.wakeFd(), .{ .readable = true }, handleCatalogWake, server) catch |err| blk: {
        log.warn("init: could not register catalog wake fd: {}", .{err});
        break :blk null;
    };
    errdefer if (server.catalog_wake_source) |source| source.remove();
    if (!greeter) catalog.attachWatch(loop);

    server.loadWallpaper(startup.envDelayNs(environ, "REDIWM_WALLPAPER_DECODE_DELAY_MS"));
    errdefer {
        server.stopWallpaperLoad();
        server.forgetWallpaperSource();
    }

    server.renderer.initServer(wl_server) catch return error.ShmInitFailed;

    const compositor = wlr.Compositor.create(server.wl_server, 6, server.renderer) catch return error.CompositorCreateFailed;
    server.compositor = compositor;
    server.world.projection.watch(compositor);
    _ = wlr.Subcompositor.create(server.wl_server) catch return error.SubcompositorCreateFailed;
    _ = wlr.DataDeviceManager.create(server.wl_server) catch return error.DataDeviceManagerCreateFailed;
    _ = wlr.DataControlManagerV1.create(server.wl_server) catch return error.DataControlManagerCreateFailed;
    _ = wlr.ExtDataControlManagerV1.create(server.wl_server, 1) catch return error.DataControlManagerCreateFailed;
    _ = wlr.PrimarySelectionDeviceManagerV1.create(server.wl_server) catch return error.PrimarySelectionManagerCreateFailed;
    _ = wlr.Viewporter.create(server.wl_server) catch return error.ViewporterCreateFailed;
    _ = wlr.FractionalScaleManagerV1.create(server.wl_server, 1) catch return error.FractionalScaleManagerCreateFailed;
    _ = wlr.SinglePixelBufferManagerV1.create(server.wl_server) catch return error.SinglePixelBufferManagerCreateFailed;
    // Soft-fail, not a CompositorError: a software renderer (pixman, used by
    // most headless tests) may not support dmabuf import at all, in which
    // case this simply advertises zero formats rather than blocking startup.
    _ = wlr.LinuxDmabufV1.createWithRenderer(server.wl_server, 4, server.renderer) catch |err| {
        log.warn("init: could not create linux-dmabuf manager, dmabuf clients disabled: {}", .{err});
    };
    // Explicit sync: the proprietary NVIDIA driver has no implicit sync, so
    // without it Xwayland and Vulkan clients flicker or show torn frames.
    // wlr_scene waits on acquire points and signals release points; the
    // compositor's own reads of client buffers go through server.read_fence.
    if (server.read_fence != null) {
        if (wlr.LinuxDrmSyncobjManagerV1.create(server.wl_server, 1, server.renderer.getDrmFd())) |_| {
            log.info("init: explicit sync (linux-drm-syncobj-v1) enabled", .{});
        } else {
            log.warn("init: could not create linux-drm-syncobj manager, explicit sync disabled", .{});
        }
    } else {
        log.info("init: explicit sync unavailable (renderer/backend lack timelines or disabled)", .{});
    }
    server.xdg_output_manager = wlr.XdgOutputManagerV1.create(server.wl_server, server.output_layout) catch return error.XdgOutputManagerCreateFailed;
    _ = wlr.Presentation.create(server.wl_server, server.backend, 2) catch return error.PresentationCreateFailed;
    server.capture_mgr = capture.Manager.create(server) catch |err| blk: {
        log.warn("init: could not create screen-capture manager, sharing disabled: {}", .{err});
        break :blk null;
    };
    if (!greeter) {
        server.foreign_toplevels = wlr.ForeignToplevelManagerV1.create(server.wl_server) catch |err| blk: {
            log.warn("init: could not create wlr foreign-toplevel manager: {}", .{err});
            break :blk null;
        };
        server.output_management = @import("output_management.zig").Manager.create(server) catch |err| blk: {
            log.warn("init: could not create output-management manager: {}", .{err});
            break :blk null;
        };
        server.output_power = @import("output_power.zig").Manager.create(server) catch |err| blk: {
            log.warn("init: could not create output-power manager: {}", .{err});
            break :blk null;
        };
        server.session_lock = @import("session/client_lock.zig").Manager.create(server) catch |err| blk: {
            log.warn("init: could not create session-lock manager: {}", .{err});
            break :blk null;
        };
        server.security_context = wlr.SecurityContextManagerV1.create(server.wl_server) catch |err| blk: {
            log.warn("init: could not create security-context manager: {}", .{err});
            break :blk null;
        };
        if (server.security_context) |mgr| {
            mgr.events.destroy.add(&server.security_context_destroy);
            mgr.events.commit.add(&server.security_context_commit);
        }
    }
    _ = Xwayland.create(server);

    const layer_shell = wlr.LayerShellV1.create(wl_server, 4) catch return error.CompositorCreateFailed;
    layer_shell.events.new_surface.add(&server.new_layer);
    server.backend.events.new_output.add(&server.new_output);
    if (server.session) |s| {
        s.events.active.add(&server.session_active);
    }
    @import("global_filter.zig").install(server);
}

/// The greeter never writes a config: REDIWM_CONFIG, else the administrator's
/// /etc/rediwm/greeter.toml, else built-in defaults.
fn loadGreeterConfig(io: std.Io, environ: std.process.Environ) !config_loader.Config {
    const allocator = @import("main.zig").gpa;
    const path = if (environ.getPosix("REDIWM_CONFIG")) |p| (if (p.len > 0) p else null) else null;
    const system = "/etc/rediwm/greeter.toml";
    if (path) |p| return config_loader.load(p, allocator, io, environ);
    std.Io.Dir.cwd().access(io, system, .{}) catch return config_loader.default(allocator);
    return config_loader.load(system, allocator, io, environ);
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
        .region = server.config.region,
        .input_method = server.config.input_method.env,
        .wayland_display = server.wl_server_socket_name,
        .ipc_socket = server.ipc_socket_path,
        .x11_display = if (server.xwayland) |xw| xw.displayName() else null,
        .activation_token = token,
        .cursor_theme = cursor_theme.managerTheme(server.config.input.cursor_theme),
        .cursor_size = server.config.input.cursor_size,
        .cursor_path = cursor_theme.childSearchPath(),
    });
}

pub fn configuredXwaylandNativeScaling(server: *Server) bool {
    return server.config.compositor.xwayland_native_scaling or server.config.compositor.xwayland_scale != 0;
}

pub fn computeXwaylandScale(server: *Server) f64 {
    if (server.config.compositor.xwayland_scale != 0) return server.config.compositor.xwayland_scale;
    if (!server.config.compositor.xwayland_native_scaling) return 1;
    var factor: f64 = 1;
    var have_output = false;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.isLogicallyEnabled() and output.wlr_output.enabled) {
            have_output = true;
            factor = @max(factor, @as(f64, @ceil(output.wlr_output.scale)));
        }
    }
    if (!have_output and server.config.compositor.xwayland_native_scaling) {
        if (server.scale_override) |scale| factor = @ceil(scale);
    }
    return factor;
}

pub fn xwaylandScale(server: *Server) f64 {
    if (server.xwayland) |xw| return xw.scale;
    return server.computeXwaylandScale();
}

pub fn xwaylandScalePending(server: *Server) ?f64 {
    const xwayland = server.xwayland orelse return null;
    const desired = server.computeXwaylandScale();
    if (desired != xwayland.scale or server.configuredXwaylandNativeScaling() != xwayland.native_scaling) return desired;
    return null;
}

pub fn terminate(server: *Server) void {
    if (server.shutting_down) return;
    server.shutting_down = true;
    log.info("terminating compositor session", .{});
    if (server.layout_autosave) |as| as.saveNow();
    // Unwind the event callback before tearing down clients. deinit destroys
    // the owned Xwayland server first; disconnecting its Wayland client here
    // would trigger wlroots' crash recovery and start it again during logout.
    server.wl_server.terminate();
}

pub fn deactivateSession(server: *Server) void {
    if (server.polkit) |agent| {
        if (server.locker != null) agent.pauseForLock() else agent.cancelAll();
    }
    log.info("deactivating session: cancelling grabs, focus and menus", .{});
    server.input.clearGrab();
    server.screenshot_selector.cancel();
    server.switcher.cancel();

    if (server.input.gesture != .none) {
        if (server.input.gesture == .compositor_pinch or server.input.gesture == .client_pinch) {
            server.input.handlePinchEnd(0, true);
        } else if (server.input.gesture == .compositor_swipe or server.input.gesture == .client_swipe) {
            server.input.handleSwipeEnd(0, true);
        }
    }
    if (server.input.finger_pan) {
        server.input.finger_pan = false;
        server.world.cancelPan();
    }

    server.input.seat.keyboardEndGrab();
    server.input.seat.pointerEndGrab();
    server.input.window_menu.close();
    server.input.seat.keyboardClearFocus();
    server.input.seat.pointerClearFocus();
    server.input.setDefaultCursor();
    @import("ui").input.reset();

    var it = server.outputs.iterator(.forward);
    while (it.next()) |out| {
        out.closeStartMenu();
        out.closePowerMenu();
        out.closeBattery();
        out.closeWifi();
    }
    if (server.input.open_control_center) |cc| cc.pointer_down = false;

    if (server.layout_autosave) |as| as.saveNow();
}

pub fn reactivateSession(server: *Server) void {
    log.info("reactivating session: restoring output layout, damage and presentation", .{});
    Output.syncLayout(server);
    server.input.refreshOutputScales();

    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (server.scene.getSceneOutput(output.wlr_output)) |so| {
            so.damage_ring.addWhole();
        }
        output.wlr_output.scheduleFrame();
    }
}

fn handleSessionActive(listener: *wl.Listener(void)) void {
    const server: *Server = @fieldParentPtr("session_active", listener);
    const session = server.session orelse return;
    if (session.active) {
        log.info("session became active (VT switch back)", .{});
        server.reactivateSession();
    } else {
        log.info("session became inactive (VT switch away)", .{});
        server.deactivateSession();
    }
}

fn handleSecurityContextDestroy(listener: *wl.Listener(void)) void {
    const server: *Server = @fieldParentPtr("security_context_destroy", listener);
    server.security_context = null;
    server.security_context_destroy.link.remove();
    server.security_context_commit.link.remove();
}

fn handleSecurityContextCommit(listener: *wl.Listener(*wlr.SecurityContextManagerV1.event.Commit), event: *wlr.SecurityContextManagerV1.event.Commit) void {
    _ = listener;
    const engine = if (event.state.sandbox_engine) |s| std.mem.span(s) else "<unspecified>";
    const app_id = if (event.state.app_id) |s| std.mem.span(s) else "<unspecified>";
    const instance_id = if (event.state.instance_id) |s| std.mem.span(s) else "<unspecified>";
    log.info("security-context: commit engine='{s}' app_id='{s}' instance_id='{s}'", .{ engine, app_id, instance_id });
}

pub fn getSystemd(server: *Server) !*@import("systemd.zig").Client {
    if (server.greeter_mode) return error.ServicesUnavailable;
    if (server.systemd_client) |client| return client;
    const client = try @import("systemd.zig").Client.create(server);
    server.systemd_client = client;
    client.watching = true;
    return client;
}

pub fn deinit(server: *Server) void {
    // terminate saved the layout before leaving the event loop. Only paths
    // such as restart_shell, which stop the display directly, need to save it
    // here. In both cases save before tearing down Xwayland or native clients.
    const already_terminating = server.shutting_down;
    server.shutting_down = true;
    server.session_startup.deinit();
    if (!already_terminating) {
        if (server.layout_autosave) |as| as.saveNow();
    }
    server.screenshot_selector.cancel();
    @import("clipboard.zig").cancelImageTransfers();
    // Shutting down, its window is freed at once rather than animating out.
    if (server.input.open_control_center) |cc| cc.close();
    if (server.systemd_client) |client| client.destroy();
    server.systemd_client = null;
    server.world.destroyClosing();
    server.night_light.deinit();
    server.brightness.deinit(server);
    if (server.locker) |lock| {
        lock.destroy();
        server.locker = null;
    }
    server.startup_warmup.deinit();
    if (server.desktop) |desktop| desktop.destroy();
    server.desktop = null;
    if (server.catalog_wake_source) |source| {
        source.remove();
        server.catalog_wake_source = null;
    }
    server.stopWallpaperLoad();
    server.forgetWallpaperSource();
    @import("control_center/folder_picker.zig").cancel();
    if (server.wallpaper_thumb) |thumb| thumb.deinit(@import("main.zig").gpa);
    server.wallpaper_thumb = null;
    if (server.wallpaper_displayed_path) |path| @import("main.zig").gpa.free(path);
    server.wallpaper_displayed_path = null;
    if (server.config_watcher) |*w| {
        w.deinit(@import("main.zig").gpa);
        server.config_watcher = null;
    }
    if (server.xwayland) |xw| {
        server.xwayland = null;
        xw.destroy();
    }
    server.switcher.cancel();
    if (server.services) |s| {
        s.stopOwnedHelpers(1000);
    }
    server.wl_server.destroyClients();
    while (server.pending_launches.pop()) |pending| pending.destroy();
    server.pending_launches.deinit(@import("main.zig").gpa);
    server.window_tabs.deinit();
    @import("extra_protocols.zig").rediwm_protocols_destroy(server.extra_protocols);
    server.extra_protocols = null;
    server.activation.deinit();
    server.launch_feedback.deinit();
    if (server.text_input) |relay| {
        relay.destroy();
        server.text_input = null;
    }

    server.new_output.link.remove();
    server.new_layer.link.remove();
    server.shell.deinit();
    if (server.virtual_input) |vi| {
        vi.destroy();
        server.virtual_input = null;
    }
    if (server.screenshot_mgr) |sm| {
        sm.deinit();
        server.screenshot_mgr = null;
    }
    if (server.tray) |tray| tray.closing = true;
    if (server.polkit_dialog) |dialog| dialog.cancel();
    if (server.polkit) |agent| {
        agent.destroy();
        server.polkit = null;
    }
    if (server.notifications) |nm| {
        nm.deinit();
        server.notifications = null;
    }
    if (server.tray) |tray| {
        tray.deinit();
        server.tray = null;
    }
    if (server.power) |pm| {
        pm.deinit();
        server.power = null;
    }
    if (server.bluetooth) |bluetooth| {
        bluetooth.destroy();
        server.bluetooth = null;
    }
    if (server.network) |network| {
        network.destroy();
        server.network = null;
    }
    if (server.power_profiles) |pp| {
        pp.deinit();
        server.power_profiles = null;
    }
    if (server.app_scopes) |scopes| {
        scopes.destroy();
        server.app_scopes = null;
    }
    if (server.services) |s| {
        s.deinit();
        server.services = null;
    }
    if (server.session != null) {
        server.session_active.link.remove();
    }
    if (server.layout_autosave) |as| {
        as.deinit();
        server.layout_autosave = null;
    }
    if (server.capture_mgr) |cm| {
        cm.deinit();
        server.capture_mgr = null;
    }
    if (server.output_management) |om| {
        om.destroy();
        server.output_management = null;
    }
    if (server.output_power) |op| {
        op.destroy();
        server.output_power = null;
    }
    if (server.session_lock) |sl| {
        sl.destroy();
        server.session_lock = null;
    }
    if (server.audio_wake_source) |source| {
        source.remove();
        server.audio_wake_source = null;
    }
    if (server.audio) |mgr| {
        mgr.deinit();
        server.audio = null;
    }
    if (server.battery_uevent_source) |source| {
        source.remove();
        server.battery_uevent_source = null;
    }
    if (server.battery_uevent_fd) |fd| {
        _ = std.posix.system.close(fd);
        server.battery_uevent_fd = null;
    }
    if (server.icon_wake_source) |source| {
        source.remove();
        server.icon_wake_source = null;
    }
    if (server.icon_service) |svc| {
        svc.deinit();
        server.icon_service = null;
    }
    if (server.idle) |im| {
        im.destroy();
        server.idle = null;
    }
    // Device/output destroy callbacks can still end gestures and hit-test.
    // Keep the seat and cursor alive until those callbacks have finished.
    // Detach this backend listener now; Input.deinit can then remove the
    // self-linked listener without touching the freed backend.
    server.input.new_input.link.remove();
    server.input.new_input.link.init();
    server.backend.destroy();
    server.input.deinit();
    server.world.deinit();
    server.start_menu_catalog.deinit();
    glass.Engine.destroy(server.glass_engine);
    explicit_sync.ReadFence.destroy(server.read_fence);
    server.scene.tree.node.destroy();
    server.output_layout.destroy();
    server.allocator.destroy();
    if (server.gpu_timer) |timer| timer.destroy();
    server.renderer.destroy();
    if (server.wallpaper) |image| image.base.drop();
    server.config.deinit();
    server.wl_server.destroy();
    log.info("compositor session teardown complete", .{});
}

pub fn maxOutputScale(server: *Server) f32 {
    var scale: f32 = 1;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.isLogicallyEnabled()) scale = @max(scale, output.wlr_output.scale);
    }
    return scale;
}

fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const server: *Server = @fieldParentPtr("new_output", listener);

    // wlroots' own `wlr_ext_image_capture_source_v1_create_with_scene_node`
    // (capture/manager.zig, stage 3 window capture) creates a private
    // `non_desktop` output to render a captured scene node, and drives it
    // entirely itself. Before this check existed, this handler treated it
    // like any other monitor — enabling it, attaching the *whole* scene via
    // `Output.create`, and adding it to the layout — which raced wlroots'
    // own internal rendering and made a window capture show whatever
    // happened to be on top on the real desktop instead of that window's
    // own isolated content (caught by `run_window_occlusion_case`: a
    // captured background window showed its occluder's color). `non_desktop`
    // is the standard wlroots signal (also used for VR/HMD outputs) that a
    // compositor must leave an output alone rather than treat it as a
    // desktop monitor.
    if (wlr_output.non_desktop) {
        @import("extra_protocols.zig").rediwm_protocols_offer(server.extra_protocols, wlr_output);
        log.debug("newOutput: excluding non-desktop output {s} from desktop layout", .{wlr_output.name});
        return;
    }

    if (!wlr_output.initRender(server.allocator, server.renderer)) {
        log.err("newOutput: initRender failed for {s}", .{wlr_output.name});
        return;
    }

    var state = wlr.Output.State.init();
    defer state.finish();

    state.setEnabled(true);
    const saved = Output.configuredMode(server, wlr_output);
    const preferred = if (saved) |mode| mode.advertised else wlr_output.preferredMode() orelse wlr_output.modes.first();
    const output_scale = if (saved) |mode|
        Output.scaleForDimensions(server, wlr_output, mode.width, mode.height)
    else
        Output.scaleForMode(server, wlr_output, preferred);
    state.setScale(output_scale);
    if (saved) |mode| {
        mode.setState(&state);
    } else if (preferred) |mode| {
        // A real display's mode is already in device pixels; the scale only
        // changes the logical size derived from it.
        state.setMode(mode);
    } else {
        // Backends without modes (nested, headless) size themselves as though
        // the scale were 1, so the buffer has to be enlarged to match it.
        state.setCustomMode(
            geometry.devicePixels(wlr_output.width, output_scale),
            geometry.devicePixels(wlr_output.height, output_scale),
            0,
        );
    }
    if (!wlr_output.commitState(&state)) {
        // A preferred mode can exceed available link bandwidth. Try only
        // modes advertised by this connector before giving up on the display.
        var modes = wlr_output.modes.iterator(.forward);
        var recovered = false;
        while (modes.next()) |mode| {
            if (mode == preferred) continue;
            state.setMode(mode);
            state.setScale(Output.scaleForMode(server, wlr_output, mode));
            if (wlr_output.commitState(&state)) {
                recovered = true;
                log.warn("output {s}: preferred mode rejected; using {d}x{d}@{d} mHz", .{ wlr_output.name, mode.width, mode.height, mode.refresh });
                break;
            }
        }
        if (!recovered) {
            log.err("newOutput: no usable mode for {s}", .{wlr_output.name});
            return;
        }
    }

    log.info("output {s}: {d}x{d}@{d:.2} Hz, {d}x{d} mm, scale {d}", .{ wlr_output.name, wlr_output.width, wlr_output.height, @as(f64, @floatFromInt(wlr_output.refresh)) / 1000, wlr_output.phys_width, wlr_output.phys_height, wlr_output.scale });

    Output.create(server, wlr_output) catch |err| {
        log.err("newOutput: could not create output {s}: {}", .{ wlr_output.name, err });
        wlr_output.destroy();
        return;
    };
    if (server.xwayland) |xw| xw.refreshScale();
}

// Rebuilds every output's taskbar chip layout (FLIP-animating any that
// moved) and keeps the bar above windows but below menus and modal overlays.
pub fn refreshTaskbars(server: *Server) void {
    if (server.taskbar_hold > 0) {
        server.taskbar_hold_pending = true;
        return;
    }
    const desired_h = Taskbar.barHeight();
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.taskbar) |bar| {
            if (bar.box.height != desired_h) {
                var box: wlr.Box = undefined;
                server.output_layout.getBox(output.wlr_output, &box);
                bar.relayout(box);
                if (server.input.open_start_menu) |sm| {
                    if (sm.wlr_output == output.wlr_output) sm.relayout();
                }
            }
            bar.notifyToplevelsChanged();
        }
    }
    server.taskbar_tree.node.placeBelow(&server.overlay_tree.node);
    server.updateTaskbarFullscreenVisibility();
}

// Coalesces taskbar refreshes until the matching `releaseTaskbars`, which
// runs one. Mapping a window refreshes the bar before the window is known to
// be a new tab of an existing group; without the hold the bar would show (and
// FLIP-animate) a transient extra chip.
pub fn holdTaskbars(server: *Server) void {
    server.taskbar_hold += 1;
}

pub fn releaseTaskbars(server: *Server) void {
    server.taskbar_hold -= 1;
    if (server.taskbar_hold == 0 and server.taskbar_hold_pending) {
        server.taskbar_hold_pending = false;
        server.refreshTaskbars();
    }
}

// Like refreshTaskbars, but always relayouts instead of only when bar height
// changed. Item geometry (chip/tray/start-button size, the start button's
// gap and icon size) also derives from `chip_gap`/`start_button_gap`/
// `start_button_icon_size`, none of which move `bar.box.height`, so the
// cheaper height-guarded path used by window-lifecycle events can't detect
// them. Callers are theme-change sites only (the settings panel, config
// hot-reload), not the frequent per-window-event ones, so the extra full
// raster pass here is rare and not a hot-path concern.
pub fn refreshTaskbarsGeometry(server: *Server) void {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.taskbar) |bar| {
            var box: wlr.Box = undefined;
            server.output_layout.getBox(output.wlr_output, &box);
            bar.relayout(box);
            if (server.input.open_start_menu) |sm| {
                if (sm.wlr_output == output.wlr_output) sm.relayout();
            }
        }
    }
    server.taskbar_tree.node.placeBelow(&server.overlay_tree.node);
    server.updateTaskbarFullscreenVisibility();
}

/// Apply a changed taskbar edge to panels, reserved space and fixed layouts.
pub fn applyTaskbarPosition(server: *Server) void {
    Output.syncLayout(server);
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (toplevel.fullscreen) continue;
        const output = toplevel.resolveTargetOutput() orelse continue;
        if (toplevel.maximized) {
            toplevel.setMaximizedOn(output);
        } else if (toplevel.tile) |tile| {
            toplevel.setTiledOn(output, tile);
        } else if (server.config.compositor.taskbar_position == .top) {
            // Keep visible floating titlebars reachable when the strip moves
            // over them, including the Settings window that made the change.
            const usable = output.usableBox();
            const position = server.world.toLayout(@floatFromInt(toplevel.x), @floatFromInt(toplevel.y));
            const top: f64 = @floatFromInt(usable.y);
            const bar_height: f64 = if (output.taskbar) |bar| @floatFromInt(bar.box.height) else 0;
            if (position.y >= top - bar_height and position.y < top) {
                const target = server.world.toWorld(position.x, top);
                toplevel.finishMoveAnimation();
                toplevel.setPosition(@intFromFloat(@round(target.x)), @intFromFloat(@round(target.y)));
            }
        }
    }
}

// Hides the taskbar strip on whichever output currently hosts the focused
// fullscreen window (e.g. a video fullscreened in a browser), the same way
// a layer-shell panel would yield to an exclusive-fullscreen surface. Other
// outputs keep their bar, since a fullscreen window elsewhere shouldn't
// blank an unrelated monitor's taskbar.
fn updateTaskbarFullscreenVisibility(server: *Server) void {
    const focused = server.world.toplevels.first();
    // The raw compositor-side intent flag, not `isFullscreen()`: for xdg
    // surfaces that reads the client-acked `current.fullscreen`, which lags
    // a round trip behind the resize we already applied synchronously in
    // setFullscreenOn/toggleFullscreen. Reading the same flag those setters
    // write keeps the bar in lockstep with the resize instead of flashing
    // on top for a frame.
    const fullscreen_output: ?*Output = if (focused) |t|
        (if (t.fullscreen) t.currentOutput() else null)
    else
        null;

    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        const bar = output.taskbar orelse continue;
        bar.tree.node.setEnabled(fullscreen_output != output);
    }
}

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

/// Nonblocking icon lookup for titlebar/taskbar/start-menu rendering; see
/// `icon_service.zig`. `.missing` whenever the service failed to start,
/// matching how every other optional subsystem in this compositor degrades.
pub fn iconLookup(server: *Server, name: []const u8, size_px: i32) icon_service_mod.Lookup {
    const svc = server.icon_service orelse return .missing;
    // Resolve the canonical icon name: many apps advertise an app_id /
    // StartupWMClass that differs from their desktop Icon= name (e.g.
    // "brave-browser" → "brave-desktop", "dev.zed.Zed" → "zed").
    // Retain the snapshot for the duration of this call so any slice
    // borrowed from its arena stays valid until after svc.request().
    const snap = server.start_menu_catalog.retainSnapshot();
    defer snap.release();
    const icon_name = server.icon_names.resolve(snap, name);
    return svc.request(icon_name, size_px);
}

/// Small direct-mapped memo for resolved icon names, keyed by app_id and
/// invalidated wholesale whenever the catalog publishes a new generation.
/// Names or app_ids longer than `max_len` simply bypass it and rescan.
const IconNameCache = struct {
    const capacity = 32;
    const max_len = 96;

    const Entry = struct {
        app_id: [max_len]u8 = undefined,
        app_id_len: u8 = 0,
        name: [max_len]u8 = undefined,
        name_len: u8 = 0,
        filled: bool = false,
    };

    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    generation: u64 = 0,
    primed: bool = false,

    fn slot(app_id: []const u8) usize {
        return std.hash.Wyhash.hash(0, app_id) % capacity;
    }

    /// The returned slice is owned by the cache (stable until the entry is
    /// replaced) or borrowed from `snap` on the uncached path, so callers must
    /// keep `snap` retained for the rest of the call either way.
    fn resolve(self: *IconNameCache, snap: *applications.Snapshot, app_id: []const u8) []const u8 {
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

/// Returns the icon name that should be used for a given app_id / WM class.
/// Priority:
///   1. A catalog entry whose StartupWMClass= exactly matches `app_id` → use
///      that entry's Icon= name.
///   2. A catalog entry whose desktop-file ID (sans ".desktop") exactly
///      matches `app_id` → use its Icon= name.
///   3. Reverse-DNS strip: "com.example.App" → last component, tried against
///      catalog icon names.
///   4. Fall back to `app_id` unchanged.
/// The returned slice is either borrowed from `snap` arena memory or is a
/// sub-slice of `app_id`; the caller must keep `snap` retained until done.
fn iconNameForAppId(snap: *applications.Snapshot, app_id: []const u8) []const u8 {
    if (app_id.len == 0) return app_id;
    // The built-in settings window has no desktop entry.
    if (std.mem.eql(u8, app_id, @import("Toplevel.zig").settings_app_id)) return "preferences-system";

    // Pass 1: exact StartupWMClass match → use the desktop file's Icon= name.
    for (snap.entries) |e| {
        if (e.startup_wm_class) |wmc| {
            if (std.mem.eql(u8, wmc, app_id)) {
                return e.icon orelse app_id;
            }
        }
    }

    // Pass 2: desktop-file ID (strip ".desktop" suffix) match.
    for (snap.entries) |e| {
        // e.id is the desktop file ID, e.g. "brave-browser.desktop" or
        // "dev.zed.Zed.desktop"; strip the suffix before comparing.
        const id = if (std.mem.endsWith(u8, e.id, ".desktop"))
            e.id[0 .. e.id.len - ".desktop".len]
        else
            e.id;
        if (std.mem.eql(u8, id, app_id)) {
            return e.icon orelse app_id;
        }
    }

    // Pass 3: reverse-DNS heuristic — "dev.zed.Zed" → last component "Zed".
    // Only fire when there are at least two dots (genuine reverse-DNS prefix).
    if (std.mem.lastIndexOfScalar(u8, app_id, '.')) |dot| {
        const last = app_id[dot + 1 ..];
        if (std.mem.indexOfScalar(u8, app_id[0..dot], '.') != null and last.len > 0) {
            // Try matching the last component against catalog icon names.
            for (snap.entries) |e| {
                const icon = e.icon orelse continue;
                if (std.mem.eql(u8, icon, last)) return icon;
            }
            // Return the last component so the theme lookup at least tries it
            // (e.g. "Zed" — some icon themes use that exact casing).
            return last;
        }
    }

    return app_id;
}

pub fn iconAcquire(server: *Server, id: u64) void {
    if (server.icon_service) |svc| svc.acquire(id);
}

pub fn iconRelease(server: *Server, id: u64) void {
    if (server.icon_service) |svc| svc.release(id);
}

/// Speculative scroll-ahead/initial-results prefetch (step 5); see
/// `IconService.prefetch`. Fire-and-forget, budget-gated, safe to call
/// every frame for names that may already be resolved.
pub fn iconPrefetch(server: *Server, name: []const u8, size_px: i32) void {
    if (server.icon_service) |svc| svc.prefetch(name, size_px);
}

/// Drops speculative work nothing is interested in anymore (a query/scroll
/// change); see `IconService.cancelSpeculative`.
pub fn iconCancelSpeculative(server: *Server) void {
    if (server.icon_service) |svc| svc.cancelSpeculative();
}

/// Forces every titlebar/chip/logo icon to redecode on its next repaint;
/// see `IconService.invalidateAll`. Nothing calls this automatically today
/// (no runtime icon-theme reload path exists in this compositor) — it's
/// available for a future explicit-refresh trigger.
pub fn iconInvalidateAll(server: *Server) void {
    if (server.icon_service) |svc| svc.invalidateAll();
}

/// Best-effort: `null` on any failure just means the taskbar/control-center
/// UI catches up to an external volume change (another app, `pactl`) on its
/// next incidental repaint instead of immediately — never fatal.
fn createAudioWakeFd() ?std.posix.fd_t {
    const rc = std.os.linux.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// Runs on the compositor thread, woken by `audio.AudioManager`'s PA-thread
/// callback incrementing `fd` (see audio/pipewire.zig's module doc
/// comment) — never touches `AudioManager` state directly, since the actual
/// re-read happens in Taskbar.tick and the open control center's next frame.
fn handleAudioWake(fd: c_int, mask: wl.EventMask, server: *Server) c_int {
    _ = mask;
    var buf: [8]u8 = undefined;
    _ = std.posix.system.read(fd, &buf, buf.len);
    @import("osd.zig").refreshAudio(server);
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.taskbar) |bar| bar.markDirty(Taskbar.paint_audio);
    }
    if (server.input.open_control_center) |cc| cc.refresh();
    if (server.locker) |lock| lock.controlsChanged();
    server.scheduleFrames();
    return 0;
}

/// Drains everything queued, so events that arrive together (a plug-in sends
/// several) cost one sysfs read, shared by every output's taskbar.
fn handleBatteryUevent(fd: c_int, mask: wl.EventMask, server: *Server) c_int {
    _ = mask;
    if (!battery_mod.drainUevents(fd)) return 0;
    const state = battery_mod.read(server.io, @import("main.zig").gpa);
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.taskbar) |bar| bar.applyBattery(state);
    }
    return 0;
}

pub fn ensureGpuTimer(server: *Server) void {
    server.gpu_timer_used_ns = @import("ipc/stats.zig").nowNs();
    if (server.gpu_timer_tried) return;
    server.gpu_timer_tried = true;
    server.gpu_timer = @import("gpu_timing.zig").Timer.create(server.renderer);
}

/// One `perf` query must not leave the timer's per-frame cost (measured
/// ~0.17 ms at 60 Hz on Iris Xe) running for the rest of the session. After
/// five minutes without a stats request it stops; the next request restarts it.
pub fn expireGpuTimer(server: *Server) void {
    const timer = server.gpu_timer orelse return;
    const idle_ns: u64 = 5 * 60 * std.time.ns_per_s;
    if (@import("ipc/stats.zig").nowNs() -% server.gpu_timer_used_ns < idle_ns) return;
    timer.destroy();
    server.gpu_timer = null;
    server.gpu_timer_tried = false;
}

/// Runs on the compositor thread, woken by `IconService`'s worker thread
/// finishing a decode (see `icon_service.zig`'s module comment). Does not
/// know or care which consumer wanted the icon that just became ready — it
/// rechecks live consumers. Chrome/taskbar memos and the menu's visible icon
/// IDs avoid repainting when nothing relevant changed, so touching them is safe and
/// avoids tracking per-request subscriber pointers into windows/panels that
/// could be destroyed before their icon arrives.
fn themeColorArgb(color: [4]f32) u32 {
    const a = std.math.clamp(color[3], 0, 1);
    const a8: u32 = @intFromFloat(@round(a * 255.0));
    const r8: u32 = @intFromFloat(@round(std.math.clamp(color[0] * a, 0, 1) * 255.0));
    const g8: u32 = @intFromFloat(@round(std.math.clamp(color[1] * a, 0, 1) * 255.0));
    const b8: u32 = @intFromFloat(@round(std.math.clamp(color[2] * a, 0, 1) * 255.0));
    return (a8 << 24) | (r8 << 16) | (g8 << 8) | b8;
}

fn applyDecodedWallpaper(server: *Server, decoded: png.Image) void {
    const image = ImageBuffer.createFromDecoded(decoded) catch |err| {
        log.warn("applyDecodedWallpaper: {}", .{err});
        decoded.deinit(@import("main.zig").gpa);
        startup.markWallpaperFailed();
        return;
    };
    const old = server.wallpaper;
    server.wallpaper = image;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        output.replaceWallpaper(image);
    }
    if (old) |prev| prev.base.drop();
}

fn handleCatalogWake(fd: c_int, mask: wl.EventMask, server: *Server) c_int {
    _ = fd;
    _ = mask;
    if (!server.start_menu_catalog.drainCompletions()) return 0;
    if (server.input.open_control_center) |cc| cc.refresh();
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.start_menu) |sm| sm.refreshCatalog();
    }
    server.startup_warmup.onCatalogReady(server);
    if (server.ipc) |ipc| ipc.wait_mgr.checkAll();
    return 0;
}

/// Loads `[compositor] wallpaper` unless it is already shown or loading.
/// The current wallpaper stays until the new one has decoded.
pub fn reloadWallpaper(server: *Server) void {
    server.loadWallpaper(0);
}

fn loadWallpaper(server: *Server, delay_ns: u64) void {
    const gpa = @import("main.zig").gpa;
    const path = wallpapers.resolve(gpa, server.io, server.config.compositor.wallpaper) catch |err| {
        log.warn("wallpaper '{s}': {}", .{ server.config.compositor.wallpaper, err });
        return;
    };
    if (server.wallpaper_source) |current| {
        if (std.mem.eql(u8, current, path) and !server.wallpaper_failed) {
            gpa.free(path);
            return;
        }
        gpa.free(current);
    }
    server.wallpaper_source = path;
    server.stopWallpaperLoad();

    // A missing or broken choice falls back to the bundled image.
    const default = wallpapers.resolve(gpa, server.io, "") catch null;
    defer if (default) |d| gpa.free(d);
    var candidates: [2][]const u8 = .{ path, undefined };
    var count: usize = 1;
    if (default) |d| {
        if (!std.mem.eql(u8, d, path)) {
            candidates[1] = d;
            count = 2;
        }
    }
    const loader = wallpaper_load.Loader.start(gpa, server.io, candidates[0..count], delay_ns) catch |err| {
        server.wallpaper_failed = true;
        log.warn("wallpaper decode worker failed: {}", .{err});
        server.forgetWallpaperSource();
        return;
    };
    server.wallpaper_failed = false;
    server.wallpaper_loader = loader;
    startup.markWallpaperDecoding();
    server.wallpaper_wake_source = server.wl_server.getEventLoop().addFd(*Server, loader.wakeFd(), .{ .readable = true }, handleWallpaperWake, server) catch |err| {
        server.wallpaper_failed = true;
        log.warn("could not register wallpaper wake fd: {}", .{err});
        server.stopWallpaperLoad();
        server.forgetWallpaperSource();
        return;
    };
}

fn stopWallpaperLoad(server: *Server) void {
    if (server.wallpaper_wake_source) |source| source.remove();
    server.wallpaper_wake_source = null;
    if (server.wallpaper_loader) |loader| loader.deinit();
    server.wallpaper_loader = null;
}

fn forgetWallpaperSource(server: *Server) void {
    if (server.wallpaper_source) |path| @import("main.zig").gpa.free(path);
    server.wallpaper_source = null;
}

fn handleWallpaperWake(fd: c_int, mask: wl.EventMask, server: *Server) c_int {
    _ = fd;
    _ = mask;
    const gpa = @import("main.zig").gpa;
    const loader = server.wallpaper_loader orelse return 0;
    if (loader.take()) |result| {
        startup.markWallpaperDecoded(loader.decode_ns);
        if (server.wallpaper_displayed_path) |path| gpa.free(path);
        server.wallpaper_displayed_path = gpa.dupe(u8, loader.paths[result.path_index]) catch null;
        server.wallpaper_failed = result.path_index != 0;
        applyDecodedWallpaper(server, result.image);
        if (server.wallpaper_thumb) |old| old.deinit(gpa);
        server.wallpaper_thumb = result.thumb;
    } else if (loader.takeFailed()) {
        server.wallpaper_failed = true;
        // Later failures keep the wallpaper already on screen.
        if (startup.marks.wallpaper_state != .presented) startup.markWallpaperFailed();
        server.forgetWallpaperSource();
    } else return 0;
    // Removing the source from its own callback is safe; the worker is done.
    server.stopWallpaperLoad();
    if (server.input.open_control_center) |cc| cc.refresh();
    if (server.ipc) |ipc| ipc.wait_mgr.checkAll();
    return 0;
}

fn handleIconWake(fd: c_int, mask: wl.EventMask, server: *Server) c_int {
    _ = fd;
    _ = mask;
    const service = server.icon_service orelse return 0;
    service.drainCompletions();

    const now = @import("Toplevel.zig").nowMs();
    var toplevel_it = server.world.toplevels.iterator(.forward);
    while (toplevel_it.next()) |toplevel| {
        toplevel.syncChrome(false, false, now) catch |err| {
            log.warn("handleIconWake: syncChrome failed: {}", .{err});
        };
    }

    var output_it = server.outputs.iterator(.forward);
    while (output_it.next()) |output| {
        if (output.taskbar) |bar| bar.notifyToplevelsChanged();
        if (output.start_menu) |sm| sm.iconsReady();
    }
    if (server.notifications) |mgr| mgr.iconsReady();
    if (server.tray) |tray| tray.changed();
    server.scheduleFrames();
    return 0;
}

fn newLayer(listener: *wl.Listener(*wlr.LayerSurfaceV1), layer: *wlr.LayerSurfaceV1) void {
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
            agent.conversation = .{ .owner = server, .opened = @import("polkit/dialog.zig").Dialog.opened, .event = @import("polkit/dialog.zig").Dialog.event };
            if (server.locker != null) agent.pauseForLock();
        }
    }
    if (server.polkit) |agent| agent.configure(config.enable, config.helper_socket) catch |err| {
        log.warn("could not configure polkit agent: {}", .{err});
        polkitState(server, .unavailable);
    };
}

fn polkitState(owner: ?*anyopaque, state: polkit_mod.Agent.State) void {
    if (state != .unavailable) return;
    const server: *Server = @ptrCast(@alignCast(owner.?));
    if (server.notifications) |mgr| {
        _ = mgr.postNotification("Authentication", 0, "", "Authentication agent unavailable", "Could not register with polkit. Another authentication agent may already be running.", &.{}, 1, false, true, 6000, "", null) catch {};
    }
}
