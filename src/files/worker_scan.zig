//! The listing worker's scanning: a folder or an archive's inside into a
//! `Snapshot` (items, Git state, changed files), with collation keys. Runs on
//! the worker thread; split from `worker.zig`, which owns the thread.
const std = @import("std");
const tr = @import("i18n").tr;
const archive = @import("archive.zig");
const c = @import("c.zig").api;
const platform = @import("platform");
const theme = @import("../icon_theme.zig");
const icons = @import("../icon_cache.zig");
const git = @import("git.zig");
const recent = @import("recent.zig");
const collation = @import("collation.zig");
const Allocator = std.mem.Allocator;
const worker = @import("worker.zig");
const Worker = worker.Worker;
const Item = worker.Item;
const Snapshot = worker.Snapshot;

pub const ArchiveCache = struct {
    path: ?[]u8 = null,
    stat: c.struct_stat = undefined,
    index: ?archive.Index = null,
    pub fn clear(self: *ArchiveCache, mem: Allocator) void {
        if (self.path) |p| mem.free(p);
        if (self.index) |*index| index.deinit();
        self.* = .{};
    }
};

pub fn scanArchive(self: *Worker, path: []const u8, archive_len: usize, hidden: bool, request: u64, cache: *ArchiveCache) *Snapshot {
    const snap = std.heap.c_allocator.create(Snapshot) catch @panic("OOM");
    snap.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator), .request_id = request, .dir = "", .items = &.{} };
    fillArchive(self, snap, path, archive_len, hidden, cache) catch |err| {
        snap.items = &.{};
        snap.err_msg = archive.message(err);
    };
    return snap;
}

pub fn fillArchive(self: *Worker, snap: *Snapshot, path: []const u8, archive_len: usize, hidden: bool, cache: *ArchiveCache) !void {
    const mem = snap.arena.allocator();
    snap.dir = try mem.dupe(u8, path);
    const source = path[0..archive_len];
    const zsource = try mem.dupeSentinel(u8, source, 0);
    var stat: c.struct_stat = undefined;
    if (c.stat(zsource, &stat) != 0) return error.OpenArchiveFailed;
    if (cache.path == null or !std.mem.eql(u8, cache.path.?, source) or
        cache.stat.st_ino != stat.st_ino or cache.stat.st_dev != stat.st_dev or cache.stat.st_size != stat.st_size or
        !std.meta.eql(cache.stat.st_mtim, stat.st_mtim) or !std.meta.eql(cache.stat.st_ctim, stat.st_ctim))
    {
        cache.clear(self.allocator);
        var index = try archive.Index.read(self.allocator, source, &self.stop);
        errdefer index.deinit();
        cache.path = try self.allocator.dupe(u8, source);
        cache.index = index;
        cache.stat = stat;
    }
    const member_dir = if (path.len > archive_len) path[archive_len + 1 ..] else "";
    var exists = member_dir.len == 0;
    var items: std.ArrayList(Item) = .empty;
    for (cache.index.?.entries) |entry| {
        if (entry.directory and std.mem.eql(u8, entry.path, member_dir)) exists = true;
        if (!std.mem.eql(u8, std.fs.path.dirname(entry.path) orelse "", member_dir)) continue;
        const name = std.fs.path.basename(entry.path);
        if (!hidden and std.mem.startsWith(u8, name, ".")) continue;
        try items.append(mem, .{
            .name = try mem.dupe(u8, name),
            .path = try std.fmt.allocPrint(mem, "{s}/{s}", .{ source, entry.path }),
            .is_dir = entry.directory,
            .is_symlink = entry.link,
            .is_broken = entry.link,
            .bytes = entry.bytes,
            .mtime = entry.mtime,
            .icon_name = mimeIcon(name, entry.directory, entry.link, entry.link),
        });
    }
    if (!exists) return error.MemberNotFound;
    snap.items = try items.toOwnedSlice(mem);
}

/// A real listing preserves the spelling of its directory, including a
/// trailing separator at filesystem root.
pub fn listingPath(allocator: Allocator, dir: []const u8, name: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
}

