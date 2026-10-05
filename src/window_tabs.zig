//! Compositor window groups. Membership requires an explicit + launch and
//! attribution by activation token or a newly spawned process, never app ID alone.
const std = @import("std");
const wl = @import("wayland").server.wl;
const Server = @import("Server.zig");
const Top = @import("Toplevel.zig");
const apps = @import("start_menu/applications.zig");
const gpa = @import("main.zig").gpa;
const Self = @This();

known: std.ArrayList([]const u8) = .empty,
loaded: bool = false,
pending: std.ArrayList(*Pending) = .empty,

pub const max_tabs = 128;
pub const Notice = enum { none, opening, failed };
const Pending = struct {
    server: *Server,
    group: u64,
    after_id: u64,
    pid: i32 = 0,
    token: []const u8,
    timer: ?*wl.EventSource = null,
};

pub fn deinit(self: *Self) void {
    while (self.pending.pop()) |p| destroyPending(p);
    self.pending.deinit(gpa);
    for (self.known.items) |id| gpa.free(id);
    self.known.deinit(gpa);
}

/// Transmission's GTK application ID includes a per-instance numeric suffix.
/// Keep the stable app identity in preferences and the discovered-app list.
pub fn identity(raw: []const u8) []const u8 {
    const base = "com.transmissionbt.transmission";
    if (std.mem.startsWith(u8, raw, base ++ "_")) {
        var parts = std.mem.splitScalar(u8, raw[base.len + 1 ..], '_');
        const first = parts.next() orelse return raw;
        const second = parts.next() orelse return raw;
        if (first.len == 0 or second.len == 0 or parts.next() != null) return raw;
        for (first) |ch| if (!std.ascii.isDigit(ch)) return raw;
        for (second) |ch| if (!std.ascii.isDigit(ch)) return raw;
        return base;
    }
    return raw;
}

pub fn enabled(server: *Server, raw: []const u8) bool {
    const id = identity(raw);
    if (std.mem.startsWith(u8, id, "rediwm-")) return false;
    for (server.config.compositor.window_tab_apps) |app| if (std.mem.eql(u8, id, identity(app))) return true;
    return false;
}

pub fn entry(entries: []const apps.AppEntry, raw: []const u8) ?*const apps.AppEntry {
    const id = identity(raw);
    // Prefer exact identities; suffix heuristics used by icon lookup aren't
    // sufficient authority to launch an application.
    for (entries) |*e| {
        const stem = if (std.mem.endsWith(u8, e.id, ".desktop")) e.id[0 .. e.id.len - 8] else e.id;
        if (std.mem.eql(u8, id, e.id) or std.mem.eql(u8, id, stem)) return e;
    }
    if (std.mem.eql(u8, id, "com.transmissionbt.transmission")) {
        for (entries) |*e| if (std.mem.eql(u8, e.id, "transmission-gtk.desktop")) return e;
    }
    var found: ?*const apps.AppEntry = null;
    for (entries) |*e| if (e.startup_wm_class) |wm| {
        if (std.mem.eql(u8, wm, id)) {
            if (found != null) return null;
            found = e;
        }
    };
    return found;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 512 or !std.unicode.utf8ValidateSlice(id)) return false;
    for (id) |ch| if (ch < 32 or ch == 127) return false;
    return true;
}

pub fn remember(self: *Self, raw: []const u8) bool {
    const id = identity(raw);
    if (std.mem.startsWith(u8, id, "rediwm-")) return false;
    if (!validId(id) or self.known.items.len >= 2048) return false;
    for (self.known.items) |known| if (std.mem.eql(u8, known, id)) return false;
    const copy = gpa.dupe(u8, id) catch return false;
    self.known.append(gpa, copy) catch {
        gpa.free(copy);
        return false;
    };
    return true;
}

pub fn loadKnown(self: *Self, server: *Server) void {
    if (self.loaded or server.greeter_mode) return;
    self.loaded = true;
    const dir = (@import("window_sizes.zig").resolveStateDir(gpa, server.environ) catch return) orelse return;
    defer gpa.free(dir);
    const path = std.fmt.allocPrint(gpa, "{s}/window_tab_apps", .{dir}) catch return;
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(server.io, path, gpa, .limited(1 << 20)) catch return;
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice([]const []const u8, gpa, bytes, .{}) catch return;
    defer parsed.deinit();
    for (parsed.value) |id| _ = self.remember(id);
}

