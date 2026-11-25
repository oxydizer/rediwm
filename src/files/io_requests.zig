//! Metadata and small-mutation requests (docs/plans/files-io-threading-and-
//! ownership.md §8, audit U7 to U12). They are not jobs: a window sends one,
//! a service task runs it, and its reply goes to one of the window's reserved
//! reply slots. The window shows a pending state meanwhile and never waits.
//!
//! A request owns its strings in an arena; a reply owns what it carries.
//! Both travel between threads by pointer and are freed by whoever holds them
//! last.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ops = @import("ops.zig");
const trash = @import("trash.zig");
const properties = @import("properties.zig");
const pins = @import("pins.zig");
const c = @import("c.zig").api;

pub const Request = union(enum) {
    /// Puts Trash entries back (`trash.restoreMany`): `names`, or every
    /// entry when `all`.
    restore: struct { trash_dir: []const u8, names: []const []const u8 = &.{}, all: bool = false },
    create_folder: struct { dir: []const u8, name: []const u8 },
    create_file: struct { dir: []const u8, name: []const u8 },
    rename: struct { target: []const u8, name: []const u8 },
    /// Reads what the Properties dialog shows.
    properties: struct { path: []const u8 },
    toggle_permission: struct { path: []const u8, bit: u8 },
    /// `mkdir -p`, then whether it is a folder.
    make_directory: struct { path: []const u8 },
    /// What each path is now: folder, file or missing.
    path_kinds: struct { paths: []const []const u8 },
    /// The real path of each path, and whether it is a folder.
    canonical: struct { paths: []const []const u8 },
    /// File chooser checks on confirm (`app_chooser.collectChooser`).
    chooser: ChooserCheck,
    /// A free name in `dir` for `name` ("name (1)"), for a conflict renamed.
    unique_name: struct { dir: []const u8, name: []const u8 },
    /// What the conflict dialog shows. Answered by the coordinator from the
    /// Manager, in memory: never on a worker (`answeredByCoordinator`).
    conflict_details: struct { conflict_id: u64 },
};

/// Requests about Manager state: the coordinator answers them itself.
pub fn answeredByCoordinator(request: *const Request) bool {
    return request.* == .conflict_details;
}

pub const ConflictDetails = struct {
    conflict_id: u64,
    job_id: u64,
    /// Owned.
    destination_path: []u8,
    /// Both sides are folders: Merge is offered.
    can_merge: bool,
};

pub const ChooserCheck = struct {
    pub const Mode = enum { open, save, folder };
    mode: Mode,
    /// Open by name, or save: the one path named in the filename field.
    named: ?[]const u8 = null,
    /// The folder shown: where a save goes.
    parent: []const u8 = "/",
    /// Save over an existing entry was confirmed already.
    overwrite_confirmed: bool = false,
    /// Open or folder by selection: the selected items, in order.
    selected: []const []const u8 = &.{},
    /// Folder mode with nothing selected: the folder shown, if loaded.
    fallback: ?[]const u8 = null,
    /// Names the caller wants to save into the chosen folder; each gets a
    /// free name there.
    files: []const []const u8 = &.{},
};

pub const ChooserVerdict = enum {
    /// The named path is a folder: browse it.
    navigate,
    /// Save over an existing entry: ask first.
    confirm_overwrite,
    /// Everything checked out: `paths` are the result.
    accept,
    inaccessible,
    no_selection,
};

pub const ChooserResult = struct {
    verdict: ChooserVerdict,
    paths: [][]u8 = &.{},
};

pub const Canonical = struct {
    /// Null when the path could not be resolved.
    path: ?[]u8,
    is_dir: bool = false,
};

/// An owned request: its strings live in the arena.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    request: Request,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

pub const ReplyData = union(enum) {
    /// A mutation: null on success.
    done: ?anyerror,
    restore: trash.Summary,
    properties: anyerror!properties.State,
    mode: anyerror!c.mode_t,
    kinds: []pins.Kind,
    canonical: []Canonical,
    chooser: ChooserResult,
    unique_name: anyerror![]u8,
    /// Null when the conflict is no longer at the head of the queue.
    conflict: ?ConflictDetails,
};

