//! Persist the effective bindings, including inherited defaults. A noop at the
//! previous key prevents the loader from restoring an inherited binding.
const std = @import("std");
const loader = @import("loader.zig");
const keys = @import("keybinds.zig");
const command_table = @import("shortcut_command_table.zig");
const slots = @import("shortcut_slots.zig");
extern fn xkb_keysym_get_name(u32, [*]u8, usize) c_int;

pub fn format(a: std.mem.Allocator, bind: keys.Keybind) ![]const u8 {
    var name: [128]u8 = undefined;
    const n = xkb_keysym_get_name(@intFromEnum(bind.sym), &name, name.len);
    if (n <= 0) return error.InvalidKeybind;
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ if (bind.modifiers.logo) "Super+" else "", if (bind.modifiers.ctrl) "Ctrl+" else "", if (bind.modifiers.alt) "Alt+" else "", if (bind.modifiers.shift) "Shift+" else "", name[0..@intCast(n)] });
}

pub fn patch(a: std.mem.Allocator, original: []const u8, binds: []const keys.Keybind, index: usize, replacement: keys.Keybind) ![]u8 {
    return patchMode(a, original, binds, index, replacement, .canvas);
}

pub fn patchMode(a: std.mem.Allocator, original: []const u8, binds: []const keys.Keybind, index: ?usize, replacement: keys.Keybind, mode: loader.DesktopMode) ![]u8 {
    var changes: [2]keys.Keybind = undefined;
    return patchBindings(a, original, binds, bindingChanges(binds, index, replacement, &changes), mode);
}

fn bindingChanges(binds: []const keys.Keybind, index: ?usize, replacement: keys.Keybind, changes: *[2]keys.Keybind) []const keys.Keybind {
    changes[0] = replacement;
    var count: usize = 1;
    if (index) |i| {
        const previous = binds[i];
        if (chord(previous) != chord(replacement)) {
            changes[1] = previous;
            changes[1].action = .noop;
            count += 1;
        }
    }
    return changes[0..count];
}

fn chord(bind: keys.Keybind) u64 {
    return keys.pack(bind.modifiers, bind.sym);
}

fn find(binds: []const keys.Keybind, target: keys.Keybind) ?keys.Keybind {
    var i = binds.len;
    while (i > 0) {
        i -= 1;
        const bind = binds[i];
        if (chord(bind) == chord(target)) return bind;
    }
    return null;
}

pub fn factoryConfig(a: std.mem.Allocator, mode: loader.DesktopMode) !loader.Config {
    var config = try loader.parse(a, "", "shortcut-defaults");
    config.compositor.desktop_mode = mode;
    return config;
}

/// Change one slot while preserving the other slot and overflow bindings.
/// Return a complete configuration without modifying the filesystem.
pub fn patchSlot(
    a: std.mem.Allocator,
    original: []const u8,
    cfg: *const loader.Config,
    action: keys.Action,
    slot: slots.Slot,
    replacement: ?keys.Keybind,
) ![]u8 {
    if (action == .noop) return error.InvalidSlotMetadata;
    if (action == .custom_command and
        !cfg.shortcut_commands.contains(action.custom_command))
        return error.ConfigChanged;

    const mode = cfg.compositor.desktop_mode;
    const binds = cfg.activeKeybinds();
    var defaults = try factoryConfig(a, mode);
    defer defaults.deinit();

    var assigned = slots.resolve(
        binds,
        defaults.activeKeybinds(),
        action,
        cfg.storedShortcutSlots(action),
    );
    const previous = assigned.get(slot);
    const next = if (replacement) |bind| slots.chord(bind) else null;

    var changes: [2]keys.Keybind = undefined;
    var count: usize = 0;

    if (replacement) |bind| {
        if (!keys.actionEql(bind.action, action))
            return error.InvalidSlotMetadata;

        if (next != previous) {
            if (slots.lookup(binds, slots.chord(bind))) |owner| {
                if (owner.action != .noop)
                    return error.ShortcutConflict;
            }
            changes[count] = bind;
            count += 1;
        }
    }

    if (previous != next) {
        if (previous) |value| {
            var removal = slots.lookup(binds, value) orelse
                return error.ConfigChanged;
            removal.action = .noop;
            changes[count] = removal;
            count += 1;
        }
    }

    assigned.set(slot, next);

    const patched = if (count != 0)
        try patchBindings(a, original, binds, changes[0..count], mode)
    else
        try a.dupe(u8, original);
    defer a.free(patched);

    const result = try slots.patch(
        a,
        patched,
        action,
        assigned,
        mode.tiled(),
    );
    errdefer a.free(result);

    var checked = try loader.parse(a, result, "shortcut-slot-edit");
    defer checked.deinit();
    checked.compositor.desktop_mode = mode;

    const resolved = slots.resolve(
        checked.activeKeybinds(),
        defaults.activeKeybinds(),
        action,
        checked.storedShortcutSlots(action),
    );
    if (!resolved.eql(assigned)) return error.InvalidSlotMetadata;

    // Every chord outside this edit must retain its effective action.
    // This also protects overflow bindings and explicit disables.
    for (binds) |bind| {
        const value = chord(bind);
        if (previous != next and
            (value == previous or value == next))
            continue;

        const before = slots.lookup(binds, value) orelse continue;
        const after = slots.lookup(checked.activeKeybinds(), value);
        if (after == null or
            !keys.actionEql(before.action, after.?.action))
            return error.InvalidSlotMetadata;
    }

    return result;
}