fn saveKnown(self: *Self, server: *Server) void {
    if (server.greeter_mode) return;
    const dir = (@import("window_sizes.zig").resolveStateDir(gpa, server.environ) catch return) orelse return;
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(server.io, dir) catch return;
    const path = std.fmt.allocPrint(gpa, "{s}/window_tab_apps", .{dir}) catch return;
    defer gpa.free(path);
    const tmp = std.fmt.allocPrint(gpa, "{s}.tmp", .{path}) catch return;
    defer gpa.free(tmp);
    const bytes = std.json.Stringify.valueAlloc(gpa, self.known.items, .{}) catch return;
    defer gpa.free(bytes);
    const file = std.Io.Dir.cwd().createFile(server.io, tmp, .{ .permissions = .fromMode(0o600) }) catch return;
    defer file.close(server.io);
    defer std.Io.Dir.cwd().deleteFile(server.io, tmp) catch {};
    file.writeStreamingAll(server.io, bytes) catch return;
    std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, server.io) catch {};
}

fn eligible(top: *Top) bool {
    if (!top.in_world or top.backend_gone or top.backend == .shell or top.backend == .placeholder) return false;
    switch (top.backend) {
        .xdg => |*a| if (a.xdg_toplevel.parent != null) return false,
        .xwayland => |*a| if (a.xsurface.parent != null) return false,
        else => return false,
    }
    return top.hasServerDecorations();
}

pub fn reconcile(self: *Self, top: *Top) void {
    if (top.server.greeter_mode) return;
    self.loadKnown(top.server);
    const can_tab = eligible(top);
    if (can_tab and self.remember(top.appId())) {
        self.saveKnown(top.server);
        if (top.server.input.open_control_center) |cc| cc.refresh();
    }
    if (top.tab_group != 0 and !std.mem.eql(u8, top.tab_identity, identity(top.appId()))) self.remove(top, true);
    if (!enabled(top.server, top.appId()) or (!can_tab and !top.isFullscreen())) {
        if (top.tab_group != 0) self.remove(top, true);
        return;
    }
    if (can_tab and top.tab_group == 0) {
        const known_id = for (self.known.items) |id| {
            if (std.mem.eql(u8, id, identity(top.appId()))) break id;
        } else return;
        top.tab_identity = known_id;
        top.tab_group = top.id;
        top.tab_restore = top.rememberGeometry();
        publish(top);
    }
}

fn publish(top: *Top) void {
    top.syncForeign();
    if (top.server.ipc) |ipc| @import("ipc/events.zig").onWindowChanged(ipc, top);
}

pub fn reconfigure(self: *Self, server: *Server) void {
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        self.reconcile(top);
        top.syncChrome(false, false, Top.nowMs()) catch {};
    }
    var pending_index: usize = 0;
    while (pending_index < self.pending.items.len) {
        if (active(server, self.pending.items[pending_index].group) == null) self.finish(pending_index, false) else pending_index += 1;
    }
    server.refreshTaskbars();
}

pub fn active(server: *Server, group: u64) ?*Top {
    if (group == 0) return null;
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| if (top.tab_group == group and !top.tab_hidden and top.in_world) return top;
    return null;
}

pub fn members(top: *Top, storage: *[max_tabs]*Top) []*Top {
    if (top.tab_group == 0) return storage[0..0];
    var count: usize = 0;
    var it = top.server.world.toplevels.iterator(.forward);
    while (it.next()) |other| {
        if (other.tab_group != top.tab_group or count == storage.len) continue;
        storage[count] = other;
        count += 1;
    }
    std.mem.sort(*Top, storage[0..count], {}, struct {
        fn less(_: void, a: *Top, b: *Top) bool {
            return a.id < b.id;
        }
    }.less);
    return storage[0..count];
}

