// Shared animation primitive. Every curve is sampled analytically at a
// timestamp (never integrated per frame): multi-output ticks, pinned-clock
// tests (`setNowMs`) and dropped frames are all the same `x(t)`.
//
// Models:
// - `.duration` — today's ease over a fixed ms window (`out_cubic`, `flip_bezier`).
// - `.spring` — damped harmonic oscillator (libadwaita / RBBAnimation closed form).
//   Parameterised by damping ratio, not raw damping. Velocity is the analytic
//   derivative so a retarget continues from the current speed.
// - `.decay` — exponential fling (`x(t) = from + (v0/coeff)·(e^{coeff·t} − 1)`).
// - `.off` — jump to the target and settle now.
// Rubber-band resistance is a pure function of overshoot, not a curve: apply
// it while a gesture is held, then retarget a spring or decay on release.
//
// `settled()` compares `now` against a settle duration stored at retarget;
// it must not re-derive remaining time from a clock that may be pinned.
// `sampleChanged` answers "did the picture change?"; `settled` answers
// "should I keep waking up?".
const std = @import("std");

pub const Ease = enum { out_cubic, flip_bezier };

pub const Spring = struct {
    damping_ratio: f32 = 1.0,
    stiffness: f32 = 800,
    epsilon: f32 = 0.0001,
};

/// Compiled-in defaults from plan-physics-animation.md §7. Stage 4 overlays
/// per-target config on top of these.
pub const springs = struct {
    pub const panel_slide = Spring{ .damping_ratio = 1.0, .stiffness = 900, .epsilon = 1e-4 };
    pub const taskbar_hover = Spring{ .damping_ratio = 1.0, .stiffness = 1400, .epsilon = 1e-3 };
    pub const start_button = taskbar_hover;
    pub const titlebar_hover = taskbar_hover;
    // The window-button chip trails the pointer: critically damped so it
    // glides without overshoot, ~180 ms to cover most of a button pitch.
    pub const titlebar_chip = Spring{ .damping_ratio = 1.0, .stiffness = 450, .epsilon = 1e-3 };
    pub const titlebar_chip_fade = Spring{ .damping_ratio = 1.0, .stiffness = 700, .epsilon = 1e-3 };
    // Start menu list highlight (and Files' sidebar and list, `ui/hover_glide.zig`):
    // same feel as the window-button chip.
    pub const start_glide = titlebar_chip;
    pub const start_glide_fade = titlebar_chip_fade;
    pub const taskbar_flip = Spring{ .damping_ratio = 0.9, .stiffness = 700, .epsilon = 1e-3 };
    pub const toast_flip = taskbar_flip;
    pub const switcher_scroll = Spring{ .damping_ratio = 1.0, .stiffness = 1000, .epsilon = 1e-3 };
    // ~90% of a notch within ~140 ms, settled by ~250 ms: close to a
    // browser's wheel smoothing, so the shell and clients feel alike.
    pub const wheel_scroll = Spring{ .damping_ratio = 1.0, .stiffness = 800, .epsilon = 1e-3 };
    pub const osd_level = Spring{ .damping_ratio = 1.0, .stiffness = 1200, .epsilon = 1e-3 };
    pub const toast_slide = Spring{ .damping_ratio = 0.8, .stiffness = 600, .epsilon = 1e-3 };
    pub const window_open = Spring{ .damping_ratio = 0.85, .stiffness = 700, .epsilon = 1e-4 };
    pub const window_move = Spring{ .damping_ratio = 1.0, .stiffness = 800, .epsilon = 1e-4 };
    pub const window_peek = Spring{ .damping_ratio = 1.0, .stiffness = 1000, .epsilon = 1e-3 };
    pub const camera_pan = Spring{ .damping_ratio = 1.0, .stiffness = 500, .epsilon = 0.5 };
    pub const camera_zoom = Spring{ .damping_ratio = 1.0, .stiffness = 600, .epsilon = 1e-3 };
    pub const camera_reveal = Spring{ .damping_ratio = 1.0, .stiffness = 450, .epsilon = 0.5 };
};

pub const ReducedMotion = enum { auto, on, off };

/// `[compositor] desktop_switch_ms` default.
pub const default_desktop_switch_ms: u32 = 220;

/// Keyboard desktop switches move immediately, then ease into the destination.
pub fn desktopSwitchCurve(ms: u32) Curve {
    return .{ .duration = .{ .ms = ms, .ease = .out_cubic } };
}

/// One row in `[animations.<name>]`. Lookup is "table entry, else this default".
pub const Target = enum {
    panel_slide,
    panel_scrim,
    taskbar_hover,
    taskbar_press,
    taskbar_flip,
    start_button,
    switcher_scroll,
    wheel_scroll,
    osd_level,
    toast_slide,
    toast_flip,
    titlebar_hover,
    titlebar_chip,
    titlebar_chip_fade,
    start_glide,
    start_glide_fade,
    window_open,
    window_close,
    window_move,
    window_resize,
    window_zoom,
    window_peek,
    camera_pan,
    camera_zoom,
    camera_reveal,
    camera_desktop,

    pub const count = std.meta.tags(Target).len;

    pub fn parse(name: []const u8) ?Target {
        inline for (std.meta.tags(Target)) |tag| {
            if (std.mem.eql(u8, name, @tagName(tag))) return tag;
        }
        return null;
    }
};

pub const TargetSpec = struct {
    curve: Curve,
    decay: Decay = .{},

    pub fn eql(a: TargetSpec, b: TargetSpec) bool {
        return curveEql(a.curve, b.curve) and a.decay.rate == b.decay.rate and a.decay.threshold == b.decay.threshold;
    }
};

/// Process-wide overlay applied at sample/retarget time. Copy-safe; no pointers.
pub const Settings = struct {
    enabled: bool = true,
    speed: f32 = 1.0,
    reduced_motion: ReducedMotion = .auto,
    targets: [Target.count]TargetSpec = defaultTargets(),

    pub fn eql(a: Settings, b: Settings) bool {
        if (a.enabled != b.enabled or a.speed != b.speed or a.reduced_motion != b.reduced_motion) return false;
        for (a.targets, b.targets) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

pub fn defaultSpec(target: Target) TargetSpec {
    return switch (target) {
        .panel_slide, .panel_scrim => .{ .curve = .{ .spring = springs.panel_slide } },
        .taskbar_hover, .start_button, .titlebar_hover => .{ .curve = .{ .spring = springs.taskbar_hover } },
        .titlebar_chip => .{ .curve = .{ .spring = springs.titlebar_chip } },
        .titlebar_chip_fade => .{ .curve = .{ .spring = springs.titlebar_chip_fade } },
        .start_glide => .{ .curve = .{ .spring = springs.start_glide } },
        .start_glide_fade => .{ .curve = .{ .spring = springs.start_glide_fade } },
        .taskbar_press => .{ .curve = .{ .duration = .{ .ms = 90, .ease = .out_cubic } } },
        .taskbar_flip, .toast_flip => .{ .curve = .{ .spring = springs.taskbar_flip } },
        .switcher_scroll => .{ .curve = .{ .spring = springs.switcher_scroll } },
        .wheel_scroll => .{ .curve = .{ .spring = springs.wheel_scroll } },
        .osd_level => .{ .curve = .{ .spring = springs.osd_level } },
        .toast_slide => .{ .curve = .{ .spring = springs.toast_slide } },
        .window_open, .window_close => .{ .curve = .{ .spring = springs.window_open } },
        .window_move, .window_resize => .{ .curve = .{ .spring = springs.window_move } },
        // Still duration in the adopted UI; config can overlay a spring.
        .window_zoom => .{ .curve = .{ .duration = .{ .ms = 160, .ease = .out_cubic } } },
        .window_peek => .{ .curve = .{ .duration = .{ .ms = 150, .ease = .out_cubic } } },
        .camera_pan => .{ .curve = .{ .duration = .{ .ms = 160, .ease = .out_cubic } }, .decay = .{ .rate = 0.998, .threshold = 0.5 } },
        .camera_zoom => .{ .curve = .{ .spring = springs.camera_zoom } },
        .camera_reveal => .{ .curve = .{ .duration = .{ .ms = 320, .ease = .out_cubic } } },
        .camera_desktop => .{ .curve = desktopSwitchCurve(default_desktop_switch_ms) },
    };
}

pub fn defaultTargets() [Target.count]TargetSpec {
    var t: [Target.count]TargetSpec = undefined;
    inline for (std.meta.tags(Target)) |tag| {
        t[@intFromEnum(tag)] = defaultSpec(tag);
    }
    return t;
}

/// ε is in the target's own units (opacity fraction vs camera pixels).
pub fn epsilonBounds(target: Target) struct { min: f32, max: f32 } {
    return switch (target) {
        .camera_pan, .camera_reveal, .camera_desktop => .{ .min = 0.05, .max = 16 },
        .camera_zoom => .{ .min = 1e-4, .max = 0.5 },
        else => .{ .min = 1e-6, .max = 1 },
    };
}

pub fn curveEql(a: Curve, b: Curve) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .off => true,
        .duration => |d| d.ms == b.duration.ms and d.ease == b.duration.ease,
        .spring => |s| s.damping_ratio == b.spring.damping_ratio and s.stiffness == b.spring.stiffness and s.epsilon == b.spring.epsilon,
        .decay => |d| d.rate == b.decay.rate and d.threshold == b.decay.threshold,
    };
}

