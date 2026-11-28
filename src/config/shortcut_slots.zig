//! Persistent shortcut slot identities, independent of runtime dispatch.
const std = @import("std");
const keys = @import("keybinds.zig");

pub const Chord = u64;
pub const Slot = enum { primary, alternate };

pub const Entry = struct {
    action: keys.Action,
    slots: Slots,
};

/// Explicit slot assignments only. An absent entry means that callers
/// should derive slots from the effective bindings and factory defaults.
pub const Table = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn get(self: Table, action: keys.Action) ?Slots {
        for (self.entries.items) |entry| {
            if (keys.actionEql(entry.action, action)) return entry.slots;
        }
        return null;
    }

    pub fn put(
        self: *Table,
        allocator: std.mem.Allocator,
        action: keys.Action,
        slots: Slots,
    ) !void {
        if (self.get(action) != null) return error.DuplicateSlotAction;
        try self.entries.append(allocator, .{
            .action = action,
            .slots = slots,
        });
    }
};

pub const Slots = struct {
    primary: ?Chord = null,
    alternate: ?Chord = null,

    pub fn get(self: Slots, slot: Slot) ?Chord {
        return switch (slot) {
            .primary => self.primary,
            .alternate => self.alternate,
        };
    }

    pub fn set(self: *Slots, slot: Slot, value: ?Chord) void {
        switch (slot) {
            .primary => self.primary = value,
            .alternate => self.alternate = value,
        }
    }

    pub fn contains(self: Slots, value: Chord) bool {
        return self.primary == value or self.alternate == value;
    }

    pub fn eql(self: Slots, other: Slots) bool {
        return self.primary == other.primary and
            self.alternate == other.alternate;
    }
};

fn parseChord(value: []const u8) !?Chord {
    if (value.len == 0) return null;
    const spec = keys.parseKeybind(value) catch return error.InvalidSlotMetadata;
    return keys.pack(spec.modifiers, spec.sym);
}

/// The key is a JSON-quoted action descriptor and the value is a pair
/// of JSON strings. Empty strings represent explicitly unassigned slots.
///
/// The JSON string grammar is compatible with TOML's basic quoted strings
/// for these values and supports escaped custom command action names.
pub fn parseEntry(
    allocator: std.mem.Allocator,
    table: *Table,
    raw_key: []const u8,
    raw_value: []const u8,
) !void {
    const name = std.json.parseFromSliceLeaky(
        []const u8,
        allocator,
        raw_key,
        .{ .allocate = .alloc_always },
    ) catch return error.InvalidSlotMetadata;

    const action = keys.parseAction(name, allocator) catch
        return error.InvalidSlotMetadata;
    if (action == .noop) return error.InvalidSlotMetadata;

    const values = std.json.parseFromSliceLeaky(
        [2][]const u8,
        allocator,
        raw_value,
        .{ .allocate = .alloc_always },
    ) catch return error.InvalidSlotMetadata;

    const result: Slots = .{
        .primary = try parseChord(values[0]),
        .alternate = try parseChord(values[1]),
    };
    if (result.primary != null and result.primary == result.alternate)
        return error.InvalidSlotMetadata;

    try table.put(allocator, action, result);
}

/// Produce the same spelling accepted by parseEntry.
pub fn encodeEntry(
    a: std.mem.Allocator,
    action: keys.Action,
    slots: Slots,
) ![]const u8 {
    const action_buf = try a.alloc(u8, switch (action) {
        .spawn => |v| v.len + 32,
        .custom_command => |v| v.len + 32,
        .save_layout => |v| v.len + 32,
        .restore_layout => |v| v.len + 32,
        else => 128,
    });
    defer a.free(action_buf);
    const name = keys.describeAction(action, action_buf);
    const encoded_name = try std.json.Stringify.valueAlloc(a, name, .{});
    defer a.free(encoded_name);

    const primary = try formatChord(a, slots.primary);
    defer a.free(primary);
    const alternate = try formatChord(a, slots.alternate);
    defer a.free(alternate);

    const encoded_slots = try std.json.Stringify.valueAlloc(
        a,
        [2][]const u8{ primary, alternate },
        .{},
    );
    defer a.free(encoded_slots);
    return std.fmt.allocPrint(a, "{s} = {s}", .{ encoded_name, encoded_slots });
}