fn copyGeometry(from: *Top, to: *Top) void {
    to.finishMoveAnimation();
    to.finishZoomAnimation();
    to.finishSizeAnimation();
    to.fullscreen = from.fullscreen;
    to.fullscreen_restore = from.fullscreen_restore;
    to.fullscreen_target = from.fullscreen_target;
    to.maximized = from.maximized;
    to.maximize_restore = from.maximize_restore;
    to.maximize_target = from.maximize_target;
    to.tile = from.tile;
    to.tile_target = from.tile_target;
    to.tile_restore = from.tile_restore;
    to.pending_restore = from.pending_restore;
    to.setZoomOrigin(from.zoom_index);
    switch (to.backend) {
        .xdg => |*a| {
            _ = a.xdg_toplevel.setMaximized(from.maximized);
            _ = a.xdg_toplevel.setFullscreen(from.fullscreen);
        },
        .xwayland => |*a| {
            a.xsurface.setMaximized(from.maximized, from.maximized);
            a.xsurface.setFullscreen(from.fullscreen);
        },
        else => {},
    }
    to.sendTiled(if (from.tile) |tile| @import("snap.zig").tiledEdges(tile) else .{});
    const geom = from.forcedGeometry() orelse from.rememberGeometry();
    to.setPosition(geom.x, geom.y);
    _ = to.requestSize(geom.width, geom.height);
}

pub fn visible(top: *Top) bool {
    var next: ?*Top = top;
    var depth: usize = 0;
    while (next) |t| : (depth += 1) {
        if (depth == 32 or t.tab_hidden or t.minimized) return false;
        next = t.parentWindow();
    }
    return true;
}

pub fn refreshVisibility(server: *Server) void {
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (top.in_world and !top.closing) top.applyVisualTransform(Top.nowMs());
    }
    server.refreshTaskbars();
    server.scheduleFrames();
}

pub fn select(self: *Self, top: *Top) void {
    _ = self;
    if (!top.tab_hidden or !top.in_world) return;
    const old = active(top.server, top.tab_group) orelse {
        top.tab_hidden = false;
        return;
    };
    copyGeometry(old, top);
    top.tab_notice = old.tab_notice;
    top.tab_first = old.tab_first;
    const minimized = old.minimized;
    old.detachInput();
    old.setActivated(false);
    old.tab_hidden = true;
    old.minimized = false;
    old.frame_tree.node.setEnabled(false);
    top.tab_hidden = false;
    top.minimized = minimized;
    top.map_motion.cancel(1);
    top.map_opacity.cancel(1);
    top.syncChrome(false, false, Top.nowMs()) catch {};
    old.syncForeign();
    top.syncForeign();
    if (top.server.ipc) |ipc| {
        @import("ipc/events.zig").onWindowChanged(ipc, old);
        @import("ipc/events.zig").onWindowChanged(ipc, top);
    }
    refreshVisibility(top.server);
}

pub fn focusMember(self: *Self, top: *Top) void {
    var parent: ?*Top = top;
    var depth: usize = 0;
    while (parent) |p| : (depth += 1) {
        if (depth == 32) break;
        if (p.tab_hidden) self.select(p);
        if (p.minimized) p.restore();
        parent = p.parentWindow();
    }
}

pub fn remove(self: *Self, top: *Top, restore: bool) void {
    const group = top.tab_group;
    if (group == 0) return;
    const was_active = !top.tab_hidden;
    var storage: [max_tabs]*Top = undefined;
    const list = members(top, &storage);
    var next: ?*Top = null;
    for (list) |other| if (other != top) {
        next = other;
        break;
    };
    if (was_active) if (next) |other| self.select(other);
    top.tab_group = 0;
    top.tab_identity = "";
    top.tab_hidden = false;
    top.tab_notice = .none;
    if (restore) if (top.tab_restore) |geom| {
        top.leaveLayout();
        top.setPosition(geom.x, geom.y);
        _ = top.requestSize(geom.width, geom.height);
    };
    top.tab_restore = null;
    publish(top);
    if (!restore and was_active) if (next) |other| {
        // Do not steal focus if an unrelated window is active.
        const focused = top.server.world.toplevels.first();
        if (focused == top or (focused != null and focused.?.parentWindow() == top)) top.server.world.focus(other);
    };
    if (active(top.server, group)) |other| other.syncChrome(false, false, Top.nowMs()) catch {};
    refreshVisibility(top.server);
}

pub fn closeGroup(top: *Top) void {
    var storage: [max_tabs]*Top = undefined;
    const list = members(top, &storage);
    if (list.len == 0) return top.sendClose();
    for (list) |member| member.sendClose();
}