pub fn scan(self: *Worker, dir_path: []const u8, show_hidden: bool, req_id: u64) *Snapshot {
    const snap = std.heap.c_allocator.create(Snapshot) catch @panic("OOM");
    snap.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        .request_id = req_id,
        .dir = "",
        .items = &.{},
        .err_msg = null,
    };
    const mem = snap.arena.allocator();
    snap.dir = mem.dupe(u8, dir_path) catch {
        snap.err_msg = tr("Out of memory");
        return snap;
    };

    if (recent.isLocation(dir_path)) {
        const entries = recent.read(mem, self.io, self.environ) catch {
            snap.err_msg = tr("Could not read recent files");
            return snap;
        };
        var list: std.ArrayList(Item) = .empty;
        var owners: std.AutoHashMapUnmanaged(c.uid_t, []const u8) = .empty;
        var associations: @import("associations.zig").Resolver = .{ .allocator = mem };
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (entries) |entry| {
            const name = std.fs.path.basename(entry.path);
            if (!show_hidden and std.mem.startsWith(u8, name, ".")) continue;
            if (seen.contains(entry.path)) continue;
            var item = statItem(mem, &owners, &associations, name, entry.path) orelse continue;
            if (item.is_dir or item.is_broken or (item.mode & c.S_IFMT != c.S_IFREG and !item.is_symlink)) continue;
            item.opened = entry.opened;
            seen.put(mem, entry.path, {}) catch continue;
            if (item.is_dir) item.icon_name = theme.folderName(mem, self.io, self.environ, item.path);
            list.append(mem, item) catch continue;
        }
        snap.items = list.toOwnedSlice(mem) catch &.{};
        return snap;
    }

    var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch |err| {
        snap.err_msg = switch (err) {
            error.FileNotFound => tr("Folder not found"),
            error.AccessDenied => tr("Permission denied"),
            error.NotDir => tr("Not a directory"),
            else => tr("Could not open folder"),
        };
        return snap;
    };
    defer dir.close(self.io);

    const hidden_entries = if (show_hidden)
        ""
    else
        dir.readFileAlloc(self.io, ".hidden", mem, .limited(1 << 20)) catch "";

    var it = dir.iterate();
    var list: std.ArrayList(Item) = .empty;
    var owners: std.AutoHashMapUnmanaged(c.uid_t, []const u8) = .empty;
    var associations: @import("associations.zig").Resolver = .{ .allocator = mem };

    while (it.next(self.io) catch null) |entry| {
        if (!show_hidden and (std.mem.startsWith(u8, entry.name, ".") or isHiddenEntry(hidden_entries, entry.name))) continue;
        const full_path = listingPath(mem, dir_path, entry.name) catch continue;
        var item = statItem(mem, &owners, &associations, entry.name, full_path) orelse continue;
        if (item.is_dir) item.icon_name = theme.folderName(mem, self.io, self.environ, item.path);
        list.append(mem, item) catch continue;
    }

    // Temporarily disable Git integration while file operations are being completed.
    const git_enabled = false;
    snap.repository = if (git_enabled) git.scan(mem, self.io, self.environ, dir_path) catch null else null;
    if (snap.repository) |repo| {
        for (list.items) |*item| {
            item.git_status = repo.status(item.name);
            item.git_lines = repo.lines(item.name);
        }
        snap.changed = changedItems(mem, repo, dir_path, show_hidden, &owners, &associations, &snap.changed_truncated);
        // Missing tracked files are informational rows, never file-operation targets.
        const prefix = if (repo.directory.len > repo.root.len) repo.directory[repo.root.len + 1 ..] else "";
        for (repo.changes) |change| {
            if (change.status != .deleted) continue;
            var name = change.path;
            if (prefix.len > 0) {
                if (!std.mem.startsWith(u8, name, prefix) or name.len <= prefix.len or name[prefix.len] != '/') continue;
                name = name[prefix.len + 1 ..];
            }
            if (std.mem.indexOfScalar(u8, name, '/') != null or (!show_hidden and std.mem.startsWith(u8, name, "."))) continue;
            var exists = false;
            for (list.items) |item| {
                if (std.mem.eql(u8, item.name, name)) {
                    exists = true;
                    break;
                }
            }
            if (exists) continue;
            list.append(mem, .{ .name = name, .path = std.fmt.allocPrint(mem, "{s}/{s}", .{ dir_path, name }) catch continue, .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = mimeIcon(name, false, false, false), .git_status = .deleted, .git_lines = repo.lines(name), .missing = true }) catch {};
        }
    }

    snap.items = list.toOwnedSlice(mem) catch &.{};
    return snap;
}