fn formatChord(a: std.mem.Allocator, value: ?Chord) ![]const u8 {
    const packed_chord = value orelse return a.dupe(u8, "");
    const modifiers: keys.ModifierMask = @bitCast(@as(u32, @truncate(packed_chord >> 32)));
    const symbol: @import("xkbcommon").Keysym = @enumFromInt(@as(u32, @truncate(packed_chord)));
    var name: [128]u8 = undefined;
    const n = xkb_keysym_get_name(@intFromEnum(symbol), &name, name.len);
    if (n <= 0) return error.InvalidKeybind;
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{
        if (modifiers.logo) "Super+" else "",
        if (modifiers.ctrl) "Ctrl+" else "",
        if (modifiers.alt) "Alt+" else "",
        if (modifiers.shift) "Shift+" else "",
        name[0..@intCast(n)],
    });
}

extern fn xkb_keysym_get_name(u32, [*]u8, usize) c_int;

/// Find the assignment separator, ignoring '=' inside quoted action names.
pub fn assignmentSeparator(line: []const u8) ?usize {
    var quoted = false;
    var escaped = false;
    for (line, 0..) |char, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quoted and char == '\\') {
            escaped = true;
        } else if (char == '"') {
            quoted = !quoted;
        } else if (char == '=' and !quoted) {
            return i;
        }
    }
    return null;
}

/// Edit only one action's metadata. `null` removes its entry.
/// The caller may combine this result with binding edits before one rename.
pub fn patch(
    a: std.mem.Allocator,
    original: []const u8,
    action: keys.Action,
    replacement: ?Slots,
    workspace: bool,
) ![]u8 {
    const section = if (workspace)
        "[shortcut_slots.workspace]"
    else
        "[shortcut_slots]";
    const theme = @import("ui").theme;
    const encoded = if (replacement) |slots|
        try encodeEntry(a, action, slots)
    else
        null;
    defer if (encoded) |entry| a.free(entry);

    var scratch_arena = std.heap.ArenaAllocator.init(a);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    var in_section = false;
    var section_body: ?usize = null;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |raw| {
        const start = offset;
        offset += raw.len + @as(usize, @intFromBool(lines.index != null));
        const left = std.mem.trimStart(u8, raw, " \t");
        const indent = raw.len - left.len;
        const clean = theme.stripComment(std.mem.trimEnd(u8, left, " \t\r"));

        if (std.mem.startsWith(u8, clean, "[")) {
            in_section = std.mem.eql(u8, clean, section);
            if (in_section and section_body == null)
                section_body = offset;
            continue;
        }
        if (!in_section) continue;

        const eq = assignmentSeparator(clean) orelse continue;
        const raw_key = std.mem.trim(u8, clean[0..eq], " \t");
        const name = std.json.parseFromSliceLeaky(
            []const u8,
            scratch,
            raw_key,
            .{ .allocate = .alloc_always },
        ) catch continue;
        const current_action = keys.parseAction(name, scratch) catch continue;
        if (!keys.actionEql(current_action, action)) continue;

        if (encoded) |entry| {
            return std.mem.concat(a, u8, &.{
                original[0 .. start + indent],
                entry,
                original[start + indent + clean.len ..],
            });
        }

        const tail = left[clean.len..];
        if (std.mem.indexOfScalar(u8, tail, '#')) |hash| {
            return std.mem.concat(a, u8, &.{
                original[0 .. start + indent],
                original[start + indent + clean.len + hash ..],
            });
        }
        return std.mem.concat(a, u8, &.{
            original[0..start],
            original[offset..],
        });
    }

    const entry = encoded orelse return a.dupe(u8, original);
    const at = section_body orelse original.len;
    const newline = if (at != 0 and original[at - 1] != '\n')
        "\n"
    else
        "";
    return std.mem.concat(a, u8, &.{
        original[0..at],
        newline,
        if (section_body == null) section else "",
        if (section_body == null) "\n" else "",
        entry,
        "\n",
        original[at..],
    });
}

pub fn chord(bind: keys.Keybind) Chord {
    return keys.pack(bind.modifiers, bind.sym);
}

