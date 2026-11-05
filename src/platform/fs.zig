//! File operations that differ between systems. Linux has `renameat2`;
//! FreeBSD has no rename that refuses to replace.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .freebsd)
        @compileError("platform.fs is not ported to this OS yet (docs/plans/freebsd.md, phase 1)");
}

/// What a path names, for the callers that compare identities or check an owner.
pub const Stat = struct {
    /// Device and inode: equal for the same file, whatever path reaches it.
    dev: u64,
    ino: u64,
    uid: u32,
    /// The type and permission bits, as `st_mode`.
    mode: u32,
};

/// The identity, owner and mode of what `path` names (symbolic links
/// followed), or null when it cannot be examined.
pub fn stat(path: [*:0]const u8) ?Stat {
    switch (builtin.os.tag) {
        .linux => {
            var info: linux.Statx = undefined;
            const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .UID = true, .MODE = true, .INO = true }, &info);
            if (linux.errno(rc) != .SUCCESS) return null;
            return .{ .dev = @as(u64, info.dev_major) << 32 | info.dev_minor, .ino = info.ino, .uid = info.uid, .mode = info.mode };
        },
        .freebsd => {
            var info: std.c.Stat = undefined;
            if (std.c.fstatat(std.c.AT.FDCWD, path, &info, 0) != 0) return null;
            return .{ .dev = @intCast(info.dev), .ino = @intCast(info.ino), .uid = info.uid, .mode = info.mode };
        },
        else => unreachable,
    }
}

pub const AttributeError = error{
    OutOfMemory,
    /// The source's attributes changed while they were being read.
    FileChanged,
    MetadataFailed,
};

/// The largest attribute list or value copied.
const max_attribute = 1024 * 1024;

/// Copies the extended attributes (user ones, on FreeBSD) of one open file to
/// another. A file system without them copies nothing and succeeds. The
/// callers' libc is linked: these are libc functions, not raw syscalls.
pub fn copyAttributes(allocator: std.mem.Allocator, source: c_int, destination: c_int) AttributeError!void {
    switch (builtin.os.tag) {
        .linux => try copyAttributesLinux(allocator, source, destination),
        .freebsd => try copyAttributesFreebsd(allocator, source, destination),
        else => unreachable,
    }
}

fn copyAttributesLinux(a: std.mem.Allocator, source: c_int, destination: c_int) AttributeError!void {
    const libc = struct {
        extern "c" fn flistxattr(c_int, ?[*]u8, usize) isize;
        extern "c" fn fgetxattr(c_int, [*:0]const u8, ?[*]u8, usize) isize;
        extern "c" fn fsetxattr(c_int, [*:0]const u8, [*]const u8, usize, c_int) c_int;
    };
    const len = libc.flistxattr(source, null, 0);
    if (len < 0) {
        if (std.posix.errno(@as(c_int, -1)) == .OPNOTSUPP) return;
        return error.MetadataFailed;
    }
    if (len == 0) return;
    if (len > max_attribute) return error.MetadataFailed;
    const names = try a.alloc(u8, @intCast(len));
    defer a.free(names);
    if (libc.flistxattr(source, names.ptr, names.len) != len) return error.FileChanged;
    var offset: usize = 0;
    while (offset < names.len) {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(names.ptr + offset)), 0);
        const size = libc.fgetxattr(source, name, null, 0);
        if (size < 0 or size > max_attribute) return error.MetadataFailed;
        const value = try a.alloc(u8, @intCast(size));
        defer a.free(value);
        if (libc.fgetxattr(source, name, value.ptr, value.len) != size or libc.fsetxattr(destination, name, value.ptr, value.len, 0) != 0) return error.MetadataFailed;
        offset += name.len + 1;
    }
}

/// FreeBSD lists a file's user attributes as a run of length-prefixed names
/// with no terminator and no namespace prefix.
fn copyAttributesFreebsd(a: std.mem.Allocator, source: c_int, destination: c_int) AttributeError!void {
    const libc = struct {
        extern "c" fn extattr_list_fd(c_int, c_int, ?[*]u8, usize) isize;
        extern "c" fn extattr_get_fd(c_int, c_int, [*:0]const u8, ?[*]u8, usize) isize;
        extern "c" fn extattr_set_fd(c_int, c_int, [*:0]const u8, [*]const u8, usize) isize;
    };
    // EXTATTR_NAMESPACE_USER (sys/extattr.h); the system namespace needs root.
    const user = 1;
    const len = libc.extattr_list_fd(source, user, null, 0);
    if (len < 0) {
        if (std.posix.errno(@as(c_int, -1)) == .OPNOTSUPP) return;
        return error.MetadataFailed;
    }
    if (len == 0) return;
    if (len > max_attribute) return error.MetadataFailed;
    const names = try a.alloc(u8, @intCast(len));
    defer a.free(names);
    if (libc.extattr_list_fd(source, user, names.ptr, names.len) != len) return error.FileChanged;
    var offset: usize = 0;
    while (offset < names.len) {
        const name_len = names[offset];
        offset += 1;
        if (name_len == 0 or name_len > names.len - offset) return error.MetadataFailed;
        var name: [256:0]u8 = undefined;
        @memcpy(name[0..name_len], names[offset..][0..name_len]);
        name[name_len] = 0;
        offset += name_len;
        const size = libc.extattr_get_fd(source, user, &name, null, 0);
        if (size < 0 or size > max_attribute) return error.MetadataFailed;
        const value = try a.alloc(u8, @intCast(size));
        defer a.free(value);
        if (libc.extattr_get_fd(source, user, &name, value.ptr, value.len) != size) return error.MetadataFailed;
        if (libc.extattr_set_fd(destination, user, &name, value.ptr, value.len) < 0) return error.MetadataFailed;
    }
}

