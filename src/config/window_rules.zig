// Window rules configuration: data types, glob matching, TOML rule parsing, and resolution.
const std = @import("std");
const Allocator = std.mem.Allocator;
const theme_mod = @import("ui").theme;

const log = std.log.scoped(.config);

pub const max_rules = 256;
pub const max_pattern_bytes = 512;

pub const Backend = enum {
    xdg,
    xwayland,

    pub fn parse(str: []const u8) !Backend {
        return std.meta.stringToEnum(Backend, str) orelse error.InvalidBackend;
    }

    pub fn asString(self: Backend) []const u8 {
        return @tagName(self);
    }
};

pub const DecorationMode = enum {
    auto,
    server,
    client,

    pub fn parse(str: []const u8) !DecorationMode {
        return std.meta.stringToEnum(DecorationMode, str) orelse error.InvalidDecorationMode;
    }

    pub fn asString(self: DecorationMode) []const u8 {
        return @tagName(self);
    }
};

pub const WindowRule = struct {
    // Matchers (AND across different keys, OR across elements of slice)
    app_id: ?[]const []const u8 = null,
    title: ?[]const []const u8 = null,
    tag: ?[]const []const u8 = null,
    x11_class: ?[]const []const u8 = null,
    x11_instance: ?[]const []const u8 = null,
    backend: ?Backend = null,
    dialog: ?bool = null,

    // Exclusions
    exclude_app_id: ?[]const []const u8 = null,
    exclude_title: ?[]const []const u8 = null,
    exclude_x11_class: ?[]const []const u8 = null,
    exclude_x11_instance: ?[]const []const u8 = null,

    // Open-time properties
    output: ?[]const u8 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    center: ?bool = null,
    width: ?u32 = null,
    height: ?u32 = null,
    maximized: ?bool = null,
    fullscreen: ?bool = null,
    focus: ?bool = null,
    depth: ?u8 = null,

    // Live properties
    opacity: ?f32 = null,
    decorations: ?DecorationMode = null,
    skip_taskbar: ?bool = null,

    pub fn hasProperties(self: WindowRule) bool {
        return self.output != null or
            self.x != null or
            self.y != null or
            self.center != null or
            self.width != null or
            self.height != null or
            self.maximized != null or
            self.fullscreen != null or
            self.focus != null or
            self.depth != null or
            self.opacity != null or
            self.decorations != null or
            self.skip_taskbar != null;
    }

    pub fn hasMatchers(self: WindowRule) bool {
        return self.app_id != null or
            self.title != null or
            self.tag != null or
            self.x11_class != null or
            self.x11_instance != null or
            self.backend != null or
            self.dialog != null or
            self.exclude_app_id != null or
            self.exclude_title != null or
            self.exclude_x11_class != null or
            self.exclude_x11_instance != null;
    }
};

pub const WindowIdentity = struct {
    app_id: []const u8 = "",
    title: []const u8 = "",
    tag: []const u8 = "",
    x11_class: []const u8 = "",
    x11_instance: []const u8 = "",
    backend: Backend = .xdg,
    dialog: bool = false,
};

pub const Resolved = struct {
    output: ?[]const u8 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    center: ?bool = null,
    width: ?u32 = null,
    height: ?u32 = null,
    maximized: ?bool = null,
    fullscreen: ?bool = null,
    focus: ?bool = null,
    depth: ?u8 = null,
    opacity: ?f32 = null,
    decorations: ?DecorationMode = null,
    skip_taskbar: ?bool = null,
    matched_rules: std.StaticBitSet(max_rules) = std.StaticBitSet(max_rules).initEmpty(),
};