/// The last occurrence of a chord owns its effective binding.
pub fn lookup(binds: []const keys.Keybind, value: Chord) ?keys.Keybind {
    var i = binds.len;
    while (i > 0) {
        i -= 1;
        if (chord(binds[i]) == value) return binds[i];
    }
    return null;
}

pub fn owns(binds: []const keys.Keybind, action: keys.Action, value: Chord) bool {
    const bind = lookup(binds, value) orelse return false;
    return bind.action != .noop and keys.actionEql(bind.action, action);
}

fn validChord(
    binds: []const keys.Keybind,
    action: keys.Action,
    value: ?Chord,
) ?Chord {
    const candidate = value orelse return null;
    return if (owns(binds, action, candidate)) candidate else null;
}

/// Reconcile explicit metadata without filling empty slots or promoting
/// an alternate. Runtime bindings always remain authoritative.
pub fn reconcile(
    binds: []const keys.Keybind,
    action: keys.Action,
    stored: Slots,
) Slots {
    var result: Slots = .{
        .primary = validChord(binds, action, stored.primary),
        .alternate = validChord(binds, action, stored.alternate),
    };
    if (result.primary != null and result.primary == result.alternate)
        result.alternate = null;
    return result;
}

fn nextChord(
    binds: []const keys.Keybind,
    action: keys.Action,
    occupied: Slots,
) ?Chord {
    var result: ?Chord = null;
    for (binds) |bind| {
        const value = chord(bind);
        if (occupied.contains(value) or !owns(binds, action, value))
            continue;
        if (result == null or value < result.?) result = value;
    }
    return result;
}

/// Derive slots only when no explicit metadata exists.
/// Prefer factory chords in their declared order, then use a stable
/// chord ordering for remaining assignments.
pub fn derive(
    binds: []const keys.Keybind,
    defaults: []const keys.Keybind,
    action: keys.Action,
) Slots {
    var result: Slots = .{};
    for (defaults) |bind| {
        if (!keys.actionEql(bind.action, action)) continue;
        const value = chord(bind);
        if (result.contains(value) or !owns(binds, action, value))
            continue;
        if (result.primary == null) {
            result.primary = value;
        } else {
            result.alternate = value;
            break;
        }
    }
    if (result.primary == null)
        result.primary = nextChord(binds, action, result);
    if (result.alternate == null)
        result.alternate = nextChord(binds, action, result);
    return result;
}

pub fn resolve(
    binds: []const keys.Keybind,
    defaults: []const keys.Keybind,
    action: keys.Action,
    stored: ?Slots,
) Slots {
    return if (stored) |slots|
        reconcile(binds, action, slots)
    else
        derive(binds, defaults, action);
}

/// Additional effective bindings remain active but are not slot members.
pub fn isOverflow(
    binds: []const keys.Keybind,
    action: keys.Action,
    slots: Slots,
    value: Chord,
) bool {
    return !slots.contains(value) and owns(binds, action, value);
}

fn binding(name: []const u8, action: keys.Action) !keys.Keybind {
    const spec = try keys.parseKeybind(name);
    return .{
        .sym = spec.sym,
        .modifiers = spec.modifiers,
        .action = action,
    };
}

test "factory order takes precedence over configuration order" {
    const primary = try binding("Super+q", .close_window);
    const alternate = try binding("Alt+F4", .close_window);
    const extra = try binding("Super+F12", .close_window);
    const defaults = [_]keys.Keybind{ primary, alternate };
    const binds = [_]keys.Keybind{ extra, alternate, primary };
    const slots = derive(&binds, &defaults, .close_window);
    try std.testing.expectEqual(chord(primary), slots.primary.?);
    try std.testing.expectEqual(chord(alternate), slots.alternate.?);
    try std.testing.expect(isOverflow(&binds, .close_window, slots, chord(extra)));
}

test "legacy slot derivation is independent of binding order" {
    const first = try binding("Super+F11", .close_window);
    const second = try binding("Super+F12", .close_window);
    const x = derive(&.{ first, second }, &.{}, .close_window);
    const y = derive(&.{ second, first }, &.{}, .close_window);
    try std.testing.expect(x.eql(y));
}