/// 1/255 of an 0–1 channel, for colour/opacity dirty checks.
pub const quantum_alpha: f32 = 1.0 / 255.0;
/// One logical pixel, for offsets and FLIP.
pub const quantum_px: f32 = 1.0;

/// Per-output CPU pressure, with hysteresis so one fast frame cannot undo
/// degradation. Refresh is in mHz; unknown modes use a 60 Hz budget.
pub const FrameBudget = struct {
    long_frames: u8 = 0,
    good_frames: u8 = 0,
    coarse: bool = false,

    pub fn record(self: *FrameBudget, cpu_ns: u64, refresh: i32) void {
        const budget: u64 = 1_000_000_000_000 / @as(u64, @intCast(if (refresh > 0) refresh else 60_000));
        if (cpu_ns > budget) {
            self.good_frames = 0;
            self.long_frames = @min(self.long_frames + 1, 3);
            if (self.long_frames == 3) self.coarse = true;
        } else {
            self.long_frames = 0;
            self.good_frames = @min(self.good_frames + 1, 3);
            if (self.good_frames == 3) self.coarse = false;
        }
    }
};

var raster_step: f32 = 1;
var sampling_clock: ?*const fn () u64 = null;
var sampling_ns: u64 = 0;

/// Scope these settings to an output frame; event/IPC sampling is unmeasured.
pub fn beginFrame(coarse: bool, clock: *const fn () u64) void {
    raster_step = if (coarse) 2 else 1;
    sampling_clock = clock;
    sampling_ns = 0;
}

pub fn endFrame() u64 {
    sampling_clock = null;
    raster_step = 1;
    return sampling_ns;
}

pub fn rasterPixelQuantum(scale: f32) f32 {
    return raster_step / @max(scale, 0.01);
}

/// Colours have channel steps, not a spatial extent.
pub fn rasterAlphaQuantum() f32 {
    return raster_step * quantum_alpha;
}

test "frame pressure is consecutive, per output and refresh aware" {
    var slow: FrameBudget = .{};
    var fast: FrameBudget = .{};
    for (0..2) |_| {
        slow.record(8_000_000, 144_000);
        fast.record(8_000_000, 60_000);
    }
    try std.testing.expect(!slow.coarse);
    slow.record(8_000_000, 144_000);
    try std.testing.expect(slow.coarse);
    try std.testing.expect(!fast.coarse);
    for (0..2) |_| slow.record(1_000_000, 144_000);
    try std.testing.expect(slow.coarse);
    slow.record(1_000_000, 144_000);
    try std.testing.expect(!slow.coarse);
    for (0..6) |i| slow.record(if (i % 2 == 0) 20_000_000 else 1, 0);
    try std.testing.expect(!slow.coarse);
}

test "raster degradation preserves sampling and settlement, and publishes endpoint" {
    resetGlobals();
    defer resetGlobals();
    const Clock = struct {
        fn read() u64 {
            return 0;
        }
    };
    var a = Anim.initDuration(0, 1, 0, 100, .out_cubic);
    const before = a.value(50);
    beginFrame(true, Clock.read);
    defer _ = endFrame();
    try std.testing.expectEqual(@as(f32, 2), rasterPixelQuantum(1));
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 1.5), rasterPixelQuantum(1.5), 0.0001);
    try std.testing.expectEqual(before, a.value(50));
    try std.testing.expect(!a.settled(99));
    try std.testing.expect(a.settled(100));
    try std.testing.expect(a.sampleChanged(99, 1));
    try std.testing.expect(!a.sampleChanged(99, 1));
    try std.testing.expect(a.sampleChanged(100, 1));
    try std.testing.expect(!a.sampleChanged(100, 1));
    try std.testing.expect(!a.sampleChanged(100, 2.0 / 255.0));
}

test "sampling timer excludes work between samples and outside frames" {
    const Clock = struct {
        var ns: u64 = 0;
        fn read() u64 {
            ns += 10;
            return ns;
        }
    };
    Clock.ns = 0;
    const a = Anim.initDuration(0, 1, 0, 100, .out_cubic);
    beginFrame(false, Clock.read);
    _ = a.value(20);
    Clock.ns += 1_000_000; // Raster work between samples.
    _ = a.velocity(20);
    try std.testing.expectEqual(@as(u64, 20), endFrame());
    _ = a.value(30);
    try std.testing.expectEqual(@as(u64, 20), endFrame());
    try std.testing.expectEqual(@as(f32, 1), rasterPixelQuantum(1));
}
/// Opening windows scale up from this fraction of their rest size.
pub const window_open_scale: f32 = 0.92;

pub fn windowMapScale(amount: f32) f32 {
    return window_open_scale + (1.0 - window_open_scale) * amount;
}

pub const Decay = struct {
    rate: f32 = 0.998,
    threshold: f32 = 0.5,
};

pub const Curve = union(enum) {
    off,
    duration: struct { ms: i64, ease: Ease },
    spring: Spring,
    decay: Decay,
};

/// Distinguishes motion from opacity so `reduced_motion` can keep a short
/// cross-fade while turning every other curve into `.off`.
pub const Property = enum { motion, opacity };

pub const reduced_opacity_ms: i64 = 120;
pub const rubber_c: f32 = 0.55;

