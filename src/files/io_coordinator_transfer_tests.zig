//! Coordinator transfers that the JobRunner fallback used to cover: mixed
//! selections, copies onto the source itself, moves onto itself, overlapping
//! moves and unsupported file types (roadmap phase 2).
const std = @import("std");
const c = @import("c.zig").api;
const io_coordinator = @import("io_coordinator.zig");
const io_service = @import("io_service.zig");
const ops = @import("ops.zig");
const support = @import("io_coordinator_test_support.zig");
const io_service_tasks = @import("io_service_tasks.zig");

const allocator = std.testing.allocator;
const Code = io_coordinator.RejectionCode;

/// A temporary directory with a running coordinator and one window.
const Fixture = struct {
    temp_buffer: [256]u8 = undefined,
    temp: []const u8 = "",
    service: io_service.Service = .{},
    coordinator: io_coordinator.Coordinator = undefined,
    window: io_service.Handle = undefined,
    view: support.View = undefined,

    fn start(self: *Fixture) !void {
        self.temp = try support.makeTempDir(&self.temp_buffer);
        try self.service.init();
        try self.coordinator.init(allocator, &self.service);
        self.window = try self.service.registerWindow();
        self.view = support.View.init(self.window, &self.service);
    }

    fn stop(self: *Fixture) void {
        self.coordinator.deinit();
        self.window.close();
        self.service.deinit();
        ops.deleteRecursive(allocator, self.temp) catch {};
    }

    fn path(self: *Fixture, name: []const u8) ![]u8 {
        return support.join(allocator, self.temp, name);
    }

    fn rejection(self: *Fixture) !Code {
        return @enumFromInt(try self.view.failedSubmit());
    }
};

test "a mixed selection of files and folders copies as one job" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();

    const file = try f.path("note.txt");
    defer allocator.free(file);
    const folder = try f.path("folder");
    defer allocator.free(folder);
    const child = try f.path("folder/child.txt");
    defer allocator.free(child);
    const destination = try f.path("destination");
    defer allocator.free(destination);
    try support.writeFile(file, "loose file");
    try support.makeDirectory(folder);
    try support.writeFile(child, "inside the folder");
    try support.makeDirectory(destination);

    try support.submitSources(allocator, f.window, .copy, destination, &.{ file, folder });

    const copied_file = try f.path("destination/note.txt");
    defer allocator.free(copied_file);
    const copied_child = try f.path("destination/folder/child.txt");
    defer allocator.free(copied_child);
    try support.waitForContents(copied_file, "loose file");
    try support.waitForContents(copied_child, "inside the folder");
    try f.view.waitState(1, .completed);
    try std.testing.expect(support.pathExists(file));
    try std.testing.expect(support.pathExists(child));
}

test "a mixed selection of files and folders moves as one job" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();

    const file = try f.path("note.txt");
    defer allocator.free(file);
    const folder = try f.path("folder");
    defer allocator.free(folder);
    const child = try f.path("folder/child.txt");
    defer allocator.free(child);
    const destination = try f.path("destination");
    defer allocator.free(destination);
    try support.writeFile(file, "loose file");
    try support.makeDirectory(folder);
    try support.writeFile(child, "inside the folder");
    try support.makeDirectory(destination);

    try support.submitSources(allocator, f.window, .move, destination, &.{ file, folder });

    const moved_file = try f.path("destination/note.txt");
    defer allocator.free(moved_file);
    const moved_child = try f.path("destination/folder/child.txt");
    defer allocator.free(moved_child);
    try support.waitForContents(moved_file, "loose file");
    try support.waitForContents(moved_child, "inside the folder");
    try f.view.waitState(1, .completed);
    try support.waitForRemoval(file);
    try support.waitForRemoval(folder);
}

test "copying a file into its own folder makes a uniquely named copy" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();

    const file = try f.path("report.txt");
    defer allocator.free(file);
    try support.writeFile(file, "original");
    const expected_name = try ops.generateUniqueName(allocator, f.temp, "report.txt");
    defer allocator.free(expected_name);
    const expected = try f.path(expected_name);
    defer allocator.free(expected);

    try support.submitSources(allocator, f.window, .copy, f.temp, &.{file});

    try support.waitForContents(expected, "original");
    try f.view.waitState(1, .completed);
    try support.waitForContents(file, "original");
}

