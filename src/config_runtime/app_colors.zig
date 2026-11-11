//! One compositor-owned exporter for manual snapshots and automatic following.
//! A burst of edits retains only the latest palette; closing Settings never
//! cancels synchronization. An unchanged palette performs no filesystem work.
const std = @import("std");
const Server = @import("../Server.zig");
const wl = @import("wayland").server.wl;
const app = @import("config").app_theme;
const worker = @import("app_theme.zig");
const theme = @import("ui").theme;

pub const State = struct {
    job: ?*worker.Job = null,
    source: ?*wl.EventSource = null,
    pending: bool = false,
    action: ?worker.Action = null,
    result: ?worker.Result = null,
    failure: ?anyerror = null,
    palette: ?app.Palette = null,
    gtk_slot: ?u1 = null,
    qt_styles: worker.QtStyles = .{},

    pub fn deinit(self: *State) void {
        if (self.source) |source| source.remove();
        if (self.job) |job| job.deinit();
        self.qt_styles.deinit();
        self.* = .{};
    }
};

pub fn gtkTheme(server: *Server) ?[]const u8 {
    if (server.greeter_mode or !server.config.compositor.follow_app_colors) return null;
    return if (server.app_colors.gtk_slot) |slot| app.follow.name(slot) else null;
}

pub fn sync(server: *Server) void {
    const state = &server.app_colors;
    if (server.greeter_mode or !server.config.compositor.follow_app_colors) {
        state.pending = false;
        state.palette = null;
        return;
    }
    if (state.job != null) {
        state.pending = true;
        return;
    }
    const palette = app.Palette.fromTheme(theme.global);
    if (state.palette) |last| {
        if (state.failure == null and std.meta.eql(last, palette)) return;
    }
    start(server, .follow) catch |err| fail(server, err);
}

pub fn start(server: *Server, action: worker.Action) !void {
    if (server.greeter_mode) return error.GreeterMode;
    const state = &server.app_colors;
    if (state.job != null) return error.AppColorsBusy;
    const job = try worker.Job.create(server.io, server.environ, action, app.Palette.fromTheme(theme.global), .{ state.qt_styles.qt5, state.qt_styles.qt6 });
    errdefer job.deinit();
    const source = try server.wl_server.getEventLoop().addFd(*Server, job.fd, .{ .readable = true }, ready, server);
    errdefer source.remove();
    try job.start();
    state.job = job;
    state.source = source;
    state.action = action;
    state.failure = null;
    state.result = null;
    refresh(server);
}

pub fn fail(server: *Server, err: anyerror) void {
    server.app_colors.failure = err;
    std.log.warn("app colors export failed: {}", .{err});
    refresh(server);
}

fn refresh(server: *Server) void {
    if (server.input.open_control_center) |cc| {
        if (cc.showingPage(.appearance)) cc.refresh();
    }
}

fn ready(_: c_int, _: wl.EventMask, server: *Server) c_int {
    const state = &server.app_colors;
    const job = state.job orelse return 0;
    state.source.?.remove();
    state.source = null;
    state.job = null;
    job.join();
    defer job.deinit();
    if (job.result) |result| {
        state.result = result;
        if (result.qt_error == null and (result.support.qt5 or result.support.qt6)) server.qt_app_colors = true;
        if (result.gtk_slot) |slot| {
            const changed = state.gtk_slot == null or state.gtk_slot.? != slot;
            state.gtk_slot = slot;
            state.palette = job.palette;
            if (changed) @import("../session/settings_portal.zig").emitGtkTheme(server);
        } else state.palette = null;
    } else |err| fail(server, err);
    const pending = state.pending;
    state.pending = false;
    if (pending) sync(server);
    refresh(server);
    return 0;
}
