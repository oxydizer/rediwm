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
    try support.writeFile(a, "newer");
    try support.makeDirectory(destination);
    try support.writeFile(taken, "old");

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    try std.testing.expect(s.app.executeTransfer(.copy, &.{a}, destination, false));
    try s.until(conflictShown);
    try std.testing.expectEqualStrings("a.txt", s.app.dialog.?.conflict_name.?);
    // It stays up across further ticks until answered.
    for (0..5) |_| s.app.stepService();
    try std.testing.expect(conflictShown(&s.app));
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
    try support.writeFile(a, "newer");
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

fn mergeOffered(app: *App) bool {
    return conflictShown(app) and app.managerConflictCanMerge();
}

test "copying a folder again into the same place asks, and Merge finishes it" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const folder = try support.join(allocator, temp, "Season");
    defer allocator.free(folder);
    const destination = try support.join(allocator, temp, "Backup");
    defer allocator.free(destination);
    try support.makeDirectory(folder);
    try support.makeDirectory(destination);
    var name_buf: [32]u8 = undefined;
    for (0..6) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "Season/e{d}.mkv", .{i});
        const path = try support.join(allocator, temp, name);
        defer allocator.free(path);
        try support.writeFile(path, "episode");
    }

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    // The first copy, as the earlier run left it, complete.
    try std.testing.expect(s.app.executeTransfer(.copy, &.{folder}, destination, false));
    try s.until(idle);

    // Again: the folder is there already.
    try s.app.history.navigate(destination);
    try std.testing.expect(s.app.executeTransfer(.copy, &.{folder}, destination, false));
    try s.until(mergeOffered);
    s.app.resolveConflictDialog(.merge);
    // Each file there is the one the first copy made (same size and time):
    // nothing more is asked and nothing is written again.
    try s.until(idle);
    try std.testing.expect(!conflictShown(&s.app));

    // One episode changed since: only that one is asked about.
    const changed = try support.join(allocator, temp, "Backup/Season/e3.mkv");
    defer allocator.free(changed);
    try ops.deleteRecursive(allocator, changed);
    try support.writeFile(changed, "an older cut");
    try std.testing.expect(s.app.executeTransfer(.copy, &.{folder}, destination, false));
    try s.until(mergeOffered);
    s.app.resolveConflictDialog(.merge);
    try s.until(conflictShown);
    try std.testing.expectEqualStrings("e3.mkv", s.app.dialog.?.conflict_name.?);
    s.app.resolveConflictDialog(.skip);
    try s.until(idle);
    try std.testing.expect(!conflictShown(&s.app));
}

test "Apply to all answers the job's later conflicts the same way" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const folder = try support.join(allocator, temp, "Season");
    defer allocator.free(folder);
    const destination = try support.join(allocator, temp, "Backup");
    defer allocator.free(destination);
    const copied = try support.join(allocator, temp, "Backup/Season");
    defer allocator.free(copied);
    try support.makeDirectory(folder);
    try support.makeDirectory(destination);
    try support.makeDirectory(copied);
    var name_buf: [32]u8 = undefined;
    for (0..4) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "Season/e{d}.mkv", .{i});
        const path = try support.join(allocator, temp, name);
        defer allocator.free(path);
        try support.writeFile(path, "episode");
        // Every one is there already, as another file.
        const there = try std.fmt.bufPrint(&name_buf, "Backup/Season/e{d}.mkv", .{i});
        const taken = try support.join(allocator, temp, there);
        defer allocator.free(taken);
        try support.writeFile(taken, "another cut");
    }

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    try std.testing.expect(s.app.executeTransfer(.copy, &.{folder}, destination, false));
    try s.until(mergeOffered);
    s.app.resolveConflictDialog(.merge);
    try s.until(conflictShown);
    s.app.toggleApplyAll();
    s.app.resolveConflictDialog(.skip);
    // The other three are skipped without asking.
    try s.until(idle);
    try std.testing.expect(!conflictShown(&s.app));
    for (0..4) |i| {
        const there = try std.fmt.bufPrint(&name_buf, "Backup/Season/e{d}.mkv", .{i});
        const taken = try support.join(allocator, temp, there);
        defer allocator.free(taken);
        const kept = try support.readFile(allocator, taken);
        defer allocator.free(kept);
        try std.testing.expectEqualStrings("another cut", kept);
    }
}

test "closing the last window while a job runs asks, and Cancel keeps it open" {
    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();
    s.app.service.jobs.apply(.{ .id = 3, .kind = .copy, .state = .running, .started_at_ms = 1 });

    s.app.requestClose();
    try std.testing.expectEqual(app_mod.DialogKind.quit_jobs, s.app.dialog.?.kind);
    try std.testing.expect(!s.app.closed);
    @import("app_quit.zig").choose(&s.app, .cancel);
    try std.testing.expect(s.app.dialog == null and !s.app.closed);

    s.app.requestClose();
    @import("app_quit.zig").choose(&s.app, .keep);
    try std.testing.expect(s.app.closed);
}

test "a window that is not the last closes without asking" {
    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();
    var other = try s.service.registerWindow();
    defer other.close();
    s.app.service.jobs.apply(.{ .id = 3, .kind = .copy, .state = .running, .started_at_ms = 1 });
    s.app.requestClose();
    try std.testing.expect(s.app.dialog == null and s.app.closed);
}

test "group completion refreshes and reveals the only selected row without navigating" {
    if (!@import("platform").fs.hasAtomicRenameNoReplace()) return error.SkipZigTest;
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const source = try support.join(allocator, temp, "photo.jpg");
    defer allocator.free(source);
    const destination = try support.join(allocator, temp, "zz-group");
    defer allocator.free(destination);
    try support.writeFile(source, "photo");
    for (0..12) |index| {
        const path = try std.fmt.allocPrint(allocator, "{s}/folder-{d}", .{ temp, index });
        defer allocator.free(path);
        try support.makeDirectory(path);
    }

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();
    s.app.environ = std.process.Environ.empty;
    s.app.list_view = true;
    s.app.h = 260;
    s.app.navigate(temp);
    try s.until(struct {
        fn ready(app: *App) bool {
            if (app.worker.takeSnapshot()) |snap| @import("app_listing.zig").applySnapshot(app, snap);
            return !app.loading;
        }
    }.ready);
    s.app.items.items[0].selected = true;
    s.app.items.items[1].selected = true;
    const navigation = s.app.navigation_count;
    const back_count = s.app.history.back_stack.items.len;
    const forward_count = s.app.history.forward_stack.items.len;
    try std.testing.expect(@import("app_transfers.zig").submitFolderMove(&s.app, &.{source}, destination, navigation));
    try s.until(struct {
        fn ready(app: *App) bool {
            if (app.worker.takeSnapshot()) |snap| @import("app_listing.zig").applySnapshot(app, snap);
            return app.service.transfers.len == 0 and !app.loading;
        }
    }.ready);

    try std.testing.expectEqualStrings(temp, s.app.history.current);
    try std.testing.expectEqual(navigation, s.app.navigation_count);
    try std.testing.expectEqual(back_count, s.app.history.back_stack.items.len);
    try std.testing.expectEqual(forward_count, s.app.history.forward_stack.items.len);
    const focused = s.app.focused_index orelse return error.NoFocusedFolder;
    try std.testing.expectEqualStrings(destination, s.app.items.items[focused].path);
    try std.testing.expectEqual(@as(?usize, focused), s.app.selection_anchor);
    for (s.app.items.items, 0..) |item, i| try std.testing.expectEqual(i == focused, item.selected);
    try std.testing.expect(s.app.scroll_y > 0);
}
