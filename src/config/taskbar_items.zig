//! Ordered right-hand taskbar items. Hidden items retain their place in the list.
const std = @import("std");

pub const Item = enum {
    battery,
    network,
    volume,
    clock,

    pub fn label(item: Item) []const u8 {
        return switch (item) {
            .battery => "Battery",
            .network => "Network",
            .volume => "Volume",
            .clock => "Clock",
        };
    }
};
pub const count = std.meta.fields(Item).len;

pub const Config = struct {
    order: [count]Item = .{ .battery, .network, .volume, .clock },
    visible: [count]bool = .{ true, true, true, true },

    pub fn move(config: *Config, index: usize, right: bool) void {
        if (index >= count or (!right and index == 0) or (right and index == count - 1)) return;
        const other = if (right) index + 1 else index - 1;
        std.mem.swap(Item, &config.order[index], &config.order[other]);
    }

    pub fn shown(config: Config, item: Item) bool {
        return config.visible[@intFromEnum(item)];
    }

    /// A minus prefix hides an item while keeping its configured position.
    pub fn parse(value: []const u8) !Config {
        const raw = std.mem.trim(u8, value, " \t\r");
        if (raw.len < 2 or raw[0] != '[' or raw[raw.len - 1] != ']') return error.InvalidValue;
        var result: Config = .{};
        var seen = [_]bool{false} ** count;
        var tokens = std.mem.splitScalar(u8, raw[1 .. raw.len - 1], ',');
        var index: usize = 0;
        while (tokens.next()) |token| {
            const entry = std.mem.trim(u8, token, " \t\r");
            if (index >= count or entry.len < 3 or entry[0] != '"' or entry[entry.len - 1] != '"') return error.InvalidValue;
            var name = entry[1 .. entry.len - 1];
            const visible = name[0] != '-';
            if (!visible) name = name[1..];
            const item = std.meta.stringToEnum(Item, name) orelse return error.InvalidValue;
            const id = @intFromEnum(item);
            if (seen[id]) return error.InvalidValue;
            seen[id] = true;
            result.order[index] = item;
            result.visible[id] = visible;
            index += 1;
        }
        if (index != count) return error.InvalidValue;
        return result;
    }

    pub fn serialize(config: Config, allocator: std.mem.Allocator) ![]u8 {
        var buffer: std.Io.Writer.Allocating = .init(allocator);
        errdefer buffer.deinit();
        try buffer.writer.writeByte('[');
        for (config.order, 0..) |item, i| {
            if (i > 0) try buffer.writer.writeAll(", ");
            try buffer.writer.print("\"{s}{s}\"", .{ if (config.shown(item)) "" else "-", @tagName(item) });
        }
        try buffer.writer.writeByte(']');
        return buffer.toOwnedSlice();
    }
};

pub const Layout = struct {
    x: [count]?f32 = .{ null, null, null, null },
    left: f32,
};

pub fn arrange(config: Config, right: f32, widths: [count]f32, battery_present: bool, gap: f32, clock_gap: f32) Layout {
    var result: Layout = .{ .left = right };
    var next: ?Item = null;
    var index: usize = count;
    while (index > 0) {
        index -= 1;
        const item = config.order[index];
        if (!config.shown(item) or (item == .battery and !battery_present)) continue;
        if (next) |neighbor| result.left -= if (item == .clock or neighbor == .clock) clock_gap else gap;
        result.left -= widths[@intFromEnum(item)];
        result.x[@intFromEnum(item)] = result.left;
        next = item;
    }
    return result;
}

test "taskbar order and hidden state round trip and reject malformed lists" {
    var config: Config = .{};
    config.move(0, true);
    config.visible[@intFromEnum(Item.volume)] = false;
    const encoded = try config.serialize(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualDeep(config, try Config.parse(encoded));
    for ([_][]const u8{ "[]", "[\"battery\", \"network\", \"volume\", \"volume\"]", "[\"battery\", \"network\", \"volume\", \"chevron\"]" }) |bad| {
        try std.testing.expectError(error.InvalidValue, Config.parse(bad));
    }
}

test "taskbar layout packs visible items and keeps move boundaries stable" {
    var config: Config = .{};
    config.move(0, false);
    config.move(count - 1, true);
    try std.testing.expectEqualDeep(Config{}, config);
    const widths = [count]f32{ 112, 34, 34, 96 };
    const full = arrange(config, 1000, widths, true, 6, 16);
    try std.testing.expectEqual(@as(?f32, 904), full.x[@intFromEnum(Item.clock)]);
    config.visible[@intFromEnum(Item.network)] = false;
    const hidden = arrange(config, 1000, widths, false, 6, 16);
    try std.testing.expect(hidden.x[@intFromEnum(Item.battery)] == null);
    try std.testing.expect(hidden.x[@intFromEnum(Item.network)] == null);
    try std.testing.expectEqual(@as(f32, 854), hidden.left);
    config.visible = .{ false, false, false, false };
    try std.testing.expectEqual(@as(f32, 1000), arrange(config, 1000, widths, true, 6, 16).left);
}
