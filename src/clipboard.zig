// Clipboard access for the compositor's *own* UI (the start menu's search
// field), as distinct from `Input.zig`'s `request_set_selection`, which only
// forwards one client's selection to the seat on that client's behalf.
//
// Shell chrome is not a Wayland client, so it has no `wl_data_device` to work
// through. It has to sit on the other side of the protocol:
//
// - **Copy** means owning a `wlr_data_source`. wlroots gives no ready-made
//   "here is a string" source, so `TextSource` below is one: a `DataSource`
//   embedded at offset zero of a struct that also owns the bytes, with an
//   `Impl` whose `send` writes them to the fd the requesting client passed.
// - **Paste** means being the *receiver*: hand the current
//   `seat.selection_source` the write end of a pipe, then read the other end.
//   That read cannot block the compositor, so it goes on the Wayland event
//   loop and the text arrives some frames later — which is why `requestText`
//   is a callback rather than a return value.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const gpa = @import("main.zig").gpa;
const Server = @import("Server.zig");

const log = std.log.scoped(.clipboard);

/// Offered for a copy, and searched for in that order on a paste. The first
/// two are what every toolkit publishes; the X11 spellings come through
/// Xwayland's clipboard bridge and cost nothing to accept.
const text_mime_types = [_][:0]const u8{
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
};

/// A single paste can be arbitrarily large (another app's clipboard), so cap
/// it: a runaway source must not be able to grow the compositor's heap.
const max_paste_bytes: usize = 1 << 20;

// `wl_array_add` is not in the Zig bindings, and `wlr_data_source_destroy`
// `free()`s each mime string and releases the array itself — so the strings
// must come from the C allocator and the array must be grown libwayland's
// way, not with a Zig ArrayList pointed at it.
extern fn wl_array_add(array: *wl.Array, size: usize) ?*anyopaque;

// ---- Copy ----

const TextSource = struct {
    /// First field, and never moved: wlroots hands `*DataSource` back to the
    /// impl callbacks and `@fieldParentPtr` walks from there.
    base: wlr.DataSource,
    text: []u8,

    const impl: wlr.DataSource.Impl = .{
        .send = send,
        .accept = null,
        .destroy = destroy,
        .dnd_drop = null,
        .dnd_finish = null,
        .dnd_action = null,
    };

    fn send(source: *wlr.DataSource, mime_type: [*:0]const u8, fd: i32) callconv(.c) void {
        _ = mime_type; // every type we offer is the same UTF-8 bytes
        const self: *TextSource = @fieldParentPtr("base", source);
        defer _ = std.c.close(fd);

        // The fd is whatever the requesting client passed, so this write can
        // in principle block on a full pipe. It does not in practice: the only
        // thing that reaches here is a one-line text field's contents, orders
        // of magnitude under a pipe buffer. A source that could hold megabytes
        // would need this moved onto the event loop like the paste side.
        //
        // The receiver may also go away mid-write (a client that asked for the
        // selection and exited), which arrives as EPIPE. Partial writes are
        // normal on a pipe, so loop.
        var written: usize = 0;
        while (written < self.text.len) {
            const n = std.c.write(fd, self.text.ptr + written, self.text.len - written);
            if (n > 0) {
                written += @intCast(n);
                continue;
            }
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            break;
        }
    }

    fn destroy(source: *wlr.DataSource) callconv(.c) void {
        const self: *TextSource = @fieldParentPtr("base", source);
        gpa.free(self.text);
        gpa.destroy(self);
    }
};

