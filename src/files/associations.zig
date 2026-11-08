//! MIME icons and application associations. File types and their icons come
//! from `mime_db` (shared-mime-info read directly); applications and defaults
//! go through the system GIO database so every other program agrees.
//! Icon candidates run on the directory worker; application snapshots belong
//! to the Open With dialog. Neither owns the UI icon cache.
const std = @import("std");
const mime_db = @import("../mime_db.zig");
const collation = @import("collation.zig");
const Allocator = std.mem.Allocator;

// GLib headers cannot be translated by Zig; declare the stable GIO ABI only.
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
        const key = mime_db.guess(filename);
        if (self.by_type.get(key)) |cached| return cached;
        var names: std.ArrayList([]const u8) = .empty;
        var buffer: mime_db.IconBuffer = .{};
        const mime_icons = mime_db.iconNames(key, &buffer);
        // A specific file icon wins. A plain document fallback must not hide
        // the icon of the user's associated application.
        try appendMimeIcons(self.allocator, &names, mime_icons, true);
        var type_z: TypeZ = undefined;
        if (type_z.set(key)) |content_type| if (g_app_info_get_default_for_type(content_type, 0)) |app| {
            defer g_object_unref(app);
            if (g_app_info_get_icon(app)) |icon| try appendIcon(self.allocator, &names, icon, false);
        };
        try appendMimeIcons(self.allocator, &names, mime_icons, false);
        const result = try names.toOwnedSlice(self.allocator);
        try self.by_type.put(self.allocator, try self.allocator.dupe(u8, key), result);
        return result;
    }
};

/// A MIME type as a C string for GIO calls; types longer than the buffer
/// cannot be real and simply have no application lookup.
const TypeZ = struct {
    buf: [256]u8,

    fn set(self: *TypeZ, mime: []const u8) ?[*:0]const u8 {
        if (mime.len >= self.buf.len) return null;
        @memcpy(self.buf[0..mime.len], mime);
        self.buf[mime.len] = 0;
        return @ptrCast(&self.buf);
    }
};

