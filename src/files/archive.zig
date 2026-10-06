//! Read-only archive indexing and extraction. No process cwd changes and no
//! archive-controlled programs. All output walks are relative to an owned dirfd.
const std = @import("std");
const c = @import("c.zig").api;
const a = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});
const Allocator = std.mem.Allocator;
pub const Cancel = std.atomic.Value(bool);

pub fn candidate(path: []const u8) bool {
    inline for (.{ ".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar.zst", ".7z" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(path, suffix)) return true;
    }
    return false;
}

pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.Cancelled => "Extraction cancelled",
        error.EncryptedArchive => "Password-protected archives are not supported yet",
        error.UnsafeArchivePath => "Archive contains an unsafe path",
        error.UnsupportedArchiveEntry => "Archive contains unsupported links or special files",
        error.ArchiveTooLarge => "Archive has too many entries",
        error.OpenArchiveFailed => "Could not open archive",
        error.InvalidArchive => "Archive is corrupt or unsupported",
        error.WriteFailed => "Could not write extracted file (check space and permissions)",
        error.MemberNotFound => "File no longer exists in the archive",
        else => "Could not extract archive",
    };
}

fn check(cancel: *const Cancel) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
}

/// Canonical member names never contain absolute paths, '..', or backslashes.
/// Empty names describe the archive root (a common tar './' or ZIP '/' entry).
pub fn normalize(mem: Allocator, raw: []const u8) ![]const u8 {
    if (raw.len > 4095 or (std.mem.startsWith(u8, raw, "/") and !std.mem.eql(u8, raw, "/")) or std.mem.indexOfAny(u8, raw, "\\\x00") != null) return error.UnsafeArchivePath;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(mem);
    var parts = std.mem.splitScalar(u8, raw, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, ':') != null) return error.UnsafeArchivePath;
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (result.items.len > 0) try result.append(mem, '/');
        try result.appendSlice(mem, part);
    }
    return result.toOwnedSlice(mem);
}

