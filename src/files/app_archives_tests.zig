//! Archive jobs from a window through a running I/O service (stage S4):
//! extraction publishes into the folder, a member opens, and exported
//! members reach the clipboard, a drag or Open With on staging the window
//! holds until it gives it back.
const std = @import("std");
const c = @import("c.zig").api;
const App = @import("app.zig").App;
const ops = @import("ops.zig");
const support = @import("io_coordinator_test_support.zig");
const ServiceApp = @import("app_transfers_tests.zig").ServiceApp;

const allocator = std.testing.allocator;

/// A zip of `nested/payload.txt` ("payload"), plus `entry-N.txt` files at
/// the top level when `extra` is non-zero.
fn writeArchive(path: []const u8, extra: usize) !void {
    const api = @import("c_archive");
    const writer = api.archive_write_new() orelse return error.OutOfMemory;
    defer _ = api.archive_write_free(writer);
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_set_format_zip(writer));
    const zpath = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(zpath);
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_open_filename(writer, zpath));
    try addEntry(writer, "nested/payload.txt", "payload");
    for (0..extra) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(&name_buffer, "entry-{d}.txt", .{index}, 0);
        try addEntry(writer, name, "x");
    }
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_close(writer));
}

fn addEntry(writer: anytype, name: [:0]const u8, contents: []const u8) !void {
    const api = @import("c_archive");
    const entry = api.archive_entry_new() orelse return error.OutOfMemory;
    defer api.archive_entry_free(entry);
    api.archive_entry_set_pathname(entry, name);
    api.archive_entry_set_filetype(entry, c.S_IFREG);
    api.archive_entry_set_perm(entry, 0o644);
    api.archive_entry_set_size(entry, @intCast(contents.len));
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_header(writer, entry));
    try std.testing.expectEqual(@as(isize, @intCast(contents.len)), api.archive_write_data(writer, contents.ptr, contents.len));
}

fn idle(app: *App) bool {
    return app.service.archives.len == 0 and app.service.request_count == 0;
}

fn expectContents(path: []const u8, expected: []const u8) !void {
    const contents = try support.readFile(allocator, path);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings(expected, contents);
}

/// Shows the archive and selects its `name` entry.
fn showArchive(app: *App, archive: []const u8, name: []const u8, is_dir: bool) !void {
    try app.history.navigateLocation(archive, archive.len);
    const path = try std.fmt.allocPrint(app.items_arena.allocator(), "{s}/{s}", .{ archive, name });
    try app.items.append(allocator, .{
        .name = name,
        .path = path,
        .is_dir = is_dir,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 0,
        .mtime = 0,
        .icon_name = if (is_dir) "folder" else "text-x-generic",
        .selected = true,
    });
}

test "extracting an archive publishes every top-level entry and its folders" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const archive = try support.join(allocator, temp, "sample.zip");
    defer allocator.free(archive);
    const destination = try support.join(allocator, temp, "destination");
    defer allocator.free(destination);
    // More top-level entries than one listing batch.
    try writeArchive(archive, 300);
    try support.makeDirectory(destination);

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    s.app.startExtraction(archive, destination);
    try std.testing.expectEqualStrings("Extracting archive", s.app.status_notice.?);
    try s.until(idle);
    try std.testing.expectEqualStrings("Archive extracted", s.app.status_notice.?);

    const payload = try support.join(allocator, destination, "nested/payload.txt");
    defer allocator.free(payload);
    try expectContents(payload, "payload");
    const last = try support.join(allocator, destination, "entry-299.txt");
    defer allocator.free(last);
    try expectContents(last, "x");

    // Nothing but what the archive holds: the staging folder goes too, on a
    // service worker, just after the job's end.
    for (0..2000) |_| {
        if (try countEntries(destination) == 301) break;
        support.waitBriefly();
    } else return error.StagingLeftBehind;
}

/// How many entries `path` holds.
fn countEntries(path: []const u8) !usize {
    var names: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, path, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |_| names += 1;
    return names;
}

