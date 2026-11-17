//! rediwm-firewall-helper: root-side firewall reads and changes for Settings.
//! Run by pkexec as `read` (status and recent blocks; polkit lets an active
//! session in without a password) or `manage` (everything; the Unlock
//! password), with one JSON request on stdin and a JSON reply on stdout.
//! `sync` (no request) re-applies our saved rules for boot and
//! NetworkManager's dispatcher. Every request field is validated before use.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const fw = @import("firewall");
const platform = @import("platform");
const run = @import("firewall_helper/run.zig");
const state = @import("firewall_helper/state.zig");
const backend = switch (builtin.os.tag) {
    .linux => @import("firewall_helper/linux.zig"),
    .freebsd => @import("firewall_helper/freebsd.zig"),
    else => @compileError("the firewall helper is not ported to this OS"),
};
const Request = fw.protocol.Request;

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) u8 {
    if (c.geteuid() != 0) return fail("must be run through pkexec");
    platform.process.denyDumps() catch {};
    platform.process.ignoreBrokenPipes();
    _ = c.umask(0o077);
    // No run may hang Settings: the page has its own deadline, but a root
    // process cannot be signalled by it.
    _ = c.alarm(90);
    const args = init.minimal.args.vector;
    if (args.len != 2) return fail("usage: rediwm-firewall-helper read|manage|sync");
    const mode = std.mem.span(args[1]);

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = run.environment(a) catch return fail("out of memory");
    const ctx: run.Ctx = .{ .a = a, .io = init.io, .env = &env };

    if (std.mem.eql(u8, mode, "sync")) {
        backend.sync(ctx) catch |err| {
            std.log.err("sync failed: {s}", .{@errorName(err)});
            return 1;
        };
        return 0;
    }
    const manage = std.mem.eql(u8, mode, "manage");
    if (!manage and !std.mem.eql(u8, mode, "read")) return fail("unknown mode");

    const input = readRequest(a) catch return fail("invalid request");
    const parsed = std.json.parseFromSliceLeaky(Request, a, input, .{ .allocate = .alloc_always, .max_value_len = 4096 }) catch return fail("invalid request");
    if (!manage and !fw.protocol.readOnly(parsed.op)) return fail("operation needs the manage action");
    if (!valid(parsed)) return fail("invalid request");

    var reply: fw.protocol.Reply = .{};
    perform(ctx, parsed) catch |err| {
        std.log.err("firewall {s} failed: {s}", .{ @tagName(parsed.op), @errorName(err) });
        reply.failure = failure(err);
    };
    if (parsed.op != .authorize) {
        reply.status = backend.status(ctx) catch |err| blk: {
            std.log.err("firewall status failed: {s}", .{@errorName(err)});
            if (reply.failure == null) reply.failure = "The firewall could not be read.";
            break :blk .{};
        };
        if (parsed.op == .blocks and reply.failure == null) reply.status.blocks = backend.blocks(ctx) catch &.{};
    }
    const json = std.json.Stringify.valueAlloc(a, reply, .{}) catch return fail("out of memory");
    var done: usize = 0;
    while (done < json.len) {
        const n = c.write(1, json.ptr + done, json.len - done);
        if (n <= 0) return 1;
        done += @intCast(n);
    }
    if (parsed.op != .status and parsed.op != .blocks and parsed.op != .authorize) {
        std.log.info("firewall {s} by uid {s}: {s}", .{ @tagName(parsed.op), callerUid(), if (reply.failure == null) "done" else "failed" });
    }
    return if (reply.failure == null) 0 else 3;
}

fn callerUid() []const u8 {
    const raw = c.getenv("PKEXEC_UID") orelse return "?";
    return std.mem.span(raw);
}

fn readRequest(a: std.mem.Allocator) ![]u8 {
    var input: std.ArrayList(u8) = .empty;
    while (true) {
        var chunk: [4096]u8 = undefined;
        const got = c.read(0, &chunk, chunk.len);
        if (got < 0 and std.posix.errno(got) == .INTR) continue;
        if (got < 0) return error.ReadFailed;
        if (got == 0) break;
        const n: usize = @intCast(got);
        if (input.items.len + n > fw.model.max_request) return error.TooLarge;
        try input.appendSlice(a, chunk[0..n]);
    }
    return input.items;
}

fn valid(req: Request) bool {
    if (req.rule) |rule| if (!(if (req.op == .remove_rule) fw.validate.removal(rule) else fw.validate.rule(rule))) return false;
    if ((req.op == .add_rule or req.op == .remove_rule) and req.rule == null) return false;
    if (req.op == .set_option and req.option == null) return false;
    if (req.op == .set_trust) {
        if (req.uuid.len != 0 and !fw.validate.uuid(req.uuid)) return false;
        if (req.uuid.len == 0 and !fw.validate.iface(req.iface)) return false;
    }
    if (req.revert_after > 300) return false;
    return true;
}

fn undo(ctx: run.Ctx, req: Request) ?Request {
    return switch (req.op) {
        .lockdown => if (req.on) Request{ .op = .lockdown, .on = false } else null,
        .disable => Request{ .op = .enable },
        .remove_rule => Request{ .op = .add_rule, .rule = req.rule },
        .set_defaults => blk: {
            const now = backend.status(ctx) catch break :blk null;
            break :blk Request{ .op = .set_defaults, .incoming = if (req.incoming != null) now.incoming else null, .outgoing = if (req.outgoing != null) now.outgoing else null, .forward = if (req.forward != null) now.forward else null };
        },
        else => null,
    };
}

fn perform(ctx: run.Ctx, req: Request) !void {
    switch (req.op) {
        .status, .blocks, .authorize => return,
        .confirm => return state.confirm(ctx),
        .sync => return backend.sync(ctx),
        else => {},
    }
    const revert = if (req.revert_after != 0) undo(ctx, req) else null;
    try backend.change(ctx, req);
    if (revert) |back| try state.arm(ctx, back, req.revert_after, changeOnly);
}

fn changeOnly(ctx: run.Ctx, req: Request) anyerror!void {
    return backend.change(ctx, req);
}

/// Fixed words for the page; tool output never reaches it.
fn failure(err: anyerror) []const u8 {
    return switch (err) {
        error.Conflict => "Another firewall is active. Turn it off first.",
        error.ManagedElsewhere => "This firewall is managed by RediOS.",
        error.ToolMissing => "A firewall tool this needs is not installed.",
        error.RulesetRejected => "The firewall rejected the new rules; nothing was changed.",
        error.NoSuchRule => "That rule is no longer there.",
        error.TooManyRules => "There are too many rules.",
        error.Unsupported => "This firewall cannot do that.",
        else => "The change could not be made.",
    };
}

fn fail(message: []const u8) u8 {
    _ = c.write(2, message.ptr, message.len);
    _ = c.write(2, "\n", 1);
    return 1;
}
