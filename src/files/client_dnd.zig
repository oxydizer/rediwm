//! Drag and drop: data offers, drops into folders or the terminal, and dragging files out.

const std = @import("std");
const io_thread_guard = @import("io_thread_guard.zig");
const wl = @import("wayland").client.wl;
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const transfer = @import("transfer.zig");
const clipboard_mod = @import("clipboard.zig");
const a = std.heap.c_allocator;
const main = @import("main.zig");
const Offer = main.Offer;
const ClipboardSource = main.ClipboardSource;
const DragIcon = main.DragIcon;
const Client = @import("Client.zig");
const clipboardEvent = Client.clipboardEvent;

pub fn offerEvent(_: *wl.DataOffer, event: wl.DataOffer.Event, offer: *Offer) void {
    if (event == .action) offer.action = event.action.dnd_action;
    if (event == .offer) {
        if (std.mem.eql(u8, std.mem.span(event.offer.mime_type), "text/plain")) offer.text = true;
        if (std.mem.eql(u8, std.mem.span(event.offer.mime_type), "text/plain;charset=utf-8")) offer.utf8 = true;
        if (std.mem.eql(u8, std.mem.span(event.offer.mime_type), "text/uri-list")) offer.uri = true;
        if (std.mem.eql(u8, std.mem.span(event.offer.mime_type), "application/x-rediwm-file-transfer")) offer.files = true;
        if (std.mem.eql(u8, std.mem.span(event.offer.mime_type), "x-special/gnome-copied-files")) offer.gnome = true;
    }
}

pub fn discardOffer(self: *Client, offer: *Offer) void {
    for (self.offers.items, 0..) |o, i| {
        if (o == offer) {
            _ = self.offers.swapRemove(i);
            break;
        }
    }
    offer.proxy.destroy();
    a.destroy(offer);
}

pub fn dataEvent(_: *wl.DataDevice, event: wl.DataDevice.Event, self: *Client) void {
    switch (event) {
        .data_offer => |ev| {
            const offer = a.create(Offer) catch return;
            offer.* = .{ .proxy = ev.id };
            self.offers.append(a, offer) catch {
                a.destroy(offer);
                return;
            };
            ev.id.setListener(*Offer, offerEvent, offer);
        },
        .enter => |ev| {
            // Every window's data device hears every drag that enters any
            // window of the connection; only the one under the drag takes it.
            // The others keep their copy of the offer until it is inert:
            // wlroots takes a version 3 drag offer destroyed before the drop
            // finishes as a refusal and cancels the whole drag, so discarding
            // it here ended every drag while two windows were open. After the
            // leave (or once the next drag enters) the compositor has let go
            // of it.
            if (ev.surface != self.surface) {
                if (self.foreign_offer) |old| self.discardOffer(old);
                self.foreign_offer = if (ev.id) |id| @ptrCast(@alignCast(id.getUserData())) else null;
                return;
            }
            self.drag_here = true;
            if (self.drag_offer) |old| self.discardOffer(old);
            self.drag_offer = if (ev.id) |id| @ptrCast(@alignCast(id.getUserData())) else null;
            self.drag_enter_serial = ev.serial;
            // Offers are released on leave instead of retaining every re-entry.
            self.dragOver(ev.x.toDouble(), ev.y.toDouble(), true);
        },
        .motion => |ev| if (self.drag_here) self.dragOver(ev.x.toDouble(), ev.y.toDouble(), false),
        .leave => {
            if (self.foreign_offer) |offer| self.discardOffer(offer);
            self.foreign_offer = null;
            if (!self.drag_here) return;
            self.drag_here = false;
            self.app.dropLeave();
            if (self.drag_offer) |offer| self.discardOffer(offer);
            self.drag_offer = null;
        },
        .drop => if (self.drag_here) {
            self.drag_here = false;
            self.dragDropped();
        },
        .selection => |ev| {
            self.cancelReceive();
            if (self.selection_offer) |old| self.discardOffer(old);
            self.selection_offer = if (ev.id) |id| @ptrCast(@alignCast(id.getUserData())) else null;
        },
    }
}

