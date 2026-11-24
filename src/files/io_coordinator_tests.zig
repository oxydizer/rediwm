const std = @import("std");
const io_coordinator = @import("io_coordinator.zig");
const io_service = @import("io_service.zig");

test "coordinator rejects transfer submissions without a payload" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(std.testing.allocator, &service);
    defer coordinator.deinit();

    var window = try service.registerWindow();
    defer window.close() catch unreachable;

    try window.trySend(.{ .kind = .submit_job, .job_id = 73 });
    try std.testing.expect(waitReadable(service.updateWakeFd(), 2000));
    _ = service.drainUpdateWake();

    const update = (try window.tryReceiveUpdate()).?;
    try std.testing.expectEqual(io_service.UpdateKind.command_rejected, update.kind);
    try std.testing.expectEqual(@as(u64, 73), update.job_id);
    try std.testing.expectEqual(@as(u8, 5), update.state_code);
}

fn waitReadable(fd: std.posix.fd_t, timeout_ms: i32) bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const rc = std.posix.system.poll(&fds, 1, timeout_ms);
    return std.posix.errno(rc) == .SUCCESS and fds[0].revents != 0;
}

const c = @import("c.zig").api;

fn allocZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

fn join(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

fn makeTempDir(buffer: []u8) ![]const u8 {
    _ = try std.fmt.bufPrint(buffer, "/tmp/rediwm_coordinator_XXXXXX\x00", .{});
    const result = c.mkdtemp(@ptrCast(buffer.ptr)) orelse return error.MkdtempFailed;
    return std.mem.span(@as([*:0]const u8, @ptrCast(result)));
}

fn makeDirectory(path: []const u8) !void {
    const zpath = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(zpath);
    if (c.mkdir(zpath, 0o755) != 0) return error.MkdirFailed;
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    const zpath = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(zpath);
    const fd = c.open(
        zpath,
        c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC,
        @as(c_uint, 0o600),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.write(fd, contents.ptr, contents.len) != contents.len)
        return error.WriteFailed;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const zpath = try allocZ(allocator, path);
    defer allocator.free(zpath);
    const fd = c.open(zpath, c.O_RDONLY | c.O_CLOEXEC, @as(c_uint, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var buffer: [4096]u8 = undefined;
    const count = c.read(fd, &buffer, buffer.len);
    if (count < 0) return error.ReadFailed;
    return allocator.dupe(u8, buffer[0..@intCast(count)]);
}

fn makeSymlink(target: []const u8, path: []const u8) !void {
    const ztarget = try allocZ(std.testing.allocator, target);
    defer std.testing.allocator.free(ztarget);
    const zpath = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(zpath);
    if (c.symlink(ztarget, zpath) != 0) return error.SymlinkFailed;
}

fn readLink(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const zpath = try allocZ(allocator, path);
    defer allocator.free(zpath);
    var buffer: [4096]u8 = undefined;
    const count = c.readlink(zpath, &buffer, buffer.len);
    if (count < 0) return error.ReadlinkFailed;
    return allocator.dupe(u8, buffer[0..@intCast(count)]);
}

fn pathExists(path: []const u8) bool {
    const zpath = allocZ(std.heap.page_allocator, path) catch return false;
    defer std.heap.page_allocator.free(zpath);
    var stat: c.struct_stat = undefined;
    return c.lstat(zpath, &stat) == 0;
}

fn waitBriefly() void {
    _ = std.posix.system.poll(&.{}, 0, 10);
}

fn waitForContents(path: []const u8, expected: []const u8) !void {
    for (0..500) |_| {
        if (pathExists(path)) {
            const contents = readFile(std.testing.allocator, path) catch {
                waitBriefly();
                continue;
            };
            defer std.testing.allocator.free(contents);
            if (std.mem.eql(u8, contents, expected)) return;
        }
        waitBriefly();
    }
    return error.TransferTimedOut;
}

fn waitForPath(path: []const u8) !void {
    for (0..500) |_| {
        if (pathExists(path)) return;
        waitBriefly();
    }
    return error.TransferTimedOut;
}

fn waitForRemoval(path: []const u8) !void {
    for (0..500) |_| {
        if (!pathExists(path)) return;
        waitBriefly();
    }
    return error.TransferTimedOut;
}

fn cleanup(path: []const u8, directory: bool) void {
    const zpath = allocZ(std.heap.page_allocator, path) catch return;
    defer std.heap.page_allocator.free(zpath);
    if (directory) {
        _ = c.rmdir(zpath);
    } else {
        _ = c.unlink(zpath);
    }
}

fn submitTransfer(
    allocator: std.mem.Allocator,
    window: io_service.Handle,
    mode: io_service.TransferMode,
    destination: []const u8,
    source: []const u8,
) !void {
    const sources = [_][]const u8{source};
    var payload = try io_service.OwnedPayload.createTransfer(
        allocator,
        mode,
        destination,
        &sources,
    );
    var command: io_service.Command = .{
        .kind = .submit_job,
        .payload = payload,
    };
    window.trySendOwned(&command) catch |err| {
        payload.deinit();
        return err;
    };
}

test "coordinator copies a regular-file transfer" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "payload.bin");
    defer allocator.free(source);
    defer cleanup(source, false);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    const destination = try join(allocator, destination_dir, "payload.bin");
    defer allocator.free(destination);
    defer cleanup(destination, false);

    try writeFile(source, "coordinator regular-file copy");
    try makeDirectory(destination_dir);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);
    defer coordinator.deinit();

    var window = try service.registerWindow();
    defer window.close() catch unreachable;

    try submitTransfer(allocator, window, .copy, destination_dir, source);
    try waitForContents(destination, "coordinator regular-file copy");

    try std.testing.expect(pathExists(source));
}

