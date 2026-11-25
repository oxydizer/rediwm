//! wp_commit_timer_v1 holds an entire wl_surface commit in wlroots' ordered
//! cache. The constraint belongs to the surface once set, even if the client
//! destroys the timer or binds another before committing.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wp = @import("wayland").server.wp;
const wlr = @import("wlroots");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const vrr = @import("output/vrr.zig");
const nowNs = @import("ipc/stats.zig").nowNs;
const gpa = @import("main.zig").gpa;
const Manager = @This();

extern fn rediwm_surface_frame_pacing_output(*wlr.Surface) ?*wlr.Output;

server: *Server,
global: *wl.Global,
alarm: *wl.EventSource,
armed: ?u64 = null,
surfaces: std.AutoHashMapUnmanaged(*wlr.Surface, *Track) = .empty,
waiting: wl.list.Head(Track, .link) = undefined,

const Hold = struct { seq: u32, target: u64 };
const Track = struct {
    manager: *Manager,
    surface: ?*wlr.Surface,
    resource: ?*wp.CommitTimerV1 = null,
    pending: ?u64 = null,
    holds: std.Deque(Hold) = .empty,
    link: wl.list.Link = undefined, // in waiting only while holds is nonempty
    frame_requested: bool = false,
    has_timed_descendant: bool = false,
    /// Members of a synchronized transaction must release together, even
    /// when a newly mapped child has no presentation output of its own yet.
    exact_only: bool = false,
    commit: wl.Listener(void) = .init(clientCommit),
    destroy: wl.Listener(*wlr.Surface) = .init(surfaceDestroyed),
};

pub fn create(server: *Server) !*Manager {
    const self = try gpa.create(Manager);
    errdefer gpa.destroy(self);
    const alarm = try server.wl_server.getEventLoop().addTimer(*Manager, onAlarm, self);
    errdefer alarm.remove();
    self.* = .{
        .server = server,
        .alarm = alarm,
        .global = try wl.Global.create(server.wl_server, wp.CommitTimingManagerV1, 1, *Manager, self, bind),
    };
    self.waiting.init();
    return self;
}

pub fn destroy(self: *Manager) void {
    // All client resources and surfaces are destroyed first.
    std.debug.assert(self.surfaces.count() == 0);
    self.surfaces.deinit(gpa);
    self.global.destroy();
    self.alarm.remove();
    gpa.destroy(self);
}

fn bind(client: *wl.Client, self: *Manager, version: u32, id: u32) void {
    const resource = wp.CommitTimingManagerV1.create(client, version, id) catch return client.postNoMemory();
    resource.setHandler(*Manager, managerRequest, null, self);
}

fn track(self: *Manager, surface: *wlr.Surface) !*Track {
    if (self.surfaces.get(surface)) |existing| return existing;
    const state = try gpa.create(Track);
    errdefer gpa.destroy(state);
    try self.surfaces.put(gpa, surface, state);
    state.* = .{ .manager = self, .surface = surface };
    surface.events.client_commit.add(&state.commit);
    surface.events.destroy.add(&state.destroy);
    return state;
}

fn managerRequest(resource: *wp.CommitTimingManagerV1, req: wp.CommitTimingManagerV1.Request, self: *Manager) void {
    switch (req) {
        .destroy => resource.destroy(),
        .get_timer => |args| {
            const client = resource.getClient();
            const state = self.track(wlr.Surface.fromWlSurface(args.surface)) catch return client.postNoMemory();
            if (state.resource != null) return resource.postError(.commit_timer_exists, "surface already has a commit timer");
            const timer = wp.CommitTimerV1.create(client, resource.getVersion(), args.id) catch return client.postNoMemory();
            state.resource = timer;
            timer.setHandler(*Track, timerRequest, timerDestroyed, state);
        },
    }
}

fn timerRequest(timer: *wp.CommitTimerV1, req: wp.CommitTimerV1.Request, state: *Track) void {
    switch (req) {
        .destroy => timer.destroy(),
        .set_timestamp => |ts| {
            if (state.surface == null) return timer.postError(.surface_destroyed, "commit timer surface has been destroyed");
            if (ts.tv_nsec >= std.time.ns_per_s) return timer.postError(.invalid_timestamp, "nanoseconds out of range");
            if (state.pending != null) return timer.postError(.timestamp_exists, "timestamp already set for the next commit");
            const seconds = (@as(u64, ts.tv_sec_hi) << 32) | ts.tv_sec_lo;
            state.pending = seconds *| std.time.ns_per_s +| ts.tv_nsec;
        },
    }
}

fn timerDestroyed(_: *wp.CommitTimerV1, state: *Track) void {
    state.resource = null;
    if (state.surface == null) gpa.destroy(state);
}

fn surfaceDestroyed(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
    const state: *Track = @fieldParentPtr("destroy", listener);
    const self = state.manager;
    _ = self.surfaces.remove(surface);
    state.commit.link.remove();
    state.destroy.link.remove();
    // wlroots drops cached commits after the destroy signal. Applying them here
    // would deliver commits to a surface whose role has already gone away.
    if (state.holds.front() != null) state.link.remove();
    state.holds.deinit(gpa);
    state.surface = null;
    if (state.resource == null) gpa.destroy(state);
    self.rearm();
}

