//! Files the helper owns: our firewall's saved state and rendered rules under
//! `${sysconfdir}/rediwm`, and run state (a pending revert, lockdown) under
//! `${rundir}/rediwm-firewall`. All root-only (0600 files, 0700 directories).
const std = @import("std");
const c = @import("c");
const fw = @import("firewall");
const paths = @import("install_paths");
const run = @import("run.zig");

pub const conf_dir = paths.sysconfdir ++ "/rediwm";
pub const state_path = conf_dir ++ "/firewall.json";
pub const nft_path = conf_dir ++ "/firewall.nft";
pub const pf_path = conf_dir ++ "/pf.rediwm.conf";
pub const run_dir = paths.rundir ++ "/rediwm-firewall";
pub const revert_path = run_dir ++ "/revert.json";
pub const lockdown_path = run_dir ++ "/lockdown";
pub const helper_path = paths.bin ++ "/rediwm-firewall-helper";

pub fn load(ctx: run.Ctx) fw.own.State {
    const text = run.readFile(ctx, state_path, 1 << 20) orelse return .{};
    const parsed = std.json.parseFromSliceLeaky(fw.own.State, ctx.a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .{};
    // A file edited by hand must not smuggle text into a ruleset.
    var rules: std.ArrayList(fw.model.Rule) = .empty;
    for (parsed.rules) |rule| if (fw.validate.rule(rule)) rules.append(ctx.a, rule) catch {};
    var home: std.ArrayList([]const u8) = .empty;
    for (parsed.home_ifaces) |name| if (fw.validate.iface(name)) home.append(ctx.a, name) catch {};
    var state = parsed;
    state.rules = rules.items;
    state.home_ifaces = home.items;
    return state;
}

pub fn save(ctx: run.Ctx, state: fw.own.State) !void {
    const json = try std.json.Stringify.valueAlloc(ctx.a, state, .{ .whitespace = .indent_2 });
    _ = c.umask(0o077);
    try run.writeAtomic(ctx, state_path, json, 0o600);
}

pub fn lockdown(ctx: run.Ctx) bool {
    return run.exists(ctx, lockdown_path);
}

pub fn setLockdown(ctx: run.Ctx, on: bool) !void {
    if (on) try run.writeAtomic(ctx, lockdown_path, "1\n", 0o600) else run.remove(ctx, lockdown_path);
}

const Revert = struct { pid: i32 = 0, deadline: i64 = 0, undo: fw.protocol.Request = .{} };

fn readRevert(ctx: run.Ctx) ?Revert {
    const text = run.readFile(ctx, revert_path, 64 << 10) orelse return null;
    const value = std.json.parseFromSliceLeaky(Revert, ctx.a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    if (value.pid <= 1 or c.kill(value.pid, 0) != 0) return null;
    return value;
}

/// Seconds until a pending change reverts, or 0.
pub fn revertIn(ctx: run.Ctx) u32 {
    const value = readRevert(ctx) orelse return 0;
    const left = value.deadline - run.nowSeconds();
    return if (left > 0) @intCast(left) else 0;
}

/// Keeps the change: stops the watchdog.
pub fn confirm(ctx: run.Ctx) void {
    if (readRevert(ctx)) |value| _ = c.kill(value.pid, c.SIGTERM);
    run.remove(ctx, revert_path);
}

pub const Perform = *const fn (run.Ctx, fw.protocol.Request) anyerror!void;

/// Forks a watchdog that applies `undo` after `seconds` unless `confirm`
/// stops it first. It detaches from Settings' pipe so the page's request
/// finishes now, and outlives the helper run that started it.
pub fn arm(ctx: run.Ctx, undo: fw.protocol.Request, seconds: u32, perform: Perform) !void {
    confirm(ctx);
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setsid();
        const null_fd = c.open("/dev/null", c.O_RDWR);
        if (null_fd >= 0) {
            _ = c.dup2(null_fd, 0);
            _ = c.dup2(null_fd, 1);
            _ = c.dup2(null_fd, 2);
        }
        var remaining: c.struct_timespec = .{ .tv_sec = @intCast(seconds), .tv_nsec = 0 };
        while (c.nanosleep(&remaining, &remaining) != 0) {}
        perform(ctx, undo) catch {};
        run.remove(ctx, revert_path);
        c._exit(0);
    }
    const json = try std.json.Stringify.valueAlloc(ctx.a, Revert{ .pid = pid, .deadline = run.nowSeconds() + seconds, .undo = undo }, .{});
    try run.writeAtomic(ctx, revert_path, json, 0o600);
}
