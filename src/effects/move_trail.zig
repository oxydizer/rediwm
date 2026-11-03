//! A faint sheet joining the two drag flames, sharing their folds and fade.
const ribbon = @import("ribbon.zig");

pub fn between(trails: *const [2]ribbon.Geometry) ribbon.Geometry {
    const count = trails[0].mesh.count;
    if (count < 4 or count != trails[1].mesh.count) return .{};
    var result: ribbon.Geometry = .{};
    result.mesh = .{
        .count = count,
        .edge = 4,
        .color = trails[0].mesh.color,
        .core_color = trails[0].mesh.core_color,
        .fade = trails[0].mesh.fade,
    };
    // Both paths use the same history and row count. Join their row centres
    // in host coordinates so the sheet follows turns, flutter and soft caps.
    var row: usize = 0;
    while (row < count) : (row += 2) {
        for (trails, 0..) |*trail, side| {
            const a = trail.mesh.vertices[row];
            const b = trail.mesh.vertices[row + 1];
            result.mesh.vertices[row + side] = .{
                @as(f32, @floatFromInt(trail.x)) + (a[0] + b[0]) * 0.5 * @as(f32, @floatFromInt(trail.width)),
                @as(f32, @floatFromInt(trail.y)) + (a[1] + b[1]) * 0.5 * @as(f32, @floatFromInt(trail.height)),
                if (side == 0) -1 else 1,
                a[3],
            };
        }
    }
    result.enclose();
    return result;
}
