//! Helpers shared by the coordinator test files.
const std = @import("std");
const io_coordinator = @import("io_coordinator.zig");
const io_service = @import("io_service.zig");
const io_manager = @import("io_manager.zig");
const c = @import("c.zig").api;

// The Service fails fast with `ServiceBusy` while the coordinator thread holds
// its mutex; callers retry later instead of waiting. These helpers do that for
// tests, which may spin briefly where the UI would retry on its next iteration.
const busy_retries = 100_000;

pub fn send(window: io_service.Handle, command: io_service.Command) !void {
    for (0..busy_retries) |_| {
        window.trySend(command) catch |err| switch (err) {
            error.ServiceBusy => {
                std.Thread.yield() catch {};
                continue;
            },
            else => return err,
        };
        return;
    }
    return error.ServiceBusy;
}

pub fn sendOwned(window: io_service.Handle, command: *io_service.Command) !void {
    for (0..busy_retries) |_| {
        window.trySendOwned(command) catch |err| switch (err) {
            error.ServiceBusy => {
                std.Thread.yield() catch {};
                continue;
            },
            else => return err,
        };
        return;
    }
    return error.ServiceBusy;
}

pub fn receive(window: io_service.Handle) !?io_service.Update {
    for (0..busy_retries) |_| {
        return window.tryReceiveUpdate() catch {
            // ServiceBusy is its only error.
            std.Thread.yield() catch {};
            continue;
        };
    }
    return error.ServiceBusy;
}

pub fn waitReadable(fd: std.posix.fd_t, timeout_ms: i32) bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const rc = std.posix.system.poll(&fds, 1, timeout_ms);
    return std.posix.errno(rc) == .SUCCESS and fds[0].revents != 0;
}

pub fn allocZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

