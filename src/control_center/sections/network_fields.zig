//! Text fields that keep what was typed across a rebuild of the widget tree.
//! The tree is rebuilt on every refresh, so a form keeps each field's data
//! (and a pointer to the field in the current tree) in a `Slots`.

const std = @import("std");
const panel = @import("../panel.zig");
const ui = @import("ui");
const gpa = @import("../../main.zig").gpa;
const W = ui.layout.Widget;
const Allocator = std.mem.Allocator;
const widgets = @import("network_ui.zig");

pub const Slot = struct { data: ?ui.layout.TextInputData = null, widget: ?*W = null };

fn typed(_: ?*anyopaque, _: usize, _: []const u8) void {}

/// A caption above a control.
pub fn labeled(a: Allocator, title: []const u8, control: W) !W {
    var column = try widgets.group(a, .column, &.{ widgets.text(title, 12, true), control });
    column.gap = 6;
    return column;
}

pub fn Slots(comptime Field: type) type {
    return struct {
        items: [std.enums.values(Field).len]Slot = @splat(.{}),

        const Self = @This();

        /// Keeps what was typed; call before the tree is rebuilt.
        pub fn capture(self: *Self) void {
            for (&self.items) |*slot| {
                if (slot.widget) |w| slot.data = w.kind.text_input;
                slot.widget = null;
            }
        }
        pub fn release(self: *Self) void {
            self.capture();
            for (&self.items) |*slot| {
                if (slot.data) |data| gpa.free(data.value);
                slot.* = .{};
            }
        }
        pub fn value(self: *const Self, f: Field) []const u8 {
            const slot = self.items[@intFromEnum(f)];
            if (slot.widget) |w| return w.kind.text_input.value;
            if (slot.data) |d| return d.value;
            return "";
        }
        pub fn set(self: *Self, cc: *panel.ControlCenter, f: Field, content: []const u8, placeholder: []const u8) void {
            const slot = &self.items[@intFromEnum(f)];
            if (slot.data) |old| gpa.free(old.value);
            slot.data = .{ .placeholder = placeholder, .value = gpa.dupe(u8, content) catch @constCast(&[_]u8{}), .owner = cc, .id = @intFromEnum(f), .on_change = typed };
        }
        /// A captioned field bound to `f`, for the tree being built.
        pub fn input(self: *Self, a: Allocator, f: Field, name: []const u8, title: []const u8) !W {
            const slot = &self.items[@intFromEnum(f)];
            const control: W = .{ .name = name, .kind = .{ .text_input = slot.data.? }, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 } };
            const column = try labeled(a, title, control);
            slot.widget = &column.children[1];
            return column;
        }
    };
}
