//! Bounded, time-based trail geometry, reusable by any point/edge/path emitter.
//! Samples use the caller's coordinate space; mesh() maps them into a scene node.
const std = @import("std");
pub const Preset = @import("config").effects.Preset;
pub const Point = struct { x: f32, y: f32 };
// Keep the moving history long; a stopped trail clears quickly from its tail.
pub const stop_fade_ms: u32 = 450;
const Sample = struct { p: Point, time: i64, travel: f32 };
pub const Mesh = extern struct {
    count: u32 = 0,
    vertices: [128][4]f32 = @splat(@splat(0)),
    color: [4]f32 = @splat(0),
    core_color: [4]f32 = @splat(0),
    edge: u32 = 0,
    fade: [2]f32 = .{ 1, 1 },
};
pub const Geometry = struct {
    mesh: Mesh = .{},
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 1,
    height: i32 = 1,

    /// Enclose every vertex (including the glow) before publishing damage.
    pub fn enclose(self: *Geometry) void {
        if (self.mesh.count == 0) return;
        var low: Point = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) };
        var high: Point = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32) };
        for (self.mesh.vertices[0..self.mesh.count]) |v| {
            low.x = @min(low.x, v[0]);
            low.y = @min(low.y, v[1]);
            high.x = @max(high.x, v[0]);
            high.y = @max(high.y, v[1]);
        }
        self.x = @intFromFloat(@floor(low.x) - 1);
        self.y = @intFromFloat(@floor(low.y) - 1);
        self.width = @intFromFloat(@ceil(high.x) + 1 - @as(f32, @floatFromInt(self.x)));
        self.height = @intFromFloat(@ceil(high.y) + 1 - @as(f32, @floatFromInt(self.y)));
        for (self.mesh.vertices[0..self.mesh.count]) |*v| {
            v[0] = (v[0] - @as(f32, @floatFromInt(self.x))) / @as(f32, @floatFromInt(self.width));
            v[1] = (v[1] - @as(f32, @floatFromInt(self.y))) / @as(f32, @floatFromInt(self.height));
        }
    }
};
pub const Path = struct {
    samples: [64]Sample = undefined,
    len: usize = 0,
    last: ?Point = null,
    travel: f32 = 0,
    flutter_phase: f32 = 0,
    flutter_tick: ?i64 = null,

    /// Advance the wind once per presented frame with real drag movement.
    /// Stationary frames remember the time without advancing the folds, so
    /// resuming does not jump through the paused interval.
    pub fn tickFlutter(self: *Path, now: i64, moving: bool) void {
        if (self.len < 2) {
            self.flutter_tick = null;
            return;
        }
        if (moving) if (self.flutter_tick) |last| {
            const elapsed: f32 = @floatFromInt(@max(0, now - last));
            // Both wave frequencies (1 and 1.7) repeat after 20 pi.
            self.flutter_phase = @mod(self.flutter_phase + elapsed * 0.004, 20 * std.math.pi);
        };
        self.flutter_tick = now;
    }

    pub fn push(self: *Path, p: Point, now: i64, preset: Preset) void {
        if (self.last) |last| {
            const distance = std.math.hypot(p.x - last.x, p.y - last.y);
            if (distance < 0.5) return;
            self.expire(now, preset.lifetime_ms);
            // Teleports and restored geometry must never make a screen-wide streak.
            if (distance > preset.max_length_px) {
                self.len = 0;
                self.travel = 0;
            } else self.travel += distance;
        }
        self.last = p;
        const cap: usize = switch (preset.quality) {
            .low => 16,
            .balanced => 32,
            .high => 64,
        };
        // Coalesce high-rate input into time buckets without extending the
        // history on a stationary pointer. Quality changes detail, not lifetime.
        // Reserve both endpoints so capacity does not discard a live tail.
        const quantum: i64 = @max(1, std.math.divCeil(i64, preset.lifetime_ms, @intCast(cap - 2)) catch unreachable);
        self.trimTime(now - preset.lifetime_ms);
        // Keep the first point: even a long-lived preset must start drawing on
        // the first motion rather than waiting for its next history bucket.
        if (self.len > 1 and @divFloor(self.samples[self.len - 1].time, quantum) == @divFloor(now, quantum)) self.len -= 1;
        if (self.len == cap) self.dropFirst();
        self.samples[self.len] = .{ .p = p, .time = now, .travel = self.travel };
        self.len += 1;
        var distance: f32 = 0;
        var i = self.len - 1;
        while (i > 0) {
            const segment = std.math.hypot(self.samples[i].p.x - self.samples[i - 1].p.x, self.samples[i].p.y - self.samples[i - 1].p.y);
            if (distance + segment >= preset.max_length_px) {
                self.startAt(i - 1, 1 - (preset.max_length_px - distance) / segment);
                break;
            }
            distance += segment;
            i -= 1;
        }
    }

    fn dropFirst(self: *Path) void {
        self.len -= 1;
        std.mem.copyForwards(Sample, self.samples[0..self.len], self.samples[1 .. self.len + 1]);
    }

    pub fn expire(self: *Path, now: i64, lifetime: u32) void {
        // At rest the whole shape stays fixed while its opacity fades. Dropping
        // individual samples here would shorten and re-shape a stationary tail.
        if (self.len > 0 and now - self.samples[self.len - 1].time >= @min(lifetime, stop_fade_ms)) self.* = .{};
    }

    fn trimTime(self: *Path, cutoff: i64) void {
        while (self.len > 1 and self.samples[1].time <= cutoff) self.dropFirst();
        if (self.len < 2 or self.samples[0].time >= cutoff) return;
        const a = self.samples[0].time;
        const b = self.samples[1].time;
        self.startAt(0, @as(f32, @floatFromInt(cutoff - a)) / @as(f32, @floatFromInt(b - a)));
    }

    fn startAt(self: *Path, index: usize, t: f32) void {
        const a = self.samples[index];
        const b = self.samples[index + 1];
        self.len -= index;
        std.mem.copyForwards(Sample, self.samples[0..self.len], self.samples[index .. index + self.len]);
        self.samples[0] = .{
            .p = .{ .x = a.p.x + (b.p.x - a.p.x) * t, .y = a.p.y + (b.p.y - a.p.y) * t },
            .time = a.time + @as(i64, @intFromFloat(@as(f32, @floatFromInt(b.time - a.time)) * t)),
            .travel = a.travel + (b.travel - a.travel) * t,
        };
    }

    pub fn mesh(self: *const Path, now: i64, preset: Preset, origin: Point, scale: f32, seed: f32, source_half: ?Point) Geometry {
        var result: Geometry = .{};
        if (self.len < 2 or scale <= 0) return result;
        result.mesh.color = preset.color;
        result.mesh.core_color = preset.core_color;
        result.mesh.color[3] *= preset.opacity;
        result.mesh.core_color[3] *= preset.opacity;
        const first = self.samples[0].time;
        const last = self.samples[self.len - 1].time;
        const lifetime: f32 = @floatFromInt(preset.lifetime_ms);
        const fade_time: f32 = @floatFromInt(@min(preset.lifetime_ms, stop_fade_ms));
        if (@as(f32, @floatFromInt(now - last)) >= fade_time) return .{};
        // x retains the history's tail opacity; y drives a tail-to-head wipe.
        result.mesh.fade = .{
            std.math.clamp(1 - @as(f32, @floatFromInt(now - first)) / lifetime, 0, 1),
            std.math.clamp(1 - @as(f32, @floatFromInt(now - last)) / fade_time, 0, 1),
        };
        const count: usize = switch (preset.quality) {
            .low => 16,
            .balanced => 48,
            .high => 63, // reserve the last pair for the head's soft cap
        };
        // Distance sampling keeps existing folds stable when a history bucket
        // gains a point; sample-count spacing used to redistribute every row.
        var lengths: [64]f32 = undefined;
        lengths[0] = 0;
        for (1..self.len) |i| {
            const a = self.samples[i - 1].p;
            const b = self.samples[i].p;
            lengths[i] = lengths[i - 1] + std.math.hypot(b.x - a.x, b.y - a.y);
        }
        const total = lengths[self.len - 1];
        if (total < 0.001) return .{};
        var index: usize = 0;
        for (0..count) |i| {
            const progress = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1));
            const along = progress * total;
            while (index + 2 < self.len and lengths[index + 1] < along) index += 1;
            const span = @max(0.001, lengths[index + 1] - lengths[index]);
            const t = std.math.clamp((along - lengths[index]) / span, 0, 1);
            const a = self.samples[index];
            const b = self.samples[index + 1];
            // Resample the path and its tangent, keeping both endpoints exact.
            // Chord-length tangents handle uneven input spacing without the
            // overshoot caused by treating a short segment like a long one.
            const before = self.samples[index -| 1].p;
            const after = self.samples[@min(index + 2, self.len - 1)].p;
            const before_span = span / @max(0.001, lengths[index + 1] - lengths[index -| 1]);
            const after_span = span / @max(0.001, lengths[@min(index + 2, self.len - 1)] - lengths[index]);
            const x_curve = curve(a.p.x, b.p.x, (b.p.x - before.x) * before_span, (after.x - a.p.x) * after_span, t);
            const y_curve = curve(a.p.y, b.p.y, (b.p.y - before.y) * before_span, (after.y - a.p.y) * after_span, t);
            const point: Point = .{ .x = x_curve[0], .y = y_curve[0] };
            const dx = x_curve[1];
            const dy = y_curve[1];
            const length = @max(0.001, std.math.hypot(dx, dy));
            const nx = -dy / length;
            const ny = dx / length;
            // Material coordinates depend on distance, not current age.
            // Fading cannot collapse the two sources or slide the merge point.
            // Wind advances independently of drag distance. The material
            // coordinate keeps the spatial folds stable as history changes.
            const travel = a.travel + (b.travel - a.travel) * t;
            const phase = self.flutter_phase + travel * 0.02 + seed;
            const wave = (@sin(phase) + 0.3 * @sin(phase * 1.7 + seed)) * preset.width_px * 2 * preset.turbulence * (1 - progress);
            const half = preset.width_px * (0.65 + 0.35 * progress);
            const sources = source_half orelse Point{ .x = nx * preset.width_px * source_across, .y = ny * preset.width_px * source_across };
            const attach = std.math.clamp((progress - 0.65) / 0.35, 0, 1);
            const blend = attach * attach * (3 - 2 * attach);
            // At the head, the two bright creases land exactly on the source
            // points even when the motion tangent differs from the window edge.
            const hx = nx * half * (1 - blend) + sources.x / source_across * blend;
            const hy = ny * half * (1 - blend) + sources.y / source_across * blend;
            for (0..2) |side| {
                const across: f32 = if (side == 0) -1 else 1;
                const x = (point.x - origin.x + nx * wave + across * hx) / scale;
                const y = (point.y - origin.y + ny * wave + across * hy) / scale;
                result.mesh.vertices[i * 2 + side] = .{ x, y, across, progress };
            }
            if (i + 1 == count) {
                // A diagonal source pair straddles a corner, exposing the end
                // of the glow outside the frame. Extend it along the tangent
                // and fade this cap rather than leaving a straight cut there.
                const cap = @min(24, preset.width_px * 0.4) / scale;
                for (0..2) |side| {
                    var v = result.mesh.vertices[i * 2 + side];
                    v[0] += dx / length * cap;
                    v[1] += dy / length * cap;
                    v[3] = 2;
                    result.mesh.vertices[count * 2 + side] = v;
                }
            }
        }
        result.mesh.count = @intCast((count + 1) * 2);
        result.enclose();
        return result;
    }
};

// Keep in step with the two source creases in scene_pass_ribbon.c.
pub const source_across: f32 = 0.55;

/// Hermite position and derivative with chord-length tangents.
fn curve(b: f32, c: f32, v: f32, w: f32, t: f32) [2]f32 {
    const p = 3 * (c - b) - 2 * v - w;
    const q = 2 * (b - c) + v + w;
    return .{ b + t * (v + t * (p + t * q)), v + t * (2 * p + 3 * t * q) };
}

test {
    _ = @import("ribbon_tests.zig");
}