pub const OpenRules = struct {
    output: ?[64]u8 = null,
    output_len: u8 = 0,
    x: ?i32 = null,
    y: ?i32 = null,
    center: ?bool = null,
    width: ?u32 = null,
    height: ?u32 = null,
    maximized: ?bool = null,
    fullscreen: ?bool = null,
    focus: ?bool = null,
    depth: ?u8 = null,

    // The returned slice borrows the snapshot's storage, never a value copy.
    pub fn getOutput(self: *const OpenRules) ?[]const u8 {
        if (self.output) |*buf| {
            return buf[0..self.output_len];
        }
        return null;
    }

    pub fn hasPositionRule(self: OpenRules) bool {
        return (self.center orelse false) or self.x != null or self.y != null;
    }

    pub fn eql(self: OpenRules, other: OpenRules) bool {
        if (self.x != other.x or self.y != other.y or self.center != other.center) return false;
        if (self.width != other.width or self.height != other.height) return false;
        if (self.maximized != other.maximized or self.fullscreen != other.fullscreen) return false;
        if (self.focus != other.focus or self.depth != other.depth) return false;
        const o1 = self.getOutput();
        const o2 = other.getOutput();
        if ((o1 == null) != (o2 == null)) return false;
        if (o1) |s1| {
            if (!std.mem.eql(u8, s1, o2.?)) return false;
        }
        return true;
    }

    pub fn fromResolved(resolved: Resolved) OpenRules {
        var res = OpenRules{
            .x = resolved.x,
            .y = resolved.y,
            .center = resolved.center,
            .width = resolved.width,
            .height = resolved.height,
            .maximized = resolved.maximized,
            .fullscreen = resolved.fullscreen,
            .focus = resolved.focus,
            .depth = resolved.depth,
        };
        if (resolved.output) |out| {
            var buf: [64]u8 = undefined;
            const len: u8 = @intCast(@min(buf.len, out.len));
            @memcpy(buf[0..len], out[0..len]);
            res.output = buf;
            res.output_len = len;
        }
        return res;
    }
};

pub const LiveRules = struct {
    opacity: ?f32 = null,
    decorations: ?DecorationMode = null,
    skip_taskbar: ?bool = null,

    pub fn fromResolved(resolved: Resolved) LiveRules {
        return .{
            .opacity = resolved.opacity,
            .decorations = resolved.decorations,
            .skip_taskbar = resolved.skip_taskbar,
        };
    }
};

/// UTF-8 sequence length helper. In case of invalid UTF-8 in text, treat as 1 byte.
fn utf8CharLen(b: u8) usize {
    return std.unicode.utf8ByteSequenceLength(b) catch 1;
}

/// Matches case-sensitive whole-string glob patterns.
/// '*' matches any run of characters (including empty).
/// '?' matches exactly one UTF-8 codepoint.
pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;

    while (s < text.len) {
        if (p < pattern.len and pattern[p] == '?') {
            const len = utf8CharLen(text[s]);
            s += len;
            p += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            p += 1;
            star_s = s;
        } else if (p < pattern.len and pattern[p] == text[s]) {
            p += 1;
            s += 1;
        } else if (star_p) |sp| {
            p = sp + 1;
            star_s += utf8CharLen(text[star_s]);
            s = star_s;
        } else {
            return false;
        }
    }

    while (p < pattern.len and pattern[p] == '*') {
        p += 1;
    }

    return p == pattern.len and s == text.len;
}

fn matchAnyPattern(patterns: []const []const u8, target: []const u8) bool {
    for (patterns) |pat| {
        if (matchGlob(pat, target)) return true;
    }
    return false;
}

pub fn matchesRule(rule: WindowRule, id: WindowIdentity) bool {
    // Exclusions: if any exclude pattern matches, rule is rejected.
    if (rule.exclude_app_id) |pats| {
        if (matchAnyPattern(pats, id.app_id)) return false;
    }
    if (rule.exclude_title) |pats| {
        if (matchAnyPattern(pats, id.title)) return false;
    }
    if (rule.exclude_x11_class) |pats| {
        if (matchAnyPattern(pats, id.x11_class)) return false;
    }
    if (rule.exclude_x11_instance) |pats| {
        if (matchAnyPattern(pats, id.x11_instance)) return false;
    }

    // Matchers: all specified matchers must match.
    if (rule.backend) |b| {
        if (b != id.backend) return false;
    }
    if (rule.dialog) |d| {
        if (d != id.dialog) return false;
    }
    if (rule.app_id) |pats| {
        if (!matchAnyPattern(pats, id.app_id)) return false;
    }
    if (rule.title) |pats| {
        if (!matchAnyPattern(pats, id.title)) return false;
    }
    if (rule.x11_class) |pats| {
        if (!matchAnyPattern(pats, id.x11_class)) return false;
    }
    if (rule.tag) |pats| {
        if (!matchAnyPattern(pats, id.tag)) return false;
    }
    if (rule.x11_instance) |pats| {
        if (!matchAnyPattern(pats, id.x11_instance)) return false;
    }

    return true;
}

