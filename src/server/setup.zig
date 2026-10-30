//! Server construction and ownership rollback.

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const battery_mod = @import("../taskbar/battery.zig");
const ImageBuffer = @import("../ImageBuffer.zig");
const Output = @import("../Output.zig");
const sn = @import("../node.zig");
const icon_theme = @import("../icon_theme.zig");
const icon_service_mod = @import("../icon_service.zig");
const glass = @import("../glass.zig");
const scene_output_mod = @import("../scene_output.zig");
const scene_outputs_mod = @import("../scene_outputs.zig");
const explicit_sync = @import("../explicit_sync.zig");
const screenshot = @import("../screenshot/capture.zig");
const capture = @import("../capture/manager.zig");
const config_loader = @import("config").loader;
const watcher_mod = @import("../config_runtime/watcher.zig");
const ui_theme = @import("ui").theme;
const idle_mod = @import("../session/idle.zig");
const power_mod = @import("../session/power.zig");
const services_mod = @import("../session/services.zig");
const VirtualInput = @import("../input/virtual.zig").VirtualInput;
const applications = @import("../start_menu/applications.zig");
const Xwayland = @import("../Xwayland.zig");
const startup = @import("../startup.zig");
const server_wakeups = @import("wakeups.zig");
const server_wallpaper = @import("wallpaper.zig");
const log = std.log.scoped(.compositor);
const handleBatteryUevent = server_wakeups.handleBatteryUevent;
const themeColorArgb = server_wallpaper.themeColorArgb;
const handleCatalogWake = server_wallpaper.handleCatalogWake;
const handleIconWake = server_wallpaper.handleIconWake;
const Server = @import("../Server.zig");
const wl_display_set_default_max_buffer_size = Server.wl_display_set_default_max_buffer_size;
const CompositorError = Server.CompositorError;
const loadGreeterConfig = Server.loadGreeterConfig;
const enablePolygons = Server.enablePolygons;

