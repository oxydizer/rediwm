// Owned Xwayland server. Created after compositor and seat, destroyed before
// them. DISPLAY is published from `display_name` immediately — lazy startup
// still reserves the socket, so children must not wait for `ready`.
const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("Server.zig");
const XwaylandOutputManager = @import("xwayland_output.zig").XwaylandOutputManager;
const gpa = @import("main.zig").gpa;

const Xwayland = @This();
const log = std.log.scoped(.xwayland);

server: *Server,
wlr_xwayland: *wlr.Xwayland,
output_manager: ?*XwaylandOutputManager = null,
scale: f64 = 1,
native_scaling: bool = false,
scale_locked: bool = false,
ready: bool = false,
stop_source: ?*wl.EventSource = null,

on_ready: wl.Listener(void) = .init(handleReady),
on_destroy: wl.Listener(void) = .init(handleDestroy),
on_new_surface: wl.Listener(*wlr.XwaylandSurface) = .init(handleNewSurface),

pub fn create(server: *Server) ?*Xwayland {
    if (!wlr.config.has_xwayland) {
        log.warn("wlroots was built without Xwayland; native apps still work", .{});
        return null;
    }
    if (!server.config.compositor.xwayland) {
        log.info("Xwayland disabled in config; native apps still work", .{});
        return null;
    }
    if (!xwaylandOnPath(server.io, server.environ)) {
        log.err("Xwayland enabled but the Xwayland binary was not found on PATH; native apps still work", .{});
        return null;
    }

    const native_scaling = server.configuredXwaylandNativeScaling();
    // Reserving DISPLAY is enough for child environments. Native scaling's
    // private output global and ready callback work with on-demand startup too.
    const wlr_xwayland = wlr.Xwayland.create(server.wl_server, server.compositor, true) catch |err| {
        log.err("failed to create Xwayland: {}; native apps still work", .{err});
        return null;
    };

    const xwayland = gpa.create(Xwayland) catch {
        wlr_xwayland.destroy();
        log.err("out of memory creating Xwayland; native apps still work", .{});
        return null;
    };
    const scale = server.computeXwaylandScale();
    var output_manager: ?*XwaylandOutputManager = null;
    if (native_scaling) {
        output_manager = XwaylandOutputManager.create(server) catch |err| blk: {
            log.err("failed to create xwayland xdg-output manager: {}", .{err});
            break :blk null;
        };
    }
    xwayland.* = .{
        .server = server,
        .wlr_xwayland = wlr_xwayland,
        .output_manager = output_manager,
        .scale = scale,
        .native_scaling = native_scaling,
    };
    wlr_xwayland.events.ready.add(&xwayland.on_ready);
    wlr_xwayland.events.destroy.add(&xwayland.on_destroy);
    wlr_xwayland.events.new_surface.add(&xwayland.on_new_surface);
    wlr_xwayland.setSeat(server.input.seat);
    server.xwayland = xwayland;

    if (native_scaling) {
        log.info("Xwayland display {s} reserved (native scaling N={d}, lazy start)", .{ xwayland.displayName(), scale });
    } else {
        log.info("Xwayland display {s} reserved (lazy start)", .{xwayland.displayName()});
    }
    return xwayland;
}

pub fn destroy(xwayland: *Xwayland) void {
    xwayland.cancelStop();
    xwayland.on_ready.link.remove();
    xwayland.on_destroy.link.remove();
    xwayland.on_new_surface.link.remove();
    if (xwayland.output_manager) |mgr| mgr.destroy();
    xwayland.output_manager = null;
    xwayland.wlr_xwayland.destroy();
    gpa.destroy(xwayland);
}

pub fn displayName(xwayland: *const Xwayland) []const u8 {
    return std.mem.span(xwayland.wlr_xwayland.display_name);
}

/// Stop the compositor-owned wrapper through wlroots' supported teardown
/// path. This is useful for logout/administrative cleanup and deterministic
/// lifecycle testing, and cannot affect an X server belonging to the host.
pub fn stop(xwayland: *Xwayland) void {
    if (xwayland.stop_source != null) return;
    const loop = xwayland.server.wl_server.getEventLoop();
    xwayland.stop_source = loop.addIdle(*Xwayland, stopIdle, xwayland) catch |err| {
        log.err("could not schedule Xwayland stop: {}", .{err});
        return;
    };
}

fn cancelStop(xwayland: *Xwayland) void {
    if (xwayland.stop_source) |source| source.remove();
    xwayland.stop_source = null;
}

