//! Shared contract between the portal backend and Files' chooser mode.
const std = @import("std");
const c = @cImport({
    @cInclude("fnmatch.h");
});
extern fn g_content_type_guess([*:0]const u8, ?[*]const u8, usize, ?*c_int) ?[*:0]u8;
extern fn g_content_type_is_a([*:0]const u8, [*:0]const u8) c_int;
extern fn g_free(?*anyopaque) void;

pub const Mode = enum { open, save, folder };
pub const Rule = struct { kind: u32, value: []const u8 };
pub const Filter = struct { name: []const u8, rules: []const Rule };
pub const ChoiceValue = struct { id: []const u8, label: []const u8 };
pub const Choice = struct { id: []const u8, label: []const u8, values: []const ChoiceValue, selected: []const u8 };
pub const Options = struct {
    mode: Mode = .open,
    multiple: bool = false,
    title: []const u8 = "",
    accept_label: []const u8 = "",
    current_folder: []const u8 = "",
    current_name: []const u8 = "",
    parent_window: []const u8 = "",
    filters: []const Filter = &.{},
    filter_index: usize = 0,
    choices: []const Choice = &.{},
    files: []const []const u8 = &.{},
};
pub const Result = struct {
    paths: []const []const u8,
    filter_index: usize = 0,
    choices: []const []const u8 = &.{},
};

pub fn matches(filter: Filter, name: []const u8) bool {
    var name_buf: [4096]u8 = undefined;
    const zname = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch return false;
    for (filter.rules) |rule| {
        var buf: [4096]u8 = undefined;
        const pattern = std.fmt.bufPrintZ(&buf, "{s}", .{rule.value}) catch continue;
        if (rule.kind == 0) {
            if (c.fnmatch(pattern, zname, 0) == 0) return true;
        } else if (rule.kind == 1) {
            const mime = g_content_type_guess(zname, null, 0, null) orelse continue;
            defer g_free(mime);
            if (g_content_type_is_a(mime, pattern) != 0) return true;
        }
    }
    return false;
}

pub fn validName(name: []const u8) bool {
    return name.len > 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and std.mem.indexOfAny(u8, name, "/\x00") == null;
}

test "chooser filters preserve glob semantics and MIME inheritance" {
    try std.testing.expect(matches(.{ .name = "Images", .rules = &.{.{ .kind = 0, .value = "*.png" }} }, "a.png"));
    try std.testing.expect(!matches(.{ .name = "Images", .rules = &.{.{ .kind = 0, .value = "*.png" }} }, "a.txt"));
    try std.testing.expect(matches(.{ .name = "Text", .rules = &.{.{ .kind = 1, .value = "text/plain" }} }, "a.txt"));
    try std.testing.expect(!validName("../outside"));
    try std.testing.expect(validName("a\nquoted\".txt"));
}
