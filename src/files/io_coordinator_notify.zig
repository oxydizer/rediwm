//! Desktop notifications for jobs that end with no window open (stage S3b,
//! architecture §6): the user closed the last window and chose to keep the
//! jobs running, so nothing else would say how they ended. Methods of
//! `Coordinator`, aliased there.
//!
//! `notify-send` is spawned and never waited for: the coordinator collects
//! the child on a later pass (WNOHANG), so a slow notification daemon holds
//! nothing up. Without `notify-send`, it says so once in the log.
const std = @import("std");
const platform = @import("platform");
const i18n = @import("i18n");
const tr = i18n.tr;
const io_service = @import("io_service.zig");
const Coordinator = @import("io_coordinator.zig").Coordinator;

pub const max_children = 8;

pub const Notifier = struct {
    io: std.Io,
    children: [max_children]platform.child.Pid = undefined,
    count: usize = 0,
    missing: bool = false,

    /// Collects the notifications that are done.
    pub fn reap(self: *Notifier) void {
        var kept: usize = 0;
        for (self.children[0..self.count]) |pid| {
            if (platform.child.reap(pid) != null) continue;
            self.children[kept] = pid;
            kept += 1;
        }
        self.count = kept;
    }

    /// At shutdown: whatever is left is collected, killed if need be.
    pub fn deinit(self: *Notifier) void {
        self.reap();
        for (self.children[0..self.count]) |pid| platform.child.killAndReap(pid);
        self.count = 0;
    }

    fn send(self: *Notifier, title: []const u8, body: []const u8) void {
        self.reap();
        if (self.missing or self.count == max_children) return;
        var child = std.process.spawn(self.io, .{
            .argv = &.{ "notify-send", "--app-name=Files", "--icon=system-file-manager", title, body },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            if (err == error.FileNotFound) {
                self.missing = true;
                std.log.info("Files cannot notify: notify-send is not installed", .{});
            }
            return;
        };
        self.children[self.count] = child.id.?;
        child.id = null;
        self.count += 1;
    }
};

/// A job ended: with no window open, tell the desktop.
pub fn jobEnded(self: *Coordinator, record: io_service.JobRecord) void {
    // Tests end jobs headless all the time: never on a developer's desktop.
    if (@import("builtin").is_test) return;
    if (self.service.anyWindowOpen()) return;
    const title = switch (record.state) {
        .completed => switch (record.kind) {
            .copy => tr("Copy finished"),
            .move => tr("Move finished"),
            .extract => tr("Extraction finished"),
            .delete => tr("Items deleted"),
            .trash => tr("Items moved to Trash"),
            .empty_trash => tr("Trash emptied"),
            .other => tr("File operation finished"),
        },
        .completed_with_errors => tr("File operation finished with errors"),
        .cancelled => tr("File operation cancelled"),
        else => tr("File operation failed"),
    };
    var buf: [160]u8 = undefined;
    const body = if (record.kind == .empty_trash)
        ""
    else if (record.source_count > 1)
        i18n.fmt(&buf, tr("{name} and {count} more"), .{ .name = record.label(), .count = record.source_count - 1 }) catch record.label()
    else
        record.label();
    self.notifier.send(title, body);
}
