//! What the desktop app needs from whatever displays it. `App` calls these on
//! the thread that owns it; the filesystem worker never does, so the host
//! (`embedded.zig`) answers from compositor state directly. Unit tests run
//! the app against `Host.none`.
const std = @import("std");

/// `busy` is launch feedback; `text` is over the rename field; `grabbing`
/// while icons are dragged.
pub const Cursor = enum { normal, busy, text, grabbing };

/// How a paste request was handled.
pub const Paste = enum {
    /// The desktop owns the selection, or nothing is offered: paste
    /// `App.clipboard` itself.
    local,
    /// The host started a transfer into the given directory.
    transfer,
    /// Nothing usable to paste, or a transfer is already running.
    ignored,
};

pub const Host = struct {
    ctx: ?*anyopaque = null,
    vtable: *const VTable = &none_vtable,

    pub const VTable = struct {
        /// Keyboard focus follows interaction: on while a menu, dialog, edit
        /// or selected icon needs keys, off otherwise.
        keyboard: *const fn (ctx: ?*anyopaque, wanted: bool) void,
        cursor: *const fn (ctx: ?*anyopaque, cursor: Cursor) void,
        /// Offers `paths` as the clipboard selection (URI list and GNOME
        /// copied-files); `cut` marks a move.
        publishSelection: *const fn (ctx: ?*anyopaque, paths: []const []const u8, cut: bool) void,
        paste: *const fn (ctx: ?*anyopaque, dir: []const u8) Paste,
        /// The height reserved along the output's bottom edge (the taskbar),
        /// or null when the host cannot tell.
        bottomExclusion: *const fn (ctx: ?*anyopaque) ?i32,
        /// Newest window id at launch time; `windowAppeared` only matches
        /// windows newer than this.
        newestWindow: *const fn (ctx: ?*anyopaque) u64,
        /// Whether a window with this pid or app_id mapped after `after_id`.
        /// Called repeatedly while a launch is pending; a host may rate-limit
        /// and answer false in between.
        windowAppeared: *const fn (ctx: ?*anyopaque, pid: i32, app_id: []const u8, after_id: u64) bool,
        /// error.Unsupported means the host has no Appearance settings, and
        /// the caller opens the desktop's own config file instead.
        openAppearance: *const fn (ctx: ?*anyopaque) anyerror!void,
    };

    pub fn keyboard(self: Host, wanted: bool) void {
        self.vtable.keyboard(self.ctx, wanted);
    }
    pub fn cursor(self: Host, value: Cursor) void {
        self.vtable.cursor(self.ctx, value);
    }
    pub fn publishSelection(self: Host, paths: []const []const u8, cut: bool) void {
        self.vtable.publishSelection(self.ctx, paths, cut);
    }
    pub fn paste(self: Host, dir: []const u8) Paste {
        return self.vtable.paste(self.ctx, dir);
    }
    pub fn bottomExclusion(self: Host) ?i32 {
        return self.vtable.bottomExclusion(self.ctx);
    }
    pub fn newestWindow(self: Host) u64 {
        return self.vtable.newestWindow(self.ctx);
    }
    pub fn windowAppeared(self: Host, pid: i32, app_id: []const u8, after_id: u64) bool {
        return self.vtable.windowAppeared(self.ctx, pid, app_id, after_id);
    }
    pub fn openAppearance(self: Host) anyerror!void {
        return self.vtable.openAppearance(self.ctx);
    }

    /// Displays nothing and knows nothing: unit tests, and the app before a
    /// host attaches.
    pub const none: Host = .{};
};

const none_vtable: Host.VTable = .{
    .keyboard = struct {
        fn f(_: ?*anyopaque, _: bool) void {}
    }.f,
    .cursor = struct {
        fn f(_: ?*anyopaque, _: Cursor) void {}
    }.f,
    .publishSelection = struct {
        fn f(_: ?*anyopaque, _: []const []const u8, _: bool) void {}
    }.f,
    .paste = struct {
        fn f(_: ?*anyopaque, _: []const u8) Paste {
            return .local;
        }
    }.f,
    .bottomExclusion = struct {
        fn f(_: ?*anyopaque) ?i32 {
            return null;
        }
    }.f,
    .newestWindow = struct {
        fn f(_: ?*anyopaque) u64 {
            return 0;
        }
    }.f,
    .windowAppeared = struct {
        fn f(_: ?*anyopaque, _: i32, _: []const u8, _: u64) bool {
            return false;
        }
    }.f,
    .openAppearance = struct {
        fn f(_: ?*anyopaque) anyerror!void {
            return error.Unsupported;
        }
    }.f,
};
