//! Config file editing: rewrite or splice one section of the TOML in place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const theme_mod = @import("ui").theme;
const Theme = theme_mod.Theme;
const log = @import("loader.zig").log;

pub const resolvePath = @import("path.zig").resolvePath;

/// Removes the obsolete `invert_scroll` setting from `[input]`, preserving
/// every other line. Returns null when the legacy key is absent.
pub fn removeLegacyInputKey(allocator: Allocator, original: []const u8) !?[]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var section: []const u8 = "";
    var removed = false;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |raw| {
        const end = @min(original.len, offset + raw.len + 1);
        const line = theme_mod.stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (std.mem.startsWith(u8, line, "[")) section = line;

        const eq = std.mem.indexOfScalar(u8, line, '=');
        const matches = std.mem.eql(u8, section, "[input]") and
            if (eq) |i|
                std.mem.eql(u8, std.mem.trim(u8, line[0..i], " \t\""), "invert_scroll")
            else
                false;

        if (matches) {
            removed = true;
        } else {
            try result.appendSlice(allocator, original[offset..end]);
        }
        offset = end;
    }

    if (!removed) {
        result.deinit(allocator);
        return null;
    }
    return try result.toOwnedSlice(allocator);
}

/// Rewrites the `[theme]` section of `path` in place, preserving every other
/// section and any leading comments. Used by the control center so appearance
/// edits don't clobber keybinds/input.
pub fn replaceThemeSection(allocator: Allocator, io: Io, path: []const u8, t: Theme) void {
    replaceThemeOverrides(allocator, io, path, t, .{}, "");
}

pub fn replaceThemeOverrides(allocator: Allocator, io: Io, path: []const u8, t: Theme, defaults: Theme, base: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    theme_mod.writeOverrides(allocator, &buf, t, defaults, base) catch return;
    rewriteSection(allocator, io, path, "[theme]", buf.items);
}

/// Rewrites `[taskbar_theme]` to `t`'s taskbar tokens, or drops the section
/// for null so the taskbar follows the main theme again.
pub fn replaceTaskbarThemeSection(allocator: Allocator, io: Io, path: []const u8, t: ?Theme) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    if (t) |tokens| theme_mod.writeTaskbarInto(allocator, &buf, tokens) catch return;
    rewriteSection(allocator, io, path, "[taskbar_theme]", if (t == null) null else buf.items);
}

/// Replaces the section starting with `header` by `body` (a whole section,
/// header line included), or removes it for null, leaving everything else as
/// it was. A section that is not there yet goes at the end.
pub fn rewriteSection(allocator: Allocator, io: Io, path: []const u8, header: []const u8, body: ?[]const u8) void {
    const existing = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch {
        const text = body orelse return;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch return;
        return;
    };
    defer allocator.free(existing);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    spliceSection(allocator, &out, existing, header, body) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch |err| {
        log.warn("rewrite '{s}' in '{s}': {}", .{ header, path, err });
    };
}

/// `rewriteSection` on text: appends `existing` to `out` with the section
/// replaced (or removed for a null `body`).
pub fn spliceSection(allocator: Allocator, out: *std.ArrayList(u8), existing: []const u8, header: []const u8, body: ?[]const u8) !void {
    var in_section = false;
    var replaced = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |raw| {
        // The piece after the file's final newline is not a line; keeping it
        // would add a blank line to the file on every save.
        if (raw.len == 0 and lines.peek() == null) break;
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            const is_section = std.mem.startsWith(u8, trimmed, header);
            in_section = false;
            if (is_section) {
                if (!replaced) {
                    if (body) |text| {
                        try out.appendSlice(allocator, text);
                        if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
                    }
                    replaced = true;
                }
                in_section = true;
                continue;
            }
        }
        if (in_section) continue;
        try out.appendSlice(allocator, raw);
        try out.append(allocator, '\n');
    }
    if (!replaced) {
        const text = body orelse return;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, text);
    }
}