pub const Anim = struct {
    from: f32 = 0,
    to: f32 = 0,
    v0: f32 = 0,
    start_ms: i64 = 0,
    settle_ms: i64 = 0,
    clamped_ms: i64 = 0,
    curve: Curve = .{ .duration = .{ .ms = 0, .ease = .out_cubic } },
    property: Property = .motion,
    last_quantised: f32 = std.math.nan(f32),
    last_sample_settled: bool = true,

    pub fn initDuration(from: f32, to: f32, start_ms: i64, duration_ms: i64, ease: Ease) Anim {
        return initCurve(from, to, start_ms, .{ .duration = .{ .ms = @max(duration_ms, 0), .ease = ease } });
    }

    pub fn initCurve(from: f32, to: f32, start_ms: i64, curve: Curve) Anim {
        var a: Anim = .{
            .from = from,
            .to = to,
            .start_ms = start_ms,
        };
        a.installCurve(curve);
        return a;
    }

    /// Retargets toward `target`, starting from wherever the animation
    /// currently is (so an in-flight transition reverses smoothly instead of
    /// snapping). A no-op if already animating toward the same target with
    /// the same duration curve.
    pub fn retarget(self: *Anim, now_ms: i64, target: f32, duration_ms: i64, ease: Ease) void {
        self.retargetTo(now_ms, target, .{ .duration = .{ .ms = duration_ms, .ease = ease } });
    }

    pub fn retargetTo(self: *Anim, now_ms: i64, target: f32, curve: Curve) void {
        self.retargetWith(now_ms, target, curve, 0);
    }

    /// Like `retargetTo`, but *adds* an externally measured velocity (gesture
    /// release). The addition is divided by the global speed so a fling still
    /// covers the same distance when the clock is scaled.
    pub fn retargetWith(self: *Anim, now_ms: i64, target: f32, curve: Curve, add_velocity: f32) void {
        // `active()` is the old `duration_ms > 0` sentinel: same-target
        // retargets after settle (caret, OSD) must not restart the curve.
        if (add_velocity == 0 and self.to == target and self.active()) {
            return;
        }
        const from = self.value(now_ms);
        const sampled_v = self.velocity(now_ms);
        const rate = @max(speed_g, 0.001);
        const v0 = sampled_v + add_velocity / rate;
        self.commit(now_ms, from, target, v0, curve);
    }

    /// Install a new curve from an already-sampled `(from, to, v0)`. Used
    /// when config hot-reloads: the same-target no-op in `retargetWith`
    /// would otherwise ignore a stiffness change.
    pub fn continueFrom(self: *Anim, now_ms: i64, from: f32, to: f32, v0: f32, curve: Curve) void {
        self.commit(now_ms, from, to, v0, curve);
    }

    /// A one-shot pulse that starts already displaced and eases back to rest,
    /// for feedback with no natural "end" event to retarget from (e.g. a
    /// press that never gets a matching release routed back to it).
    pub fn pulse(self: *Anim, now_ms: i64, from: f32, to: f32, duration_ms: i64) void {
        self.pulseTo(now_ms, from, to, .{ .duration = .{ .ms = duration_ms, .ease = .out_cubic } });
    }

    pub fn pulseTo(self: *Anim, now_ms: i64, from: f32, to: f32, curve: Curve) void {
        const property = self.property;
        self.* = .{
            .from = from,
            .to = to,
            .start_ms = now_ms,
            .property = property,
        };
        self.installCurve(curve);
    }

    pub fn value(self: Anim, now_ms: i64) f32 {
        return self.sample(now_ms).value;
    }

    pub fn velocity(self: Anim, now_ms: i64) f32 {
        return self.sample(now_ms).velocity;
    }

    pub fn settled(self: Anim, now_ms: i64) bool {
        if (self.completesInstantly()) return true;
        if (reduced_motion_g and self.property == .opacity) {
            return self.elapsedEffective(now_ms) >= @as(f64, @floatFromInt(reduced_opacity_ms));
        }
        if (speed_g == 1.0) return now_ms - self.start_ms >= self.settle_ms;
        return self.elapsedEffective(now_ms) >= @as(f64, @floatFromInt(self.settle_ms));
    }

    pub fn arrived(self: Anim, now_ms: i64) bool {
        if (self.completesInstantly()) return true;
        if (reduced_motion_g and self.property == .opacity) {
            return self.elapsedEffective(now_ms) >= @as(f64, @floatFromInt(reduced_opacity_ms));
        }
        if (speed_g == 1.0) return now_ms - self.start_ms >= self.clamped_ms;
        return self.elapsedEffective(now_ms) >= @as(f64, @floatFromInt(self.clamped_ms));
    }

    /// True while a non-idle curve is installed. Replaces the
    /// `duration_ms > 0` sentinel; stays true after `settled()` until
    /// `cancel()` (or a struct overwrite) so existing "is a zoom in flight"
    /// checks keep working.
    pub fn active(self: Anim) bool {
        return switch (self.curve) {
            .off => false,
            .duration => |d| d.ms > 0,
            .spring, .decay => self.settle_ms > 0,
        };
    }

    pub fn cancel(self: *Anim, value_: f32) void {
        self.* = .{
            .from = value_,
            .to = value_,
            .property = self.property,
        };
    }

    pub fn restingValue(self: Anim) f32 {
        return switch (self.curve) {
            .decay => |d| decayResting(self.from, self.v0, d.rate),
            else => self.to,
        };
    }

    pub fn curveName(self: Anim) []const u8 {
        return switch (self.curve) {
            .off => "off",
            .duration => "duration",
            .spring => "spring",
            .decay => "decay",
        };
    }

    /// Rounds this frame's sample to `quantum` (1 device pixel, 1/255 of an
    /// alpha step, one zoom percent) and reports whether it differs from the
    /// last call's rounded value. Answers "did the picture change";
    /// `settled()` separately answers "should I keep waking up". Never call
    /// it twice per frame for the same Anim — it mutates `last_quantised`.
    pub fn sampleChanged(self: *Anim, now_ms: i64, quantum: f32) bool {
        const q: f32 = if (quantum > 0) quantum else 1;
        const done = self.settled(now_ms);
        const sampled = self.value(now_ms);
        // Resting values must not change buckets when another output uses a
        // different quantum, or idle multi-output frames would repaint forever.
        const rounded = if (done) sampled else @round(sampled / q) * q;
        const prev = self.last_quantised;
        self.last_quantised = rounded;
        const finished = done and !self.last_sample_settled;
        self.last_sample_settled = done;
        if (!done) {
            observe_active = true;
            const elapsed = now_ms - self.start_ms;
            if (elapsed > observe_longest_ms) observe_longest_ms = elapsed;
        }
        // A quantised tail may already occupy the target bucket while its
        // painted sample still differs. Always publish the exact endpoint.
        const changed = finished or std.math.isNan(prev) or rounded != prev;
        if (changed) observe_changed = true;
        return changed;
    }

    fn commit(self: *Anim, now_ms: i64, from: f32, to: f32, v0: f32, curve: Curve) void {
        self.from = from;
        self.to = to;
        self.v0 = v0;
        self.start_ms = now_ms;
        self.last_quantised = std.math.nan(f32);
        self.installCurve(curve);
    }

    fn installCurve(self: *Anim, curve: Curve) void {
        if (curve == .decay) {
            self.to = decayResting(self.from, self.v0, curve.decay.rate);
        }
        self.curve = curve;
        const times = computeSettle(self.from, self.to, self.v0, curve);
        self.settle_ms = times.settle;
        self.clamped_ms = times.clamped;
    }

    fn completesInstantly(self: Anim) bool {
        if (!enabled_g or speed_g <= 0) return true;
        if (reduced_motion_g and self.property != .opacity) return true;
        return switch (self.curve) {
            .off => true,
            .duration => |d| d.ms <= 0,
            .spring, .decay => self.settle_ms <= 0,
        };
    }

    fn elapsedEffective(self: Anim, now_ms: i64) f64 {
        const raw = @as(f64, @floatFromInt(now_ms - self.start_ms));
        if (raw <= 0) return 0;
        if (speed_g == 1.0) return raw;
        return raw * @as(f64, speed_g);
    }

    const Sample = struct { value: f32, velocity: f32 };

    fn sample(self: Anim, now_ms: i64) Sample {
        const clock = sampling_clock;
        const started = if (clock) |read| read() else 0;
        defer if (clock) |read| {
            sampling_ns +|= read() -% started;
        };
        if (self.completesInstantly()) return .{ .value = self.to, .velocity = 0 };
        if (reduced_motion_g and self.property == .opacity) {
            return sampleDuration(self.from, self.to, self.elapsedEffective(now_ms), reduced_opacity_ms, .out_cubic);
        }
        const elapsed = self.elapsedEffective(now_ms);
        if (elapsed <= 0) {
            return switch (self.curve) {
                .duration => |d| sampleDuration(self.from, self.to, 0, d.ms, d.ease),
                else => .{ .value = self.from, .velocity = self.v0 },
            };
        }
        if (elapsed >= @as(f64, @floatFromInt(self.settle_ms))) {
            return .{ .value = self.to, .velocity = 0 };
        }
        return switch (self.curve) {
            .off => .{ .value = self.to, .velocity = 0 },
            .duration => |d| sampleDuration(self.from, self.to, elapsed, d.ms, d.ease),
            .spring => |s| sampleSpring(self.from, self.to, self.v0, s, elapsed / 1000.0),
            .decay => |d| sampleDecay(self.from, self.v0, d, elapsed / 1000.0),
        };
    }
};

