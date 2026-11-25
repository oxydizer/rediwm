//! Copy and move from a window through a running I/O service: what lands on
//! disk, what the window says, and what happens to a cut clipboard. How the
//! service plans a transfer is tested in io_coordinator_transfer_tests.zig.
const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const io_service = @import("io_service.zig");
const io_coordinator = @import("io_coordinator.zig");
const ops = @import("ops.zig");
const support = @import("io_coordinator_test_support.zig");
const testApp = @import("app_tests.zig").testApp;
const worker_mod = @import("worker.zig");

const allocator = std.testing.allocator;

/// An App joined to a running service, as `Client.create` joins one.
pub const ServiceApp = struct {
    service: io_service.Service = .{},
    coordinator: io_coordinator.Coordinator = undefined,
    app: App = undefined,
    worker: *worker_mod.Worker = undefined,

    pub fn start(self: *ServiceApp) !void {
        try self.service.init();
        try self.coordinator.init(allocator, std.testing.io, &self.service);
        self.app = try testApp();
        // Refreshing the listing needs the window's listing worker.
        self.worker = try worker_mod.Worker.init(allocator, std.testing.io, std.process.Environ.empty, "/");
        self.app.worker = self.worker;
        self.app.service.handle = try self.service.registerWindow();
    }

    pub fn stop(self: *ServiceApp) void {
        var handle = self.app.service.handle.?;
        self.app.deinit();
        self.worker.deinit();
        self.coordinator.deinit();
        handle.close();
        self.service.deinit();
    }

    /// Steps the window as the event loop would until `done` holds.
    pub fn until(self: *ServiceApp, done: *const fn (*App) bool) !void {
        for (0..2000) |_| {
            if (support.waitReadable(self.service.updateWakeFd(), 5)) {
                _ = self.service.drainUpdateWake();
                self.app.serviceUpdated();
            }
            self.app.stepService();
            if (done(&self.app)) return;
        }
        return error.Timeout;
    }
};

fn idle(app: *App) bool {
    return app.service.transfers.len == 0;
}

fn conflictShown(app: *App) bool {
    return if (app.dialog) |dialog| dialog.kind == .conflict else false;
}

fn notice(app: *const App) []const u8 {
    return app.status_notice orelse "";
}

test "a copy runs as a service job and the window reports its end" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const a = try support.join(allocator, temp, "a.txt");
    defer allocator.free(a);
    const folder = try support.join(allocator, temp, "folder");
    defer allocator.free(folder);
    const inner = try support.join(allocator, temp, "folder/inner.txt");
    defer allocator.free(inner);
    const destination = try support.join(allocator, temp, "destination");
    defer allocator.free(destination);
    try support.writeFile(a, "alpha");
    try support.makeDirectory(folder);
    try support.writeFile(inner, "inside");
    try support.makeDirectory(destination);

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    try std.testing.expect(s.app.executeTransfer(.copy, &.{ a, folder }, destination, false));
    try std.testing.expectEqual(@as(usize, 1), s.app.service.transfers.len);
    try s.until(idle);
    try std.testing.expectEqualStrings("Items copied", notice(&s.app));

    const copied = try support.join(allocator, destination, "folder/inner.txt");
    defer allocator.free(copied);
    const contents = try support.readFile(allocator, copied);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("inside", contents);
    try std.testing.expect(support.pathExists(a));
}

test "a cut and paste moves, and empties the cut clipboard" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const a = try support.join(allocator, temp, "a.txt");
    defer allocator.free(a);
    const destination = try support.join(allocator, temp, "destination");
    defer allocator.free(destination);
    try support.writeFile(a, "alpha");
    try support.makeDirectory(destination);

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    try s.app.clipboard_paths.append(allocator, try allocator.dupe(u8, a));
    s.app.clipboard_cut = true;
    try s.app.history.navigate(destination);
    s.app.executePasteLocal();
    try s.until(idle);
    try std.testing.expectEqualStrings("Item moved", notice(&s.app));
    try std.testing.expect(!support.pathExists(a));
    const moved = try support.join(allocator, destination, "a.txt");
    defer allocator.free(moved);
    try std.testing.expect(support.pathExists(moved));
    try std.testing.expectEqual(@as(usize, 0), s.app.clipboard_paths.items.len);
    try std.testing.expect(!s.app.clipboard_cut);
}

test "a refused transfer says why" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const folder = try support.join(allocator, temp, "folder");
    defer allocator.free(folder);
    const inside = try support.join(allocator, temp, "folder/inside");
    defer allocator.free(inside);
    try support.makeDirectory(folder);
    try support.makeDirectory(inside);

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    try std.testing.expect(s.app.executeTransfer(.copy, &.{folder}, inside, false));
    try s.until(idle);
    try std.testing.expectEqualStrings("Cannot drop a folder into itself", notice(&s.app));
}

test "a conflict opens the dialog, and Skip answers it through the service" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const a = try support.join(allocator, temp, "a.txt");
    defer allocator.free(a);
    const destination = try support.join(allocator, temp, "destination");
    defer allocator.free(destination);
    const taken = try support.join(allocator, temp, "destination/a.txt");
    defer allocator.free(taken);
    try support.writeFile(a, "new");
    try support.makeDirectory(destination);
    try support.writeFile(taken, "old");

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    try std.testing.expect(s.app.executeTransfer(.copy, &.{a}, destination, false));
    try s.until(conflictShown);
    try std.testing.expectEqualStrings("a.txt", s.app.dialog.?.conflict_name.?);
    try std.testing.expect(!s.app.managerConflictCanMerge());
    s.app.resolveConflictDialog(.skip);
    try std.testing.expect(s.app.dialog == null);
    try s.until(idle);
    const kept = try support.readFile(allocator, taken);
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("old", kept);
}

test "Rename in the conflict dialog keeps both" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const a = try support.join(allocator, temp, "a.txt");
    defer allocator.free(a);
    const destination = try support.join(allocator, temp, "destination");
    defer allocator.free(destination);
    const taken = try support.join(allocator, temp, "destination/a.txt");
    defer allocator.free(taken);
    try support.writeFile(a, "new");
    try support.makeDirectory(destination);
    try support.writeFile(taken, "old");

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    try std.testing.expect(s.app.executeTransfer(.copy, &.{a}, destination, false));
    try s.until(conflictShown);
    s.app.resolveConflictDialog(.rename);
    try s.until(idle);
    var entries: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, destination, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |_| entries += 1;
    try std.testing.expectEqual(@as(usize, 2), entries);
    const kept = try support.readFile(allocator, taken);
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("old", kept);
}
