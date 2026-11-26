//! Runtime bridge for the config module's versioned workspace format.
const std = @import("std");
const Server = @import("Server.zig");
const Top = @import("Toplevel.zig");
const format = @import("config").workspace_layout;
const layout = @import("auto_layout.zig");
const scroll = @import("scroll_layout.zig");
const gpa = @import("main.zig").gpa;

fn geometry(g: Top.RestoreGeometry) format.Geometry {
    return .{ .x = g.x, .y = g.y, .width = g.width, .height = g.height };
}
fn liveGeometry(g: format.Geometry) Top.RestoreGeometry {
    return .{ .x = g.x, .y = g.y, .width = g.width, .height = g.height };
}
fn optional(g: ?Top.RestoreGeometry) ?format.Geometry {
    return if (g) |v| geometry(v) else null;
}
fn liveOptional(g: ?format.Geometry) ?Top.RestoreGeometry {
    return if (g) |v| liveGeometry(v) else null;
}
pub fn nodes(a: std.mem.Allocator, list: *std.ArrayList(format.Node), node: *const layout.Node) !void {
    try list.append(a, .{ .id = if (node.member) |m| m.key.id else null, .group = if (node.member) |m| m.key.group else false, .axis = @enumFromInt(@intFromEnum(node.axis)), .ratio = node.ratio });
    if (node.children) |c| {
        try nodes(a, list, c.a);
        try nodes(a, list, c.b);
    }
}
pub fn columns(a: std.mem.Allocator, strip: *const @import("scroll_layout.zig").Strip) ![]const format.Column {
    const result = try a.alloc(format.Column, strip.columns.items.len);
    for (strip.columns.items, result) |column, *out| {
        const members = try a.alloc(format.ColumnMember, column.cells.items.len);
        for (column.cells.items, members) |cell, *m| m.* = .{ .id = cell.member.key.id, .group = cell.member.key.group, .weight = cell.weight };
        out.* = .{ .width = column.width, .members = members };
    }
    return result;
}
pub fn save(server: *Server, path: []const u8, last_hash: ?*?u64) !void {
    if (server.greeter_mode or !server.world.workspaces.active) return;
    server.world.workspaces.tiler.flushNow(server);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var windows: std.ArrayList(format.Window) = .empty;
    var tops: std.ArrayList(*Top) = .empty;
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| if (top.workspace_id > 0 and top.backend != .placeholder) {
        try tops.append(a, top);
    };
    std.mem.sort(*Top, tops.items, {}, struct {
        fn less(_: void, x: *Top, y: *Top) bool {
            return x.workspace_order < y.workspace_order;
        }
    }.less);
    for (tops.items, 0..) |top, index| {
        var ordinal: usize = 0;
        for (tops.items[0..index]) |previous| if (std.mem.eql(u8, top.appId(), previous.appId()) and std.mem.eql(u8, top.backendName(), previous.backendName())) {
            ordinal += 1;
        };
        try windows.append(a, .{
            .app_id = top.appId(),
            .title = top.title(),
            .backend = top.backendName(),
            .instance = top.x11Instance() orelse "",
            .ordinal = ordinal,
            .workspace = top.workspace_id,
            .order = top.workspace_order,
            .group = top.tab_group,
            .tab_active = !top.tab_hidden,
            .floating = top.auto_float,
            .floating_override = top.auto_float_override,
            .reinsert = if (top.auto_reinsert) |at| .{ .anchor = at.anchor.id, .group = at.anchor.group, .axis = @enumFromInt(@intFromEnum(at.axis)), .ratio = at.ratio, .before = at.before } else null,
            .geometry = geometry(top.auto_restore orelse top.tile_restore orelse top.maximize_restore orelse top.fullscreen_restore orelse top.rememberGeometry()),
            .auto_restore = optional(top.auto_restore),
            .maximize_restore = optional(top.maximize_restore),
            .fullscreen_restore = optional(top.fullscreen_restore),
            .tile = if (top.tile) |tile| @tagName(tile) else null,
            .tile_restore = optional(top.tile_restore),
            .maximized = top.maximized,
            .fullscreen = top.fullscreen,
            .minimized = top.minimized,
            .canvas = if (top.canvas_state) |c| .{ .geometry = geometry(c.geometry), .zoom_index = c.zoom_index, .maximized = c.layout == .maximized, .tile = if (c.layout == .tiled) @tagName(c.layout.tiled) else null, .fullscreen = c.fullscreen, .maximize_restore = optional(c.maximize_restore), .tile_restore = optional(c.tile_restore), .fullscreen_restore = optional(c.fullscreen_restore) } else null,
        });
    }
    var workspaces: std.ArrayList(format.Workspace) = .empty;
    const manager = &server.world.workspaces;
    for (&manager.slots, 0..) |*slot, index| if (slot.exists) {
        var flat: std.ArrayList(format.Node) = .empty;
        if (manager.tiler.trees[index].root) |root| try nodes(a, &flat, root);
        const focused = if (slot.focus) |id| server.findToplevelById(id) else null;
        const output_name = if (slot.displaced) |*home| home.name() else if (slot.output) |out| std.mem.span(out.wlr_output.name) else "";
        try workspaces.append(a, .{
            .id = @intCast(index + 1),
            .layout = slot.layout,
            .nodes = flat.items,
            .output = output_name,
            .visible = if (slot.displaced) |home| home.shown else if (slot.output) |out| @import("workspaces.zig").nativeSelection(out) == index + 1 else false,
            .focus_order = if (focused) |top| top.workspace_order else null,
            .columns = try columns(a, &manager.tiler.strips[index]),
            .view = manager.tiler.strips[index].view,
        });
    };
    const saved: format.Saved = .{ .mode = if (manager.last_tiled == .scrolling) .scrolling else .workspaces, .windows = windows.items, .workspaces = workspaces.items, .camera = .{ .offset_x = manager.saved_camera.offset_x, .offset_y = manager.saved_camera.offset_y, .zoom_index = manager.saved_camera.zoom_index }, .bounds = .{ .max_x = manager.saved_bounds.max_x, .max_y = manager.saved_bounds.max_y, .origin_x = manager.saved_bounds.origin_x, .origin_y = manager.saved_bounds.origin_y, .width = manager.saved_bounds.width, .height = manager.saved_bounds.height } };
    const bytes = try format.stringify(a, saved);
    const hash = std.hash.Wyhash.hash(0, bytes);
    if (last_hash) |last| if (last.* == hash) return;
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(server.io, dir);
    const temporary = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    const file = try std.Io.Dir.cwd().createFile(server.io, temporary, .{ .permissions = .fromMode(0o600) });
    defer file.close(server.io);
    defer std.Io.Dir.cwd().deleteFile(server.io, temporary) catch {};
    try file.writeStreamingAll(server.io, bytes);
    try file.sync(server.io);
    try std.Io.Dir.rename(.cwd(), temporary, .cwd(), path, server.io);
    if (last_hash) |last| last.* = hash;
}