const Reader = struct {
    handle: *a.struct_archive,
    input: *Input,
    allocator: Allocator,
    const Input = struct { fd: c_int, cancel: *const Cancel, buffer: [65536]u8 = undefined };

    fn readCallback(handle: ?*a.struct_archive, data: ?*anyopaque, output: [*c]?*const anyopaque) callconv(.c) isize {
        const input: *Input = @ptrCast(@alignCast(data.?));
        if (input.cancel.load(.acquire)) {
            a.archive_set_error(handle, c.ECANCELED, "Cancelled");
            return -1;
        }
        output[0] = &input.buffer;
        while (true) {
            const n = c.read(input.fd, &input.buffer, input.buffer.len);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            return n;
        }
    }
    fn seekCallback(_: ?*a.struct_archive, data: ?*anyopaque, offset: i64, whence: c_int) callconv(.c) i64 {
        const input: *Input = @ptrCast(@alignCast(data.?));
        if (input.cancel.load(.acquire)) return -1;
        return c.lseek(input.fd, offset, whence);
    }
    fn skipCallback(handle: ?*a.struct_archive, data: ?*anyopaque, amount: i64) callconv(.c) i64 {
        const before = seekCallback(handle, data, 0, c.SEEK_CUR);
        if (before < 0) return -1;
        const after = seekCallback(handle, data, amount, c.SEEK_CUR);
        return if (after < 0) -1 else after - before;
    }

    fn open(mem: Allocator, path: []const u8, cancel: *const Cancel) !Reader {
        const handle = a.archive_read_new() orelse return error.OutOfMemory;
        errdefer _ = a.archive_read_free(handle);
        // Only built-in decoders; do not enable filters that spawn programs.
        _ = a.archive_read_support_filter_none(handle);
        _ = a.archive_read_support_filter_gzip(handle);
        _ = a.archive_read_support_filter_bzip2(handle);
        _ = a.archive_read_support_filter_xz(handle);
        _ = a.archive_read_support_filter_zstd(handle);
        _ = a.archive_read_support_format_zip(handle);
        _ = a.archive_read_support_format_tar(handle);
        _ = a.archive_read_support_format_7zip(handle);
        const zpath = try mem.dupeZ(u8, path);
        defer mem.free(zpath);
        const fd = c.open(zpath, c.O_RDONLY | c.O_NONBLOCK | c.O_CLOEXEC);
        if (fd < 0) return error.OpenArchiveFailed;
        errdefer _ = c.close(fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.OpenArchiveFailed;
        const input = try mem.create(Input);
        errdefer mem.destroy(input);
        input.* = .{ .fd = fd, .cancel = cancel };
        _ = a.archive_read_set_callback_data(handle, input);
        _ = a.archive_read_set_read_callback(handle, readCallback);
        _ = a.archive_read_set_seek_callback(handle, seekCallback);
        _ = a.archive_read_set_skip_callback(handle, skipCallback);
        const result = a.archive_read_open1(handle);
        try check(cancel);
        if (result != a.ARCHIVE_OK) return error.OpenArchiveFailed;
        return .{ .handle = handle, .input = input, .allocator = mem };
    }
    fn close(self: Reader) void {
        _ = a.archive_read_free(self.handle);
        _ = c.close(self.input.fd);
        self.allocator.destroy(self.input);
    }
    fn next(self: Reader, cancel: *const Cancel) !?*a.struct_archive_entry {
        try check(cancel);
        var entry: ?*a.struct_archive_entry = null;
        const result = a.archive_read_next_header(self.handle, &entry);
        try check(cancel);
        if (result == a.ARCHIVE_EOF) return null;
        if (result != a.ARCHIVE_OK) return if (a.archive_read_has_encrypted_entries(self.handle) > 0) error.EncryptedArchive else error.InvalidArchive;
        if (a.archive_entry_is_encrypted(entry) > 0) return error.EncryptedArchive;
        return entry orelse error.InvalidArchive;
    }
};

pub const Entry = struct {
    path: []const u8,
    directory: bool,
    link: bool = false,
    bytes: i64 = 0,
    mtime: i64 = 0,
};

pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,

    pub fn deinit(self: *Index) void {
        self.arena.deinit();
    }

    pub fn read(mem: Allocator, path: []const u8, cancel: *const Cancel) !Index {
        var arena = std.heap.ArenaAllocator.init(mem);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const reader = try Reader.open(mem, path, cancel);
        defer reader.close();
        var entries: std.ArrayList(Entry) = .empty;
        var seen: std.StringHashMapUnmanaged(usize) = .empty;
        var name_bytes: usize = 0;
        while (try reader.next(cancel)) |entry| {
            const raw = a.archive_entry_pathname(entry) orelse return error.InvalidArchive;
            name_bytes += std.mem.span(raw).len;
            if (name_bytes > 32 * 1024 * 1024) return error.ArchiveTooLarge;
            const name = try normalize(alloc, std.mem.span(raw));
            if (name.len == 0) {
                if (a.archive_entry_filetype(entry) != c.S_IFDIR or a.archive_entry_hardlink(entry) != null) return error.UnsupportedArchiveEntry;
                continue;
            }
            var parts = std.mem.splitScalar(u8, name, '/');
            var end: usize = 0;
            while (parts.next()) |part| {
                if (end > 0) end += 1;
                end += part.len;
                const key = name[0..end];
                const directory = end < name.len or a.archive_entry_filetype(entry) == c.S_IFDIR;
                const slot = try seen.getOrPut(alloc, key);
                if (!slot.found_existing) {
                    if (entries.items.len >= 250_000) return error.ArchiveTooLarge;
                    slot.value_ptr.* = entries.items.len;
                    try entries.append(alloc, .{ .path = key, .directory = directory });
                } else if (entries.items[slot.value_ptr.*].directory != directory) return error.InvalidArchive;
                if (end == name.len) {
                    const item = &entries.items[slot.value_ptr.*];
                    item.bytes = @max(0, a.archive_entry_size(entry));
                    item.mtime = a.archive_entry_mtime(entry);
                    item.link = a.archive_entry_filetype(entry) != c.S_IFREG and !directory or a.archive_entry_hardlink(entry) != null;
                }
            }
        }
        return .{ .arena = arena, .entries = try entries.toOwnedSlice(alloc) };
    }
};

