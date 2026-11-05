//! Files dragged onto the dock's Trash item go to the Trash, with no question
//! asked (the Trash is where a deleted file can still be got back from).
//!
//! This is the desktop Trash icon's drop (`desktop_drop.zig`) for the dock: the
//! compositor is the target of a wl_data_device drag. Only a source that offers
//! text/uri-list and allows *move* may drop here; a copy-only drag (a link, an
//! archive member) is refused rather than deleting what the user meant to copy.
//! The list is read on the event loop, because a client writes it at its own
//! pace (a stalled one is dropped after `read_timeout_ms`); `gio trash` does the
//! moving, as Files and the desktop do. The drag is finished when `gio` exits,
//! so the source learns whether it worked.
const std = @import("std");
const platform = @import("platform");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const i18n = @import("i18n");
const Input = @import("Input.zig");
const Server = @import("Server.zig");
const Dock = @import("Dock.zig");
const Child = @import("session/child.zig");
const app_scope = @import("session/app_scope.zig");
const DropTarget = @import("desktop_drop.zig").Target;
const dnd = @import("desktop/dnd.zig");
const gpa = @import("main.zig").gpa;
const Self = @This();

/// A URI list longer than this is not a selection of files: the drop is refused.
const max_list = 256 * 1024;
const read_timeout_ms = 5000;

target: DropTarget = .{},
/// The read end of the URI list and what has come through it, until the writer closes.
fd: i32 = -1,
data: std.ArrayList(u8) = .empty,
source: ?*wl.EventSource = null,
timer: ?*wl.EventSource = null,
/// The `gio trash` run that the drag waits for.
child: ?*Child = null,

pub fn deinit(self: *Self) void {
    self.stopReading();
    if (self.timer) |timer| timer.remove();
    self.timer = null;
    // The process runs on, reaped by its watch; nothing may call back into us.
    if (self.child) |child| child.detach();
    self.child = null;
    self.data.deinit(gpa);
}

fn input(self: *Self) *Input {
    return @fieldParentPtr("trash_drop", self);
}

/// A file drag is over the dock: the Trash item takes it, the rest of the dock
/// does not. Tells the source, so it can show what a drop would do.
pub fn hover(self: *Self, over_trash: bool) void {
    const in = self.input();
    if (over_trash and in.server.locker == null) self.target.hover(in.seat, .move, false) else self.target.refuse(in.seat);
}

/// A drag was released over `dock` at (`x`, `y`) in the dock's own coordinates.
/// True when the Trash took it; false leaves it to wlroots, which cancels it.
/// Call before the release reaches the seat (`desktop_drop.Target.take`).
pub fn drop(self: *Self, dock: *Dock, x: f64, y: f64, button: u32) bool {
    const in = self.input();
    if (in.server.locker != null or !dock.trashAt(x, y)) return false;
    const taken = self.target.take(in.seat, button, .move, false) orelse return false;
    self.receive(taken.fd);
    return true;
}

fn receive(self: *Self, fd: i32) void {
    const loop = self.input().server.wl_server.getEventLoop();
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }))) < 0) {
        _ = std.c.close(fd);
        return self.failed();
    }
    self.fd = fd;
    self.data.clearRetainingCapacity();
    self.source = loop.addFd(*Self, fd, .{ .readable = true }, readable, self) catch return self.abandon();
    if (self.timer == null) self.timer = loop.addTimer(*Self, timedOut, self) catch return self.abandon();
    self.timer.?.timerUpdate(read_timeout_ms) catch self.abandon();
}

fn readable(fd: c_int, _: wl.EventMask, self: *Self) c_int {
    // Bounded per dispatch, so a fast writer cannot starve input.
    var budget: usize = 64 * 1024;
    while (budget > 0) {
        var buffer: [4096]u8 = undefined;
        const n = std.c.read(fd, &buffer, buffer.len);
        if (n > 0) {
            const len: usize = @intCast(n);
            budget -|= len;
            if (self.data.items.len + len > max_list) {
                self.abandon();
                return 0;
            }
            self.data.appendSlice(gpa, buffer[0..len]) catch {
                self.abandon();
                return 0;
            };
            continue;
        }
        if (n == 0) {
            self.received();
            return 0;
        }
        switch (std.posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return 0,
            else => {
                self.abandon();
                return 0;
            },
        }
    }
    return 0;
}

fn timedOut(self: *Self) c_int {
    self.abandon();
    return 0;
}

fn stopReading(self: *Self) void {
    if (self.source) |source| source.remove();
    self.source = null;
    if (self.timer) |timer| timer.timerUpdate(0) catch {};
    if (self.fd >= 0) _ = std.c.close(self.fd);
    self.fd = -1;
}

/// The writer closed its end: the list is complete.
fn received(self: *Self) void {
    self.stopReading();
    defer self.data.clearRetainingCapacity();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const paths = parse(arena.allocator(), self.data.items) catch &.{};
    if (paths.len == 0) return self.target.finish(false);
    self.trash(arena.allocator(), paths);
}

/// The local files in a text/uri-list; other URIs and comments are skipped.
fn parse(a: std.mem.Allocator, list: []const u8) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |raw| {
        const uri = std.mem.trim(u8, raw, " \t\r");
        if (uri.len == 0 or uri[0] == '#') continue;
        try paths.append(a, dnd.localPath(a, uri) catch continue);
    }
    return paths.items;
}

/// Starts `gio trash`. There is no prompt to answer: `gio` reads no input.
fn trash(self: *Self, a: std.mem.Allocator, paths: []const []const u8) void {
    const server = self.input().server;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ "gio", "trash", "--" }) catch return self.failed();
    argv.appendSlice(a, paths) catch return self.failed();
    var env = server.environ.createMap(gpa) catch return self.failed();
    defer env.deinit();
    server.applyChildEnv(&env) catch return self.failed();
    const started = std.process.spawn(server.io, .{ .argv = argv.items, .environ_map = &env, .stdin = .ignore }) catch |err| {
        std.log.warn("could not run gio trash: {}", .{err});
        return self.failed();
    };
    const pid = started.id orelse return self.failed();
    app_scope.place(server, pid, "gio");
    self.child = Child.watch(gpa, server.wl_server.getEventLoop(), pid, self, exited) catch {
        // Nobody would collect it.
        platform.child.killAndReap(pid);
        return self.failed();
    };
}

fn exited(owner: ?*anyopaque, _: *Child, status: ?u32) void {
    const self: *Self = @ptrCast(@alignCast(owner.?));
    self.child = null;
    const ok = if (status) |value| std.posix.W.IFEXITED(value) and std.posix.W.EXITSTATUS(value) == 0 else false;
    if (ok) self.target.finish(true) else self.failed();
}

/// The list never arrived whole.
fn abandon(self: *Self) void {
    self.stopReading();
    self.failed();
}

/// Nothing (or not everything) was moved: say so, and cancel the drag.
fn failed(self: *Self) void {
    self.target.finish(false);
    const manager = self.input().server.notifications orelse return;
    _ = manager.postNotification(i18n.tr("Trash"), 0, "user-trash", i18n.tr("Could not move all items to Trash"), "", &.{}, 1, false, false, 0, "", null) catch {};
}
