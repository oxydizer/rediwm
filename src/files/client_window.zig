//! Window and seat events: the editor and preview handoff, xdg surface and toplevel, decorations, outputs and scale.

const std = @import("std");
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const c = @import("c.zig").api;
const a = std.heap.c_allocator;
const main = @import("main.zig");
const CSD_TITLEBAR_H = main.CSD_TITLEBAR_H;
const OutputInfo = main.OutputInfo;
const Client = @import("Client.zig");
const pointerEvent = Client.pointerEvent;
const keyboardEvent = Client.keyboardEvent;

pub fn editorToken(token: *xdg.ActivationTokenV1, event: xdg.ActivationTokenV1.Event, self: *Client) void {
    if (event == .done) {
        self.app.launchEditor(std.mem.span(event.done.token));
        token.destroy();
        self.editor_token_pending = false;
    }
}

pub fn openEditor(self: *Client) void {
    if (self.app.editor_path == null or self.editor_token_pending) return;
    if (self.activation) |activation| {
        const token = activation.getActivationToken() catch {
            self.app.launchEditor("");
            return;
        };
        token.setListener(*Client, editorToken, self);
        token.setSurface(self.surface);
        if (self.seat) |seat| token.setSerial(self.input_serial, seat);
        token.setAppId("rediwm-editor");
        token.commit();
        self.editor_token_pending = true;
    } else self.app.launchEditor("");
}

/// A launch handed over by another process came with that launch's XDG
/// activation token: presenting it lets the compositor focus the new window
/// as if the launcher had opened it.
pub fn activateWith(self: *Client, token: []const u8) void {
    const activation = self.activation orelse return;
    const z = a.dupeSentinel(u8, token, 0) catch return;
    defer a.free(z);
    activation.activate(z, self.surface);
}

pub fn previewReturned(self: *Client) void {
    const fd = self.app.preview_return_fd orelse return;
    const n = c.read(fd, self.preview_token[self.preview_token_len..].ptr, self.preview_token.len - self.preview_token_len);
    if (n > 0) {
        self.preview_token_len += @intCast(n);
        if (std.mem.indexOfScalar(u8, self.preview_token[0..self.preview_token_len], '\n')) |end| {
            self.preview_token[end] = 0;
            if (self.activation) |activation| activation.activate(&self.preview_token, self.surface);
        } else if (self.preview_token_len < self.preview_token.len) return;
    } else if (n < 0 and std.posix.errno(n) == .INTR) return;
    _ = c.close(fd);
    self.app.preview_return_fd = null;
    self.preview_token_len = 0;
}

pub fn wmBaseEvent(_: *xdg.WmBase, event: xdg.WmBase.Event, self: *Client) void {
    switch (event) {
        .ping => |ev| {
            if (self.wm_base) |wm| wm.pong(ev.serial);
        },
    }
}

pub fn outputEvent(_: *wl.Output, event: wl.Output.Event, info: *OutputInfo) void {
    if (event == .scale) {
        info.scale = std.math.clamp(event.scale.factor, 1, 4);
        info.client.recomputeScale();
    }
}

// The window may span multiple outputs at different scales; use the
// largest scale among outputs the surface currently overlaps, per the
// usual Wayland client convention. Falls back to 1 before the first
// wl_surface.enter is received.
pub fn recomputeScale(self: *Client) void {
    var new_scale: i32 = 1;
    for (self.entered_outputs.items) |info| new_scale = @max(new_scale, info.scale);
    if (new_scale != self.scale) {
        self.scale = new_scale;
        self.app.scale = new_scale;
        self.app.invalidate();
    }
}

pub fn removeEnteredOutput(self: *Client, info: *OutputInfo) void {
    for (self.entered_outputs.items, 0..) |o, i| {
        if (o == info) {
            _ = self.entered_outputs.swapRemove(i);
            return;
        }
    }
}

pub fn surfaceEvent(_: *wl.Surface, event: wl.Surface.Event, self: *Client) void {
    switch (event) {
        .enter => |ev| {
            if (ev.output) |out| {
                for (self.outputs.items) |info| {
                    if (info.proxy == out) {
                        self.entered_outputs.append(a, info) catch {};
                        self.recomputeScale();
                        break;
                    }
                }
            }
            self.app.invalidate();
        },
        .leave => |ev| {
            if (ev.output) |out| {
                for (self.outputs.items) |info| {
                    if (info.proxy == out) {
                        self.removeEnteredOutput(info);
                        self.recomputeScale();
                        break;
                    }
                }
            }
        },
    }
}