pub const VelocityTracker = struct {
    const cap = 32;
    const Sample = struct { time_ms: i64, position: f32 };

    samples: [cap]Sample = undefined,
    head: u8 = 0,
    count: u8 = 0,

    pub fn reset(self: *VelocityTracker) void {
        self.head = 0;
        self.count = 0;
    }

    pub fn push(self: *VelocityTracker, time_ms: i64, position: f32) void {
        if (self.count == cap) {
            self.head = @intCast((@as(usize, self.head) + 1) % cap);
            self.count -= 1;
        }
        const i = (@as(usize, self.head) + @as(usize, self.count)) % cap;
        self.samples[i] = .{ .time_ms = time_ms, .position = position };
        self.count += 1;
        self.dropOlderThan(time_ms, 100);
    }

    pub fn velocity(self: VelocityTracker, now_ms: i64) f32 {
        var n: usize = 0;
        var t0: i64 = 0;
        var sum_t: f64 = 0;
        var sum_x: f64 = 0;
        var sum_tt: f64 = 0;
        var sum_tx: f64 = 0;
        var last_ms: i64 = 0;

        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const s = self.at(i);
            if (now_ms - s.time_ms > 100) continue;
            if (n == 0) t0 = s.time_ms;
            const t = @as(f64, @floatFromInt(s.time_ms - t0)) / 1000.0;
            const x: f64 = s.position;
            sum_t += t;
            sum_x += x;
            sum_tt += t * t;
            sum_tx += t * x;
            last_ms = s.time_ms;
            n += 1;
        }
        if (n < 2) return 0;
        if (now_ms - last_ms > 50) return 0;
        const nf: f64 = @floatFromInt(n);
        const denom = nf * sum_tt - sum_t * sum_t;
        if (@abs(denom) < 1e-18) return 0;
        return @floatCast((nf * sum_tx - sum_t * sum_x) / denom);
    }

    fn at(self: VelocityTracker, i: u8) Sample {
        return self.samples[(@as(usize, self.head) + i) % cap];
    }

    fn dropOlderThan(self: *VelocityTracker, now_ms: i64, window_ms: i64) void {
        while (self.count > 0 and now_ms - self.at(0).time_ms > window_ms) {
            self.head = @intCast((@as(usize, self.head) + 1) % cap);
            self.count -= 1;
        }
    }
};

/// Apple-style rubber band: maps a positive overshoot `x` into `(0, d)`.
pub fn rubber(overshoot: f32, dimension: f32, c: f32) f32 {
    if (overshoot <= 0 or dimension <= 0 or c <= 0) return 0;
    const x: f64 = overshoot;
    const d: f64 = dimension;
    const cc: f64 = c;
    return @floatCast((1.0 - 1.0 / (x * cc / d + 1.0)) * d);
}

pub fn rubberClamp(value: f32, min: f32, max: f32, dimension: f32, c: f32) f32 {
    if (value < min) return min - rubber(min - value, dimension, c);
    if (value > max) return max + rubber(value - max, dimension, c);
    return value;
}

var override_ms: ?i64 = null;
var speed_g: f32 = 1.0;
var enabled_g: bool = true;
var reduced_motion_g: bool = false;
var settings_g: Settings = .{};
var desktop_enable_animations_g: bool = true;

/// Per-frame observation for scheduling stats. `observeBegin` at the start
/// of an output frame; `sampleChanged` fills these; the frame handler reads
/// them afterwards. Not a registry — ticks already call `sampleChanged`.
///
/// These describe *why* a frame was re-armed; they must never be what decides
/// whether it was. `anim_frames_scheduled` counts the frame handler's own
/// `keep_going`, so a keep-awake that never reaches `sampleChanged` still shows
/// up. Two kinds of tick do exactly that, and both must say so explicitly:
/// a `settled()`-only check (`observeUnsettled`) and a repaint driven by
/// something other than a curve, such as a caret blink (`observeNoteActive` /
/// `observeNoteChanged`). Forgetting one only over-reports a wasted wakeup —
/// it can no longer hide a spinning output.
var observe_active: bool = false;
var observe_changed: bool = false;
var observe_longest_ms: i64 = 0;

pub fn observeBegin() void {
    observe_active = false;
    observe_changed = false;
    observe_longest_ms = 0;
}

fn observeElapsed(start_ms: i64, now_ms: i64) void {
    observe_active = true;
    const elapsed = now_ms - start_ms;
    if (elapsed > observe_longest_ms) observe_longest_ms = elapsed;
}

/// `!settled`, recording the observation on the way. Use wherever a keep-awake
/// decision reads `settled()` on an Anim that this frame never passes through
/// `sampleChanged` — otherwise the frame is scheduled with nothing observed.
pub fn observeUnsettled(a: Anim, now_ms: i64) bool {
    if (a.settled(now_ms)) return false;
    observeElapsed(a.start_ms, now_ms);
    return true;
}

/// Record a keep-awake that is not an `Anim` at all (a blink phase, a timed
/// repaint). `start_ms` is when that activity began, for `observeLongestMs`.
pub fn observeNoteActive(start_ms: i64, now_ms: i64) void {
    observeElapsed(start_ms, now_ms);
}

/// Record that the picture changed for a reason `sampleChanged` cannot see, so
/// the frame is not miscounted as a wasted wakeup.
pub fn observeNoteChanged() void {
    observe_changed = true;
}

pub fn observeActive() bool {
    return observe_active;
}

pub fn observeChanged() bool {
    return observe_changed;
}

pub fn observeLongestMs() i64 {
    return observe_longest_ms;
}

pub fn setNowMs(ms: ?i64) void {
    override_ms = ms;
}

pub fn clockOverridden() bool {
    return override_ms != null;
}