pub fn resolve(rules: []const WindowRule, id: WindowIdentity) Resolved {
    var res = Resolved{};

    for (rules, 0..) |rule, i| {
        if (!matchesRule(rule, id)) continue;

        if (i < max_rules) res.matched_rules.set(i);

        if (rule.output) |out| res.output = out;

        if (rule.center != null) {
            res.center = rule.center;
            res.x = null;
            res.y = null;
        }
        if (rule.x != null) {
            res.x = rule.x;
            res.center = null;
        }
        if (rule.y != null) {
            res.y = rule.y;
            res.center = null;
        }

        if (rule.width != null) res.width = rule.width;
        if (rule.height != null) res.height = rule.height;
        if (rule.maximized != null) res.maximized = rule.maximized;
        if (rule.fullscreen != null) res.fullscreen = rule.fullscreen;
        if (rule.focus != null) res.focus = rule.focus;
        if (rule.depth != null) res.depth = rule.depth;

        if (rule.opacity != null) res.opacity = rule.opacity;
        if (rule.decorations != null) res.decorations = rule.decorations;
        if (rule.skip_taskbar != null) res.skip_taskbar = rule.skip_taskbar;
    }

    // Across rules, fullscreen wins over maximized if fullscreen is true.
    if (res.fullscreen orelse false) {
        res.maximized = false;
    }

    return res;
}

/// Parses a string or a quote-aware single-line array of strings:
/// e.g. "foot" or ["firefox", "chromium"] or ["Save, as", "Open"]
pub fn parseStringOrArray(allocator: Allocator, value: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len == 0) return error.InvalidValue;

    if (trimmed[0] == '[') {
        if (trimmed[trimmed.len - 1] != ']') return error.InvalidValue;
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r");
        if (inner.len == 0) return allocator.dupe([]const u8, &.{});

        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }

        var in_quotes = false;
        var start: usize = 0;
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            const c = inner[i];
            if (c == '"') {
                in_quotes = !in_quotes;
            } else if (c == ',' and !in_quotes) {
                const raw_item = std.mem.trim(u8, inner[start..i], " \t\r");
                const item = try parseQuotedPattern(allocator, raw_item);
                try list.append(allocator, item);
                start = i + 1;
            }
        }
        if (in_quotes) return error.InvalidValue;
        const last_raw = std.mem.trim(u8, inner[start..], " \t\r");
        if (last_raw.len > 0) {
            const item = try parseQuotedPattern(allocator, last_raw);
            try list.append(allocator, item);
        }
        return list.toOwnedSlice(allocator);
    } else {
        const item = try parseQuotedPattern(allocator, trimmed);
        const slice = try allocator.alloc([]const u8, 1);
        slice[0] = item;
        return slice;
    }
}

fn parseQuotedPattern(allocator: Allocator, value: []const u8) ![]const u8 {
    const unquoted = try theme_mod.unquote(value);
    if (unquoted.len > max_pattern_bytes) return error.PatternTooLong;
    return allocator.dupe(u8, unquoted);
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidValue;
}