test "clearing primary never promotes alternate or overflow" {
    const primary = try binding("Super+q", .close_window);
    const alternate = try binding("Alt+F4", .close_window);
    const extra = try binding("Super+F12", .close_window);
    const defaults = [_]keys.Keybind{ primary, alternate };
    var slots = derive(&.{ primary, alternate, extra }, &defaults, .close_window);
    slots.set(.primary, null);
    const remaining = [_]keys.Keybind{ alternate, extra };
    const resolved = resolve(&remaining, &defaults, .close_window, slots);
    try std.testing.expectEqual(@as(?Chord, null), resolved.primary);
    try std.testing.expectEqual(chord(alternate), resolved.alternate.?);
    try std.testing.expect(isOverflow(&remaining, .close_window, resolved, chord(extra)));
}

test "clearing alternate preserves primary" {
    const primary = try binding("Super+q", .close_window);
    const alternate = try binding("Alt+F4", .close_window);
    var slots: Slots = .{
        .primary = chord(primary),
        .alternate = chord(alternate),
    };
    slots.set(.alternate, null);
    const resolved = reconcile(&.{primary}, .close_window, slots);
    try std.testing.expectEqual(chord(primary), resolved.primary.?);
    try std.testing.expectEqual(@as(?Chord, null), resolved.alternate);
}

test "explicit empty slots differ from absent metadata" {
    const bind = try binding("Super+q", .close_window);
    const inferred = resolve(&.{bind}, &.{bind}, .close_window, null);
    const explicit = resolve(&.{bind}, &.{bind}, .close_window, Slots{});
    try std.testing.expectEqual(chord(bind), inferred.primary.?);
    try std.testing.expect(explicit.eql(.{}));
    try std.testing.expect(isOverflow(&.{bind}, .close_window, explicit, chord(bind)));
}

test "external reassignment and noop invalidate only the affected slot" {
    const primary = try binding("Super+q", .close_window);
    const alternate = try binding("Alt+F4", .close_window);
    const reassigned = try binding("Super+q", .toggle_fullscreen);
    const disabled = try binding("Alt+F4", .noop);
    const stored: Slots = .{
        .primary = chord(primary),
        .alternate = chord(alternate),
    };
    const changed = reconcile(&.{ primary, alternate, reassigned }, .close_window, stored);
    try std.testing.expectEqual(@as(?Chord, null), changed.primary);
    try std.testing.expectEqual(chord(alternate), changed.alternate.?);
    const cleared = reconcile(&.{ primary, alternate, reassigned, disabled }, .close_window, stored);
    try std.testing.expect(cleared.eql(.{}));
}

test "duplicate metadata cannot assign one chord to both slots" {
    const bind = try binding("Super+q", .close_window);
    const value = chord(bind);
    const resolved = reconcile(&.{bind}, .close_window, .{
        .primary = value,
        .alternate = value,
    });
    try std.testing.expectEqual(value, resolved.primary.?);
    try std.testing.expectEqual(@as(?Chord, null), resolved.alternate);
}

test "metadata parsing distinguishes absent and explicitly empty slots" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var table: Table = .{};
    try std.testing.expectEqual(
        @as(?Slots, null),
        table.get(.close_window),
    );

    try parseEntry(
        arena.allocator(),
        &table,
        "\"close_window\"",
        "[\"\", \"Alt+F4\"]",
    );

    const slots = table.get(.close_window).?;
    try std.testing.expectEqual(@as(?Chord, null), slots.primary);
    const alternate = try binding("Alt+F4", .close_window);
    try std.testing.expectEqual(chord(alternate), slots.alternate.?);
}

test "slot metadata supports custom command action identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var table: Table = .{};
    try parseEntry(
        arena.allocator(),
        &table,
        "\"custom_command command-7\"",
        "[\"Ctrl+Alt+F7\", \"\"]",
    );
    const action: keys.Action = .{ .custom_command = "command-7" };
    try std.testing.expect(table.get(action) != null);
    try std.testing.expect(table.get(.close_window) == null);
}