test "coordinator copies a symlink without dereferencing its target" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "relative-link");
    defer allocator.free(source);
    defer cleanup(source, false);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    const destination = try join(allocator, destination_dir, "relative-link");
    defer allocator.free(destination);
    defer cleanup(destination, false);

    try makeSymlink("../missing/target", source);
    try makeDirectory(destination_dir);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);
    defer coordinator.deinit();

    var window = try service.registerWindow();
    defer window.close() catch unreachable;

    try submitTransfer(allocator, window, .copy, destination_dir, source);
    try waitForPath(destination);

    const target = try readLink(allocator, destination);
    defer allocator.free(target);
    try std.testing.expectEqualStrings("../missing/target", target);
    try std.testing.expect(pathExists(source));
}

test "coordinator moves a same-filesystem regular file" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "move-me.bin");
    defer allocator.free(source);
    defer cleanup(source, false);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    const destination = try join(allocator, destination_dir, "move-me.bin");
    defer allocator.free(destination);
    defer cleanup(destination, false);

    try writeFile(source, "coordinator same-filesystem move");
    try makeDirectory(destination_dir);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);
    defer coordinator.deinit();

    var window = try service.registerWindow();
    defer window.close() catch unreachable;

    try submitTransfer(allocator, window, .move, destination_dir, source);
    try waitForContents(destination, "coordinator same-filesystem move");
    try waitForRemoval(source);
}

test "coordinator discovers and copies a directory tree" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const source_nested = try join(allocator, source, "nested");
    defer allocator.free(source_nested);
    const source_file = try join(allocator, source, "root.txt");
    defer allocator.free(source_file);
    const source_nested_file = try join(allocator, source_nested, "nested.txt");
    defer allocator.free(source_nested_file);

    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination = try join(allocator, destination_dir, "source");
    defer allocator.free(destination);
    const destination_nested = try join(allocator, destination, "nested");
    defer allocator.free(destination_nested);
    const destination_file = try join(allocator, destination, "root.txt");
    defer allocator.free(destination_file);
    const destination_nested_file = try join(allocator, destination_nested, "nested.txt");
    defer allocator.free(destination_nested_file);

    defer cleanup(destination_dir, true);
    defer cleanup(destination, true);
    defer cleanup(destination_nested, true);
    defer cleanup(destination_file, false);
    defer cleanup(destination_nested_file, false);
    defer cleanup(source, true);
    defer cleanup(source_nested, true);
    defer cleanup(source_file, false);
    defer cleanup(source_nested_file, false);

    try makeDirectory(source);
    try makeDirectory(source_nested);
    try makeDirectory(destination_dir);
    try writeFile(source_file, "directory root content");
    try writeFile(source_nested_file, "directory nested content");

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);
    defer coordinator.deinit();

    var window = try service.registerWindow();
    defer window.close() catch unreachable;

    try submitTransfer(allocator, window, .copy, destination_dir, source);
    try waitForContents(destination_file, "directory root content");
    try waitForContents(destination_nested_file, "directory nested content");

    try std.testing.expect(pathExists(source_file));
    try std.testing.expect(pathExists(source_nested_file));
}

test "coordinator moves a same-filesystem directory tree" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const source = try join(allocator, temp, "source");
    defer allocator.free(source);
    const source_nested = try join(allocator, source, "nested");
    defer allocator.free(source_nested);
    const source_file = try join(allocator, source_nested, "payload.txt");
    defer allocator.free(source_file);

    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination = try join(allocator, destination_dir, "source");
    defer allocator.free(destination);
    const destination_nested = try join(allocator, destination, "nested");
    defer allocator.free(destination_nested);
    const destination_file = try join(allocator, destination_nested, "payload.txt");
    defer allocator.free(destination_file);

    defer cleanup(destination_dir, true);
    defer cleanup(destination, true);
    defer cleanup(destination_nested, true);
    defer cleanup(destination_file, false);
    defer cleanup(source, true);
    defer cleanup(source_nested, true);
    defer cleanup(source_file, false);

    try makeDirectory(source);
    try makeDirectory(source_nested);
    try makeDirectory(destination_dir);
    try writeFile(source_file, "directory move content");

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);
    defer coordinator.deinit();

    var window = try service.registerWindow();
    defer window.close() catch unreachable;

    try submitTransfer(allocator, window, .move, destination_dir, source);
    try waitForContents(destination_file, "directory move content");
    try waitForRemoval(source);
}

test "coordinator rejects an invalid transfer source" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTempDir(&temp_buffer);
    defer cleanup(temp, true);

    const missing_source = try join(allocator, temp, "does-not-exist");
    defer allocator.free(missing_source);
    const destination_dir = try join(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    defer cleanup(destination_dir, true);
    try makeDirectory(destination_dir);

    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var coordinator: io_coordinator.Coordinator = undefined;
    try coordinator.init(allocator, &service);
    defer coordinator.deinit();

    var window = try service.registerWindow();
    defer window.close() catch unreachable;

    try submitTransfer(allocator, window, .copy, destination_dir, missing_source);

    try std.testing.expect(waitReadable(service.updateWakeFd(), 2000));
    _ = service.drainUpdateWake();

    const update = (try window.tryReceiveUpdate()).?;
    try std.testing.expectEqual(io_service.UpdateKind.command_rejected, update.kind);
    try std.testing.expectEqual(@as(u8, 255), update.state_code);
    try std.testing.expectEqual(@as(usize, 0), blk: {
        var count: usize = 0;
        const zpath = try allocZ(allocator, destination_dir);
        defer allocator.free(zpath);
        const dir = c.opendir(zpath) orelse return error.OpenDirectoryFailed;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, ".."))
                count += 1;
        }
        break :blk count;
    });
}
