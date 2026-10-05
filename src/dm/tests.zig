//! Unit tests for rediwm-dm (`zig build test-dm`).
const std = @import("std");
const config = @import("config.zig");
const state = @import("state.zig");
const proto = @import("proto.zig");
const dm_ipc = @import("dm_ipc");
const ws = @import("wayland_sessions");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});

test {
    _ = proto;
}

test "config: load defaults and custom dm.conf" {
    const a = std.testing.allocator;
    const def = config.Config{};
    try std.testing.expectEqual(@as(u32, 1), def.vt);
    try std.testing.expectEqualStrings("rediwm-greeter", def.greeter_user);

    const conf = try config.Config.parse(a,
        \\vt = 3
        \\greeter_user = test-user
        \\greeter_command = /usr/bin/test-greeter
        \\autologin_user = alice
        \\autologin_session = rediwm
    );
    defer {
        a.free(conf.greeter_user);
        a.free(conf.greeter_command);
        a.free(conf.autologin_user.?);
        a.free(conf.autologin_session.?);
    }
    try std.testing.expectEqual(@as(u32, 3), conf.vt);
    try std.testing.expectEqualStrings("test-user", conf.greeter_user);
    try std.testing.expectEqualStrings("/usr/bin/test-greeter", conf.greeter_command);
    try std.testing.expectEqualStrings("alice", conf.autologin_user.?);
    try std.testing.expectEqualStrings("rediwm", conf.autologin_session.?);
}

/// A relay wired to socketpairs standing in for the greeter and the worker.
const Harness = struct {
    relay: state.Relay,
    greeter: [2]c_int,
    worker: [2]c_int,
    buf: [8192]u8 = undefined,

    fn init(self: *Harness) !void {
        self.relay = .init(std.testing.allocator);
        try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &self.greeter));
        try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &self.worker));
        self.relay.greeter_fd = self.greeter[0];
        self.relay.worker_fd = self.worker[0];
    }

    fn deinit(self: *Harness) void {
        for (self.greeter ++ self.worker) |fd| _ = c.close(fd);
        self.relay.deinit();
    }

    fn request(self: *Harness, req: dm_ipc.Request) !state.Action {
        return self.relay.handleGreeterRequest(req, std.testing.io, &.{});
    }

    fn report(self: *Harness, tag: proto.Report, text: []const u8) !void {
        var frame: [256]u8 = undefined;
        frame[0] = @intFromEnum(tag);
        @memcpy(frame[1..][0..text.len], text);
        try self.relay.handleWorkerMessage(frame[0 .. text.len + 1]);
    }

    /// The next response the greeter received.
    fn greeterGot(self: *Harness) !dm_ipc.ParsedResponse {
        return dm_ipc.parseResponse(std.testing.allocator, try proto.readFrame(self.greeter[1], &self.buf));
    }

    fn workerGot(self: *Harness) ![]const u8 {
        return proto.readFrame(self.worker[1], &self.buf);
    }
};

test "relay: a secret question, a tricky answer and success" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try std.testing.expectEqual(state.Action.spawn_login, try h.request(.{ .login = "alice" }));
    try h.report(.question, "sPassword:");
    try std.testing.expectEqual(state.Phase.prompting, h.relay.phase);
    var q = try h.greeterGot();
    defer q.deinit();
    try std.testing.expectEqual(dm_ipc.MessageKind.secret, q.response.question.kind);
    try std.testing.expectEqualStrings("Password:", q.response.question.text);

    // Answers reach the worker as raw bytes: quotes, backslashes and
    // control characters included.
    try std.testing.expectEqual(state.Action.none, try h.request(.{ .answer = "p\"w\\\x08\x0c\xc3\xa9" }));
    try std.testing.expectEqualStrings("Ap\"w\\\x08\x0c\xc3\xa9", try h.workerGot());

    // Info messages are acknowledged with no answer.
    try h.report(.question, "iTouch the key");
    var info = try h.greeterGot();
    defer info.deinit();
    try std.testing.expectEqual(state.Action.none, try h.request(.{ .answer = null }));
    try std.testing.expectEqualStrings("N", try h.workerGot());

    try h.report(.auth_ok, "");
    try std.testing.expectEqual(state.Phase.authenticated, h.relay.phase);
    var ok = try h.greeterGot();
    defer ok.deinit();
    try std.testing.expect(ok.response == .ok);

    // A session id that is not a plain stem is refused and ends the login.
    try std.testing.expectEqual(state.Action.kill_worker, try h.request(.{ .start = "../invalid" }));
    try std.testing.expectEqual(state.Phase.idle, h.relay.phase);
    var fail = try h.greeterGot();
    defer fail.deinit();
    try std.testing.expect(fail.response == .failed);
}