pub fn seatEvent(seat: *wl.Seat, event: wl.Seat.Event, self: *Client) void {
    switch (event) {
        .capabilities => |ev| {
            if (ev.capabilities.pointer and self.pointer == null) {
                self.pointer = seat.getPointer() catch null;
                if (self.pointer) |p| p.setListener(*Client, pointerEvent, self);
            }
            if (!ev.capabilities.pointer) {
                self.cursor_shape.clearPointer();
                if (self.pointer) |p| p.release();
                self.pointer = null;
            }
            if (ev.capabilities.keyboard and self.keyboard == null) {
                self.keyboard = seat.getKeyboard() catch null;
                if (self.keyboard) |k| k.setListener(*Client, keyboardEvent, self);
            }
            if (!ev.capabilities.keyboard) {
                if (self.keyboard) |k| k.release();
                self.keyboard = null;
            }
        },
        else => {},
    }
}

pub fn xdgSurfaceEvent(xdg_surf: *xdg.Surface, event: xdg.Surface.Event, self: *Client) void {
    switch (event) {
        .configure => |ev| {
            xdg_surf.ackConfigure(ev.serial);
            self.configured = true;
            self.ack_uncommitted = true;
            self.app.invalidate();
        },
    }
}

// Whether this window must draw its own titlebar: either the compositor
// never advertised zxdg_decoration_manager_v1 (no configure event will
// ever arrive, so self-decorate unconditionally), or it did negotiate a
// mode and that mode isn't server_side. Per the xdg-decoration spec, a
// mode that hasn't been negotiated yet is assumed to be client_side.
pub fn wantsCsd(self: *const Client) bool {
    return self.decoration_mode != .server_side;
}

pub fn titlebarHeight(self: *const Client) i32 {
    return if (self.wantsCsd()) CSD_TITLEBAR_H else 0;
}

pub fn decorationEvent(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, self: *Client) void {
    switch (event) {
        .configure => |ev| {
            self.decoration_mode = switch (ev.mode) {
                .server_side => .server_side,
                .client_side => .client_side,
                else => .client_side,
            };
            self.app.invalidate();
        },
    }
}

pub fn xdgToplevelEvent(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Client) void {
    switch (event) {
        .configure => |ev| {
            const tbh = self.titlebarHeight();
            if (ev.width > 0 and ev.height > 0) {
                self.app.resize(ev.width, @max(1, ev.height - tbh));
            } else if (!self.configured) {
                self.app.resize(960, @max(540, 214 + self.app.footerHeight()));
            }
            self.xdg_toplevel.setMinSize(if (self.app.chooser != null) 600 else 360, 214 + self.app.footerHeight() + tbh);
            self.app.invalidate();
        },
        .close => {
            self.app.requestClose();
        },
        .configure_bounds, .wm_capabilities => {},
    }
}

/// A portal request names the requesting app's window: as "wayland:<handle>"
/// it is imported through xdg-foreign and the chooser becomes its dialog, modal
/// unless the app asked otherwise. An "x11:<xid>" window cannot parent a Wayland
/// one, so that chooser stays a window of its own.
pub fn attachToParent(self: *Client, options: @import("chooser.zig").Options) void {
    const prefix = "wayland:";
    if (!std.mem.startsWith(u8, options.parent_window, prefix)) return;
    const handle = options.parent_window[prefix.len..];
    // Real handles are short; a huge one would not fit a Wayland message.
    if (handle.len == 0 or handle.len > 256) return;
    const importer = self.importer orelse return;
    const name = a.dupeSentinel(u8, handle, 0) catch return;
    defer a.free(name);
    const imported = importer.importToplevel(name) catch return;
    imported.setListener(*Client, importedEvent, self);
    imported.setParentOf(self.surface);
    self.imported_parent = imported;
    const manager = self.wm_dialog orelse return;
    const dialog = manager.getXdgDialog(self.xdg_toplevel) catch return;
    if (options.modal) dialog.setModal();
    self.dialog = dialog;
}

/// Before the toplevel goes: the dialog object refers to it.
pub fn detachParent(self: *Client) void {
    if (self.dialog) |dialog| dialog.destroy();
    self.dialog = null;
    if (self.imported_parent) |imported| imported.destroy();
    self.imported_parent = null;
}

/// The app's window closed or withdrew its handle; the chooser stays open on
/// its own, and the portal request decides when it ends.
fn importedEvent(imported: *zxdg.ImportedV2, event: zxdg.ImportedV2.Event, self: *Client) void {
    switch (event) {
        .destroyed => {
            imported.destroy();
            self.imported_parent = null;
        },
    }
}