pub fn join(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

pub fn makeTempDir(buffer: []u8) ![]const u8 {
    _ = try std.fmt.bufPrint(buffer, "/tmp/rediwm_coordinator_XXXXXX\x00", .{});
    const result = c.mkdtemp(@ptrCast(buffer.ptr)) orelse return error.MkdtempFailed;
    return std.mem.span(@as([*:0]const u8, @ptrCast(result)));
}

pub fn makeDirectory(path: []const u8) !void {
    const zpath = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(zpath);
    if (c.mkdir(zpath, 0o755) != 0) return error.MkdirFailed;
}

pub fn writeFile(path: []const u8, contents: []const u8) !void {
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

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
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

pub fn makeSymlink(target: []const u8, path: []const u8) !void {
    const ztarget = try allocZ(std.testing.allocator, target);
    defer std.testing.allocator.free(ztarget);
    const zpath = try allocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(zpath);
    if (c.symlink(ztarget, zpath) != 0) return error.SymlinkFailed;
}

pub fn readLink(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const zpath = try allocZ(allocator, path);
    defer allocator.free(zpath);
    var buffer: [4096]u8 = undefined;
    const count = c.readlink(zpath, &buffer, buffer.len);
    if (count < 0) return error.ReadlinkFailed;
    return allocator.dupe(u8, buffer[0..@intCast(count)]);
}

pub fn pathExists(path: []const u8) bool {
    const zpath = allocZ(std.heap.page_allocator, path) catch return false;
    defer std.heap.page_allocator.free(zpath);
    var stat: c.struct_stat = undefined;
    return c.lstat(zpath, &stat) == 0;
}

pub fn waitBriefly() void {
    _ = std.posix.system.poll(&.{}, 0, 10);
}

pub fn waitForContents(path: []const u8, expected: []const u8) !void {
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

pub fn waitForPath(path: []const u8) !void {
    for (0..500) |_| {
        if (pathExists(path)) return;
        waitBriefly();
    }
    return error.TransferTimedOut;
}

pub fn waitForRemoval(path: []const u8) !void {
    for (0..500) |_| {
        if (!pathExists(path)) return;
        waitBriefly();
    }
    return error.TransferTimedOut;
}

pub fn cleanup(path: []const u8, directory: bool) void {
    const zpath = allocZ(std.heap.page_allocator, path) catch return;
    defer std.heap.page_allocator.free(zpath);
    if (directory) {
        _ = c.rmdir(zpath);
    } else {
        _ = c.unlink(zpath);
    }
}

pub fn submitTransfer(
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
    sendOwned(window, &command) catch |err| {
        payload.deinit();
        return err;
    };
}

pub fn resolveConflict(
    allocator: std.mem.Allocator,
    window: io_service.Handle,
    conflict_id: io_manager.ConflictId,
    action: io_service.ConflictAction,
) !void {
    const payload = try io_service.OwnedPayload.createConflictResolution(
        allocator,
        conflict_id,
        action,
        null,
    );
    var command: io_service.Command = .{
        .kind = .resolve_conflict,
        .payload = payload,
    };
    sendOwned(window, &command) catch |err| {
        payload.deinit();
        return err;
    };
}

pub fn sendDiscoveryCommand(
    allocator: std.mem.Allocator,
    window: io_service.Handle,
    kind: io_service.CommandKind,
    job_id: io_service.JobId,
    root_entry_id: u64,
    root_path: ?[]const u8,
) !void {
    const payload = try io_service.OwnedPayload.createDiscovery(
        allocator,
        root_entry_id,
        root_path,
    );
    var command: io_service.Command = .{
        .kind = kind,
        .job_id = job_id,
        .payload = payload,
    };
    sendOwned(window, &command) catch |err| {
        payload.deinit();
        return err;
    };
}

pub fn waitForRejection(
    service: *io_service.Service,
    window: io_service.Handle,
    job_id: io_service.JobId,
) !io_service.Update {
    for (0..500) |_| {
        if (waitReadable(service.updateWakeFd(), 10))
            _ = service.drainUpdateWake();
        while (try receive(window)) |update| {
            if (update.kind == .command_rejected and update.job_id == job_id)
                return update;
        }
    }
    return error.CommandRejectionTimedOut;
}

pub fn waitForJobState(window: io_service.Handle, service: *io_service.Service, job_id: u64, state: io_manager.JobState) !void {
    for (0..1000) |_| {
        if (waitReadable(service.updateWakeFd(), 10)) _ = service.drainUpdateWake();
        while (try receive(window)) |update| {
            if (update.kind == .job_state and update.job_id == job_id and
                update.state_code == @intFromEnum(state)) return;
        }
    }
    return error.Timeout;
}

pub fn waitForRejection999(window: io_service.Handle, service: *io_service.Service) !void {
    for (0..1000) |_| {
        if (waitReadable(service.updateWakeFd(), 10)) _ = service.drainUpdateWake();
        while (try receive(window)) |update| {
            if (update.kind == .command_rejected and update.job_id == 999) return;
        }
    }
    return error.Timeout;
}

pub fn submitSources(
    allocator: std.mem.Allocator,
    window: io_service.Handle,
    mode: io_service.TransferMode,
    destination: []const u8,
    sources: []const []const u8,
) !void {
    var payload = try io_service.OwnedPayload.createTransfer(
        allocator,
        mode,
        destination,
        sources,
    );
    var command: io_service.Command = .{
        .kind = .submit_job,
        .payload = payload,
    };
    sendOwned(window, &command) catch |err| {
        payload.deinit();
        return err;
    };
}

/// Waits for the next rejection routed to `window` and returns its code.
pub fn waitForAnyRejection(window: io_service.Handle, service: *io_service.Service) !u8 {
    for (0..1000) |_| {
        if (waitReadable(service.updateWakeFd(), 10)) _ = service.drainUpdateWake();
        while (try receive(window)) |update| {
            if (update.kind == .command_rejected) return update.state_code;
        }
    }
    return error.Timeout;
}