pub fn isHiddenEntry(contents: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const entry = std.mem.trimEnd(u8, line, "\r");
        if (entry.len > 0 and std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

pub fn prepareCollation(self: *Worker, snap: *Snapshot) !void {
    const mem = snap.arena.allocator();
    snap.collation_name = try mem.dupe(u8, self.collate.name());
    for ([_][]Item{ snap.items, snap.changed }) |items| for (items) |*item| {
        item.name_key = try self.collate.key(mem, item.name);
        if (item.label.len > 0) item.label_key = try self.collate.key(mem, item.label);
    };
    // Freeze expensive libc transformations once, also for archive and
    // Recent listings. UI re-sorts compare these byte keys only.
    std.mem.sort(Item, snap.items, {}, struct {
        fn less(_: void, a: Item, b: Item) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            return collation.order(a.name_key.?, b.name_key.?, a.name, b.name, a.path, b.path) == .lt;
        }
    }.less);
}

/// Describes one directory entry, or null when it vanished or cannot be read.
pub fn statItem(
    mem: Allocator,
    owners: *std.AutoHashMapUnmanaged(c.uid_t, []const u8),
    associations: *@import("associations.zig").Resolver,
    name: []const u8,
    full_path: [:0]const u8,
) ?Item {
    var lstat_buf: c.struct_stat = undefined;
    if (c.lstat(full_path, &lstat_buf) != 0) return null;

    const is_symlink = (lstat_buf.st_mode & c.S_IFMT) == c.S_IFLNK;
    var is_dir = false;
    var is_broken = false;
    var size = @as(i64, @intCast(lstat_buf.st_size));

    if (is_symlink) {
        var target_stat: c.struct_stat = undefined;
        if (c.stat(full_path, &target_stat) == 0) {
            is_dir = (target_stat.st_mode & c.S_IFMT) == c.S_IFDIR;
            size = @as(i64, @intCast(target_stat.st_size));
        } else {
            is_broken = true;
        }
    } else {
        is_dir = (lstat_buf.st_mode & c.S_IFMT) == c.S_IFDIR;
    }

    return .{
        .name = mem.dupe(u8, name) catch return null,
        .path = full_path,
        .is_dir = is_dir,
        .is_symlink = is_symlink,
        .is_broken = is_broken,
        .bytes = size,
        .mtime = @as(i64, @intCast(lstat_buf.st_mtim.tv_sec)),
        .mode = lstat_buf.st_mode,
        .owner_uid = lstat_buf.st_uid,
        .owner = owners.get(lstat_buf.st_uid) orelse blk: {
            const owner = ownerName(mem, lstat_buf.st_uid) catch return null;
            owners.put(mem, lstat_buf.st_uid, owner) catch {};
            break :blk owner;
        },
        .icon_name = mimeIcon(name, is_dir, is_symlink, is_broken),
        .icon_candidates = if (is_dir or is_broken) &.{} else associations.candidates(full_path) catch &.{},
    };
}

pub const max_changed_rows = 10_000;

fn hasHiddenComponent(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, ".")) return true;
    }
    return false;
}

/// One row per changed file under the folder, however deep. `label` is the
/// path from the folder, so identical names in different places stay apart.
fn changedItems(
    mem: Allocator,
    repo: git.Repository,
    dir_path: []const u8,
    show_hidden: bool,
    owners: *std.AutoHashMapUnmanaged(c.uid_t, []const u8),
    associations: *@import("associations.zig").Resolver,
    truncated: *bool,
) []Item {
    const prefix = if (repo.directory.len > repo.root.len) repo.directory[repo.root.len + 1 ..] else "";
    var list: std.ArrayList(Item) = .empty;
    // Git can report one path twice, such as a staged deletion of a file that
    // was then recreated; the rows merge like the folder listing's statuses.
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    for (repo.changes) |change| {
        var rel = change.path;
        if (prefix.len > 0) {
            if (!std.mem.startsWith(u8, rel, prefix) or rel.len <= prefix.len or rel[prefix.len] != '/') continue;
            rel = rel[prefix.len + 1 ..];
        }
        if (rel.len == 0 or (!show_hidden and hasHiddenComponent(rel))) continue;
        if (seen.get(rel)) |i| {
            const row = &list.items[i];
            const status: git.Status = if (change.status == .deleted and !row.missing) .modified else change.status;
            if (row.git_status == .conflict or status == .conflict) {
                row.git_status = .conflict;
            } else if (row.git_status != status) row.git_status = .modified;
            row.git_lines = git.LineCounts.merge(row.git_lines, change.lines);
            continue;
        }
        if (list.items.len >= max_changed_rows) {
            truncated.* = true;
            break;
        }
        const full_path = std.fmt.allocPrintSentinel(mem, "{s}/{s}", .{ dir_path, rel }, 0) catch continue;
        const base = std.fs.path.basename(rel);
        var item = statItem(mem, owners, associations, base, full_path) orelse blk: {
            // Only a deletion may be absent from the disk; anything else vanished mid-scan.
            if (change.status != .deleted) continue;
            break :blk Item{ .name = base, .path = full_path, .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = mimeIcon(base, false, false, false), .missing = true };
        };
        item.label = rel;
        item.git_status = if (item.missing) .deleted else if (change.status == .deleted) .modified else change.status;
        item.git_lines = change.lines;
        seen.put(mem, rel, list.items.len) catch {};
        list.append(mem, item) catch continue;
    }
    return list.toOwnedSlice(mem) catch &.{};
}

