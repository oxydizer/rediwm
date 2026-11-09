//! Activation environment for a session bus without a systemd user manager.
//! There is no shared-manager journal: the bus belongs to this console session.
const std = @import("std");
const publication = @import("publication.zig");

pub fn Publication(comptime Bus: type) type {
    return struct {
        bus: *Bus,
        allocator: std.mem.Allocator,
        session: []const u8,
        published: bool = false,
        const Self = @This();
        pub fn init(allocator: std.mem.Allocator, bus: *Bus, _: []const u8, session: []const u8) !Self {
            return .{ .bus = bus, .allocator = allocator, .session = session };
        }
        pub fn acquire(self: *Self) !void {
            if (self.bus.owns_user_bus) return;
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            if (try self.bus.conflict(arena.allocator(), self.session) != null) return error.GraphicalSessionConflict;
        }
        pub fn deinit(self: *Self) void {
            self.restore() catch {};
        }
        pub fn publish(self: *Self, values: []const publication.Pair) !void {
            for (values) |pair| {
                if (std.mem.eql(u8, pair.key, publication.owner_key)) return error.InvalidActivationEnvironment;
                var allowed = false;
                for (publication.allowlist) |key| if (std.mem.eql(u8, key, pair.key)) {
                    allowed = true;
                    break;
                };
                if (!allowed) return error.InvalidActivationEnvironment;
            }
            try self.acquire();
            self.published = true;
            try self.bus.activation(values);
        }
        pub fn restore(self: *Self) !void {
            if (!self.published) return;
            // A borrowed bus may now belong to another desktop. It has no
            // readable activation environment with which to verify ownership.
            if (!self.bus.owns_user_bus) {
                self.published = false;
                return;
            }
            // Do not activate an app onto a dead display between compositor runs.
            try self.bus.activation(&.{
                .{ .key = "WAYLAND_DISPLAY", .value = "" },
                .{ .key = "DISPLAY", .value = "" },
                .{ .key = "REDIWM_SOCKET", .value = "" },
            });
            self.published = false;
        }
    };
}

test {
    _ = @import("private_publication_tests.zig");
}
