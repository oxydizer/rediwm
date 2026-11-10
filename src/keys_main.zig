//! No privileges, no compositor imports, and no private bytes in replies.
const std = @import("std");
const c = @import("c");
const keys = @import("keys");
const platform = @import("platform");
const helper = @import("keys_helper.zig");
const secure = @import("network/secure_allocator.zig").allocator;

fn run(init: std.process.Init) !void {
    try platform.process.denyDumps();
    platform.process.ignoreBrokenPipes();
    platform.process.dieWithParent(.KILL);
    if (std.c.geteuid() == 0) return error.RunAsDesktopUser;
    try std.posix.setrlimit(.AS, .{ .cur = 256 << 20, .max = 256 << 20 });
    try std.posix.setrlimit(.CPU, .{ .cur = 10, .max = 10 });
    const args = init.minimal.args.vector;
    if (args.len != 2) return error.Usage;
    const verb = std.mem.span(args[1]);
    const env = init.minimal.environ;
    if (!std.mem.eql(u8, verb, "scan") and !std.mem.eql(u8, verb, "op")) return helper.askpass(env, verb);
    _ = c.umask(0o077);
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var reply: keys.protocol.Reply = .{};
    if (std.mem.eql(u8, verb, "op")) {
        const buffer = try secure.alloc(u8, 16384);
        defer secure.free(buffer);
        var used: usize = 0;
        while (true) {
            if (used == buffer.len) return error.RequestTooLarge;
            const n = c.read(0, buffer.ptr + used, buffer.len - used);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            used += @intCast(n);
        }
        const request = try std.json.parseFromSlice(keys.protocol.Request, secure, buffer[0..used], .{ .allocate = .alloc_always, .max_value_len = 4096 });
        defer request.deinit();
        helper.perform(a, init.io, env, request.value) catch |err| {
            reply.failure = @errorName(err);
        };
    }
    const keygen = platform.tool.system(init.io, "ssh-keygen") != null;
    const trash = platform.tool.system(init.io, "gio") != null;
    const directory = std.Io.Dir.cwd().openDir(init.io, try keys.scan.sshDir(a, env), .{ .iterate = true, .follow_symlinks = false }) catch |err| blk: {
        if (err != error.FileNotFound) reply.failure = @errorName(err);
        break :blk null;
    };
    defer if (directory) |dir| dir.close(init.io);
    // Preopen the two read capabilities before entering the FreeBSD sandbox.
    const index_path = try a.dupeSentinel(u8, try helper.indexPath(a, env), 0);
    const index_fd = c.open(index_path.ptr, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_NONBLOCK);
    defer if (index_fd >= 0) {
        _ = c.close(index_fd);
    };
    // After the operation, even the refresh runs with read-only syscalls.
    try platform.key_scan.enter(if (directory) |dir| dir.handle else -1, index_fd);
    reply.inventory = keys.scan.inventory(a, init.io, env, directory) catch |err| blk: {
        if (reply.failure == null) reply.failure = @errorName(err);
        break :blk .{};
    };
    reply.inventory.keygen = keygen;
    reply.inventory.trash = trash;
    if (index_fd >= 0) {
        var info: c.struct_stat = undefined;
        if (c.fstat(index_fd, &info) == 0 and info.st_uid == std.c.getuid() and info.st_mode & c.S_IFMT == c.S_IFREG and info.st_size > 0 and info.st_size <= keys.model.max_file) {
            const index_bytes = try a.alloc(u8, @intCast(info.st_size));
            const count = c.read(index_fd, index_bytes.ptr, index_bytes.len);
            if (count == index_bytes.len) try helper.applyLabels(a, index_bytes, &reply.inventory);
        }
    }
    const bytes = try std.json.Stringify.valueAlloc(a, reply, .{});
    if (bytes.len > keys.model.max_reply) return error.ResponseTooLarge;
    try helper.writeAll(1, bytes);
}
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        // Error names are metadata: tool output and requests are never logged.
        std.debug.print("rediwm-keys: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
