//! Direct argument parsing for managed custom shortcuts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Env = std.process.Environ.Map;

/// The returned arguments are owned by the caller's arena.
pub fn parse(a: Allocator, command: []const u8, env: *const Env) ![]const []const u8 {
    if (std.mem.indexOfAny(u8, command, "\x00\r\n") != null) return error.InvalidCommand;

    var argv: std.ArrayList([]const u8) = .empty;
    var arg: std.ArrayList(u8) = .empty;
    defer arg.deinit(a);
    var quote: enum { none, single, double } = .none;
    var started = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const ch = command[i];
        if (quote == .none and std.ascii.isWhitespace(ch)) {
            if (started) try appendArg(a, &argv, &arg);
            started = false;
            continue;
        }
        defer started = true;

        if (ch == '\'' and quote != .double) {
            quote = if (quote == .single) .none else .single;
        } else if (ch == '"' and quote != .single) {
            quote = if (quote == .double) .none else .double;
        } else if (ch == '\\' and quote != .single) {
            i += 1;
            if (i == command.len) return error.InvalidCommand;
            try arg.append(a, command[i]);
        } else if (ch == '$' and quote != .single) {
            try expandVariable(a, &arg, command, &i, env);
        } else if (ch == '~' and !started and quote == .none and
            (i + 1 == command.len or command[i + 1] == '/' or std.ascii.isWhitespace(command[i + 1])))
        {
            const home = env.get("HOME") orelse "";
            try arg.appendSlice(a, if (home.len == 0) "~" else home);
        } else {
            try arg.append(a, ch);
        }
    }
    if (quote != .none) return error.InvalidCommand;
    if (started) try appendArg(a, &argv, &arg);
    if (argv.items.len == 0 or argv.items[0].len == 0) return error.InvalidCommand;
    return argv.items;
}

fn appendArg(a: Allocator, argv: *std.ArrayList([]const u8), arg: *std.ArrayList(u8)) !void {
    try argv.append(a, try a.dupe(u8, arg.items));
    arg.clearRetainingCapacity();
}

fn nameStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn expandVariable(a: Allocator, arg: *std.ArrayList(u8), command: []const u8, pos: *usize, env: *const Env) !void {
    const after_dollar = pos.* + 1;
    const braced = after_dollar < command.len and command[after_dollar] == '{';
    const start = after_dollar + @as(usize, @intFromBool(braced));
    if (start == command.len or !nameStart(command[start])) {
        if (braced) return error.InvalidCommand;
        return arg.append(a, '$');
    }
    var end = start + 1;
    while (end < command.len and (nameStart(command[end]) or std.ascii.isDigit(command[end]))) : (end += 1) {}
    if (braced and (end == command.len or command[end] != '}')) return error.InvalidCommand;
    pos.* = if (braced) end else end - 1;
    try arg.appendSlice(a, env.get(command[start..end]) orelse "");
}

test "command arguments keep quotes, expansions, and literal shell operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    defer env.deinit();
    try env.put("HOME", "/home/Test User");
    try env.put("WORD", "two words");
    const argv = try parse(a,
        \\"/some path/prog" "" one\ two prefix"${WORD}" '$WORD' ~/here "~" $MISSING ; $
    , &env);
    const expected = [_][]const u8{ "/some path/prog", "", "one two", "prefixtwo words", "$WORD", "/home/Test User/here", "~", "", ";", "$" };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try std.testing.expectEqualStrings(want, got);

    const shell = try parse(a, "sh -c 'printf \"%s\" \"$WORD\" > output'", &env);
    try std.testing.expectEqual(@as(usize, 3), shell.len);
    try std.testing.expectEqualStrings("sh", shell[0]);
    try std.testing.expectEqualStrings("-c", shell[1]);
    try std.testing.expectEqualStrings("printf \"%s\" \"$WORD\" > output", shell[2]);
}

test "invalid command syntax and an empty executable are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    defer env.deinit();
    for ([_][]const u8{ "", "\t ", "'' arg", "$MISSING", "a 'unfinished", "a \\", "a $\x00", "a\nb", "a ${BAD-NAME}", "a ${WORD" }) |bad| {
        try std.testing.expectError(error.InvalidCommand, parse(a, bad, &env));
    }
    try std.testing.expectEqualStrings("~", (try parse(a, "a ~", &env))[1]);
}
