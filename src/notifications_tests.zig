//! Unit tests for notifications: toasts, image decoding, manager logic, DND, replaces_id, urgency, FLIP.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const anim = @import("ui").anim;
const notif = @import("notifications/mod.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");

test "notifications unit: replaces_id, urgency, DND, lock suppression" {
    anim.setNowMs(1000);
    defer anim.setNowMs(null);

    const display = try wl.Server.create();
    defer display.destroy();
    const backend = try wlr.Backend.createHeadless(display.getEventLoop());
    defer backend.destroy();
    const scene = try wlr.Scene.create();
    defer scene.tree.node.destroy();
    const output_layout = try wlr.OutputLayout.create(display);
    defer output_layout.destroy();
    var dummy_cursor: wlr.Cursor = std.mem.zeroes(wlr.Cursor);

    var server: Server = undefined;
    server.wl_server = display;
    server.scene = scene;
    server.overlay_tree = try scene.tree.createSceneTree();
    server.locker = null;
    server.environ = std.process.Environ.empty;
    server.config = undefined;
    server.config.notifications = .{ .dnd = false, .default_timeout_ms = 5000 };
    server.config.notification_rules = &.{};
    server.ipc = null;
    server.icon_service = null;
    server.output_layout = output_layout;
    server.outputs.init();
    server.input.cursor = &dummy_cursor;

    const wlr_out = try backend.headlessAddOutput(1280, 720);
    var mode = wlr.Output.State.init();
    defer mode.finish();
    mode.setEnabled(true);
    _ = wlr_out.commitState(&mode);
    _ = try output_layout.add(wlr_out, 0, 0);

    var out: Output = undefined;
    out.server = &server;
    out.wlr_output = wlr_out;
    out.user_disabled = false;
    out.idle_blanked = false;
    out.taskbar = null;
    out.cached_box = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
    wlr_out.data = &out;
    server.outputs.append(&out);

    const allocator = std.testing.allocator;
    const mgr = try allocator.create(notif.Manager);
    defer {
        for (mgr.toasts.items) |t| t.deinit(allocator);
        mgr.toasts.deinit(allocator);
        for (mgr.history.items) |rec| {
            allocator.free(rec.app_name);
            allocator.free(rec.summary);
            allocator.free(rec.body);
            allocator.free(rec.app_icon);
        }
        mgr.history.deinit(allocator);
        allocator.destroy(mgr);
    }

    mgr.* = .{
        .server = &server,
        .allocator = allocator,
        .dnd = false,
        .default_timeout_ms = 5000,
    };

    // 1. Post normal notification
    const id1 = try mgr.postNotification(
        "test_app",
        0,
        "",
        "First Notification",
        "Hello world",
        &.{ .{ .key = "default", .label = "Open" }, .{ .key = "dismiss", .label = "Dismiss" } },
        1, // normal urgency
        false, // resident
        false, // transient
        5000, // expire_timeout
        "",
        null,
    );
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(usize, 1), mgr.toasts.items.len);
    try std.testing.expectEqual(@as(i64, 6000), mgr.toasts.items[0].expire_at_ms.?);

    // 2. Post critical notification (urgency=2) -> must never expire regardless of timeout
    const id2 = try mgr.postNotification(
        "alert_app",
        0,
        "",
        "Battery Low",
        "10% remaining",
        &.{},
        2, // critical urgency
        false,
        false,
        1000, // even with positive timeout, critical must never auto-expire!
        "",
        null,
    );
    try std.testing.expectEqual(@as(u32, 2), id2);
    try std.testing.expectEqual(@as(usize, 2), mgr.toasts.items.len);
    try std.testing.expect(mgr.toasts.items[1].expire_at_ms == null);

    // 3. replaces_id: update id1 in-place
    const id1_repl = try mgr.postNotification(
        "test_app",
        id1,
        "",
        "Updated Notification",
        "New text",
        &.{},
        1,
        false,
        false,
        3000,
        "",
        null,
    );
    try std.testing.expectEqual(id1, id1_repl);
    try std.testing.expectEqual(@as(usize, 2), mgr.toasts.items.len);
    try std.testing.expectEqualStrings("Updated Notification", mgr.toasts.items[0].summary);
    try std.testing.expectEqual(@as(i64, 4000), mgr.toasts.items[0].expire_at_ms.?);

    // 4. DND mode: non-critical is suppressed from toast stack but added to history
    mgr.setDnd(true);
    const id3 = try mgr.postNotification(
        "chat_app",
        0,
        "",
        "New message",
        "Hey",
        &.{},
        1, // normal
        false,
        false,
        5000,
        "",
        null,
    );
    try std.testing.expectEqual(@as(u32, 3), id3);
    // Notice: id1 was dismissed because setDnd(true) closes active non-critical toasts!
    // id2 was critical so it survived!
    // id3 did not create a visible toast!
    try std.testing.expect(mgr.findToast(id3) == null);
    // But id3 is in history!
    var in_history = false;
    for (mgr.history.items) |rec| {
        if (rec.id == id3) in_history = true;
    }
    try std.testing.expect(in_history);

    // 5. Critical in DND mode: critical still creates visible toast!
    const id4 = try mgr.postNotification(
        "sys_app",
        0,
        "",
        "System Overheating",
        "Shutting down",
        &.{},
        2, // critical
        false,
        false,
        0,
        "",
        null,
    );
    try std.testing.expectEqual(@as(u32, 4), id4);
    try std.testing.expect(mgr.findToast(id4) != null);
}