/// Puts `text` on the seat's clipboard, replacing whatever was there. The
/// bytes are copied; the caller keeps ownership of its own buffer (and in
/// practice is about to free it — a cut rebuilds the field immediately).
pub fn copyText(server: *Server, text: []const u8) void {
    if (text.len == 0) return;
    const source = gpa.create(TextSource) catch |err| {
        log.err("copyText: {}", .{err});
        return;
    };
    source.text = gpa.dupe(u8, text) catch |err| {
        gpa.destroy(source);
        log.err("copyText: {}", .{err});
        return;
    };
    // `init` zeroes the mime array, so it has to come before the types go in.
    wlr.DataSource.init(&source.base, &TextSource.impl);
    for (text_mime_types) |mime| {
        if (!offerMime(&source.base, mime)) {
            // Half-populated is still usable as long as something was offered;
            // with nothing offered the source is useless, so drop it.
            if (source.base.mime_types.size == 0) {
                wlr.DataSource.destroy(&source.base);
                return;
            }
            break;
        }
    }
    server.input.seat.setSelection(&source.base, server.wl_server.nextSerial());
}

fn offerMime(source: *wlr.DataSource, mime: [:0]const u8) bool {
    const duped = std.c.malloc(mime.len + 1) orelse return false;
    const bytes: [*]u8 = @ptrCast(duped);
    @memcpy(bytes[0..mime.len], mime);
    bytes[mime.len] = 0;
    const slot = wl_array_add(&source.mime_types, @sizeOf(usize)) orelse {
        std.c.free(duped);
        return false;
    };
    @as(*[*]u8, @ptrCast(@alignCast(slot))).* = bytes;
    return true;
}

// ---- Paste ----

/// One in-flight read of the seat's selection. At most one exists at a time
/// per owner: a second Ctrl+V before the first lands replaces it, so a source
/// that never writes cannot pile these up.
const PasteRequest = struct {
    server: *Server,
    owner: *anyopaque,
    deliver: *const fn (owner: *anyopaque, text: []const u8) void,
    read_fd: std.posix.fd_t,
    source: ?*wl.EventSource = null,
    buffer: std.ArrayList(u8) = .empty,

    fn finish(self: *PasteRequest, deliver_text: bool) void {
        if (self.source) |src| src.remove();
        _ = std.c.close(self.read_fd);
        if (pending == self) pending = null;
        if (deliver_text and self.buffer.items.len > 0) {
            self.deliver(self.owner, self.buffer.items);
        }
        self.buffer.deinit(gpa);
        gpa.destroy(self);
    }

    fn readable(fd: c_int, mask: wl.EventMask, self: *PasteRequest) c_int {
        _ = mask;
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &chunk, chunk.len);
            if (n > 0) {
                const len: usize = @intCast(n);
                if (self.buffer.items.len + len > max_paste_bytes) {
                    log.warn("paste exceeded {d} bytes; truncating", .{max_paste_bytes});
                    self.finish(true);
                    return 0;
                }
                self.buffer.appendSlice(gpa, chunk[0..len]) catch {
                    self.finish(false);
                    return 0;
                };
                continue;
            }
            if (n == 0) {
                // EOF: the source closed its end, so the text is complete.
                self.finish(true);
                return 0;
            }
            return switch (std.posix.errno(n)) {
                // Nothing more right now; the loop wakes us again.
                .AGAIN => 0,
                .INTR => continue,
                else => blk: {
                    self.finish(false);
                    break :blk 0;
                },
            };
        }
    }
};

var pending: ?*PasteRequest = null;

/// Asks the seat's current selection for text and delivers it to `callback`
/// once it has all arrived — possibly several frames later, and not at all if
/// the clipboard is empty or holds no text type. The delivered slice is
/// borrowed for the duration of the call.
pub fn requestText(
    server: *Server,
    comptime T: type,
    comptime callback: fn (owner: T, text: []const u8) void,
    owner: T,
) void {
    // A second paste before the first landed abandons the first: the newer
    // keystroke is what the user meant, and this keeps the count at one.
    if (pending) |old| old.finish(false);

    const source = server.input.seat.selection_source orelse return;
    const mime = pickTextMime(source) orelse {
        log.debug("requestText: clipboard holds no text type", .{});
        return;
    };

    var fds: [2]std.posix.fd_t = undefined;
    // CLOEXEC so a spawned app cannot inherit the pipe; NONBLOCK on the read
    // end so `readable` can drain without ever blocking the event loop.
    if (std.c.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }) != 0) {
        log.err("requestText: pipe2 failed", .{});
        return;
    }

    const request = gpa.create(PasteRequest) catch |err| {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        log.err("requestText: {}", .{err});
        return;
    };
    const Shim = struct {
        fn deliver(raw: *anyopaque, text: []const u8) void {
            callback(@ptrCast(@alignCast(raw)), text);
        }
    };
    request.* = .{
        .server = server,
        .owner = owner,
        .deliver = &Shim.deliver,
        .read_fd = fds[0],
    };

    // Hand over the write end. wlr_data_source_send closes it, so the pipe
    // reaches EOF once the source is done; closing it again here could close
    // an unrelated descriptor that reused the number.
    source.send(mime, fds[1]);

    request.source = server.wl_server.getEventLoop().addFd(
        *PasteRequest,
        fds[0],
        .{ .readable = true, .hangup = true },
        PasteRequest.readable,
        request,
    ) catch |err| {
        log.err("requestText: could not watch the pipe: {}", .{err});
        request.finish(false);
        return;
    };
    pending = request;
}

