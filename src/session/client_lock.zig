//! ext-session-lock-v1 (swaylock, gtklock, hyprlock). A client lock is the
//! built-in `Lock` with `client` set, so every `locker != null` guard applies
//! unchanged. The built-in lock screen stays underneath as the fallback; the
//! client's surfaces cover it per output and take input.
//!
//! * The client's `unlock_and_destroy` ends the lock without PAM: the client
//!   authenticated. Unlocking through the built-in screen instead sends the
//!   client `finished`.
//! * If the client dies first, the session stays locked on the built-in
//!   screen. A new client may take over that abandoned lock; a built-in lock
//!   (hotkey, idle) is never handed to a client.
//! * `locked` is sent once every available output has committed a frame with
//!   the lock covering it (`Output.lock_commit_pending`).
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Lock = @import("lock.zig").Lock;
const gpa = @import("../main.zig").gpa;

const log = std.log.scoped(.session_lock);

pub const Manager = struct {
    server: *Server,
    new_lock: wl.Listener(*wlr.SessionLockV1) = .init(handleNewLock),

    pub fn create(server: *Server) !*Manager {
        const self = try gpa.create(Manager);
        errdefer gpa.destroy(self);
        const manager = try wlr.SessionLockManagerV1.create(server.wl_server);
        self.* = .{ .server = server };
        manager.events.new_lock.add(&self.new_lock);
        return self;
    }

    pub fn destroy(self: *Manager) void {
        self.new_lock.link.remove();
        gpa.destroy(self);
    }

    fn handleNewLock(listener: *wl.Listener(*wlr.SessionLockV1), wlr_lock: *wlr.SessionLockV1) void {
        const self: *Manager = @fieldParentPtr("new_lock", listener);
        const server = self.server;
        if (server.locker) |lock| {
            // Only a lock whose client died may be taken over.
            if (lock.origin != .client or lock.client != null) {
                log.info("refusing lock request: session already locked", .{});
                return wlr_lock.destroy();
            }
            ClientLock.attach(lock, wlr_lock) catch return wlr_lock.destroy();
            // Already covered: the abandoned lock has been showing all along.
            lock.client.?.sendLocked();
            return;
        }
        const lock = Lock.create(server, .client) catch |err| {
            log.err("cannot lock for client: {}", .{err});
            return wlr_lock.destroy();
        };
        ClientLock.attach(lock, wlr_lock) catch {
            // The session is locked now; the client just gets no say in it.
            return wlr_lock.destroy();
        };
        var it = server.outputs.iterator(.forward);
        while (it.next()) |out| out.lock_commit_pending = out.isAvailable();
        lock.client.?.checkLocked();
    }
};