pub fn applyRuleKey(rule: *WindowRule, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "app_id")) {
        rule.app_id = try parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "tag")) {
        rule.tag = try parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "title")) {
        rule.title = try parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "x11_class")) {
        rule.x11_class = try parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "x11_instance")) {
        rule.x11_instance = try parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "backend")) {
        const str = try theme_mod.unquote(value);
        rule.backend = try Backend.parse(str);
    } else if (std.mem.eql(u8, key, "dialog")) {
        rule.dialog = try parseBool(value);
    } else if (std.mem.eql(u8, key, "exclude_app_id")) {
        rule.exclude_app_id = try parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "exclude_title")) {
        rule.exclude_title = try parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "exclude_x11_class")) {
        rule.exclude_x11_class = try parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "exclude_x11_instance")) {
        rule.exclude_x11_instance = try parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "output")) {
        rule.output = try allocator.dupe(u8, try theme_mod.unquote(value));
    } else if (std.mem.eql(u8, key, "x")) {
        if (rule.center != null) return error.ConflictingRuleKeys;
        rule.x = try std.fmt.parseInt(i32, value, 10);
    } else if (std.mem.eql(u8, key, "y")) {
        if (rule.center != null) return error.ConflictingRuleKeys;
        rule.y = try std.fmt.parseInt(i32, value, 10);
    } else if (std.mem.eql(u8, key, "center")) {
        if (rule.x != null or rule.y != null) return error.ConflictingRuleKeys;
        rule.center = try parseBool(value);
    } else if (std.mem.eql(u8, key, "width")) {
        const w = try std.fmt.parseInt(u32, value, 10);
        if (w < 1 or w > 100_000) return error.InvalidValue;
        rule.width = w;
    } else if (std.mem.eql(u8, key, "height")) {
        const h = try std.fmt.parseInt(u32, value, 10);
        if (h < 1 or h > 100_000) return error.InvalidValue;
        rule.height = h;
    } else if (std.mem.eql(u8, key, "maximized")) {
        if (rule.fullscreen != null) return error.ConflictingRuleKeys;
        rule.maximized = try parseBool(value);
    } else if (std.mem.eql(u8, key, "fullscreen")) {
        if (rule.maximized != null) return error.ConflictingRuleKeys;
        rule.fullscreen = try parseBool(value);
    } else if (std.mem.eql(u8, key, "focus")) {
        rule.focus = try parseBool(value);
    } else if (std.mem.eql(u8, key, "depth")) {
        const d = try std.fmt.parseInt(u32, value, 10);
        if (d > 255) return error.InvalidValue;
        rule.depth = @intCast(d);
    } else if (std.mem.eql(u8, key, "opacity")) {
        const op = try std.fmt.parseFloat(f32, value);
        if (!std.math.isFinite(op) or op < 0 or op > 1) return error.InvalidValue;
        rule.opacity = op;
    } else if (std.mem.eql(u8, key, "decorations")) {
        const str = try theme_mod.unquote(value);
        rule.decorations = try DecorationMode.parse(str);
    } else if (std.mem.eql(u8, key, "skip_taskbar")) {
        rule.skip_taskbar = try parseBool(value);
    } else {
        return error.UnknownKey;
    }
}

// --- Unit tests ---

test "glob matching: exact, wildcards, utf-8" {
    // Empty pattern
    try std.testing.expect(matchGlob("", ""));
    try std.testing.expect(!matchGlob("", "a"));

    // Lone *
    try std.testing.expect(matchGlob("*", ""));
    try std.testing.expect(matchGlob("*", "anything"));
    try std.testing.expect(matchGlob("***", "anything"));

    // Trailing ?
    try std.testing.expect(matchGlob("test?", "tests"));
    try std.testing.expect(!matchGlob("test?", "test"));
    try std.testing.expect(!matchGlob("test?", "testss"));

    // Exact match
    try std.testing.expect(matchGlob("firefox", "firefox"));
    try std.testing.expect(!matchGlob("firefox", "Firefox"));
    try std.testing.expect(!matchGlob("firefox", "firefox1"));

    // Substring with *
    try std.testing.expect(matchGlob("*Firefox*", "Mozilla Firefox Nightly"));
    try std.testing.expect(!matchGlob("*Firefox*", "Chrome"));

    // Multibyte UTF-8
    try std.testing.expect(matchGlob("Caf?", "Café"));
    try std.testing.expect(matchGlob("?本語", "日本語"));
    try std.testing.expect(!matchGlob("?本語", "日本語x"));
    try std.testing.expect(matchGlob("*語", "日本語"));
    try std.testing.expect(matchGlob("日*", "日本語"));

    // Patterns longer than input
    try std.testing.expect(!matchGlob("verylongpattern", "short"));
    try std.testing.expect(!matchGlob("a?b", "a"));

    // Multiple stars and interleaving
    try std.testing.expect(matchGlob("*a*b*c*", "123a456b789c0"));
    try std.testing.expect(matchGlob("a*b?c", "aXXbYc"));
    try std.testing.expect(!matchGlob("a*b?c", "aXXbc"));
}