fn stopIdle(xwayland: *Xwayland) void {
    // Wayland removes an idle source after dispatch; don't remove it twice.
    xwayland.stop_source = null;
    const server = xwayland.server;
    if (server.xwayland != xwayland) return;
    server.xwayland = null;
    xwayland.destroy();
}

fn handleNewSurface(listener: *wl.Listener(*wlr.XwaylandSurface), xsurface: *wlr.XwaylandSurface) void {
    const xwayland: *Xwayland = @fieldParentPtr("on_new_surface", listener);
    xwayland.scale_locked = true;
    if (xsurface.override_redirect) {
        @import("xwayland_unmanaged.zig").create(xwayland.server, xsurface) catch |err| {
            log.err("could not map override-redirect X11 window: {}", .{err});
        };
        return;
    }
    @import("Toplevel.zig").createXwayland(xwayland.server, xsurface) catch |err| {
        log.err("could not manage X11 window: {}", .{err});
    };
}

fn handleReady(listener: *wl.Listener(void)) void {
    const xwayland: *Xwayland = @fieldParentPtr("on_ready", listener);
    xwayland.ready = true;
    xwayland.applyCursor();
    if (xwayland.native_scaling) {
        xwayland.applyScaleHints();
    }
    @import("startup.zig").markXwaylandReady();
    log.info("Xwayland ready on {s}", .{xwayland.displayName()});
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const xwayland: *Xwayland = @fieldParentPtr("on_destroy", listener);
    xwayland.cancelStop();
    // The wlr_xwayland object is going away. Do not restart it: a crash loop
    // would pin the compositor. Native windows keep working.
    log.warn("Xwayland server destroyed; native windows remain usable", .{});
    xwayland.on_ready.link.remove();
    xwayland.on_destroy.link.remove();
    xwayland.on_new_surface.link.remove();
    if (xwayland.output_manager) |mgr| mgr.destroy();
    xwayland.output_manager = null;
    xwayland.server.xwayland = null;
    gpa.destroy(xwayland);
}

/// Real outputs are not known yet when Xwayland is constructed: `create` runs
/// during `Server.init`, before `server.backend.start()` even runs, so
/// `computeXwaylandScale()` at that point always sees an empty
/// `server.outputs` and freezes `scale` at 1 unless `REDIWM_SCALE` overrides
/// it. `Server.newOutput` calls this once each real output is known (and
/// scaled per the DPI policy) so the private xdg-output geometry is settled
/// before the first client starts Xwayland.
pub fn refreshScale(xwayland: *Xwayland) void {
    if (!xwayland.native_scaling or xwayland.scale_locked) return;
    const new_scale = xwayland.server.computeXwaylandScale();
    if (new_scale == xwayland.scale) return;
    xwayland.scale = new_scale;
    log.info("Xwayland native scaling N={d} (output scale settled)", .{new_scale});
    if (xwayland.output_manager) |mgr| mgr.refreshAll();
    if (xwayland.ready) xwayland.applyScaleHints();
}

pub fn applyCursor(xwayland: *Xwayland) void {
    const input = &xwayland.server.input;
    if (!xwayland.ready) return;
    const cursor = input.cursor_mgr.getXcursor("default", 1) orelse
        input.cursor_mgr.getXcursor("left_ptr", 1) orelse return;
    if (cursor.image_count == 0) return;
    const image = cursor.images[0];
    xwayland.wlr_xwayland.setCursor(image.getBuffer(), @intCast(image.hotspot_x), @intCast(image.hotspot_y));
}

fn applyScaleHints(xwayland: *Xwayland) void {
    const disp = xwayland.displayName();
    var disp_z: [64:0]u8 = undefined;
    if (disp.len >= disp_z.len) return;
    @memcpy(disp_z[0..disp.len], disp);
    disp_z[disp.len] = 0;

    var screen_num: c_int = 0;
    const conn = xcb_connect(&disp_z, &screen_num) orelse {
        log.err("failed to connect to Xwayland for RESOURCE_MANAGER", .{});
        return;
    };
    defer xcb_disconnect(conn);
    if (xcb_connection_has_error(conn) != 0) {
        log.err("failed to connect to Xwayland for RESOURCE_MANAGER", .{});
        return;
    }

    const setup = xcb_get_setup(conn);
    const iter = xcb_setup_roots_iterator(setup);
    const screen = iter.data orelse return;

    var prop_buf: [256]u8 = undefined;
    const n = xwayland.scale;
    const dpi = 96 * n;
    // X11 clients load their own cursors; name the compositor's theme.
    const theme = @import("cursor_theme.zig").managerTheme(xwayland.server.config.input.cursor_theme);
    const prop_str = if (theme) |name|
        std.fmt.bufPrint(&prop_buf, "Xft.dpi:\t{d}\nXcursor.size:\t24\nXcursor.theme:\t{s}\n", .{ dpi, name }) catch return
    else
        std.fmt.bufPrint(&prop_buf, "Xft.dpi:\t{d}\nXcursor.size:\t24\n", .{dpi}) catch return;

    const xcb_prop_mode_replace: u8 = 0;
    const xcb_atom_resource_manager: u32 = 23;
    const xcb_atom_string: u32 = 31;

    _ = xcb_change_property(
        conn,
        xcb_prop_mode_replace,
        screen.*.root,
        xcb_atom_resource_manager,
        xcb_atom_string,
        8,
        @intCast(prop_str.len),
        prop_str.ptr,
    );
    _ = xcb_flush(conn);
    log.info("published X11 RESOURCE_MANAGER (Xft.dpi={d}, Xcursor.size=24)", .{dpi});
}

