//! Configuration for rediwm-dm (/etc/rediwm/dm.conf).
//! Simple key = value syntax, parsed by the daemon itself without TOML dependencies.
const std = @import("std");

pub const Config = struct {
    vt: u32 = 1,
    greeter_user: []const u8 = "rediwm-greeter",
    greeter_command: []const u8 = "/usr/local/bin/rediwm --greeter",
    autologin_user: ?[]const u8 = null,
    autologin_session: ?[]const u8 = null,

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Config {
        var conf: Config = .{};
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            // Strip trailing inline comments if any
            if (std.mem.indexOfScalar(u8, line, '#')) |hash_idx| {
                line = std.mem.trim(u8, line[0..hash_idx], " \t\r");
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (val.len == 0) continue;

            if (std.mem.eql(u8, key, "vt")) {
                if (std.fmt.parseInt(u32, val, 10)) |v| {
                    if (v > 0 and v <= 63) conf.vt = v;
                } else |_| {}
            } else if (std.mem.eql(u8, key, "greeter_user")) {
                conf.greeter_user = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "greeter_command")) {
                conf.greeter_command = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "autologin_user")) {
                conf.autologin_user = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "autologin_session")) {
                conf.autologin_session = try allocator.dupe(u8, val);
            }
        }
        return conf;
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return Config{},
            else => return err,
        };
        defer allocator.free(bytes);
        return parse(allocator, bytes);
    }
};

/// Rewrites only the two automatic-login keys while preserving every other
/// line, including comments and settings this version does not understand.
/// Passing null for user clears both values.
pub fn rewriteAutologin(a: std.mem.Allocator, bytes: []const u8, user: ?[]const u8, session: ?[]const u8) ![]u8 {
    const selected_session = if (user != null) session else null;
    var output: std.ArrayList(u8) = .empty;
    var have_user = false;
    var have_session = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line_with_cr| {
        const line = if (std.mem.endsWith(u8, line_with_cr, "\r")) line_with_cr[0 .. line_with_cr.len - 1] else line_with_cr;
        if (!first) try output.append(a, '\n');
        first = false;
        const content = std.mem.trim(u8, line, " \t\r");
        const is_comment = content.len == 0 or content[0] == '#';
        const eq = if (is_comment) null else std.mem.indexOfScalar(u8, content, '=');
        if (eq) |index| {
            const key = std.mem.trim(u8, content[0..index], " \t");
            if (std.mem.eql(u8, key, "autologin_user")) {
                try appendAutoLine(a, &output, "autologin_user", user, line);
                have_user = true;
                continue;
            }
            if (std.mem.eql(u8, key, "autologin_session")) {
                try appendAutoLine(a, &output, "autologin_session", selected_session, line);
                have_session = true;
                continue;
            }
        }
        try output.appendSlice(a, line);
    }
    if (!have_user or !have_session) {
        if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') try output.append(a, '\n');
        if (!have_user) {
            try output.appendSlice(a, "autologin_user = ");
            if (user) |value| try output.appendSlice(a, value);
            if (!have_session) try output.append(a, '\n');
        }
        if (!have_session) {
            try output.appendSlice(a, "autologin_session = ");
            if (selected_session) |value| try output.appendSlice(a, value);
        }
    }
    return output.toOwnedSlice(a);
}

fn appendAutoLine(a: std.mem.Allocator, output: *std.ArrayList(u8), key: []const u8, value: ?[]const u8, original: []const u8) !void {
    try output.appendSlice(a, key);
    try output.appendSlice(a, " = ");
    if (value) |text| try output.appendSlice(a, text);
    if (std.mem.indexOfScalar(u8, original, '#')) |hash| {
        const before = std.mem.trimEnd(u8, original[0..hash], " \t");
        const spacing = original[before.len..hash];
        try output.appendSlice(a, spacing);
        try output.appendSlice(a, original[hash..]);
    }
}

test "default config values" {
    const conf = Config{};
    try std.testing.expectEqual(@as(u32, 1), conf.vt);
    try std.testing.expectEqualStrings("rediwm-greeter", conf.greeter_user);
    try std.testing.expectEqualStrings("/usr/local/bin/rediwm --greeter", conf.greeter_command);
    try std.testing.expect(conf.autologin_user == null);
    try std.testing.expect(conf.autologin_session == null);
}

test "parse sample config" {
    const input =
        \\# Sample dm.conf
        \\vt = 7 # graphic vt
        \\greeter_user = custom-greeter
        \\greeter_command = /opt/bin/greeter --opt
        \\autologin_user = alex
        \\autologin_session = rediwm
    ;
    const a = std.testing.allocator;
    const conf = try Config.parse(a, input);
    defer {
        a.free(conf.greeter_user);
        a.free(conf.greeter_command);
        a.free(conf.autologin_user.?);
        a.free(conf.autologin_session.?);
    }
    try std.testing.expectEqual(@as(u32, 7), conf.vt);
    try std.testing.expectEqualStrings("custom-greeter", conf.greeter_user);
    try std.testing.expectEqualStrings("/opt/bin/greeter --opt", conf.greeter_command);
    try std.testing.expectEqualStrings("alex", conf.autologin_user.?);
    try std.testing.expectEqualStrings("rediwm", conf.autologin_session.?);
}

test "parse ignores comments and empty values" {
    const input =
        \\# Comment only
        \\vt = invalid
        \\greeter_user =
        \\autologin_user = 
    ;
    const a = std.testing.allocator;
    const conf = try Config.parse(a, input);
    try std.testing.expectEqual(@as(u32, 1), conf.vt);
    try std.testing.expectEqualStrings("rediwm-greeter", conf.greeter_user);
    try std.testing.expect(conf.autologin_user == null);
}
