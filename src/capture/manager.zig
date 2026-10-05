//! Standard output and native-window capture, policy, and session tracking.
//! See docs/screen-sharing.md for source semantics and qualification status.
//!
//! ext-image-copy-capture sessions track their output or native xdg toplevel.
//! stopForOutput/stopForWindow end affected sessions on source loss, while
//! listSessions backs IPC inspection and the taskbar's capture indicator.
//! WindowCaptureSource renders the selected content subtree into an owned
//! swapchain; the earlier wlroots scene-node helper leaked occluding pixels
//! in the two-window fixture (see window_source.zig).
//!
//! wlr-screencopy-v1 has frames rather than sessions. guardScreencopy refuses
//! copies during authentication or lock, and each copy keeps the indicator
//! lit for screencopy_hold_ms. Stop sharing disconnects capture clients.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("../Server.zig");
const protocol = @import("../ipc/protocol.zig");
const gpa = @import("../main.zig").gpa;
const WindowCaptureSource = @import("window_source.zig").WindowCaptureSource;

const log = std.log.scoped(.capture);

pub const failure_stop_all = "stop_all";
pub const failure_output_idle = "output_idle";
pub const failure_output_destroyed = "output_destroyed";
pub const failure_window_closed = "window_closed";

/// How long one screencopy frame keeps the capture indicator lit. A recorder
/// copies every frame; a one-shot grim still shows a brief flash.
const screencopy_hold_ms = 1500;

