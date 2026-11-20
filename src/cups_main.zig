//! rediwm-cups: printer administration through libcups, in a process of its own
//! so the compositor never maps libcups and the TLS and crypto libraries it
//! pulls in (gnutls, nettle, p11-kit, ...). The Printers page starts it on the
//! first administration request when no cups-pk-helper is present and kills it
//! with the page. It runs as the desktop user, never as root, talks only on its
//! stdin socketpair (`printing/direct_protocol.zig`) and sleeps in poll(2) when
//! idle: the C worker (`printing/direct.c`) does the CUPS I/O on its own threads
//! and wakes this loop through its eventfd.
const std = @import("std");
const c = @import("c");
const platform = @import("platform");
const proto = @import("printing/direct_protocol.zig");
const secure = @import("network/secure_allocator.zig").allocator;

const Native = opaque {};
extern fn rediwm_cups_create() ?*Native;
extern fn rediwm_cups_destroy(*Native) void;
extern fn rediwm_cups_fd(*Native) c_int;
extern fn rediwm_cups_submit(*Native, [*:0]const u8, c_int, [*]const [*:0]const u8, c_int) c_int;
extern fn rediwm_cups_state(*Native) c_int;
extern fn rediwm_cups_result(*Native) c_int;
extern fn rediwm_cups_device(*Native, c_int, c_int) ?[*:0]const u8;
extern fn rediwm_cups_credentials(*Native, [*:0]const u8, [*]const u8, c_ulong) void;
extern fn rediwm_cups_cancel(*Native) void;
extern fn rediwm_cups_finish(*Native) void;

const socket = 0;

/// Fewest arguments each method `direct.c` implements reads. A method not in
/// this list is refused: `execute` would send an unrelated IPP request for it.
fn minimumArguments(method: []const u8) ?usize {
    const table = [_]struct { []const u8, usize }{
        .{ "DevicesGet", 0 },
        .{ "PrinterAdd", 5 },
        .{ "PrinterDelete", 1 },
        .{ "PrinterSetEnabled", 2 },
        .{ "PrinterSetAcceptJobs", 2 },
        .{ "PrinterSetDefault", 1 },
        .{ "PrinterSetInfo", 2 },
        .{ "PrinterSetDevice", 2 },
        .{ "PrinterRename", 2 },
        .{ "PrinterAddOption", 3 },
        .{ "PrinterAddOptionDefault", 3 },
        .{ "PrinterDeleteOptionDefault", 2 },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], method)) return entry[1];
    return null;
}

var frame: [proto.max_command]u8 = undefined;

const Chooser = struct {
    secret: []u8,
    /// A password is received straight into the locked page, every other
    /// payload into the plain buffer.
    pub fn destination(self: Chooser, kind: u8, len: usize) ?[]u8 {
        if (kind == @intFromEnum(proto.Command.credentials)) return if (len <= proto.max_credentials) self.secret else null;
        return if (len <= frame.len) &frame else null;
    }
};