/// The highest ancestor whose commit applies this synchronized subtree.
fn syncRoot(surface: *wlr.Surface) *wlr.Surface {
    var root = surface;
    var current = surface;
    while (wlr.Subsurface.tryFromWlrSurface(current)) |sub| {
        current = sub.parent;
        if (sub.synchronized) root = current;
    }
    return root;
}

fn syncAncestor(surface: *wlr.Surface, ancestor: *wlr.Surface) bool {
    const root = syncRoot(surface);
    var current = surface;
    while (current != root) {
        current = wlr.Subsurface.tryFromWlrSurface(current).?.parent;
        if (current == ancestor) return true;
    }
    return false;
}

fn clientCommit(listener: *wl.Listener(void)) void {
    const state: *Track = @fieldParentPtr("commit", listener);
    const self = state.manager;
    const surface = state.surface.?;
    var target = state.pending orelse 0;
    var inherited = false;
    state.pending = null;
    // Keep the parent's buffer and synchronized children atomic. Resolve the
    // relationship at parent commit time: desync or destroying the child
    // before that request must not leave a deadline on the parent.
    if (state.has_timed_descendant) {
        var it = self.waiting.iterator(.forward);
        while (it.next()) |child| {
            if (syncAncestor(child.surface.?, surface)) {
                target = @max(target, child.holds.back().?.target);
                inherited = true;
            }
        }
    }
    const previous = if (state.holds.back()) |last| last.target else 0;
    const latest = @max(previous, target);
    if (latest == 0 or latest <= nowNs()) return;
    // A later commit can become synchronized while an older one is held.
    const root = syncRoot(surface);
    if (inherited or root != surface) state.exact_only = true;
    var current = surface;
    while (current != root) {
        current = wlr.Subsurface.tryFromWlrSurface(current).?.parent;
        const parent = self.track(current) catch return surface.resource.getClient().postNoMemory();
        parent.has_timed_descendant = true;
    }
    if (target <= previous) return; // wlroots already queues this commit behind it
    const first = state.holds.front() == null;
    state.holds.pushBack(gpa, .{ .seq = surface.pending.seq, .target = target }) catch return surface.resource.getClient().postNoMemory();
    const seq = surface.lockPending();
    std.debug.assert(seq == surface.pending.seq);
    if (first) {
        self.waiting.append(state);
        self.rearm();
    }
}

/// Unlocking changes the scene for all outputs. Use early preparation only
/// when the surface has one possible scanout, with a fixed, synchronous flip.
fn fixedOutput(self: *Manager) ?*Output {
    var single: ?*Output = null;
    var outputs = self.server.outputs.iterator(.forward);
    while (outputs.next()) |out| {
        if (!out.wlr_output.enabled or out.power_off) continue;
        if (single != null) return null;
        single = out;
    }
    const out = single orelse return null;
    if (out.commit_refresh.period == 0 or !out.wlr_output.isDrm() or out.tearing.active or out.tearingAllowed() or
        vrr.active(out) or (vrr.supported(out) and vrr.wanted(out))) return null;
    return out;
}

fn wakeAt(state: *Track, output: ?*Output, now: u64, target: u64) u64 {
    const out = output orelse return target;
    if (state.exact_only) return target;
    if (rediwm_surface_frame_pacing_output(state.surface.?) != out.wlr_output) return target;
    return out.commit_refresh.wakeAt(now, target);
}

fn rearm(self: *Manager) void {
    var earliest: ?u64 = null;
    if (self.waiting.first() != null) {
        const now = nowNs();
        const output = self.fixedOutput();
        var it = self.waiting.iterator(.forward);
        while (it.next()) |state| {
            var wake = state.holds.front().?.target;
            if (!state.frame_requested and now < wake) {
                const prepare = wakeAt(state, output, now, wake);
                if (prepare <= now) {
                    state.frame_requested = true;
                    output.?.wlr_output.scheduleFrame();
                } else wake = prepare;
            }
            earliest = @min(earliest orelse wake, wake);
        }
    }
    if (earliest == self.armed) return;
    self.armed = earliest;
    const ms = if (earliest) |deadline| std.math.divCeil(u64, deadline -| nowNs(), std.time.ns_per_ms) catch unreachable else 0;
    self.alarm.timerUpdate(if (earliest == null) 0 else @intCast(std.math.clamp(ms, 1, std.math.maxInt(c_int)))) catch {
        // libwayland can fail to grow the timer heap. Fail the affected
        // requests rather than applying them early or leaving them held.
        self.armed = null;
        var it = self.waiting.iterator(.forward);
        while (it.next()) |state| state.surface.?.resource.getClient().postNoMemory();
    };
}

fn release(self: *Manager, now: u64, output: ?*Output) void {
    var it = self.waiting.iterator(.forward);
    while (it.next()) |state| {
        while (state.holds.front()) |held| {
            if (wakeAt(state, output, now, held.target) > now) break;
            if (held.target > now) {
                const out = output.?;
                out.timed_vsync_until = @max(out.timed_vsync_until, held.target);
            }
            _ = state.holds.popFront();
            state.frame_requested = false;
            if (state.holds.front() == null) {
                state.link.remove();
                state.exact_only = false;
            }
            state.surface.?.unlockCached(held.seq);
        }
    }
    self.rearm();
}

pub fn beforeFrame(self: *Manager, output: *Output, now: u64) void {
    if (self.waiting.first() != null and self.fixedOutput() == output) self.release(now, output);
}

fn onAlarm(self: *Manager) c_int {
    self.armed = null;
    self.release(nowNs(), null);
    return 0;
}