pub fn mimeIcon(name: []const u8, is_dir: bool, is_symlink: bool, is_broken: bool) []const u8 {
    _ = is_symlink;
    if (is_broken) return "dialog-warning";
    if (is_dir) return "folder";

    const ext = std.fs.path.extension(name);
    if (std.ascii.eqlIgnoreCase(ext, ".png") or std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg") or std.ascii.eqlIgnoreCase(ext, ".svg") or
        std.ascii.eqlIgnoreCase(ext, ".webp") or std.ascii.eqlIgnoreCase(ext, ".gif"))
    {
        return "image-x-generic";
    }
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return "application-pdf";
    if (std.ascii.eqlIgnoreCase(ext, ".mp3") or std.ascii.eqlIgnoreCase(ext, ".flac") or
        std.ascii.eqlIgnoreCase(ext, ".wav") or std.ascii.eqlIgnoreCase(ext, ".ogg"))
    {
        return "audio-x-generic";
    }
    if (std.ascii.eqlIgnoreCase(ext, ".mp4") or std.ascii.eqlIgnoreCase(ext, ".mkv") or
        std.ascii.eqlIgnoreCase(ext, ".webm") or std.ascii.eqlIgnoreCase(ext, ".avi"))
    {
        return "video-x-generic";
    }
    if (std.ascii.eqlIgnoreCase(ext, ".zip") or std.ascii.eqlIgnoreCase(ext, ".tar") or
        std.ascii.eqlIgnoreCase(ext, ".gz") or std.ascii.eqlIgnoreCase(ext, ".xz") or
        std.ascii.eqlIgnoreCase(ext, ".7z"))
    {
        return "package-x-generic";
    }
    if (std.ascii.eqlIgnoreCase(ext, ".sh") or std.ascii.eqlIgnoreCase(ext, ".bash") or
        std.ascii.eqlIgnoreCase(ext, ".py") or std.ascii.eqlIgnoreCase(ext, ".zig") or
        std.ascii.eqlIgnoreCase(ext, ".c") or std.ascii.eqlIgnoreCase(ext, ".h") or
        std.ascii.eqlIgnoreCase(ext, ".cpp"))
    {
        return "text-x-script";
    }
    if (std.ascii.eqlIgnoreCase(ext, ".desktop")) return "application-x-executable";
    return "text-x-generic";
}

// Resolve once per UID per snapshot, off the UI thread. Use the reentrant
// lookup because other workers may also be consulting the account database.
fn ownerName(mem: Allocator, uid: c.uid_t) ![]const u8 {
    var size: usize = 1024;
    while (size <= 1024 * 1024) : (size *= 2) {
        const buffer = try mem.alloc(u8, size);
        defer mem.free(buffer);
        var entry: c.struct_passwd = undefined;
        var result: ?*c.struct_passwd = null;
        const err = c.getpwuid_r(uid, &entry, buffer.ptr, buffer.len, &result);
        if (err == c.ERANGE) continue;
        if (err == 0 and result != null) return mem.dupe(u8, std.mem.span(entry.pw_name));
        break;
    }
    return std.fmt.allocPrint(mem, "{d}", .{uid});
}

test "Files .hidden entries match exact names" {
    const contents = "secret.txt\nprivate folder\nnotes.txt\n";

    try std.testing.expect(isHiddenEntry(contents, "secret.txt"));
    try std.testing.expect(isHiddenEntry(contents, "private folder"));
    try std.testing.expect(isHiddenEntry(contents, "notes.txt"));

    try std.testing.expect(!isHiddenEntry(contents, "secret"));
    try std.testing.expect(!isHiddenEntry(contents, "secret.txt.bak"));
    try std.testing.expect(!isHiddenEntry(contents, "other.txt"));
}

test "Files .hidden entries support CRLF and ignore empty lines" {
    const contents = "\r\nsecret.txt\r\n\r\nnotes.txt\r\n";

    try std.testing.expect(isHiddenEntry(contents, "secret.txt"));
    try std.testing.expect(isHiddenEntry(contents, "notes.txt"));
    try std.testing.expect(!isHiddenEntry(contents, ""));
    try std.testing.expect(!isHiddenEntry(contents, "other.txt"));
}

test "Files empty or missing .hidden content hides nothing" {
    try std.testing.expect(!isHiddenEntry("", "file.txt"));
    try std.testing.expect(!isHiddenEntry("\n\r\n", "file.txt"));
}
