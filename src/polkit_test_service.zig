//! Noninstalled runner: isolated registration/fixture tests, or an explicit
//! --terminal for manual authentication. Production has no simulated answers.
const std = @import("std");
const wl = @import("wayland").server.wl;
const Agent = @import("polkit/mod.zig").Agent;
const helper = @import("polkit/helper.zig");
const Terminal = @import("polkit_test_terminal.zig").Terminal;
var stop = false;
var hold_prompt = false;
var terminal_mode = false;
var input_agent: ?*Agent = null;
var next_socket: []const u8 = "";

// Fixed fixture lives only in this noninstalled binary. The production agent
// has no environment/IPC path that can supply passwords or automatic answers.
fn simulated(_: ?*anyopaque, agent: *Agent, event: helper.Event) void {
    const line: []const u8 = switch (event) {
        .prompt_hidden, .prompt_visible => blk: {
            if (!hold_prompt) agent.respond("test-response") catch agent.cancel();
            break :blk "prompt\n";
        },
        .info => "info\n",
        .error_message => "error-message\n",
        .success => "success\n",
        .failure => "failure\n",
        .transport_error => "transport-error\n",
        .cancelled => "cancelled\n",
    };
    _ = std.posix.system.write(1, line.ptr, line.len);
}

fn input(_: c_int, _: wl.EventMask, _: *bool) c_int {
    var byte: [1]u8 = undefined;
    const n = std.posix.system.read(0, &byte, byte.len);
    if (n == 1 and hold_prompt) {
        const agent = input_agent.?;
        switch (byte[0]) {
            'd' => agent.conn.close(),
            't', 'x', 'e' => {
                agent.configure(byte[0] != 'x', if (next_socket.len > 0) next_socket else agent.helper_socket) catch {
                    stop = true;
                    return 0;
                };
                _ = std.posix.system.write(1, "configured\n", 11);
            },
            'p' => {
                agent.pauseForLock();
                _ = std.posix.system.write(1, "paused\n", 7);
            },
            'r' => {
                agent.resumeAfterLock();
                _ = std.posix.system.write(1, "resumed\n", 8);
            },
            'a' => agent.respond("test-response") catch agent.cancel(),
            's' => {
                var buf: [80]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "state {d} {d} {d}\n", .{ agent.queue.items.len, if (agent.active) |active| active.attempt else @as(u8, 0), @intFromBool(agent.suspended) }) catch unreachable;
                _ = std.posix.system.write(1, line.ptr, line.len);
            },
            else => {
                stop = true;
            },
        }
        return 0;
    }
    stop = true;
    return 0;
}
fn state(_: ?*anyopaque, value: Agent.State) void {
    if (terminal_mode and value == .unavailable) stop = true;
    const line = switch (value) {
        .registered => "registered\n",
        .unavailable => "unavailable\n",
    };
    _ = std.posix.system.write(1, line.ptr, line.len);
}
fn interrupted(_: std.posix.SIG) callconv(.c) void {
    stop = true;
}
pub fn main(init: std.process.Init) !void {
    const display = try wl.Server.create();
    defer display.destroy();
    const agent = try Agent.create(std.heap.c_allocator, display.getEventLoop(), init.minimal.environ, null, state) orelse return;
    defer agent.destroy();
    input_agent = agent;
    // Only this fixture honours an environment override; the compositor takes
    // the socket from `[polkit] helper_socket`.
    if (init.minimal.environ.getPosix("REDIWM_POLKIT_HELPER_SOCKET")) |path| agent.helper_socket = path;
    next_socket = init.minimal.environ.getPosix("REDIWM_TEST_NEXT_HELPER_SOCKET") orelse "";
    const args = init.minimal.args.vector;
    var terminal: ?*Terminal = null;
    defer if (terminal) |tty| tty.destroy();
    if (args.len > 1) {
        const mode = std.mem.span(args[1]);
        terminal_mode = std.mem.eql(u8, mode, "--terminal");
        if (terminal_mode) {
            terminal = try Terminal.create(display.getEventLoop(), agent, &stop);
            const action: std.posix.Sigaction = .{ .handler = .{ .handler = interrupted }, .mask = std.posix.sigemptyset(), .flags = 0 };
            std.posix.sigaction(.INT, &action, null);
            std.posix.sigaction(.TERM, &action, null);
        } else {
            if (!std.mem.eql(u8, mode, "--simulate") and !std.mem.eql(u8, mode, "--hold")) return error.InvalidMode;
            // Never send a fixture password to a real bus/helper by mistake.
            const system = init.minimal.environ.getPosix("DBUS_SYSTEM_BUS_ADDRESS") orelse return error.NotPrivate;
            const session = init.minimal.environ.getPosix("DBUS_SESSION_BUS_ADDRESS") orelse return error.NotPrivate;
            if (!std.mem.eql(u8, system, session) or std.mem.eql(u8, agent.helper_socket, helper.default_socket)) return error.NotPrivate;
            hold_prompt = std.mem.eql(u8, mode, "--hold");
            agent.conversation = .{ .event = simulated };
        }
    }
    const source = if (!terminal_mode) try display.getEventLoop().addFd(*bool, 0, .{ .readable = true }, input, &stop) else null;
    defer if (source) |s| s.remove();
    while (!stop) display.getEventLoop().dispatch(-1) catch |err| {
        if (!stop) return err;
    };
}