pub fn nowMs() i64 {
    if (override_ms) |ms| return ms;
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => return 0,
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn setSpeed(new_speed: f32) void {
    speed_g = new_speed;
}

pub fn speed() f32 {
    return speed_g;
}

pub fn setEnabled(on: bool) void {
    enabled_g = on;
}

pub fn enabled() bool {
    return enabled_g;
}

pub fn setReducedMotion(on: bool) void {
    reduced_motion_g = on;
}

pub fn reducedMotion() bool {
    return reduced_motion_g;
}

pub fn curveFor(target: Target) Curve {
    return settings_g.targets[@intFromEnum(target)].curve;
}

pub fn decayFor(target: Target) Decay {
    return settings_g.targets[@intFromEnum(target)].decay;
}

pub fn currentSettings() Settings {
    return settings_g;
}

pub fn desktopEnableAnimations() bool {
    return desktop_enable_animations_g;
}

pub fn setDesktopEnableAnimations(on: bool) void {
    desktop_enable_animations_g = on;
}

/// `null` means we do not own the key (auto follows the desktop portal).
pub fn servedEnableAnimations(settings: Settings) ?bool {
    if (!settings.enabled) return false;
    return switch (settings.reduced_motion) {
        .auto => null,
        .on => false,
        .off => true,
    };
}

pub fn applySettings(settings: Settings) void {
    settings_g = settings;
    setEnabled(settings.enabled);
    setSpeed(@max(settings.speed, 0));
    const reduced = switch (settings.reduced_motion) {
        .on => true,
        .off => false,
        .auto => !desktop_enable_animations_g,
    };
    setReducedMotion(reduced);
}

pub const LiveCapture = struct {
    ptr: *Anim,
    target: Target,
    from: f32,
    to: f32,
    v0: f32,
};

pub fn captureIfLive(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(LiveCapture),
    a: *Anim,
    target: Target,
    now_ms: i64,
) !void {
    if (!a.active() or a.settled(now_ms)) return;
    try list.append(allocator, .{
        .ptr = a,
        .target = target,
        .from = a.value(now_ms),
        .to = a.to,
        .v0 = a.velocity(now_ms),
    });
}

fn resetGlobals() void {
    override_ms = null;
    speed_g = 1.0;
    enabled_g = true;
    reduced_motion_g = false;
    settings_g = .{};
    desktop_enable_animations_g = true;
    observeBegin();
}

const SettleTimes = struct { settle: i64, clamped: i64 };

fn computeSettle(from: f32, to: f32, v0: f32, curve: Curve) SettleTimes {
    return switch (curve) {
        .off => .{ .settle = 0, .clamped = 0 },
        .duration => |d| .{ .settle = @max(d.ms, 0), .clamped = @max(d.ms, 0) },
        .spring => |s| springSettle(from, to, v0, s),
        .decay => |d| blk: {
            const ms = decayDurationMs(v0, d.rate, d.threshold);
            break :blk .{ .settle = ms, .clamped = ms };
        },
    };
}

const f32_eps: f64 = std.math.floatEps(f32);

const SpringMode = enum { critical, under, over };

const SpringEval = struct {
    to: f64,
    x0: f64,
    v0: f64,
    beta: f64,
    omega: f64,
    mode: SpringMode,
    epsilon: f64,
};

fn springEval(from: f32, to: f32, v0: f32, params: Spring) ?SpringEval {
    const k: f64 = params.stiffness;
    if (!(k > 0) or !std.math.isFinite(k)) return null;
    const ratio = @max(@as(f64, params.damping_ratio), 1e-3);
    const mass: f64 = 1.0;
    const critical = 2.0 * @sqrt(mass * k);
    const b = ratio * critical;
    const beta = b / (2.0 * mass);
    const omega0 = @sqrt(k / mass);
    const mode: SpringMode = if (@abs(beta - omega0) <= f32_eps)
        .critical
    else if (beta < omega0)
        .under
    else
        .over;
    const omega = switch (mode) {
        .critical => 0.0,
        .under => @sqrt(omega0 * omega0 - beta * beta),
        .over => @sqrt(beta * beta - omega0 * omega0),
    };
    return .{
        .to = to,
        .x0 = @as(f64, from) - @as(f64, to),
        .v0 = v0,
        .beta = beta,
        .omega = omega,
        .mode = mode,
        .epsilon = @max(@as(f64, params.epsilon), 1e-12),
    };
}

fn springOscillate(e: SpringEval, t: f64) f64 {
    const env = @exp(-e.beta * t);
    switch (e.mode) {
        .critical => return e.to + env * (e.x0 + (e.beta * e.x0 + e.v0) * t),
        .under => {
            const w = e.omega;
            const c = (e.beta * e.x0 + e.v0) / w;
            return e.to + env * (e.x0 * @cos(w * t) + c * @sin(w * t));
        },
        .over => {
            const w = e.omega;
            const d = (e.beta * e.x0 + e.v0) / w;
            const arg = w * t;
            const ch = std.math.cosh(arg);
            const sh = std.math.sinh(arg);
            const y = e.to + env * (e.x0 * ch + d * sh);
            if (!std.math.isFinite(y)) return e.to;
            return y;
        },
    }
}

fn springVelocityAt(e: SpringEval, t: f64) f64 {
    const env = @exp(-e.beta * t);
    switch (e.mode) {
        .critical => {
            const a = e.beta * e.x0 + e.v0;
            return env * (a - e.beta * (e.x0 + a * t));
        },
        .under => {
            const w = e.omega;
            const c = (e.beta * e.x0 + e.v0) / w;
            const wt = w * t;
            const cos_wt = @cos(wt);
            const sin_wt = @sin(wt);
            return env * (-e.beta * (e.x0 * cos_wt + c * sin_wt) + w * (c * cos_wt - e.x0 * sin_wt));
        },
        .over => {
            const w = e.omega;
            const d = (e.beta * e.x0 + e.v0) / w;
            const arg = w * t;
            const ch = std.math.cosh(arg);
            const sh = std.math.sinh(arg);
            const y = env * (-e.beta * (e.x0 * ch + d * sh) + w * (e.x0 * sh + d * ch));
            if (!std.math.isFinite(y)) return 0;
            return y;
        },
    }
}

fn secondsToMs(s: f64) i64 {
    if (!std.math.isFinite(s) or s >= 60) return 60_000;
    if (s <= 0) return 0;
    return @intFromFloat(@ceil(s * 1000.0));
}

fn springSettle(from: f32, to: f32, v0: f32, params: Spring) SettleTimes {
    const e = springEval(from, to, v0, params) orelse return .{ .settle = 0, .clamped = 0 };
    if (@abs(e.x0) <= e.epsilon and @abs(e.v0) <= e.epsilon) return .{ .settle = 0, .clamped = 0 };

    const settle_s = springDuration(e);
    const settle = secondsToMs(settle_s);
    const clamped_s = springClampedDuration(e) orelse settle_s;
    var clamped = secondsToMs(clamped_s);
    if (clamped > settle) clamped = settle;
    return .{ .settle = settle, .clamped = clamped };
}

fn springDuration(e: SpringEval) f64 {
    const delta: f64 = 0.001;
    if (@abs(e.beta) <= f32_eps or e.beta < 0) return 60;
    if (@abs(e.x0) <= e.epsilon and @abs(e.v0) <= e.epsilon) return 0;

    var x0 = -@log(e.epsilon) / e.beta;
    if (e.mode != .over) return x0;

    var y0 = springOscillate(e, x0);
    var m = (springOscillate(e, x0 + delta) - y0) / delta;
    if (@abs(m) < 1e-18 or !std.math.isFinite(m)) return x0;
    var x1 = (e.to - y0 + m * x0) / m;
    var y1 = springOscillate(e, x1);
    var i: usize = 0;
    while (@abs(e.to - y1) > e.epsilon) {
        if (i > 1000) return x0;
        x0 = x1;
        y0 = y1;
        m = (springOscillate(e, x0 + delta) - y0) / delta;
        if (@abs(m) < 1e-18 or !std.math.isFinite(m) or !std.math.isFinite(x0)) return x0;
        x1 = (e.to - y0 + m * x0) / m;
        y1 = springOscillate(e, x1);
        if (!std.math.isFinite(y1) or !std.math.isFinite(x1)) return x0;
        i += 1;
    }
    if (!std.math.isFinite(x1) or x1 < 0) return x0;
    return x1;
}

test "window reveal eases through the old 33ms snap and reaches its destination" {
    const a = Anim.initCurve(0, 602, 1000, defaultSpec(.camera_reveal).curve);
    try std.testing.expect(!a.settled(1033));
    try std.testing.expect(@abs(a.value(1033) - a.value(1032)) < 6);
    try std.testing.expect(a.value(1160) > a.value(1033));
    try std.testing.expect(a.value(1160) < 602);
    try std.testing.expect(a.settled(1320));
    try std.testing.expectEqual(@as(f32, 602), a.value(1320));
}

fn springClampedDuration(e: SpringEval) ?f64 {
    if (@abs(e.beta) <= f32_eps or e.beta < 0) return 60;
    if (@abs(e.x0) <= e.epsilon) return 0;
    const from = e.to + e.x0;
    var i: u16 = 1;
    var y = springOscillate(e, @as(f64, i) / 1000.0);
    while ((e.to - from > f32_eps and e.to - y > e.epsilon) or
        (from - e.to > f32_eps and y - e.to > e.epsilon))
    {
        if (i > 3000) return null;
        i += 1;
        y = springOscillate(e, @as(f64, i) / 1000.0);
    }
    return @as(f64, i) / 1000.0;
}

fn sampleSpring(from: f32, to: f32, v0: f32, params: Spring, t_s: f64) Anim.Sample {
    const e = springEval(from, to, v0, params) orelse return .{ .value = to, .velocity = 0 };
    const x = springOscillate(e, t_s);
    const v = springVelocityAt(e, t_s);
    // niri's numerical-stability clamp: 10× the travel, in case cosh blows up.
    const range = (@as(f64, to) - @as(f64, from)) * 10.0;
    const lo = @min(@as(f64, from) - range, @as(f64, to) + range);
    const hi = @max(@as(f64, from) - range, @as(f64, to) + range);
    const clamped = std.math.clamp(x, @min(lo, hi), @max(lo, hi));
    return .{
        .value = @floatCast(if (std.math.isFinite(clamped)) clamped else to),
        .velocity = @floatCast(if (std.math.isFinite(v)) v else 0),
    };
}

fn decayCoeff(rate: f32) f64 {
    const r = std.math.clamp(@as(f64, rate), 0.001, 0.999);
    return 1000.0 * @log(r);
}

fn decayResting(from: f32, v0: f32, rate: f32) f32 {
    const coeff = decayCoeff(rate);
    return @floatCast(@as(f64, from) - @as(f64, v0) / coeff);
}

fn decayDurationMs(v0: f32, rate: f32, threshold: f32) i64 {
    const coeff = decayCoeff(rate);
    const vel = @abs(@as(f64, v0));
    const thresh = @max(@as(f64, threshold), 1e-6);
    if (vel <= thresh) return 0;
    const inner = -coeff * thresh / vel;
    if (inner <= 0) return 0;
    const seconds = @log(inner) / coeff;
    return secondsToMs(seconds);
}

fn sampleDecay(from: f32, v0: f32, d: Decay, t_s: f64) Anim.Sample {
    const coeff = decayCoeff(d.rate);
    const env = @exp(coeff * t_s);
    const x = @as(f64, from) + (@as(f64, v0) / coeff) * (env - 1.0);
    const v = @as(f64, v0) * env;
    return .{ .value = @floatCast(x), .velocity = @floatCast(v) };
}

fn sampleDuration(from: f32, to: f32, elapsed_ms: f64, duration_ms: i64, ease: Ease) Anim.Sample {
    if (duration_ms <= 0) return .{ .value = to, .velocity = 0 };
    const dur: f64 = @floatFromInt(duration_ms);
    if (elapsed_ms >= dur) return .{ .value = to, .velocity = 0 };
    const t = if (elapsed_ms <= 0) 0 else elapsed_ms / dur;
    const t32: f32 = @floatCast(t);
    const eased: f32 = switch (ease) {
        .out_cubic => 1 - std.math.pow(f32, 1 - t32, 3),
        .flip_bezier => cubicBezierY(t32, 0.22, 0.9, 0.3, 1),
    };
    const deriv = easeDeriv(ease, t);
    const vel = (to - from) * deriv * (1000.0 / dur);
    return .{
        .value = from + (to - from) * eased,
        .velocity = @floatCast(vel),
    };
}

fn easeDeriv(ease: Ease, t: f64) f64 {
    const tt = std.math.clamp(t, 0, 1);
    return switch (ease) {
        .out_cubic => 3.0 * (1.0 - tt) * (1.0 - tt),
        .flip_bezier => cubicBezierDeriv(tt, 0.22, 0.9, 0.3, 1.0),
    };
}

fn bezierComponent64(u: f64, p1: f64, p2: f64) f64 {
    const mu = 1.0 - u;
    return 3.0 * mu * mu * u * p1 + 3.0 * mu * u * u * p2 + u * u * u;
}

fn bezierDeriv64(u: f64, p1: f64, p2: f64) f64 {
    const mu = 1.0 - u;
    return 3.0 * mu * mu * p1 + 6.0 * mu * u * (p2 - p1) + 3.0 * u * u * (1.0 - p2);
}

fn cubicBezierDeriv(t: f64, x1: f64, y1: f64, x2: f64, y2: f64) f64 {
    var lo: f64 = 0;
    var hi: f64 = 1;
    var u: f64 = t;
    for (0..24) |_| {
        const x = bezierComponent64(u, x1, x2);
        if (@abs(x - t) < 1e-6) break;
        if (x < t) lo = u else hi = u;
        u = (lo + hi) / 2.0;
    }
    const dx = bezierDeriv64(u, x1, x2);
    const dy = bezierDeriv64(u, y1, y2);
    if (@abs(dx) < 1e-12) return 0;
    return dy / dx;
}

fn bezierComponent(u: f32, p1: f32, p2: f32) f32 {
    const mu = 1 - u;
    return 3 * mu * mu * u * p1 + 3 * mu * u * u * p2 + u * u * u;
}

// Solves x(u) = t for the CSS-style cubic-bezier(x1,y1,x2,y2) easing curve
// (implicit endpoints (0,0) and (1,1)) and returns y(u). Bisection keeps this
// robust without needing the curve's derivative. Kept for the existing f32
// duration path's exact historical samples.
fn cubicBezierY(t: f32, x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    var lo: f32 = 0;
    var hi: f32 = 1;
    var u: f32 = t;
    for (0..20) |_| {
        const x = bezierComponent(u, x1, x2);
        if (@abs(x - t) < 1e-4) break;
        if (x < t) lo = u else hi = u;
        u = (lo + hi) / 2;
    }
    return bezierComponent(u, y1, y2);
}

test "retarget is a no-op when already animating toward the same target" {
    var a = Anim.initDuration(0, 1, 0, 100, .out_cubic);
    a.retarget(50, 1, 999, .out_cubic);
    try std.testing.expectEqual(@as(i64, 100), a.settle_ms);
    a.retarget(150, 1, 999, .out_cubic);
    try std.testing.expectEqual(@as(i64, 100), a.settle_ms);
    try std.testing.expect(a.settled(150));
}

test "pulse starts displaced and eases to rest" {
    var a: Anim = .{};
    a.pulse(0, 0.9, 1, 100);
    try std.testing.expectEqual(@as(f32, 0.9), a.value(0));
    try std.testing.expectEqual(@as(f32, 1), a.value(100));
}

test "setNowMs overrides the monotonic clock until cleared" {
    defer resetGlobals();
    setNowMs(1234);
    try std.testing.expect(clockOverridden());
    try std.testing.expectEqual(@as(i64, 1234), nowMs());
    setNowMs(null);
    try std.testing.expect(!clockOverridden());
}

test "out_cubic mid-duration matches the historical sample" {
    var a = Anim.initDuration(0.50, 0.55, 1000, 80, .out_cubic);
    try std.testing.expectApproxEqAbs(@as(f32, 0.54375), a.value(1040), 0.001);
    try std.testing.expect(!a.settled(1040));
    try std.testing.expect(a.settled(1080));
    try std.testing.expectEqual(@as(f32, 0.55), a.value(1080));
}

test "velocity at start_ms equals v0 for all three damping regimes" {
    const cases = [_]Spring{
        .{ .damping_ratio = 1.0, .stiffness = 800 },
        .{ .damping_ratio = 0.7, .stiffness = 800 },
        .{ .damping_ratio = 1.6, .stiffness = 800 },
    };
    const v0: f32 = 12.5;
    for (cases) |spring| {
        var a: Anim = .{};
        a.retargetWith(100, 1, .{ .spring = spring }, v0);
        try std.testing.expectApproxEqAbs(v0, a.velocity(100), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0), a.value(100), 1e-5);
    }
}

