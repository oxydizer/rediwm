//! wp_fifo_v1: a content update can wait until the surface's previous update
//! has been on screen for one refresh (Vulkan FIFO in Mesa, SDL3 vsync).
//! Plan and decisions: docs/plans/fifo.md.
//!
//! A held update stays in the surface's cached-state queue
//! (`wlr_surface_lock_pending`), so wlroots keeps every later commit behind
//! it in order. A barrier is cleared by a *latch* of the output that paces
//! the surface (`Output.latch_seq`: a non-tearing buffer commit, or the
//! `vblank_timer` refresh after a skipped commit), never by frame callbacks,
//! which late render sends before it renders. Two fallbacks keep clients
//! going: a hidden surface (no pacing output: covered, minimized, another
//! workspace, outputs off) is released at 20 Hz, and a shown one whose
//! output has not latched within two refreshes (torn flips, failed commits)
//! is released late. One deadline timer serves both, armed only while
//! something is held.
//!
//! Releasing applies client state synchronously and can create scene nodes,
//! and latches happen inside the output frame; so a latch only clears the
//! barrier (bookkeeping) and the unlocks run from an idle callback.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wp = @import("wayland").server.wp;
const wlr = @import("wlroots");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const stats = @import("ipc/stats.zig");
const gpa = @import("main.zig").gpa;

const Fifo = @This();

extern fn rediwm_surface_frame_pacing_output(surface: *wlr.Surface) ?*wlr.Output;

/// D1: how often a hidden surface's barrier clears.
pub const hidden_period_ns: u64 = 50 * std.time.ns_per_ms;
/// Refreshes a shown surface waits for its output's latch before it is
/// released anyway (forward progress).
pub const late_refreshes: u64 = 2;

/// The double-buffered requests (`wlr_surface_synced` state).
const State = extern struct {
    set_barrier: bool = false,
    wait_barrier: bool = false,
};

fn moveState(dst: *anyopaque, src: *anyopaque) callconv(.c) void {
    const to: *State = @ptrCast(@alignCast(dst));
    const from: *State = @ptrCast(@alignCast(src));
    to.* = from.*;
    from.* = .{};
}

const synced_impl: wlr.Surface.Synced.Impl = .{
    .state_size = @sizeOf(State),
    .init_state = null,
    .finish_state = null,
    .move_state = moveState,
};

/// Barrier bookkeeping of one surface, in wl_surface state sequence numbers
/// (wlroots numbers every commit; cached and applied states keep theirs).
/// No wlroots calls, so the rules are unit tested (`fifo_tests.zig`).
pub const Barriers = struct {
    pub const Held = struct {
        /// The held state (`wlr_surface_lock_pending`).
        seq: u32,
        /// The set_barrier commit whose condition it waits for.
        waits_on: u32,
    };

    /// The latest committed set_barrier, applied or still queued behind a
    /// lock (explicit sync, a held update).
    last_set: ?u32 = null,
    /// The latest applied set_barrier, and whether its condition holds.
    applied: ?u32 = null,
    armed: bool = false,
    /// The latest set_barrier whose condition has cleared.
    cleared: ?u32 = null,
    /// Held updates, oldest first.
    held: std.ArrayList(Held) = .empty,

    pub fn deinit(self: *Barriers) void {
        self.held.deinit(gpa);
    }

    /// `a` was committed after `b` (wrapping).
    fn after(a: u32, b: u32) bool {
        return @as(i32, @bitCast(a -% b)) > 0;
    }

    /// Whether the condition set by commit `seq` has cleared.
    fn clearedFor(self: *const Barriers, seq: u32) bool {
        const cleared = self.cleared orelse return false;
        return !after(seq, cleared);
    }

    /// A client commit numbered `seq`. Returns the commit it must wait for,
    /// or null when it is ready. A synchronized subsurface's wait is ignored
    /// (the spec says so); its set_barrier still counts.
    pub fn committed(self: *Barriers, seq: u32, set: bool, wait: bool, exempt: bool) ?u32 {
        const before = self.last_set;
        if (set) self.last_set = seq;
        if (!wait or exempt) return null;
        // An earlier set_barrier that has not even been applied (a lock
        // ahead of it) must be waited for too, not just the applied one.
        const target = before orelse return null;
        return if (self.clearedFor(target)) null else target;
    }

    /// State `seq` was applied.
    pub fn appliedState(self: *Barriers, seq: u32, set: bool) void {
        if (!set) return;
        self.applied = seq;
        self.armed = true;
    }

    /// A latch (or a fallback) clears the applied condition. Returns whether
    /// it cleared one.
    pub fn clear(self: *Barriers) bool {
        if (!self.armed) return false;
        self.armed = false;
        self.cleared = self.applied;
        return true;
    }

    /// Whether the oldest held update waits for the applied condition (so
    /// clearing it releases something).
    pub fn waitingOnArmed(self: *const Barriers) bool {
        if (!self.armed or self.held.items.len == 0) return false;
        return !after(self.held.items[0].waits_on, self.applied.?);
    }

    /// The next held update that may be released, removed from the queue.
    pub fn nextReleasable(self: *Barriers) ?Held {
        if (self.held.items.len == 0) return null;
        const first = self.held.items[0];
        if (!self.clearedFor(first.waits_on)) return null;
        _ = self.held.orderedRemove(0);
        return first;
    }
};

