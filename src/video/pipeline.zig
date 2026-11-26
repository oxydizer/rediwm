//! One reader and one decoder per active stream. A seek clears all queues
//! under the same lock. Work outside the lock carries its generation back
//! to the queue before publishing. All waits can be interrupted by a seek
//! or shutdown, including an audio producer waiting for callback space.
const std = @import("std");
const libc = @import("c");
const c = @import("c_av");
const wake = @import("platform").wake;
const q = @import("queue.zig");
const audio = @import("audio.zig");
const Media = @import("media.zig").Media;
const Stream = @import("media.zig").Stream;
const hw = @import("hw.zig");
const decode = @import("decode.zig");
const Device = audio.Device;

pub const SeekMode = enum { exact, keyframe, previous };
pub const Kind = enum { video, audio };
pub const Pipeline = struct {
    media: *Media,
    device: ?*const hw.Device,
    output: ?*Device = null,
    main_fd: c_int,
    space_fd: c_int,
    mutex: libc.pthread_mutex_t = undefined,
    cond: libc.pthread_cond_t = undefined,
    threads: [3]?std.Thread = @splat(null),
    stop: bool = false,
    generation: u64 = 1,
    target: i64,
    preview_only: bool,
    seek_mode: SeekMode = .exact,
    /// The audio stream being decoded; changes under the lock, and workers
    /// take it at the start of each generation (a seek always follows).
    audio: ?Stream,
    video: q.Packets = .{},
    audio_packets: q.Packets = .{},
    pictures: q.Ring(q.Picture, 6) = .{},
    read_eof: bool = false,
    video_eof: bool = false,
    audio_eof: bool = false,
    audio_ready: bool = false,
    failure: ?anyerror = null,
    retry_software: bool = false,

    pub fn init(media: *Media, device: ?*const hw.Device, target: i64, paused: bool, previous: ?*Pipeline) !*Pipeline {
        const self = try std.heap.c_allocator.create(Pipeline);
        errdefer std.heap.c_allocator.destroy(self);
        const main_fd = wake.create() orelse return error.EventFdFailed;
        errdefer _ = std.c.close(main_fd);
        const space_fd = wake.create() orelse return error.EventFdFailed;
        errdefer _ = std.c.close(space_fd);
        const audio_stream: ?Stream = if (media.default_track) |i| media.tracks[i] else null;
        self.* = .{ .media = media, .audio = audio_stream, .device = device, .main_fd = main_fd, .space_fd = space_fd, .target = target, .preview_only = paused };
        if (libc.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexFailed;
        errdefer _ = libc.pthread_mutex_destroy(&self.mutex);
        if (libc.pthread_cond_init(&self.cond, null) != 0) return error.CondFailed;
        errdefer _ = libc.pthread_cond_destroy(&self.cond);
        const shared = if (audio_stream != null and previous != null) previous.?.output else null;
        if (shared != null) {
            self.output = shared;
        } else if (audio_stream != null) {
            self.output = Device.rv_audio_open(space_fd, main_fd);
            if (self.output) |out| {
                out.rv_audio_reset();
            } else std.log.warn("audio device unavailable, playing video silently", .{});
        }
        errdefer if (shared == null) {
            if (self.output) |out| out.rv_audio_close();
        };
        errdefer self.join();
        // Stage all new workers before taking the stopped audio device from
        // the old movie. This also works for exclusive sound backends.
        self.lock();
        errdefer {
            self.stop = true;
            self.unlock();
        }
        self.threads[0] = try std.Thread.spawn(.{}, read, .{self});
        self.threads[1] = try std.Thread.spawn(.{}, decode.run, .{ self, Kind.video });
        if (self.output != null) self.threads[2] = try std.Thread.spawn(.{}, decode.run, .{ self, Kind.audio });
        if (shared) |out| {
            previous.?.join();
            previous.?.output = null;
            out.rv_audio_rebind(space_fd, main_fd);
            out.rv_audio_reset();
        }
        self.unlock();
        return self;
    }

    fn join(self: *Pipeline) void {
        self.lock();
        self.stop = true;
        self.broadcast();
        self.unlock();
        signal(self.space_fd);
        for (self.threads) |thread| if (thread) |t| t.join();
        self.threads = @splat(null);
        self.clear();
    }

    pub fn deinit(self: *Pipeline) void {
        self.join();
        if (self.output) |out| out.rv_audio_close();
        _ = libc.pthread_cond_destroy(&self.cond);
        _ = libc.pthread_mutex_destroy(&self.mutex);
        _ = std.c.close(self.space_fd);
        _ = std.c.close(self.main_fd);
        std.heap.c_allocator.destroy(self);
    }

    fn clear(self: *Pipeline) void {
        self.video.clear();
        self.audio_packets.clear();
        while (self.pictures.pop()) |pic| pic.free();
    }

    /// The caller stops the audio device before resetting the producer.
    pub fn seek(self: *Pipeline, target: i64, software: bool, paused: bool, mode: SeekMode) void {
        self.lock();
        defer self.unlock();
        self.generation += 1;
        self.target = target;
        self.preview_only = paused;
        self.seek_mode = mode;
        self.clear();
        if (software) self.device = null;
        if (self.output) |out| out.rv_audio_reset();
        self.read_eof = false;
        self.video_eof = false;
        self.audio_eof = false;
        self.audio_ready = false;
        self.retry_software = false;
        self.failure = null;
        self.broadcast();
        signal(self.space_fd);
    }

    /// Pick another audio stream. The caller seeks afterwards, which starts a
    /// generation whose workers use it.
    pub fn selectAudio(self: *Pipeline, stream: Stream) void {
        self.lock();
        defer self.unlock();
        self.audio = stream;
    }

    pub fn lock(self: *Pipeline) void {
        _ = libc.pthread_mutex_lock(&self.mutex);
    }
    pub fn unlock(self: *Pipeline) void {
        _ = libc.pthread_mutex_unlock(&self.mutex);
    }
    pub fn wait(self: *Pipeline) void {
        _ = libc.pthread_cond_wait(&self.cond, &self.mutex);
    }
    pub fn broadcast(self: *Pipeline) void {
        _ = libc.pthread_cond_broadcast(&self.cond);
    }
    pub fn active(self: *const Pipeline, generation: u64) bool {
        return !self.stop and self.generation == generation;
    }
    pub fn packets(self: *Pipeline, kind: Kind) *q.Packets {
        return if (kind == .audio) &self.audio_packets else &self.video;
    }

    fn read(self: *Pipeline) void {
        var previous: u64 = 0;
        while (true) {
            self.lock();
            while (self.active(previous)) self.wait();
            const gen = self.generation;
            // At a keyframe boundary a backward step needs the preceding
            // GOP. Move one stream tick before the displayed timestamp.
            const tick = @max(1, c.av_rescale_q(1, self.media.video.base, @import("media.zig").ns_base));
            const target = if (self.seek_mode == .previous) @max(0, self.target -| tick) else self.target;
            const stop = self.stop;
            const with_audio = self.output != null and !self.preview_only;
            const audio_stream = self.audio;
            self.unlock();
            if (stop) return;
            self.readGeneration(gen, previous != 0 or target > 0, target, with_audio, audio_stream) catch |err| self.fail(gen, err, false);
            previous = gen;
        }
    }

    fn readGeneration(self: *Pipeline, gen: u64, needs_seek: bool, target: i64, with_audio: bool, audio_stream: ?Stream) !void {
        if (needs_seek) try self.media.seek(target, audio_stream);
        while (true) {
            self.lock();
            const live = self.active(gen);
            self.unlock();
            if (!live) return;
            var raw: ?*c.AVPacket = c.av_packet_alloc() orelse return error.OutOfMemory;
            defer c.av_packet_free(&raw);
            const pkt = raw.?;
            const result = c.av_read_frame(self.media.format, pkt);
            if (result == c.AVERROR_EOF) {
                self.lock();
                defer self.unlock();
                if (self.active(gen)) {
                    self.read_eof = true;
                    self.broadcast();
                }
                return;
            }
            if (result < 0) return error.DemuxFailed;
            const video = pkt.stream_index == self.media.video.index;
            if (!video and (!with_audio or pkt.stream_index != audio_stream.?.index)) continue;
            const stream = if (video) self.media.video else audio_stream.?;
            const duration = @max(0, c.av_rescale_q(pkt.duration, stream.base, @import("media.zig").ns_base));
            const queue = self.packets(if (video) .video else .audio);
            self.lock();
            defer self.unlock();
            while (self.active(gen) and !queue.fits(@intCast(pkt.size), duration)) self.wait();
            if (!self.active(gen)) return;
            queue.push(pkt, duration);
            raw = null;
            self.broadcast();
        }
    }

    pub fn fail(self: *Pipeline, gen: u64, err: anyerror, retry: bool) void {
        self.lock();
        defer self.unlock();
        if (!self.active(gen)) return;
        if (retry) self.retry_software = true else self.failure = err;
        signal(self.main_fd);
    }

    pub fn picture(self: *Pipeline, gen: u64, pic: q.Picture) void {
        self.lock();
        defer self.unlock();
        while (self.active(gen) and self.pictures.full()) self.wait();
        if (!self.active(gen)) return pic.free();
        if (self.pictures.count == 0) signal(self.main_fd);
        self.pictures.push(pic);
    }

    pub fn writeAudio(self: *Pipeline, gen: u64, pcm: []const f32, begin: i64) !void {
        var offset: usize = 0;
        while (offset < pcm.len / 2) {
            self.lock();
            if (!self.active(gen)) {
                self.unlock();
                return;
            }
            const n = self.output.?.rv_audio_write(pcm[offset * 2 ..].ptr, @intCast(pcm.len / 2 - offset), begin + @as(i64, @intCast(offset)));
            if (n > 0 and !self.audio_ready) {
                self.audio_ready = true;
                signal(self.main_fd);
            }
            self.unlock();
            offset += n;
            if (n > 0) continue;
            var fds = [_]std.posix.pollfd{.{ .fd = self.space_fd, .events = std.posix.POLL.IN, .revents = 0 }};
            _ = try std.posix.poll(&fds, -1);
            drain(self.space_fd);
        }
    }
};

pub fn signal(fd: c_int) void {
    const one: u64 = 1;
    while (std.posix.errno(std.c.write(fd, std.mem.asBytes(&one), 8)) == .INTR) {}
}
pub fn drain(fd: c_int) void {
    var count: u64 = undefined;
    while (std.posix.errno(std.c.read(fd, std.mem.asBytes(&count), 8)) == .INTR) {}
}
