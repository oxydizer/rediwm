const std = @import("std");
const fold = @import("ui").fold;

pub const Filter = struct {
    query: []const u8,
    chord: []const u8,
    options: fold.Options,

    pub fn init(a: std.mem.Allocator, query: []const u8, options: fold.Options) !Filter {
        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        var chord: std.ArrayList(u8) = .empty;
        for (trimmed) |byte| {
            if (!std.ascii.isWhitespace(byte)) try chord.append(a, byte);
        }
        return .{ .query = trimmed, .chord = chord.items, .options = options };
    }

    pub fn text(f: Filter, title: []const u8, description: []const u8) bool {
        return f.query.len == 0 or
            fold.contains(title, f.query, f.options) or
            fold.contains(description, f.query, f.options);
    }

    pub fn binding(f: Filter, label: []const u8) bool {
        return fold.contains(label, f.chord, .{});
    }
};

test "shortcut search folds localized names and normalizes chord whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const title = "Close Window";
    const desc = "Close the focused window.";
    for ([_][]const u8{ "close", "WINDOW", "focused" }) |query| {
        const filter = try Filter.init(a, query, .{});
        try std.testing.expect(filter.text(title, desc));
        try std.testing.expect(!filter.binding("Super+q"));
    }
    for ([_][]const u8{ "Super+q", "super + Q" }) |query| {
        const filter = try Filter.init(a, query, .{});
        try std.testing.expect(!filter.text(title, desc));
        try std.testing.expect(filter.binding("Super+q"));
    }
    const unicode = try Filter.init(a, "ÉCRAN", .{});
    try std.testing.expect(unicode.text("Capture de l’écran", ""));
}