pub fn dragOver(self: *Client, x: f64, y: f64, entered: bool) void {
    const offer = self.drag_offer orelse return;
    self.drag_x = x;
    self.drag_y = y - @as(f64, @floatFromInt(self.titlebarHeight()));
    const available = offer.uri and self.drop_receiving == null;
    // The Trash row takes moves only, like the dock's Trash: a source that
    // can only copy (Files' own Trash view among them) is refused.
    const trash = available and offer.proxy.getVersion() >= 3 and self.app.trashDropAt(x, self.drag_y);
    const trash_changed = trash != self.app.trash_drop;
    self.app.setTrashDrop(trash);
    const pin = available and !trash and self.app.dropMotion(x, self.drag_y);
    if (trash) self.app.setPinDrop(null);
    const terminal = available and !pin and !trash and self.app.terminalDropAt(x, self.drag_y);
    const folder = available and !pin and !terminal and !trash and self.app.dropDirectoryAt(x, self.drag_y) != null;
    self.app.highlightDrop(x, self.drag_y, folder);
    const wanted = pin or folder or terminal or trash;
    const moving = trash or (folder and offer.files and !self.app.ctrl);
    if (!entered and !trash_changed and wanted == self.drag_accepting and moving == self.drag_moving) return;
    self.drag_accepting = wanted;
    self.drag_moving = moving;
    offer.proxy.accept(self.drag_enter_serial, if (wanted) "text/uri-list" else null);
    if (offer.proxy.getVersion() >= 3) {
        // Files performs filesystem moves in the receiving job, never in
        // the source's finished callback. Other sources, pins and terminal
        // path insertion use copy only.
        offer.proxy.setActions(.{ .copy = wanted and !trash, .move = moving }, if (moving) .{ .move = true } else .{ .copy = wanted });
    }
}

pub fn dragDropped(self: *Client) void {
    const offer = self.drag_offer orelse return;
    self.drag_offer = null;
    defer self.app.dropLeave();
    const accepted = self.drag_accepting;
    self.drag_accepting = false;
    const trash = self.app.takeTrashDrop();
    const slot = self.app.takePinDrop();
    const terminal = !trash and slot == null and self.app.terminalDropAt(self.drag_x, self.drag_y);
    const directory = if (trash or slot != null or terminal) "" else self.app.dropDirectoryAt(self.drag_x, self.drag_y) orelse {
        self.discardOffer(offer);
        return;
    };
    if (!accepted or (offer.proxy.getVersion() >= 3 and !offer.action.copy and !offer.action.move) or (trash and !offer.action.move)) {
        self.discardOffer(offer);
        return;
    }
    self.drop_trash = trash;
    self.startDropReceive(offer, slot, directory, terminal) catch {
        self.app.setStatusNotice(@import("i18n").tr("Could not read the dropped items"), true);
        self.discardOffer(offer);
    };
}

