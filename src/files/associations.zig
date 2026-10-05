//! MIME icons and application associations through the system GIO database.
//! Icon candidates run on the directory worker; application snapshots belong
//! to the Open With dialog. Neither owns the UI icon cache.
const std = @import("std");
const Allocator = std.mem.Allocator;

// GLib headers cannot be translated by Zig; declare the stable GIO ABI only.
extern fn g_content_type_guess(filename: [*:0]const u8, data: ?[*]const u8, size: usize, uncertain: ?*c_int) ?[*:0]u8;
extern fn g_content_type_get_icon(content_type: [*:0]const u8) ?*anyopaque;
extern fn g_app_info_get_default_for_type(content_type: [*:0]const u8, must_support_uris: c_int) ?*anyopaque;
extern fn g_app_info_get_icon(app: *anyopaque) ?*anyopaque;
extern fn g_themed_icon_get_type() usize;
extern fn g_file_icon_get_type() usize;
extern fn g_type_check_instance_is_a(instance: *anyopaque, gtype: usize) c_int;
extern fn g_themed_icon_get_names(icon: *anyopaque) [*:null]const ?[*:0]const u8;
extern fn g_file_icon_get_file(icon: *anyopaque) *anyopaque;
extern fn g_file_get_path(file: *anyopaque) ?[*:0]u8;
extern fn g_object_unref(object: *anyopaque) void;
extern fn g_free(memory: ?*anyopaque) void;

pub const Resolver = struct {
    // All storage, including cached candidate lists, belongs to the snapshot.
    allocator: Allocator,
    by_type: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    pub fn candidates(self: *Resolver, filename: [:0]const u8) ![]const []const u8 {
        // Filename globs come from shared-mime-info, including app-installed
        // types such as OpenSCAD. Never read arbitrary file contents here.
        const content_type = g_content_type_guess(filename, null, 0, null) orelse return &.{};
        defer g_free(content_type);
        const key = std.mem.span(content_type);
        if (self.by_type.get(key)) |cached| return cached;
        var names: std.ArrayList([]const u8) = .empty;
        const mime_icon = g_content_type_get_icon(content_type);
        defer if (mime_icon) |icon| g_object_unref(icon);
        // A specific file icon wins. A plain document fallback must not hide
        // the icon of the user's associated application.
        if (mime_icon) |icon| try appendIcon(self.allocator, &names, icon, true);
        if (g_app_info_get_default_for_type(content_type, 0)) |app| {
            defer g_object_unref(app);
            if (g_app_info_get_icon(app)) |icon| try appendIcon(self.allocator, &names, icon, false);
        }
        if (mime_icon) |icon| try appendIcon(self.allocator, &names, icon, false);
        const result = try names.toOwnedSlice(self.allocator);
        try self.by_type.put(self.allocator, try self.allocator.dupe(u8, key), result);
        return result;
    }
};

fn appendIcon(a: Allocator, names: *std.ArrayList([]const u8), icon: *anyopaque, specific_only: bool) !void {
    if (g_type_check_instance_is_a(icon, g_themed_icon_get_type()) != 0) {
        const candidates = g_themed_icon_get_names(icon);
        var i: usize = 0;
        while (candidates[i]) |candidate| : (i += 1) {
            const name = std.mem.span(candidate);
            if (specific_only and genericDocument(name)) continue;
            try appendName(a, names, name);
        }
    } else if (g_type_check_instance_is_a(icon, g_file_icon_get_type()) != 0) {
        const path = g_file_get_path(g_file_icon_get_file(icon)) orelse return;
        defer g_free(path);
        try appendName(a, names, std.mem.span(path));
    }
}

fn genericDocument(name: []const u8) bool {
    const base = if (std.mem.endsWith(u8, name, "-symbolic")) name[0 .. name.len - "-symbolic".len] else name;
    return std.mem.eql(u8, base, "text-x-generic") or std.mem.eql(u8, base, "application-x-generic") or std.mem.eql(u8, base, "application-octet-stream");
}

