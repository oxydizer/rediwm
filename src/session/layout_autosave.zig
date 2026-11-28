//! Workspace layouts are saved after edits and when leaving tiled mode. A saved
//! client claims its geometry when it maps. Keep the startup file intact until
//! slow clients have had a chance to return, or the user explicitly leaves.
//! A session starting on Canvas keeps the snapshot until it enters tiled mode.
const std = @import("std");
const wl = @import("wayland").server.wl;
const Server = @import("../Server.zig");
const Top = @import("../Toplevel.zig");
const persistence = @import("../workspace_persistence.zig");
const window_sizes = @import("../window_sizes.zig");
const log = std.log.scoped(.layout_autosave);
const gpa = @import("../main.zig").gpa;

pub const Autosave = struct {
    server: *Server,
    save_timer: *wl.EventSource,
    restore_timer: *wl.EventSource,
    prepare_idle: ?*wl.EventSource = null,
    save_pending: bool = false,
    workspace_hash: ?u64 = null,
    workspace_restore: ?persistence.Restore = null,

    pub fn create(server: *Server) !*Autosave {
        const self = try gpa.create(Autosave);
        errdefer gpa.destroy(self);
        const loop = server.wl_server.getEventLoop();
        const save_timer = try loop.addTimer(*Autosave, onSaveTimer, self);
        errdefer save_timer.remove();
        const restore_timer = try loop.addTimer(*Autosave, onRestoreDeadline, self);
        self.* = .{ .server = server, .save_timer = save_timer, .restore_timer = restore_timer };

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        if (workspacePath(arena.allocator(), server)) |path| {
            self.workspace_restore = persistence.Restore.load(server, path) catch |err| blk: {
                if (err != error.FileNotFound) log.warn("workspace restore: {s}", .{@errorName(err)});
                break :blk null;
            };
            const manager = &server.world.workspaces;
            if (self.workspace_restore) |*restore| if (restore.parsed.value.mode) |mode| if (!manager.active) {
                manager.last_tiled = if (mode == .scrolling) .scrolling else .tiling;
            };
        }
        if (server.world.workspaces.active) self.entered();
        return self;
    }

    pub fn deinit(self: *Autosave) void {
        self.cancelWorkspaceRestore();
        self.save_timer.remove();
        self.restore_timer.remove();
        gpa.destroy(self);
    }

    pub fn entered(self: *Autosave) void {
        const restore = if (self.workspace_restore) |*r| r else return;
        // Windows already open on Canvas were matched in workspaces.enter.
        for (restore.matches) |match| {
            const top = self.server.findToplevelById(match orelse continue) orelse continue;
            restore.finish(self.server, top);
        }
        // On startup collect the initial set of outputs before assigning the
        // snapshot's workspace selections, even if no clients have mapped.
        if (!restore.initialized and self.prepare_idle == null)
            self.prepare_idle = self.server.wl_server.getEventLoop().addIdle(*Autosave, prepareRestore, self) catch null;
        self.restore_timer.timerUpdate(37_000) catch {};
    }

    fn prepareRestore(self: *Autosave) void {
        self.prepare_idle = null;
        if (self.workspace_restore) |*restore| restore.prepare(self.server);
    }

    /// Coalesce a burst of changes into one write. Neither Canvas nor a
    /// stationary workspace re-arms this timer.
    pub fn changed(self: *Autosave) void {
        if (self.save_pending or !self.server.world.workspaces.active) return;
        self.save_timer.timerUpdate(10_000) catch return;
        self.save_pending = true;
    }

    pub fn saveNow(self: *Autosave) void {
        if (!self.server.world.workspaces.active) return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        if (workspacePath(arena.allocator(), self.server)) |path|
            persistence.save(self.server, path, &self.workspace_hash) catch |err| {
                log.warn("workspace autosave: {s}", .{@errorName(err)});
            };
    }

    pub fn mapped(self: *Autosave, top: *Top) void {
        if (self.workspace_restore) |*restore| restore.apply(self.server, top);
    }
    pub fn finishMapped(self: *Autosave, top: *Top) void {
        if (!self.server.world.workspaces.active) return;
        if (self.workspace_restore) |*restore| restore.finish(self.server, top);
    }
    pub fn cancelWorkspaceRestore(self: *Autosave) void {
        if (self.prepare_idle) |idle| idle.remove();
        self.prepare_idle = null;
        self.restore_timer.timerUpdate(0) catch {};
        if (self.workspace_restore) |*restore| restore.deinit();
        self.workspace_restore = null;
    }
    pub fn navigation(self: *Autosave) void {
        if (self.workspace_restore) |*restore| if (!restore.initialized) {
            restore.restore_output_selection = false;
        };
        self.changed();
    }
    pub fn touch(self: *Autosave, ids: []const u8) void {
        if (self.workspace_restore) |*restore| for (ids) |id| {
            if (id > 0 and id <= 32) restore.touched[id - 1] = true;
        };
        self.changed();
    }

    fn onSaveTimer(self: *Autosave) c_int {
        defer self.save_pending = false;
        if (self.workspace_restore) |*restore| if (restore.pending()) return 0;
        self.saveNow();
        return 0;
    }

    fn onRestoreDeadline(self: *Autosave) c_int {
        self.cancelWorkspaceRestore();
        self.changed();
        return 0;
    }
};

fn workspacePath(a: std.mem.Allocator, server: *Server) ?[]const u8 {
    const dir = (window_sizes.resolveStateDir(a, server.environ) catch return null) orelse return null;
    return std.fmt.allocPrint(a, "{s}/workspace-layout.json", .{dir}) catch null;
}
