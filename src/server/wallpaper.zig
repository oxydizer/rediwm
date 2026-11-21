//! Server wallpaper and catalog loading, and icon wake.

const std = @import("std");
const Server = @import("../Server.zig");
const wl = @import("wayland").server.wl;
const ImageBuffer = @import("../ImageBuffer.zig");
const ui_theme = @import("ui").theme;
const wallpaper_load = @import("../wallpaper_load.zig");
const wallpapers = @import("../wallpapers.zig");
const startup = @import("../startup.zig");
const png = @import("../png.zig");
const log = std.log.scoped(.compositor);

/// Runs on the compositor thread, woken by `IconService`'s worker thread
/// finishing a decode (see `icon_service.zig`'s module comment). Does not
/// know or care which consumer wanted the icon that just became ready — it
/// rechecks live consumers. Chrome/taskbar memos and the menu's visible icon
/// IDs avoid repainting when nothing relevant changed, so touching them is safe and
/// avoids tracking per-request subscriber pointers into windows/panels that
/// could be destroyed before their icon arrives.
pub fn themeColorArgb(color: [4]f32) u32 {
    const a = std.math.clamp(color[3], 0, 1);
    const a8: u32 = @intFromFloat(@round(a * 255.0));
    const r8: u32 = @intFromFloat(@round(std.math.clamp(color[0] * a, 0, 1) * 255.0));
    const g8: u32 = @intFromFloat(@round(std.math.clamp(color[1] * a, 0, 1) * 255.0));
    const b8: u32 = @intFromFloat(@round(std.math.clamp(color[2] * a, 0, 1) * 255.0));
    return (a8 << 24) | (r8 << 16) | (g8 << 8) | b8;
}

pub fn applyDecodedWallpaper(server: *Server, decoded: png.Image) void {
    const image = ImageBuffer.createFromDecoded(decoded) catch |err| {
        log.warn("applyDecodedWallpaper: {}", .{err});
        decoded.deinit(@import("../main.zig").gpa);
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

pub fn handleCatalogWake(fd: c_int, mask: wl.EventMask, server: *Server) c_int {
    _ = fd;
    _ = mask;
    if (!server.start_menu_catalog.drainCompletions()) return 0;
    // New entries usually come with icons (a package install, or a launcher
    // sync such as arch-run's linking them into ~/.local/share/icons before
    // moving the entries in), which the cached theme index has not seen.
    server.iconRefreshInstalled();
    if (server.input.open_control_center) |cc| cc.refresh();
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        output.dock.invalidate();
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

pub fn saveLoginTheme(server: *Server) void {
    if (server.greeter_mode) return;
    const dir = server.login_appearance_dir orelse return;
    @import("../session/login_appearance.zig").saveTheme(@import("../main.zig").gpa, dir, ui_theme.global) catch |err| {
        log.warn("could not save login appearance: {s}", .{@errorName(err)});
    };
}

pub fn loadWallpaper(server: *Server, delay_ns: u64) void {
    const gpa = @import("../main.zig").gpa;
    const path = @import("../config_runtime/theme_pack.zig").wallpaperPath(server, gpa) catch |err| {
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
    const loader = wallpaper_load.Loader.start(gpa, server.io, candidates[0..count], delay_ns, server.login_appearance_dir) catch |err| {
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

pub fn stopWallpaperLoad(server: *Server) void {
    if (server.wallpaper_wake_source) |source| source.remove();
    server.wallpaper_wake_source = null;
    if (server.wallpaper_loader) |loader| loader.deinit();
    server.wallpaper_loader = null;
}

pub fn forgetWallpaperSource(server: *Server) void {
    if (server.wallpaper_source) |path| @import("../main.zig").gpa.free(path);
    server.wallpaper_source = null;
}

pub fn handleWallpaperWake(fd: c_int, mask: wl.EventMask, server: *Server) c_int {
    _ = fd;
    _ = mask;
    const gpa = @import("../main.zig").gpa;
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
    server.reveal.onWallpaper();
    if (server.input.open_control_center) |cc| cc.refresh();
    if (server.ipc) |ipc| ipc.wait_mgr.checkAll();
    return 0;
}

pub fn handleIconWake(fd: c_int, mask: wl.EventMask, server: *Server) c_int {
    _ = fd;
    _ = mask;
    const service = server.icon_service orelse return 0;
    service.drainCompletions();

    const now = @import("../Toplevel.zig").nowMs();
    var toplevel_it = server.world.toplevels.iterator(.forward);
    while (toplevel_it.next()) |toplevel| {
        toplevel.syncChrome(false, now) catch |err| {
            log.warn("handleIconWake: syncChrome failed: {}", .{err});
        };
    }

    var output_it = server.outputs.iterator(.forward);
    while (output_it.next()) |output| {
        if (output.taskbar) |bar| bar.notifyToplevelsChanged();
        output.dock.invalidate();
        if (output.start_menu) |sm| sm.iconsReady();
    }
    if (server.notifications) |mgr| mgr.iconsReady();
    server.input.window_menu.iconsReady();
    if (server.input.open_control_center) |cc| @import("../control_center/sections/appearance.zig").iconsReady(&cc.appearance);
    if (server.tray) |tray| tray.changed();
    server.scheduleFrames();
    return 0;
}
