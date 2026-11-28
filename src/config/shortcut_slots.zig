//! Persistent shortcut slot identities, independent of runtime dispatch.
const std = @import("std");
const keys = @import("keybinds.zig");

pub const Chord = u64;
pub const Slot = enum { primary, alternate };

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
