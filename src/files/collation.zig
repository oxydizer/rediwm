//! Private name collation. Keys are frozen with each listing so UI sorting
//! never calls libc, changes the process locale or races a worker update.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const Locale = struct {
    handle: c.locale_t,
    name_buffer: [256:0]u8,
    name_len: usize,

    pub fn init(locale_name: []const u8) ?Locale {
        if (locale_name.len >= 256 or std.mem.indexOfScalar(u8, locale_name, 0) != null) return null;
        var self: Locale = .{ .handle = null, .name_buffer = @splat(0), .name_len = locale_name.len };
        @memcpy(self.name_buffer[0..locale_name.len], locale_name);
        self.handle = c.newlocale(c.LC_COLLATE_MASK, &self.name_buffer, null) orelse return null;
        return self;
    }

    pub fn deinit(self: *Locale) void {
        c.freelocale(self.handle);
        self.* = undefined;
    }

    pub fn name(self: *const Locale) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    /// Empty preferences inherit LC_ALL, LC_COLLATE, then LANG. Reading the
    /// supplied environment also keeps isolated worker fixtures independent
    /// of libc's process-global environment.
    pub fn requested(formats: []const u8, env: std.process.Environ) []const u8 {
        if (formats.len > 0) return formats;
        inline for (.{ "LC_ALL", "LC_COLLATE", "LANG" }) |variable| {
            if (env.getPosix(variable)) |value| if (value.len > 0) return value;
        }
        return "C";
    }

    pub fn fromPreferences(formats: []const u8, env: std.process.Environ) Locale {
        return init(requested(formats, env)) orelse init("C").?;
    }

    pub fn key(self: *const Locale, allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        // Linux filenames need not be UTF-8. Keep their raw bytes as a stable
        // key instead of passing malformed multibyte sequences to libc.
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return allocator.dupe(u8, text);
        var source_buffer: [1024]u8 = undefined;
        const owned_source = if (text.len >= source_buffer.len) try allocator.dupeSentinel(u8, text, 0) else null;
        defer if (owned_source) |owned| allocator.free(owned);
        const ztext: [:0]const u8 = owned_source orelse blk: {
            @memcpy(source_buffer[0..text.len], text);
            source_buffer[text.len] = 0;
            break :blk source_buffer[0..text.len :0];
        };
        var unused: [1]u8 = undefined;
        const size = c.strxfrm_l(&unused, ztext, 0, self.handle);
        if (size == std.math.maxInt(usize)) return error.OutOfMemory;
        const result = try allocator.alloc(u8, size + 1);
        errdefer allocator.free(result);
        if (c.strxfrm_l(result.ptr, ztext, result.len, self.handle) != size) return error.InvalidCollation;
        // Keep the allocation's terminating byte in the slice. It is equal
        // for every key and lets ordinary allocators free the exact length.
        return result;
    }
};

/// Equal collation weights use the original bytes and full path, giving
/// distinct files a repeatable order across readdir and refreshes.
pub fn order(a_key: []const u8, b_key: []const u8, a: []const u8, b: []const u8, a_path: []const u8, b_path: []const u8) std.math.Order {
    const weights = std.mem.order(u8, a_key, b_key);
    if (weights != .eq) return weights;
    const names = std.mem.order(u8, a, b);
    return if (names != .eq) names else std.mem.order(u8, a_path, b_path);
}

const Fixture = struct { text: []const u8, key: []const u8 };

fn checkOrder(locale_name: []const u8, expected: []const []const u8) !void {
    var locale = Locale.init(locale_name) orelse {
        std.debug.print("SKIP Files collation: locale {s} is not installed\n", .{locale_name});
        return error.SkipZigTest;
    };
    defer locale.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try arena.allocator().alloc(Fixture, expected.len);
    for (expected, 0..) |text, i| entries[expected.len - 1 - i] = .{ .text = text, .key = try locale.key(arena.allocator(), text) };
    std.mem.sort(Fixture, entries, {}, struct {
        fn less(_: void, a: Fixture, b: Fixture) bool {
            return order(a.key, b.key, a.text, b.text, a.text, b.text) == .lt;
        }
    }.less);
    for (entries, expected) |entry, text| try std.testing.expectEqualStrings(text, entry.text);
}

test "C name collation preserves byte order for a mixed name list" {
    try checkOrder("C", &.{ "Apfel", "Zebra", "apple", "Äpfel", "Élan", "Ёж", "Ель", "Яблоко" });
}

/// The expected orders are glibc's. FreeBSD's tables differ (see
/// docs/plans/freebsd.md); there `strxfrm_l` still agrees with `strcoll_l`.
fn needsGlibcTables() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
}

test "German name collation places accented names beside their base letters" {
    try needsGlibcTables();
    try checkOrder("de_DE.UTF-8", &.{ "Apfel", "Äpfel", "apple", "Élan", "Zebra", "Ёж", "Ель", "Яблоко" });
}

test "Russian name collation orders Cyrillic names and yo with ye" {
    try needsGlibcTables();
    try checkOrder("ru_RU.UTF-8", &.{ "Apfel", "Äpfel", "apple", "Élan", "Zebra", "Еж", "Ёж", "Ель", "Яблоко" });
}

test "name collation accepts invalid UTF-8 and keeps deterministic ties" {
    var locale = Locale.init("C").?;
    defer locale.deinit();
    const invalid = try locale.key(std.testing.allocator, "invalid\xff");
    defer std.testing.allocator.free(invalid);
    try std.testing.expectEqualStrings("invalid\xff", invalid);
    try std.testing.expectEqual(std.math.Order.lt, order("same", "same", "name", "name", "/a/name", "/b/name"));
    try std.testing.expect(Locale.init("bad\x00locale") == null);
    try std.testing.expect(Locale.init("no_such_REDIWM_locale") == null);
}

test "Files collation preferences override environment with LC_COLLATE fallback" {
    const env: std.process.Environ = .{ .block = .{ .slice = &.{ "LANG=ru_RU.UTF-8", "LC_COLLATE=de_DE.UTF-8", "LC_ALL=C" } } };
    try std.testing.expectEqualStrings("fr_FR.UTF-8", Locale.requested("fr_FR.UTF-8", env));
    try std.testing.expectEqualStrings("C", Locale.requested("", env));
    const category_env: std.process.Environ = .{ .block = .{ .slice = &.{ "LANG=ru_RU.UTF-8", "LC_COLLATE=de_DE.UTF-8", "LC_ALL=" } } };
    try std.testing.expectEqualStrings("de_DE.UTF-8", Locale.requested("", category_env));
    const language_env: std.process.Environ = .{ .block = .{ .slice = &.{"LANG=ru_RU.UTF-8"} } };
    try std.testing.expectEqualStrings("ru_RU.UTF-8", Locale.requested("", language_env));
    var fallback = Locale.fromPreferences("no_such_REDIWM_locale", .empty);
    defer fallback.deinit();
    try std.testing.expectEqualStrings("C", fallback.name());
}
