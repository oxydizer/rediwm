//! Disposable helper operations. Tools see only staged files; passphrases
//! reach askpass through an inherited pipe, never argv or environment values.
const std = @import("std");
const c = @import("c");
const platform = @import("platform");
const keys = @import("keys");
const secure = @import("network/secure_allocator.zig").allocator;
const Request = keys.protocol.Request;
const A = std.mem.Allocator;

pub fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}
fn readAll(fd: c_int, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.ReadFailed;
        offset += @intCast(n);
    }
}
pub fn askpass(env: std.process.Environ, prompt: []const u8) !void {
    const fd = try std.fmt.parseInt(c_int, env.getPosix("REDIWM_KEYS_ASKPASS_FD") orelse return error.NoPipe, 10);
    if (fd <= 2) return error.NoPipe;
    var header: [9]u8 = undefined;
    try readAll(fd, &header);
    const old_len = std.mem.readInt(u32, header[0..4], .big);
    const new_len = std.mem.readInt(u32, header[4..8], .big);
    if (old_len > 512 or new_len > 512) return error.InvalidPassphrase;
    const secrets = try secure.alloc(u8, old_len + new_len);
    defer secure.free(secrets);
    try readAll(fd, secrets);
    const old = secrets[0..old_len];
    const new = secrets[old_len..];
    const value = if (std.mem.startsWith(u8, prompt, "Enter old passphrase")) old else if (std.mem.startsWith(u8, prompt, "Enter new passphrase") or std.mem.startsWith(u8, prompt, "Enter same passphrase")) new else if (std.mem.startsWith(u8, prompt, "Enter passphrase")) (if (header[8] == 1) new else old) else return error.UnexpectedPrompt;
    try writeAll(1, value);
    try writeAll(1, "\n");
}

