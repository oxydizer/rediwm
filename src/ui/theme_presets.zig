//! Embedded fallback packs. Filesystem discovery and metadata parsing live
//! in config/theme_pack.zig, keeping shared UI independent of configuration.

pub const Preset = struct {
    id: []const u8 = "",
    name: []const u8,
    bytes: []const u8,
};

pub const bundled = [_]Preset{
    .{ .id = "rediwm-dark", .name = "RediWM Dark", .bytes = @embedFile("theme-rediwm-dark") },
    .{ .id = "rediwm-light", .name = "RediWM Light", .bytes = @embedFile("theme-rediwm-light") },
    .{ .id = "redi-blue", .name = "Redi Blue", .bytes = @embedFile("theme-redi-blue") },
    .{ .id = "redi-mocha", .name = "Redi-Mocha", .bytes = @embedFile("theme-redi-mocha") },
    // Hidden from the picker until the theme is ready.
    // .{ .id = "chamfer-blue", .name = "Chamfer Blue", .bytes = @embedFile("theme-chamfer-blue") },
    .{ .id = "gold", .name = "Gold", .bytes = @embedFile("theme-gold") },
    .{ .id = "blackout", .name = "Blackout", .bytes = @embedFile("theme-blackout") },
};