test "clearing primary preserves alternate and overflow across reload" {
    const a = std.testing.allocator;
    const original =
        \\[keybinds]
        \\"Super+q" = "close_window"
        \\"Alt+F4" = "close_window"
        \\"Ctrl+F12" = "close_window"
        \\[shortcut_slots]
        \\"close_window" = ["Super+q", "Alt+F4"]
        \\
    ;
    var cfg = try loader.parse(a, original, "test");
    defer cfg.deinit();
    cfg.compositor.desktop_mode = .canvas;

    const updated = try patchSlot(
        a, original, &cfg, .close_window, .primary, null,
    );
    defer a.free(updated);

    var parsed = try loader.parse(a, updated, "test");
    defer parsed.deinit();
    parsed.compositor.desktop_mode = .canvas;

    const primary = try keys.parseKeybind("Super+q");
    const alternate = try keys.parseKeybind("Alt+F4");
    const overflow = try keys.parseKeybind("Ctrl+F12");
    const stored = parsed.storedShortcutSlots(.close_window).?;

    try std.testing.expect(stored.primary == null);
    try std.testing.expectEqual(
        @as(?slots.Chord, keys.pack(alternate.modifiers, alternate.sym)),
        stored.alternate,
    );
    try std.testing.expect(!slots.owns(
        parsed.activeKeybinds(), .close_window,
        keys.pack(primary.modifiers, primary.sym),
    ));
    try std.testing.expect(slots.owns(
        parsed.activeKeybinds(), .close_window,
        keys.pack(alternate.modifiers, alternate.sym),
    ));
    try std.testing.expect(slots.isOverflow(
        parsed.activeKeybinds(), .close_window, stored,
        keys.pack(overflow.modifiers, overflow.sym),
    ));
}

test "slot assignment rejects occupied chords" {
    const a = std.testing.allocator;
    const original =
        \\[keybinds]
        \\"Super+q" = "close_window"
        \\"Alt+F4" = "close_window"
        \\"Ctrl+F12" = "close_window"
        \\"Super+f" = "toggle_fullscreen"
        \\[shortcut_slots]
        \\"close_window" = ["Super+q", "Alt+F4"]
        \\
    ;
    var cfg = try loader.parse(a, original, "test");
    defer cfg.deinit();
    cfg.compositor.desktop_mode = .canvas;

    for ([_][]const u8{ "Alt+F4", "Ctrl+F12", "Super+f" }) |name| {
        const spec = try keys.parseKeybind(name);
        try std.testing.expectError(
            error.ShortcutConflict,
            patchSlot(a, original, &cfg, .close_window, .primary, .{
                .modifiers = spec.modifiers,
                .sym = spec.sym,
                .action = .close_window,
            }),
        );
    }
}

fn selected(action: keys.Action, target: ?keys.Action) bool {
    return if (target) |one| keys.actionEql(action, one) else keys.isBuiltIn(action);
}

