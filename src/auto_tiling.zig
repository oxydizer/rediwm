//! Event-driven bridge from workspace membership to pure split geometry.
const std = @import("std");
const wl = @import("wayland").server.wl;
const Server = @import("Server.zig");
const Top = @import("Toplevel.zig");
const layout = @import("auto_layout.zig");
const gpa = @import("main.zig").gpa;

pub const State = struct {
    workspace: u8,
    group: u64,
    constraints: @import("resize.zig").SizeConstraints,
    horizontal: i32,
    vertical: i32,
    excluded: bool,
    suspended: bool,
    hidden: bool,
};

pub fn isFloating(top: *const Top) bool {
    // The welcome chooser stays usable while switching into tiling mode.
    if (top.backend == .shell and top.backend.shell.welcome) return true;
    if (top.auto_float_override) |value| return value;
    if (top.auto_float) return true;
    if (top.live_rules.floating) |value| return value;
    for (top.server.config.compositor.floating_apps) |pattern| {
        if (@import("config").window_rules.matchGlob(pattern, top.appId())) return true;
    }
    return false;
}

fn state(top: *Top) State {
    const c = top.sizeConstraints();
    const fixed = c.min_width > 0 and c.min_height > 0 and c.min_width == c.max_width and c.min_height == c.max_height;
    return .{
        .workspace = top.workspace_id,
        .group = top.tab_group,
        .constraints = c,
        .horizontal = 2 * top.borderWidth(),
        // Fullscreen/maximize decoration suppression must not alter the saved tile.
        .vertical = top.titlebarHeight() + if (top.hasServerDecorations()) @import("chrome.zig").frameBorder() else @as(i32, 0),
        .excluded = isFloating(top) or top.tile != null or top.currentIdentity().dialog or fixed,
        .suspended = top.minimized or top.fullscreen or top.maximized,
        .hidden = top.tab_hidden,
    };
}

pub fn observe(top: *Top) void {
    if (!top.in_world or !top.server.world.workspaces.active) return;
    const next = state(top);
    if ((next.suspended or next.excluded or next.hidden) and top.server.input.tiling_grab != null and top.server.input.grabbed_toplevel == top)
        top.server.input.finishTilingGrab(false);
    if (top.auto_seen) |previous| if (std.meta.eql(next, previous)) return;
    if (top.auto_seen) |previous| {
        if (previous.group != next.group and previous.workspace == next.workspace and next.workspace != 0) {
            const old: layout.Key = if (previous.group != 0) .{ .id = previous.group, .group = true } else .{ .id = top.workspace_order };
            var shared = false;
            var it = top.server.world.toplevels.iterator(.forward);
            while (it.next()) |other| if (other != top and std.meta.eql(key(other), old)) {
                shared = true;
                break;
            };
            if (!shared) top.server.world.workspaces.tiler.trees[next.workspace - 1].rename(old, key(top));
        }
    }
    top.auto_seen = next;
    top.server.world.workspaces.tiler.schedule(top.server);
}

pub fn key(top: *Top) layout.Key {
    return if (top.tab_group != 0) .{ .id = top.tab_group, .group = true } else .{ .id = top.workspace_order };
}

/// Manual placement opts the whole tab group out until explicitly rejoined.
pub fn setFloating(top: *Top, floating: bool) void {
    if (!top.server.world.workspaces.active) return;
    var it = top.server.world.toplevels.iterator(.forward);
    while (it.next()) |member| {
        if (member != top and (top.tab_group == 0 or member.tab_group != top.tab_group)) continue;
        if (floating and member.auto_target != null and member.workspace_id != 0)
            member.auto_reinsert = top.server.world.workspaces.tiler.trees[member.workspace_id - 1].placement(key(member));
        member.auto_float = floating;
        member.auto_float_override = floating;
        if (floating) member.clearAutoTile(false);
        observe(member);
    }
    top.auto_float = floating;
    top.auto_float_override = floating;
    top.server.world.workspaces.tiler.schedule(top.server);
}

pub fn unmapped(top: *Top) void {
    if (!top.server.world.workspaces.active or top.workspace_id == 0) return;
    if (!top.auto_float) top.auto_reinsert = top.server.world.workspaces.tiler.trees[top.workspace_id - 1].placement(key(top));
    top.auto_seen = null;
}