pub const Restore = struct {
    parsed: std.json.Parsed(format.Saved),
    matches: []?u64,
    finished: []bool,
    initialized: bool = false,
    restore_output_selection: bool = true,
    touched: [32]bool = @splat(false),
    pub fn load(server: *Server, path: []const u8) !Restore {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(server.io, path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        return fromBytes(bytes);
    }
    pub fn fromBytes(bytes: []const u8) !Restore {
        const parsed = try format.parse(gpa, bytes);
        errdefer parsed.deinit();
        const matches = try gpa.alloc(?u64, parsed.value.windows.len);
        errdefer gpa.free(matches);
        @memset(matches, null);
        const finished = try gpa.alloc(bool, matches.len);
        @memset(finished, false);
        return .{ .parsed = parsed, .matches = matches, .finished = finished };
    }
    pub fn deinit(self: *Restore) void {
        self.parsed.deinit();
        gpa.free(self.matches);
        gpa.free(self.finished);
    }
    pub fn pending(self: *const Restore) bool {
        for (self.finished) |done| if (!done) return true;
        return false;
    }
    pub fn prepare(self: *Restore, server: *Server) void {
        self.initialize(server);
    }
    fn initialize(self: *Restore, server: *Server) void {
        if (self.initialized or !server.world.workspaces.active or server.getDefaultOutput() == null) return;
        self.initialized = true;
        const manager = &server.world.workspaces;
        const saved = self.parsed.value;
        for (saved.windows) |window| manager.next_order = @max(manager.next_order, window.order + 1);
        var tops = server.world.toplevels.iterator(.forward);
        while (tops.next()) |top| {
            top.workspace_order = manager.next_order;
            manager.next_order += 1;
        }
        manager.saved_camera = .{ .offset_x = saved.camera.offset_x, .offset_y = saved.camera.offset_y, .zoom_index = @min(saved.camera.zoom_index, @import("camera.zig").zoom_levels.len - 1) };
        manager.saved_bounds = .{ .max_x = saved.bounds.max_x, .max_y = saved.bounds.max_y, .origin_x = saved.bounds.origin_x, .origin_y = saved.bounds.origin_y, .width = saved.bounds.width, .height = saved.bounds.height };
        var outputs = server.outputs.iterator(.forward);
        while (outputs.next()) |out| if (self.restore_output_selection) {
            out.workspace_id = 0;
        };
        for (saved.workspaces) |workspace| {
            if (self.touched[workspace.id - 1]) continue;
            const slot = &manager.slots[workspace.id - 1];
            slot.exists = true;
            slot.layout = workspace.layout;
            const named = server.findOutputByName(workspace.output);
            const home = if (named != null and named.?.isLogicallyEnabled()) named else null;
            const out = home orelse server.getDefaultOutput();
            slot.displaced = if (home == null) @import("workspaces.zig").Disconnected.init(workspace.output, workspace.visible) else null;
            slot.output = out;
            if (out) |output| {
                slot.box = output.usableBox();
                if (self.restore_output_selection and slot.displaced == null and workspace.visible and output.workspace_id == 0) output.workspace_id = workspace.id;
            }
        }
        manager.syncOutputs(server);
    }
    pub fn apply(self: *Restore, server: *Server, top: *Top) void {
        if (!server.world.workspaces.active or top.backend == .placeholder) return;
        self.initialize(server);
        if (!self.initialized) return;
        for (self.matches) |id| if (id == top.id) return;
        const windows = self.parsed.value.windows;
        var found: ?usize = null;
        // Prefer a title/instance match; fall back to the first unconsumed
        // occurrence in saved insertion order when an app changes its title.
        for (windows, 0..) |saved, index| {
            if (self.matches[index] != null or !std.mem.eql(u8, saved.app_id, top.appId()) or !std.mem.eql(u8, saved.backend, top.backendName())) continue;
            if (found == null) found = index;
            if (std.mem.eql(u8, saved.title, top.title()) and std.mem.eql(u8, saved.instance, top.x11Instance() orelse "")) {
                found = index;
                break;
            }
        }
        const index = found orelse {
            if (!top.in_world) {
                top.workspace_order = server.world.workspaces.next_order;
                server.world.workspaces.next_order += 1;
            }
            return;
        };
        const saved = windows[index];
        self.matches[index] = top.id;
        const applying = server.undo.applying;
        server.undo.applying = true;
        defer server.undo.applying = applying;
        top.workspace_id = saved.workspace;
        top.workspace_order = saved.order;
        // Runtime keys stay unique even when new windows mapped before restore.
        top.auto_seen = null;
        if (saved.canvas) |c| top.canvas_state = .{ .geometry = liveGeometry(c.geometry), .zoom_index = c.zoom_index, .layout = if (c.maximized) .maximized else if (c.tile) |tile| blk: {
            const t = std.meta.stringToEnum(@import("snap.zig").Tile, tile) orelse break :blk .floating;
            break :blk .{ .tiled = t };
        } else .floating, .fullscreen = c.fullscreen, .maximize_restore = liveOptional(c.maximize_restore), .tile_restore = liveOptional(c.tile_restore), .fullscreen_restore = liveOptional(c.fullscreen_restore) };
        top.clearAutoTile(false);
        if (top.fullscreen) top.setFullscreen(false);
        top.leaveLayout();
        top.restoreGeometryNow(liveGeometry(saved.geometry));
        top.auto_float = saved.floating;
        top.auto_float_override = saved.floating_override;
        top.auto_restore = liveOptional(saved.auto_restore);
        top.tile_restore = liveOptional(saved.tile_restore);
        if (@import("workspaces.zig").outputFor(top)) |output| {
            _ = top.moveFromUsableToOutput(output.usableBox(), output);
            if (saved.tile) |name| if (std.meta.stringToEnum(@import("snap.zig").Tile, name)) |tile| top.setTiledOn(output, tile);
            if (saved.maximized) top.setMaximizedOn(output);
            if (saved.fullscreen) top.setFullscreenOn(output);
        }
        top.maximize_restore = liveOptional(saved.maximize_restore);
        top.fullscreen_restore = liveOptional(saved.fullscreen_restore);
    }
    /// Late maps from the snapshot may arrive after the workspace's remembered
    /// window. Keep keyboard focus on that window when it is already present.
    pub fn takesMapFocus(self: *const Restore, top: *Top) bool {
        if (!self.initialized or top.workspace_id == 0 or self.touched[top.workspace_id - 1]) return true;
        const saved = for (self.matches, self.parsed.value.windows) |id, window| {
            if (id == top.id) break window;
        } else return true;
        for (self.parsed.value.workspaces) |workspace| {
            if (workspace.id != saved.workspace) continue;
            const focus = workspace.focus_order orelse break;
            if (focus == saved.order) break;
            for (self.matches, self.parsed.value.windows) |id, window| {
                if (window.order != focus) continue;
                const remembered = top.server.findToplevelById(id orelse break) orelse break;
                return !@import("window_tabs.zig").visible(remembered);
            }
            break;
        }
        return true;
    }
    pub fn finish(self: *Restore, server: *Server, top: *Top) void {
        if (!self.initialized) return;
        for (self.matches, self.parsed.value.windows, 0..) |id, saved, index| if (id == top.id) {
            if (self.finished[index]) return;
            self.finished[index] = true;
            if (saved.group != 0 and top.tab_group != 0) {
                for (self.matches, self.parsed.value.windows) |other_id, other_saved| {
                    if (other_saved.group != saved.group or other_id == null or other_id == top.id) continue;
                    const other = server.findToplevelById(other_id.?) orelse continue;
                    if (other.tab_group == 0) continue;
                    top.tab_group = other.tab_group;
                    const hidden = if (saved.tab_active) other else top;
                    hidden.detachInput();
                    hidden.setActivated(false);
                    hidden.tab_hidden = true;
                    break;
                }
                @import("window_tabs.zig").refreshVisibility(server);
            }
            if (saved.minimized) top.minimize();
            self.rebuild(server) catch |err| std.log.warn("workspace restore: {s}", .{@errorName(err)});
            if (top.tab_hidden or top.minimized) @import("workspaces.zig").focusFallback(server, if (@import("workspaces.zig").visible(top)) top.workspace_id else null);
            break;
        };
    }
    pub fn rebuild(self: *Restore, server: *Server) !void {
        for (self.parsed.value.windows, self.matches) |saved, id| {
            const at = saved.reinsert orelse continue;
            const top = server.findToplevelById(id orelse continue) orelse continue;
            if (self.touched[top.workspace_id - 1]) continue;
            for (self.parsed.value.windows, self.matches) |anchor, anchor_id| {
                if ((if (at.group) anchor.group else anchor.order) != at.anchor) continue;
                const other = server.findToplevelById(anchor_id orelse continue) orelse continue;
                top.auto_reinsert = .{ .anchor = @import("auto_tiling.zig").key(other), .axis = @enumFromInt(@intFromEnum(at.axis)), .ratio = at.ratio, .before = at.before };
                break;
            }
        }

        for (self.parsed.value.workspaces) |workspace| {
            if (self.touched[workspace.id - 1]) continue;
            var cursor: usize = 0;
            var tree: layout.Tree = .{ .root = if (workspace.nodes.len > 0) try self.buildNode(server, workspace.nodes, &cursor) else null };
            errdefer tree.deinit(gpa);
            const target = &server.world.workspaces.tiler.trees[workspace.id - 1];
            // New unmatched windows are admitted by the normal membership sync.
            const strip = try self.buildStrip(server, workspace);
            target.deinit(gpa);
            target.* = tree;
            const strip_target = &server.world.workspaces.tiler.strips[workspace.id - 1];
            strip_target.deinit(gpa);
            strip_target.* = strip;
            const slot = &server.world.workspaces.slots[workspace.id - 1];
            if (workspace.focus_order) |order| for (self.parsed.value.windows, self.matches) |saved, id| {
                if (saved.order == order and id != null and server.findToplevelById(id.?) != null) slot.focus = id;
            };
        }
        server.world.workspaces.tiler.quiet = true;
        server.world.workspaces.tiler.schedule(server);
        server.world.workspaces.refresh(server);
    }
    /// The live, tiling window a saved leaf or column member named.
    fn liveMember(self: *Restore, server: *Server, key: u64, group: bool) ?*Top {
        for (self.parsed.value.windows, self.matches) |window, id| {
            if (id == null or (if (group) window.group else window.order) != key) continue;
            const top = server.findToplevelById(id.?) orelse continue;
            if (top.workspace_id != window.workspace or @import("auto_tiling.zig").isFloating(top)) continue;
            return top;
        }
        return null;
    }
    fn buildStrip(self: *Restore, server: *Server, workspace: format.Workspace) !scroll.Strip {
        var strip: scroll.Strip = .{ .view = workspace.view };
        errdefer strip.deinit(gpa);
        for (workspace.columns) |column| {
            var cells: std.ArrayList(scroll.Cell) = .empty;
            errdefer cells.deinit(gpa);
            for (column.members) |saved| {
                const top = self.liveMember(server, saved.id, saved.group) orelse continue;
                const key = @import("auto_tiling.zig").key(top);
                const known = strip.contains(key) or for (cells.items) |cell| {
                    if (std.meta.eql(cell.member.key, key)) break true;
                } else false;
                if (!known) try cells.append(gpa, .{ .member = .{ .key = key, .order = top.workspace_order }, .weight = saved.weight });
            }
            if (cells.items.len == 0) continue;
            try strip.columns.append(gpa, .{ .width = scroll.clampFraction(column.width), .cells = cells });
        }
        return strip;
    }
    fn buildNode(self: *Restore, server: *Server, flat: []const format.Node, cursor: *usize) !?*layout.Node {
        const saved = flat[cursor.*];
        cursor.* += 1;
        if (saved.id) |key| {
            const top = self.liveMember(server, key, saved.group) orelse return null;
            const node = try gpa.create(layout.Node);
            node.* = .{ .member = .{ .key = @import("auto_tiling.zig").key(top), .order = top.workspace_order } };
            return node;
        }
        const a = try self.buildNode(server, flat, cursor);
        errdefer {
            var tree: layout.Tree = .{ .root = a };
            tree.deinit(gpa);
        }
        const b = try self.buildNode(server, flat, cursor);
        errdefer {
            var tree: layout.Tree = .{ .root = b };
            tree.deinit(gpa);
        }
        if (a == null) return b;
        if (b == null) return a;
        const node = try gpa.create(layout.Node);
        node.* = .{ .children = .{ .a = a.?, .b = b.? }, .axis = @enumFromInt(@intFromEnum(saved.axis)), .ratio = saved.ratio };
        return node;
    }
};
