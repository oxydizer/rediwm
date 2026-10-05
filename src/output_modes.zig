//! Advertised modes plus standard lower-resolution modes validated by the
//! backend. Some laptop panels advertise only their native resolution.
const std = @import("std");
const wlr = @import("wlroots");

pub const Choice = struct {
    width: i32,
    height: i32,
    refresh: i32,
    advertised: ?*wlr.Output.Mode = null,

    pub fn fromMode(mode: *wlr.Output.Mode) Choice {
        return .{ .width = mode.width, .height = mode.height, .refresh = mode.refresh, .advertised = mode };
    }

    pub fn setState(choice: Choice, state: *wlr.Output.State) void {
        if (choice.advertised) |mode| state.setMode(mode) else state.setCustomMode(choice.width, choice.height, choice.refresh);
    }
};

const sizes = [_][2]i32{
    .{ 3840, 2160 }, .{ 2560, 1600 }, .{ 2560, 1440 }, .{ 1920, 1200 },
    .{ 1920, 1080 }, .{ 1680, 1050 }, .{ 1600, 1000 }, .{ 1600, 900 },
    .{ 1440, 900 },  .{ 1280, 800 },  .{ 1280, 720 },  .{ 1024, 640 },
};

fn fits(width: i32, height: i32, native_width: i32, native_height: i32) bool {
    return width < native_width and height < native_height and
        @as(i64, width) * native_height == @as(i64, height) * native_width;
}

fn nativeMode(output: *wlr.Output) ?*wlr.Output.Mode {
    var best: ?*wlr.Output.Mode = null;
    var it = output.modes.iterator(.forward);
    while (it.next()) |mode| {
        const area = @as(i64, mode.width) * mode.height;
        const best_area = if (best) |previous| @as(i64, previous.width) * previous.height else 0;
        if (best == null or area > best_area or (area == best_area and mode.refresh > best.?.refresh)) best = mode;
    }
    return best;
}

/// A deterministic candidate set also lets startup restore saved choices.
/// Custom timings use 60 Hz (or the panel's lower native refresh rate).
pub fn customChoice(output: *wlr.Output, width: i32, height: i32, refresh: ?i32) ?Choice {
    if (!output.isDrm()) return null;
    const native = nativeMode(output) orelse return null;
    if (!fits(width, height, native.width, native.height)) return null;
    for (sizes) |size| {
        if (size[0] != width or size[1] != height) continue;
        const rate = @min(60000, native.refresh);
        if (rate <= 0 or (refresh != null and refresh.? != rate)) return null;
        return .{ .width = width, .height = height, .refresh = rate };
    }
    return null;
}

pub fn appendCustom(allocator: std.mem.Allocator, choices: *std.ArrayList(Choice), output: *wlr.Output) !void {
    for (sizes) |size| {
        const candidate = customChoice(output, size[0], size[1], null) orelse continue;
        var present = false;
        for (choices.items) |choice| {
            if (choice.width == candidate.width and choice.height == candidate.height) {
                present = true;
                break;
            }
        }
        if (present) continue;
        var state = wlr.Output.State.init();
        defer state.finish();
        candidate.setState(&state);
        // Testing does not modeset the display. Never list rejected timings.
        if (output.testState(&state)) try choices.append(allocator, candidate);
    }
}

test "lower resolution candidates preserve panel aspect ratio and never upscale" {
    const expect = std.testing.expect;
    try expect(fits(1920, 1200, 2560, 1600));
    try expect(fits(1280, 800, 2560, 1600));
    try expect(!fits(1920, 1080, 2560, 1600));
    try expect(!fits(2560, 1600, 2560, 1600));
    try expect(!fits(3840, 2400, 2560, 1600));
}
