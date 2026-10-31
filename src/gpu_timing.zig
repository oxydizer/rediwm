const wlr = @import("wlroots");
const stats = @import("ipc/stats.zig");
const late_render = @import("output/late_render.zig");
const Sample = extern struct { ns: u64, generation: u64 };

pub const Timer = opaque {
    extern fn rediwm_gpu_timer_create(renderer: *wlr.Renderer) ?*Timer;
    extern fn rediwm_gpu_timer_destroy(timer: *Timer) void;
    extern fn rediwm_gpu_timer_begin(timer: *Timer, generation: u64) bool;
    extern fn rediwm_gpu_timer_end(timer: *Timer) void;
    extern fn rediwm_gpu_timer_collect(timer: *Timer, generation: u64, samples: *[8]Sample, dropped: *u64) usize;
    pub const create = rediwm_gpu_timer_create;
    pub const destroy = rediwm_gpu_timer_destroy;
    pub const end = rediwm_gpu_timer_end;

    pub fn begin(self: *Timer) bool {
        const ok = rediwm_gpu_timer_begin(self, stats.global_stats.generation);
        if (!ok) stats.global_stats.gpu_samples_dropped +%= 1;
        return ok;
    }
    /// Records finished samples in the stats window and in `recent`, which
    /// keeps them whatever the stats generation (late rendering reads it).
    pub fn collect(self: *Timer, recent: *late_render.PeakRing(32)) void {
        var samples: [8]Sample = undefined;
        var dropped: u64 = 0;
        const n = rediwm_gpu_timer_collect(self, stats.global_stats.generation, &samples, &dropped);
        stats.global_stats.gpu_samples_dropped +%= dropped;
        for (samples[0..n]) |sample| {
            recent.push(sample.ns);
            if (sample.generation == stats.global_stats.generation)
                stats.global_stats.gpu_elapsed.record(sample.ns);
        }
    }
};
