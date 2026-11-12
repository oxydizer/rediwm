//! Keyboard layouts as an ordered list of input sources. They live in the
//! existing comma lists (`xkb_layout`, `xkb_variant`), so older configs and
//! other tools keep reading them; `xkb_labels` adds optional indicator texts
//! in the same positions. Order is the XKB group order.
const std = @import("std");

/// XKB, X11 and Xwayland address at most four groups.
pub const max_layouts = 4;
/// Longest indicator text a source may carry (a few characters, any script).
pub const max_label_bytes = 16;

pub const Layout = struct {
    layout: []const u8,
    variant: []const u8 = "",
    label: []const u8 = "",

    pub fn eql(a: Layout, b: Layout) bool {
        return std.mem.eql(u8, a.layout, b.layout) and std.mem.eql(u8, a.variant, b.variant);
    }

    /// `de(nodeadkeys)`, the usual XKB spelling of a layout and variant.
    pub fn format(self: Layout, buf: []u8) []const u8 {
        if (self.variant.len == 0) return std.fmt.bufPrint(buf, "{s}", .{self.layout}) catch self.layout;
        return std.fmt.bufPrint(buf, "{s}({s})", .{ self.layout, self.variant }) catch self.layout;
    }
};

pub const List = struct {
    items: [max_layouts]Layout = undefined,
    len: usize = 0,
    /// Entries past `max_layouts` that were dropped.
    dropped: usize = 0,

    pub fn slice(self: *const List) []const Layout {
        return self.items[0..self.len];
    }
};

/// The configured layouts in group order; empty when `xkb_layout` is empty
/// (XKB then falls back to XKB_DEFAULT_LAYOUT or its built-in default).
/// The returned strings point into `cfg`.
pub fn split(cfg: anytype) List {
    var list: List = .{};
    if (std.mem.trim(u8, cfg.xkb_layout, " \t").len == 0) return list;
    var layouts = std.mem.splitScalar(u8, cfg.xkb_layout, ',');
    var variants = std.mem.splitScalar(u8, cfg.xkb_variant, ',');
    var labels = std.mem.splitScalar(u8, if (@hasField(@TypeOf(cfg), "xkb_labels")) cfg.xkb_labels else "", ',');
    while (layouts.next()) |raw| {
        const variant = std.mem.trim(u8, variants.next() orelse "", " \t");
        const label = std.mem.trim(u8, labels.next() orelse "", " \t");
        const layout = std.mem.trim(u8, raw, " \t");
        if (list.len == max_layouts) {
            list.dropped += 1;
            continue;
        }
        list.items[list.len] = .{ .layout = layout, .variant = variant, .label = if (label.len <= max_label_bytes) label else "" };
        list.len += 1;
    }
    return list;
}

pub const Joined = struct {
    layout: []u8,
    variant: []u8,
    labels: []u8,

    pub fn deinit(self: Joined, allocator: std.mem.Allocator) void {
        allocator.free(self.layout);
        allocator.free(self.variant);
        allocator.free(self.labels);
    }
};

/// The three config values for `layouts`. Variant and label lists collapse to
/// "" when every entry is empty, as people write them by hand.
pub fn join(allocator: std.mem.Allocator, layouts: []const Layout) !Joined {
    const layout = try joinField(allocator, layouts, "layout", false);
    errdefer allocator.free(layout);
    const variant = try joinField(allocator, layouts, "variant", true);
    errdefer allocator.free(variant);
    const labels = try joinField(allocator, layouts, "label", true);
    return .{ .layout = layout, .variant = variant, .labels = labels };
}

fn joinField(allocator: std.mem.Allocator, layouts: []const Layout, comptime field: []const u8, collapse: bool) ![]u8 {
    if (collapse) {
        var any = false;
        for (layouts) |l| any = any or @field(l, field).len > 0;
        if (!any) return allocator.dupe(u8, "");
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (layouts, 0..) |l, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, @field(l, field));
    }
    return out.toOwnedSlice(allocator);
}

/// A layout or variant name as XKB spells them; anything else would break the
/// comma lists or the rule lookup.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '+', '.' => {},
        else => return false,
    };
    return true;
}

/// An indicator label: short, and free of the list separator.
pub fn validLabel(label: []const u8) bool {
    if (label.len > max_label_bytes) return false;
    if (std.mem.indexOfAny(u8, label, ",\"\\\n\r\t") != null) return false;
    return std.unicode.utf8ValidateSlice(label);
}

test "layout lists split by position, cap at four and join back" {
    const cfg = .{ .xkb_layout = "us, de,jp", .xkb_variant = ",nodeadkeys", .xkb_labels = ",,JP" };
    const list = split(cfg);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("de", list.items[1].layout);
    try std.testing.expectEqualStrings("nodeadkeys", list.items[1].variant);
    try std.testing.expectEqualStrings("", list.items[2].variant);
    try std.testing.expectEqualStrings("JP", list.items[2].label);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("de(nodeadkeys)", list.items[1].format(&buf));

    const joined = try join(std.testing.allocator, list.slice());
    defer joined.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("us,de,jp", joined.layout);
    try std.testing.expectEqualStrings(",nodeadkeys,", joined.variant);
    try std.testing.expectEqualStrings(",,JP", joined.labels);

    const plain = try join(std.testing.allocator, &.{ .{ .layout = "us" }, .{ .layout = "ru" } });
    defer plain.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", plain.variant);
    try std.testing.expectEqualStrings("", plain.labels);

    const many = split(.{ .xkb_layout = "us,de,fr,ru,jp", .xkb_variant = "" });
    try std.testing.expectEqual(@as(usize, 4), many.len);
    try std.testing.expectEqual(@as(usize, 1), many.dropped);
    try std.testing.expectEqual(@as(usize, 0), split(.{ .xkb_layout = " ", .xkb_variant = "" }).len);
}

test "names and labels are validated before they reach the comma lists" {
    try std.testing.expect(validName("de"));
    try std.testing.expect(validName("nodeadkeys"));
    try std.testing.expect(!validName("us,ru"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(validLabel("あ"));
    try std.testing.expect(validLabel(""));
    try std.testing.expect(!validLabel("a,b"));
    try std.testing.expect(!validLabel("much too long for a chip"));
}