pub const Manager = struct {
    server: *Server,
    copy_capture: *wlr.ExtImageCopyCaptureManagerV1,
    output_source: *wlr.ExtOutputImageCaptureSourceManagerV1,
    toplevel_list: *wlr.ExtForeignToplevelListV1,
    toplevel_source: *wlr.ExtForeignToplevelImageCaptureSourceManagerV1,
    screencopy: *wlr.ScreencopyManagerV1,
    /// Until when the last screencopy copy keeps the indicator lit.
    screencopy_until_ms: i64 = 0,
    /// One-shot: repaints the indicator once the hold expires.
    screencopy_timer: ?*wl.EventSource = null,
    last_failure: ?[]const u8 = null,

    new_session: wl.Listener(*wlr.ExtImageCopyCaptureSessionV1) = .init(handleNewSession),
    new_toplevel_request: wl.Listener(*wlr.ExtForeignToplevelImageCaptureSourceManagerV1.Request) = .init(handleNewToplevelRequest),
    sessions: wl.list.Head(Session, .link) = undefined,
    window_sources: wl.list.Head(WindowCaptureSource, .link) = undefined,

    pub fn create(server: *Server) !*Manager {
        const mgr = try gpa.create(Manager);
        errdefer gpa.destroy(mgr);

        const copy_capture = try wlr.ExtImageCopyCaptureManagerV1.create(server.wl_server, 1);
        const output_source = try wlr.ExtOutputImageCaptureSourceManagerV1.create(server.wl_server, 1);
        const toplevel_list = try wlr.ExtForeignToplevelListV1.create(server.wl_server, 1);
        const toplevel_source = try wlr.ExtForeignToplevelImageCaptureSourceManagerV1.create(server.wl_server, 1);
        const screencopy = try wlr.ScreencopyManagerV1.create(server.wl_server);

        mgr.* = .{
            .server = server,
            .copy_capture = copy_capture,
            .output_source = output_source,
            .toplevel_list = toplevel_list,
            .toplevel_source = toplevel_source,
            .screencopy = screencopy,
        };
        mgr.screencopy_timer = server.wl_server.getEventLoop().addTimer(*Manager, screencopyExpired, mgr) catch null;
        mgr.sessions.init();
        mgr.window_sources.init();
        copy_capture.events.new_session.add(&mgr.new_session);
        toplevel_source.events.new_request.add(&mgr.new_toplevel_request);
        return mgr;
    }

    /// Call after `wl_server.destroyClients()` so every session's destroy
    /// signal has already fired and freed its `Session` tracker; the two
    /// wlr managers clean themselves up separately when `wl_server` itself
    /// is destroyed.
    pub fn deinit(mgr: *Manager) void {
        mgr.new_session.link.remove();
        mgr.new_toplevel_request.link.remove();
        if (mgr.screencopy_timer) |timer| timer.remove();
        gpa.destroy(mgr);
    }

    fn handleNewSession(listener: *wl.Listener(*wlr.ExtImageCopyCaptureSessionV1), session: *wlr.ExtImageCopyCaptureSessionV1) void {
        const mgr: *Manager = @fieldParentPtr("new_session", listener);
        if (mgr.server.polkit_dialog != null or mgr.server.locker != null) {
            // Reject before allocation, so OOM cannot bypass authentication.
            // Wayland disconnects the failed client without dispatching a
            // queued frame request; no wlroots object is freed on its own stack.
            session.resource.getClient().postImplementationError("capture unavailable during authentication or lock");
            return;
        }
        const tracked = Session.create(mgr, session) catch {
            session.resource.getClient().postNoMemory();
            return;
        };
        mgr.sessions.prepend(tracked);
        log.info("capture session started (active={d})", .{mgr.sessions.length()});
        mgr.server.scheduleFrames();
    }

    /// Turns one client's request for a foreign-toplevel's capture source
    /// into a `WindowCaptureSource` over that window's `content_tree`
    /// (never `frame_tree`/`shadow_tree` — docs/screen-sharing.md's
    /// "Separate monitor and window semantics" excludes server decorations,
    /// shadows, and backdrop glass, which can sample unrelated windows). A
    /// fresh source is created per request rather than shared/deduped like
    /// the output manager's one-source-per-output: the protocol event is
    /// itself named `new_request`, and nothing here needs cross-request
    /// sharing. If the handle no longer has a live toplevel (closed
    /// mid-race), the request is simply never accepted —
    /// `ext_image_capture_source_v1_from_resource` already documents that
    /// an un-accepted resource stays inert; there is no separate
    /// protocol-level rejection to send.
    fn handleNewToplevelRequest(
        listener: *wl.Listener(*wlr.ExtForeignToplevelImageCaptureSourceManagerV1.Request),
        request: *wlr.ExtForeignToplevelImageCaptureSourceManagerV1.Request,
    ) void {
        const mgr: *Manager = @fieldParentPtr("new_toplevel_request", listener);
        const toplevel = mgr.server.findToplevelByForeignHandle(request.toplevel_handle) orelse {
            log.warn("new_toplevel_request: handle has no live toplevel, leaving source unaccepted", .{});
            return;
        };
        const tracked = WindowCaptureSource.create(mgr, toplevel) catch {
            log.warn("new_toplevel_request: could not create window-source for window {d}", .{toplevel.id});
            return;
        };
        mgr.window_sources.prepend(tracked);
        if (!request.accept(&tracked.base)) {
            log.warn("new_toplevel_request: accept failed for window {d} (client likely gone)", .{toplevel.id});
        }
    }

    /// The public wlroots 0.20 API exposes no general per-session or
    /// per-source stop call (see docs/screen-sharing.md's "Capture
    /// visibility, stop, and locking" section), so this is the documented
    /// bounded fallback: disconnect every client holding a capture session.
    /// That ends every session on that connection at once, including any
    /// other sessions the same client happens to hold — a client is only
    /// ever destroyed once, since doing it twice would use a freed pointer.
    pub fn stopAll(mgr: *Manager) void {
        // Destroy listeners remove every session belonging to that client.
        // No allocation: authentication must also stop capture under OOM.
        var count: usize = 0;
        while (mgr.sessions.first()) |tracked| {
            tracked.resource.getClient().destroy();
            count += 1;
        }
        // A recorder almost always has its next screencopy frame pending.
        while (mgr.screencopy.frames.first()) |frame| {
            frame.resource.getClient().destroy();
            count += 1;
        }
        mgr.screencopy_until_ms = 0;
        mgr.last_failure = failure_stop_all;
        log.info("stopAll: disconnected {d} client(s) holding capture sessions", .{count});
        mgr.server.scheduleFrames();
    }

    /// Bounded fallback scoped to one output, for policy that must end
    /// monitor streams without a general stop/lock event (docs/screen-sharing.md's
    /// "Capture visibility, stop, and locking": idle blanking, and pre-empting
    /// output teardown). `wlr_ext_output_image_capture_source_manager_v1`
    /// gives every session on an output the *same* shared source (see the
    /// `Session.output` doc comment below), and the public API still has no
    /// way to stop a single session, so this is `stopAll` with the same
    /// caveat narrowed to one output's sessions: a client capturing this
    /// output and some other one loses both, since only whole clients can be
    /// disconnected.
    pub fn stopForOutput(mgr: *Manager, target: *wlr.Output, reason: []const u8) void {
        var clients: std.ArrayList(*wl.Client) = .empty;
        defer clients.deinit(gpa);

        var it = mgr.sessions.iterator(.forward);
        while (it.next()) |tracked| {
            const output = tracked.output orelse continue;
            if (output != target) continue;
            const client = tracked.resource.getClient();
            for (clients.items) |seen| {
                if (seen == client) break;
            } else {
                clients.append(gpa, client) catch continue;
            }
        }
        if (clients.items.len == 0) return;

        for (clients.items) |client| client.destroy();
        mgr.last_failure = reason;
        log.info("stopForOutput: disconnected {d} client(s) capturing {s}", .{ clients.items.len, target.name });
        mgr.server.scheduleFrames();
    }

    /// `stopForOutput`'s window-source counterpart: the failure contract's
    /// "minimize: End the selected source's session" row, called from
    /// `Toplevel.minimize`. A real *close* does not need this — destroying
    /// `content_tree` fires `WindowCaptureSource`'s own destroy listener,
    /// which ends any live session gracefully (a real `stopped` event) via
    /// that source's `finish()` call; minimizing only hides the frame
    /// without destroying anything, so nothing else would ever notice.
    /// Unlike output sources, each window session has its own
    /// independently created source (see `handleNewToplevelRequest`), but
    /// the bounded fallback is identical: disconnect every client holding
    /// a session on this window, since wlroots 0.20 still has no
    /// per-session stop.
    pub fn stopForWindow(mgr: *Manager, window_id: u64, reason: []const u8) void {
        var clients: std.ArrayList(*wl.Client) = .empty;
        defer clients.deinit(gpa);

        var it = mgr.sessions.iterator(.forward);
        while (it.next()) |tracked| {
            const wid = tracked.window_id orelse continue;
            if (wid != window_id) continue;
            const client = tracked.resource.getClient();
            for (clients.items) |seen| {
                if (seen == client) break;
            } else {
                clients.append(gpa, client) catch continue;
            }
        }
        if (clients.items.len == 0) return;

        for (clients.items) |client| client.destroy();
        mgr.last_failure = reason;
        log.info("stopForWindow: disconnected {d} client(s) capturing window {d}", .{ clients.items.len, window_id });
        mgr.server.scheduleFrames();
    }

    /// Capture sessions plus one for recent screencopy use: the taskbar
    /// indicator's count.
    pub fn activeCount(mgr: *const Manager) usize {
        const copying = !mgr.screencopy.frames.empty() or monotonicMs() < mgr.screencopy_until_ms;
        return mgr.sessions.length() + @intFromBool(copying);
    }

    /// Runs before an output commit whose buffer screencopy would read.
    /// wlroots copies in its own commit listener, so refusing means
    /// disconnecting the client first, as `handleNewSession` does.
    pub fn guardScreencopy(mgr: *Manager, output: *wlr.Output) void {
        const refuse = mgr.server.polkit_dialog != null or mgr.server.locker != null;
        var copying = false;
        var it = mgr.screencopy.frames.safeIterator(.forward);
        while (it.next()) |frame| {
            if (frame.output != output or !copyRequested(frame)) continue;
            if (refuse) {
                // Destroying the client frees its other frames too.
                frame.resource.getClient().destroy();
                mgr.last_failure = failure_stop_all;
                return mgr.guardScreencopy(output);
            }
            copying = true;
        }
        if (!copying) return;
        const now = monotonicMs();
        if (now >= mgr.screencopy_until_ms) mgr.server.scheduleFrames();
        mgr.screencopy_until_ms = now + screencopy_hold_ms;
        if (mgr.screencopy_timer) |timer| timer.timerUpdate(screencopy_hold_ms + 50) catch {};
    }

    fn screencopyExpired(mgr: *Manager) c_int {
        mgr.server.scheduleFrames();
        return 0;
    }

    /// Diagnostics for the `get_capture_state` IPC query: session count and,
    /// when known, each session's target output name or window id — never
    /// pixels, titles, or other sensitive content (docs/screen-sharing.md
    /// section 5).
    pub fn listSessions(mgr: *Manager, allocator: std.mem.Allocator) ![]protocol.CaptureSessionData {
        var list: std.ArrayList(protocol.CaptureSessionData) = .empty;
        errdefer list.deinit(allocator);

        var it = mgr.sessions.iterator(.forward);
        while (it.next()) |tracked| {
            try list.append(allocator, .{
                .output = if (tracked.output) |o| std.mem.span(o.name) else null,
                .window_id = tracked.window_id,
            });
        }
        return list.toOwnedSlice(allocator);
    }
};

