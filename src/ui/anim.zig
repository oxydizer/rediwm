// Shared animation primitive. Every curve is sampled analytically at a
// timestamp (never integrated per frame): multi-output ticks, pinned-clock
// tests (`setNowMs`) and dropped frames are all the same `x(t)`.
//
// Models:
// - `.duration` — today's ease over a fixed ms window (`out_cubic`, `flip_bezier`,
//   `in_out_sine`).
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

const anim_curves = @import("anim_curves.zig");
pub const SettleTimes = anim_curves.SettleTimes;
pub const computeSettle = anim_curves.computeSettle;
pub const f32_eps = anim_curves.f32_eps;
pub const SpringMode = anim_curves.SpringMode;
pub const SpringEval = anim_curves.SpringEval;
pub const springEval = anim_curves.springEval;
pub const springOscillate = anim_curves.springOscillate;
pub const springVelocityAt = anim_curves.springVelocityAt;
pub const secondsToMs = anim_curves.secondsToMs;
pub const springSettle = anim_curves.springSettle;
pub const springDuration = anim_curves.springDuration;
pub const springClampedDuration = anim_curves.springClampedDuration;
pub const sampleSpring = anim_curves.sampleSpring;
pub const decayCoeff = anim_curves.decayCoeff;
pub const decayResting = anim_curves.decayResting;
pub const decayDurationMs = anim_curves.decayDurationMs;
pub const sampleDecay = anim_curves.sampleDecay;
pub const sampleDuration = anim_curves.sampleDuration;
pub const easeDeriv = anim_curves.easeDeriv;
pub const bezierComponent64 = anim_curves.bezierComponent64;
pub const bezierDeriv64 = anim_curves.bezierDeriv64;
pub const cubicBezierDeriv = anim_curves.cubicBezierDeriv;
pub const bezierComponent = anim_curves.bezierComponent;
pub const cubicBezierY = anim_curves.cubicBezierY;

pub const Ease = enum { out_cubic, flip_bezier, in_out_sine };

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
    // A hovered dock icon pops past its zoom and settles back (~16% overshoot,
    // peak at ~150 ms); leaving dips it just under rest the same way.
    pub const dock_hover = Spring{ .damping_ratio = 0.5, .stiffness = 600, .epsilon = 1e-3 };
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
    // A window launched from the dock grows out of its icon: slower than an
    // ordinary open so the travel reads, with a touch of settle at the end.
    pub const window_launch = Spring{ .damping_ratio = 0.88, .stiffness = 260, .epsilon = 1e-4 };
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
    dock_hover,
    taskbar_press,
    taskbar_flip,
    start_button,
    switcher_scroll,
    switcher_open,
    switcher_close,
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
    window_launch,
    window_close,
    window_move,
    window_resize,
    window_zoom,
    window_drag,
    window_peek,
    window_dim,
    camera_pan,
    camera_zoom,
    camera_reveal,
    camera_desktop,
    session_reveal,

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
        .dock_hover => .{ .curve = .{ .spring = springs.dock_hover } },
        .titlebar_chip => .{ .curve = .{ .spring = springs.titlebar_chip } },
        .titlebar_chip_fade => .{ .curve = .{ .spring = springs.titlebar_chip_fade } },
        .start_glide => .{ .curve = .{ .spring = springs.start_glide } },
        .start_glide_fade => .{ .curve = .{ .spring = springs.start_glide_fade } },
        .taskbar_press => .{ .curve = .{ .duration = .{ .ms = 90, .ease = .out_cubic } } },
        .taskbar_flip, .toast_flip => .{ .curve = .{ .spring = springs.taskbar_flip } },
        .switcher_scroll => .{ .curve = .{ .spring = springs.switcher_scroll } },
        // Circular style only: the hub appears first and windows grow out of
        // it (reversed on close); kept short since it plays on every gesture.
        .switcher_open => .{ .curve = .{ .duration = .{ .ms = 150, .ease = .out_cubic } } },
        .switcher_close => .{ .curve = .{ .duration = .{ .ms = 110, .ease = .out_cubic } } },
        .wheel_scroll => .{ .curve = .{ .spring = springs.wheel_scroll } },
        .osd_level => .{ .curve = .{ .spring = springs.osd_level } },
        .toast_slide => .{ .curve = .{ .spring = springs.toast_slide } },
        .window_open, .window_close => .{ .curve = .{ .spring = springs.window_open } },
        .window_launch => .{ .curve = .{ .spring = springs.window_launch } },
        .window_move, .window_resize => .{ .curve = .{ .spring = springs.window_move } },
        // Still duration in the adopted UI; config can overlay a spring.
        .window_zoom => .{ .curve = .{ .duration = .{ .ms = 160, .ease = .out_cubic } } },
        .window_drag => .{ .curve = .{ .spring = .{ .damping_ratio = 1.0, .stiffness = 600, .epsilon = 1e-4 } } },
        .window_peek, .window_dim => .{ .curve = .{ .duration = .{ .ms = 150, .ease = .out_cubic } } },
        .camera_pan => .{ .curve = .{ .duration = .{ .ms = 160, .ease = .out_cubic } }, .decay = .{ .rate = 0.998, .threshold = 0.5 } },
        .camera_zoom => .{ .curve = .{ .spring = springs.camera_zoom } },
        .camera_reveal => .{ .curve = .{ .duration = .{ .ms = 320, .ease = .out_cubic } } },
        .camera_desktop => .{ .curve = desktopSwitchCurve(default_desktop_switch_ms) },
        // Out of black: an even ramp, not one that is almost bright at once.
        .session_reveal => .{ .curve = .{ .duration = .{ .ms = 420, .ease = .in_out_sine } } },
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