const Session = struct {
    worker: *Native,
    discovery: bool = false,
    /// The last state sent to the compositor; 0 after it sent something that
    /// moves the worker on, so the next password prompt is reported again.
    reported: c_int = 2,

    fn command(self: *Session, kind: u8, payload: []u8) !void {
        switch (@as(proto.Command, @enumFromInt(kind))) {
            .submit => try self.submit(payload),
            .credentials => try self.credentials(payload),
            .cancel => rediwm_cups_cancel(self.worker),
            .finish => rediwm_cups_finish(self.worker),
            _ => return error.UnknownCommand,
        }
    }

    fn submit(self: *Session, payload: []const u8) !void {
        if (payload.len < 2) return error.BadFrame;
        var list: [proto.max_args + 1][:0]const u8 = undefined;
        const count = proto.strings(payload[1..], &list) orelse return error.BadFrame;
        if (count == 0) return error.BadFrame;
        const method = list[0];
        const needed = minimumArguments(method) orelse return error.UnknownMethod;
        if (count - 1 < needed) return error.BadFrame;
        var args: [proto.max_args][*:0]const u8 = undefined;
        for (list[1..count], 0..) |value, i| args[i] = value.ptr;
        self.discovery = std.mem.eql(u8, method, "DevicesGet");
        if (rediwm_cups_submit(self.worker, method.ptr, @intCast(count - 1), &args, @intFromBool(payload[0] != 0)) != 0) return error.Busy;
        self.reported = 0;
    }

    /// `payload` is the locked page; it is wiped as soon as the worker has its copy.
    fn credentials(self: *Session, payload: []u8) !void {
        defer std.crypto.secureZero(u8, payload);
        const nul = std.mem.indexOfScalar(u8, payload, 0) orelse return error.BadFrame;
        const password = payload[nul + 1 ..];
        if (nul == 0 or nul > proto.max_user or password.len > proto.max_password) return error.BadFrame;
        if (std.mem.indexOfScalar(u8, password, 0) != null) return error.BadFrame;
        rediwm_cups_credentials(self.worker, @ptrCast(payload.ptr), password.ptr, password.len);
        self.reported = 0;
    }

    /// The worker changed state (its eventfd fired): tell the compositor about
    /// a password prompt or the end of the request, once each.
    fn changed(self: *Session) !void {
        var counter: u64 = 0;
        _ = c.read(rediwm_cups_fd(self.worker), &counter, @sizeOf(u64));
        const state = rediwm_cups_state(self.worker);
        if (state == 0 or state == self.reported) return;
        self.reported = state;
        if (state == 1) return report(1, 0);
        const result = rediwm_cups_result(self.worker);
        if (self.discovery and result == 0) try self.devices();
        try report(2, result);
    }

    fn devices(self: *Session) !void {
        var bytes: [proto.max_report]u8 = undefined;
        for (0..proto.max_devices) |i| {
            if (rediwm_cups_device(self.worker, @intCast(i), 0) == null) break;
            var used: usize = 0;
            for (0..5) |field| {
                const value = std.mem.span(rediwm_cups_device(self.worker, @intCast(i), @intCast(field)) orelse return error.BadDevice);
                if (used + value.len + 1 > bytes.len) return error.BadDevice;
                @memcpy(bytes[used..][0..value.len], value);
                bytes[used + value.len] = 0;
                used += value.len + 1;
            }
            if (!proto.send(socket, @intFromEnum(proto.Report.device), &.{bytes[0..used]})) return error.PeerGone;
        }
    }
};

fn report(state: u8, result: c_int) !void {
    var body: [5]u8 = undefined;
    body[0] = state;
    std.mem.writeInt(i32, body[1..5], result, .little);
    if (!proto.send(socket, @intFromEnum(proto.Report.state), &.{&body})) return error.PeerGone;
}

fn run() !void {
    try platform.process.denyDumps();
    try platform.process.noNewPrivileges();
    platform.process.ignoreBrokenPipes();
    platform.process.dieWithParent(.KILL);
    if (std.c.geteuid() == 0) return error.RunAsDesktopUser;
    const secret = try secure.alloc(u8, proto.max_credentials);
    defer secure.free(secret);
    const worker = rediwm_cups_create() orelse return error.WorkerFailed;
    defer rediwm_cups_destroy(worker);
    var session: Session = .{ .worker = worker };
    var receiver: proto.Receiver = .{};
    const chooser: Chooser = .{ .secret = secret };
    var fds = [2]c.struct_pollfd{
        .{ .fd = socket, .events = c.POLLIN, .revents = 0 },
        .{ .fd = rediwm_cups_fd(worker), .events = c.POLLIN, .revents = 0 },
    };
    while (true) {
        const ready = c.poll(&fds, fds.len, -1);
        if (ready < 0) {
            if (std.posix.errno(ready) == .INTR) continue;
            return error.PollFailed;
        }
        if (fds[1].revents != 0) try session.changed();
        if (fds[0].revents == 0) continue;
        // Level-triggered: whatever is left after one frame is read next time round.
        switch (receiver.read(socket, chooser)) {
            .again => {},
            .frame => try session.command(receiver.kind, receiver.payload()),
            // The compositor went away: its page is gone, so is this request.
            .closed => return,
            .invalid => return error.BadFrame,
        }
    }
}

pub fn main() void {
    run() catch |err| {
        std.debug.print("rediwm-cups: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