pub const ClientLock = struct {
    lock: *Lock,
    wlr_lock: *wlr.SessionLockV1,
    surfaces: wl.list.Head(Surface, .link) = undefined,
    /// Keyboard target; the client gets keys whenever it has one.
    focused: ?*Surface = null,
    locked_sent: bool = false,

    new_surface: wl.Listener(*wlr.SessionLockSurfaceV1) = .init(handleNewSurface),
    unlock: wl.Listener(void) = .init(handleUnlock),
    destroy_listener: wl.Listener(void) = .init(handleDestroy),

    fn attach(lock: *Lock, wlr_lock: *wlr.SessionLockV1) !void {
        const self = try gpa.create(ClientLock);
        self.* = .{ .lock = lock, .wlr_lock = wlr_lock };
        self.surfaces.init();
        wlr_lock.events.new_surface.add(&self.new_surface);
        wlr_lock.events.unlock.add(&self.unlock);
        wlr_lock.events.destroy.add(&self.destroy_listener);
        lock.client = self;
    }

    /// Called by `Lock.destroy` when the lock ends some other way (PAM):
    /// wlroots then sends the client `finished`.
    pub fn end(self: *ClientLock) void {
        const wlr_lock = self.wlr_lock;
        self.detach();
        wlr_lock.destroy();
    }

    /// Forgets the client: listeners, surfaces and focus. The lock remains.
    fn detach(self: *ClientLock) void {
        const server = self.lock.server;
        self.new_surface.link.remove();
        self.unlock.link.remove();
        self.destroy_listener.link.remove();
        self.focused = null;
        while (self.surfaces.first()) |surface| surface.destroy();
        server.input.seat.keyboardClearFocus();
        server.input.seat.pointerClearFocus();
        self.lock.client = null;
        gpa.destroy(self);
    }

    fn sendLocked(self: *ClientLock) void {
        if (self.locked_sent) return;
        self.locked_sent = true;
        self.wlr_lock.sendLocked();
        log.info("session locked by client", .{});
    }

    /// Sends `locked` once no available output still shows unlocked content.
    pub fn checkLocked(self: *ClientLock) void {
        var it = self.lock.server.outputs.iterator(.forward);
        while (it.next()) |out| {
            if (out.lock_commit_pending and out.isAvailable()) return;
        }
        self.sendLocked();
    }

    /// Output teardown runs before wlroots destroys the lock surfaces on it;
    /// their scene trees go with the output's lock view.
    pub fn forgetOutput(self: *ClientLock, output: *Output) void {
        var it = self.surfaces.iterator(.forward);
        while (it.next()) |surface| {
            if (surface.output == output) {
                surface.output = null;
                surface.tree = null;
            }
        }
        self.checkLocked();
    }

    fn surfaceOn(self: *ClientLock, output: *Output) ?*Surface {
        var it = self.surfaces.iterator(.forward);
        while (it.next()) |surface| {
            if (surface.output == output) return surface;
        }
        return null;
    }

    /// True when the client's surface hides the built-in screen on `output`.
    pub fn covers(self: *ClientLock, output: *Output) bool {
        const surface = self.surfaceOn(output) orelse return false;
        return surface.lock_surface.surface.mapped;
    }

    /// Per frame, from `View.sync`: follow output size changes.
    pub fn syncOutput(self: *ClientLock, output: *Output) void {
        const surface = self.surfaceOn(output) orelse return;
        const box = output.cached_box;
        if (box.width <= 0 or box.height <= 0) return;
        if (surface.width == box.width and surface.height == box.height) return;
        surface.width = box.width;
        surface.height = box.height;
        _ = surface.lock_surface.configure(@intCast(box.width), @intCast(box.height));
    }

    fn focus(self: *ClientLock, target: ?*Surface) void {
        if (self.focused == target) return;
        self.focused = target;
        const seat = self.lock.server.input.seat;
        const surface = target orelse return seat.keyboardClearFocus();
        if (seat.getKeyboard()) |keyboard| {
            seat.keyboardNotifyEnter(surface.lock_surface.surface, keyboard.keycodes[0..keyboard.num_keycodes], &keyboard.modifiers);
        } else {
            const modifiers = std.mem.zeroes(wlr.Keyboard.Modifiers);
            seat.keyboardNotifyEnter(surface.lock_surface.surface, &.{}, &modifiers);
        }
    }

    /// Pointer motion while locked. False: the built-in screen is under the cursor.
    pub fn pointerMotion(self: *ClientLock, time_msec: u32) bool {
        const input = &self.lock.server.input;
        const seat = input.seat;
        const target = blk: {
            const out = Output.atLayout(self.lock.server, input.cursor.x, input.cursor.y) orelse break :blk null;
            const surface = self.surfaceOn(out) orelse break :blk null;
            if (!surface.lock_surface.surface.mapped) break :blk null;
            const lx = input.cursor.x - @as(f64, @floatFromInt(out.cached_box.x));
            const ly = input.cursor.y - @as(f64, @floatFromInt(out.cached_box.y));
            var sx: f64 = undefined;
            var sy: f64 = undefined;
            const hit = surface.lock_surface.surface.surfaceAt(lx, ly, &sx, &sy) orelse break :blk null;
            seat.pointerNotifyEnter(hit, sx, sy);
            seat.pointerNotifyMotion(time_msec, sx, sy);
            break :blk hit;
        };
        if (target == null) seat.pointerClearFocus();
        return target != null;
    }

    /// Button while locked. False: the built-in screen takes the click.
    pub fn button(self: *ClientLock, time_msec: u32, code: u32, state: wl.Pointer.ButtonState) bool {
        if (!self.pointerMotion(time_msec)) return false;
        const seat = self.lock.server.input.seat;
        if (state == .pressed) {
            const hovered = seat.pointer_state.focused_surface;
            var it = self.surfaces.iterator(.forward);
            while (it.next()) |surface| {
                if (hovered != null and wlr.Surface.getRootSurface(hovered.?) == surface.lock_surface.surface) {
                    self.focus(surface);
                    break;
                }
            }
        }
        _ = seat.pointerNotifyButton(time_msec, code, state);
        return true;
    }

    /// Scroll while locked; dropped unless a lock surface has the pointer.
    pub fn axis(self: *ClientLock, time_msec: u32, orientation: wl.Pointer.Axis, delta: f64, discrete: i32, source: wl.Pointer.AxisSource) void {
        if (!self.pointerMotion(time_msec)) return;
        self.lock.server.input.seat.pointerNotifyAxis(time_msec, orientation, delta, discrete, source, .identical);
    }

    fn handleNewSurface(listener: *wl.Listener(*wlr.SessionLockSurfaceV1), lock_surface: *wlr.SessionLockSurfaceV1) void {
        const self: *ClientLock = @fieldParentPtr("new_surface", listener);
        const output = Output.fromWlr(lock_surface.output) orelse return;
        const surface = gpa.create(Surface) catch return;
        const tree = output.lock_view.tree.createSceneSubsurfaceTree(lock_surface.surface) catch {
            gpa.destroy(surface);
            return;
        };
        surface.* = .{ .client = self, .lock_surface = lock_surface, .output = output, .tree = tree };
        lock_surface.events.destroy.add(&surface.destroy_listener);
        self.surfaces.append(surface);
        self.syncOutput(output);
        if (self.focused == null) self.focus(surface);
        self.lock.server.scheduleFrames();
    }

    fn handleUnlock(listener: *wl.Listener(void)) void {
        const self: *ClientLock = @fieldParentPtr("unlock", listener);
        const lock = self.lock;
        log.info("session unlocked by client", .{});
        self.detach();
        lock.release();
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const self: *ClientLock = @fieldParentPtr("destroy_listener", listener);
        const lock = self.lock;
        log.warn("lock client went away without unlocking; the session stays locked", .{});
        self.detach();
        lock.clientGone();
    }
};

const Surface = struct {
    client: *ClientLock,
    lock_surface: *wlr.SessionLockSurfaceV1,
    /// Null once the output is gone; wlroots destroys the surface next.
    output: ?*Output,
    tree: ?*wlr.SceneTree,
    width: i32 = 0,
    height: i32 = 0,
    link: wl.list.Link = undefined,
    destroy_listener: wl.Listener(void) = .init(handleDestroy),

    fn destroy(self: *Surface) void {
        const client = self.client;
        self.destroy_listener.link.remove();
        self.link.remove();
        // The wl_surface can outlive its role; stop drawing it now.
        if (self.tree) |tree| tree.node.destroy();
        if (client.focused == self) {
            client.focused = null;
            client.focus(client.surfaces.first());
        }
        client.lock.server.scheduleFrames();
        gpa.destroy(self);
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const self: *Surface = @fieldParentPtr("destroy_listener", listener);
        self.destroy();
    }
};
