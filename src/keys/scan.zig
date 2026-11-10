//! Only regular, owned, non-symlink files directly in ~/.ssh are candidates.
//! Names/extensions never decide whether a file contains a key.
const std = @import("std");
const c = @import("c");
const model = @import("model.zig");
const openssh = @import("openssh.zig");
const A = std.mem.Allocator;
pub const File = struct {
    bytes: []u8,
    mode: u32,
    ino: u64,
    dev: u64,
    pub fn deinit(self: File, a: A) void {
        std.crypto.secureZero(u8, self.bytes);
        a.free(self.bytes);
    }
};
pub fn read(a: A, path: []const u8) !File {
    return readAt(a, c.AT_FDCWD, path);
}
pub fn readAt(a: A, directory: c_int, path: []const u8) !File {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const fd = c.openat(directory, z.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK);
    if (fd < 0) return error.UnreadableFile;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & std.c.S.IFMT != std.c.S.IFREG or stat.st_uid != std.c.getuid()) return error.UnsafeFile;
    if (stat.st_size <= 0 or stat.st_size > model.max_file) return error.FileTooLarge;
    const bytes = try a.alloc(u8, @intCast(stat.st_size));
    errdefer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.FileChanged;
        offset += @intCast(n);
    }
    var extra: [1]u8 = undefined;
    if (c.read(fd, &extra, 1) != 0) return error.FileChanged;
    return .{ .bytes = bytes, .mode = stat.st_mode, .ino = @intCast(stat.st_ino), .dev = @intCast(stat.st_dev) };
}
pub fn sshDir(a: A, env: std.process.Environ) ![]const u8 {
    const home = env.getPosix("HOME") orelse return error.NoHome;
    if (!std.fs.path.isAbsolute(home)) return error.NoHome;
    return std.fs.path.join(a, &.{ home, ".ssh" });
}
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 200 or name[0] == '.' or !openssh.cleanText(name)) return false;
    return std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}
/// A write target is always one plain filename in the standard directory.
pub fn target(a: A, env: std.process.Environ, path: []const u8) ![]const u8 {
    const dir = try sshDir(a, env);
    if (!std.mem.eql(u8, std.fs.path.dirname(path) orelse "", dir) or !validName(std.fs.path.basename(path))) return error.InvalidPath;
    return dir;
}
pub fn inventory(a: A, io: std.Io, env: std.process.Environ, opened: ?std.Io.Dir) !model.Inventory {
    const path = try sshDir(a, env);
    var result: model.Inventory = .{};
    const dir = opened orelse return result;
    var st: c.struct_stat = undefined;
    if (c.fstat(dir.handle, &st) != 0 or st.st_uid != std.c.getuid()) return error.UnsafeDirectory;
    result.directory_permissions = st.st_mode & 0o077 != 0;
    var items: std.ArrayList(model.Item) = .empty;
    var it = dir.iterate();
    var examined: usize = 0;
    while (try it.next(io)) |entry| {
        examined += 1;
        if (examined > 4096 or items.items.len >= model.max_items) {
            result.skipped += 1;
            break;
        }
        if (entry.name[0] == '.' or std.mem.eql(u8, entry.name, "config") or std.mem.startsWith(u8, entry.name, "known_hosts") or std.mem.startsWith(u8, entry.name, "authorized_keys")) continue;
        if (entry.kind != .file or !validName(entry.name)) {
            result.skipped += 1;
            continue;
        }
        const full = try std.fs.path.join(a, &.{ path, entry.name });
        const file = readAt(a, dir.handle, entry.name) catch {
            result.skipped += 1;
            continue;
        };
        defer file.deinit(a);
        const parsed = openssh.parse(a, file.bytes) catch {
            result.skipped += 1;
            continue;
        };
        var location: model.Location = .{ .path = full, .private = parsed.private, .encrypted = parsed.encrypted, .permissions = parsed.private and file.mode & 0o077 != 0 };
        if (parsed.private) {
            const pub_path = try std.fmt.allocPrint(a, "{s}.pub", .{entry.name});
            const public = readAt(a, dir.handle, pub_path) catch null;
            if (public) |pub_file| {
                defer pub_file.deinit(a);
                const pub_item = openssh.publicLine(a, pub_file.bytes) catch null;
                location.mismatched_public = if (pub_item) |p| !std.mem.eql(u8, p.fingerprint, parsed.item.fingerprint) else true;
            } else location.missing_public = true;
        }
        var found: ?*model.Item = null;
        for (items.items) |*item| if (std.mem.eql(u8, item.fingerprint, parsed.item.fingerprint)) {
            found = item;
            break;
        };
        if (found) |item| {
            item.locations = try std.mem.concat(a, model.Location, &.{ item.locations, &.{location} });
            if (!parsed.private and parsed.item.comment.len > 0) {
                item.comment = parsed.item.comment;
                item.public_key = parsed.item.public_key;
            }
        } else {
            var item = parsed.item;
            item.locations = try a.dupe(model.Location, &.{location});
            try items.append(a, item);
        }
    }
    std.mem.sort(model.Item, items.items, {}, struct {
        fn less(_: void, x: model.Item, y: model.Item) bool {
            return std.mem.lessThan(u8, x.locations[0].path, y.locations[0].path);
        }
    }.less);
    result.items = try items.toOwnedSlice(a);
    return result;
}