fn tool(a: A, io: std.Io, req: Request, staged: []const u8) !void {
    const executable = platform.tool.system(io, "ssh-keygen") orelse return error.MissingKeygen;
    const argv = try keys.ops.argv(a, executable, req, staged);
    var pipes: [2]c_int = undefined;
    if (c.pipe(&pipes) != 0) return error.PipeFailed;
    defer {
        _ = c.close(pipes[0]);
        if (pipes[1] >= 0) _ = c.close(pipes[1]);
    }
    if (c.fcntl(pipes[0], c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0 or c.fcntl(pipes[1], c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0 or c.fcntl(pipes[1], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.PipeFailed;
    var header: [9]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(req.old_passphrase.len), .big);
    std.mem.writeInt(u32, header[4..8], @intCast(req.new_passphrase.len), .big);
    header[8] = @intFromBool(req.action == .generate);
    // At most 3099 bytes, with a nonblocking write end. Each askpass
    // invocation consumes exactly one packet.
    for (0..3) |_| {
        try writeAll(pipes[1], &header);
        try writeAll(pipes[1], req.old_passphrase);
        try writeAll(pipes[1], req.new_passphrase);
    }
    _ = c.close(pipes[1]);
    pipes[1] = -1;
    var self_buf: [4096]u8 = undefined;
    const self = platform.exe.path(&self_buf) orelse return error.NoExecutable;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    // A minimal environment excludes agent sockets and user askpass hooks.
    try env.put("LC_ALL", "C");
    try env.put("SSH_ASKPASS", self);
    try env.put("SSH_ASKPASS_REQUIRE", "force");
    try env.put("REDIWM_KEYS_ASKPASS_FD", try std.fmt.allocPrint(a, "{d}", .{pipes[0]}));
    const file: std.Io.File = .{ .handle = pipes[0], .flags = .{ .nonblocking = false } };
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = &env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .inherit_files = &.{file} });
    defer child.kill(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.KeygenFailed;
}
pub fn dataDir(a: A, env: std.process.Environ) ![]const u8 {
    const data = env.getPosix("XDG_DATA_HOME") orelse try std.fs.path.join(a, &.{ env.getPosix("HOME") orelse return error.NoHome, ".local/share" });
    if (!std.fs.path.isAbsolute(data)) return error.InvalidPath;
    return std.fs.path.join(a, &.{ data, "rediwm/keys" });
}
const Label = struct { fingerprint: []const u8, label: []const u8 };
pub fn indexPath(a: A, env: std.process.Environ) ![]const u8 {
    return std.fs.path.join(a, &.{ try dataDir(a, env), "index.json" });
}
fn labels(a: A, env: std.process.Environ) ![]const Label {
    const path = try indexPath(a, env);
    const file = keys.scan.read(a, path) catch return &.{};
    defer file.deinit(a);
    return (try std.json.parseFromSlice([]const Label, a, file.bytes, .{ .allocate = .alloc_always, .max_value_len = 1024 })).value;
}
pub fn applyLabels(a: A, bytes: []const u8, inventory: *keys.model.Inventory) !void {
    const index = (std.json.parseFromSlice([]const Label, a, bytes, .{ .allocate = .alloc_always, .max_value_len = 1024 }) catch return).value;
    for (@constCast(inventory.items)) |*item| for (index) |entry| {
        if (std.mem.eql(u8, item.fingerprint, entry.fingerprint) and entry.label.len <= 512 and keys.openssh.cleanText(entry.label)) item.label = entry.label;
    };
}
fn saveLabel(a: A, io: std.Io, env: std.process.Environ, req: Request) !void {
    const directory = try dataDir(a, env);
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const dz = try a.dupeSentinel(u8, directory, 0);
    if (c.chmod(dz.ptr, 0o700) != 0) return error.WriteFailed;
    const old = try labels(a, env);
    var entries: std.ArrayList(Label) = .empty;
    for (old) |entry| if (!std.mem.eql(u8, entry.fingerprint, req.fingerprint)) try entries.append(a, entry);
    if (req.text.len > 0) try entries.append(a, .{ .fingerprint = req.fingerprint, .label = req.text });
    const bytes = try std.json.Stringify.valueAlloc(a, entries.items, .{});
    const temp = try std.fmt.allocPrintSentinel(a, "{s}/.index-XXXXXX", .{directory}, 0);
    const fd = c.mkstemp(temp.ptr);
    if (fd < 0) return error.WriteFailed;
    defer _ = c.close(fd);
    defer _ = c.unlink(temp.ptr);
    try writeAll(fd, bytes);
    if (c.fsync(fd) != 0) return error.WriteFailed;
    const final = try std.fmt.allocPrintSentinel(a, "{s}/index.json", .{directory}, 0);
    if (c.rename(temp.ptr, final.ptr) != 0) return error.WriteFailed;
}
fn writeNew(a: A, path: []const u8, bytes: []const u8, mode: c.mode_t) !void {
    const z = try a.dupeSentinel(u8, path, 0);
    const fd = c.open(z.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW, mode);
    if (fd < 0) return error.PathAlreadyExists;
    defer _ = c.close(fd);
    errdefer _ = c.unlink(z.ptr);
    try writeAll(fd, bytes);
    if (c.fsync(fd) != 0) return error.WriteFailed;
}
fn unchanged(a: A, path: []const u8, original: keys.scan.File) !void {
    const current = try keys.scan.read(a, path);
    defer current.deinit(a);
    if (current.ino != original.ino or current.dev != original.dev or !std.mem.eql(u8, current.bytes, original.bytes)) return error.FileChanged;
}
pub fn perform(a: A, io: std.Io, env: std.process.Environ, req: Request) !void {
    try keys.ops.validate(req);
    if (req.action == .scan) return;
    const directory = if (req.action == .generate) blk: {
        if (!keys.scan.validName(req.path) or std.mem.endsWith(u8, req.path, ".pub")) return error.InvalidPath;
        break :blk try keys.scan.sshDir(a, env);
    } else try keys.scan.target(a, env, req.path);
    if (req.action == .generate) try std.Io.Dir.cwd().createDirPath(io, directory);
    // Reject a symlinked standard directory before any write.
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var stat: c.struct_stat = undefined;
    if (c.fstat(dir.handle, &stat) != 0 or stat.st_uid != std.c.getuid()) return error.UnsafeDirectory;
    const path = if (req.action == .generate) try std.fs.path.join(a, &.{ directory, req.path }) else req.path;
    const original = if (req.action == .generate) null else try keys.scan.read(a, path);
    defer if (original) |file| file.deinit(a);
    const parsed = if (original) |file| try keys.openssh.parse(a, file.bytes) else null;
    if (parsed) |key| if (!std.mem.eql(u8, key.item.fingerprint, req.fingerprint)) return error.FileChanged;
    if (req.action == .label) return saveLabel(a, io, env, req);
    if (req.action == .recreate_public) {
        if (!parsed.?.private) return error.InvalidAction;
        return writeNew(a, try std.fmt.allocPrint(a, "{s}.pub", .{path}), parsed.?.item.public_key, 0o644);
    }
    if (req.action == .permissions) {
        const z = try a.dupeSentinel(u8, path, 0);
        const fd = c.open(z.ptr, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) return error.UnreadableFile;
        defer _ = c.close(fd);
        if (c.fstat(fd, &stat) != 0 or stat.st_ino != original.?.ino or stat.st_dev != original.?.dev) return error.FileChanged;
        if (c.fchmod(fd, @as(c.mode_t, if (parsed.?.private) 0o600 else 0o644)) != 0 or c.fchmod(dir.handle, 0o700) != 0) return error.WriteFailed;
        return;
    }
    if (req.action == .trash) {
        const gio = platform.tool.system(io, "gio") orelse return error.MissingTrashTool;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ gio, "trash", "--", path });
        // Only trash the companion when it still belongs to this identity.
        if (parsed.?.private) {
            const public = try std.fmt.allocPrint(a, "{s}.pub", .{path});
            if (keys.scan.read(a, public)) |file| {
                defer file.deinit(a);
                const pub_key = keys.openssh.publicLine(a, file.bytes) catch null;
                if (pub_key) |key| if (std.mem.eql(u8, key.fingerprint, req.fingerprint)) try argv.append(a, public);
            } else |_| {}
        }
        try unchanged(a, path, original.?);
        const result = try std.process.run(a, io, .{ .argv = argv.items, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096), .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } } });
        if (result.term != .exited or result.term.exited != 0) return error.TrashFailed;
        return;
    }
    if (parsed) |key| if (!key.private) return error.InvalidAction;
    if (c.fchmod(dir.handle, 0o700) != 0) return error.WriteFailed;
    const stage = try std.fmt.allocPrintSentinel(a, "{s}/.rediwm-keys-XXXXXX", .{directory}, 0);
    if (c.mkdtemp(stage.ptr) == null) return error.StageFailed;
    defer std.Io.Dir.cwd().deleteTree(io, stage) catch {};
    const staged = try std.fs.path.join(a, &.{ stage, "key" });
    if (original) |file| try writeNew(a, staged, file.bytes, 0o600);
    try tool(a, io, req, staged);
    const output = try keys.scan.read(a, staged);
    defer output.deinit(a);
    const checked = try keys.openssh.parse(a, output.bytes);
    if (!checked.private) return error.InvalidKey;
    if (parsed) |key| if (!std.mem.eql(u8, key.item.fingerprint, checked.item.fingerprint)) return error.FileChanged;
    const from = try a.dupeSentinel(u8, staged, 0);
    const to = try a.dupeSentinel(u8, path, 0);
    if (original) |file| {
        try unchanged(a, path, file);
        if (c.rename(from.ptr, to.ptr) != 0) return error.WriteFailed;
    } else {
        const public = try std.fmt.allocPrint(a, "{s}.pub", .{path});
        const check_path = try a.dupeSentinel(u8, public, 0);
        if (c.access(check_path.ptr, c.F_OK) == 0) return error.PathAlreadyExists;
        try platform.fs.renameNoReplace(from.ptr, to.ptr);
        const generated_pub = try keys.scan.read(a, try std.fmt.allocPrint(a, "{s}.pub", .{staged}));
        defer generated_pub.deinit(a);
        try writeNew(a, public, generated_pub.bytes, 0o644);
    }
    if (req.action == .comment) {
        // ssh-keygen -c also updates the public file. Preserve a missing or
        // mismatched companion; the UI reports it for an explicit repair.
        const public = try std.fmt.allocPrint(a, "{s}.pub", .{path});
        if (keys.scan.read(a, public)) |file| {
            defer file.deinit(a);
            const old_public = keys.openssh.publicLine(a, file.bytes) catch return;
            if (std.mem.eql(u8, old_public.fingerprint, req.fingerprint)) {
                const new_public = try keys.scan.read(a, try std.fmt.allocPrint(a, "{s}.pub", .{staged}));
                defer new_public.deinit(a);
                try unchanged(a, public, file);
                const pub_from = try std.fmt.allocPrintSentinel(a, "{s}.pub", .{staged}, 0);
                const pub_to = try a.dupeSentinel(u8, public, 0);
                if (c.rename(pub_from.ptr, pub_to.ptr) != 0) return error.WriteFailed;
            }
        } else |_| {}
    }
}