pub fn canReset(binds: []const keys.Keybind, defaults: []const keys.Keybind, target: ?keys.Action) bool {
    for (defaults) |bind| {
        if (!selected(bind.action, target)) continue;
        const current = find(binds, bind) orelse return true;
        if (!keys.actionEql(current.action, bind.action)) return true;
    }
    for (binds) |bind| {
        if (!selected(bind.action, target)) continue;
        const default = find(defaults, bind) orelse return true;
        if (!keys.actionEql(default.action, bind.action)) return true;
    }
    return false;
}

fn resetChanges(a: std.mem.Allocator, binds: []const keys.Keybind, defaults: []const keys.Keybind, target: ?keys.Action) ![]const keys.Keybind {
    var changes: std.ArrayList(keys.Keybind) = .empty;
    // Reserve the factory chords before dropping obsolete bindings. Occupants
    // in the reset scope are moved or removed by the same replacement.
    for (defaults) |bind| {
        if (!selected(bind.action, target)) continue;
        if (find(binds, bind)) |current| {
            if (keys.actionEql(current.action, bind.action)) continue;
            if (current.action != .noop and !selected(current.action, target)) return error.ShortcutConflict;
        }
        try changes.append(a, bind);
    }
    for (binds) |bind| {
        const current = find(binds, bind).?;
        if (!selected(current.action, target) or find(changes.items, bind) != null) continue;
        if (find(defaults, bind)) |default| {
            if (keys.actionEql(current.action, default.action)) continue;
        }
        var removal = bind;
        removal.action = .noop;
        try changes.append(a, removal);
    }
    return changes.items;
}

fn writeBinding(a: std.mem.Allocator, writer: *std.Io.Writer, bind: keys.Keybind) !void {
    const key = try format(a, bind);
    defer a.free(key);
    const action_buf = try a.alloc(u8, switch (bind.action) {
        .spawn => |v| v.len + 32,
        .custom_command => |v| v.len + 32,
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
    return saveMode(a, io, path, binds, index, replacement, .canvas, null);
}

pub const CommandSnapshot = struct {
    id: []const u8,
    text: ?[]const u8,

    pub fn matches(snapshot: CommandSnapshot, cfg: *const loader.Config) bool {
        const current = cfg.shortcut_commands.get(snapshot.id);
        return if (snapshot.text) |old| current != null and std.mem.eql(u8, old, current.?) else current == null;
    }
};

/// Persist one shortcut slot using the same validated, atomic replacement
/// as other Control Center shortcut edits.
pub fn saveSlot(
    a: std.mem.Allocator,
    io: std.Io,
    cfg: *const loader.Config,
    mode: loader.DesktopMode,
    action: keys.Action,
    slot: slots.Slot,
    replacement: ?keys.Keybind,
    command: ?CommandSnapshot,
) !void {
    if (cfg.path.len == 0) return error.NoConfigPath;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();

    const original = try std.Io.Dir.cwd().readFileAlloc(
        io,
        cfg.path,
        scratch,
        .limited(1 << 20),
    );
    var current = try loader.parse(scratch, original, cfg.path);
    defer current.deinit();
    current.compositor.desktop_mode = mode;

    const expected_binds = if (mode.tiled())
        cfg.workspace_keybinds
    else
        cfg.keybinds;
    if (!sameBindings(current.activeKeybinds(), expected_binds))
        return error.ConfigChanged;

    const expected_slots = if (mode.tiled())
        cfg.workspace_shortcut_slots.get(action)
    else
        cfg.shortcut_slots.get(action);
    const actual_slots = current.storedShortcutSlots(action);
    if ((expected_slots == null) != (actual_slots == null))
        return error.ConfigChanged;
    if (expected_slots) |expected| {
        if (!expected.eql(actual_slots.?))
            return error.ConfigChanged;
    }

    if (command) |snapshot| {
        if (!snapshot.matches(&current))
            return error.ConfigChanged;
    }
    if (action == .custom_command) {
        const id = action.custom_command;
        const expected = cfg.shortcut_commands.get(id) orelse
            return error.ConfigChanged;
        const actual = current.shortcut_commands.get(id) orelse
            return error.ConfigChanged;
        if (!std.mem.eql(u8, expected, actual))
            return error.ConfigChanged;
    }

    const result = try patchSlot(
        scratch,
        original,
        &current,
        action,
        slot,
        replacement,
    );
    try writeConfig(scratch, io, cfg.path, result);
}

pub fn saveMode(a: std.mem.Allocator, io: std.Io, path: []const u8, binds: []const keys.Keybind, index: ?usize, replacement: keys.Keybind, mode: loader.DesktopMode, command: ?CommandSnapshot) !void {
    var changes: [2]keys.Keybind = undefined;
    return saveChanges(a, io, path, binds, bindingChanges(binds, index, replacement, &changes), mode, command);
}

pub fn saveReset(a: std.mem.Allocator, io: std.Io, path: []const u8, binds: []const keys.Keybind, mode: loader.DesktopMode, target: ?keys.Action) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var defaults = try factoryConfig(a, mode);
    defer defaults.deinit();
    const changes = try resetChanges(arena.allocator(), binds, defaults.activeKeybinds(), target);
    if (changes.len > 0) try saveChanges(a, io, path, binds, changes, mode, null);
}

fn saveChanges(a: std.mem.Allocator, io: std.Io, path: []const u8, binds: []const keys.Keybind, changes: []const keys.Keybind, mode: loader.DesktopMode, command: ?CommandSnapshot) !void {
    if (path.len == 0) return error.NoConfigPath;
    const original = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    defer a.free(original);
    var old = try loader.parse(a, original, path);
    defer old.deinit();
    old.compositor.desktop_mode = mode;
    if (!sameBindings(old.activeKeybinds(), binds)) return error.ConfigChanged;
    if (command) |snapshot| {
        if (!snapshot.matches(&old)) return error.ConfigChanged;
    }
    for (changes) |bind| {
        if (bind.action == .custom_command and !old.shortcut_commands.contains(bind.action.custom_command)) return error.ConfigChanged;
    }
    const result = try patchBindings(a, original, binds, changes, mode);
    defer a.free(result);
    try writeConfig(a, io, path, result);
}

pub fn saveCustomCommand(a: std.mem.Allocator, io: std.Io, cfg: *const loader.Config, id: []const u8, command: ?[]const u8) !void {
    const path = cfg.path;
    if (path.len == 0) return error.NoConfigPath;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const original = try std.Io.Dir.cwd().readFileAlloc(io, path, scratch, .limited(1 << 20));
    var old = try loader.parse(a, original, path);
    defer old.deinit();
    const snapshot: CommandSnapshot = .{ .id = id, .text = cfg.shortcut_commands.get(id) };
    if (!snapshot.matches(&old)) return error.ConfigChanged;
    if (command == null and (!sameBindings(old.keybinds, cfg.keybinds) or
        !sameBindings(old.workspace_keybinds, cfg.workspace_keybinds))) return error.ConfigChanged;

    const result = try patchCustomCommand(scratch, original, &old, id, command);
    try writeConfig(a, io, path, result);
}

fn sameBindings(a: []const keys.Keybind, b: []const keys.Keybind) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (chord(x) != chord(y) or !keys.actionEql(x.action, y.action)) return false;
    }
    return true;
}

