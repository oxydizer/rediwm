// Parsing and data types for [[sandbox_allow]] configuration.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SandboxGroup = enum {
    capture,
    windows,
    clipboard,
    input,
    input_method,
    outputs,
    lock,
    layer_shell,
    idle,
    ipc,
    automation,
};

pub const GroupSet = std.EnumSet(SandboxGroup);

const log = std.log.scoped(.config);

pub const SandboxAllowRule = struct {
    app_id: []const u8 = "",
    engine: ?[]const u8 = null,
    allow: GroupSet = GroupSet.initEmpty(),
};

pub fn parseGroup(str: []const u8) ?SandboxGroup {
    return std.meta.stringToEnum(SandboxGroup, str);
}

fn stripQuotes(str: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

pub fn applyKey(
    rule: *SandboxAllowRule,
    allocator: Allocator,
    key: []const u8,
    value: []const u8,
    path: []const u8,
    line_no: usize,
) !void {
    if (std.mem.eql(u8, key, "app_id")) {
        const unquoted = stripQuotes(value);
        rule.app_id = try allocator.dupe(u8, unquoted);
    } else if (std.mem.eql(u8, key, "engine")) {
        const unquoted = stripQuotes(value);
        rule.engine = try allocator.dupe(u8, unquoted);
    } else if (std.mem.eql(u8, key, "allow")) {
        try parseAllowField(&rule.allow, value, path, line_no);
    } else {
        return error.UnknownField;
    }
}

pub fn parseAllowField(
    allow: *GroupSet,
    value: []const u8,
    path: []const u8,
    line_no: usize,
) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return;

    if (trimmed[0] == '[') {
        // Array of strings, e.g. ["capture", "windows"]
        const inner = if (trimmed[trimmed.len - 1] == ']') trimmed[1 .. trimmed.len - 1] else trimmed[1..];
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |item| {
            const raw = stripQuotes(item);
            if (raw.len == 0) continue;
            if (parseGroup(raw)) |group| {
                allow.insert(group);
            } else {
                log.warn("{s}:{d}: (warn): unknown sandbox_allow group '{s}'", .{ path, line_no, raw });
            }
        }
    } else {
        // Single string, e.g. "capture"
        const raw = stripQuotes(trimmed);
        if (raw.len > 0) {
            if (parseGroup(raw)) |group| {
                allow.insert(group);
            } else {
                log.warn("{s}:{d}: (warn): unknown sandbox_allow group '{s}'", .{ path, line_no, raw });
            }
        }
    }
}

test "sandbox_allow parsing and group matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var rule = SandboxAllowRule{};
    try applyKey(&rule, a, "app_id", "\"com.obsproject.Studio\"", "test.toml", 1);
    try applyKey(&rule, a, "engine", "\"org.flatpak\"", "test.toml", 2);
    try applyKey(&rule, a, "allow", "[\"capture\", \"clipboard\", \"invalid_group\"]", "test.toml", 3);

    try std.testing.expectEqualStrings("com.obsproject.Studio", rule.app_id);
    try std.testing.expectEqualStrings("org.flatpak", rule.engine.?);
    try std.testing.expect(rule.allow.contains(.capture));
    try std.testing.expect(rule.allow.contains(.clipboard));
    try std.testing.expect(!rule.allow.contains(.windows));

    // Single string allow
    var rule2 = SandboxAllowRule{};
    try applyKey(&rule2, a, "app_id", "org.example.App", "test.toml", 4);
    try applyKey(&rule2, a, "allow", "\"ipc\"", "test.toml", 5);
    try std.testing.expectEqualStrings("org.example.App", rule2.app_id);
    try std.testing.expect(rule2.allow.contains(.ipc));
    try std.testing.expect(!rule2.allow.contains(.automation));
}
