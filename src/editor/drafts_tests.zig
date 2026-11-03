const std = @import("std");
const c = @import("../files/c.zig").api;
const drafts = @import("drafts.zig");
const a = std.heap.c_allocator;

const Scratch = struct {
    root: [:0]u8,
    fn make() !Scratch {
        var template = "/tmp/rediwm-drafts-XXXXXX".*;
        _ = c.mkdtemp(&template) orelse return error.MkdtempFailed;
        return .{ .root = try a.dupeSentinel(u8, std.mem.sliceTo(&template, 0), 0) };
    }
    fn path(s: Scratch) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/state/drafts", .{s.root}, 0);
    }
    fn remove(s: Scratch) void {
        std.Io.Dir.cwd().deleteTree(std.testing.io, s.root) catch {};
        a.free(s.root);
    }
};

fn item(name: u64, path: ?[]const u8, text: ?[]const u8) !drafts.Item {
    return .{
        .entry = .{ .name = name, .path = if (path) |p| try a.dupe(u8, p) else null, .cursor = 3, .anchor = 1, .top = 0 },
        .tab_id = name,
        .revision = 1,
        .text = if (text) |t| try a.dupe(u8, t) else null,
    };
}

test "drafts survive a write and load, and unreferenced files are swept" {
    const scratch = try Scratch.make();
    defer scratch.remove();
    var store = try drafts.Store.open(std.testing.io, try scratch.path());
    defer store.deinit();

    var items = try a.alloc(drafts.Item, 2);
    items[0] = try item(4, null, "typed, never saved\nsecond line é");
    items[1] = try item(7, "/home/user/notes.txt", "edited file");
    const first: drafts.Snapshot = .{ .selected = 1, .next = 8, .items = items };
    defer first.deinit();
    try store.write(first);
    // A stale draft and a half-written file from a crash are cleared by the next write.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/state/drafts/99.txt", .{scratch.root}), .data = "stale" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/state/drafts/7.txt.tmp", .{scratch.root}), .data = "torn" });

    // Tab 4 is unchanged (no text to write); tab 7 gets new text.
    var again = try a.alloc(drafts.Item, 2);
    again[0] = try item(4, null, null);
    again[1] = try item(7, "/home/user/notes.txt", "edited file, again");
    const second: drafts.Snapshot = .{ .selected = 0, .next = 8, .items = again };
    defer second.deinit();
    try store.write(second);

    var loaded = store.load();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.tabs.items.len);
    try std.testing.expectEqual(@as(u64, 8), loaded.next);
    try std.testing.expectEqual(@as(usize, 0), loaded.selected);
    try std.testing.expectEqualStrings("typed, never saved\nsecond line é", loaded.tabs.items[0].text.items);
    try std.testing.expect(loaded.tabs.items[0].path == null);
    try std.testing.expectEqualStrings("/home/user/notes.txt", loaded.tabs.items[1].path.?);
    try std.testing.expectEqualStrings("edited file, again", loaded.tabs.items[1].text.items);
    try std.testing.expectEqual(@as(usize, 3), loaded.tabs.items[0].cursor);

    var stale: c.struct_stat = undefined;
    const stale_path = try std.fmt.allocPrintSentinel(a, "{s}/state/drafts/99.txt", .{scratch.root}, 0);
    defer a.free(stale_path);
    try std.testing.expect(c.stat(stale_path, &stale) != 0);
    const torn_path = try std.fmt.allocPrintSentinel(a, "{s}/state/drafts/7.txt.tmp", .{scratch.root}, 0);
    defer a.free(torn_path);
    try std.testing.expect(c.stat(torn_path, &stale) != 0);
}

test "a draft that cannot be read or is not text is left out, not fatal" {
    const scratch = try Scratch.make();
    defer scratch.remove();
    var store = try drafts.Store.open(std.testing.io, try scratch.path());
    defer store.deinit();
    var items = try a.alloc(drafts.Item, 3);
    items[0] = try item(1, null, "good");
    items[1] = try item(2, null, "will be binary");
    items[2] = try item(3, null, "will vanish");
    const snapshot: drafts.Snapshot = .{ .selected = 2, .next = 4, .items = items };
    defer snapshot.deinit();
    try store.write(snapshot);
    const dir = try std.fmt.allocPrint(a, "{s}/state/drafts", .{scratch.root});
    defer a.free(dir);
    const binary = try std.fmt.allocPrint(a, "{s}/2.txt", .{dir});
    defer a.free(binary);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = binary, .data = "bin\x00ary" });
    const vanished = try std.fmt.allocPrint(a, "{s}/3.txt", .{dir});
    defer a.free(vanished);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, vanished);

    var loaded = store.load();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.tabs.items.len);
    try std.testing.expectEqualStrings("good", loaded.tabs.items[0].text.items);
    // The selected tab was dropped: fall back to the first.
    try std.testing.expectEqual(@as(usize, 0), loaded.selected);
}

test "a second editor cannot take the drafts directory" {
    const scratch = try Scratch.make();
    defer scratch.remove();
    var store = try drafts.Store.open(std.testing.io, try scratch.path());
    defer store.deinit();
    try std.testing.expectError(error.Busy, drafts.Store.open(std.testing.io, try scratch.path()));
}