/// The names a themed GIO icon for the type would carry: each name, then each
/// again with a "-symbolic" suffix as a last resort.
fn appendMimeIcons(a: Allocator, names: *std.ArrayList([]const u8), mime_icons: []const []const u8, specific_only: bool) !void {
    for (mime_icons) |name| {
        if (specific_only and genericDocument(name)) continue;
        try appendName(a, names, name);
    }
    for (mime_icons) |name| {
        if (specific_only and genericDocument(name)) continue;
        const symbolic = try std.fmt.allocPrint(a, "{s}-symbolic", .{name});
        defer a.free(symbolic);
        try appendName(a, names, symbolic);
    }
}

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
extern fn g_get_user_config_dir() [*:0]const u8;
extern fn g_key_file_new() *anyopaque;
extern fn g_key_file_unref(key_file: *anyopaque) void;
extern fn g_key_file_load_from_file(key_file: *anyopaque, filename: [*:0]const u8, flags: c_int, err: ?*?*anyopaque) c_int;
extern fn g_key_file_get_keys(key_file: *anyopaque, group: [*:0]const u8, length: ?*usize, err: ?*?*anyopaque) ?[*:null]?[*:0]u8;
extern fn g_strfreev(strings: ?[*:null]?[*:0]u8) void;
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
        sort_key: []const u8 = "",
        icons: []const []const u8,
        is_default: bool,
    };

    pub fn init(allocator: Allocator, paths: []const []const u8) !Applications {
        var self: Applications = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer self.deinit();
        const a = self.arena.allocator();
        const owned = try a.alloc([:0]const u8, paths.len);
        for (paths, 0..) |path, i| {
            owned[i] = try a.dupeSentinel(u8, path, 0);
            const kind = mime_db.guess(owned[i]);
            if (i == 0) self.content_type = try a.dupeSentinel(u8, kind, 0) else if (!std.mem.eql(u8, self.content_type, kind)) self.same_type = false;
        }
        self.paths = owned;
        const default = if (self.same_type) g_app_info_get_default_for_type(self.content_type, 0) else null;
        defer if (default) |app| g_object_unref(app);
        if (default) |app| try self.append(app, default, false);
        if (self.same_type) try self.appendList(g_app_info_get_all_for_type(self.content_type), default, false);
        self.recommended = self.entries.items.len;
        try self.appendList(g_app_info_get_all(), default, true);
        var locale = collation.Locale.init(@import("settings.zig").formatsLocale()) orelse collation.Locale.init("C").?;
        defer locale.deinit();
        for (self.entries.items) |*entry| entry.sort_key = try locale.key(a, entry.name);
        std.mem.sort(Entry, self.entries.items[self.recommended..], {}, struct {
            fn less(_: void, a_entry: Entry, b_entry: Entry) bool {
                return collation.order(a_entry.sort_key, b_entry.sort_key, a_entry.name, b_entry.name, "", "") == .lt;
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

    fn saveDefault(self: *Applications, app: *anyopaque) !void {
        // GIO merges aliases in file order when reading defaults, but its
        // setter updates only the exact key. An older video/x-matroska entry
        // can therefore override a newly saved video/matroska preference.
        const a = self.arena.child_allocator;
        const filename = try std.fmt.allocPrintSentinel(a, "{s}/mimeapps.list", .{g_get_user_config_dir()}, 0);
        defer a.free(filename);
        const key_file = g_key_file_new();
        defer g_key_file_unref(key_file);
        if (g_key_file_load_from_file(key_file, filename, 0, null) != 0) {
            if (g_key_file_get_keys(key_file, "Default Applications", null, null)) |keys| {
                defer g_strfreev(keys);
                var i: usize = 0;
                while (keys[i]) |key| : (i += 1) {
                    if (std.mem.eql(u8, std.mem.span(key), self.content_type)) continue;
                    if (!mime_db.equals(std.mem.span(key), self.content_type)) continue;
                    if (g_app_info_set_as_default_for_type(app, key, null) == 0) return error.DefaultFailed;
                }
            }
        }
        if (g_app_info_set_as_default_for_type(app, self.content_type, null) == 0) return error.DefaultFailed;
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
        if (remember and self.same_type) self.saveDefault(app) catch return error.DefaultFailed;
    }
};

extern fn g_app_info_get_id(app: *anyopaque) ?[*:0]const u8;
extern fn g_key_file_get_string(key_file: *anyopaque, group: [*:0]const u8, key: [*:0]const u8, err: ?*?*anyopaque) ?[*:0]u8;

/// Whether the user chose, in their own mimeapps.list, a default application
/// for this file's type other than `bundled_id`. GIO's own default also names
/// whatever happens to be installed first, which is not a choice: a bundled
/// app that has no explicit rival keeps its files.
pub fn hasExplicitDefault(path: []const u8, bundled_id: []const u8) bool {
    const filename = std.heap.c_allocator.dupeSentinel(u8, path, 0) catch return false;
    defer std.heap.c_allocator.free(filename);
    const content_type = mime_db.guess(filename);
    const list = std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}/mimeapps.list", .{g_get_user_config_dir()}, 0) catch return false;
    defer std.heap.c_allocator.free(list);
    const key_file = g_key_file_new();
    defer g_key_file_unref(key_file);
    if (g_key_file_load_from_file(key_file, list, 0, null) == 0) return false;
    const keys = g_key_file_get_keys(key_file, "Default Applications", null, null) orelse return false;
    defer g_strfreev(keys);
    var i: usize = 0;
    while (keys[i]) |key| : (i += 1) {
        if (!mime_db.equals(std.mem.span(key), content_type)) continue;
        const value = g_key_file_get_string(key_file, "Default Applications", key, null) orelse continue;
        defer g_free(value);
        // A list of desktop ids, the first of which is the preferred one.
        var ids = std.mem.tokenizeScalar(u8, std.mem.span(value), ';');
        const first = ids.next() orelse continue;
        if (!std.mem.eql(u8, first, bundled_id)) return true;
    }
    return false;
}

/// Launch through the same MIME default that Open With displays. A URI-based
/// launch can pick the handler for file:// instead of the file's content type.
pub fn launchDefault(path: []const u8) !void {
    const filename = try std.heap.c_allocator.dupeSentinel(u8, path, 0);
    defer std.heap.c_allocator.free(filename);
    var kind: TypeZ = undefined;
    const content_type = kind.set(mime_db.guess(filename)) orelse return error.NoDefaultApplication;
    const app = g_app_info_get_default_for_type(content_type, 0) orelse return error.NoDefaultApplication;
    defer g_object_unref(app);
    const file = g_file_new_for_path(filename);
    defer g_object_unref(file);
    var files: List = .{ .data = file };
    if (g_app_info_launch(app, &files, null, null) == 0) return error.LaunchFailed;
}

/// Keep the bundled PDF viewer fallback, but honor an explicit alternative.
pub fn hasAlternativeDefault(path: []const u8, bundled_id: []const u8) bool {
    const filename = std.heap.c_allocator.dupeSentinel(u8, path, 0) catch return false;
    defer std.heap.c_allocator.free(filename);
    var kind: TypeZ = undefined;
    const content_type = kind.set(mime_db.guess(filename)) orelse return false;
    const app = g_app_info_get_default_for_type(content_type, 0) orelse return false;
    defer g_object_unref(app);
    const id = g_app_info_get_id(app) orelse return true;
    return !std.mem.eql(u8, std.mem.span(id), bundled_id);
}
