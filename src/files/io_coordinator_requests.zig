//! Requests on the coordinator: most go to a service task; those about
//! Manager state are answered here, from memory (architecture §8, §14).
//! Methods of `Coordinator`, aliased there.
const std = @import("std");
const io_service = @import("io_service.zig");
const io_requests = @import("io_requests.zig");
const Coordinator = @import("io_coordinator.zig").Coordinator;

/// Moves a request to a service task. A request that cannot run gives
/// back its reply slot, so the window is never left one short.
pub fn handleRequest(self: *Coordinator, routed: *io_service.RoutedCommand) void {
    const payload = routed.command.payload orelse
        return self.service.cancelReplyReservation(routed.window_id);
    if (payload.data != .request) return self.service.cancelReplyReservation(routed.window_id);
    if (io_requests.answeredByCoordinator(&payload.data.request.request))
        return answerRequest(self, routed.window_id, routed.command.submit_tag, &payload.data.request.request);
    routed.command.payload = null;
    self.submitTask(.{ .request = .{ .window_id = routed.window_id, .tag = routed.command.submit_tag, .payload = payload } });
}

/// Answers a request about Manager state from memory, on this thread.
fn answerRequest(self: *Coordinator, window_id: io_service.WindowId, tag: u64, request: *const io_requests.Request) void {
    const reply = self.allocator.create(io_requests.Reply) catch return self.service.cancelReplyReservation(window_id);
    reply.* = .{ .allocator = self.allocator, .tag = tag, .data = switch (request.*) {
        .conflict_details => |r| .{ .conflict = conflictDetails(self, r.conflict_id) },
        else => unreachable,
    } };
    self.service.deliverReply(window_id, reply);
}

fn conflictDetails(self: *Coordinator, conflict_id: u64) ?io_requests.ConflictDetails {
    const conflict = self.runtime.manager.nextConflict() orelse return null;
    if (conflict.id != conflict_id) return null;
    return .{
        .conflict_id = conflict.id,
        .job_id = conflict.job_id,
        .destination_path = self.allocator.dupe(u8, conflict.destination_path) catch return null,
        .can_merge = conflict.source_kind == .directory and conflict.destination_kind == .directory,
    };
}

