//! Persist the effective bindings, including inherited defaults. A noop at the
//! previous key prevents the loader from restoring an inherited binding.
const std = @import("std");
const loader = @import("loader.zig");
const keys = @import("keybinds.zig");
extern fn xkb_keysym_get_name(u32, [*]u8, usize) c_int;

pub fn format(a: std.mem.Allocator, bind: keys.Keybind) ![]const u8 {
    var name: [128]u8 = undefined;
    const n = xkb_keysym_get_name(@backingInt(bind.sym), &name, name.len);
    if (n <= 0) return error.InvalidKeybind;
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ if (bind.modifiers.logo) "Super+" else "", if (bind.modifiers.ctrl) "Ctrl+" else "", if (bind.modifiers.alt) "Alt+" else "", if (bind.modifiers.shift) "Shift+" else "", name[0..@intCast(n)] });
}

pub fn patch(a: std.mem.Allocator, original: []const u8, binds: []const keys.Keybind, index: usize, replacement: keys.Keybind) ![]u8 {
    return patchMode(a, original, binds, index, replacement, .canvas);
}

pub fn patchMode(a: std.mem.Allocator, original: []const u8, binds: []const keys.Keybind, index: ?usize, replacement: keys.Keybind, mode: loader.DesktopMode) ![]u8 {
    var changes = [_]keys.Keybind{ replacement, undefined };
    var count: usize = 1;
    if (index) |i| {
        const previous = binds[i];
        if (chord(previous) != chord(replacement)) {
            changes[1] = previous;
            changes[1].action = .noop;
            count += 1;
        }
    }
    return patchBindings(a, original, binds, changes[0..count], mode);
}

fn chord(bind: keys.Keybind) u64 {
    return keys.pack(bind.modifiers, bind.sym);
}

fn find(binds: []const keys.Keybind, target: keys.Keybind) ?keys.Keybind {
    for (binds) |bind| {
        if (chord(bind) == chord(target)) return bind;
    }
    return null;
}

fn writeBinding(a: std.mem.Allocator, writer: *std.Io.Writer, bind: keys.Keybind) !void {
    const key = try format(a, bind);
    defer a.free(key);
    const action_buf = try a.alloc(u8, switch (bind.action) {
        .spawn => |v| v.len + 32,
        .save_layout => |v| v.len + 32,
        .restore_layout => |v| v.len + 32,
        else => 128,
    });
    defer a.free(action_buf);
    try writer.print("\"{s}\" = \"{s}\"\n", .{ key, keys.describeAction(bind.action, action_buf) });
}

/// Apply only the changed chords. Keep the spelling and comments on other
/// lines, including on explicit disable overrides.
fn patchBindings(a: std.mem.Allocator, original: []const u8, binds: []const keys.Keybind, changes: []const keys.Keybind, mode: loader.DesktopMode) ![]u8 {
    const section = if (mode.tiled()) "[keybinds.workspace]" else "[keybinds]";
    const trim = std.mem.trim;
    const stripComment = @import("ui").theme.stripComment;
    var defaults = try loader.parse(a, "[keybinds]\n", "shortcut-defaults");
    defer defaults.deinit();
    defaults.compositor.desktop_mode = mode;

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var in_section = false;
    var found_section = false;
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |line| {
        const clean = stripComment(trim(u8, line, " \t\r"));
        if (std.mem.startsWith(u8, clean, "[")) {
            in_section = std.mem.eql(u8, clean, section);
            if (in_section and !found_section) {
                found_section = true;
                try out.writer.print("{s}\n", .{line});
                for (changes) |change| {
                    if (change.action != .noop or find(defaults.activeKeybinds(), change) != null) try writeBinding(a, &out.writer, change);
                }
                continue;
            }
        }
        if (in_section) {
            if (std.mem.indexOfScalar(u8, clean, '=')) |eq| {
                const raw_key = trim(u8, clean[0..eq], " \t");
                const key = @import("ui").theme.unquote(raw_key) catch raw_key;
                const spec = try keys.parseKeybind(key);
                const bind: keys.Keybind = .{ .modifiers = spec.modifiers, .sym = spec.sym, .action = .noop };
                if (find(changes, bind) != null) {
                    if (std.mem.indexOfScalarPos(u8, trim(u8, line, " \t\r"), clean.len, '#')) |comment| {
                        try out.writer.print("{s}\n", .{trim(u8, line, " \t\r")[comment..]});
                    }
                    continue;
                }
            }
        }
        try out.writer.writeAll(line);
        if (lines.index != null) try out.writer.writeByte('\n');
    }
    if (!found_section) {
        if (original.len > 0 and original[original.len - 1] != '\n') try out.writer.writeByte('\n');
        try out.writer.print("\n{s}\n", .{section});
        // Creating a Canvas replacement table would otherwise discard every
        // implicit binding beyond the loader's fallback subset.
        if (!mode.tiled()) for (binds) |bind| {
            if (find(changes, bind) == null and find(defaults.activeKeybinds(), bind) == null) try writeBinding(a, &out.writer, bind);
        };
        for (changes) |change| {
            if (change.action != .noop or find(defaults.activeKeybinds(), change) != null) try writeBinding(a, &out.writer, change);
        }
    }
    return out.toOwnedSlice();
}

