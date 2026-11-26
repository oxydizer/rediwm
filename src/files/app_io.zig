//! Priorities for service jobs from what the window shows: a hovered ghost
//! file is copied next, a hovered ghost folder is discovered and copied
//! sooner (architecture §14).
const std = @import("std");
const App = @import("app.zig").App;
const io_service = @import("io_service.zig");
const io_tree = @import("io_tree.zig");

/// A hovered ghost of a service job: ask the service to copy it next. The
/// preference outlasts the hover.
pub fn prioritizeTransferEntry(self: *App, entry_id: io_tree.EntryId) bool {
    for (self.items.items) |item| {
        if (item.transfer_job_id == 0 or item.transfer_entry_id != entry_id) continue;
        return sendPriority(self, .prioritize_entry, item.transfer_job_id, entry_id);
    }
    return false;
}

fn sendPriority(self: *App, kind: io_service.CommandKind, job_id: u64, entry_id: u64) bool {
    const link = &self.service;
    const handle = link.handle orelse return false;
    var command: io_service.Command = .{ .kind = kind, .job_id = job_id, .resource_id = entry_id };
    link.outbox.send(handle, &command) catch return false;
    return true;
}

/// A hovered ghost folder of a service job: ask the service to bring it
/// and what is under it sooner.
pub fn promoteDiscoverySubtreePath(self: *App, path: []const u8) void {
    for (self.items.items) |item| {
        if (item.transfer_job_id == 0 or !std.mem.eql(u8, item.path, path)) continue;
        if (item.transfer_entry_id) |entry_id| _ = sendPriority(self, .promote_subtree, item.transfer_job_id, entry_id);
        return;
    }
}
