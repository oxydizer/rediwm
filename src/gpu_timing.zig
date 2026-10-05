const wlr = @import("wlroots");
const stats = @import("ipc/stats.zig");
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
    pub fn collect(self: *Timer) void {
        var samples: [8]Sample = undefined;
        var dropped: u64 = 0;
        const n = rediwm_gpu_timer_collect(self, stats.global_stats.generation, &samples, &dropped);
        stats.global_stats.gpu_samples_dropped +%= dropped;
        for (samples[0..n]) |sample| {
            if (sample.generation == stats.global_stats.generation)
                stats.global_stats.gpu_elapsed.record(sample.ns);
        }
    }
};