test "malformed and duplicate slot metadata is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var table: Table = .{};
    const a = arena.allocator();
    try std.testing.expectError(
        error.InvalidSlotMetadata,
        parseEntry(a, &table, "\"close_window\"", "[\"Super+q\"]"),
    );
    try std.testing.expectError(
        error.InvalidSlotMetadata,
        parseEntry(a, &table, "\"close_window\"", "[\"Super+q\", \"Super+q\"]"),
    );
    try std.testing.expectError(
        error.InvalidSlotMetadata,
        parseEntry(a, &table, "\"close_window\"", "[\"Super+notakey\", \"\"]"),
    );
    try std.testing.expectError(
        error.InvalidSlotMetadata,
        parseEntry(a, &table, "\"noop\"", "[\"\", \"\"]"),
    );
    try parseEntry(a, &table, "\"close_window\"", "[\"\", \"\"]");
    try std.testing.expectError(
        error.DuplicateSlotAction,
        parseEntry(a, &table, "\"close_window\"", "[\"Super+q\", \"\"]"),
    );
}

test "encoded slot metadata round-trips with an empty primary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try keys.parseKeybind("Alt+F4");
    const expected: Slots = .{
        .primary = null,
        .alternate = keys.pack(spec.modifiers, spec.sym),
    };
    const encoded = try encodeEntry(a, .close_window, expected);
    const eq = std.mem.indexOfScalar(u8, encoded, '=') orelse unreachable;

    var table: Table = .{};
    try parseEntry(
        a,
        &table,
        std.mem.trim(u8, encoded[0..eq], " \t"),
        std.mem.trim(u8, encoded[eq + 1 ..], " \t"),
    );
    try std.testing.expect(expected.eql(table.get(.close_window).?));
}

test "slot metadata patch preserves other sections and comments" {
    const a = std.testing.allocator;
    const original =
        "# retain\n" ++
        "[shortcut_slots] # canvas\n" ++
        "  \"close_window\" = [\"Super+q\", \"Alt+F4\"] # close\n" ++
        "\"toggle_fullscreen\" = [\"Super+f\", \"\"]\n" ++
        "[shortcut_slots.workspace]\n" ++
        "\"close_window\" = [\"Super+c\", \"Alt+F4\"]\n" ++
        "[input]\n" ++
        "pointer_speed = 0.4\n";

    const alternate = try binding("Alt+F4", .close_window);
    const slots: Slots = .{ .alternate = chord(alternate) };
    const edited = try patch(a, original, .close_window, slots, false);
    defer a.free(edited);

    try std.testing.expect(
        std.mem.indexOf(u8, edited, "# close") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            edited,
            "\"toggle_fullscreen\" = [\"Super+f\", \"\"]",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            edited,
            "\"close_window\" = [\"Super+c\", \"Alt+F4\"]",
        ) != null,
    );
    var cfg = try @import("loader.zig").parse(a, edited, "test");
    defer cfg.deinit();
    try std.testing.expect(slots.eql(cfg.shortcut_slots.get(.close_window).?));
    try std.testing.expectEqual(@as(f32, 0.4), cfg.input.pointer_speed);

    const removed = try patch(a, edited, .close_window, null, false);
    defer a.free(removed);
    var after = try @import("loader.zig").parse(a, removed, "test");
    defer after.deinit();
    try std.testing.expect(after.shortcut_slots.get(.close_window) == null);
    try std.testing.expect(after.workspace_shortcut_slots.get(.close_window) != null);
}

test "slot metadata can be inserted without an existing section" {
    const a = std.testing.allocator;
    const original = "[input]\npointer_speed = 0.2\n";
    const added = try patch(a, original, .close_window, .{}, false);
    defer a.free(added);
    var cfg = try @import("loader.zig").parse(a, added, "test");
    defer cfg.deinit();
    try std.testing.expect(cfg.shortcut_slots.get(.close_window).?.eql(.{}));
    try std.testing.expectEqual(@as(f32, 0.2), cfg.input.pointer_speed);
}

test "assignment separator ignores equals inside quoted action names" {
    const line = "\"spawn printf FOO=bar\" = [\"\", \"\"]";
    const eq = assignmentSeparator(line).?;
    try std.testing.expectEqualStrings(
        "\"spawn printf FOO=bar\" ",
        line[0..eq],
    );
}