manager: *Manager,
resource: *wp.FifoV1,
surface: ?*wlr.Surface,
synced: wlr.Surface.Synced = undefined,
pending: State = .{},
current: State = .{},
barriers: Barriers = .{},
/// The applied barrier: when, and its pacing output's latch generation then.
armed_ns: u64 = 0,
armed_output: ?*wlr.Output = null,
armed_latch: u64 = 0,
/// A latch cleared the barrier; the idle callback releases what waited.
release_pending: bool = false,
link: wl.list.Link = undefined,
client_commit: wl.Listener(void) = .init(handleClientCommit),
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
surface_destroy: wl.Listener(*wlr.Surface) = .init(handleSurfaceDestroy),

pub const Manager = struct {
    server: *Server,
    global: *wl.Global,
    fifos: wl.list.Head(Fifo, .link) = undefined,
    timer: *wl.EventSource,
    /// When `timer` fires, 0 while disarmed.
    deadline_ns: u64 = 0,
    release_idle: ?*wl.EventSource = null,

    pub fn create(server: *Server) !*Manager {
        const self = try gpa.create(Manager);
        errdefer gpa.destroy(self);
        const timer = try server.wl_server.getEventLoop().addTimer(*Manager, handleTimer, self);
        errdefer timer.remove();
        self.* = .{
            .server = server,
            .timer = timer,
            .global = try wl.Global.create(server.wl_server, wp.FifoManagerV1, 1, *Manager, self, bind),
        };
        self.fifos.init();
        return self;
    }

    /// Clients are gone by now (teardown destroys them first); any fifo left
    /// is destroyed like a client would.
    pub fn destroy(self: *Manager) void {
        self.global.destroy();
        while (self.fifos.first()) |fifo| fifo.resource.destroy();
        if (self.release_idle) |idle| idle.remove();
        self.timer.remove();
        gpa.destroy(self);
    }

    /// `output` latched (`Output.latch_seq` is now `latch`): clear the
    /// barriers of the surfaces it paces that were applied before it.
    pub fn latched(self: *Manager, output: *wlr.Output, latch: u64) void {
        var any = false;
        var it = self.fifos.iterator(.forward);
        while (it.next()) |fifo| {
            const surface = fifo.surface orelse continue;
            if (!fifo.barriers.armed) continue;
            if (rediwm_surface_frame_pacing_output(surface) != output) continue;
            // Applied at this generation on this output: not latched yet.
            if (fifo.armed_output == output and fifo.armed_latch == latch) continue;
            const releases = fifo.barriers.waitingOnArmed();
            _ = fifo.barriers.clear();
            stats.global_stats.fifo.latched +%= 1;
            if (releases) {
                fifo.release_pending = true;
                any = true;
            }
        }
        if (any and self.release_idle == null) {
            self.release_idle = self.server.wl_server.getEventLoop().addIdle(*Manager, releaseIdle, self) catch null;
            // Without an idle the deadline timer releases them.
            if (self.release_idle == null) self.rearm();
        }
    }

    fn releaseIdle(self: *Manager) void {
        self.release_idle = null;
        var it = self.fifos.iterator(.forward);
        while (it.next()) |fifo| {
            if (!fifo.release_pending) continue;
            fifo.release_pending = false;
            fifo.release();
        }
        self.rearm();
    }

    /// When the oldest held update of `fifo` is released anyway, if it waits
    /// for an applied barrier.
    fn deadlineOf(fifo: *Fifo) ?u64 {
        const surface = fifo.surface orelse return null;
        if (!fifo.barriers.waitingOnArmed()) return null;
        const output = rediwm_surface_frame_pacing_output(surface) orelse
            return fifo.armed_ns + hidden_period_ns;
        return fifo.armed_ns + late_refreshes * refreshPeriodNs(output) + std.time.ns_per_ms;
    }

    /// Arms the timer for the earliest deadline, or disarms it.
    fn rearm(self: *Manager) void {
        var earliest: u64 = 0;
        var it = self.fifos.iterator(.forward);
        while (it.next()) |fifo| {
            const deadline = deadlineOf(fifo) orelse continue;
            if (earliest == 0 or deadline < earliest) earliest = deadline;
        }
        if (earliest == self.deadline_ns) return;
        self.deadline_ns = earliest;
        if (earliest == 0) {
            self.timer.timerUpdate(0) catch {};
            return;
        }
        const now = stats.nowNs();
        const delay_ms: c_int = if (earliest <= now) 1 else @intCast(@min(
            std.math.divCeil(u64, earliest - now, std.time.ns_per_ms) catch 1,
            std.math.maxInt(c_int),
        ));
        self.timer.timerUpdate(delay_ms) catch {
            self.deadline_ns = 0;
        };
    }

    fn handleTimer(self: *Manager) c_int {
        self.deadline_ns = 0;
        const now = stats.nowNs();
        var it = self.fifos.iterator(.forward);
        while (it.next()) |fifo| {
            const deadline = deadlineOf(fifo) orelse continue;
            if (deadline > now) continue;
            const hidden = rediwm_surface_frame_pacing_output(fifo.surface.?) == null;
            _ = fifo.barriers.clear();
            if (hidden) stats.global_stats.fifo.hidden +%= 1 else stats.global_stats.fifo.late +%= 1;
            fifo.release_pending = false;
            fifo.release();
        }
        self.rearm();
        return 0;
    }

    fn bind(client: *wl.Client, self: *Manager, version: u32, id: u32) void {
        const resource = wp.FifoManagerV1.create(client, version, id) catch {
            client.postNoMemory();
            return;
        };
        resource.setHandler(*Manager, handleRequest, null, self);
    }

    fn handleRequest(manager: *wp.FifoManagerV1, request: wp.FifoManagerV1.Request, self: *Manager) void {
        switch (request) {
            .destroy => manager.destroy(),
            .get_fifo => |args| {
                const surface = wlr.Surface.fromWlSurface(args.surface);
                var it = self.fifos.iterator(.forward);
                while (it.next()) |existing| {
                    if (existing.surface == surface) {
                        manager.postError(.already_exists, "the surface already has a wp_fifo_v1");
                        return;
                    }
                }
                self.createFifo(manager, args.id, surface) catch manager.getClient().postNoMemory();
            },
        }
    }

    fn createFifo(self: *Manager, manager: *wp.FifoManagerV1, id: u32, surface: *wlr.Surface) !void {
        const fifo = try gpa.create(Fifo);
        errdefer gpa.destroy(fifo);
        const resource = try wp.FifoV1.create(manager.getClient(), manager.getVersion(), id);
        errdefer resource.destroy();
        fifo.* = .{ .manager = self, .resource = resource, .surface = surface };
        try fifo.synced.init(surface, &synced_impl, &fifo.pending, &fifo.current);
        surface.events.client_commit.add(&fifo.client_commit);
        surface.events.commit.add(&fifo.commit);
        surface.events.destroy.add(&fifo.surface_destroy);
        self.fifos.append(fifo);
        resource.setHandler(*Fifo, handleFifoRequest, handleResourceDestroy, fifo);
    }
};

