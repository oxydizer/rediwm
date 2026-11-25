//! Automatic output placement. Outputs without a saved position sit side by
//! side, right of the saved ones, in the order each was first connected this
//! session. wlroots' own (`wlr_output_layout_add_auto`) orders them by when they
//! were last added, so a monitor that dropped out (on a wake from sleep, say)
//! came back on the far right: the screens swapped and the windows of both
//! ended up on one. Here a returning output takes its old place, and windows
//! ride along with the outputs that close its gap or move aside for it. Every
//! output enters the wlroots layout at a fixed position, so wlroots never moves
//! one by itself.

const std = @import("std");
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const gpa = @import("../main.zig").gpa;
const log = std.log.scoped(.output);

/// Output names in the order they were first connected this session.
pub const Order = struct {
    const capacity = 16;
    const name_max = 64;

    names: [capacity][name_max]u8 = undefined,
    lens: [capacity]u8 = @splat(0),
    count: usize = 0,

    pub fn rank(self: *const Order, name: []const u8) ?usize {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.names[i][0..self.lens[i]], name)) return i;
        }
        return null;
    }

    /// Remembers `name` after those seen before. A full list first forgets
    /// its oldest name that `connected.has` denies, else its oldest.
    pub fn note(self: *Order, name: []const u8, connected: anytype) void {
        if (name.len == 0 or name.len > name_max or self.rank(name) != null) return;
        if (self.count == capacity) {
            var drop: usize = 0;
            for (0..self.count) |i| {
                if (!connected.has(self.names[i][0..self.lens[i]])) {
                    drop = i;
                    break;
                }
            }
            for (drop..self.count - 1) |i| {
                self.names[i] = self.names[i + 1];
                self.lens[i] = self.lens[i + 1];
            }
            self.count -= 1;
        }
        @memcpy(self.names[self.count][0..name.len], name);
        self.lens[self.count] = @intCast(name.len);
        self.count += 1;
    }
};

const Connected = struct {
    server: *Server,

    pub fn has(self: Connected, name: []const u8) bool {
        var it = self.server.output_layout.outputs.iterator(.forward);
        while (it.next()) |entry| {
            if (std.mem.eql(u8, std.mem.span(entry.output.name), name)) return true;
        }
        return false;
    }
};

/// Gives `out` its place in the session's order; call before it joins the layout.
pub fn note(server: *Server, out: *wlr.Output) void {
    server.auto_order.note(std.mem.span(out.name), Connected{ .server = server });
}

/// The position `out`'s saved configuration pins, if any.
pub fn savedPosition(server: *Server, out: *wlr.Output) ?[2]i32 {
    const config = Output.configured(server, out) orelse return null;
    if (config.x == null and config.y == null) return null;
    return .{ config.x orelse 0, config.y orelse 0 };
}

/// Where a new output waits until `arrange` gives it its place: right of
/// everything, so it covers no output's windows meanwhile.
pub fn provisionalPosition(server: *Server) [2]i32 {
    var all: wlr.Box = undefined;
    server.output_layout.getBox(null, &all);
    return .{ all.x +| all.width, all.y };
}

fn width(out: *wlr.Output) i32 {
    var w: c_int = 0;
    var h: c_int = 0;
    out.effectiveResolution(&w, &h);
    return w;
}

fn layoutPosition(server: *Server, out: *wlr.Output) ?[2]i32 {
    var it = server.output_layout.outputs.iterator(.forward);
    while (it.next()) |entry| {
        if (entry.output == out) return .{ entry.x, entry.y };
    }
    return null;
}

const max_outputs = 32;

/// Places every output without a saved position: side by side from the right
/// edge of the rightmost saved one (at its top; else from 0,0), in the
/// session's order. An unplugged output leaves no gap; a disabled or blanked
/// one keeps its place, as in wlroots.
pub fn arrange(server: *Server) void {
    const Entry = wlr.OutputLayout.Output;
    var autos: [max_outputs]*Entry = undefined;
    var count: usize = 0;
    var right: ?i32 = null;
    var top: i32 = 0;
    var it = server.output_layout.outputs.iterator(.forward);
    while (it.next()) |entry| {
        if (savedPosition(server, entry.output) == null) {
            if (count < autos.len) {
                autos[count] = entry;
                count += 1;
            }
            continue;
        }
        const edge = entry.x +| width(entry.output);
        if (right == null or edge > right.?) {
            right = edge;
            top = entry.y;
        }
    }
    const ByOrder = struct {
        fn lessThan(order: *const Order, a: *Entry, b: *Entry) bool {
            const max = std.math.maxInt(usize);
            return (order.rank(std.mem.span(a.output.name)) orelse max) < (order.rank(std.mem.span(b.output.name)) orelse max);
        }
    };
    // Stable: names the order can't hold keep their layout order, last.
    std.sort.insertion(*Entry, autos[0..count], &server.auto_order, ByOrder.lessThan);
    var x = right orelse 0;
    for (autos[0..count]) |entry| {
        defer x +|= width(entry.output);
        if (entry.x == x and entry.y == top) continue;
        // Already in the layout, so this only moves it.
        _ = server.output_layout.add(entry.output, x, top) catch |err| {
            log.warn("output {s}: could not move to {d},{d}: {}", .{ entry.output.name, x, top, err });
            continue;
        };
        // A blanked output's box is not refreshed until it wakes.
        if (Output.fromWlr(entry.output)) |output| {
            output.cached_box.x = x;
            output.cached_box.y = top;
        }
    }
}

