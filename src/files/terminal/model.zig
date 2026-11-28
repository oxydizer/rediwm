//! Session and drawer state, owned by one Files window.
const std = @import("std");
const ui = @import("ui");
pub const c = @import("c_terminal");
pub const Point = struct { line: i64, col: i32 };
pub const Selection = struct {
    anchor: Point,
    end: Point,
    pub fn ordered(self: Selection) [2]Point {
        return if (self.anchor.line < self.end.line or (self.anchor.line == self.end.line and self.anchor.col <= self.end.col))
            .{ self.anchor, self.end }
        else
            .{ self.end, self.anchor };
    }
    pub fn contains(self: Selection, line: i64, col: i32) bool {
        const p = self.ordered();
        return (line > p[0].line or (line == p[0].line and col >= p[0].col)) and
            (line < p[1].line or (line == p[1].line and col < p[1].col));
    }
};
pub const Drawer = struct {
    session: ?*c.FT = null,
    visible: bool = false,
    requested_height: i32 = 0,
    pixels: i32 = 0,
    glide: ui.anim.Anim = .{},
    active: bool = false,
    resize: ?ui.widgets.splitter.Drag = null,
    directory: ?[:0]u8 = null,
    navigation: ?u32 = null,
    focused: bool = false,
    window_focused: bool = false,
    generation: u64 = std.math.maxInt(u64),
    cell_w: f64 = 9,
    cell_h: f64 = 20,
    ascent: f64 = 15,
    error_message: ?[]const u8 = null,
    selection: ?Selection = null,
    selecting: bool = false,
    mouse_buttons: u8 = 0,
    scroll_drag: ui.widgets.scrollbar.Drag = .{},
    bar: ui.widgets.scrollbar.Appearance = .{},
    observed_offset: i32 = 0,
    /// What the header and scrollbar last showed, so a terminal change
    /// repaints them only when they change (`terminalChanged`).
    painted_label: u64 = 0,
    observed_history: i32 = 0,
    close_at: ?i64 = null,
    close_forced: bool = false,
    preedit: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Drawer, a: std.mem.Allocator) void {
        if (self.session) |session| c.ft_free(session);
        if (self.directory) |path| a.free(path);
        self.preedit.deinit(a);
        self.* = .{};
    }
};
