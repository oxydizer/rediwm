const std = @import("std");
const panel = @import("../panel.zig");
const ui = @import("ui");
const defaults = @import("../../config_runtime/default_apps.zig");
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    values: [2][]const []const u8 = .{ &.{}, &.{} },
    message: []const u8 = "Used for desktop folders, app shortcuts and apps that run in a terminal.",
};
fn text(value: []const u8) W {
    return .{ .kind = .{ .text = .{ .content = value, .font_size = 14, .color = panel.palette().fg } } };
}
pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    _ = s.arena.reset(.retain_capacity);
    s.values = .{ &.{}, &.{} };
    s.root = tree(s, cc, s.arena.allocator()) catch panel.outOfMemory();
}
fn tree(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const snapshot = cc.server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    const children = try a.alloc(W, 4);
    children[0] = text("Default applications");
    inline for (.{ defaults.Kind.file_manager, defaults.Kind.terminal }, 0..) |kind, index| {
        var labels: std.ArrayList([]const u8) = .empty;
        var values: std.ArrayList([]const u8) = .empty;
        try labels.append(a, if (kind == .file_manager) "Files (built-in)" else "Automatic ($TERMINAL / Foot)");
        try values.append(a, "");
        const selected = if (kind == .file_manager) cc.server.config.compositor.default_file_manager else cc.server.config.compositor.default_terminal;
        var selected_index: usize = 0;
        for (snapshot.entries) |entry| {
            if (!defaults.matches(entry, kind)) continue;
            try labels.append(a, try a.dupe(u8, entry.name));
            try values.append(a, try a.dupe(u8, entry.id));
            if (std.mem.eql(u8, entry.id, selected)) selected_index = values.items.len - 1;
        }
        if (selected.len > 0 and selected_index == 0) {
            try labels.append(a, try std.fmt.allocPrint(a, "Unavailable: {s}", .{selected}));
            try values.append(a, try a.dupe(u8, selected));
            selected_index = values.items.len - 1;
        }
        s.values[index] = values.items;
        children[index + 1] = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .gap = 12, .children = try a.dupe(W, &.{
            text(if (kind == .file_manager) "File Manager" else "Terminal"),
            .{ .name = "default_" ++ @tagName(kind), .kind = .{ .select = .{ .labels = labels.items, .selected = selected_index, .owner = cc, .on_change = if (kind == .file_manager) fileChanged else terminalChanged } }, .width = .{ .fixed = 240 } },
        }) };
    }
    children[3] = text(s.message);
    return .{ .kind = .container, .direction = .column, .gap = 12, .width = .{ .percent = 1 }, .children = children };
}
fn save(owner: ?*anyopaque, comptime kind: defaults.Kind, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    const server = cc.server;
    const values = cc.default_apps.values[@intFromEnum(kind)];
    if (index >= values.len) return;
    const value = values[index];
    const key = "default_" ++ @tagName(kind);
    @import("config").setting_save.saveCompositor(gpa, server.io, server.config.path, key, value) catch |err| {
        std.log.warn("could not save default application: {}", .{err});
        cc.default_apps.message = "Could not save the default application.";
        cc.refresh();
        return;
    };
    @field(server.config.compositor, key) = server.config.arena.allocator().dupe(u8, value) catch return;
    cc.default_apps.message = "Saved. Your choice applies immediately.";
    if (kind == .file_manager) setDirectoryDefault(value) catch {
        cc.default_apps.message = "Saved for RediWM, but could not update the system folder association.";
    };
    cc.refresh();
}
extern fn g_desktop_app_info_new(id: [*:0]const u8) ?*anyopaque;
extern fn g_app_info_set_as_default_for_type(app: *anyopaque, content_type: [*:0]const u8, err: ?*?*anyopaque) c_int;
extern fn g_object_unref(object: *anyopaque) void;

fn setDirectoryDefault(id: []const u8) !void {
    const terminated = try gpa.dupeZ(u8, if (id.len == 0) "rediwm-files.desktop" else id);
    defer gpa.free(terminated);
    const app = g_desktop_app_info_new(terminated) orelse return error.ApplicationUnavailable;
    defer g_object_unref(app);
    if (g_app_info_set_as_default_for_type(app, "inode/directory", null) == 0) return error.AssociationFailed;
}

fn fileChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    save(owner, .file_manager, index);
}
fn terminalChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    save(owner, .terminal, index);
}