/// The windows shown on each output, noted before outputs move so that
/// `finish` can move each by as much as its output moved. In workspace mode
/// `workspaces.syncOutputs` refits each workspace on its output instead.
pub const Carry = struct {
    const Entry = struct {
        toplevel: *Toplevel,
        output: *wlr.Output,
        from: [2]i32,
    };

    entries: std.ArrayList(Entry) = .empty,

    pub fn begin(server: *Server) Carry {
        var carry: Carry = .{};
        if (server.world.workspaces.active) return carry;
        var tops = server.world.toplevels.iterator(.forward);
        while (tops.next()) |toplevel| {
            if (!toplevel.in_world) continue;
            const center = toplevel.frameWorld(@floatFromInt(@divTrunc(toplevel.chrome_width, 2)), @floatFromInt(@divTrunc(toplevel.chrome_height, 2)));
            const layout_center = server.world.toLayout(center.x, center.y);
            // Only windows shown on an output; canvas beyond them stays put.
            const output = Output.atLayout(server, layout_center.x, layout_center.y) orelse continue;
            const from = layoutPosition(server, output.wlr_output) orelse continue;
            carry.entries.append(gpa, .{ .toplevel = toplevel, .output = output.wlr_output, .from = from }) catch {
                log.warn("could not note every window to move with its output", .{});
                break;
            };
        }
        return carry;
    }

    /// Call while the noted windows and outputs are all still alive.
    pub fn finish(self: *Carry, server: *Server) void {
        var moved = false;
        for (self.entries.items) |entry| {
            if (!entry.toplevel.in_world) continue;
            const now = layoutPosition(server, entry.output) orelse continue;
            const dx = now[0] - entry.from[0];
            const dy = now[1] - entry.from[1];
            if (dx == 0 and dy == 0) continue;
            shift(server, entry.toplevel, dx, dy);
            moved = true;
        }
        if (moved) server.scheduleFrames();
        self.entries.clearRetainingCapacity();
    }

    pub fn deinit(self: *Carry) void {
        self.entries.deinit(gpa);
    }
};

/// Moves a window `dx`, `dy` layout pixels with its output, keeping its size,
/// its maximized, fullscreen or tiled geometry and any wait for an output that
/// went away. A glide in progress ends where it was going, moved along.
fn shift(server: *Server, toplevel: *Toplevel, dx: i32, dy: i32) void {
    const waiting = toplevel.hasOutputDisconnect();
    inline for (.{ "fullscreen_target", "maximize_target", "tile_target", "auto_target" }) |field| {
        if (@field(toplevel, field)) |*target| {
            const p = shifted(server, target.x, target.y, dx, dy);
            target.x = p[0];
            target.y = p[1];
        }
    }
    const p = shifted(server, toplevel.x, toplevel.y, dx, dy);
    toplevel.setPosition(p[0], p[1]);
    if (waiting) toplevel.markOutputDisconnectPosition();
}

fn shifted(server: *Server, x: i32, y: i32, dx: i32, dy: i32) [2]i32 {
    const layout = server.world.toLayout(@floatFromInt(x), @floatFromInt(y));
    const world = server.world.toWorld(layout.x + @as(f64, @floatFromInt(dx)), layout.y + @as(f64, @floatFromInt(dy)));
    return .{ @intFromFloat(@round(world.x)), @intFromFloat(@round(world.y)) };
}

test "order keeps first-connected places and forgets an absent name when full" {
    const None = struct {
        connected: []const []const u8,
        pub fn has(self: @This(), name: []const u8) bool {
            for (self.connected) |c| if (std.mem.eql(u8, c, name)) return true;
            return false;
        }
    };
    var order: Order = .{};
    order.note("DP-1", None{ .connected = &.{} });
    order.note("DP-2", None{ .connected = &.{} });
    order.note("DP-1", None{ .connected = &.{} });
    try std.testing.expectEqual(@as(?usize, 0), order.rank("DP-1"));
    try std.testing.expectEqual(@as(?usize, 1), order.rank("DP-2"));
    var name: [8]u8 = undefined;
    for (2..Order.capacity) |i| order.note(std.fmt.bufPrint(&name, "X-{d}", .{i}) catch unreachable, None{ .connected = &.{} });
    // Full: DP-1 is connected, so DP-2 (the oldest absent name) goes.
    order.note("HDMI-A-1", None{ .connected = &.{"DP-1"} });
    try std.testing.expectEqual(@as(?usize, 0), order.rank("DP-1"));
    try std.testing.expectEqual(@as(?usize, null), order.rank("DP-2"));
    try std.testing.expectEqual(@as(?usize, Order.capacity - 1), order.rank("HDMI-A-1"));
}