fn patchCustomCommand(a: std.mem.Allocator, original: []const u8, cfg: *const loader.Config, id: []const u8, command: ?[]const u8) ![]u8 {
    var patched = original;
    if (command == null) {
        const target: keys.Action = .{ .custom_command = id };
        const modes = [_]loader.DesktopMode{ .canvas, .tiling };
        for (modes, [_][]const keys.Keybind{ cfg.keybinds, cfg.workspace_keybinds }) |mode, binds| {
            var changes: std.ArrayList(keys.Keybind) = .empty;
            for (binds) |bind| {
                if (!keys.actionEql(bind.action, target) or find(changes.items, bind) != null) continue;
                var winner = find(binds, bind).?;
                if (keys.actionEql(winner.action, target)) winner.action = .noop;
                try changes.append(a, winner);
            }
            if (changes.items.len != 0) patched = try patchBindings(a, patched, binds, changes.items, mode);
        }
    }
    return command_table.patch(a, patched, id, command);
}

fn writeConfig(a: std.mem.Allocator, io: std.Io, path: []const u8, result: []const u8) !void {
    if (result.len > 1 << 20) return error.ConfigTooLarge;
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

test "saveSlot persists independent primary and alternate slots" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        a, ".zig-cache/tmp/{s}/config.toml", .{tmp.sub_path},
    );
    defer a.free(path);

    const original =
        \\[keybinds]
        \\"Super+q" = "close_window"
        \\"Alt+F4" = "close_window"
        \\"Ctrl+F12" = "close_window"
        \\[shortcut_slots]
        \\"close_window" = ["Super+q", "Alt+F4"]
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = original });

    var before = try loader.parse(a, original, path);
    defer before.deinit();
    try saveSlot(a, io, &before, .canvas, .close_window, .primary, null, null);

    const saved = try std.Io.Dir.cwd().readFileAlloc(
        io, path, a, .limited(1 << 20),
    );
    defer a.free(saved);
    var after = try loader.parse(a, saved, path);
    defer after.deinit();

    const assigned = after.storedShortcutSlots(.close_window).?;
    const alt = try keys.parseKeybind("Alt+F4");
    const overflow = try keys.parseKeybind("Ctrl+F12");
    try std.testing.expect(assigned.primary == null);
    try std.testing.expectEqual(
        @as(?slots.Chord, keys.pack(alt.modifiers, alt.sym)),
        assigned.alternate,
    );
    try std.testing.expect(slots.owns(
        after.activeKeybinds(), .close_window,
        keys.pack(overflow.modifiers, overflow.sym),
    ));
}

