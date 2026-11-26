const std = @import("std");
const c = @import("c.zig").api;
const io_service = @import("io_service.zig");
const io_job_table = @import("io_job_table.zig");
const io_endpoint = @import("io_endpoint.zig");
const subscribers = @import("io_endpoint_subscribers.zig");

const allocator = std.testing.allocator;

fn record(id: u64, state: io_service.JobState) io_service.JobRecord {
    var value: io_service.JobRecord = .{ .id = id, .kind = .copy, .state = state, .total_bytes = 100 };
    value.setLabel("photo.jpg");
    return value;
}

const Event = struct {
    version: u32,
    event: []const u8,
    sequence: u64,
    jobs: []const struct {
        id: u64,
        state: []const u8,
        label: []const u8,
        removed: bool,
        rate_history: ?[]const u64 = null,
    },
};

/// Splits `output` into lines and parses each as an event.
fn events(output: []const u8, out: []std.json.Parsed(Event)) !usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        out[count] = try std.json.parseFromSlice(Event, allocator, line, .{ .ignore_unknown_fields = true });
        count += 1;
    }
    return count;
}

test "external control: pause, resume and cancel reach the coordinator's queue" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    try std.testing.expectError(error.JobNotFound, service.sendControl(.pause, 7));
    try service.createJobRecord(record(7, .running), false);
    try service.sendControl(.pause, 7);
    try std.testing.expect(service.hasQueuedCommands());
    const routed = service.tryReceiveCommand() orelse return error.MissingCommand;
    try std.testing.expectEqual(io_service.CommandKind.pause_job, routed.command.kind);
    try std.testing.expectEqual(@as(u64, 7), routed.command.job_id);
    try std.testing.expectEqual(@as(u64, 0), routed.window_id);

    try service.updateJobRecord(record(7, .completed));
    try std.testing.expectError(error.InvalidState, service.sendControl(.cancel, 7));
    try service.retireJobRecord(7);
}

test "subscriber: a snapshot with speed history, then changes, then the retirement" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    try service.createJobRecord(record(1, .running), false);
    service.appendRateSample(1, 5000);
    service.appendRateSample(1, 7000);

    var subscriber = try subscribers.Subscriber.init(&service);
    defer subscriber.deinit(allocator);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try std.testing.expect(subscriber.pump(allocator, &output));
    var parsed: [4]std.json.Parsed(Event) = undefined;
    var n = try events(output.items, &parsed);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("snapshot", parsed[0].value.event);
    try std.testing.expectEqual(@as(usize, 1), parsed[0].value.jobs.len);
    try std.testing.expectEqualStrings("photo.jpg", parsed[0].value.jobs[0].label);
    try std.testing.expectEqualSlices(u64, &.{ 5000, 7000 }, parsed[0].value.jobs[0].rate_history.?);
    parsed[0].deinit();
    output.clearRetainingCapacity();

    // Nothing changed: nothing sent.
    try std.testing.expect(subscriber.pump(allocator, &output));
    try std.testing.expectEqual(@as(usize, 0), output.items.len);

    try service.updateJobRecord(record(1, .completed));
    try service.retireJobRecord(1);
    try std.testing.expect(subscriber.pump(allocator, &output));
    n = try events(output.items, &parsed);
    defer for (parsed[0..n]) |*p| p.deinit();
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("jobs", parsed[0].value.event);
    // The update and the retirement of one job arrive as its newest record.
    const last = parsed[0].value.jobs[parsed[0].value.jobs.len - 1];
    try std.testing.expectEqualStrings("completed", last.state);
    try std.testing.expect(last.removed);
}

test "subscriber: falling behind the retired jobs it missed brings a new snapshot" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();

    var subscriber = try subscribers.Subscriber.init(&service);
    defer subscriber.deinit(allocator);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try std.testing.expect(subscriber.pump(allocator, &output));
    output.clearRetainingCapacity();

    // More retirements than the tombstone ring holds, unread.
    for (0..io_job_table.tombstone_capacity + 4) |i| {
        try service.createJobRecord(record(100 + i, .completed), false);
        try service.retireJobRecord(100 + i);
    }
    try service.createJobRecord(record(999, .running), false);
    defer {
        service.retireJobRecord(999) catch {};
    }

    try std.testing.expect(subscriber.pump(allocator, &output));
    var parsed: [4]std.json.Parsed(Event) = undefined;
    const n = try events(output.items, &parsed);
    defer for (parsed[0..n]) |*p| p.deinit();
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("snapshot", parsed[0].value.event);
    // Only what is still live.
    try std.testing.expectEqual(@as(usize, 1), parsed[0].value.jobs.len);
    try std.testing.expectEqual(@as(u64, 999), parsed[0].value.jobs[0].id);
}

test "endpoint: Subscribe over the socket answers, then sends the snapshot and changes" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();
    try service.createJobRecord(record(5, .running), false);
    defer service.retireJobRecord(5) catch {};

    var dir_buf: [64]u8 = undefined;
    const template = "/tmp/rediwm_subscribe_XXXXXX";
    @memcpy(dir_buf[0..template.len], template);
    dir_buf[template.len] = 0;
    const dir = std.mem.span(@as([*:0]const u8, @ptrCast(c.mkdtemp(@ptrCast(&dir_buf)) orelse return error.MkdtempFailed)));
    var paths = try io_endpoint.Paths.init(allocator, dir, "wayland-test");
    defer paths.deinit(allocator);
    defer {
        _ = c.unlink(paths.lock);
        _ = c.rmdir(@ptrCast(&dir_buf));
    }

    var endpoint: io_endpoint.Endpoint = undefined;
    switch (io_endpoint.claim(allocator, &paths, .{ .path = "/" })) {
        .instance => |fd| try endpoint.start(allocator, fd, paths.socket, &service),
        else => return error.TestUnexpectedResult,
    }
    defer endpoint.deinit();

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    defer _ = c.close(fd);
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(address.sun_path[0..paths.socket.len], paths.socket);
    try std.testing.expectEqual(@as(c_int, 0), std.c.connect(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)));

    const requests = "{\"version\":1,\"id\":\"s\",\"command\":\"Subscribe\"}\n" ++
        "{\"version\":1,\"id\":\"p\",\"command\":\"PauseJob\",\"params\":{\"job_id\":404}}\n";
    _ = c.send(fd, requests, requests.len, c.MSG_NOSIGNAL);
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(allocator);
    try readLines(fd, &received, 3);
    try std.testing.expect(std.mem.indexOf(u8, received.items, "\"id\":\"s\",\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, received.items, "\"event\":\"snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, received.items, "JOB_NOT_FOUND") != null);

    received.clearRetainingCapacity();
    var changed = record(5, .paused);
    changed.completed_bytes = 40;
    try service.updateJobRecord(changed);
    try readLines(fd, &received, 1);
    try std.testing.expect(std.mem.indexOf(u8, received.items, "\"event\":\"jobs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, received.items, "\"state\":\"paused\"") != null);
}

/// Reads until `want` complete lines arrived, or two seconds passed.
fn readLines(fd: c_int, out: *std.ArrayList(u8), want: usize) !void {
    var waited: usize = 0;
    while (std.mem.count(u8, out.items, "\n") < want) {
        var pfd = [_]c.struct_pollfd{.{ .fd = fd, .events = c.POLLIN, .revents = 0 }};
        if (c.poll(&pfd, 1, 100) <= 0) {
            waited += 1;
            if (waited == 20) return error.Timeout;
            continue;
        }
        var buf: [4096]u8 = undefined;
        const n = c.recv(fd, &buf, buf.len, 0);
        if (n <= 0) return error.Closed;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
}