fn refreshPeriodNs(output: *wlr.Output) u64 {
    const mhz: u64 = if (output.refresh > 0) @intCast(output.refresh) else 60_000;
    return 1_000_000_000_000 / mhz;
}

/// A synchronized subsurface, directly or through a synchronized parent
/// (wlroots' subsurface_is_synchronized).
fn isSynchronized(surface: *wlr.Surface) bool {
    var current = surface;
    while (wlr.Subsurface.tryFromWlrSurface(current)) |sub| {
        if (sub.synchronized) return true;
        current = sub.parent;
    }
    return false;
}

fn handleFifoRequest(resource: *wp.FifoV1, request: wp.FifoV1.Request, fifo: *Fifo) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_barrier, .wait_barrier => {
            if (fifo.surface == null) {
                resource.postError(.surface_destroyed, "the wl_surface of this wp_fifo_v1 was destroyed");
                return;
            }
            if (request == .set_barrier) fifo.pending.set_barrier = true else fifo.pending.wait_barrier = true;
        },
    }
}

/// Before wlroots applies or caches the commit: hold it behind its barrier.
fn handleClientCommit(listener: *wl.Listener(void)) void {
    const fifo: *Fifo = @fieldParentPtr("client_commit", listener);
    const surface = fifo.surface.?;
    const seq = surface.pending.seq;
    const waits_on = fifo.barriers.committed(seq, fifo.pending.set_barrier, fifo.pending.wait_barrier, isSynchronized(surface)) orelse return;
    fifo.barriers.held.append(gpa, .{ .seq = seq, .waits_on = waits_on }) catch {
        // Unheld, the update shows a refresh early; nothing worse.
        surface.resource.getClient().postNoMemory();
        return;
    };
    const locked = surface.lockPending();
    std.debug.assert(locked == seq);
    stats.global_stats.fifo.held +%= 1;
    fifo.manager.rearm();
}

