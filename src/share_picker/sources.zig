//! xdpw dmenu chooser contract (xdg-desktop-portal-wlr 0.8.4):
//! stdin is a newline-separated list of opaque source labels; stdout must be
//! exactly one of those lines, or empty to decline. Logs go to stderr.
//! Labels are not parsed for "Monitor:" / "Window:" prefixes — those are
//! part of the opaque value xdpw later strcmp's against.
const std = @import("std");

pub const Decision = union(enum) {
    select: []const u8,
    cancel,
};

pub const Options = struct {
    select_index: ?usize = null,
    select_label: ?[]const u8 = null,
    cancel: bool = false,
};

pub fn parseLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |line| allocator.free(line);
        list.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = raw;
        if (std.mem.endsWith(u8, line, "\r")) line = line[0 .. line.len - 1];
        if (line.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, line));
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeLines(allocator: std.mem.Allocator, lines: [][]const u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

pub fn decide(labels: []const []const u8, options: Options) Decision {
    if (options.cancel) return .cancel;
    if (options.select_index) |index| {
        if (index < labels.len) return .{ .select = labels[index] };
        return .cancel;
    }
    if (options.select_label) |wanted| {
        for (labels) |label| {
            if (std.mem.eql(u8, label, wanted)) return .{ .select = label };
        }
        return .cancel;
    }
    return .cancel;
}

test "parseLines keeps duplicate and malformed titles, drops blanks" {
    const labels = try parseLines(std.testing.allocator, "Monitor: eDP-1 Built-in\n\nWindow: (untitled)\nMonitor: eDP-1 Built-in\nnot a source at all\n");
    defer freeLines(std.testing.allocator, labels);
    try std.testing.expectEqual(@as(usize, 4), labels.len);
    try std.testing.expectEqualStrings("Monitor: eDP-1 Built-in", labels[0]);
    try std.testing.expectEqualStrings("Window: (untitled)", labels[1]);
    try std.testing.expectEqualStrings("Monitor: eDP-1 Built-in", labels[2]);
    try std.testing.expectEqualStrings("not a source at all", labels[3]);
}

test "select-index returns the exact stdin line, including duplicates" {
    const labels = try parseLines(std.testing.allocator, "same\nsame\nother\n");
    defer freeLines(std.testing.allocator, labels);
    const first = decide(labels, .{ .select_index = 0 });
    const second = decide(labels, .{ .select_index = 1 });
    try std.testing.expectEqualStrings("same", first.select);
    try std.testing.expectEqualStrings("same", second.select);
    try std.testing.expect(first.select.ptr != second.select.ptr);
}

test "select-label requires an exact match and cancel emits nothing" {
    const labels = [_][]const u8{ "Monitor: HDMI-A-1", "Window: foo" };
    switch (decide(&labels, .{ .select_label = "Monitor: HDMI-A-1" })) {
        .select => |line| try std.testing.expectEqualStrings("Monitor: HDMI-A-1", line),
        .cancel => return error.TestUnexpectedResult,
    }
    switch (decide(&labels, .{ .select_label = "HDMI-A-1" })) {
        .cancel => {},
        .select => return error.TestUnexpectedResult,
    }
    switch (decide(&labels, .{ .cancel = true, .select_index = 0 })) {
        .cancel => {},
        .select => return error.TestUnexpectedResult,
    }
    switch (decide(&labels, .{ .select_index = 99 })) {
        .cancel => {},
        .select => return error.TestUnexpectedResult,
    }
}