pub const Manager = struct {
    trees: [@import("workspaces.zig").count]layout.Tree = @splat(.{}),
    idle: ?*wl.EventSource = null,
    applying: bool = false,
    /// The next flush places tiles at once instead of gliding: entering the
    /// mode, output changes and restored layouts are not user rearrangements.
    quiet: bool = false,

    pub fn deinit(self: *Manager) void {
        if (self.idle) |source| source.remove();
        self.idle = null;
        for (&self.trees) |*tree| tree.deinit(gpa);
    }
    pub fn schedule(self: *Manager, server: *Server) void {
        if (!server.world.workspaces.active or self.applying or self.idle != null) return;
        self.idle = server.wl_server.getEventLoop().addIdle(*Server, flush, server) catch null;
    }
    /// Resolve pending membership before a user operation takes a snapshot.
    pub fn flushNow(self: *Manager, server: *Server) void {
        if (self.applying or !server.world.workspaces.active) return;
        if (self.idle) |source| source.remove();
        flush(server);
    }
    fn flush(server: *Server) void {
        const self = &server.world.workspaces.tiler;
        self.idle = null;
        if (!server.world.workspaces.active) return;
        self.applying = true;
        defer self.applying = false;
        defer self.quiet = false;
        self.reflow(server) catch |err| {
            std.log.warn("automatic layout: {s}", .{@errorName(err)});
            return;
        };
        @import("tiling_grab.zig").refreshPreview(&server.input);
    }
    fn reflow(self: *Manager, server: *Server) !void {
        var tops: std.ArrayList(*Top) = .empty;
        defer tops.deinit(gpa);
        var it = server.world.toplevels.iterator(.forward);
        while (it.next()) |top| try tops.append(gpa, top);
        std.mem.sort(*Top, tops.items, {}, struct {
            fn less(_: void, a: *Top, b: *Top) bool {
                return a.workspace_order < b.workspace_order;
            }
        }.less);
        var members: std.ArrayList(layout.Member) = .empty;
        defer members.deinit(gpa);
        // A live split drag follows the pointer exactly.
        const dragging = if (server.input.tiling_grab) |grab| grab.kind == .resize else false;
        const animate = !self.quiet and !dragging;
        for (&self.trees, 0..) |*tree, index| {
            members.clearRetainingCapacity();
            const output = server.world.workspaces.slots[index].output;
            for (tops.items) |top| {
                if (top.workspace_id != index + 1) continue;
                const s = state(top);
                const k = key(top);
                var m: layout.Member = .{
                    .key = k,
                    .order = top.workspace_order,
                    .active = server.world.workspaces.slots[index].automatic and !s.excluded and !s.suspended and !s.hidden,
                    .min_width = @max(1, s.constraints.min_width) +| s.horizontal,
                    .min_height = @max(1, s.constraints.min_height) +| s.vertical,
                    .max_width = if (s.constraints.max_width > 0) s.constraints.max_width +| s.horizontal else 0,
                    .max_height = if (s.constraints.max_height > 0) s.constraints.max_height +| s.vertical else 0,
                    .anchor = anchorOf(top),
                };
                if (s.constraints.control_min_width > s.constraints.min_width and
                    (s.constraints.max_width == 0 or s.constraints.control_min_width <= s.constraints.max_width))
                    m.min_width = s.constraints.control_min_width +| s.horizontal;
                // A group occupies one leaf. Inactive tabs contribute constraints
                // so selecting a tab cannot shuffle neighbouring tiles.
                var found = false;
                for (members.items) |*existing| {
                    if (!std.meta.eql(existing.key, k)) continue;
                    existing.active = existing.active or m.active;
                    existing.order = @min(existing.order, m.order);
                    existing.min_width = @max(existing.min_width, m.min_width);
                    existing.min_height = @max(existing.min_height, m.min_height);
                    existing.max_width = boundedMin(existing.max_width, m.max_width);
                    existing.max_height = boundedMin(existing.max_height, m.max_height);
                    found = true;
                    break;
                }
                if (!found and !s.excluded) try members.append(gpa, m);
            }
            for (members.items) |*member| {
                // Conflicting limits in a tab group have no valid shared tile.
                // Keep the group floating instead of violating a client's max.
                if ((member.max_width > 0 and member.min_width > member.max_width) or
                    (member.max_height > 0 and member.min_height > member.max_height)) member.active = false;
            }
            const box = if (output) |out| out.usableBox() else @import("wlroots").Box{ .x = 0, .y = 0, .width = 0, .height = 0 };
            for (tops.items) |top| {
                if (top.workspace_id != index + 1 or tree.contains(key(top))) continue;
                const at = top.auto_reinsert orelse continue;
                if (!tree.contains(at.anchor)) continue;
                for (members.items) |m| if (std.meta.eql(m.key, key(top))) {
                    try tree.insertAt(gpa, m, at);
                    top.auto_reinsert = null;
                    break;
                };
            }
            try tree.sync(gpa, members.items, .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height }, server.config.compositor.windowGap());
            for (tops.items) |top| {
                if (top.workspace_id != index + 1) continue;
                const s = state(top);
                // Used by the sync above, or moot for a window that floats.
                top.auto_anchor = null;
                if (!s.excluded and !s.suspended and !s.hidden) {
                    if (tree.rectangle(key(top))) |rect| {
                        top.setAutoTile(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height }, animate and @import("workspaces.zig").visible(top));
                    } else top.clearAutoTile(true);
                } else if (s.excluded) top.clearAutoTile(true);
                top.auto_seen = state(top);
            }
        }
    }
};

