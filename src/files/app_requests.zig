//! Requests this window sends to the I/O service and what it does with the
//! replies (stage S3a, audit U7 to U12). The window never waits: it sends,
//! keeps a `Pending` entry under the request's tag, and finishes the action
//! when the reply arrives on a later turn of the event loop.
const std = @import("std");
const builtin = @import("builtin");
const i18n = @import("i18n");
const tr = i18n.tr;
const app_mod = @import("app.zig");
const App = app_mod.App;
const io_service = @import("io_service.zig");
const io_requests = @import("io_requests.zig");
const icons = @import("../icon_cache.zig");
const tc = @import("c_terminal");
const app_trash = @import("app_trash.zig");
const ops = @import("ops.zig");

/// What to do with a reply. Owned strings are freed when it is.
pub const Pending = union(enum) {
    restore: struct { all: bool },
    create_folder,
    create_file,
    rename,
    properties: struct { preview: ?icons.Entry },
    toggle_permission: struct { path: []u8 },
    /// Opening the Trash place created its folder first.
    open_trash: struct { path: []u8, navigation: u32 },
    /// "Open in New Window" on a place: only a folder opens.
    place_window: struct { path: []u8 },
    /// A sidebar place opened in a background tab: only a folder opens.
    folder_tab: struct { path: []u8 },
    /// A pin clicked: browsed, or opened as a file.
    open_pin: struct { path: []u8 },
    /// The pins' kinds, by path.
    pin_kinds: struct { paths: [][]u8 },
    /// Paths dropped on the Places gap `slot`, normalized, in order.
    pin_drop: struct { slot: usize, paths: [][]u8 },
    terminal_directory: struct { navigation: u32 },
    /// A drop onto the listing: `[destination, sources..., parents...]` were
    /// canonicalised.
    drop: struct { paths: [][]u8, move: bool },
    chooser: struct { named: ?[]u8 },

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .toggle_permission => |p| allocator.free(p.path),
            .open_trash => |p| allocator.free(p.path),
            .place_window => |p| allocator.free(p.path),
            .folder_tab => |p| allocator.free(p.path),
            .open_pin => |p| allocator.free(p.path),
            .pin_kinds => |p| freeAll(allocator, p.paths),
            .pin_drop => |p| freeAll(allocator, p.paths),
            .drop => |p| freeAll(allocator, p.paths),
            .chooser => |p| if (p.named) |path| allocator.free(path),
            else => {},
        }
    }
};

fn freeAll(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

pub fn dupeAll(allocator: std.mem.Allocator, paths: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, paths.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |path| allocator.free(path);
        allocator.free(out);
    }
    for (paths) |path| {
        out[done] = try allocator.dupe(u8, path);
        done += 1;
    }
    return out;
}

pub const Entry = struct { tag: u64, pending: Pending };

/// Sends `request`; `pending` (whose strings it now owns) is kept until the
/// reply. False when it could not be sent; `pending` is freed then.
pub fn send(self: *App, request: io_requests.Request, pending_value: Pending) bool {
    var pending = pending_value;
    const link = &self.service;
    const handle = link.handle orelse {
        // Unit tests run an App without a service: the request runs inline,
        // through the same completion as a reply. Never in production, where
        // every window has its handle before it handles input.
        if (builtin.is_test) {
            defer pending.deinit(self.allocator);
            const reply = io_requests.execute(self.allocator, self.io, 0, &request) orelse return false;
            defer reply.destroy();
            finish(self, &pending, reply);
            return true;
        }
        pending.deinit(self.allocator);
        return false;
    };
    if (link.request_count == link.requests.len) {
        pending.deinit(self.allocator);
        self.setStatusNotice(tr("Busy, try again"), true);
        return false;
    }
    var command: io_service.Command = .{
        .kind = .request,
        .submit_tag = link.next_tag,
        .payload = io_service.OwnedPayload.createRequest(self.allocator, request) catch {
            pending.deinit(self.allocator);
            return false;
        },
    };
    defer command.deinitPayload();
    link.outbox.send(handle, &command) catch |err| {
        std.log.warn("Files request not sent: {s}", .{@errorName(err)});
        pending.deinit(self.allocator);
        self.setStatusNotice(tr("Busy, try again"), true);
        return false;
    };
    link.requests[link.request_count] = .{ .tag = link.next_tag, .pending = pending };
    link.request_count += 1;
    link.next_tag += 1;
    return true;
}