pub fn save(a: std.mem.Allocator, io: std.Io, path: []const u8, binds: []const keys.Keybind, index: usize, replacement: keys.Keybind) !void {
    return saveMode(a, io, path, binds, index, replacement, .canvas);
}

pub fn saveMode(a: std.mem.Allocator, io: std.Io, path: []const u8, binds: []const keys.Keybind, index: ?usize, replacement: keys.Keybind, mode: loader.DesktopMode) !void {
    if (path.len == 0) return error.NoConfigPath;
    const original = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    defer a.free(original);
    var old = try loader.parse(a, original, path);
    defer old.deinit();
    old.compositor.desktop_mode = mode;
    if (old.activeKeybinds().len != binds.len) return error.ConfigChanged;
    for (old.activeKeybinds(), binds) |x, y| {
        if (chord(x) != chord(y) or !keys.actionEql(x.action, y.action)) return error.ConfigChanged;
    }
    const result = try patchMode(a, original, binds, index, replacement, mode);
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

test "moving inherited shortcuts persists and old keys can be reused" {
    for ([_]keys.Action{ .volume_up, .open_system_monitor }) |action| {
        const a = std.testing.allocator;
        const original = "# keep me\n[input]\npointer_speed = 0.4\n";
        var cfg = try loader.parse(a, original, "test");
        defer cfg.deinit();
        var index: usize = 0;
        for (cfg.keybinds, 0..) |bind, i| {
            if (keys.actionEql(bind.action, action)) {
                index = i;
                break;
            }
        }
        const key = try keys.parseKeybind("Super+F12");
        const replacement: keys.Keybind = .{ .sym = key.sym, .modifiers = key.modifiers, .action = action };
        const updated = try patch(a, original, cfg.keybinds, index, replacement);
        defer a.free(updated);
        var parsed = try loader.parse(a, updated, "test");
        defer parsed.deinit();
        try std.testing.expectEqual(@as(f32, 0.4), parsed.input.pointer_speed);
        try std.testing.expect(std.mem.indexOf(u8, updated, "# keep me") != null);
        const old = cfg.keybinds[index];
        try std.testing.expectEqual(keys.Action.noop, parsed.lookupKeybind(old.modifiers, old.sym).?);
        try std.testing.expectEqual(action, parsed.lookupKeybind(key.modifiers, key.sym).?);
        const moved = for (parsed.keybinds, 0..) |bind, i| {
            if (chord(bind) == chord(replacement)) break i;
        } else unreachable;
        const restored = try patch(a, updated, parsed.keybinds, moved, old);
        defer a.free(restored);
        var again = try loader.parse(a, restored, "test");
        defer again.deinit();
        try std.testing.expectEqual(action, again.lookupKeybind(old.modifiers, old.sym).?);
        try std.testing.expectEqual(@as(?keys.Action, null), again.lookupKeybind(key.modifiers, key.sym));
    }
}

test "moving Files preserves an unrelated explicit disable override" {
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
    try std.testing.expectEqual(keys.Action.noop, parsed.lookupKeybind(plain.modifiers, plain.sym).?);
    try std.testing.expectEqual(@as(?keys.Action, null), parsed.lookupKeybind(cfg.keybinds[0].modifiers, cfg.keybinds[0].sym));
}

test "assigning an unbound action preserves key spelling, comments and custom commands" {
    const a = std.testing.allocator;
    const original = "[keybinds] # keep header\n\"mod+f\" = \"toggle_fullscreen\" # keep inline\n\"alt+x\" = \"spawn printf hello\"\n";
    var cfg = try loader.parse(a, original, "test");
    defer cfg.deinit();
    const key = try keys.parseKeybind("Super+F12");
    const added = try patchMode(a, original, cfg.activeKeybinds(), null, .{ .sym = key.sym, .modifiers = key.modifiers, .action = .close_window }, .canvas);
    defer a.free(added);
    try std.testing.expect(std.mem.indexOf(u8, added, "\"mod+f\" = \"toggle_fullscreen\" # keep inline") != null);
    try std.testing.expect(std.mem.indexOf(u8, added, "\"alt+x\" = \"spawn printf hello\"") != null);
    var parsed = try loader.parse(a, added, "test");
    defer parsed.deinit();
    try std.testing.expectEqual(keys.Action.close_window, parsed.lookupKeybind(key.modifiers, key.sym).?);
}

test "editing workspace defaults preserves canvas bindings and masks the previous key" {
    inline for (.{ loader.DesktopMode.workspaces, loader.DesktopMode.scrolling }) |mode| {
        try checkWorkspaceEdit(mode);
    }
}

test "unassign and reassign Close Window from implicit defaults in each mode" {
    const a = std.testing.allocator;
    for ([_]loader.DesktopMode{ .canvas, .workspaces, .scrolling }) |mode| {
        var cfg = try loader.parse(a, "", "test");
        defer cfg.deinit();
        cfg.compositor.desktop_mode = mode;
        const original = cfg.activeKeybinds();
        const i = for (original, 0..) |bind, index| {
            if (bind.action == .close_window) break index;
        } else unreachable;
        const bind = original[i];
        try std.testing.expect(bind.inherited);
        const removed = try patchMode(a, "", original, i, .{ .sym = bind.sym, .modifiers = bind.modifiers, .action = .noop }, mode);
        defer a.free(removed);
        var parsed = try loader.parse(a, removed, "test");
        defer parsed.deinit();
        parsed.compositor.desktop_mode = mode;
        if (mode.tiled()) {
            try std.testing.expectEqual(keys.Action.noop, parsed.lookupKeybind(bind.modifiers, bind.sym).?);
        } else {
            try std.testing.expectEqual(@as(?keys.Action, null), parsed.lookupKeybind(bind.modifiers, bind.sym));
        }
        const key = try keys.parseKeybind("Super+F12");
        const added = try patchMode(a, removed, parsed.activeKeybinds(), null, .{ .sym = key.sym, .modifiers = key.modifiers, .action = .close_window }, mode);
        defer a.free(added);
        var restarted = try loader.parse(a, added, "test");
        defer restarted.deinit();
        restarted.compositor.desktop_mode = mode;
        try std.testing.expectEqual(keys.Action.close_window, restarted.lookupKeybind(key.modifiers, key.sym).?);
        const fullscreen = try keys.parseKeybind("Super+f");
        try std.testing.expectEqual(keys.Action.toggle_fullscreen, restarted.lookupKeybind(fullscreen.modifiers, fullscreen.sym).?);
    }
}

fn checkWorkspaceEdit(comptime mode: loader.DesktopMode) !void {
    const a = std.testing.allocator;
    const original = "[compositor]\ndesktop_mode = \"" ++ @tagName(mode) ++ "\"\n[keybinds]\n\"Super+q\" = \"close_window\"\n";
    var cfg = try loader.parse(a, original, "test");
    defer cfg.deinit();
    const binds = cfg.activeKeybinds();
    const key = try keys.parseKeybind("Super+F12");
    const updated = try patchMode(a, original, binds, 0, .{ .sym = key.sym, .modifiers = key.modifiers, .action = binds[0].action }, mode);
    defer a.free(updated);
    var parsed = try loader.parse(a, updated, "test");
    defer parsed.deinit();
    try std.testing.expectEqual(keys.Action.noop, parsed.lookupKeybind(binds[0].modifiers, binds[0].sym).?);
    try std.testing.expectEqualStrings("default-terminal", parsed.lookupKeybind(key.modifiers, key.sym).?.spawn);
    parsed.compositor.desktop_mode = .canvas;
    try std.testing.expectEqual(keys.Action.close_window, parsed.lookupKeybind(binds[0].modifiers, binds[0].sym).?);
}
