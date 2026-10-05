//! Persist the effective bindings, including inherited defaults. A noop at the
//! previous key prevents the loader from restoring an inherited hardware bind.
const std = @import("std");
const loader = @import("loader.zig");
const keys = @import("keybinds.zig");
extern fn xkb_keysym_get_name(u32, [*]u8, usize) c_int;

pub fn format(a: std.mem.Allocator, bind: keys.Keybind) ![]const u8 {
    var name: [128]u8 = undefined;
    const n = xkb_keysym_get_name(@intFromEnum(bind.sym), &name, name.len);
    if (n <= 0) return error.InvalidKeybind;
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ if (bind.modifiers.logo) "Super+" else "", if (bind.modifiers.ctrl) "Ctrl+" else "", if (bind.modifiers.alt) "Alt+" else "", if (bind.modifiers.shift) "Shift+" else "", name[0..@intCast(n)] });
}

pub fn patch(a: std.mem.Allocator, original: []const u8, binds: []const keys.Keybind, index: usize, replacement: keys.Keybind) ![]u8 {
    var defaults = try loader.parse(a, "[keybinds]\n", "shortcut-defaults");
    defer defaults.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var in_section = false;
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "[")) {
            in_section = std.mem.eql(u8, @import("ui").theme.stripComment(trimmed), "[keybinds]");
            if (in_section) continue;
        }
        if (in_section and trimmed.len > 0 and trimmed[0] != '#') {
            const content = @import("ui").theme.stripComment(line);
            if (content.len < line.len) {
                if (std.mem.indexOfScalarPos(u8, line, content.len, '#')) |start| try out.writer.print("{s}\n", .{line[start..]});
            }
            continue;
        }
        try out.writer.print("{s}\n", .{line});
    }
    try out.writer.writeAll("\n[keybinds]\n");
    for (binds, 0..) |old, i| {
        if (i != index and keys.pack(old.modifiers, old.sym) == keys.pack(replacement.modifiers, replacement.sym)) continue;
        const bind = if (i == index) replacement else old;
        if (bind.action == .noop and !isInherited(defaults.keybinds, bind)) continue;
        const key = try format(a, bind);
        defer a.free(key);
        // Match the loader: quoted action contents are literal, without unescaping.
        const action_buf = try a.alloc(u8, switch (bind.action) {
            .spawn => |v| v.len + 32,
            .save_layout => |v| v.len + 32,
            .restore_layout => |v| v.len + 32,
            else => 128,
        });
        defer a.free(action_buf);
        try out.writer.print("\"{s}\" = \"{s}\"\n", .{ key, keys.describeAction(bind.action, action_buf) });
    }
    const old = binds[index];
    if (isInherited(defaults.keybinds, old) and keys.pack(old.modifiers, old.sym) != keys.pack(replacement.modifiers, replacement.sym)) {
        const key = try format(a, old);
        defer a.free(key);
        try out.writer.print("\"{s}\" = \"noop\"\n", .{key});
    }
    return out.toOwnedSlice();
}

fn isInherited(defaults: []const keys.Keybind, bind: keys.Keybind) bool {
    for (defaults) |inherited| {
        if (keys.pack(inherited.modifiers, inherited.sym) == keys.pack(bind.modifiers, bind.sym)) return true;
    }
    return false;
}

pub fn save(a: std.mem.Allocator, io: std.Io, path: []const u8, binds: []const keys.Keybind, index: usize, replacement: keys.Keybind) !void {
    if (path.len == 0) return error.NoConfigPath;
    const original = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    defer a.free(original);
    var old = try loader.parse(a, original, path);
    defer old.deinit();
    if (old.keybinds.len != binds.len) return error.ConfigChanged;
    for (old.keybinds, binds) |x, y| {
        if (keys.pack(x.modifiers, x.sym) != keys.pack(y.modifiers, y.sym) or !keys.actionEql(x.action, y.action)) return error.ConfigChanged;
    }
    const result = try patch(a, original, binds, index, replacement);
    defer a.free(result);
    var checked = try loader.parse(a, result, path);
    defer checked.deinit();
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    const tmp = try std.fmt.allocPrint(a, "{s}.shortcuts.tmp", .{path});
    defer a.free(tmp);
    const file = try std.Io.Dir.cwd().createFile(io, tmp, .{ .exclusive = true, .permissions = stat.permissions });
    defer file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try file.writeStreamingAll(io, result);
    try file.sync(io);
    try std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, io);
}

test "moving inherited hardware shortcuts persists and old keys can be reused" {
    const a = std.testing.allocator;
    const original = "# keep me\n[input]\npointer_speed = 0.4\n";
    var cfg = try loader.parse(a, original, "test");
    defer cfg.deinit();
    var index: usize = 0;
    for (cfg.keybinds, 0..) |bind, i| {
        if (bind.action == .volume_up) {
            index = i;
            break;
        }
    }
    const key = try keys.parseKeybind("Super+F12");
    const replacement: keys.Keybind = .{ .sym = key.sym, .modifiers = key.modifiers, .action = .volume_up };
    const updated = try patch(a, original, cfg.keybinds, index, replacement);
    defer a.free(updated);
    var parsed = try loader.parse(a, updated, "test");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f32, 0.4), parsed.input.pointer_speed);
    try std.testing.expect(std.mem.indexOf(u8, updated, "# keep me") != null);
    const old = cfg.keybinds[index];
    try std.testing.expectEqual(keys.Action.noop, parsed.lookupKeybind(old.modifiers, old.sym).?);
    try std.testing.expectEqual(keys.Action.volume_up, parsed.lookupKeybind(key.modifiers, key.sym).?);
    const restored = try patch(a, updated, parsed.keybinds, index, old);
    defer a.free(restored);
    var again = try loader.parse(a, restored, "test");
    defer again.deinit();
    try std.testing.expectEqual(keys.Action.volume_up, again.lookupKeybind(old.modifiers, old.sym).?);
    try std.testing.expectEqual(@as(?keys.Action, null), again.lookupKeybind(key.modifiers, key.sym));
}

test "moving Files restores ordinary keys and removes obsolete non-inherited noops" {
    const a = std.testing.allocator;
    const original = "[keybinds]\n\"backslash\" = \"spawn rediwm-files\"\n\"e\" = \"noop\"\n\"Super+e\" = \"noop\"\n";
    var cfg = try loader.parse(a, original, "test");
    defer cfg.deinit();
    const key = try keys.parseKeybind("Super+e");
    const updated = try patch(a, original, cfg.keybinds, 0, .{ .sym = key.sym, .modifiers = key.modifiers, .action = cfg.keybinds[0].action });
    defer a.free(updated);
    var parsed = try loader.parse(a, updated, "test");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("rediwm-files", parsed.lookupKeybind(key.modifiers, key.sym).?.spawn);
    const plain = try keys.parseKeybind("e");
    try std.testing.expectEqual(@as(?keys.Action, null), parsed.lookupKeybind(plain.modifiers, plain.sym));
    try std.testing.expectEqual(@as(?keys.Action, null), parsed.lookupKeybind(cfg.keybinds[0].modifiers, cfg.keybinds[0].sym));
}