test "an extraction onto taken names asks, and Skip keeps what was there" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const archive = try support.join(allocator, temp, "sample.zip");
    defer allocator.free(archive);
    const destination = try support.join(allocator, temp, "destination");
    defer allocator.free(destination);
    const taken = try support.join(allocator, destination, "entry-0.txt");
    defer allocator.free(taken);
    try writeArchive(archive, 1);
    try support.makeDirectory(destination);
    try support.writeFile(taken, "mine");

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    s.app.startExtraction(archive, destination);
    try s.until(struct {
        fn shown(app: *App) bool {
            return if (app.dialog) |dialog| dialog.kind == .conflict else false;
        }
    }.shown);
    try std.testing.expectEqualStrings("entry-0.txt", s.app.dialog.?.conflict_name.?);
    s.app.resolveConflictDialog(.skip);
    try s.until(idle);
    try expectContents(taken, "mine");
}

test "an opened archive member keeps its staging until the window gives it back" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const archive = try support.join(allocator, temp, "sample.zip");
    defer allocator.free(archive);
    try writeArchive(archive, 0);

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    try s.app.history.navigateLocation(archive, archive.len);
    const member = try std.fmt.allocPrint(allocator, "{s}/nested/payload.txt", .{archive});
    defer allocator.free(member);
    s.app.openArchiveMember(member, true);
    try s.until(idle);
    try std.testing.expectEqualStrings("Archive member opened", s.app.status_notice.?);
    try std.testing.expectEqual(@as(usize, 1), s.app.archive_open_with_leases.items.len);
    const opened = s.app.editor_path orelse return error.MemberNotOpened;
    try expectContents(opened, "payload");

    // Given back, the service deletes it.
    const staging = try allocator.dupe(u8, s.app.archive_open_with_leases.items[0].path);
    defer allocator.free(staging);
    var lease = s.app.archive_open_with_leases.pop().?;
    lease.deinit();
    s.app.stepService();
    try support.waitForRemoval(staging);
}

test "copying archive members puts staged paths on the clipboard" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const archive = try support.join(allocator, temp, "sample.zip");
    defer allocator.free(archive);
    try writeArchive(archive, 0);

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    try showArchive(&s.app, archive, "nested", true);
    // The toolbar offers Copy like Ctrl+C and the menu; not Cut or Paste.
    try std.testing.expect(s.app.toolbarButtonEnabled(.copy));
    try std.testing.expect(!s.app.toolbarButtonEnabled(.cut));
    try std.testing.expect(!s.app.toolbarButtonEnabled(.paste));
    s.app.copySelected();
    try s.until(idle);
    try std.testing.expectEqualStrings("Archive members copied to clipboard", s.app.status_notice.?);
    try std.testing.expectEqual(@as(usize, 1), s.app.clipboard_paths.items.len);
    const staged = s.app.clipboard_paths.items[0];
    try std.testing.expect(!std.mem.startsWith(u8, staged, archive));
    const payload = try support.join(allocator, staged, "payload.txt");
    defer allocator.free(payload);
    try expectContents(payload, "payload");

    // Replacing the clipboard gives the staging back.
    const staging = try allocator.dupe(u8, s.app.clipboard_staging_lease.?.path);
    defer allocator.free(staging);
    s.app.clearClipboard();
    s.app.stepService();
    try support.waitForRemoval(staging);
}

test "a drag of archive members waits for their staging; Open With holds it" {
    var temp_buffer: [256]u8 = undefined;
    const temp = try support.makeTempDir(&temp_buffer);
    defer ops.deleteRecursive(allocator, temp) catch {};
    const archive = try support.join(allocator, temp, "sample.zip");
    defer allocator.free(archive);
    try writeArchive(archive, 0);

    var s: ServiceApp = .{};
    try s.start();
    defer s.stop();

    try showArchive(&s.app, archive, "nested/payload.txt", false);
    const tag = try s.app.startArchiveDragExport();
    try std.testing.expect(@import("app_archives.zig").pending(&s.app, tag));
    try s.until(idle);
    const drag = s.app.takeArchiveDragExport() orelse return error.DragNotReady;
    var owned = drag;
    try std.testing.expectEqual(@as(usize, 1), owned.paths.items.len);
    try expectContents(owned.paths.items[0], "payload");
    owned.deinit();

    try s.app.startArchiveOpenWith();
    try s.until(idle);
    try std.testing.expectEqual(@as(usize, 1), s.app.archive_open_with_leases.items.len);
    if (s.app.dialog) |dialog| try std.testing.expectEqual(@import("app_model.zig").DialogKind.open_with, dialog.kind);
}