/// Whether a request of this kind is waiting for its reply.
pub fn waiting(self: *const App, kind: std.meta.Tag(Pending)) bool {
    const link = &self.service;
    for (link.requests[0..link.request_count]) |entry| if (entry.pending == kind) return true;
    return false;
}

/// Takes every reply that has arrived. Bounded by the reply slots.
pub fn takeReplies(self: *App) void {
    const link = &self.service;
    const handle = link.handle orelse return;
    while (link.request_count > 0) {
        const reply = (handle.takeReply() catch |err| switch (err) {
            // Retried on the next turn (`serviceTimeout`).
            error.ServiceBusy => {
                link.dirty = true;
                return;
            },
            else => return,
        }) orelse return;
        defer reply.destroy();
        var pending = link.takeRequest(reply.tag) orelse continue;
        defer pending.deinit(self.allocator);
        finish(self, &pending, reply);
    }
}

pub fn deinitPending(self: *App) void {
    const link = &self.service;
    for (link.requests[0..link.request_count]) |*entry| entry.pending.deinit(self.allocator);
    link.request_count = 0;
}

fn finish(self: *App, pending: *Pending, reply: *io_service.Reply) void {
    switch (pending.*) {
        .restore => |p| {
            const summary = reply.data.restore;
            if (p.all and summary.restored + summary.no_metadata + summary.failed == 0)
                return self.setStatusNotice(tr("Trash is empty"), false);
            app_trash.reportRestore(self, summary);
            self.refresh();
        },
        .create_folder, .create_file, .rename => finishMutation(self, pending.*, reply.data.done),
        .properties => |p| finishProperties(self, p.preview, &reply.data.properties),
        .toggle_permission => |p| finishToggle(self, p.path, reply.data.mode),
        .open_trash => |p| {
            if (reply.data.done != null) return self.setStatusNotice(tr("Could not open Trash"), true);
            if (self.navigation_count == p.navigation) self.navigate(p.path);
        },
        .place_window => |p| {
            // The Trash place made its folder; any other place was looked at.
            const folder = switch (reply.data) {
                .done => |err| err == null,
                .kinds => |kinds| kinds.len == 1 and kinds[0] == .dir,
                else => false,
            };
            if (!folder) return self.setStatusNotice(tr("Could not open folder"), true);
            self.openPlaceWindowNow(p.path);
        },
        .folder_tab => |p| {
            const kinds = reply.data.kinds;
            if (kinds.len == 1 and kinds[0] == .dir) self.openTab(p.path, false);
        },
        .open_pin => |p| {
            const kinds = reply.data.kinds;
            if (kinds.len != 1) return;
            _ = self.setPinKind(p.path, kinds[0]);
            self.openPinNow(p.path, kinds[0]);
        },
        .pin_kinds => |p| {
            const kinds = reply.data.kinds;
            if (kinds.len != p.paths.len) return;
            var changed = false;
            for (p.paths, kinds) |path, kind| changed = self.setPinKind(path, kind) or changed;
            if (changed) self.invalidate();
        },
        .pin_drop => |p| {
            const kinds = reply.data.kinds;
            if (kinds.len == p.paths.len) self.pinDroppedKnown(p.slot, p.paths, kinds);
        },
        .terminal_directory => |p| finishTerminal(self, p.navigation, reply.data.canonical),
        .drop => |p| finishDrop(self, p.paths, p.move, reply.data.canonical),
        .chooser => |p| self.finishChooser(p.named, &reply.data.chooser),
    }
}