fn appendName(a: Allocator, names: *std.ArrayList([]const u8), name: []const u8) !void {
    for (names.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    try names.append(a, try a.dupe(u8, name));
}

pub fn dupeCandidates(a: Allocator, names: []const []const u8) ![]const []const u8 {
    const result = try a.alloc([]const u8, names.len);
    for (names, 0..) |name, i| result[i] = try a.dupe(u8, name);
    return result;
}

const List = extern struct {
    data: *anyopaque,
    next: ?*List = null,
    prev: ?*List = null,
};
extern fn g_list_free(list: ?*List) void;
extern fn g_object_ref(object: *anyopaque) *anyopaque;
extern fn g_app_info_get_all() ?*List;
extern fn g_app_info_get_all_for_type(content_type: [*:0]const u8) ?*List;
extern fn g_app_info_equal(a: *anyopaque, b: *anyopaque) c_int;
extern fn g_app_info_should_show(app: *anyopaque) c_int;
extern fn g_app_info_get_display_name(app: *anyopaque) [*:0]const u8;
extern fn g_app_info_supports_files(app: *anyopaque) c_int;
extern fn g_app_info_supports_uris(app: *anyopaque) c_int;
extern fn g_app_info_set_as_default_for_type(app: *anyopaque, content_type: [*:0]const u8, err: ?*?*anyopaque) c_int;
extern fn g_file_new_for_path(path: [*:0]const u8) *anyopaque;
extern fn g_app_info_launch(app: *anyopaque, files: ?*List, context: ?*anyopaque, err: ?*?*anyopaque) c_int;

/// A dialog-owned snapshot: directory rescans cannot change its launch targets.
pub const Applications = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    paths: []const [:0]const u8 = &.{},
    content_type: [:0]const u8 = "application/octet-stream",
    same_type: bool = true,
    recommended: usize = 0,

    pub const Entry = struct {
        app: *anyopaque,
        name: []const u8,
        icons: []const []const u8,
        is_default: bool,
    };

    pub fn init(allocator: Allocator, paths: []const []const u8) !Applications {
        var self: Applications = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer self.deinit();
        const a = self.arena.allocator();
        const owned = try a.alloc([:0]const u8, paths.len);
        for (paths, 0..) |path, i| {
            owned[i] = try a.dupeZ(u8, path);
            const kind = g_content_type_guess(owned[i], null, 0, null) orelse return error.UnknownContentType;
            defer g_free(kind);
            if (i == 0) self.content_type = try a.dupeZ(u8, std.mem.span(kind)) else if (!std.mem.eql(u8, self.content_type, std.mem.span(kind))) self.same_type = false;
        }
        self.paths = owned;
        const default = if (self.same_type) g_app_info_get_default_for_type(self.content_type, 0) else null;
        defer if (default) |app| g_object_unref(app);
        if (default) |app| try self.append(app, default, false);
        if (self.same_type) try self.appendList(g_app_info_get_all_for_type(self.content_type), default, false);
        self.recommended = self.entries.items.len;
        try self.appendList(g_app_info_get_all(), default, true);
        std.mem.sort(Entry, self.entries.items[self.recommended..], {}, struct {
            fn less(_: void, a_entry: Entry, b_entry: Entry) bool {
                return std.ascii.lessThanIgnoreCase(a_entry.name, b_entry.name);
            }
        }.less);
        return self;
    }

    fn appendList(self: *Applications, list: ?*List, default: ?*anyopaque, visible_only: bool) !void {
        defer {
            var node = list;
            while (node) |it| : (node = it.next) g_object_unref(it.data);
            g_list_free(list);
        }
        var node = list;
        while (node) |it| : (node = it.next) try self.append(it.data, default, visible_only);
    }

    fn append(self: *Applications, app: *anyopaque, default: ?*anyopaque, visible_only: bool) !void {
        if ((visible_only and g_app_info_should_show(app) == 0) or
            (g_app_info_supports_files(app) == 0 and g_app_info_supports_uris(app) == 0)) return;
        for (self.entries.items) |entry| if (g_app_info_equal(app, entry.app) != 0) return;
        const a = self.arena.allocator();
        var names: std.ArrayList([]const u8) = .empty;
        if (g_app_info_get_icon(app)) |icon| try appendIcon(a, &names, icon, false);
        try self.entries.append(a, .{
            .app = app,
            .name = try a.dupe(u8, std.mem.span(g_app_info_get_display_name(app))),
            .icons = try names.toOwnedSlice(a),
            .is_default = if (default) |d| g_app_info_equal(app, d) != 0 else false,
        });
        _ = g_object_ref(app);
    }

    pub fn deinit(self: *Applications) void {
        for (self.entries.items) |entry| g_object_unref(entry.app);
        self.arena.deinit();
    }

    pub fn launch(self: *Applications, index: usize, remember: bool) !void {
        const app = self.entries.items[index].app;
        const a = self.arena.child_allocator;
        const files = try a.alloc(List, self.paths.len);
        defer a.free(files);
        for (self.paths, 0..) |path, i| files[i] = .{
            .data = g_file_new_for_path(path),
            .next = if (i + 1 < files.len) &files[i + 1] else null,
            .prev = if (i > 0) &files[i - 1] else null,
        };
        defer for (files) |file| g_object_unref(file.data);
        if (g_app_info_launch(app, if (files.len > 0) &files[0] else null, null, null) == 0) return error.LaunchFailed;
        if (remember and self.same_type and g_app_info_set_as_default_for_type(app, self.content_type, null) == 0) return error.DefaultFailed;
    }
};

extern fn g_app_info_get_id(app: *anyopaque) ?[*:0]const u8;

/// Keep the bundled PDF viewer fallback, but honor an explicit alternative.
pub fn hasAlternativeDefault(path: []const u8, bundled_id: []const u8) bool {
    const filename = std.heap.c_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.c_allocator.free(filename);
    const kind = g_content_type_guess(filename, null, 0, null) orelse return false;
    defer g_free(kind);
    const app = g_app_info_get_default_for_type(kind, 0) orelse return false;
    defer g_object_unref(app);
    const id = g_app_info_get_id(app) orelse return true;
    return !std.mem.eql(u8, std.mem.span(id), bundled_id);
}
