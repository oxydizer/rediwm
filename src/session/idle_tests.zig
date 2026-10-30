const std = @import("std");
const idle = @import("idle.zig");
const IdleManager = idle.IdleManager;
const State = idle.State;

test "idle state transitions with simulated clock" {
    var im: IdleManager = .{
        .config = .{
            .enabled = true,
            .blank_after_seconds = 10,
            .suspend_after_seconds = 30,
        },
        .clock = .{ .mock_now_ms = 1000 },
        .last_activity_ms = 1000,
    };
    im.inhibitors.init();

    try std.testing.expectEqual(State.active, im.state);
    try std.testing.expectEqual(true, im.isPolicyEnabled());

    // 5 seconds elapsed: still active
    im.clock.mock_now_ms = 6000;
    im.tickTimer();
    try std.testing.expectEqual(State.active, im.state);

    // 10 seconds elapsed: transitions to blanked
    im.clock.mock_now_ms = 11000;
    im.tickTimer();
    try std.testing.expectEqual(State.blanked, im.state);

    // 25 seconds elapsed: still blanked (suspend is at 30s)
    im.clock.mock_now_ms = 26000;
    im.tickTimer();
    try std.testing.expectEqual(State.blanked, im.state);

    // 30 seconds elapsed: transitions to suspend_pending
    im.clock.mock_now_ms = 31000;
    im.tickTimer();
    try std.testing.expectEqual(State.suspend_pending, im.state);
    try std.testing.expectEqual(@as(usize, 1), im.suspend_request_count);

    // User activity restores display
    im.clock.mock_now_ms = 35000;
    im.notifyActivity(.keyboard);
    try std.testing.expectEqual(State.active, im.state);
    try std.testing.expectEqual(@as(i64, 35000), im.last_activity_ms);
}

test "wake key absorption and matching release" {
    var im: IdleManager = .{
        .config = .{
            .enabled = true,
            .blank_after_seconds = 10,
        },
        .clock = .{ .mock_now_ms = 1000 },
        .last_activity_ms = 1000,
        .state = .blanked,
    };
    im.inhibitors.init();

    // First key press when blanked is absorbed and wakes displays
    try std.testing.expect(im.interceptWakeKey(30, .pressed));
    try std.testing.expectEqual(State.active, im.state);
    try std.testing.expectEqual(@as(?u32, 30), im.wake_consume_pending_key);

    // Another key press while waking/active is NOT absorbed
    try std.testing.expect(!im.interceptWakeKey(31, .pressed));

    // Release of an unrelated key is NOT absorbed
    try std.testing.expect(!im.interceptWakeKey(31, .released));
    try std.testing.expectEqual(@as(?u32, 30), im.wake_consume_pending_key);

    // Matching key release is absorbed and clears pending
    try std.testing.expect(im.interceptWakeKey(30, .released));
    try std.testing.expectEqual(@as(?u32, null), im.wake_consume_pending_key);

    // Subsequent press/release are normal (not absorbed)
    try std.testing.expect(!im.interceptWakeKey(30, .pressed));
    try std.testing.expect(!im.interceptWakeKey(30, .released));
}

test "wake button absorption and matching release" {
    var im: IdleManager = .{
        .config = .{
            .enabled = true,
            .blank_after_seconds = 10,
        },
        .clock = .{ .mock_now_ms = 1000 },
        .last_activity_ms = 1000,
        .state = .blanked,
    };
    im.inhibitors.init();

    // First mouse button click when blanked is absorbed and wakes displays
    try std.testing.expect(im.interceptWakeButton(0x110, .pressed));
    try std.testing.expectEqual(State.active, im.state);
    try std.testing.expectEqual(@as(?u32, 0x110), im.wake_consume_pending_button);

    // Another button press while active is not absorbed
    try std.testing.expect(!im.interceptWakeButton(0x111, .pressed));

    // Matching release is absorbed and clears pending
    try std.testing.expect(im.interceptWakeButton(0x110, .released));
    try std.testing.expectEqual(@as(?u32, null), im.wake_consume_pending_button);
}

test "config reload wakes blanked displays when policy disabled" {
    var im: IdleManager = .{
        .config = .{
            .enabled = true,
            .blank_after_seconds = 10,
        },
        .clock = .{ .mock_now_ms = 1000 },
        .last_activity_ms = 1000,
        .state = .blanked,
    };
    im.inhibitors.init();

    // Reloading config with idle disabled should restore blanked outputs
    im.applyConfig(.{ .enabled = false, .blank_after_seconds = 10 });
    try std.testing.expectEqual(State.active, im.state);
}

test "idle inhibitor release starts fresh timeout" {
    var im: IdleManager = .{
        .config = .{
            .enabled = true,
            .blank_after_seconds = 10,
        },
        .clock = .{ .mock_now_ms = 1000 },
        .last_activity_ms = 1000,
        .is_inhibited = true,
    };
    im.inhibitors.init();

    // Time elapses past blank deadline, but inhibition prevents blanking
    im.clock.mock_now_ms = 25000;
    im.tickTimer();
    try std.testing.expectEqual(State.active, im.state);

    // Release inhibitor: simulated activity timestamp reset to now
    im.is_inhibited = false;
    im.last_activity_ms = im.clock.nowMs();
    try std.testing.expectEqual(@as(i64, 25000), im.last_activity_ms);

    // 5 seconds after release: still active
    im.clock.mock_now_ms = 30000;
    im.tickTimer();
    try std.testing.expectEqual(State.active, im.state);

    // 10 seconds after release: blanks
    im.clock.mock_now_ms = 35000;
    im.tickTimer();
    try std.testing.expectEqual(State.blanked, im.state);
}

test "sleep deadline is independent of blanking and requests only once per idle episode" {
    var im: IdleManager = .{ .config = .{ .enabled = true, .blank_after_seconds = 0, .suspend_after_seconds = 5 }, .clock = .{ .mock_now_ms = 6000 }, .last_activity_ms = 0 };
    im.inhibitors.init();
    im.tickTimer();
    im.tickTimer();
    try std.testing.expectEqual(State.suspend_pending, im.state);
    try std.testing.expectEqual(@as(usize, 1), im.suspend_request_count);
    im.notifyActivity(.keyboard);
    im.clock.mock_now_ms = 12000;
    im.tickTimer();
    try std.testing.expectEqual(@as(usize, 2), im.suspend_request_count);
}

test "an unsuccessful sleep attempt does not cancel later display blanking" {
    var im: IdleManager = .{
        .config = .{ .enabled = true, .blank_after_seconds = 10, .suspend_after_seconds = 5 },
        .clock = .{ .mock_now_ms = 6000 },
        .last_activity_ms = 0,
    };
    im.inhibitors.init();
    im.tickTimer();
    try std.testing.expectEqual(State.suspend_pending, im.state);
    try std.testing.expect(!im.isBlanked());
    // A failed suspend leaves a visible desktop: don't swallow input.
    try std.testing.expect(!im.interceptWakeKey(30, .pressed));
    try std.testing.expect(!im.interceptWakeButton(0x110, .pressed));
    im.clock.mock_now_ms = 11000;
    im.tickTimer();
    try std.testing.expect(im.isBlanked());
    try std.testing.expectEqual(@as(usize, 1), im.suspend_request_count);
    im.tickTimer();
    try std.testing.expectEqual(@as(usize, 1), im.suspend_request_count);
    try std.testing.expect(im.interceptWakeKey(30, .pressed));
    try std.testing.expect(!im.isBlanked());
    try std.testing.expect(!im.suspend_requested);
}