/// A state was applied: arm its barrier, and make sure a latch will come.
fn handleCommit(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
    const fifo: *Fifo = @fieldParentPtr("commit", listener);
    if (!fifo.current.set_barrier) return;
    fifo.barriers.appliedState(surface.current.seq, true);
    fifo.armed_ns = stats.nowNs();
    const output = rediwm_surface_frame_pacing_output(surface);
    fifo.armed_output = output;
    fifo.armed_latch = if (output) |o| latchOf(o) else 0;
    // An update that changed nothing builds no frame; this either finds
    // one coming or arms the skipped-commit vblank, which latches.
    if (output) |o| Output.frameCallbacksWanted(o);
    if (fifo.barriers.waitingOnArmed()) fifo.manager.rearm();
}

fn latchOf(output: *wlr.Output) u64 {
    const owner: *Output = @ptrCast(@alignCast(output.data orelse return 0));
    return owner.latch_seq;
}

/// Unlocks the held updates whose barrier has cleared, oldest first. An
/// unlock can apply several states (and so arm a new barrier) at once.
fn release(fifo: *Fifo) void {
    const surface = fifo.surface orelse return;
    while (fifo.barriers.nextReleasable()) |held| surface.unlockCached(held.seq);
}

/// Stops following the surface. wlroots frees cached states after the
/// destroy signal; unlocking them here would apply state to a surface whose
/// role is gone, so held updates are dropped.
fn detach(fifo: *Fifo) void {
    if (fifo.surface == null) return;
    fifo.client_commit.link.remove();
    fifo.commit.link.remove();
    fifo.surface_destroy.link.remove();
    fifo.synced.deinit();
    fifo.barriers.held.clearRetainingCapacity();
    fifo.barriers.armed = false;
    fifo.release_pending = false;
    fifo.surface = null;
}

fn handleSurfaceDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const fifo: *Fifo = @fieldParentPtr("surface_destroy", listener);
    detach(fifo);
    fifo.manager.rearm();
}

/// "Surface state changes previously made by this protocol are unaffected":
/// held updates go ahead now, in order.
fn handleResourceDestroy(_: *wp.FifoV1, fifo: *Fifo) void {
    if (fifo.surface) |surface| {
        while (fifo.barriers.held.items.len > 0) {
            const held = fifo.barriers.held.orderedRemove(0);
            surface.unlockCached(held.seq);
        }
    }
    detach(fifo);
    fifo.barriers.deinit();
    fifo.link.remove();
    const manager = fifo.manager;
    gpa.destroy(fifo);
    manager.rearm();
}

test {
    _ = @import("fifo_tests.zig");
}