test "analytic spring matches RK4 integration" {
    const cases = [_]Spring{
        .{ .damping_ratio = 1.0, .stiffness = 800, .epsilon = 1e-4 },
        .{ .damping_ratio = 0.7, .stiffness = 800, .epsilon = 1e-4 },
        .{ .damping_ratio = 1.6, .stiffness = 800, .epsilon = 1e-4 },
    };
    for (cases) |spring| {
        var a: Anim = .{};
        a.retargetTo(0, 1, .{ .spring = spring });
        const Acc = struct {
            b: f64,
            k: f64,
            to: f64,
            fn call(self: @This(), x: f64, v: f64) f64 {
                return -self.b * v - self.k * (x - self.to);
            }
        };
        const k: f64 = spring.stiffness;
        const ratio: f64 = spring.damping_ratio;
        const acc = Acc{ .b = ratio * 2.0 * @sqrt(k), .k = k, .to = 1 };
        const dt: f64 = 0.0001;
        var t_ms: i64 = 0;
        const end = a.settle_ms;
        while (t_ms <= end) : (t_ms += 8) {
            const t_s = @as(f64, @floatFromInt(t_ms)) / 1000.0;
            var x: f64 = 0;
            var v: f64 = 0;
            var t: f64 = 0;
            while (t < t_s) {
                const step = @min(dt, t_s - t);
                const k1x = v;
                const k1v = acc.call(x, v);
                const k2x = v + 0.5 * step * k1v;
                const k2v = acc.call(x + 0.5 * step * k1x, v + 0.5 * step * k1v);
                const k3x = v + 0.5 * step * k2v;
                const k3v = acc.call(x + 0.5 * step * k2x, v + 0.5 * step * k2v);
                const k4x = v + step * k3v;
                const k4v = acc.call(x + step * k3x, v + step * k3v);
                x += step / 6.0 * (k1x + 2 * k2x + 2 * k3x + k4x);
                v += step / 6.0 * (k1v + 2 * k2v + 2 * k3v + k4v);
                t += step;
            }
            try std.testing.expectApproxEqAbs(@as(f32, @floatCast(x)), a.value(t_ms), 1e-3);
        }
    }
}

test "retarget is velocity-continuous" {
    const spring = Spring{ .damping_ratio = 0.85, .stiffness = 700 };
    var a: Anim = .{};
    a.retargetTo(0, 1, .{ .spring = spring });
    const mid: i64 = 40;
    const v = a.velocity(mid);
    const x = a.value(mid);
    a.retargetTo(mid, 0, .{ .spring = spring });
    try std.testing.expectApproxEqAbs(v, a.velocity(mid), 1e-4);
    try std.testing.expectApproxEqAbs(x, a.value(mid), 1e-5);
    try std.testing.expectApproxEqAbs(v, a.v0, 1e-4);

    const start = a.start_ms;
    a.retargetTo(mid + 5, 0, .{ .spring = spring });
    try std.testing.expectEqual(start, a.start_ms);

    a.cancel(0);
    a.retargetTo(1000, 1, .{ .spring = spring });
    try std.testing.expectApproxEqAbs(@as(f32, 0), a.v0, 1e-5);
}

