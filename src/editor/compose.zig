const std = @import("std");
const c = @cImport({
    @cInclude("xkbcommon/xkbcommon-compose.h");
});
pub const Compose = struct {
    table: ?*c.xkb_compose_table = null,
    state: ?*c.xkb_compose_state = null,
    pub fn init(environ: std.process.Environ) Compose {
        const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return .{};
        defer c.xkb_context_unref(context);
        const locale = environ.getPosix("LC_ALL") orelse environ.getPosix("LC_CTYPE") orelse environ.getPosix("LANG") orelse "C.UTF-8";
        const z = std.heap.c_allocator.dupeZ(u8, locale) catch return .{};
        defer std.heap.c_allocator.free(z);
        const table = c.xkb_compose_table_new_from_locale(context, z, c.XKB_COMPOSE_COMPILE_NO_FLAGS) orelse return .{};
        return .{ .table = table, .state = c.xkb_compose_state_new(table, c.XKB_COMPOSE_STATE_NO_FLAGS) };
    }
    pub fn deinit(self: *Compose) void {
        if (self.state) |s| c.xkb_compose_state_unref(s);
        if (self.table) |t| c.xkb_compose_table_unref(t);
    }
    pub fn reset(self: *Compose) void {
        if (self.state) |s| c.xkb_compose_state_reset(s);
    }
    /// null lets the ordinary XKB key through; empty text means composition is pending.
    pub fn feed(self: *Compose, sym: u32, buf: []u8) ?[]const u8 {
        const state = self.state orelse return null;
        _ = c.xkb_compose_state_feed(state, sym);
        switch (c.xkb_compose_state_get_status(state)) {
            c.XKB_COMPOSE_COMPOSING => return "",
            c.XKB_COMPOSE_COMPOSED => {
                const n = c.xkb_compose_state_get_utf8(state, buf.ptr, buf.len);
                c.xkb_compose_state_reset(state);
                return buf[0..@intCast(std.math.clamp(n, 0, @as(c_int, @intCast(buf.len - 1))))];
            },
            c.XKB_COMPOSE_CANCELLED => {
                c.xkb_compose_state_reset(state);
                return "";
            },
            else => return null,
        }
    }
};