test "copying a folder into its own parent makes a uniquely named copy" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();

    const folder = try f.path("album");
    defer allocator.free(folder);
    const child = try f.path("album/track.txt");
    defer allocator.free(child);
    try support.makeDirectory(folder);
    try support.writeFile(child, "track");
    const expected_name = try ops.generateUniqueName(allocator, f.temp, "album");
    defer allocator.free(expected_name);
    const expected_child = try std.fmt.allocPrint(allocator, "{s}/{s}/track.txt", .{ f.temp, expected_name });
    defer allocator.free(expected_child);

    try support.submitSources(allocator, f.window, .copy, f.temp, &.{folder});

    try support.waitForContents(expected_child, "track");
    try f.view.waitState(1, .completed);
    try support.waitForContents(child, "track");
}

test "moving items onto themselves changes nothing and is reported" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();

    const file = try f.path("stay.txt");
    defer allocator.free(file);
    try support.writeFile(file, "unchanged");

    try support.submitSources(allocator, f.window, .move, f.temp, &.{file});

    try std.testing.expectEqual(Code.nothing_to_transfer, try f.rejection());
    try support.waitForContents(file, "unchanged");
}

test "a move of a folder together with an item inside it is refused" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();

    const folder = try f.path("folder");
    defer allocator.free(folder);
    const child = try f.path("folder/child.txt");
    defer allocator.free(child);
    const destination = try f.path("destination");
    defer allocator.free(destination);
    try support.makeDirectory(folder);
    try support.writeFile(child, "child");
    try support.makeDirectory(destination);

    try support.submitSources(allocator, f.window, .move, destination, &.{ folder, child });

    try std.testing.expectEqual(Code.overlapping_move_roots, try f.rejection());
    try support.waitForContents(child, "child");
}

test "special files are refused with their own code" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();

    const fifo = try f.path("pipe");
    defer allocator.free(fifo);
    const fifo_z = try allocator.dupeSentinel(u8, fifo, 0);
    defer allocator.free(fifo_z);
    try std.testing.expectEqual(@as(c_int, 0), c.mkfifo(fifo_z, 0o600));
    const destination = try f.path("destination");
    defer allocator.free(destination);
    try support.makeDirectory(destination);

    try support.submitSources(allocator, f.window, .copy, destination, &.{fifo});

    try std.testing.expectEqual(Code.unsupported_source, try f.rejection());
}

test "a folder copied into itself is refused" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();

    const folder = try f.path("folder");
    defer allocator.free(folder);
    const inner = try f.path("folder/inner");
    defer allocator.free(inner);
    try support.makeDirectory(folder);
    try support.makeDirectory(inner);

    try support.submitSources(allocator, f.window, .copy, inner, &.{folder});

    try std.testing.expectEqual(Code.destination_inside_source, try f.rejection());
}

test "a submit whose preparation hangs does not delay other jobs or its own cancellation" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();
    const gate = io_service_tasks.test_gate;
    defer gate.release(); // before f.stop joins the workers

    const hung = try f.path("hung.txt");
    defer allocator.free(hung);
    const other = try f.path("other.txt");
    defer allocator.free(other);
    const destination = try f.path("destination");
    defer allocator.free(destination);
    try support.writeFile(hung, "hung");
    try support.writeFile(other, "other");
    try support.makeDirectory(destination);

    // Job 1's preparation parks on a service worker, as on a hung mount. Its
    // record exists at once, in `planning`.
    gate.arm();
    try support.submitSources(allocator, f.window, .copy, destination, &.{hung});
    try f.view.waitState(1, .planning);
    for (0..1000) |_| {
        if (gate.parked.load(.acquire)) break;
        support.waitBriefly();
    } else return error.Timeout;

    // Job 2 is prepared on the other worker and completes meanwhile.
    try support.submitSources(allocator, f.window, .copy, destination, &.{other});
    const copied_other = try f.path("destination/other.txt");
    defer allocator.free(copied_other);
    try support.waitForContents(copied_other, "other");
    try f.view.waitState(2, .completed);

    // Cancelling the parked job is accepted at once; the plan is discarded
    // when it returns, and nothing of job 1 is copied.
    try support.send(f.window, .{ .kind = .cancel_job, .job_id = 1 });
    _ = try f.view.waitFor(support.CancelRequested{ .id = 1 });
    gate.release();
    try f.view.waitState(1, .cancelled);
    const copied_hung = try f.path("destination/hung.txt");
    defer allocator.free(copied_hung);
    try std.testing.expect(!support.pathExists(copied_hung));
    try std.testing.expect(f.view.find(1).?.removed);
}