fn notice(server: *Server, group: u64, value: Notice) void {
    if (active(server, group)) |top| {
        top.tab_notice = value;
        top.syncChrome(false, false, Top.nowMs()) catch {};
    }
}

pub fn launch(self: *Self, top: *Top) void {
    if (top.server.locker != null or top.server.polkit_dialog != null or top.server.greeter_mode or top.tab_group == 0) return;
    for (self.pending.items) |p| if (p.group == top.tab_group) return;
    var storage: [max_tabs]*Top = undefined;
    if (members(top, &storage).len == max_tabs) return;
    self.start(top) catch |err| {
        std.log.warn("new window tab: {}", .{err});
        notice(top.server, top.tab_group, .failed);
    };
}

fn start(self: *Self, top: *Top) !void {
    const server = top.server;
    const snapshot = server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    const app = entry(snapshot.entries, top.appId()) orelse return error.NoDesktopEntry;
    const token = server.activation.createToken() orelse return error.NoActivationToken;
    const p = try gpa.create(Pending);
    errdefer gpa.destroy(p);
    p.* = .{ .server = server, .group = top.tab_group, .after_id = server.next_toplevel_id -| 1, .token = try gpa.dupe(u8, std.mem.span(token.name())) };
    errdefer gpa.free(p.token);
    p.timer = try server.wl_server.getEventLoop().addTimer(*Pending, timeout, p);
    errdefer p.timer.?.remove();
    try p.timer.?.timerUpdate(10000);
    try self.pending.append(gpa, p);
    errdefer _ = self.pending.pop();
    p.pid = try @import("start_menu/launch.zig").launchNewWindow(gpa, server, app, p.token);
    notice(server, p.group, .opening);
}

fn destroyPending(p: *Pending) void {
    if (p.timer) |timer| timer.remove();
    gpa.free(p.token);
    gpa.destroy(p);
}

fn finish(self: *Self, index: usize, success: bool) void {
    const p = self.pending.orderedRemove(index);
    notice(p.server, p.group, if (success) .none else .failed);
    p.server.launch_feedback.endToken(p.token);
    destroyPending(p);
}

fn timeout(p: *Pending) c_int {
    const self = &p.server.window_tabs;
    for (self.pending.items, 0..) |item, i| if (item == p) {
        self.finish(i, false);
        break;
    };
    return 0;
}

fn attach(self: *Self, index: usize, top: *Top) bool {
    const p = self.pending.items[index];
    const source = active(top.server, p.group) orelse {
        self.finish(index, false);
        return false;
    };
    if (top.id <= p.after_id or !eligible(top) or !std.mem.eql(u8, identity(top.appId()), identity(source.appId()))) return false;
    top.tab_restore = top.rememberGeometry();
    top.tab_identity = source.tab_identity;
    top.tab_group = p.group;
    top.tab_hidden = true;
    self.select(top);
    self.finish(index, true);
    if (top.server.locker == null and top.server.polkit_dialog == null) top.server.world.focus(top);
    return true;
}

pub fn mapped(self: *Self, top: *Top) void {
    self.reconcile(top);
    const pid = top.clientPid() orelse return;
    for (self.pending.items, 0..) |p, i| {
        if (pid > 0 and p.pid > 0 and @import("placeholder_match.zig").matchesPidChain(pid, p.pid)) {
            _ = self.attach(i, top);
            return;
        }
    }
}

pub fn activated(self: *Self, top: *Top, token: []const u8) bool {
    for (self.pending.items, 0..) |p, i| {
        if (!std.mem.eql(u8, p.token, token)) continue;
        if (top.id <= p.after_id) {
            self.finish(i, false);
            return true;
        }
        // Activation is allowed before the first map. Preserve the explicit
        // destination until map, without relying on the client's process ID.
        if (!top.in_world) {
            top.tab_pending_group = p.group;
            return true;
        }
        _ = self.attach(i, top);
        return true;
    }
    return false;
}

pub fn mappedToken(self: *Self, top: *Top) void {
    const group = top.tab_pending_group;
    top.tab_pending_group = 0;
    if (group == 0) return;
    for (self.pending.items, 0..) |p, i| if (p.group == group) {
        _ = self.attach(i, top);
        return;
    };
}