/// Real time even while IPC pins the animation clock: the hold is a timer.
fn monotonicMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// wlroots sets `buffer` on the copy request; zig-wlroots declares it non-null.
fn copyRequested(frame: *wlr.ScreencopyFrameV1) bool {
    const buffer: *const ?*wlr.Buffer = @ptrCast(&frame.buffer);
    return buffer.* != null;
}

/// Resolves a session's source back to the window it captures, if any
/// (`Session.create` calls this once, the same way it calls `toOutput()`).
fn findWindowSource(manager: *Manager, source: *wlr.ExtImageCaptureSourceV1) ?*WindowCaptureSource {
    var it = manager.window_sources.iterator(.forward);
    while (it.next()) |ws| {
        if (&ws.base == source) return ws;
    }
    return null;
}

const Session = struct {
    manager: *Manager,
    resource: *wl.Resource,
    /// Resolved once at session creation via `toOutput()`. A
    /// `wlr_ext_image_capture_source_v1` from the output-source manager is
    /// one persistent object per output, shared by every session any client
    /// opens on it (wlr_ext_image_capture_source_v1.h: "one screen capture
    /// source per output"), so this cannot change or go stale out from under
    /// a still-live session — the session itself always ends first, whether
    /// via wlroots' own source-destroy cascade or `Manager.stopForOutput`.
    /// `null` for a window session (see `window_id` below) — a scene-node
    /// source has no `wlr.Output` to resolve.
    output: ?*wlr.Output,
    /// Resolved once at session creation the same way `output` is, by
    /// matching this session's source against `Manager.window_sources`.
    /// `null` for a monitor session.
    window_id: ?u64,
    destroy: wl.Listener(void) = .init(handleDestroy),
    link: wl.list.Link = undefined,

    fn create(manager: *Manager, session: *wlr.ExtImageCopyCaptureSessionV1) !*Session {
        const tracked = try gpa.create(Session);
        tracked.* = .{
            .manager = manager,
            .resource = session.resource,
            .output = session.source.toOutput(),
            .window_id = if (findWindowSource(manager, session.source)) |ws| ws.window_id else null,
        };
        session.events.destroy.add(&tracked.destroy);
        return tracked;
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const tracked: *Session = @fieldParentPtr("destroy", listener);
        const manager = tracked.manager;
        tracked.destroy.link.remove();
        tracked.link.remove();
        gpa.destroy(tracked);
        log.info("capture session ended (active={d})", .{manager.sessions.length()});
        manager.server.scheduleFrames();
    }
};