test "parseStringOrArray with single string and comma array" {
    const a = std.testing.allocator;

    const single = try parseStringOrArray(a, "\"firefox\"");
    defer {
        for (single) |s| a.free(s);
        a.free(single);
    }
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqualStrings("firefox", single[0]);

    const arr = try parseStringOrArray(a, "[\"Save, as\", \"Open file\"]");
    defer {
        for (arr) |s| a.free(s);
        a.free(arr);
    }
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("Save, as", arr[0]);
    try std.testing.expectEqualStrings("Open file", arr[1]);
}

test "window rule matching and last-match-wins resolution" {
    const a = std.testing.allocator;

    var r1 = WindowRule{};
    try applyRuleKey(&r1, a, "app_id", "[\"firefox\", \"chromium\"]");
    defer {
        for (r1.app_id.?) |s| a.free(s);
        a.free(r1.app_id.?);
    }
    try applyRuleKey(&r1, a, "opacity", "0.9");
    try applyRuleKey(&r1, a, "width", "800");

    var r2 = WindowRule{};
    try applyRuleKey(&r2, a, "title", "\"*Picture-in-Picture*\"");
    defer {
        for (r2.title.?) |s| a.free(s);
        a.free(r2.title.?);
    }
    try applyRuleKey(&r2, a, "opacity", "0.8");
    try applyRuleKey(&r2, a, "skip_taskbar", "true");

    var r3 = WindowRule{};
    try applyRuleKey(&r3, a, "exclude_app_id", "\"chromium\"");
    defer {
        for (r3.exclude_app_id.?) |s| a.free(s);
        a.free(r3.exclude_app_id.?);
    }
    try applyRuleKey(&r3, a, "focus", "false");

    // Client tags use the same glob semantics, ANDed with other matchers.
    const tagged = WindowRule{ .app_id = &.{"firefox"}, .tag = &.{"settings*"} };
    try std.testing.expect(matchesRule(tagged, .{ .app_id = "firefox", .tag = "settings-dialog" }));
    try std.testing.expect(!matchesRule(tagged, .{ .app_id = "firefox", .tag = "main" }));
    try std.testing.expect(!matchesRule(tagged, .{ .app_id = "chromium", .tag = "settings" }));

    const rules = [_]WindowRule{ r1, r2, r3 };

    // Test window 1: firefox PiP
    const id1 = WindowIdentity{
        .app_id = "firefox",
        .title = "Picture-in-Picture",
        .backend = .xdg,
    };
    const res1 = resolve(&rules, id1);
    try std.testing.expectEqual(@as(?f32, 0.8), res1.opacity); // r2 overrode r1
    try std.testing.expectEqual(@as(?u32, 800), res1.width); // r1
    try std.testing.expectEqual(@as(?bool, true), res1.skip_taskbar); // r2
    try std.testing.expectEqual(@as(?bool, false), res1.focus); // r3 matched
    try std.testing.expect(res1.matched_rules.isSet(0));
    try std.testing.expect(res1.matched_rules.isSet(1));
    try std.testing.expect(res1.matched_rules.isSet(2));

    // Test window 2: chromium PiP (r3 excluded)
    const id2 = WindowIdentity{
        .app_id = "chromium",
        .title = "Picture-in-Picture",
        .backend = .xdg,
    };
    const res2 = resolve(&rules, id2);
    try std.testing.expectEqual(@as(?f32, 0.8), res2.opacity);
    try std.testing.expectEqual(@as(?bool, null), res2.focus); // r3 excluded because exclude_app_id matches chromium
    try std.testing.expect(!res2.matched_rules.isSet(2));
}