pub var raster_step: f32 = 1;
pub var sampling_clock: ?*const fn () u64 = null;
pub var sampling_ns: u64 = 0;
pub var frame_ms: ?i64 = null;

/// Scope these settings to an output frame; event/IPC sampling is unmeasured.
/// `clock` is null unless somebody is reading the sampling cost (two clock
/// reads per sample otherwise). `now_ms` is the frame's start: `nowMs` returns
/// it until `endFrame`, so one frame reads the clock once, not once per tick.
pub fn beginFrame(coarse: bool, clock: ?*const fn () u64, now_ms: i64) void {
    raster_step = if (coarse) 2 else 1;
    sampling_clock = clock;
    sampling_ns = 0;
    frame_ms = now_ms;
}

pub fn endFrame() u64 {
    sampling_clock = null;
    raster_step = 1;
    frame_ms = null;
    return sampling_ns;
}

pub fn rasterPixelQuantum(scale: f32) f32 {
    return raster_step / @max(scale, 0.01);
}

/// Colours have channel steps, not a spatial extent.
pub fn rasterAlphaQuantum() f32 {
    return raster_step * quantum_alpha;
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

    pub fn commit(self: *Anim, now_ms: i64, from: f32, to: f32, v0: f32, curve: Curve) void {
        self.from = from;
        self.to = to;
        self.v0 = v0;
        self.start_ms = now_ms;
        self.last_quantised = std.math.nan(f32);
        self.installCurve(curve);
    }

    pub fn installCurve(self: *Anim, curve: Curve) void {
        if (curve == .decay) {
            self.to = decayResting(self.from, self.v0, curve.decay.rate);
        }
        self.curve = curve;
        const times = computeSettle(self.from, self.to, self.v0, curve);
        self.settle_ms = times.settle;
        self.clamped_ms = times.clamped;
    }

    pub fn completesInstantly(self: Anim) bool {
        if (!enabled_g or speed_g <= 0) return true;
        if (reduced_motion_g and self.property != .opacity) return true;
        return switch (self.curve) {
            .off => true,
            .duration => |d| d.ms <= 0,
            .spring, .decay => self.settle_ms <= 0,
        };
    }

    pub fn elapsedEffective(self: Anim, now_ms: i64) f64 {
        const raw = @as(f64, @floatFromInt(now_ms - self.start_ms));
        if (raw <= 0) return 0;
        if (speed_g == 1.0) return raw;
        return raw * @as(f64, speed_g);
    }

    pub const Sample = struct { value: f32, velocity: f32 };

    pub fn sample(self: Anim, now_ms: i64) Sample {
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
    pub const cap = 32;
    pub const Sample = struct { time_ms: i64, position: f32 };

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

    pub fn at(self: VelocityTracker, i: u8) Sample {
        return self.samples[(@as(usize, self.head) + i) % cap];
    }

    pub fn dropOlderThan(self: *VelocityTracker, now_ms: i64, window_ms: i64) void {
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

pub var override_ms: ?i64 = null;
pub var speed_g: f32 = 1.0;
pub var enabled_g: bool = true;
pub var reduced_motion_g: bool = false;
pub var settings_g: Settings = .{};
pub var desktop_enable_animations_g: bool = true;

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
pub var observe_active: bool = false;
pub var observe_changed: bool = false;
pub var observe_longest_ms: i64 = 0;

pub fn observeBegin() void {
    observe_active = false;
    observe_changed = false;
    observe_longest_ms = 0;
}

pub fn observeElapsed(start_ms: i64, now_ms: i64) void {
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
    if (frame_ms) |ms| return ms;
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

pub fn resetGlobals() void {
    override_ms = null;
    frame_ms = null;
    speed_g = 1.0;
    enabled_g = true;
    reduced_motion_g = false;
    settings_g = .{};
    desktop_enable_animations_g = true;
    observeBegin();
}

test {
    _ = @import("anim_tests.zig");
}