pub const Reply = struct {
    allocator: Allocator,
    /// The request's tag, chosen by the window.
    tag: u64,
    data: ReplyData,

    pub fn destroy(self: *Reply) void {
        switch (self.data) {
            .properties => |*state| if (state.*) |*s| s.deinit() else |_| {},
            .kinds => |kinds| self.allocator.free(kinds),
            .canonical => |entries| {
                for (entries) |entry| if (entry.path) |path| self.allocator.free(path);
                self.allocator.free(entries);
            },
            .unique_name => |name| if (name) |n| self.allocator.free(n) else |_| {},
            .conflict => |details| if (details) |d| self.allocator.free(d.destination_path),
            .chooser => |result| {
                for (result.paths) |path| self.allocator.free(path);
                self.allocator.free(result.paths);
            },
            else => {},
        }
        self.allocator.destroy(self);
    }
};

/// Copies `request`'s strings into a new arena.
pub fn create(allocator: Allocator, request: Request) !Owned {
    var owned: Owned = .{ .arena = .init(allocator), .request = undefined };
    errdefer owned.arena.deinit();
    const a = owned.arena.allocator();
    owned.request = switch (request) {
        .restore => |r| .{ .restore = .{ .trash_dir = try a.dupe(u8, r.trash_dir), .names = try dupeAll(a, r.names), .all = r.all } },
        .create_folder => |r| .{ .create_folder = .{ .dir = try a.dupe(u8, r.dir), .name = try a.dupe(u8, r.name) } },
        .create_file => |r| .{ .create_file = .{ .dir = try a.dupe(u8, r.dir), .name = try a.dupe(u8, r.name) } },
        .rename => |r| .{ .rename = .{ .target = try a.dupe(u8, r.target), .name = try a.dupe(u8, r.name) } },
        .properties => |r| .{ .properties = .{ .path = try a.dupe(u8, r.path) } },
        .toggle_permission => |r| .{ .toggle_permission = .{ .path = try a.dupe(u8, r.path), .bit = r.bit } },
        .make_directory => |r| .{ .make_directory = .{ .path = try a.dupe(u8, r.path) } },
        .path_kinds => |r| .{ .path_kinds = .{ .paths = try dupeAll(a, r.paths) } },
        .canonical => |r| .{ .canonical = .{ .paths = try dupeAll(a, r.paths) } },
        .chooser => |r| .{ .chooser = .{
            .mode = r.mode,
            .named = if (r.named) |p| try a.dupe(u8, p) else null,
            .parent = try a.dupe(u8, r.parent),
            .overwrite_confirmed = r.overwrite_confirmed,
            .selected = try dupeAll(a, r.selected),
            .fallback = if (r.fallback) |p| try a.dupe(u8, p) else null,
            .files = try dupeAll(a, r.files),
        } },
        .unique_name => |r| .{ .unique_name = .{ .dir = try a.dupe(u8, r.dir), .name = try a.dupe(u8, r.name) } },
        .conflict_details => |r| .{ .conflict_details = r },
    };
    return owned;
}

fn dupeAll(a: Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, items.len);
    for (items, 0..) |item, i| out[i] = try a.dupe(u8, item);
    return out;
}

/// Runs a request on a service task worker. Null only when even the reply
/// could not be allocated.
pub fn execute(allocator: Allocator, io: std.Io, tag: u64, request: *const Request) ?*Reply {
    const reply = allocator.create(Reply) catch return null;
    reply.* = .{ .allocator = allocator, .tag = tag, .data = run(allocator, io, request) };
    return reply;
}

fn run(allocator: Allocator, io: std.Io, request: *const Request) ReplyData {
    return switch (request.*) {
        .restore => |r| .{ .restore = restore(allocator, r.trash_dir, r.names, r.all) },
        .create_folder => |r| .{ .done = if (ops.createFolder(allocator, r.dir, r.name)) |_| null else |err| err },
        .create_file => |r| .{ .done = if (ops.createFile(allocator, r.dir, r.name)) |_| null else |err| err },
        .rename => |r| .{ .done = if (ops.renameItem(allocator, r.target, r.name)) |_| null else |err| err },
        .properties => |r| .{ .properties = properties.State.init(allocator, r.path, null) },
        .toggle_permission => |r| .{ .mode = properties.togglePathPermission(r.path, r.bit) },
        .make_directory => |r| .{ .done = makeDirectory(io, r.path) },
        .path_kinds => |r| .{ .kinds = kinds: {
            const kinds = allocator.alloc(pins.Kind, r.paths.len) catch break :kinds &.{};
            for (r.paths, kinds) |path, *kind| kind.* = pins.kindOf(path);
            break :kinds kinds;
        } },
        .canonical => |r| .{ .canonical = canonicalAll(allocator, r.paths) },
        .chooser => |r| .{ .chooser = checkChooser(allocator, r) catch .{ .verdict = .inaccessible } },
        .unique_name => |r| .{ .unique_name = ops.generateUniqueName(allocator, r.dir, r.name) },
        // Never reaches a worker (`answeredByCoordinator`).
        .conflict_details => .{ .conflict = null },
    };
}

