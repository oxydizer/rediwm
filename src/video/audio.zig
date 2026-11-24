//! FFmpeg audio is resampled to the miniaudio callback's stereo f32 format.
//! All resampler state belongs to the audio decode thread.
const std = @import("std");
const c = @import("c_av");
const media = @import("media.zig");

pub const Device = opaque {
    pub extern fn rv_audio_open(space_fd: c_int, main_fd: c_int) ?*Device;
    pub extern fn rv_audio_close(*Device) void;
    pub extern fn rv_audio_rebind(*Device, c_int, c_int) void;
    pub extern fn rv_audio_reset(*Device) void;
    pub extern fn rv_audio_volume(*Device, c_uint) void;
    pub extern fn rv_audio_start(*Device) c_int;
    pub extern fn rv_audio_stop(*Device) void;
    pub extern fn rv_audio_eof(*Device) void;
    pub extern fn rv_audio_drained(*Device) c_int;
    pub extern fn rv_audio_clock(*Device) i64;
    pub extern fn rv_audio_first(*Device) i64;
    pub extern fn rv_audio_write(*Device, [*]const f32, c_uint, i64) c_uint;
};

pub const rate = 48000;
const samples: c.AVRational = .{ .num = 1, .den = rate };
pub const Converter = struct {
    swr: ?*c.SwrContext = null,
    layout: c.AVChannelLayout = std.mem.zeroes(c.AVChannelLayout),
    hz: c_int = 0,
    format: c_int = -1,
    buffer: std.ArrayList(f32) = .empty,
    // Output sample position in the common media timeline.
    cursor: ?i64 = null,

    pub fn reset(self: *Converter) void {
        c.swr_free(&self.swr);
        c.av_channel_layout_uninit(&self.layout);
        self.cursor = null;
    }

    pub fn deinit(self: *Converter) void {
        self.reset();
        self.buffer.deinit(std.heap.c_allocator);
    }

    pub fn convert(self: *Converter, pipe: *@import("pipeline.zig").Pipeline, gen: u64, target: i64, frame: ?*c.AVFrame, pts: i64) !void {
        if (frame) |f| {
            if (f.sample_rate <= 0) return error.InvalidAudioRate;
            if (self.swr == null or self.hz != f.sample_rate or self.format != f.format or c.av_channel_layout_compare(&self.layout, &f.ch_layout) != 0) {
                self.reset();
                self.hz = f.sample_rate;
                self.format = f.format;
                var stereo: c.AVChannelLayout = undefined;
                c.av_channel_layout_default(&stereo, 2);
                defer c.av_channel_layout_uninit(&stereo);
                if (c.av_channel_layout_copy(&self.layout, &f.ch_layout) < 0 or
                    c.swr_alloc_set_opts2(&self.swr, &stereo, c.AV_SAMPLE_FMT_FLT, rate, &f.ch_layout, f.format, f.sample_rate, 0, null) < 0 or
                    c.swr_init(self.swr) < 0) return error.ResamplerFailed;
            }
            const start = c.av_rescale_q(pts, media.ns_base, samples) - c.swr_get_delay(self.swr, rate);
            // Container timestamps (notably WebM) may be rounded to ms.
            if (self.cursor == null or @abs(start - self.cursor.?) > rate / 100) self.cursor = start;
        }
        if (self.swr == null) return;
        const count = if (frame) |f| f.nb_samples else 0;
        const max = c.swr_get_out_samples(self.swr, count);
        if (max < 0) return error.ResamplerFailed;
        try self.buffer.resize(std.heap.c_allocator, @as(usize, @intCast(max)) * 2);
        var dest = [_][*c]u8{@ptrCast(self.buffer.items.ptr)};
        const n = c.swr_convert(self.swr, &dest, max, if (frame) |f| @ptrCast(f.extended_data) else null, count);
        if (n < 0) return error.ResamplerFailed;
        const begin = self.cursor.?;
        self.cursor = begin + n;
        const skip = std.math.clamp(c.av_rescale_q(target, media.ns_base, samples) - begin, 0, @as(i64, n));
        if (skip < n) try pipe.writeAudio(gen, self.buffer.items[@intCast(skip * 2)..@intCast(n * 2)], begin + skip);
    }
};