test "validation errors" {
    const a = std.testing.allocator;
    var rule = WindowRule{};

    // Unknown key
    try std.testing.expectError(error.UnknownKey, applyRuleKey(&rule, a, "invalid_key", "\"val\""));

    // Opacity bounds
    try std.testing.expectError(error.InvalidValue, applyRuleKey(&rule, a, "opacity", "1.5"));
    try std.testing.expectError(error.InvalidValue, applyRuleKey(&rule, a, "opacity", "-0.1"));
    try std.testing.expectError(error.InvalidValue, applyRuleKey(&rule, a, "opacity", "nan"));

    // Width / height bounds
    try std.testing.expectError(error.InvalidValue, applyRuleKey(&rule, a, "width", "0"));
    try std.testing.expectError(error.InvalidValue, applyRuleKey(&rule, a, "width", "100001"));

    // Depth bounds
    try std.testing.expectError(error.InvalidValue, applyRuleKey(&rule, a, "depth", "256"));

    // Conflict: center with x/y
    var r_center = WindowRule{};
    try applyRuleKey(&r_center, a, "center", "true");
    try std.testing.expectError(error.ConflictingRuleKeys, applyRuleKey(&r_center, a, "x", "50"));

    var r_xy = WindowRule{};
    try applyRuleKey(&r_xy, a, "y", "50");
    try std.testing.expectError(error.ConflictingRuleKeys, applyRuleKey(&r_xy, a, "center", "true"));

    // Conflict: maximized with fullscreen
    var r_max = WindowRule{};
    try applyRuleKey(&r_max, a, "maximized", "true");
    try std.testing.expectError(error.ConflictingRuleKeys, applyRuleKey(&r_max, a, "fullscreen", "true"));

    var r_fs = WindowRule{};
    try applyRuleKey(&r_fs, a, "fullscreen", "true");
    try std.testing.expectError(error.ConflictingRuleKeys, applyRuleKey(&r_fs, a, "maximized", "true"));

    // Unknown decorations or backend
    try std.testing.expectError(error.InvalidDecorationMode, applyRuleKey(&rule, a, "decorations", "\"invalid\""));
    try std.testing.expectError(error.InvalidBackend, applyRuleKey(&rule, a, "backend", "\"wayland\""));
}

test "open rules snapshot survives config deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const a = arena.allocator();

    var rule = WindowRule{};
    try applyRuleKey(&rule, a, "output", "\"DP-2\"");
    try applyRuleKey(&rule, a, "width", "900");
    try applyRuleKey(&rule, a, "height", "700");
    try applyRuleKey(&rule, a, "center", "true");

    const rules = [_]WindowRule{rule};
    const id = WindowIdentity{ .app_id = "test" };
    const res = resolve(&rules, id);

    const open_snapshot = OpenRules.fromResolved(res);
    const live_snapshot = LiveRules.fromResolved(res);

    // Free all config memory
    arena.deinit();

    // Read back values from snapshot
    try std.testing.expectEqualStrings("DP-2", open_snapshot.getOutput().?);
    try std.testing.expect(open_snapshot.getOutput().?.ptr == &open_snapshot.output.?);
    try std.testing.expectEqual(@as(?u32, 900), open_snapshot.width);
    try std.testing.expectEqual(@as(?u32, 700), open_snapshot.height);
    try std.testing.expectEqual(@as(?bool, true), open_snapshot.center);
    try std.testing.expectEqual(@as(?f32, null), live_snapshot.opacity);
}
