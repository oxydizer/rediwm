const std = @import("std");
const panel = @import("../panel.zig");
const ui = @import("ui");
const config = @import("config").portals;
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;
pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    message: []const u8 = "Changes apply next time you sign in.",
};
fn text(value: []const u8, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = if (dim) 12 else 14, .color = if (dim) t.dim else t.fg } } };
}
fn row(cc: *panel.ControlCenter, a: std.mem.Allocator, title: []const u8, name: []const u8, labels: []const []const u8, values: []const []const u8, selected: []const u8, callback: *const fn (?*anyopaque, usize, usize) void) !W {
    var index: usize = values.len;
    for (values, 0..) |value, i| if (std.mem.eql(u8, value, selected)) {
        index = i;
    };
    const options = try a.alloc([]const u8, labels.len + @as(usize, if (index == values.len) 1 else 0));
    @memcpy(options[0..labels.len], labels);
    if (index == values.len) options[index] = std.fmt.allocPrint(a, "Custom ({s})", .{selected}) catch "Custom";
    return .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .gap = 12, .children = try a.dupe(W, &.{
        text(title, false),
        .{ .name = name, .kind = .{ .select = .{ .labels = options, .selected = index, .owner = cc, .on_change = callback } }, .width = .{ .fixed = 190 } },
    }) };
}
const default_values = [_][]const u8{ "gtk", "kde", "rediwm;gtk" };
const file_values = [_][]const u8{ "rediwm;gtk", "gtk", "kde", "*" };
pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    _ = s.arena.reset(.retain_capacity);
    s.root = tree(s, cc, s.arena.allocator()) catch panel.outOfMemory();
}
fn tree(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const content = config.load(a, cc.server.io, cc.server.environ) catch config.defaults;
    return .{ .kind = .container, .direction = .column, .gap = 12, .width = .{ .percent = 1 }, .children = try a.dupe(W, &.{
        text("Desktop portals", false),
        text("Choose the services apps use for desktop dialogs. The selected backend must be installed.", true),
        try row(cc, a, "Default backend", "portal_default", &.{ "GTK", "KDE", "RediWM + GTK" }, &default_values, config.get(content, "default") orelse "gtk", defaultChanged),
        try row(cc, a, "File dialogs", "portal_file_chooser", &.{ "RediWM", "GTK", "KDE", "Any available" }, &file_values, config.get(content, config.chooser_key) orelse config.get(content, "default") orelse "gtk", fileChanged),
        text(s.message, true),
    }) };
}
fn save(owner: ?*anyopaque, key: []const u8, value: []const u8) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    config.save(cc.server.io, cc.server.environ, key, value) catch {
        cc.portals.message = "Could not save portal preferences. Check your configuration directory.";
        cc.refresh();
        return;
    };
    cc.portals.message = "Saved. Changes apply next time you sign in.";
    cc.refresh();
}
fn defaultChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    if (index < default_values.len) save(owner, "default", default_values[index]);
}
fn fileChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    if (index < file_values.len) save(owner, config.chooser_key, file_values[index]);
}
