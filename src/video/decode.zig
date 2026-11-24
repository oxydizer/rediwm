//! Each decoder is owned by one worker. Flush on a seek, drain on EOF and
//! keep the last pre-target picture for a seek beyond the last video PTS.
const c = @import("c_av");
const p = @import("pipeline.zig");
const media = @import("media.zig");
const hw = @import("hw.zig");
const Picture = @import("queue.zig").Picture;
const Converter = @import("audio.zig").Converter;

pub fn run(pipe: *p.Pipeline, kind: p.Kind) void {
    var worker: Worker = .{ .pipe = pipe, .kind = kind, .stream = if (kind == .video) pipe.media.video else pipe.media.audio.? };
    defer c.avcodec_free_context(&worker.codec);
    defer worker.converter.deinit();
    while (true) {
        pipe.lock();
        while (pipe.active(worker.gen)) pipe.wait();
        const stop = pipe.stop;
        const skip = kind == .audio and pipe.preview_only;
        worker.gen = pipe.generation;
        worker.target = pipe.target;
        worker.mode = pipe.seek_mode;
        const device = if (kind == .video) pipe.device else null;
        pipe.unlock();
        if (stop) return;
        if (skip) continue;
        worker.process(device) catch |err| pipe.fail(worker.gen, err, device != null);
    }
}

const Worker = struct {
    pipe: *p.Pipeline,
    kind: p.Kind,
    stream: media.Stream,
    codec: ?*c.AVCodecContext = null,
    hardware: bool = false,
    gen: u64 = 0,
    target: i64 = 0,
    mode: p.SeekMode = .exact,
    predicted: i64 = 0,
    before: ?Picture = null,
    converter: Converter = .{},

    fn process(self: *Worker, device: ?*const hw.Device) !void {
        const pipe = self.pipe;
        if (self.hardware != (device != null)) c.avcodec_free_context(&self.codec);
        self.hardware = device != null;
        if (self.codec == null) self.codec = try self.stream.open(device) else c.avcodec_flush_buffers(self.codec);
        self.converter.reset();
        self.predicted = self.target;
        defer self.clearBefore();
        const packets = pipe.packets(self.kind);
        while (true) {
            pipe.lock();
            while (pipe.active(self.gen) and !pipe.read_eof and packets.ring.count == 0) pipe.wait();
            if (!pipe.active(self.gen)) {
                pipe.unlock();
                return;
            }
            var pkt = packets.pop();
            pipe.broadcast();
            pipe.unlock();
            defer c.av_packet_free(&pkt);
            // receive() below runs to EAGAIN after every successful send.
            const rc = c.avcodec_send_packet(self.codec, pkt);
            if (rc == c.AVERROR_INVALIDDATA and !self.hardware and pkt != null) continue;
            if (rc < 0 and rc != c.AVERROR_EOF) return error.DecodeFailed;
            self.receive(device) catch |err| {
                if (err == error.DamagedPacket and !self.hardware and pkt != null) continue;
                return err;
            };
            if (pkt == null) break;
        }
        if (self.before) |pic| {
            self.before = null;
            pipe.picture(self.gen, pic);
        }
        if (self.kind == .audio) try self.converter.convert(pipe, self.gen, self.target, null, 0);
        pipe.lock();
        defer pipe.unlock();
        if (!pipe.active(self.gen)) return;
        if (self.kind == .video) {
            pipe.video_eof = true;
        } else {
            pipe.audio_eof = true;
            pipe.output.?.rv_audio_eof();
        }
        p.signal(pipe.main_fd);
    }

    fn clearBefore(self: *Worker) void {
        if (self.before) |pic| pic.free();
        self.before = null;
    }

    fn receive(self: *Worker, device: ?*const hw.Device) !void {
        while (true) {
            var raw: ?*c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;
            defer c.av_frame_free(&raw);
            const f = raw.?;
            const rc = c.avcodec_receive_frame(self.codec, f);
            if (rc == c.AVERROR_EOF or rc == c.AVERROR(c.EAGAIN)) return;
            if (rc == c.AVERROR_INVALIDDATA) return error.DamagedPacket;
            if (rc < 0) return error.DecodeFailed;
            const pts = if (f.best_effort_timestamp == c.AV_NOPTS_VALUE) self.predicted else c.av_rescale_q(f.best_effort_timestamp, self.stream.base, media.ns_base) -| self.pipe.media.origin;
            const duration = if (self.kind == .audio and f.sample_rate > 0)
                c.av_rescale(f.nb_samples, media.ns_base.den, f.sample_rate)
            else if (f.duration > 0) c.av_rescale_q(f.duration, self.stream.base, media.ns_base) else self.stream.interval;
            self.predicted = pts +| duration;
            if (self.kind == .audio) {
                try self.converter.convert(self.pipe, self.gen, self.target, f, pts);
            } else {
                // FFmpeg may negotiate a software pixel format on a VAAPI
                // context. Reopen the preferred software decoder permanently.
                if (device) |d| {
                    if (f.format != c.AV_PIX_FMT_VAAPI) return error.UnsupportedProfile;
                    // Complete the exportable surface before decoding ahead.
                    // On nvidia-vaapi-driver a later VP9 submission can
                    // otherwise leave the presenter's vaSyncSurface waiting.
                    if (!hw.sync(d.display, hw.surfaceOf(f))) return error.SurfaceSyncFailed;
                }
                const pic: Picture = .{ .frame = f, .pts = pts };
                raw = null;
                if (self.mode == .previous and pts >= self.target) {
                    if (self.before) |before| self.pipe.picture(self.gen, before);
                    self.before = null;
                    self.mode = .exact;
                }
                self.clearBefore();
                if (self.mode != .keyframe and pts < self.target) self.before = pic else self.pipe.picture(self.gen, pic);
            }
        }
    }
};
