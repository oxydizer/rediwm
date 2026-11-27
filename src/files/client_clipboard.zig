//! Clipboard: publishing and receiving copied files and text.

const std = @import("std");
const wl = @import("wayland").client.wl;
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const transfer = @import("transfer.zig");
const clipboard_mod = @import("clipboard.zig");
const a = std.heap.c_allocator;
const main = @import("main.zig");
const ClipboardSource = main.ClipboardSource;
const Client = @import("Client.zig");

fn releaseSource(clip: *ClipboardSource) void {
    if (clip.staging_lease) |*lease| lease.deinit();
    a.free(clip.uris);
    a.free(clip.gnome);
    a.destroy(clip);
}

pub fn clipboardEvent(source: *wl.DataSource, event: wl.DataSource.Event, clip: *ClipboardSource) void {
    switch (event) {
        .action => |ev| {
            if (clip.client.drag_source == clip) {
                if (clip.client.drag_icon) |*icon| {
                    icon.update(clip.client, ev.dnd_action.copy) catch {};
                }
            }
        },
        .send => |ev| {
            const mime = std.mem.span(ev.mime_type);
            const data = if (std.mem.eql(u8, mime, "x-special/gnome-copied-files")) clip.gnome else clip.uris;
            if (clip.client.sends.items.len >= 8) {
                _ = c.close(ev.fd);
                return;
            }
            var send = transfer.Send.init(ev.fd, data, app_mod.nowMs()) catch return;
            clip.client.sends.append(a, send) catch send.deinit();
        },
        .dnd_drop_performed => {
            if (clip.client.drag_source == clip) clip.client.clearDragIcon();
        },
        .cancelled, .dnd_finished => {
            if (clip.client.drag_source == clip) {
                clip.client.clearDragIcon();
                clip.client.drag_source = null;
            }
            if (clip.client.clipboard_source == clip) {
                clip.client.clipboard_source = null;
                clip.client.app.clearClipboard();
                clip.client.app.clipboard_cut = false;
                clip.client.app.clipboard_text.clearRetainingCapacity();
                clip.client.app.invalidate();
            }
            source.destroy();
            releaseSource(clip);
        },
        else => {},
    }
}

pub fn destroyClipboardSource(self: *Client) void {
    if (self.clipboard_source) |clip| {
        self.clipboard_source = null;
        clip.proxy.destroy();
        releaseSource(clip);
    }
}

pub fn destroyDragSource(self: *Client) void {
    if (self.drag_source) |clip| {
        self.drag_source = null;
        clip.proxy.destroy();
        releaseSource(clip);
    }
}

pub fn publishClipboard(self: *Client) !void {
    const manager = self.data_manager orelse return;
    const device = self.data_device orelse return;
    if (!self.app.clipboard_is_text and self.app.clipboard_paths.items.len == 0) {
        device.setSelection(null, self.input_serial);
        self.destroyClipboardSource();
        return;
    }
    const source = try manager.createDataSource();
    errdefer source.destroy();
    const clip = try a.create(ClipboardSource);
    errdefer a.destroy(clip);
    const mode: clipboard_mod.ClipboardMode = if (self.app.clipboard_cut) .cut else .copy;
    const uris = if (self.app.clipboard_is_text) try a.dupe(u8, self.app.clipboard_text.items) else try clipboard_mod.encodeUriList(a, self.app.clipboard_paths.items);
    errdefer a.free(uris);
    const gnome = if (self.app.clipboard_is_text) try a.dupe(u8, "") else try clipboard_mod.encodeGnomeCopiedFiles(a, mode, self.app.clipboard_paths.items);
    clip.* = .{ .client = self, .proxy = source, .uris = uris, .gnome = gnome, .text = self.app.clipboard_is_text };
    source.setListener(*ClipboardSource, clipboardEvent, clip);
    if (clip.text) {
        source.offer("text/plain;charset=utf-8");
        source.offer("text/plain");
    } else {
        source.offer("text/uri-list");
        source.offer("x-special/gnome-copied-files");
    }
    clip.staging_lease = clipboard_mod.takeStagingLease(&self.app.clipboard_staging_lease);
    device.setSelection(source, self.input_serial);
    self.destroyClipboardSource();
    self.clipboard_source = clip;
}

pub fn cancelReceive(self: *Client) void {
    if (self.receiving) |*receive| receive.deinit();
    self.receiving = null;
}

pub fn receiveClipboard(self: *Client) void {
    const receive = if (self.receiving) |*r| r else return;
    if (app_mod.nowMs() - receive.started > transfer.timeout_ms) {
        self.app.setStatusNotice(@import("i18n").tr("Clipboard transfer timed out"), true);
        self.cancelReceive();
        return;
    }
    const done = receive.read() catch {
        self.app.setStatusNotice(@import("i18n").tr("Clipboard transfer failed or exceeded 1 MiB"), true);
        self.cancelReceive();
        return;
    };
    if (!done) return;
    defer self.cancelReceive();
    if (receive.text) {
        if (receive.revision == self.app.edit_revision) self.app.pasteText(receive.bytes.items);
    } else {
        // A delayed reply must not paste into a folder navigated to meanwhile.
        if (receive.folder_navigation) |navigation| {
            if (navigation != self.app.navigation_count) return;
        } else if (!std.mem.eql(u8, receive.directory, self.app.history.current)) return;
        const decoded = clipboard_mod.decodeUris(a, receive.bytes.items) catch {
            self.app.setStatusNotice(@import("i18n").tr("Invalid file clipboard"), true);
            return;
        };
        defer decoded.deinit(a);
        self.app.executePasteExternal(decoded.mode, decoded.paths, if (receive.folder_navigation != null) receive.directory else null);
    }
}

pub fn handleClipboard(self: *Client) !void {
    if (self.app.clipboard_revision != self.clipboard_revision) {
        try self.publishClipboard();
        self.clipboard_revision = self.app.clipboard_revision;
    }
    const requested_folder = self.app.paste_folder_requested;
    if (!self.app.paste_requested and !self.app.text_paste_requested and requested_folder == null) return;
    self.app.paste_folder_requested = null;
    defer if (requested_folder) |path| self.app.allocator.free(path);
    const text = self.app.text_paste_requested;
    const folder = if (text or self.app.paste_requested) null else requested_folder;
    self.app.paste_requested = false;
    self.app.text_paste_requested = false;
    self.cancelReceive();
    if (self.clipboard_source) |clip| {
        if (text and clip.text) self.app.pasteText(clip.uris);
        if (!text and !clip.text) self.app.executePasteLocal(folder);
        return;
    }
    const offer = self.selection_offer orelse return;
    const mime: [:0]const u8 = if (text) (if (offer.utf8) "text/plain;charset=utf-8" else if (offer.text) "text/plain" else return) else (if (offer.gnome) "x-special/gnome-copied-files" else if (offer.uri) "text/uri-list" else return);
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return error.PipeFailed;
    defer _ = c.close(fds[1]);
    errdefer _ = c.close(fds[0]);
    if (c.fcntl(fds[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.NonblockingFailed;
    const directory = try a.dupe(u8, folder orelse self.app.history.current);
    self.receiving = .{
        .fd = fds[0],
        .text = text,
        .revision = self.app.edit_revision,
        .directory = directory,
        .folder_navigation = if (folder != null) self.app.navigation_count else null,
        .started = app_mod.nowMs(),
    };
    offer.proxy.receive(mime, fds[1]);
    // The main loop flushes this request before polling the receive pipe.
}
