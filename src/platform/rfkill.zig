//! Radio kill switches: which radios exist and whether software blocks them,
//! and blocking or restoring them (airplane mode). Linux reads and writes
//! `/dev/rfkill`; other systems report no radios.
//!
//! Reading `/dev/rfkill` yields one ADD event per radio already present. NetworkManager and BlueZ
//! follow a soft block by themselves, so nothing else needs to be told.

const std = @import("std");
const builtin = @import("builtin");

pub const max_radios = 32;
/// The kernel's `struct rfkill_event` (version 1, which every kernel returns
/// to an 8-byte read).
pub const Event = extern struct { idx: u32, kind: u8, op: u8, soft: u8, hard: u8 };
pub const op_add = 0;
pub const op_change = 2;
pub const op_change_all = 3;
const kind_all = 0;

pub const Radio = struct { idx: u32 = 0, soft: bool = false, hard: bool = false };
pub const State = struct {
    radios: [max_radios]Radio = @splat(.{}),
    count: usize = 0,

    /// Every radio is blocked by software (and there is at least one).
    pub fn allBlocked(self: *const State) bool {
        if (self.count == 0) return false;
        for (self.radios[0..self.count]) |radio| if (!radio.soft and !radio.hard) return false;
        return true;
    }
    /// Some radio is blocked by a switch software cannot move.
    pub fn hardBlocked(self: *const State) bool {
        for (self.radios[0..self.count]) |radio| if (radio.hard) return true;
        return false;
    }
    fn add(self: *State, event: Event) void {
        if (event.op != op_add or self.count == max_radios) return;
        self.radios[self.count] = .{ .idx = event.idx, .soft = event.soft != 0, .hard = event.hard != 0 };
        self.count += 1;
    }
};

pub fn blockAllEvent(block: bool) Event {
    return .{ .idx = 0, .kind = kind_all, .op = op_change_all, .soft = @intFromBool(block), .hard = 0 };
}

pub fn changeEvent(idx: u32, block: bool) Event {
    return .{ .idx = idx, .kind = kind_all, .op = op_change, .soft = @intFromBool(block), .hard = 0 };
}

const supported = builtin.os.tag == .linux;
const linux = std.os.linux;

fn open(flags: linux.O) ?std.posix.fd_t {
    const rc = std.posix.system.open("/dev/rfkill", flags, @as(c_uint, 0));
    return if (rc < 0) null else @intCast(rc);
}

/// The radios now present; empty where there is no rfkill.
pub fn read() State {
    var state: State = .{};
    if (!supported) return state;
    const fd = open(.{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }) orelse return state;
    defer _ = std.posix.system.close(fd);
    while (true) {
        var event: Event = undefined;
        const n = std.posix.system.read(fd, @ptrCast(&event), @sizeOf(Event));
        if (n != @sizeOf(Event)) break;
        state.add(event);
    }
    return state;
}

fn send(event: Event) !void {
    if (!supported) return error.Unsupported;
    const fd = open(.{ .ACCMODE = .WRONLY, .CLOEXEC = true }) orelse return error.AccessDenied;
    defer _ = std.posix.system.close(fd);
    if (std.posix.system.write(fd, @ptrCast(&event), @sizeOf(Event)) != @sizeOf(Event)) return error.WriteFailed;
}

pub fn blockAll(block: bool) !void {
    try send(blockAllEvent(block));
}

/// Puts each radio in `before` back as it was (those since removed are skipped).
pub fn restore(before: *const State) !void {
    for (before.radios[0..before.count]) |radio| try send(changeEvent(radio.idx, radio.soft));
}

test "radio states" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Event));
    var state: State = .{};
    try std.testing.expect(!state.allBlocked());
    state.add(.{ .idx = 0, .kind = 1, .op = op_add, .soft = 1, .hard = 0 });
    state.add(.{ .idx = 1, .kind = 2, .op = op_add, .soft = 0, .hard = 0 });
    state.add(.{ .idx = 9, .kind = 2, .op = op_change, .soft = 1, .hard = 0 });
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expect(!state.allBlocked() and !state.hardBlocked());
    state.radios[1].soft = true;
    try std.testing.expect(state.allBlocked());
    state.radios[0] = .{ .idx = 0, .soft = false, .hard = true };
    try std.testing.expect(state.allBlocked() and state.hardBlocked());
    try std.testing.expectEqual(@as(u8, 1), blockAllEvent(true).soft);
    try std.testing.expectEqual(@as(u8, op_change_all), blockAllEvent(false).op);
    try std.testing.expectEqual(@as(u32, 3), changeEvent(3, false).idx);
}