/// Kill the X client owning this resource, without trusting its _NET_WM_PID.
pub fn forceClose(xwayland: *Xwayland, window: u32) void {
    if (!xwayland.ready or window == 0) return;
    const conn = xcb_connect(xwayland.wlr_xwayland.display_name, null) orelse return;
    defer xcb_disconnect(conn);
    if (xcb_connection_has_error(conn) != 0) return;
    // Wait for the request before dropping this short-lived connection: X11
    // may otherwise observe its disconnect before dispatching KillClient.
    if (xcb_request_check(conn, xcb_kill_client_checked(conn, window))) |err| {
        std.c.free(err);
        log.warn("could not force close X11 window {d}", .{window});
    }
}

const xcb_void_cookie_t = extern struct { sequence: c_uint };
extern fn xcb_kill_client_checked(c: *xcb_connection_t, resource: u32) xcb_void_cookie_t;
extern fn xcb_request_check(c: *xcb_connection_t, cookie: xcb_void_cookie_t) ?*anyopaque;

const xcb_connection_t = anyopaque;
const xcb_setup_t = anyopaque;
const xcb_screen_t = extern struct {
    root: u32,
    default_colormap: u32,
    white_pixel: u32,
    black_pixel: u32,
    current_input_masks: u32,
    width_in_pixels: u16,
    height_in_pixels: u16,
    width_in_millimeters: u16,
    height_in_millimeters: u16,
    min_installed_maps: u16,
    max_installed_maps: u16,
    root_visual: u32,
    backing_stores: u8,
    save_unders: u8,
    root_depth: u8,
    allowed_depths_len: u8,
};
const xcb_screen_iterator_t = extern struct {
    data: ?*xcb_screen_t,
    rem: c_int,
    index: c_int,
};

extern fn xcb_connect(displayname: ?[*:0]const u8, screen: ?*c_int) ?*xcb_connection_t;
extern fn xcb_connection_has_error(c: *xcb_connection_t) c_int;
extern fn xcb_disconnect(c: *xcb_connection_t) void;
extern fn xcb_get_setup(c: *xcb_connection_t) *const xcb_setup_t;
extern fn xcb_setup_roots_iterator(R: *const xcb_setup_t) xcb_screen_iterator_t;
extern fn xcb_change_property(
    c: *xcb_connection_t,
    mode: u8,
    window: u32,
    property: u32,
    type: u32,
    format: u8,
    data_len: u32,
    data: ?*const anyopaque,
) extern struct { sequence: c_uint };
extern fn xcb_flush(c: *xcb_connection_t) c_int;

pub fn globalVisible(xwayland: *const Xwayland, client: *const wl.Client, global: *const wl.Global) ?bool {
    const owner = if (xwayland.wlr_xwayland.server) |xw_server| xw_server.client else null;
    const is_xwayland = owner != null and @intFromPtr(client) == @intFromPtr(owner.?);

    if (global == xwayland.wlr_xwayland.shell_v1.global) {
        return is_xwayland;
    }
    if (xwayland.native_scaling) {
        if (xwayland.server.xdg_output_manager) |mgr| {
            if (global == mgr.global) {
                if (is_xwayland) return false;
                return null;
            }
        }
        if (xwayland.output_manager) |mgr| {
            if (global == mgr.global) return is_xwayland;
        }
    }
    return null;
}

fn xwaylandOnPath(io: std.Io, environ: std.process.Environ) bool {
    const path = environ.getPosix("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(buf[0..], "{s}/Xwayland", .{dir}) catch continue;
        std.Io.Dir.cwd().access(io, full, .{}) catch continue;
        return true;
    }
    return false;
}
