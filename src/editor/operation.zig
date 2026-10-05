//! Immutable file/chooser jobs. The UI only consumes results after the eventfd wakes it.
const std = @import("std");
const c = @import("../files/c.zig").api;
const Document = @import("document.zig").Document;
const a = std.heap.c_allocator;
extern fn flistxattr(c_int, ?[*]u8, usize) isize;
extern fn fgetxattr(c_int, [*:0]const u8, ?[*]u8, usize) isize;
extern fn fsetxattr(c_int, [*:0]const u8, [*]const u8, usize, c_int) c_int;
fn copyAttributes(source: c_int, destination: c_int) !void {
    const len = flistxattr(source, null, 0);
    if (len < 0) {
        if (std.posix.errno(@as(c_int, -1)) == .OPNOTSUPP) return;
        return error.MetadataFailed;
    }
    if (len == 0) return;
    if (len > 1024 * 1024) return error.MetadataFailed;
    const names = try a.alloc(u8, @intCast(len));
    defer a.free(names);
    if (flistxattr(source, names.ptr, names.len) != len) return error.FileChanged;
    var offset: usize = 0;
    while (offset < names.len) {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(names.ptr + offset)), 0);
        const size = fgetxattr(source, name, null, 0);
        if (size < 0 or size > 1024 * 1024) return error.MetadataFailed;
        const value = try a.alloc(u8, @intCast(size));
        defer a.free(value);
        if (fgetxattr(source, name, value.ptr, value.len) != size or fsetxattr(destination, name, value.ptr, value.len, 0) != 0) return error.MetadataFailed;
        offset += name.len + 1;
    }
}
pub const Stamp = struct {
    dev: u64,
    ino: u64,
    size: i64,
    sec: i64,
    ns: i64,
    csec: i64,
    cns: i64,
    pub fn of(st: c.struct_stat) Stamp {
        return .{ .dev = st.st_dev, .ino = st.st_ino, .size = st.st_size, .sec = st.st_mtim.tv_sec, .ns = st.st_mtim.tv_nsec, .csec = st.st_ctim.tv_sec, .cns = st.st_ctim.tv_nsec };
    }
    pub fn eql(s: Stamp, other: Stamp) bool {
        return std.meta.eql(s, other);
    }
};
pub fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}
fn readAll(fd: c_int, limit: usize) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n == 0) break;
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (bytes.items.len + @as(usize, @intCast(n)) > limit) return error.FileTooLarge;
        try bytes.appendSlice(a, buf[0..@intCast(n)]);
    }
    return bytes.toOwnedSlice(a);
}
pub fn executable(buf: []u8, name: []const u8) []const u8 {
    var path: [4096]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &path, path.len);
    if (n > 0 and n < path.len) {
        if (std.fs.path.dirname(path[0..@intCast(n)])) |dir| {
            const sibling = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name }) catch return name;
            if (c.access(sibling, c.X_OK) == 0) return sibling;
        }
    }
    return name;
}
pub const Operation = struct {
    pub const Kind = enum { load, save, open_dialog, save_dialog };
    kind: Kind,
    tab_id: usize,
    revision: usize = 0,
    path: [:0]u8,
    bytes: []u8,
    expected: ?Stamp,
    stamp: ?Stamp = null,
    io: std.Io,
    fd: c_int,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,
    cancelled: bool = false,
    document: ?Document = null,

    pub fn start(kind: Kind, io: std.Io, tab_id: usize, path: []const u8, bytes: []const u8, expected: ?Stamp) !*Operation {
        const self = try a.create(Operation);
        errdefer a.destroy(self);
        const owned = try a.dupeZ(u8, path);
        errdefer a.free(owned);
        const data = try a.dupe(u8, bytes);
        errdefer a.free(data);
        const fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (fd < 0) return error.EventFailed;
        errdefer _ = c.close(fd);
        self.* = .{ .kind = kind, .io = io, .tab_id = tab_id, .path = owned, .bytes = data, .expected = expected, .fd = fd };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn deinit(self: *Operation) void {
        self.thread.?.join();
        if (self.document) |*d| d.deinit();
        a.free(self.path);
        a.free(self.bytes);
        _ = c.close(self.fd);
        a.destroy(self);
    }
    fn run(self: *Operation) void {
        self.work() catch |err| {
            self.err = err;
        };
        self.done.store(true, .release);
        var value: u64 = 1;
        _ = c.write(self.fd, &value, 8);
    }
    fn canonical(self: *Operation) !void {
        const path = c.realpath(self.path, null) orelse return error.OpenFailed;
        defer c.free(path);
        const owned = try a.dupeZ(u8, std.mem.span(path));
        a.free(self.path);
        self.path = owned;
    }
    fn work(self: *Operation) !void {
        switch (self.kind) {
            .load => {
                try self.canonical();
                const fd = c.open(self.path, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
                if (fd < 0) return error.OpenFailed;
                defer _ = c.close(fd);
                var st: c.struct_stat = undefined;
                if (c.fstat(fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG) return error.NotRegularFile;
                self.stamp = Stamp.of(st);
                const bytes = try readAll(fd, @import("document.zig").limit);
                defer a.free(bytes);
                self.document = try Document.init(bytes);
                if (c.fstat(fd, &st) != 0 or !self.stamp.?.eql(Stamp.of(st))) return error.FileChanged;
            },
            .save => try self.save(),
            .open_dialog, .save_dialog => try self.choose(),
        }
    }
    fn save(self: *Operation) !void {
        var st: c.struct_stat = undefined;
        var existing = false;
        if (c.lstat(self.path, &st) == 0) {
            if (st.st_mode & c.S_IFMT == c.S_IFLNK) try self.canonical();
            if (c.stat(self.path, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG) return error.NotRegularFile;
            existing = true;
            if (self.expected) |stamp| {
                if (!stamp.eql(Stamp.of(st))) return error.FileChanged;
            } else return error.FileChanged;
            // Atomic replacement must not bypass a read-only file's permissions.
            if (c.access(self.path, c.W_OK) != 0) return error.PermissionDenied;
            if (st.st_nlink > 1) return error.HardLinkedFile;
        } else {
            if (std.posix.errno(@as(c_int, -1)) != .NOENT) return error.OpenFailed;
            if (self.expected != null) return error.FileChanged;
        }
        const before = if (existing) Stamp.of(st) else null;
        const parent = std.fs.path.dirname(self.path) orelse return error.InvalidPath;
        const temp = try std.fmt.allocPrintSentinel(a, "{s}/.rediwm-editor-XXXXXX", .{parent}, 0);
        defer a.free(temp);
        const fd = c.mkostemp(temp, c.O_CLOEXEC);
        if (fd < 0) return error.PermissionDenied;
        defer _ = c.close(fd);
        defer _ = c.unlink(temp);
        if (existing) {
            if (c.fchown(fd, st.st_uid, st.st_gid) != 0 or c.fchmod(fd, st.st_mode & 0o777) != 0) return error.PermissionDenied;
            const source = c.open(self.path, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK);
            if (source < 0) return error.OpenFailed;
            defer _ = c.close(source);
            var source_stat: c.struct_stat = undefined;
            if (c.fstat(source, &source_stat) != 0 or !before.?.eql(Stamp.of(source_stat))) return error.FileChanged;
            try copyAttributes(source, fd);
        }
        try writeAll(fd, self.bytes);
        if (c.fsync(fd) != 0) return error.WriteFailed;
        if (before) |stamp| {
            var current: c.struct_stat = undefined;
            if (c.stat(self.path, &current) != 0 or !stamp.eql(Stamp.of(current))) return error.FileChanged;
            if (c.rename(temp, self.path) != 0) return error.WriteFailed;
        } else if (c.renameat2(c.AT_FDCWD, temp, c.AT_FDCWD, self.path, c.RENAME_NOREPLACE) != 0) return error.FileChanged;
        if (c.stat(self.path, &st) != 0) return error.WriteFailed;
        self.stamp = Stamp.of(st);
        const parent_z = try a.dupeZ(u8, parent);
        defer a.free(parent_z);
        const dir = c.open(parent_z, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (dir >= 0) {
            defer _ = c.close(dir);
            if (c.fsync(dir) != 0) return error.WriteFailed;
        }
    }
    fn choose(self: *Operation) !void {
        const options: @import("../files/chooser.zig").Options = .{
            .mode = if (self.kind == .save_dialog) .save else .open,
            .title = if (self.kind == .save_dialog) "Save As" else "Open Text File",
            .current_folder = if (self.path.len > 0) std.fs.path.dirname(self.path) orelse "" else "",
            .current_name = if (self.kind == .save_dialog) (if (self.path.len > 0) std.fs.path.basename(self.path) else "Untitled.txt") else "",
        };
        const json = try std.json.Stringify.valueAlloc(a, options, .{});
        defer a.free(json);
        const input = c.memfd_create("editor-chooser-options", c.MFD_CLOEXEC);
        if (input < 0) return error.CreateFailed;
        defer _ = c.close(input);
        const output = c.memfd_create("editor-chooser-result", c.MFD_CLOEXEC);
        if (output < 0) return error.CreateFailed;
        defer _ = c.close(output);
        try writeAll(input, json);
        if (c.lseek(input, 0, c.SEEK_SET) < 0) return error.ReadFailed;
        var exe: [4096]u8 = undefined;
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ executable(&exe, "rediwm-files"), "--chooser-stdin" },
            .stdin = .{ .file = .{ .handle = input, .flags = .{ .nonblocking = false } } },
            .stdout = .{ .file = .{ .handle = output, .flags = .{ .nonblocking = false } } },
        });
        const term = try child.wait(self.io);
        if (term != .exited or term.exited != 0) return error.ChooserFailed;
        if (c.lseek(output, 0, c.SEEK_SET) < 0) return error.ReadFailed;
        const result = try readAll(output, 1024 * 1024);
        defer a.free(result);
        const parsed = try std.json.parseFromSlice(@import("../files/chooser.zig").Result, a, result, .{});
        defer parsed.deinit();
        if (parsed.value.paths.len == 0) {
            self.cancelled = true;
            return;
        }
        const chosen = parsed.value.paths[0];
        if (!std.fs.path.isAbsolute(chosen) or std.mem.indexOfScalar(u8, chosen, 0) != null) return error.InvalidPath;
        const owned = try a.dupeZ(u8, chosen);
        a.free(self.path);
        self.path = owned;
        // Capture the destination the user just approved, before returning to the UI.
        var st: c.struct_stat = undefined;
        if (c.stat(self.path, &st) == 0) {
            self.stamp = Stamp.of(st);
            try self.canonical();
        }
    }
};

test "atomic saves preserve permissions, reject stale files and follow symlink targets" {
    var template: [64:0]u8 = @splat(0);
    _ = try std.fmt.bufPrintZ(&template, "/tmp/rediwm-editor-XXXXXX", .{});
    const dir = c.mkdtemp(&template) orelse return error.CreateFailed;
    defer _ = c.rmdir(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/note.txt", .{std.mem.span(dir)}, 0);
    defer a.free(path);
    defer _ = c.unlink(path);
    const link = try std.fmt.allocPrintSentinel(a, "{s}/link.txt", .{std.mem.span(dir)}, 0);
    defer a.free(link);
    defer _ = c.unlink(link);
    var job: Operation = .{ .kind = .save, .tab_id = 1, .path = try a.dupeZ(u8, path), .bytes = try a.dupe(u8, "original"), .expected = null, .io = undefined, .fd = -1 };
    defer a.free(job.path);
    defer a.free(job.bytes);
    try job.work();
    try std.testing.expect(c.chmod(path, 0o640) == 0);
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.stat(path, &st) == 0);
    const first = Stamp.of(st);
    a.free(job.bytes);
    job.bytes = try a.dupe(u8, "replacement");
    job.expected = first;
    try job.work();
    try std.testing.expect(c.stat(path, &st) == 0);
    try std.testing.expectEqual(@as(c.mode_t, 0o640), st.st_mode & 0o777);
    try std.testing.expectError(error.FileChanged, job.work());
    try std.testing.expect(c.symlink(path, link) == 0);
    job.expected = Stamp.of(st);
    a.free(job.path);
    job.path = try a.dupeZ(u8, link);
    try job.work();
    try std.testing.expect(c.lstat(link, &st) == 0 and st.st_mode & c.S_IFMT == c.S_IFLNK);
    const fd = c.open(path, c.O_RDONLY);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    const bytes = try readAll(fd, 100);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("replacement", bytes);
    // A destination appearing after Save As must not be silently replaced.
    job.expected = null;
    try std.testing.expectError(error.FileChanged, job.work());
}
