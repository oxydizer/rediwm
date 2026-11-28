//! Minimal edits to the command registry in config.toml.
const std = @import("std");
const theme = @import("ui").theme;
const section = "[shortcut_commands]";

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

pub fn patch(a: std.mem.Allocator, original: []const u8, id: []const u8, command: ?[]const u8) ![]u8 {
    if (!validId(id)) return error.InvalidId;
    const encoded = if (command) |value| try std.json.Stringify.valueAlloc(a, value, .{}) else null;
    defer if (encoded) |value| a.free(value);

    var in_section = false;
    var section_body: ?usize = null;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |raw| {
        const start = offset;
        offset += raw.len + @as(usize, @intFromBool(lines.index != null));
        const left_trimmed = std.mem.trimStart(u8, raw, " \t");
        const indent = raw.len - left_trimmed.len;
        const clean = theme.stripComment(std.mem.trimEnd(u8, left_trimmed, " \t\r"));
        if (std.mem.startsWith(u8, clean, "[")) {
            in_section = std.mem.eql(u8, clean, section);
            if (in_section and section_body == null) section_body = offset;
            continue;
        }
        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, clean, '=') orelse continue;
        const raw_key = std.mem.trimEnd(u8, clean[0..eq], " \t");
        const key = theme.unquote(raw_key) catch raw_key;
        if (!std.mem.eql(u8, key, id)) continue;

        if (encoded) |value| {
            const value_start = clean.len - std.mem.trimStart(u8, clean[eq + 1 ..], " \t").len;
            return std.mem.concat(a, u8, &.{
                original[0 .. start + indent + value_start],
                value,
                original[start + indent + clean.len ..],
            });
        }
        const tail = left_trimmed[clean.len..];
        if (std.mem.indexOfScalar(u8, tail, '#')) |hash| {
            return std.mem.concat(a, u8, &.{
                original[0 .. start + indent],
                original[start + indent + clean.len + hash ..],
            });
        }
        return std.mem.concat(a, u8, &.{ original[0..start], original[offset..] });
    }

    const value = encoded orelse return a.dupe(u8, original);
    const at = section_body orelse original.len;
    const newline = if (at != 0 and original[at - 1] != '\n') "\n" else "";
    return std.mem.concat(a, u8, &.{
        original[0..at],
        newline,
        if (section_body == null) section ++ "\n" else "",
        id,
        " = ",
        value,
        "\n",
        original[at..],
    });
}

test "custom command table edits preserve comments and unrelated settings" {
    const a = std.testing.allocator;
    const original = "# keep\n[input]\npointer_speed = 0.4\n";
    const added = try patch(a, original, "command-1", "echo \"hi\"\\");
    defer a.free(added);
    try std.testing.expectEqualStrings(original ++ section ++ "\ncommand-1 = \"echo \\\"hi\\\"\\\\\"\n", added);

    const before = section ++ " # section\n  \"command-1\"  =  \"echo hello\"  # command\nother = \"stay\"\n" ++ original;
    const edited = try patch(a, before, "command-1", "echo \"# hi\"");
    defer a.free(edited);
    try std.testing.expectEqualStrings(section ++ " # section\n  \"command-1\"  =  \"echo \\\"# hi\\\"\"  # command\nother = \"stay\"\n" ++ original, edited);
    const removed = try patch(a, edited, "command-1", null);
    defer a.free(removed);
    try std.testing.expectEqualStrings(section ++ " # section\n  # command\nother = \"stay\"\n" ++ original, removed);
}