/// The tile a window joining the tree splits: the window that had focus on
/// its workspace when it joined.
fn anchorOf(top: *Top) ?layout.Key {
    const other = top.server.findToplevelById(top.auto_anchor orelse return null) orelse return null;
    if (other == top or other.workspace_id != top.workspace_id) return null;
    return key(other);
}

fn boundedMin(a: i32, b: i32) i32 {
    return if (a == 0) b else if (b == 0) a else @min(a, b);
}

pub fn execute(server: *Server, target: ?*Top, action: @import("config").keybinds.TilingAction) void {
    if (!server.world.workspaces.active or server.locker != null or server.polkit_dialog != null) return;
    if (server.input.tiling_grab != null) server.input.finishTilingGrab(false);
    const manager = &server.world.workspaces.tiler;
    manager.flushNow(server);
    if (action == .toggle_workspace_tiling) {
        const id = if (target) |top| top.workspace_id else (server.getDefaultOutput() orelse return).workspace_id;
        if (id == 0) return;
        var transaction = @import("layout_undo.zig").Transaction.begin(server, &.{id});
        defer transaction.finish();
        const slot = &server.world.workspaces.slots[id - 1];
        slot.automatic = !slot.automatic;
        if (server.input.open_control_center) |cc| cc.refresh();
        manager.schedule(server);
        return;
    }
    const top = target orelse return;
    if (!top.in_world or top.workspace_id == 0 or top.minimized or top.fullscreen or top.maximized or top.tab_hidden) return;
    if (!@import("workspaces.zig").visible(top)) return;
    var transaction = @import("layout_undo.zig").Transaction.begin(server, &.{top.workspace_id});
    defer transaction.finish();
    const tree = &manager.trees[top.workspace_id - 1];
    if (action == .toggle_floating) {
        // Dialogs and fixed-size utilities are floating exceptions, not tiles.
        const c = top.sizeConstraints();
        if (top.currentIdentity().dialog or (c.min_width > 0 and c.min_height > 0 and c.min_width == c.max_width and c.min_height == c.max_height)) return;
        const floating = !isFloating(top) and top.tile == null;
        const saved = top.auto_restore;
        if (!floating) top.leaveLayout();
        setFloating(top, floating);
        if (floating) if (saved) |geometry| top.restoreGeometryNow(geometry);
    } else {
        if (top.auto_target == null or !server.world.workspaces.slots[top.workspace_id - 1].automatic) return;
        switch (action) {
            .toggle_split => {
                if (tree.splitFor(key(top), null) == null) return;
                tree.rotate(key(top));
            },
            .swap_left, .swap_right, .swap_up, .swap_down => {
                const direction: layout.Direction = switch (action) {
                    .swap_left => .left,
                    .swap_right => .right,
                    .swap_up => .up,
                    else => .down,
                };
                const other = tree.neighbor(key(top), direction) orelse return;
                tree.swap(key(top), other);
            },
            .resize_split_left, .resize_split_right, .resize_split_up, .resize_split_down => {
                const horizontal = action == .resize_split_left or action == .resize_split_right;
                const split = tree.splitFor(key(top), if (horizontal) .horizontal else .vertical) orelse return;
                const delta: f64 = if (action == .resize_split_left or action == .resize_split_up) -32 else 32;
                tree.setRatio(key(top), split.axis, split.ratio + delta / @as(f64, @floatFromInt(split.span)));
            },
            else => unreachable,
        }
    }
    manager.schedule(server);
}

pub const Drop = struct {
    workspace: u8,
    anchor: ?layout.Key = null,
    axis: layout.Axis = .horizontal,
    before: bool = false,
};
pub const PreparedDrop = struct { tree: ?layout.Tree, rect: @import("wlroots").Box };