fn restore(allocator: Allocator, trash_dir: []const u8, names: []const []const u8, all: bool) trash.Summary {
    if (!all) return trash.restoreMany(allocator, trash_dir, names);
    const listed = trash.listEntries(allocator, trash_dir) catch return .{ .failed = 1 };
    defer allocator.free(listed);
    defer trash.freeNames(allocator, listed);
    const view: []const []const u8 = @ptrCast(listed);
    return trash.restoreMany(allocator, trash_dir, view);
}

fn makeDirectory(io: std.Io, path: []const u8) ?anyerror {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| return err;
    if (pins.kindOf(path) != .dir) return error.NotDir;
    return null;
}

fn canonicalAll(allocator: Allocator, paths: []const []const u8) []Canonical {
    const out = allocator.alloc(Canonical, paths.len) catch return &.{};
    for (paths, out) |path, *entry| entry.* = canonical(allocator, path);
    return out;
}

fn canonical(allocator: Allocator, path: []const u8) Canonical {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{path}, 0) catch return .{ .path = null };
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const real = c.realpath(name, &buffer) orelse return .{ .path = null };
    var stat: c.struct_stat = undefined;
    const is_dir = c.stat(real, &stat) == 0 and stat.st_mode & c.S_IFMT == c.S_IFDIR;
    return .{ .path = allocator.dupe(u8, std.mem.span(real)) catch null, .is_dir = is_dir };
}

fn zPath(buf: *[std.fs.max_path_bytes]u8, path: []const u8) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}", .{path}, 0);
}

/// The chooser's confirm, as `app_chooser.collectChooser` did it on the
/// window's thread.
fn checkChooser(allocator: Allocator, check: ChooserCheck) !ChooserResult {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var stat: c.struct_stat = undefined;
    if (check.named) |path| {
        const z = try zPath(&buf, path);
        const exists = c.stat(z, &stat) == 0;
        if (exists and stat.st_mode & c.S_IFMT == c.S_IFDIR) return .{ .verdict = .navigate };
        if (check.mode == .open and (!exists or c.access(z, c.R_OK) != 0)) return .{ .verdict = .inaccessible };
        if (check.mode == .save) {
            var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (c.access(try zPath(&parent_buf, check.parent), c.W_OK | c.X_OK) != 0) return .{ .verdict = .inaccessible };
            // lstat also detects a dangling symlink, which saving would replace.
            if (!check.overwrite_confirmed and c.lstat(z, &stat) == 0) return .{ .verdict = .confirm_overwrite };
        }
        try paths.append(allocator, try allocator.dupe(u8, path));
    } else {
        for (check.selected) |path| {
            const z = try zPath(&buf, path);
            if (c.stat(z, &stat) != 0 or c.access(z, c.R_OK) != 0 or
                (stat.st_mode & c.S_IFMT == c.S_IFDIR) != (check.mode == .folder)) return .{ .verdict = .inaccessible };
            try paths.append(allocator, try allocator.dupe(u8, path));
        }
        if (paths.items.len == 0) if (check.fallback) |folder| try paths.append(allocator, try allocator.dupe(u8, folder));
    }
    if (paths.items.len == 0) return .{ .verdict = .no_selection };
    if (check.files.len > 0) {
        const folder = paths.items[0];
        defer allocator.free(folder);
        paths.clearRetainingCapacity();
        for (check.files) |name| {
            var index: usize = 0;
            while (true) : (index += 1) {
                if (index > 10000) return error.TooManyFiles;
                const path = if (index == 0) try std.fs.path.join(allocator, &.{ folder, name }) else try std.fmt.allocPrint(allocator, "{s}/{s}.{d}", .{ folder, name, index });
                var exists = c.lstat(zPath(&buf, path) catch {
                    allocator.free(path);
                    return error.NameTooLong;
                }, &stat) == 0;
                for (paths.items) |chosen| if (std.mem.eql(u8, chosen, path)) {
                    exists = true;
                };
                if (exists) {
                    allocator.free(path);
                    continue;
                }
                paths.append(allocator, path) catch |err| {
                    allocator.free(path);
                    return err;
                };
                break;
            }
        }
    }
    return .{ .verdict = .accept, .paths = try paths.toOwnedSlice(allocator) };
}
