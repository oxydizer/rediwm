//! Format ownership passes to the demux thread after probing. Workers use
//! private copies of stream parameters, including when reopening in software.
const std = @import("std");
const c = @import("c_av");
const hw = @import("hw.zig");

pub const ns_base: c.AVRational = .{ .num = 1, .den = std.time.ns_per_s };
const us_base: c.AVRational = .{ .num = 1, .den = c.AV_TIME_BASE };

pub const Stream = struct {
    index: c_int,
    params: *c.AVCodecParameters,
    codec: *const c.AVCodec,
    base: c.AVRational,
    interval: i64,

    fn find(format: *c.AVFormatContext, kind: c.AVMediaType, related: c_int) !Stream {
        var codec: ?*const c.AVCodec = null;
        const index = c.av_find_best_stream(format, kind, -1, related, @ptrCast(&codec), 0);
        if (index < 0 or codec == null) return error.StreamMissing;
        const stream = format.streams[@intCast(index)];
        var params: ?*c.AVCodecParameters = c.avcodec_parameters_alloc() orelse return error.OutOfMemory;
        errdefer c.avcodec_parameters_free(&params);
        if (c.avcodec_parameters_copy(params, stream.*.codecpar) < 0) return error.OutOfMemory;
        const rate = stream.*.avg_frame_rate;
        return .{ .index = index, .params = params.?, .codec = codec.?, .base = stream.*.time_base, .interval = if (rate.num > 0 and rate.den > 0) c.av_rescale(rate.den, std.time.ns_per_s, rate.num) else 0 };
    }

    fn deinit(self: Stream) void {
        var params: ?*c.AVCodecParameters = self.params;
        c.avcodec_parameters_free(&params);
    }

    pub fn open(self: Stream, device: ?*const hw.Device) !*c.AVCodecContext {
        const codec = if (device != null) hw.decoderFor(self.codec) orelse return error.NoHardwareCodec else self.codec;
        var raw: ?*c.AVCodecContext = c.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
        errdefer c.avcodec_free_context(&raw);
        const decoder = raw.?;
        if (c.avcodec_parameters_to_context(decoder, self.params) < 0) return error.DecoderFailed;
        decoder.pkt_timebase = self.base;
        if (device) |d| {
            decoder.hw_device_ctx = c.av_buffer_ref(d.ref) orelse return error.OutOfMemory;
            decoder.get_format = hw.getFormat;
            decoder.extra_hw_frames = 9;
        } else decoder.thread_count = 0;
        if (c.avcodec_open2(decoder, codec, null) < 0) return error.DecoderFailed;
        std.log.info("decoding {s}{s}", .{ std.mem.span(codec.name), if (device != null) " (VAAPI)" else "" });
        return decoder;
    }
};

pub const Media = struct {
    format: *c.AVFormatContext,
    video: Stream,
    audio: ?Stream,
    origin: i64,
    duration: i64,
    width: i32,
    height: i32,

    pub fn open(path: [:0]const u8) !Media {
        var options: ?*c.AVDictionary = null;
        defer c.av_dict_free(&options);
        if (c.av_dict_set(&options, "protocol_whitelist", "file", 0) < 0) return error.OutOfMemory;
        var raw: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&raw, path.ptr, null, &options) < 0) return error.OpenFailed;
        errdefer c.avformat_close_input(&raw);
        const format = raw.?;
        if (c.avformat_find_stream_info(format, null) < 0) return error.ProbeFailed;
        const video = try Stream.find(format, c.AVMEDIA_TYPE_VIDEO, -1);
        errdefer video.deinit();
        const sar = c.av_guess_sample_aspect_ratio(format, format.streams[@intCast(video.index)], null);
        return .{ .format = format, .video = video, .audio = Stream.find(format, c.AVMEDIA_TYPE_AUDIO, video.index) catch |err| switch (err) {
            error.StreamMissing => null,
            else => return err,
        }, .origin = if (format.start_time == c.AV_NOPTS_VALUE) 0 else c.av_rescale_q(format.start_time, us_base, ns_base), .duration = if (format.duration > 0) c.av_rescale_q(format.duration, us_base, ns_base) else 0, .width = if (sar.num > 0 and sar.den > 0) std.math.lossyCast(i32, c.av_rescale(video.params.width, sar.num, sar.den)) else video.params.width, .height = video.params.height };
    }

    pub fn deinit(self: *Media) void {
        self.video.deinit();
        if (self.audio) |s| s.deinit();
        var raw: ?*c.AVFormatContext = self.format;
        c.avformat_close_input(&raw);
    }

    pub fn seek(self: *Media, target: i64) !void {
        const absolute = target +| self.origin;
        var stream = self.video;
        // A video keyframe can be several seconds into the file. Use the
        // audio index for targets in the audio-only introduction.
        if (self.audio) |audio| {
            const first = self.format.streams[@intCast(stream.index)].*.start_time;
            if (first != c.AV_NOPTS_VALUE and absolute < c.av_rescale_q(first, stream.base, ns_base)) stream = audio;
        }
        const timestamp = c.av_rescale_q(absolute, ns_base, stream.base);
        if (c.av_seek_frame(self.format, stream.index, timestamp, c.AVSEEK_FLAG_BACKWARD) < 0) return error.SeekFailed;
    }
};