test "saveSlot rejects stale slot metadata without changing the file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original =
        \\[keybinds]
        \\"Super+q" = "close_window"
        \\"Alt+F4" = "close_window"
        \\[shortcut_slots]
        \\"close_window" = ["Super+q", "Alt+F4"]
        \\
    ;
    const changed =
        \\[keybinds]
        \\"Super+q" = "close_window"
        \\"Alt+F4" = "close_window"
        \\[shortcut_slots]
        \\"close_window" = ["Alt+F4", "Super+q"]
        \\
    ;

    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = original });
    const path = try std.fmt.allocPrint(
        a, ".zig-cache/tmp/{s}/config.toml", .{tmp.sub_path},
    );
    defer a.free(path);
    var snapshot = try loader.parse(a, original, path);
    defer snapshot.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = changed });
    try std.testing.expectError(
        error.ConfigChanged,
        saveSlot(a, io, &snapshot, .canvas, .close_window, .primary, null, null),
    );

    const actual = try std.Io.Dir.cwd().readFileAlloc(
        io, path, a, .limited(1 << 20),
    );
    defer a.free(actual);
    try std.testing.expectEqualStrings(changed, actual);
}

test "saveSlot rejects stale custom commands without changing the file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original =
        \\[keybinds]
        \\"Super+F12" = "custom_command demo"
        \\[shortcut_commands]
        \\demo = "echo original"
        \\[shortcut_slots]
        \\"custom_command demo" = ["Super+F12", ""]
        \\
    ;
    const changed =
        \\[keybinds]
        \\"Super+F12" = "custom_command demo"
        \\[shortcut_commands]
        \\demo = "echo edited"
        \\[shortcut_slots]
        \\"custom_command demo" = ["Super+F12", ""]
        \\
    ;

    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = original });
    const path = try std.fmt.allocPrint(
        a, ".zig-cache/tmp/{s}/config.toml", .{tmp.sub_path},
    );
    defer a.free(path);
    var snapshot = try loader.parse(a, original, path);
    defer snapshot.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = changed });
    try std.testing.expectError(
        error.ConfigChanged,
        saveSlot(
            a, io, &snapshot, .canvas,
            .{ .custom_command = "demo" }, .primary, null, null,
        ),
    );

    const actual = try std.Io.Dir.cwd().readFileAlloc(
        io, path, a, .limited(1 << 20),
    );
    defer a.free(actual);
    try std.testing.expectEqualStrings(changed, actual);
}
test "editing a command retains both mode bindings and deletion removes only its references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original =
        \\[keybinds]
        \\"Super+q" = "close_window"
        \\"Ctrl+Alt+Delete" = "custom_command demo"
        \\"Alt+F11" = "spawn printf hello" # legacy
        \\[keybinds.workspace]
        \\"Super+F11" = "custom_command demo"
        \\"Super+F12" = "custom_command demo"
        \\"super+f12" = "close_window"
        \\[shortcut_commands]
        \\demo = "echo hi"
        \\
    ;
    var cfg = try loader.parse(a, original, "test");
    defer cfg.deinit();
    const updated = try patchCustomCommand(a, original, &cfg, "demo", "echo \"new value\"");
    var edited = try loader.parse(a, updated, "test");
    defer edited.deinit();
    try std.testing.expectEqualStrings("echo \"new value\"", edited.shortcut_commands.get("demo").?);
    try std.testing.expect(sameBindings(cfg.keybinds, edited.keybinds));
    try std.testing.expect(sameBindings(cfg.workspace_keybinds, edited.workspace_keybinds));

    const deleted = try patchCustomCommand(a, updated, &edited, "demo", null);
    var restarted = try loader.parse(a, deleted, "test");
    defer restarted.deinit();
    try std.testing.expect(!restarted.shortcut_commands.contains("demo"));
    try std.testing.expect(std.mem.indexOf(u8, deleted, "custom_command demo") == null);
    try std.testing.expect(std.mem.indexOf(u8, deleted, "\"Alt+F11\" = \"spawn printf hello\" # legacy") != null);
    const monitor = try keys.parseKeybind("Ctrl+Alt+Delete");
    try std.testing.expectEqual(keys.Action.noop, restarted.lookupKeybind(monitor.modifiers, monitor.sym).?);
    restarted.compositor.desktop_mode = .tiling;
    const surviving = try keys.parseKeybind("Super+F12");
    try std.testing.expectEqual(keys.Action.close_window, restarted.lookupKeybind(surviving.modifiers, surviving.sym).?);
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
    inline for (.{ loader.DesktopMode.tiling, loader.DesktopMode.scrolling }) |mode| {
        try checkWorkspaceEdit(mode);
    }
}