pub fn startDropReceive(self: *Client, offer: *Offer, slot: ?usize, target: []const u8, terminal: bool) !void {
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return error.PipeFailed;
    defer _ = c.close(fds[1]);
    errdefer _ = c.close(fds[0]);
    if (c.fcntl(fds[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.NonblockingFailed;
    const directory = try a.dupe(u8, target);
    if (terminal) {
        self.app.focus = .terminal;
        self.app.edit_revision += 1;
        self.app.terminalDamage();
    }
    self.drop_receiving = .{ .fd = fds[0], .text = false, .revision = self.app.edit_revision, .directory = directory, .started = app_mod.nowMs() };
    self.drop_offer = offer;
    self.drop_slot = slot;
    self.drop_terminal = terminal;
    self.drop_move = slot == null and !terminal and !self.drop_trash and offer.action.move;
    offer.proxy.receive("text/uri-list", fds[1]);
}

pub fn receiveDrop(self: *Client) void {
    const receive = if (self.drop_receiving) |*r| r else return;
    if (app_mod.nowMs() - receive.started > transfer.timeout_ms) {
        self.app.setStatusNotice(@import("i18n").tr("The drop timed out"), true);
        self.finishDrop();
        return;
    }
    const done = receive.read() catch {
        self.app.setStatusNotice(@import("i18n").tr("The dropped list failed or exceeded 1 MiB"), true);
        self.finishDrop();
        return;
    };
    if (!done) return;
    defer self.finishDrop();
    const decoded = clipboard_mod.decodeUris(a, receive.bytes.items) catch {
        self.app.setStatusNotice(@import("i18n").tr("Invalid dropped list"), true);
        return;
    };
    defer decoded.deinit(a);
    if (self.drop_trash) {
        self.app.trashDropped(decoded.paths);
    } else if (self.drop_terminal) {
        // Like clipboard paste, an asynchronous drop must not type into a
        // different editor or a restarted session after focus changes.
        if (receive.revision == self.app.edit_revision and self.app.focus == .terminal) self.app.terminalDropPaths(decoded.paths);
    } else if (self.drop_slot) |slot| {
        self.app.pinDropped(slot, decoded.paths);
    } else {
        // The service resolves the destination, each source and each
        // source's folder; `app_requests` finishes the drop.
        const count = decoded.paths.len;
        const all = a.alloc([]const u8, 1 + 2 * count) catch return;
        defer a.free(all);
        all[0] = receive.directory;
        for (decoded.paths, 0..) |path, i| {
            all[1 + i] = path;
            all[1 + count + i] = std.fs.path.dirname(path) orelse path;
        }
        const owned = @import("app_requests.zig").dupeAll(a, all) catch return;
        _ = @import("app_requests.zig").send(&self.app, .{ .canonical = .{ .paths = all } }, .{ .drop = .{ .paths = owned, .move = self.drop_move } });
    }
}

pub fn finishDrop(self: *Client) void {
    if (self.drop_receiving) |*receive| receive.deinit();
    self.drop_receiving = null;
    self.drop_trash = false;
    const offer = self.drop_offer orelse return;
    self.drop_offer = null;
    self.endDrop(offer);
}

/// Tells the source the drop is over, so it can let go of the drag, and
/// releases the offer.
pub fn endDrop(self: *Client, offer: *Offer) void {
    if (offer.proxy.getVersion() >= 3) offer.proxy.finish();
    self.discardOffer(offer);
}

pub fn clearDragIcon(self: *Client) void {
    if (self.drag_icon) |*icon| icon.destroy();
    self.drag_icon = null;
}

fn startFileDragPaths(
    self: *Client,
    paths: []const []const u8,
    staging_lease: ?clipboard_mod.StagingLease,
    serial: u32,
) !void {
    var owned_lease = staging_lease;
    errdefer if (owned_lease) |*lease| lease.deinit();
    const manager = self.data_manager orelse return error.DataDeviceUnavailable;
    const device = self.data_device orelse return error.DataDeviceUnavailable;
    if (self.drag_source != null) return error.DragAlreadyActive;
    if (paths.len == 0) return error.NoDragPaths;

    const source = try manager.createDataSource();
    errdefer source.destroy();
    const clip = try a.create(ClipboardSource);
    errdefer a.destroy(clip);
    const uris = try clipboard_mod.encodeUriList(a, paths);
    errdefer a.free(uris);
    const gnome = try a.dupe(u8, "");
    clip.* = .{
        .client = self,
        .proxy = source,
        .uris = uris,
        .gnome = gnome,
        .staging_lease = owned_lease,
    };
    owned_lease = null;
    source.setListener(*ClipboardSource, clipboardEvent, clip);
    source.offer("text/uri-list");
    source.offer("application/x-rediwm-file-transfer");
    // The receiving file manager performs moves; upload targets choose copy.
    // A move out of the Trash would leave the entry's metadata behind: Restore does it properly.
    if (source.getVersion() >= 3) source.setActions(.{ .copy = true, .move = !self.app.inTrash() });
    self.drag_source = clip;
    self.app.cancelWheel();
    self.app.cancelDrag();
    // The icon is optional: an allocation failure must not lose the drag.
    self.drag_icon = DragIcon.create(self) catch null;
    device.startDrag(source, self.surface, if (self.drag_icon) |icon| icon.surface else null, serial);
    if (self.drag_icon) |icon| icon.surface.commit();
}

pub fn startFileDrag(self: *Client) !void {
    if (self.drag_source != null) return;
    if (self.data_manager == null or self.data_device == null) return;

    if (self.app.history.archive_len > 0) {
        if (self.pending_archive_drag != null) return;
        self.pending_archive_drag = try self.app.startArchiveDragExport();
        self.pending_archive_drag_serial = self.drag_serial;
        self.app.cancelDrag();
        return;
    }

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(a);
    for (self.app.items.items) |item| {
        if (item.selected and !item.missing) try paths.append(a, item.path);
    }
    if (paths.items.len == 0) return;
    try startFileDragPaths(self, paths.items, null, self.drag_serial);
}

pub fn cancelPendingArchiveDrag(self: *Client) void {
    const tag = self.pending_archive_drag orelse return;
    @import("app_archives.zig").abandon(&self.app, tag);
    var pending_export = self.app.takeArchiveDragExport();
    if (pending_export) |*drag_export| drag_export.deinit();
}

/// Starts the drag an archive export was preparing once its members are
/// ready, as long as the button is still held over the window.
pub fn stepArchiveDrag(self: *Client) void {
    const tag = self.pending_archive_drag orelse return;
    if (!self.left_button_held or !self.inside) {
        self.cancelPendingArchiveDrag();
        self.pending_archive_drag = null;
        return;
    }

    var pending_export = self.app.takeArchiveDragExport();
    if (pending_export) |*drag_export| {
        self.pending_archive_drag = null;
        const lease = drag_export.staging_lease;
        drag_export.staging_lease = null;
        startFileDragPaths(
            self,
            drag_export.paths.items,
            lease,
            self.pending_archive_drag_serial,
        ) catch {
            self.app.setStatusNotice("Could not start archive drag", true);
        };
        drag_export.deinit();
        return;
    }
    // Failed or cancelled: nothing will come.
    if (!@import("app_archives.zig").pending(&self.app, tag)) self.pending_archive_drag = null;
}