test "relay: start resolves the installed session, quotes and all" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const io = std.testing.io;
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/rediwm-dm-test-{d}", .{std.os.linux.getpid()});
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(io, dir) catch {};
    var path_buf: [128]u8 = undefined;
    try cwd.createDirPath(io, try std.fmt.bufPrint(&path_buf, "{s}/wayland-sessions", .{dir}));
    try cwd.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/wayland-sessions/quoted.desktop", .{dir}),
        .data = "[Desktop Entry]\nName=Q\nExec=sh -c \"exec sway\" %U\nDesktopNames=sway;wlroots\n",
    });

    _ = try h.request(.{ .login = "alice" });
    try h.report(.auth_ok, "");
    var ok = try h.greeterGot();
    defer ok.deinit();
    try std.testing.expectEqual(state.Action.handoff, try h.relay.handleGreeterRequest(.{ .start = "quoted" }, io, &.{dir}));
    try std.testing.expectEqual(state.Phase.starting, h.relay.phase);
    try std.testing.expectEqualStrings("sh -c \"exec sway\"", h.relay.session.?.exec);
    try std.testing.expectEqualStrings("sway:wlroots", h.relay.session.?.desktops);
    var started = try h.greeterGot();
    defer started.deinit();
    try std.testing.expect(started.response == .ok);
    h.relay.reset();
    try std.testing.expect(h.relay.session == null and h.relay.phase == .idle);
}

test "relay: out-of-order requests drop the greeter" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try std.testing.expectEqual(state.Action.drop_greeter, try h.request(.{ .start = "rediwm" }));
    try std.testing.expectEqual(state.Action.drop_greeter, try h.request(.{ .answer = "pw" }));
    _ = try h.request(.{ .login = "alice" });
    // A second login while one is running, or an answer nobody asked for.
    try std.testing.expectEqual(state.Action.drop_greeter, try h.request(.{ .login = "bob" }));
    try std.testing.expectEqual(state.Action.drop_greeter, try h.request(.{ .answer = "pw" }));
    try std.testing.expectEqual(state.Action.drop_greeter, try h.request(.{ .start = "rediwm" }));
    // Reports out of order are refused, not relayed.
    try h.report(.question, "sPassword:");
    var q = try h.greeterGot();
    defer q.deinit();
    try std.testing.expectError(error.UnexpectedReport, h.report(.auth_ok, ""));
    try std.testing.expectError(error.InvalidReport, h.relay.handleWorkerMessage(""));
}

test "relay: wrong credentials end the login" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.request(.{ .login = "alice" });
    try h.report(.denied, "Authentication failure");
    try std.testing.expectEqual(state.Phase.idle, h.relay.phase);
    var denied = try h.greeterGot();
    defer denied.deinit();
    try std.testing.expectEqualStrings("Authentication failure", denied.response.denied);
    // The greeter's follow-up cancel is answered, and ends any worker left.
    try std.testing.expectEqual(state.Action.kill_worker, try h.request(.cancel));
    var ok = try h.greeterGot();
    defer ok.deinit();
    try std.testing.expect(ok.response == .ok);
}

test "relay: cancel mid-prompt kills the worker and ignores its last words" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.request(.{ .login = "alice" });
    try h.report(.question, "vCode:");
    var q = try h.greeterGot();
    defer q.deinit();
    try std.testing.expectEqual(state.Action.kill_worker, try h.request(.cancel));
    try std.testing.expectEqual(state.Phase.idle, h.relay.phase);
    var ok = try h.greeterGot();
    defer ok.deinit();
    try std.testing.expect(ok.response == .ok);
    // Nothing more reaches the greeter, even if the worker still reports.
    try std.testing.expectError(error.UnexpectedReport, h.report(.auth_ok, ""));
    try std.testing.expectEqual(state.Action.spawn_login, try h.request(.{ .login = "alice" }));
}

test "relay: PAM text that is not UTF-8 still reaches the greeter" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.request(.{ .login = "alice" });
    try h.report(.question, "eBad \xff\"byte\"\n");
    var q = try h.greeterGot();
    defer q.deinit();
    try std.testing.expectEqualStrings("Bad ?\"byte\"\n", q.response.question.text);
}

test "autologin decision table" {
    const mockValidator = struct {
        fn validate(u: []const u8, _: ws.UidRange) bool {
            return std.mem.eql(u8, u, "valid_user");
        }
    }.validate;
    const io = std.testing.io;
    try std.testing.expectEqual(state.AutologinDecision.skip_bad_user, state.checkAutologin(io, "/nonexistent/marker", "bad_user", "session", &.{}, .{}, mockValidator));
    try std.testing.expectEqual(state.AutologinDecision.skip_bad_session, state.checkAutologin(io, "/nonexistent/marker", "valid_user", "../bad/session", &.{}, .{}, mockValidator));
    try std.testing.expectEqual(state.AutologinDecision.skip_bad_session, state.checkAutologin(io, "/nonexistent/marker", "valid_user", "nonexistent_session", &.{}, .{}, mockValidator));
    try std.testing.expectEqual(state.AutologinDecision.skip_marker_exists, state.checkAutologin(io, "/", "valid_user", "session", &.{}, .{}, mockValidator));
}
