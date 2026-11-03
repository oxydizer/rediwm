//! Drag and drop: data offers, drops into folders or the terminal, and dragging files out.

const std = @import("std");
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
            if (self.drag_offer) |old| self.discardOffer(old);
            self.drag_offer = if (ev.id) |id| @ptrCast(@alignCast(id.getUserData())) else null;
            self.drag_enter_serial = ev.serial;
            // Offers are released on leave instead of retaining every re-entry.
            self.dragOver(ev.x.toDouble(), ev.y.toDouble(), true);
        },
        .motion => |ev| self.dragOver(ev.x.toDouble(), ev.y.toDouble(), false),
        .leave => {
            self.app.dropLeave();
            if (self.drag_offer) |offer| self.discardOffer(offer);
            self.drag_offer = null;
        },
        .drop => self.dragDropped(),
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
    const pin = available and self.app.dropMotion(x, self.drag_y);
    const terminal = available and !pin and self.app.terminalDropAt(x, self.drag_y);
    const folder = available and !pin and !terminal and self.app.dropDirectoryAt(x, self.drag_y) != null;
    self.app.highlightDrop(x, self.drag_y, folder);
    const wanted = pin or folder or terminal;
    const moving = folder and offer.files and !self.app.ctrl;
    if (!entered and wanted == self.drag_accepting and moving == self.drag_moving) return;
    self.drag_accepting = wanted;
    self.drag_moving = moving;
    offer.proxy.accept(self.drag_enter_serial, if (wanted) "text/uri-list" else null);
    if (offer.proxy.getVersion() >= 3) {
        // Files performs filesystem moves in the receiving job, never in
        // the source's finished callback. Other sources, pins and terminal
        // path insertion use copy only.
        offer.proxy.setActions(.{ .copy = wanted, .move = moving }, if (moving) .{ .move = true } else .{ .copy = wanted });
    }
}

pub fn dragDropped(self: *Client) void {
    const offer = self.drag_offer orelse return;
    self.drag_offer = null;
    defer self.app.dropLeave();
    const accepted = self.drag_accepting;
    self.drag_accepting = false;
    const slot = self.app.takePinDrop();
    const terminal = slot == null and self.app.terminalDropAt(self.drag_x, self.drag_y);
    const directory = if (slot != null or terminal) "" else self.app.dropDirectoryAt(self.drag_x, self.drag_y) orelse {
        self.discardOffer(offer);
        return;
    };
    if (!accepted or (offer.proxy.getVersion() >= 3 and !offer.action.copy and !offer.action.move)) {
        self.discardOffer(offer);
        return;
    }
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
    self.drop_move = slot == null and !terminal and offer.action.move;
    offer.proxy.receive("text/uri-list", fds[1]);
}

pub fn canonicalPath(path: []const u8) ![]u8 {
    const terminated = try a.dupeSentinel(u8, path, 0);
    defer a.free(terminated);
    var buffer: [4096]u8 = undefined;
    const resolved = c.realpath(terminated, &buffer) orelse return error.InvalidPath;
    return a.dupe(u8, std.mem.span(resolved));
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
    if (self.drop_terminal) {
        // Like clipboard paste, an asynchronous drop must not type into a
        // different editor or a restarted session after focus changes.
        if (receive.revision == self.app.edit_revision and self.app.focus == .terminal) self.app.terminalDropPaths(decoded.paths);
    } else if (self.drop_slot) |slot| {
        self.app.pinDropped(slot, decoded.paths);
    } else {
        const destination = canonicalPath(receive.directory) catch {
            self.app.setStatusNotice(@import("i18n").tr("The destination folder is unavailable"), true);
            return;
        };
        defer a.free(destination);
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(a);
        for (decoded.paths) |path| {
            const resolved = canonicalPath(path) catch continue;
            defer a.free(resolved);
            if (@import("ops.zig").isDescendantOrSame(resolved, destination)) {
                self.app.setStatusNotice(@import("i18n").tr("Cannot drop a folder into itself"), true);
                return;
            }
            const parent = std.fs.path.dirname(path) orelse continue;
            const resolved_parent = canonicalPath(parent) catch continue;
            defer a.free(resolved_parent);
            if (self.drop_move and std.mem.eql(u8, resolved_parent, destination)) continue;
            paths.append(a, path) catch return;
        }
        if (paths.items.len == 0) return;
        _ = self.app.executeTransfer(if (self.drop_move) .move else .copy, paths.items, destination, false);
    }
}

pub fn finishDrop(self: *Client) void {
    if (self.drop_receiving) |*receive| receive.deinit();
    self.drop_receiving = null;
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

pub fn startFileDrag(self: *Client) !void {
    const manager = self.data_manager orelse return;
    const device = self.data_device orelse return;
    if (self.drag_source != null) return;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(a);
    for (self.app.items.items) |item| {
        if (item.selected and !item.missing) try paths.append(a, item.path);
    }
    if (paths.items.len == 0) return;
    const source = try manager.createDataSource();
    errdefer source.destroy();
    const clip = try a.create(ClipboardSource);
    errdefer a.destroy(clip);
    const uris = try clipboard_mod.encodeUriList(a, paths.items);
    errdefer a.free(uris);
    const gnome = try a.dupe(u8, "");
    clip.* = .{ .client = self, .proxy = source, .uris = uris, .gnome = gnome };
    source.setListener(*ClipboardSource, clipboardEvent, clip);
    source.offer("text/uri-list");
    source.offer("application/x-rediwm-file-transfer");
    // The receiving file manager performs moves; upload targets choose copy.
    if (source.getVersion() >= 3) source.setActions(.{ .copy = true, .move = true });
    self.drag_source = clip;
    self.app.cancelWheel();
    self.app.cancelDrag();
    // The icon is optional: an allocation failure must not lose the drag.
    self.drag_icon = DragIcon.create(self) catch null;
    device.startDrag(source, self.surface, if (self.drag_icon) |icon| icon.surface else null, self.drag_serial);
    if (self.drag_icon) |icon| icon.surface.commit();
}