pub fn init(server: *Server, scale: ?f32, icon_theme_cfg: icon_theme.Config, io: std.Io, environ: std.process.Environ, theme_path: ?[]const u8, argv: []const [*:0]const u8, greeter: bool) CompositorError!void {
    const wl_server = wl.Server.create() catch return error.ServerCreateFailed;
    errdefer wl_server.destroy();
    // Let temporarily busy clients catch up with input/event bursts instead
    // of disconnecting when the default 4 KiB outgoing buffer fills. This is
    // a growth limit, not an allocation per client; keep it bounded at 1 MiB.
    wl_display_set_default_max_buffer_size(wl_server, 1024 * 1024);

    var session: ?*wlr.Session = null;
    const backend = wlr.Backend.autocreate(wl_server.getEventLoop(), &session) catch return error.BackendCreateFailed;
    errdefer backend.destroy();

    const renderer = wlr.Renderer.autocreate(backend) catch {
        log.err("init: no renderer (GLES2 is required; with several GPUs pick one with WLR_RENDER_DRM_DEVICE=/dev/dri/renderD*)", .{});
        return error.RendererInitFailed;
    };
    errdefer renderer.destroy();
    // The output pass is GLES2 only (docs/plans/scene-graph.md, renderer policy).
    // A machine without a GPU runs Mesa's llvmpipe: WLR_RENDERER_ALLOW_SOFTWARE=1.
    if (!renderer.isGles2()) {
        log.err("init: RediWM needs the GLES2 renderer (set WLR_RENDERER=gles2; without a GPU also WLR_RENDERER_ALLOW_SOFTWARE=1)", .{});
        return error.RendererInitFailed;
    }
    const renderer_name: []const u8 = if (renderer.isGles2()) "gles2" else if (renderer.isPixman()) "pixman" else "unknown";
    startup.markRendererReady(renderer_name, scale orelse 1);

    const wlr_allocator = wlr.Allocator.autocreate(backend, renderer) catch return error.AllocatorCreateFailed;
    errdefer wlr_allocator.destroy();

    const output_layout = wlr.OutputLayout.create(wl_server) catch return error.OutputLayoutCreateFailed;
    errdefer output_layout.destroy();

    const scene_outputs = scene_outputs_mod.SceneOutputs.create(output_layout) catch return error.SceneCreateFailed;
    errdefer scene_outputs.destroy();
    // The projection resolves the scene into the graph the output pass draws.
    const nodes = sn.Scene.create() catch return error.SceneCreateFailed;
    errdefer nodes.destroy();
    nodes.outputs = scene_outputs;
    nodes.frame_callbacks = Output.frameCallbacksWanted;
    const background_tree = nodes.tree.createSceneTree() catch return error.SceneCreateFailed;
    const desktop_tree = nodes.tree.createSceneTree() catch return error.SceneCreateFailed;
    const world_tree = nodes.tree.createSceneTree() catch return error.SceneCreateFailed;
    const world_desktop_tree = world_tree.createSceneTree() catch return error.SceneCreateFailed;
    const taskbar_tree = nodes.tree.createSceneTree() catch return error.SceneCreateFailed;
    const overlay_tree = nodes.tree.createSceneTree() catch return error.SceneCreateFailed;
    const ime_tree = nodes.tree.createSceneTree() catch return error.SceneCreateFailed;
    const lock_tree = nodes.tree.createSceneTree() catch return error.SceneCreateFailed;

    var config_load_error: ?[]const u8 = null;
    var loaded = (if (greeter) loadGreeterConfig(io, environ) else config_loader.loadDefault(@import("../main.zig").gpa, io, environ)) catch |err| blk: {
        config_load_error = @errorName(err);
        log.warn("config load failed: {}, using defaults", .{err});
        break :blk config_loader.default(@import("../main.zig").gpa) catch return error.ServerCreateFailed;
    };
    errdefer loaded.deinit();
    const locale_tag = @import("i18n").resolve(if (greeter) "" else loaded.region.language, environ);
    _ = @import("i18n").setLanguage(locale_tag);
    const catalog = applications.Catalog.init(@import("../main.zig").gpa, io, environ, !greeter, locale_tag) catch return error.ServerCreateFailed;
    errdefer catalog.deinit();
    if (greeter) {
        // The greeter shows no windows or desktop and speaks for no one on
        // the session bus; X11 and the authentication agent have no role.
        loaded.compositor.xwayland = false;
        loaded.desktop.enabled = false;
        loaded.polkit.enable = false;
    }
    if (!greeter) @import("ui").shell_icons.configure(io, if (loaded.theme_pack) |p| p.root else "");
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
    @import("../camera.zig").zoom_levels = loaded.compositor.zoom_percents;
    startup.markConfigReady(@intCast(loaded.autostart.len));

    server.* = .{
        .wl_server = wl_server,
        .backend = backend,
        .renderer = renderer,
        .allocator = wlr_allocator,
        .scene_outputs = scene_outputs,
        .nodes = nodes,
        .background_tree = background_tree,
        .desktop_tree = desktop_tree,
        .world_desktop_tree = world_desktop_tree,
        .taskbar_tree = taskbar_tree,
        .overlay_tree = overlay_tree,
        .ime_tree = ime_tree,
        .lock_tree = lock_tree,
        .output_layout = output_layout,
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

    try initSession(server, world_tree);
}

fn initSession(server: *Server, world_tree: *sn.Tree) CompositorError!void {
    const greeter = server.greeter_mode;
    const session = server.session;
    const environ = server.environ;
    const io = server.io;
    const loaded = server.config;
    const renderer = server.renderer;
    const backend = server.backend;
    const wl_server = server.wl_server;
    if (!greeter and session != null) server.login_appearance_dir = @import("../session/login_appearance.zig").writableDirectory(@import("../main.zig").gpa);
    errdefer if (server.login_appearance_dir) |dir| @import("../main.zig").gpa.free(dir);
    server.saveLoginTheme();

    if (!greeter) {
        const app_theme = @import("config").app_theme;
        const a = @import("../main.zig").gpa;
        if (app_theme.configHome(a, environ)) |home| {
            defer a.free(home);
            server.qt_app_colors = app_theme.qtEnabled(a, io, home) catch |err| blk: {
                log.warn("could not load app colors preference: {}", .{err});
                break :blk false;
            };
        } else |_| {}
    }

    if (!greeter) @import("../config_runtime/region.zig").applyTimezone(@import("../main.zig").gpa, loaded.region.timezone, environ.getPosix("TZ")) catch |err| {
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
    server.glass_engine = if (environ.getPosix("REDIWM_NO_GLASS") != null) null else glass.Engine.create();
    errdefer glass.Engine.destroy(server.glass_engine);
    server.output_renderer = scene_output_mod.Renderer.create(renderer) orelse return error.RendererInitFailed;
    errdefer scene_output_mod.Renderer.destroy(server.output_renderer);
    log.info("scene renderer: owned GLES2 output pass", .{});
    // The window shapes: rounded clip, ring and shadow. Built here, before any
    // window exists. Without them windows are square, with no ring or shadow.
    if (server.output_renderer.enableShapes()) {
        @import("../chrome.zig").shapes = true;
        @import("../chrome.zig").polygon_context = server;
        @import("../chrome.zig").polygon_enabler = &enablePolygons;
        // Glass (stage 5c of docs/plans/scene-graph.md); without the blur program
        // each glass surface shows its own tint.
        if (server.glass_engine != null and !server.output_renderer.enableBackdrops())
            log.err("glass: blur program unavailable, glass surfaces show their tint", .{});
    } else {
        log.err("window frames: shaped programs unavailable, windows are drawn square", .{});
    }
    server.outputs.init();
    server.layer_surfaces.init();
    try server.world.init(server, world_tree);
    errdefer server.world.deinit();
    try server.shell.init(server);
    errdefer server.shell.deinit();
    try server.input.init(server);
    errdefer server.input.deinit();
    if (!greeter) server.extra_protocols = @import("../extra_protocols.zig").create(server) orelse return error.ExtraProtocolsCreateFailed;
    errdefer @import("../extra_protocols.zig").rediwm_protocols_destroy(server.extra_protocols);
    server.activation.init(server) catch return error.ActivationManagerCreateFailed;
    errdefer server.activation.deinit();
    server.launch_feedback.init(server);
    errdefer server.launch_feedback.deinit();
    server.text_input = @import("../input/text_input.zig").create(server) catch return error.TextInputManagerCreateFailed;
    errdefer if (server.text_input) |relay| relay.destroy();

    server.idle = idle_mod.IdleManager.create(server, server.config.idle) catch |err| blk: {
        log.warn("init: could not create idle manager: {}", .{err});
        break :blk null;
    };
    errdefer if (server.idle) |im| im.destroy();

    try server.night_light.init(server, server.config.night_light);
    errdefer server.night_light.deinit();

    try initServices(server);
}

fn initServices(server: *Server) CompositorError!void {
    const greeter = server.greeter_mode;
    const environ = server.environ;
    const io = server.io;
    const catalog = server.start_menu_catalog;
    if (server.config.path.len > 0 and !greeter) {
        server.config_watcher = watcher_mod.init(server.config.path, server) catch |err| blk: {
            log.warn("config watcher: {}", .{err});
            break :blk null;
        };
    }

    server.virtual_input = VirtualInput.create(server, @import("../main.zig").gpa) catch |err| blk: {
        log.err("init: could not create virtual input: {}", .{err});
        break :blk null;
    };

    server.screenshot_mgr = screenshot.Manager.create(server, @import("../main.zig").gpa) catch |err| blk: {
        log.err("init: could not create screenshot manager: {}", .{err});
        break :blk null;
    };

    server.power = power_mod.Manager.create(server, @import("../main.zig").gpa) catch |err| blk: {
        log.warn("init: could not create power manager: {}", .{err});
        break :blk null;
    };

    if (!greeter and @import("../session/app_scope.zig").enabled(environ))
        server.app_scopes = @import("../session/app_scope.zig").Scopes.create(@import("../main.zig").gpa, server.wl_server.getEventLoop(), environ) catch null;

    if (!greeter) server.services = services_mod.Manager.create(server, @import("../main.zig").gpa) catch |err| blk: {
        log.warn("init: could not create services manager: {}", .{err});
        break :blk null;
    };

    // Layout autosave (periodic save and the startup restore) is off for now:
    // the restore moves windows seconds after login. Every user checks for
    // null, so re-enabling is uncommenting this.
    // if (!greeter) server.layout_autosave = layout_autosave_mod.Autosave.create(server) catch |err| blk: {
    //     log.warn("init: could not create layout autosave: {}", .{err});
    //     break :blk null;
    // };

    server.power_policy.init(server);
    errdefer server.power_policy.deinit();
    errdefer server.brightness.deinit(server);
    errdefer server.keyboard_brightness.deinit(server);
    if (battery_mod.openUeventSocket()) |fd| {
        server.battery_uevent_fd = fd;
        server.battery_uevent_source = server.wl_server.getEventLoop().addFd(*Server, fd, .{ .readable = true }, handleBatteryUevent, server) catch |err| blk: {
            log.warn("init: could not register power_supply uevent fd: {}", .{err});
            break :blk null;
        };
    } else {
        log.warn("init: no kernel uevent socket; taskbar battery updates once a minute", .{});
    }

    server.icon_service = icon_service_mod.IconService.create(@import("../main.zig").gpa, server.icon_theme_cfg, io) catch |err| blk: {
        log.warn("init: could not start icon service, icons disabled: {}", .{err});
        break :blk null;
    };
    @import("../config_runtime/theme_pack.zig").configureIcons(server);
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

    try initProtocols(server);
}

fn initProtocols(server: *Server) CompositorError!void {
    const wl_server = server.wl_server;
    const greeter = server.greeter_mode;
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
        server.output_management = @import("../output_management.zig").Manager.create(server) catch |err| blk: {
            log.warn("init: could not create output-management manager: {}", .{err});
            break :blk null;
        };
        server.output_power = @import("../output_power.zig").Manager.create(server) catch |err| blk: {
            log.warn("init: could not create output-power manager: {}", .{err});
            break :blk null;
        };
        server.session_lock = @import("../session/client_lock.zig").Manager.create(server) catch |err| blk: {
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
    @import("../global_filter.zig").install(server);
}
