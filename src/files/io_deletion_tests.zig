//! Deletion jobs through a running coordinator, and their child handling.
const std = @import("std");
const io_coordinator = @import("io_coordinator.zig");
const io_service = @import("io_service.zig");
const io_deletion = @import("io_deletion.zig");
const deletions = @import("io_coordinator_deletions.zig");
const ops = @import("ops.zig");
const support = @import("io_coordinator_test_support.zig");

const allocator = std.testing.allocator;

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
        try self.coordinator.init(allocator, std.testing.io, &self.service);
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

    fn submit(self: *Fixture, kind: io_service.DeletionKind, paths: []const []const u8, trash_dir: ?[]const u8) !void {
        var command: io_service.Command = .{
            .kind = .submit_job,
            .submit_tag = 7,
            .payload = try io_service.OwnedPayload.createDeletion(allocator, kind, paths, trash_dir),
        };
        defer command.deinitPayload();
        try support.sendOwned(self.window, &command);
    }

    /// The final record of the first deletion job.
    fn finished(self: *Fixture) !io_service.JobRecord {
        return self.view.waitFor(support.Retired{ .id = deletions.id_base });
    }
};

test "a delete job removes files and folders and reports its items" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();

    const file = try f.path("note.txt");
    defer allocator.free(file);
    const folder = try f.path("folder");
    defer allocator.free(folder);
    const child = try f.path("folder/child.txt");
    defer allocator.free(child);
    try support.writeFile(file, "x");
    try support.makeDirectory(folder);
    try support.writeFile(child, "y");

    try f.submit(.delete, &.{ file, folder }, null);
    const record = try f.finished();
    try std.testing.expectEqual(io_service.JobState.completed, record.state);
    try std.testing.expectEqual(io_service.JobKind.delete, record.kind);
    try std.testing.expectEqual(@as(u64, 7), record.submit_tag);
    try std.testing.expectEqual(@as(u64, 2), record.total_items);
    try std.testing.expectEqual(@as(u64, 2), record.completed_items);
    try std.testing.expectEqualStrings("note.txt", record.label());
    try std.testing.expect(!support.pathExists(file));
    try std.testing.expect(!support.pathExists(folder));
}

test "deleting from the Trash removes entries with their metadata and refuses other paths" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();

    const trash_files = try f.path("Trash/files");
    defer allocator.free(trash_files);
    const info = try f.path("Trash/info");
    defer allocator.free(info);
    const entry = try f.path("Trash/files/old.txt");
    defer allocator.free(entry);
    const metadata = try f.path("Trash/info/old.txt.trashinfo");
    defer allocator.free(metadata);
    const outside = try f.path("outside.txt");
    defer allocator.free(outside);
    const root = try f.path("Trash");
    defer allocator.free(root);
    try support.makeDirectory(root);
    try support.makeDirectory(trash_files);
    try support.makeDirectory(info);
    try support.writeFile(entry, "trashed");
    try support.writeFile(metadata, "[Trash Info]\nPath=/tmp/old.txt\nDeletionDate=2026-01-01T00:00:00\n");
    try support.writeFile(outside, "keep");

    try f.submit(.delete_from_trash, &.{ entry, outside }, trash_files);
    const record = try f.finished();
    try std.testing.expectEqual(io_service.JobState.completed_with_errors, record.state);
    try std.testing.expectEqual(@as(u64, 2), record.completed_items);
    try std.testing.expect(!support.pathExists(entry));
    try std.testing.expect(!support.pathExists(metadata));
    try std.testing.expect(support.pathExists(outside));
}

test "a delete job whose every path fails is failed" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();

    const trash_files = try f.path("files");
    defer allocator.free(trash_files);
    const stray = try f.path("stray.txt");
    defer allocator.free(stray);
    try f.submit(.delete_from_trash, &.{stray}, trash_files);
    const record = try f.finished();
    try std.testing.expectEqual(io_service.JobState.failed, record.state);
    try std.testing.expectEqual(@backingInt(io_coordinator.RejectionCode.deletion_failed), record.error_code);
}

test "a cancel terminates the running child" {
    var control: io_deletion.Control = .{};
    const Canceller = struct {
        fn run(target: *io_deletion.Control) void {
            _ = std.posix.system.poll(&.{}, 0, 50);
            target.cancel.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&control});
    defer thread.join();
    const outcome = io_deletion.runChild(std.testing.io, &.{ "sleep", "30" }, &control);
    try std.testing.expectEqual(io_deletion.ChildOutcome.cancelled, outcome);
}

test "a missing program is reported as missing" {
    var control: io_deletion.Control = .{};
    const outcome = io_deletion.runChild(std.testing.io, &.{"rediwm-no-such-program"}, &control);
    try std.testing.expectEqual(io_deletion.ChildOutcome.missing, outcome);
}