pub fn temporary(mem: Allocator, parent: []const u8) ![]u8 {
    const template = try std.fmt.allocPrintSentinel(mem, "{s}/.rediwm-extract-XXXXXX", .{parent}, 0);
    defer mem.free(template);
    if (c.mkdtemp(template) == null) return error.WriteFailed;
    return mem.dupe(u8, template) catch |err| {
        _ = c.rmdir(template);
        return err;
    };
}

fn openDirectory(root: c_int, path: []const u8) !c_int {
    var fd = c.fcntl(root, c.F_DUPFD_CLOEXEC, @as(c_int, 0));
    if (fd < 0) return error.WriteFailed;
    errdefer _ = c.close(fd);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        var buf: [4096]u8 = undefined;
        const name = try std.fmt.bufPrintZ(&buf, "{s}", .{part});
        if (c.mkdirat(fd, name, @as(c_uint, 0o700)) != 0 and std.c._errno().* != c.EEXIST) return error.WriteFailed;
        const next = c.openat(fd, name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (next < 0) return error.UnsafeArchivePath;
        _ = c.close(fd);
        fd = next;
    }
    return fd;
}

/// Destination must be a private, newly created staging directory. Publication
/// into the user's folder is handled by JobRunner's no-overwrite transfer path.
pub fn extract(mem: Allocator, path: []const u8, destination: []const u8, member: ?[]const u8, cancel: *const Cancel) !void {
    const reader = try Reader.open(mem, path, cancel);
    defer reader.close();
    const zdest = try mem.dupeZ(u8, destination);
    defer mem.free(zdest);
    const root = c.open(zdest, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (root < 0) return error.WriteFailed;
    defer _ = c.close(root);
    var found = false;
    while (try reader.next(cancel)) |entry| {
        const raw = a.archive_entry_pathname(entry) orelse return error.InvalidArchive;
        const name = try normalize(mem, std.mem.span(raw));
        defer mem.free(name);
        if (name.len == 0) {
            if (a.archive_entry_filetype(entry) != c.S_IFDIR or a.archive_entry_hardlink(entry) != null) return error.UnsupportedArchiveEntry;
            continue;
        }
        if (member) |wanted| if (!std.mem.eql(u8, name, wanted)) continue;
        const kind = a.archive_entry_filetype(entry);
        if ((kind != c.S_IFREG and kind != c.S_IFDIR) or a.archive_entry_hardlink(entry) != null) return error.UnsupportedArchiveEntry;
        const parent = try openDirectory(root, if (kind == c.S_IFDIR) name else std.fs.path.dirname(name) orelse "");
        defer _ = c.close(parent);
        if (kind == c.S_IFDIR) continue;
        const zname = try mem.dupeZ(u8, std.fs.path.basename(name));
        defer mem.free(zname);
        const fd = c.openat(parent, zname, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (fd < 0) return error.WriteFailed;
        defer _ = c.close(fd);
        var buffer: [65536]u8 = undefined;
        while (true) {
            try check(cancel);
            const n = a.archive_read_data(reader.handle, &buffer, buffer.len);
            try check(cancel);
            if (n == 0) break;
            if (n < 0) return error.InvalidArchive;
            var offset: usize = 0;
            while (offset < @as(usize, @intCast(n))) {
                try check(cancel);
                const written = c.write(fd, buffer[offset..].ptr, @as(usize, @intCast(n)) - offset);
                if (written < 0 and std.posix.errno(written) == .INTR) continue;
                if (written <= 0) return error.WriteFailed;
                offset += @intCast(written);
            }
        }
        // Keep ordinary executable bits, never set-id or archive ownership.
        if (member == null) _ = c.fchmod(fd, @as(c_uint, @intCast(a.archive_entry_perm(entry) & 0o777)) | 0o600);
        found = true;
        if (member != null) break;
    }
    if (member != null and !found) return error.MemberNotFound;
}