test "unassign and reassign Close Window from implicit defaults in each mode" {
    const a = std.testing.allocator;
    for ([_]loader.DesktopMode{ .canvas, .tiling, .scrolling }) |mode| {
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

test "reset checks factory conflicts and keeps unrelated bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var factory = try factoryConfig(a, .canvas);
    defer factory.deinit();
    const defaults = factory.activeKeybinds();
    const original =
        \\[keybinds]
        \\"Super+q" = "spawn printf hello"
        \\"Super+F12" = "close_window"
        \\"Super+f" = "toggle_fullscreen" # keep unrelated
    ;
    var cfg = try loader.parse(a, original, "test");
    defer cfg.deinit();
    const binds = cfg.activeKeybinds();
    try std.testing.expectError(error.ShortcutConflict, resetChanges(a, binds, defaults, .close_window));
    try std.testing.expectError(error.ShortcutConflict, resetChanges(a, binds, defaults, null));
    const changes = try resetChanges(a, binds, defaults, .toggle_maximize);
    const updated = try patchBindings(a, original, binds, changes, .canvas);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"Super+q\" = \"spawn printf hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"Super+F12\" = \"close_window\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"Super+f\" = \"toggle_fullscreen\" # keep unrelated") != null);
}

test "global reset frees built-in chords and protects custom shortcuts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bind = struct {
        fn make(key: []const u8, action: keys.Action) !keys.Keybind {
            const spec = try keys.parseKeybind(key);
            return .{ .modifiers = spec.modifiers, .sym = spec.sym, .action = action };
        }
    }.make;
    const close = try bind("Super+q", .close_window);
    const fullscreen = try bind("Super+f", .toggle_fullscreen);
    const defaults = [_]keys.Keybind{ close, fullscreen };
    const extra = try bind("Super+F12", .close_window);
    const legacy = try bind("Alt+F11", .{ .spawn = "printf hello" });
    const managed = try bind("Alt+F12", .{ .custom_command = "demo" });
    var current = [_]keys.Keybind{
        try bind("Super+q", .toggle_fullscreen),
        try bind("Super+f", .close_window),
        extra,
        legacy,
        managed,
    };

    const changes = try resetChanges(a, &current, &defaults, null);
    try std.testing.expectEqual(keys.Action.close_window, find(changes, close).?.action);
    try std.testing.expectEqual(keys.Action.toggle_fullscreen, find(changes, fullscreen).?.action);
    try std.testing.expectEqual(keys.Action.noop, find(changes, extra).?.action);
    try std.testing.expect(find(changes, legacy) == null);
    try std.testing.expect(find(changes, managed) == null);
    try std.testing.expectError(error.ShortcutConflict, resetChanges(a, &current, &defaults, .close_window));

    for ([_]keys.Action{ legacy.action, managed.action }) |custom| {
        current[0].action = custom;
        try std.testing.expectError(error.ShortcutConflict, resetChanges(a, &current, &defaults, null));
    }
}
