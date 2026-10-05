//! The greeter <-> login worker relay:
//! idle -> authenticating <-> prompting -> authenticated -> starting.
//! It answers the greeter and forwards to the worker; everything with a
//! process or a timer attached is returned to the daemon as an `Action`.
//! Any request out of order is a protocol violation (`drop_greeter`): the
//! greeter is replaced rather than guessed at.
const std = @import("std");
const dm_ipc = @import("dm_ipc");
const ws = @import("wayland_sessions");
const proto = @import("proto.zig");

pub const Phase = enum { idle, authenticating, prompting, authenticated, starting };

pub const Action = enum {
    none,
    /// Validate the login's user and start a worker for it.
    spawn_login,
    /// End the current login worker; nothing it says later is relayed.
    kill_worker,
    /// `session` is resolved: let the greeter exit, then start it.
    handoff,
    /// Close the greeter connection and replace the greeter.
    drop_greeter,
};

pub const AutologinDecision = enum {
    proceed,
    skip_marker_exists,
    skip_bad_user,
    skip_bad_session,
};

pub fn checkAutologin(
    io: std.Io,
    marker_path: []const u8,
    user: ?[]const u8,
    session_id: ?[]const u8,
    search_dirs: []const []const u8,
    range: ws.UidRange,
    user_validator: *const fn (user: []const u8, range: ws.UidRange) bool,
) AutologinDecision {
    const u = user orelse return .skip_bad_user;
    const s = session_id orelse return .skip_bad_session;
    if (std.Io.Dir.accessAbsolute(io, marker_path, .{})) |_| return .skip_marker_exists else |_| {}
    if (!user_validator(u, range)) return .skip_bad_user;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const resolved = ws.lookupSession(arena.allocator(), io, s, search_dirs) catch null;
    return if (resolved == null) .skip_bad_session else .proceed;
}

/// Longest PAM or error text passed on to the greeter.
const max_text = 1024;

pub const Relay = struct {
    arena: std.heap.ArenaAllocator,
    phase: Phase = .idle,
    greeter_fd: c_int = -1,
    worker_fd: c_int = -1,
    /// Set by a successful `start`, until `reset`.
    session: ?ws.Session = null,

    pub fn init(gpa: std.mem.Allocator) Relay {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Relay) void {
        self.arena.deinit();
    }

    /// Back to idle with no resolved session; fds are the daemon's to clear.
    pub fn reset(self: *Relay) void {
        self.phase = .idle;
        self.session = null;
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn handleGreeterRequest(self: *Relay, req: dm_ipc.Request, io: std.Io, search_dirs: []const []const u8) !Action {
        switch (req) {
            .login => {
                if (self.phase != .idle) return .drop_greeter;
                self.phase = .authenticating;
                return .spawn_login;
            },
            .answer => |answer| {
                if (self.phase != .prompting) return .drop_greeter;
                const sent = if (answer) |bytes|
                    proto.writeFrameParts(self.worker_fd, &.{ &.{proto.answer_tag}, bytes })
                else
                    proto.writeFrameParts(self.worker_fd, &.{&.{proto.no_answer_tag}});
                sent catch {
                    self.phase = .idle;
                    try self.reply(.{ .failed = "The login process ended unexpectedly." });
                    return .kill_worker;
                };
                self.phase = .authenticating;
                return .none;
            },
            .start => |id| {
                if (self.phase != .authenticated) return .drop_greeter;
                const resolved = ws.lookupSession(self.arena.allocator(), io, id, search_dirs) catch null;
                const session = resolved orelse {
                    self.phase = .idle;
                    try self.reply(.{ .failed = "That session is not installed." });
                    return .kill_worker;
                };
                self.session = session;
                self.phase = .starting;
                try self.reply(.ok);
                return .handoff;
            },
            .cancel => {
                // After `start` was accepted the greeter has nothing to cancel.
                if (self.phase == .starting) return .drop_greeter;
                self.phase = .idle;
                try self.reply(.ok);
                return .kill_worker;
            },
        }
    }

    /// A report from the login worker during authentication. Session
    /// reports are the daemon's; anything unexpected is an error.
    pub fn handleWorkerMessage(self: *Relay, payload: []const u8) !void {
        if (payload.len == 0) return error.InvalidReport;
        const text = payload[1..];
        var clean: [max_text]u8 = undefined;
        switch (@as(proto.Report, @enumFromInt(payload[0]))) {
            .question => {
                if (self.phase != .authenticating or text.len == 0) return error.UnexpectedReport;
                const kind: dm_ipc.MessageKind = switch (@as(proto.QuestionKind, @enumFromInt(text[0]))) {
                    .secret => .secret,
                    .visible => .visible,
                    .info => .info,
                    .@"error" => .@"error",
                    _ => return error.InvalidReport,
                };
                self.phase = .prompting;
                try self.reply(.{ .question = .{ .kind = kind, .text = proto.sanitizeText(&clean, text[1..]) } });
            },
            .auth_ok => {
                if (self.phase != .authenticating) return error.UnexpectedReport;
                self.phase = .authenticated;
                try self.reply(.ok);
            },
            .denied, .failed => |tag| {
                if (self.phase != .authenticating) return error.UnexpectedReport;
                self.phase = .idle;
                const message = proto.sanitizeText(&clean, text);
                try self.reply(if (tag == .denied) .{ .denied = message } else .{ .failed = message });
            },
            else => return error.UnexpectedReport,
        }
    }

    pub fn reply(self: *Relay, response: dm_ipc.Response) !void {
        // max_text escapes to at most 6 bytes per byte.
        var out: [max_text * 6 + 256]u8 = undefined;
        const frame = try dm_ipc.encodeResponse(&out, response);
        try proto.writeFrame(self.greeter_fd, frame[4..]);
    }
};
