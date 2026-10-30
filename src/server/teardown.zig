//! Server destruction in dependency order.

const std = @import("std");
const glass = @import("../glass.zig");
const scene_output_mod = @import("../scene_output.zig");
const explicit_sync = @import("../explicit_sync.zig");
const log = std.log.scoped(.compositor);
const Server = @import("../Server.zig");

pub fn deinit(server: *Server) void {
    if (server.theme_job) |job| job.deinit();
    server.theme_job = null;
    server.undo.clear();
    server.undo.applying = true;
    // terminate saved the layout before leaving the event loop. Only paths
    // such as restart_shell, which stop the display directly, need to save it
    // here. In both cases save before tearing down Xwayland or native clients.
    const already_terminating = server.shutting_down;
    server.shutting_down = true;
    server.startup_tasks.deinit();
    server.reveal.deinit();
    server.session_startup.deinit();
    if (!already_terminating) {
        if (server.layout_autosave) |as| as.saveNow();
    }
    server.screenshot_selector.cancel();
    @import("../clipboard.zig").cancelImageTransfers();
    // Shutting down, its window is freed at once rather than animating out.
    if (server.input.open_control_center) |cc| cc.close();
    if (server.systemd_client) |client| client.destroy();
    server.systemd_client = null;
    server.world.destroyClosing();
    server.night_light.deinit();
    server.power_policy.deinit();
    server.brightness.deinit(server);
    server.keyboard_brightness.deinit(server);
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
    if (server.login_appearance_dir) |dir| @import("../main.zig").gpa.free(dir);
    server.login_appearance_dir = null;
    @import("../control_center/folder_picker.zig").cancel();
    if (server.wallpaper_thumb) |thumb| thumb.deinit(@import("../main.zig").gpa);
    server.wallpaper_thumb = null;
    if (server.wallpaper_displayed_path) |path| @import("../main.zig").gpa.free(path);
    server.wallpaper_displayed_path = null;
    if (server.config_watcher) |*w| {
        w.deinit(@import("../main.zig").gpa);
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
    server.pending_launches.deinit(@import("../main.zig").gpa);
    server.window_tabs.deinit();
    @import("../extra_protocols.zig").rediwm_protocols_destroy(server.extra_protocols);
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
    destroyServices(server);
}

fn destroyServices(server: *Server) void {
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
    destroyRenderer(server);
}

fn destroyRenderer(server: *Server) void {
    // Device/output destroy callbacks can still end gestures and hit-test.
    // Keep the seat and cursor alive until those callbacks have finished.
    // Detach this backend listener now; Input.deinit can then remove the
    // self-linked listener without touching the freed backend.
    server.input.new_input.link.remove();
    server.input.new_input.link.init();
    server.backend.destroy();
    server.input.deinit();
    server.world.deinit();
    server.nodes.destroy();
    server.start_menu_catalog.deinit();
    glass.Engine.destroy(server.glass_engine);
    scene_output_mod.Renderer.destroy(server.output_renderer);
    explicit_sync.ReadFence.destroy(server.read_fence);
    server.scene_outputs.destroy();
    server.output_layout.destroy();
    server.allocator.destroy();
    if (server.gpu_timer) |timer| timer.destroy();
    server.renderer.destroy();
    if (server.wallpaper) |image| image.base.drop();
    server.config.deinit();
    server.wl_server.destroy();
    log.info("compositor session teardown complete", .{});
}