fn finishMutation(self: *App, kind: std.meta.Tag(Pending), result: ?anyerror) void {
    const err = result orelse {
        self.setStatusNotice(switch (kind) {
            .create_folder => tr("Folder created"),
            .create_file => tr("File created"),
            else => tr("Renamed successfully"),
        }, false);
        self.refresh();
        return;
    };
    self.setStatusNotice(switch (err) {
        error.PathAlreadyExists => switch (kind) {
            .create_folder => tr("Folder already exists"),
            .create_file => tr("File already exists"),
            else => tr("Target name already exists"),
        },
        error.AccessDenied => tr("Permission denied"),
        error.EmptyName => tr("Name cannot be empty"),
        error.InvalidCharacter => tr("Invalid characters in name"),
        error.ReservedName => if (kind == .create_folder) tr("Reserved folder name") else tr("Reserved file name"),
        else => switch (kind) {
            .create_folder => tr("Failed to create folder"),
            .create_file => tr("Failed to create file"),
            else => tr("Failed to rename"),
        },
    }, true);
}

fn finishProperties(self: *App, preview: ?icons.Entry, result: *anyerror!@import("properties.zig").State) void {
    const state = if (result.*) |*state| state else |_| return self.setStatusNotice(tr("Could not read file properties"), true);
    // The dialog takes the state; the reply must not free it.
    var taken = state.*;
    result.* = error.Taken;
    taken.preview = preview;
    self.closeDialog();
    self.dialog = .{ .kind = .properties, .title = tr("Properties"), .properties = taken };
    self.invalidate();
}

fn finishToggle(self: *App, path: []const u8, result: anyerror!@import("c.zig").api.mode_t) void {
    const mode = result catch |err| {
        self.setStatusNotice(switch (err) {
            error.NotOwner => tr("Only the owner can change permissions"),
            error.Symlink => tr("Symbolic link permissions cannot be changed"),
            error.OpenFailed => tr("Could not open file to change permissions"),
            error.StatFailed => tr("Could not read file permissions"),
            error.ChmodFailed => tr("Could not apply permission changes"),
            else => tr("Could not change permissions"),
        }, true);
        return;
    };
    // Update the visible snapshot in place. Selection and scroll stay intact.
    for (self.items.items) |*item| {
        if (!std.mem.eql(u8, item.path, path)) continue;
        item.mode = mode;
        self.invalidate();
        return;
    }
}

fn finishTerminal(self: *App, navigation: u32, entries: []io_requests.Canonical) void {
    if (self.navigation_count != navigation or entries.len != 1) return;
    const resolved = entries[0].path orelse return;
    if (!entries[0].is_dir) return;
    if (self.terminal.directory) |old| if (std.mem.eql(u8, old, resolved)) return;
    const owned = self.allocator.dupeSentinel(u8, resolved, 0) catch return;
    if (self.terminal.directory) |old| self.allocator.free(old);
    self.terminal.directory = owned;
    if (self.terminal.session) |session| _ = tc.ft_follow(session, owned);
}

/// `paths` is `[destination, sources..., parents...]` as dropped; `entries`
/// their canonical forms, in the same order.
fn finishDrop(self: *App, paths: [][]u8, move: bool, entries: []io_requests.Canonical) void {
    if (entries.len != paths.len or paths.len < 1) return;
    const destination = entries[0].path orelse
        return self.setStatusNotice(tr("The destination folder is unavailable"), true);
    const count = (paths.len - 1) / 2;
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(self.allocator);
    for (0..count) |i| {
        const resolved = entries[1 + i].path orelse continue;
        if (ops.isDescendantOrSame(resolved, destination)) {
            self.setStatusNotice(tr("Cannot drop a folder into itself"), true);
            return;
        }
        const resolved_parent = entries[1 + count + i].path orelse continue;
        if (move and std.mem.eql(u8, resolved_parent, destination)) continue;
        kept.append(self.allocator, paths[1 + i]) catch return;
    }
    if (kept.items.len == 0) return;
    _ = self.executeTransfer(if (move) .move else .copy, kept.items, destination, false);
}

/// Asks for the kinds of every pin; the sidebar updates when they arrive.
pub fn requestPinKinds(self: *App) void {
    if (self.pins.items.items.len == 0) return;
    var paths = self.allocator.alloc([]const u8, self.pins.items.items.len) catch return;
    defer self.allocator.free(paths);
    for (self.pins.items.items, 0..) |pin, i| paths[i] = pin.path;
    const owned = dupeAll(self.allocator, paths) catch return;
    _ = send(self, .{ .path_kinds = .{ .paths = paths } }, .{ .pin_kinds = .{ .paths = owned } });
}