/// Drops an in-flight paste whose destination is going away, so its callback
/// cannot fire into freed memory.
pub fn cancelFor(owner: *anyopaque) void {
    const request = pending orelse return;
    if (request.owner == owner) request.finish(false);
}

fn pickTextMime(source: *wlr.DataSource) ?[*:0]const u8 {
    const offered = source.mime_types.slice([*:0]const u8);
    for (text_mime_types) |wanted| {
        for (offered) |candidate| {
            if (std.mem.eql(u8, std.mem.span(candidate), wanted)) return candidate;
        }
    }
    return null;
}

// Image sends can exceed the pipe capacity. Each receiver gets an independent,
// nonblocking transfer whose bytes survive replacement of the clipboard source.
const ImageSource = struct {
    base: wlr.DataSource,
    bytes: []u8,
    server: *Server,
    const impl: wlr.DataSource.Impl = .{ .send = send, .accept = null, .destroy = destroy, .dnd_drop = null, .dnd_finish = null, .dnd_action = null };
    fn send(source: *wlr.DataSource, mime: [*:0]const u8, fd: i32) callconv(.c) void {
        const self: *ImageSource = @fieldParentPtr("base", source);
        if (!std.mem.eql(u8, std.mem.span(mime), "image/png")) {
            _ = std.c.close(fd);
            return;
        }
        startTransfer(self.server, fd, self.bytes);
    }
    fn destroy(source: *wlr.DataSource) callconv(.c) void {
        const self: *ImageSource = @fieldParentPtr("base", source);
        gpa.free(self.bytes);
        gpa.destroy(self);
    }
};

/// Writes a copy of `bytes` to `fd` from the event loop, then closes it.
fn startTransfer(server: *Server, fd: i32, bytes: []const u8) void {
    const transfer = gpa.create(ImageTransfer) catch {
        _ = std.c.close(fd);
        return;
    };
    const owned = gpa.dupe(u8, bytes) catch {
        gpa.destroy(transfer);
        _ = std.c.close(fd);
        return;
    };
    transfer.* = .{ .bytes = owned, .fd = fd, .next = image_transfers };
    image_transfers = transfer;
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }))) < 0) {
        transfer.finish();
        return;
    }
    transfer.source = server.wl_server.getEventLoop().addFd(*ImageTransfer, fd, .{ .writable = true, .hangup = true }, ImageTransfer.writable, transfer) catch {
        transfer.finish();
        return;
    };
}

