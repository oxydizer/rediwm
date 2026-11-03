//! Optional visual effects. Appearance presets are independent of their users.
const std = @import("std");
const theme = @import("ui").theme;
const fields = @import("loader_fields.zig");

pub const Quality = enum { low, balanced, high };
pub const Preset = struct {
    color: [4]f32 = .{ 1, 24.0 / 255.0, 32.0 / 255.0, 1 },
    core_color: [4]f32 = .{ 1, 224.0 / 255.0, 192.0 / 255.0, 1 },
    opacity: f32 = 0.9,
    width_px: f32 = 56,
    max_length_px: f32 = 420,
    lifetime_ms: u32 = 3000,
    turbulence: f32 = 0.3,
    quality: Quality = .balanced,
};
pub const NamedPreset = struct { name: []const u8, value: Preset = .{} };
pub const Binding = struct { enabled: bool = false, preset: []const u8 = "soft_flame" };
pub const Target = enum { window_move, window_minimize, window_resize };
pub const Config = struct {
    window_move: Binding = .{},
    window_minimize: ?Binding = null,
    window_resize: ?Binding = null,
    presets: std.ArrayListUnmanaged(NamedPreset) = .empty,

    pub fn minimize(self: Config) Binding {
        return self.window_minimize orelse self.window_move;
    }

    pub fn resize(self: Config) Binding {
        return self.window_resize orelse self.window_move;
    }

    /// The settings toggles: they are independent, so turning one on or off must
    /// not drag along a binding that was only following `window_move`. Those keep
    /// the look they have now and are returned so the caller can persist them.
    pub const Pinned = struct { window_minimize: bool = false, window_resize: bool = false };

    pub fn setEnabled(self: *Config, kind: Target, on: bool) Pinned {
        const was_minimize = self.minimize();
        const was_resize = self.resize();
        var pinned: Pinned = .{};
        switch (kind) {
            .window_move => self.window_move.enabled = on,
            .window_minimize => {
                pinned.window_minimize = self.window_minimize == null;
                self.window_minimize = .{ .enabled = on, .preset = was_minimize.preset };
            },
            .window_resize => {
                pinned.window_resize = self.window_resize == null;
                self.window_resize = .{ .enabled = on, .preset = was_resize.preset };
            },
        }
        if (kind == .window_move) {
            if (self.window_minimize == null) {
                self.window_minimize = was_minimize;
                pinned.window_minimize = true;
            }
            if (self.window_resize == null) {
                self.window_resize = was_resize;
                pinned.window_resize = true;
            }
        }
        return pinned;
    }

    pub fn find(self: Config, name: []const u8) ?Preset {
        for (self.presets.items) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return if (std.mem.eql(u8, name, "soft_flame")) .{} else null;
    }

    pub fn validate(self: Config) !void {
        if (self.find(self.window_move.preset) == null) return error.InvalidConfig;
        if (self.find(self.minimize().preset) == null) return error.InvalidConfig;
        if (self.find(self.resize().preset) == null) return error.InvalidConfig;
    }

    pub fn binding(self: *Config, a: std.mem.Allocator, kind: Target, key: []const u8, value: []const u8) !void {
        const target = switch (kind) {
            .window_move => &self.window_move,
            .window_minimize => blk: {
                if (self.window_minimize == null) self.window_minimize = .{};
                break :blk &self.window_minimize.?;
            },
            .window_resize => blk: {
                if (self.window_resize == null) self.window_resize = .{};
                break :blk &self.window_resize.?;
            },
        };
        if (std.mem.eql(u8, key, "enabled")) {
            target.enabled = try fields.parseBool(value);
        } else if (std.mem.eql(u8, key, "preset")) {
            target.preset = try a.dupe(u8, try theme.unquote(value));
        } else return error.InvalidConfig;
    }

    pub fn declare(self: *Config, a: std.mem.Allocator, name: []const u8) !void {
        if (name.len == 0 or name.len > 64 or self.presets.items.len >= 32) return error.InvalidConfig;
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidConfig;
        for (self.presets.items) |p| if (std.mem.eql(u8, p.name, name)) return error.InvalidConfig;
        try self.presets.append(a, .{ .name = try a.dupe(u8, name) });
    }

    pub fn apply(self: *Config, key: []const u8, value: []const u8) !void {
        const p = &self.presets.items[self.presets.items.len - 1].value;
        if (std.mem.eql(u8, key, "type")) {
            if (!std.mem.eql(u8, try theme.unquote(value), "flame_ribbon")) return error.InvalidConfig;
        } else if (std.mem.eql(u8, key, "color")) {
            p.color = try theme.parseColor(try theme.unquote(value));
        } else if (std.mem.eql(u8, key, "core_color")) {
            p.core_color = try theme.parseColor(try theme.unquote(value));
        } else if (std.mem.eql(u8, key, "quality")) {
            p.quality = std.meta.stringToEnum(Quality, try theme.unquote(value)) orelse return error.InvalidConfig;
        } else if (std.mem.eql(u8, key, "lifetime_ms")) {
            p.lifetime_ms = std.fmt.parseInt(u32, value, 10) catch return error.InvalidConfig;
            if (p.lifetime_ms < 50 or p.lifetime_ms > 10000) return error.InvalidConfig;
        } else {
            const v = std.fmt.parseFloat(f32, value) catch return error.InvalidConfig;
            if (!std.math.isFinite(v)) return error.InvalidConfig;
            if (std.mem.eql(u8, key, "opacity")) {
                if (v < 0 or v > 1) return error.InvalidConfig;
                p.opacity = v;
            } else if (std.mem.eql(u8, key, "width_px")) {
                if (v < 1 or v > 128) return error.InvalidConfig;
                p.width_px = v;
            } else if (std.mem.eql(u8, key, "max_length_px")) {
                if (v < 8 or v > 1024) return error.InvalidConfig;
                p.max_length_px = v;
            } else if (std.mem.eql(u8, key, "turbulence")) {
                if (v < 0 or v > 1) return error.InvalidConfig;
                p.turbulence = v;
            } else return error.InvalidConfig;
        }
    }
};