test "spring settle time is finite and from==to is immediate" {
    const ratios = [_]f32{ 0.1, 0.5, 1.0, 2.0, 5.0, 10.0 };
    var prev_under: i64 = std.math.maxInt(i64);
    for (ratios) |ratio| {
        var a: Anim = .{};
        a.retargetTo(0, 1, .{ .spring = .{ .damping_ratio = ratio, .stiffness = 800, .epsilon = 1e-4 } });
        try std.testing.expect(a.settle_ms > 0);
        try std.testing.expect(a.settle_ms < 60_000);
        if (ratio <= 1.0) {
            try std.testing.expect(a.settle_ms <= prev_under);
            prev_under = a.settle_ms;
        }
    }

    var same: Anim = .{};
    same.retargetTo(0, 0, .{ .spring = .{ .damping_ratio = 1.15, .stiffness = 850, .epsilon = 0.0001 } });
    try std.testing.expectEqual(@as(i64, 0), same.settle_ms);
    try std.testing.expect(same.settled(0));

    var stiff: Anim = .{};
    stiff.retargetTo(0, 1, .{ .spring = .{ .damping_ratio = 6, .stiffness = 1200, .epsilon = 0.0001 } });
    try std.testing.expect(std.math.isFinite(@as(f32, @floatFromInt(stiff.settle_ms))));
    const late = sampleSpring(0, 1, 0, .{ .damping_ratio = 6, .stiffness = 1200, .epsilon = 0.0001 }, 10.0);
    try std.testing.expect(std.math.isFinite(late.value));
}

test "decay resting value, duration and 2-D angle" {
    const rate: f32 = 0.998;
    const v0: f32 = 800;
    var a: Anim = .{};
    a.retargetWith(0, 0, .{ .decay = .{ .rate = rate, .threshold = 0.5 } }, v0);
    const rest = a.restingValue();
    try std.testing.expectApproxEqAbs(rest, a.to, 1e-4);
    const far = a.settle_ms * 2;
    try std.testing.expectApproxEqAbs(rest, a.value(@max(far, a.settle_ms)), 0.6);
    try std.testing.expect(a.settled(a.settle_ms));
    try std.testing.expect(@abs(a.velocity(a.settle_ms)) <= 0.5 + 1e-3);

    var ax: Anim = .{};
    var ay: Anim = .{};
    ax.retargetWith(0, 0, .{ .decay = .{ .rate = rate, .threshold = 0.5 } }, 300);
    ay.retargetWith(0, 0, .{ .decay = .{ .rate = rate, .threshold = 0.5 } }, 400);
    const ang0 = std.math.atan2(@as(f64, 400), @as(f64, 300));
    var t: i64 = 8;
    while (t < ax.settle_ms) : (t += 16) {
        const ang = std.math.atan2(@as(f64, ay.value(t)), @as(f64, ax.value(t)));
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(ang0)), @as(f32, @floatCast(ang)), 1e-5);
    }
}

test "rubber band is monotone, bounded and continuous at zero" {
    try std.testing.expectEqual(@as(f32, 0), rubber(0, 800, rubber_c));
    var prev: f32 = 0;
    const d: f32 = 800;
    const xs = [_]f32{ 0, 1, 10, 50, 200, 800, 4000 };
    for (xs) |x| {
        const y = rubber(x, d, rubber_c);
        try std.testing.expect(y >= prev);
        try std.testing.expect(y < d);
        prev = y;
    }
    try std.testing.expectEqual(@as(f32, 100), rubberClamp(100, 0, 400, 400, rubber_c));
    const just_out = rubberClamp(401, 0, 400, 400, rubber_c);
    try std.testing.expect(just_out > 400);
    try std.testing.expect(just_out < 401);
}

test "sampleChanged observe tracks activity, change and longest" {
    defer resetGlobals();
    observeBegin();
    var a: Anim = .{};
    a.retargetTo(0, 10, .{ .spring = .{ .damping_ratio = 1.0, .stiffness = 800, .epsilon = 1e-4 } });
    try std.testing.expect(a.sampleChanged(0, 1));
    try std.testing.expect(observeActive());
    try std.testing.expect(observeChanged());
    try std.testing.expectEqual(@as(i64, 0), observeLongestMs());

    observeBegin();
    try std.testing.expect(!a.sampleChanged(0, 1));
    try std.testing.expect(observeActive());
    try std.testing.expect(!observeChanged());

    observeBegin();
    try std.testing.expect(a.sampleChanged(50, 1));
    try std.testing.expect(observeActive());
    try std.testing.expect(observeChanged());
    try std.testing.expectEqual(@as(i64, 50), observeLongestMs());

    try std.testing.expectEqualStrings("spring", a.curveName());
    try std.testing.expectEqualStrings("off", (Anim{ .curve = .off }).curveName());
}

test "a settled()-only keep-awake is invisible until it reports itself" {
    defer resetGlobals();
    var a: Anim = .{};
    a.retargetTo(0, 10, .{ .spring = .{ .damping_ratio = 0.9, .stiffness = 700, .epsilon = 1e-3 } });
    try std.testing.expect(a.settle_ms > 60);

    // The regression: a live curve that a frame only ever asks `settled()`
    // leaves the frame looking idle, so `anim_frames_scheduled` read zero while
    // the output was being re-armed every refresh.
    observeBegin();
    try std.testing.expect(!a.settled(50));
    try std.testing.expect(!observeActive());
    try std.testing.expectEqual(@as(i64, 0), observeLongestMs());

    observeBegin();
    try std.testing.expect(observeUnsettled(a, 50));
    try std.testing.expect(observeActive());
    try std.testing.expectEqual(@as(i64, 50), observeLongestMs());
    // Still not a *visible* change: that stays `sampleChanged`'s to report,
    // so such a frame is correctly counted as a wasted wakeup.
    try std.testing.expect(!observeChanged());

    // Past the settle point it must stop claiming the output.
    observeBegin();
    try std.testing.expect(!observeUnsettled(a, a.settle_ms));
    try std.testing.expect(!observeActive());
}

test "non-curve keep-awakes report activity and change" {
    defer resetGlobals();
    observeBegin();
    try std.testing.expect(!observeActive());
    try std.testing.expect(!observeChanged());

    // A caret blink is a phase timer, not an Anim; it still owns the output.
    observeNoteActive(1000, 1400);
    try std.testing.expect(observeActive());
    try std.testing.expectEqual(@as(i64, 400), observeLongestMs());

    observeNoteChanged();
    try std.testing.expect(observeChanged());

    observeBegin();
    try std.testing.expect(!observeActive());
    try std.testing.expect(!observeChanged());
    try std.testing.expectEqual(@as(i64, 0), observeLongestMs());
}

test "sampleChanged reports each quantum crossing once" {
    var a = Anim.initDuration(0, 10, 0, 1000, .out_cubic);
    try std.testing.expect(a.sampleChanged(0, 1));
    try std.testing.expect(!a.sampleChanged(0, 1));
    var saw_one = false;
    var t: i64 = 1;
    while (t <= 1000) : (t += 1) {
        const changed = a.sampleChanged(t, 1);
        const bucket = @round(a.value(t));
        if (bucket == 1 and changed) {
            try std.testing.expect(!saw_one);
            saw_one = true;
        }
    }
    try std.testing.expect(saw_one);
}