const ImageTransfer = struct {
    bytes: []u8,
    fd: i32,
    offset: usize = 0,
    source: ?*wl.EventSource = null,
    next: ?*ImageTransfer = null,
    fn writable(fd: c_int, mask: wl.EventMask, self: *ImageTransfer) c_int {
        if (mask.hangup or mask.@"error") {
            self.finish();
            return 0;
        }
        // Bound work per dispatch so a fast receiver cannot starve input.
        const end = @min(self.bytes.len, self.offset + 65536);
        while (self.offset < end) {
            const n = std.c.write(fd, self.bytes.ptr + self.offset, end - self.offset);
            if (n > 0) {
                self.offset += @intCast(n);
                continue;
            }
            if (n < 0) switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return 0,
                else => {},
            };
            self.finish();
            return 0;
        }
        if (self.offset == self.bytes.len) self.finish();
        return 0;
    }
    fn finish(self: *ImageTransfer) void {
        var link = &image_transfers;
        while (link.*) |item| {
            if (item == self) {
                link.* = self.next;
                break;
            }
            link = &item.next;
        }
        if (self.source) |source| source.remove();
        _ = std.c.close(self.fd);
        gpa.free(self.bytes);
        gpa.destroy(self);
    }
};
var image_transfers: ?*ImageTransfer = null;

pub fn cancelImageTransfers() void {
    while (image_transfers) |transfer| transfer.finish();
}

// A file selection, as the desktop copies it: one list, in the freedesktop
// and GNOME spellings. A long list can exceed a pipe, so sends go through
// the same nonblocking transfers as images.
const FileListSource = struct {
    base: wlr.DataSource,
    uris: []u8,
    gnome: []u8,
    server: *Server,
    const impl: wlr.DataSource.Impl = .{ .send = send, .accept = null, .destroy = destroy, .dnd_drop = null, .dnd_finish = null, .dnd_action = null };
    fn send(source: *wlr.DataSource, mime: [*:0]const u8, fd: i32) callconv(.c) void {
        const self: *FileListSource = @fieldParentPtr("base", source);
        const gnome = std.mem.eql(u8, std.mem.span(mime), "x-special/gnome-copied-files");
        startTransfer(self.server, fd, if (gnome) self.gnome else self.uris);
    }
    fn destroy(source: *wlr.DataSource) callconv(.c) void {
        const self: *FileListSource = @fieldParentPtr("base", source);
        gpa.free(self.uris);
        gpa.free(self.gnome);
        gpa.destroy(self);
    }
};

/// Puts files on the clipboard. `uris` is a text/uri-list; `cut` marks a
/// move for receivers that read x-special/gnome-copied-files.
pub fn copyFiles(server: *Server, uris: []const u8, cut: bool) !void {
    const owned = try gpa.dupe(u8, uris);
    const gnome = std.fmt.allocPrint(gpa, "{s}\n{s}", .{ if (cut) "cut" else "copy", uris }) catch |err| {
        gpa.free(owned);
        return err;
    };
    const source = gpa.create(FileListSource) catch |err| {
        gpa.free(gnome);
        gpa.free(owned);
        return err;
    };
    source.* = .{ .base = undefined, .uris = owned, .gnome = gnome, .server = server };
    // From here the source's destroy frees everything.
    wlr.DataSource.init(&source.base, &FileListSource.impl);
    if (!offerMime(&source.base, "text/uri-list") or !offerMime(&source.base, "x-special/gnome-copied-files")) {
        wlr.DataSource.destroy(&source.base);
        return error.OutOfMemory;
    }
    server.input.seat.setSelection(&source.base, server.wl_server.nextSerial());
}

/// Whether `source` is a file list the compositor itself published.
pub fn isOwnFileList(source: *wlr.DataSource) bool {
    return source.impl == &FileListSource.impl;
}

pub fn offers(source: *wlr.DataSource, mime: []const u8) bool {
    for (source.mime_types.slice([*:0]const u8)) |candidate| {
        if (std.mem.eql(u8, std.mem.span(candidate), mime)) return true;
    }
    return false;
}

pub fn copyPng(server: *Server, bytes: []const u8) !void {
    const source = try gpa.create(ImageSource);
    source.bytes = gpa.dupe(u8, bytes) catch |err| {
        gpa.destroy(source);
        return err;
    };
    source.server = server;
    wlr.DataSource.init(&source.base, &ImageSource.impl);
    if (!offerMime(&source.base, "image/png")) {
        wlr.DataSource.destroy(&source.base);
        return error.OutOfMemory;
    }
    server.input.seat.setSelection(&source.base, server.wl_server.nextSerial());
}