pub fn dropAt(top: *Top, x: f64, y: f64) ?Drop {
    const server = top.server;
    const output = @import("Output.zig").atLayout(server, x, y) orelse return null;
    const id = output.workspace_id;
    if (id == 0) return null;
    if (!server.world.workspaces.slots[id - 1].automatic) return .{ .workspace = id };
    if (id == top.workspace_id) if (server.world.workspaces.tiler.trees[id - 1].rectangle(key(top))) |box| {
        if (x >= @as(f64, @floatFromInt(box.x)) and y >= @as(f64, @floatFromInt(box.y)) and
            x < @as(f64, @floatFromInt(box.x + box.width)) and y < @as(f64, @floatFromInt(box.y + box.height))) return null;
    };
    var nearest: ?*Top = null;
    var distance: f64 = std.math.inf(f64);
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |candidate| {
        if (candidate.workspace_id != id or candidate.tab_hidden or candidate.minimized or candidate.maximized or candidate.fullscreen or candidate.auto_target == null) continue;
        if (std.meta.eql(key(candidate), key(top))) continue;
        const box = server.world.workspaces.tiler.trees[id - 1].rectangle(key(candidate)) orelse continue;
        const dx = @max(0, @max(@as(f64, @floatFromInt(box.x)) - x, x - @as(f64, @floatFromInt(box.x + box.width))));
        const dy = @max(0, @max(@as(f64, @floatFromInt(box.y)) - y, y - @as(f64, @floatFromInt(box.y + box.height))));
        const d = dx * dx + dy * dy;
        if (d < distance or (d == distance and nearest != null and candidate.workspace_order < nearest.?.workspace_order)) {
            nearest = candidate;
            distance = d;
        }
    }
    const other = nearest orelse return if (id != top.workspace_id) .{ .workspace = id } else null;
    const box = server.world.workspaces.tiler.trees[id - 1].rectangle(key(other)).?;
    const dx = (x - @as(f64, @floatFromInt(box.x))) / @as(f64, @floatFromInt(@max(1, box.width))) - 0.5;
    const dy = (y - @as(f64, @floatFromInt(box.y))) / @as(f64, @floatFromInt(@max(1, box.height))) - 0.5;
    const horizontal = @abs(dx) >= @abs(dy);
    return .{ .workspace = id, .anchor = key(other), .axis = if (horizontal) .horizontal else .vertical, .before = if (horizontal) dx < 0 else dy < 0 };
}

pub fn prepareDrop(top: *Top, drop: Drop) !?PreparedDrop {
    const server = top.server;
    const slot = &server.world.workspaces.slots[drop.workspace - 1];
    const output = slot.output orelse return null;
    const usable = output.usableBox();
    if (!slot.automatic) {
        const saved = top.auto_restore orelse top.rememberGeometry();
        const width = saved.width + 2 * top.borderWidth();
        const height = saved.height + top.titlebarHeight() + top.footerHeight();
        return .{ .tree = null, .rect = .{
            .x = std.math.clamp(@as(i32, @intFromFloat(server.input.cursor.x)) - @divTrunc(width, 2), usable.x, usable.x + @max(0, usable.width - width)),
            .y = std.math.clamp(@as(i32, @intFromFloat(server.input.cursor.y)) - @divTrunc(top.titlebarHeight(), 2), usable.y, usable.y + @max(0, usable.height - height)),
            .width = width,
            .height = height,
        } };
    }
    const source = &server.world.workspaces.tiler.trees[top.workspace_id - 1];
    const value = source.getMember(key(top)) orelse return null;
    var copy = try server.world.workspaces.tiler.trees[drop.workspace - 1].clone(gpa);
    var keep = false;
    defer if (!keep) copy.deinit(gpa);
    copy.remove(gpa, value.key);
    if (drop.anchor) |anchor| {
        if (!copy.contains(anchor)) return null;
        try copy.insertAt(gpa, value, .{ .anchor = anchor, .axis = drop.axis, .before = drop.before });
    } else try copy.insert(gpa, value, null, .horizontal);
    try copy.arrangeExisting(gpa, .{ .x = usable.x, .y = usable.y, .width = usable.width, .height = usable.height }, server.config.compositor.windowGap());
    const rect = copy.rectangle(value.key) orelse return null;
    // Refuse an insertion that would evict any of the target's current tiles.
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |other| {
        if (other.workspace_id != drop.workspace or other.auto_target == null or other.minimized or other.fullscreen or other.maximized or other.tab_hidden) continue;
        if (copy.rectangle(key(other)) == null) return null;
    }
    keep = true;
    return .{ .tree = copy, .rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height } };
}

pub fn commitDrop(top: *Top, drop: Drop, prepared: *PreparedDrop) void {
    const server = top.server;
    var transaction = @import("layout_undo.zig").Transaction.begin(server, &.{ top.workspace_id, drop.workspace });
    defer transaction.finish();
    if (prepared.tree) |tree| {
        const target = &server.world.workspaces.tiler.trees[drop.workspace - 1];
        target.deinit(gpa);
        target.* = tree;
        prepared.tree = null;
    }
    if (drop.workspace != top.workspace_id) server.world.workspaces.moveTo(top, drop.workspace);
    server.world.workspaces.tiler.schedule(server);
}