pub const RenameError = error{
    /// `to` exists.
    PathAlreadyExists,
    AccessDenied,
    /// `from` and `to` are on different file systems.
    CrossDevice,
    Failed,
};

fn classify(err: std.posix.E) RenameError {
    return switch (err) {
        .EXIST => error.PathAlreadyExists,
        .ACCES => error.AccessDenied,
        .XDEV => error.CrossDevice,
        else => error.Failed,
    };
}

/// Renames `from` to `to` unless `to` exists, in which case nothing changes
/// and the error is `PathAlreadyExists`. Atomic on Linux. FreeBSD links the
/// new name and then removes the old one, so a failure part way leaves the
/// old name; a directory cannot be hard-linked and falls back to a check and
/// `rename`, which a racing creator of `to` can beat.
pub fn renameNoReplace(from: [*:0]const u8, to: [*:0]const u8) RenameError!void {
    switch (builtin.os.tag) {
        .linux => {
            // Through libc when it is linked, so a test's LD_PRELOAD fault hook sees the call
            // (tests/screenshot_save_hook.c); raw in this module's own libc-free tests.
            if (builtin.link_libc) {
                const libc = struct {
                    extern "c" fn renameat2(c_int, [*:0]const u8, c_int, [*:0]const u8, c_uint) c_int;
                };
                const rename_noreplace = 1;
                if (libc.renameat2(linux.AT.FDCWD, from, linux.AT.FDCWD, to, rename_noreplace) != 0)
                    return classify(std.posix.errno(@as(c_int, -1)));
                return;
            }
            const rc = linux.renameat2(linux.AT.FDCWD, from, linux.AT.FDCWD, to, .{ .NOREPLACE = true });
            if (linux.errno(rc) != .SUCCESS) return classify(linux.errno(rc));
        },
        .freebsd => {
            const c = std.c;
            if (c.linkat(c.AT.FDCWD, from, c.AT.FDCWD, to, 0) == 0) {
                if (c.unlink(from) == 0) return;
                const failure = std.posix.errno(@as(c_int, -1));
                _ = c.unlink(to);
                return classify(failure);
            }
            const failure = std.posix.errno(@as(c_int, -1));
            if (failure != .PERM) return classify(failure);
            // EPERM: a directory. Look first, then rename.
            var existing: c.Stat = undefined;
            if (c.fstatat(c.AT.FDCWD, to, &existing, c.AT.SYMLINK_NOFOLLOW) == 0) return error.PathAlreadyExists;
            if (c.rename(from, to) != 0) return classify(std.posix.errno(@as(c_int, -1)));
        },
        else => unreachable,
    }
}

test "stat names a directory's owner and mode, and the same file twice" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const first = stat(root).?;
    try t.expectEqual(std.posix.system.getuid(), first.uid);
    try t.expect(first.mode & std.posix.S.IFMT == std.posix.S.IFDIR);
    try t.expect(first.ino != 0);
    const dotted = try std.fmt.allocPrintSentinel(t.allocator, "{s}/.", .{root}, 0);
    defer t.allocator.free(dotted);
    try t.expectEqual(first, stat(dotted).?);
    try t.expect(stat("/rediwm-no-such-path") == null);
}

test "rename without replacing moves a file, and refuses an existing target" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a", .data = "a" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b", .data = "b" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const a = try std.fmt.allocPrintSentinel(t.allocator, "{s}/a", .{root}, 0);
    defer t.allocator.free(a);
    const b = try std.fmt.allocPrintSentinel(t.allocator, "{s}/b", .{root}, 0);
    defer t.allocator.free(b);
    const c_path = try std.fmt.allocPrintSentinel(t.allocator, "{s}/c", .{root}, 0);
    defer t.allocator.free(c_path);

    try t.expectError(error.PathAlreadyExists, renameNoReplace(a, b));
    var kept: [1]u8 = undefined;
    try t.expectEqualStrings("a", try tmp.dir.readFile(t.io, "a", &kept));
    try t.expectEqualStrings("b", try tmp.dir.readFile(t.io, "b", &kept));

    try renameNoReplace(a, c_path);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "a", .{}));
    try t.expectEqualStrings("a", try tmp.dir.readFile(t.io, "c", &kept));

    try tmp.dir.createDir(t.io, "d", .default_dir);
    const d = try std.fmt.allocPrintSentinel(t.allocator, "{s}/d", .{root}, 0);
    defer t.allocator.free(d);
    const e = try std.fmt.allocPrintSentinel(t.allocator, "{s}/e", .{root}, 0);
    defer t.allocator.free(e);
    try renameNoReplace(d, e);
    try tmp.dir.access(t.io, "e", .{});
    try tmp.dir.createDir(t.io, "d", .default_dir);
    try t.expectError(error.PathAlreadyExists, renameNoReplace(d, e));
}