test "speed scales elapsed time; reduced_motion keeps opacity" {
    defer resetGlobals();
    const spring = Spring{ .damping_ratio = 1.0, .stiffness = 800 };
    var slow: Anim = .{};
    slow.retargetTo(0, 1, .{ .spring = spring });
    const at100 = slow.value(100);

    setSpeed(2);
    var fast: Anim = .{};
    fast.retargetTo(0, 1, .{ .spring = spring });
    try std.testing.expectApproxEqAbs(at100, fast.value(50), 1e-4);
    setSpeed(1);

    setReducedMotion(true);
    var motion: Anim = .{ .property = .motion };
    motion.retargetTo(0, 1, .{ .spring = spring });
    try std.testing.expect(motion.settled(0));
    try std.testing.expectEqual(@as(f32, 1), motion.value(0));

    var fade: Anim = .{ .property = .opacity };
    fade.retargetTo(0, 1, .{ .spring = spring });
    try std.testing.expect(!fade.settled(0));
    try std.testing.expect(fade.value(0) < 1);
    try std.testing.expect(fade.settled(reduced_opacity_ms));
    try std.testing.expectEqual(@as(f32, 1), fade.value(reduced_opacity_ms));
}

test "pinned clock: settled flips at stored settle_ms and sampleChanged terminates" {
    defer resetGlobals();
    setNowMs(1000);
    var a: Anim = .{};
    a.retargetTo(1000, 1, .{ .spring = .{ .damping_ratio = 1.0, .stiffness = 800, .epsilon = 1e-4 } });
    try std.testing.expect(a.settle_ms > 0);
    try std.testing.expect(!a.settled(1000));
    try std.testing.expect(!a.settled(1000 + a.settle_ms - 1));
    try std.testing.expect(a.settled(1000 + a.settle_ms));

    var paints: usize = 0;
    while (a.sampleChanged(1000, 0.01)) {
        paints += 1;
        if (paints > 8) return error.DidNotTerminate;
    }
    try std.testing.expect(paints >= 1);
}

test "active and cancel replace the duration_ms sentinel" {
    var a: Anim = .{};
    try std.testing.expect(!a.active());
    a.retarget(0, 1, 160, .out_cubic);
    try std.testing.expect(a.active());
    try std.testing.expect(!a.settled(0));
    a.cancel(1);
    try std.testing.expect(!a.active());
    try std.testing.expect(a.settled(0));
    try std.testing.expectEqual(@as(f32, 1), a.value(50));

    var s: Anim = .{};
    s.retargetTo(0, 1, .{ .spring = .{ .damping_ratio = 1, .stiffness = 800 } });
    try std.testing.expect(s.active());
    s.cancel(0.25);
    try std.testing.expect(!s.active());
    try std.testing.expectEqual(@as(f32, 0.25), s.value(0));
}

test "velocity tracker least-squares and pause" {
    var tr: VelocityTracker = .{};
    try std.testing.expectEqual(@as(f32, 0), tr.velocity(0));
    tr.push(0, 0);
    try std.testing.expectEqual(@as(f32, 0), tr.velocity(10));
    tr.push(10, 20);
    tr.push(20, 40);
    tr.push(30, 60);
    try std.testing.expectApproxEqAbs(@as(f32, 2000), tr.velocity(30), 1);
    try std.testing.expectEqual(@as(f32, 0), tr.velocity(90));
}

test "critical-damping window does not divide by zero" {
    var a: Anim = .{};
    a.retargetWith(0, 1, .{ .spring = .{ .damping_ratio = 1.0, .stiffness = 800 } }, 3);
    var t: i64 = 0;
    while (t <= a.settle_ms) : (t += 4) {
        const v = a.value(t);
        const vel = a.velocity(t);
        try std.testing.expect(std.math.isFinite(v));
        try std.testing.expect(std.math.isFinite(vel));
    }
}

test "enabled false and speed 0 complete instantly" {
    defer resetGlobals();
    var a: Anim = .{};
    a.retargetTo(0, 1, .{ .spring = .{ .damping_ratio = 1, .stiffness = 800 } });
    setEnabled(false);
    try std.testing.expect(a.settled(0));
    try std.testing.expectEqual(@as(f32, 1), a.value(0));
    setEnabled(true);
    setSpeed(0);
    try std.testing.expect(a.settled(0));
    try std.testing.expectEqual(@as(f32, 1), a.value(0));
}

// Keep the f32 bezier solver referenced so a future duration path that still
// wants bit-identical historical samples can call it without the compiler
// folding the function away.
test "flip_bezier f32 solver stays wired" {
    const y = cubicBezierY(0.5, 0.22, 0.9, 0.3, 1);
    try std.testing.expect(y > 0.5);
    try std.testing.expect(y < 1);
}

test "desktop switches respond immediately and settle at the requested time" {
    for ([_]u32{ 220, 400, 1500 }) |ms| {
        var a: Anim = .{};
        a.retargetTo(0, 1000, desktopSwitchCurve(ms));
        // A tenth of the duration should already cover over a quarter of the
        // distance: no spring-style acceleration delay on a keyboard action.
        try std.testing.expect(a.value(@intCast(ms / 10)) > 250);
        try std.testing.expect(a.velocity(0) > 0);
        try std.testing.expect(!a.settled(ms - 1));
        try std.testing.expect(a.settled(ms));
        try std.testing.expectEqual(@as(f32, 1000), a.value(ms));
    }
}

test "panel_slide spring double-toggle is velocity-continuous" {
    const curve = Curve{ .spring = springs.panel_slide };
    var a: Anim = .{};
    a.retargetTo(0, 1, curve);
    try std.testing.expect(a.active());
    const mid: i64 = 80;
    const v = a.velocity(mid);
    const x = a.value(mid);
    a.retargetTo(mid, 0, curve);
    try std.testing.expectApproxEqAbs(v, a.velocity(mid), 1e-4);
    try std.testing.expectApproxEqAbs(x, a.value(mid), 1e-5);
    try std.testing.expect(a.settle_ms > 0);
}

test "windowMapScale interpolates from open scale to rest" {
    try std.testing.expectEqual(window_open_scale, windowMapScale(0));
    try std.testing.expectEqual(@as(f32, 1.0), windowMapScale(1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.96), windowMapScale(0.5), 1e-6);
}

test "every animation target has a compiled-in default" {
    inline for (std.meta.tags(Target)) |tag| {
        const spec = defaultSpec(tag);
        try std.testing.expect(std.meta.activeTag(spec.curve) != .off or tag == .taskbar_press);
        _ = curveFor(tag);
        _ = decayFor(tag);
        const bounds = epsilonBounds(tag);
        try std.testing.expect(bounds.min > 0);
        try std.testing.expect(bounds.max > bounds.min);
    }
}

test "applySettings overlays speed enabled and reduced_motion auto" {
    defer resetGlobals();
    var cfg: Settings = .{};
    cfg.speed = 0.5;
    cfg.enabled = true;
    cfg.reduced_motion = .auto;
    setDesktopEnableAnimations(true);
    applySettings(cfg);
    try std.testing.expectEqual(@as(f32, 0.5), speed());
    try std.testing.expect(enabled());
    try std.testing.expect(!reducedMotion());

    setDesktopEnableAnimations(false);
    applySettings(cfg);
    try std.testing.expect(reducedMotion());

    cfg.reduced_motion = .off;
    applySettings(cfg);
    try std.testing.expect(!reducedMotion());
    try std.testing.expectEqual(@as(?bool, true), servedEnableAnimations(cfg));

    cfg.reduced_motion = .on;
    applySettings(cfg);
    try std.testing.expect(reducedMotion());
    try std.testing.expectEqual(@as(?bool, false), servedEnableAnimations(cfg));

    cfg.enabled = false;
    cfg.reduced_motion = .auto;
    try std.testing.expectEqual(@as(?bool, false), servedEnableAnimations(cfg));
}

test "config overlay continueFrom keeps velocity" {
    defer resetGlobals();
    const soft = Curve{ .spring = .{ .damping_ratio = 1.0, .stiffness = 400, .epsilon = 1e-4 } };
    const stiff = Curve{ .spring = .{ .damping_ratio = 1.0, .stiffness = 2000, .epsilon = 1e-4 } };
    var a: Anim = .{};
    a.retargetTo(0, 1, soft);
    const mid: i64 = 80;
    const x = a.value(mid);
    const v = a.velocity(mid);
    a.continueFrom(mid, x, 1, v, stiff);
    try std.testing.expectApproxEqAbs(x, a.value(mid), 1e-5);
    try std.testing.expectApproxEqAbs(v, a.velocity(mid), 1e-4);
    try std.testing.expect(a.settle_ms > 0);
    try std.testing.expect(a.settle_ms != blk: {
        var b: Anim = .{};
        b.retargetTo(0, 1, soft);
        break :blk b.settle_ms;
    });
}
