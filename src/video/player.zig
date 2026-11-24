//! The Wayland thread owns presentation, input and device start/stop.
//! Workers publish pictures and PCM independently of the presentation clock.
const std = @import("std");
const c = @import("c_av");
const wl = @import("wayland").client.wl;
const hw = @import("hw.zig");
const Media = @import("media.zig").Media;
const Cache = @import("buffers.zig").Cache;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const pipeline = @import("pipeline.zig");
const Pipeline = pipeline.Pipeline;
const Picture = @import("queue.zig").Picture;
const clocks = @import("clock.zig");
const tr = @import("app_kit").i18n.tr;
const Watch = @import("app_kit").settings_watch.Watch;
const Chooser = @import("chooser.zig").Chooser;
const a = std.heap.c_allocator;
const Pool = @import("software.zig").Pool;

pub const Options = struct {
    path: [:0]const u8,
    start: f64 = 0,
    paused: bool = false,
    hardware: bool = true,
};

pub fn run(init: std.process.Init, options: Options) !void {
    defer @import("ui").text.deinit();
    defer @import("ui").shell_icons.deinit();
    defer @import("app_kit").settings.deinitTheme();
    var watch = try Watch.init(init.io, init.minimal.environ);
    defer watch.deinit();
    c.av_log_set_level(c.AV_LOG_ERROR);
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    var window: Window = .{ .display = display };
    try window.connect();

    var node_buf: [64]u8 = undefined;
    var device: ?hw.Device = null;
    if (options.hardware and window.dmabuf != null) {
        if (window.feedback.main_device) |dev| {
            if (hw.renderNode(dev, &node_buf)) |node| device = hw.Device.open(node);
        }
    }
    defer if (device) |*d| d.deinit();
    const media = try load(options.path);
    const target = clampSeek(media, std.math.lossyCast(i64, options.start * std.time.ns_per_s));
    const pipe = Pipeline.init(media, if (device) |*d| d else null, target, options.paused, null) catch |err| {
        media.deinit();
        a.destroy(media);
        return err;
    };
    var player: Player = .{ .window = &window, .pipe = pipe, .paused = options.paused, .clock = .{ .media = target }, .io = init.io, .watch = &watch };
    defer player.deinit();
    player.path = try a.dupe(u8, options.path);
    window.setVideoSize(media.width, media.height);
    try window.map(std.fs.path.basename(options.path), "rediwm-video");
    defer window.deinit();
    if (device) |*d| player.cache = .{ .display = display, .dmabuf = window.dmabuf.?, .va = d.display };
    try player.loop();
}

fn load(path: [:0]const u8) !*Media {
    const media = try a.create(Media);
    errdefer a.destroy(media);
    media.* = try Media.open(path);
    return media;
}

fn clampSeek(media: *const Media, target: i64) i64 {
    return std.math.clamp(target, 0, if (media.duration > 0) media.duration - 1 else std.math.maxInt(i64));
}

const Player = struct {
    window: *Window,
    pipe: *Pipeline,
    cache: ?Cache = null,
    pool: Pool = .{},
    // A shm release may be needed before this frame can be committed.
    pending: ?Picture = null,
    preview: bool = true,
    started: bool = false,
    ended: bool = false,
    audio_running: bool = false,
    audio_finished: bool = false,
    paused: bool,
    clock: clocks.Clock,
    dropped: usize = 0,
    path: []const u8 = "",
    io: std.Io,
    watch: *Watch,
    chooser: ?Chooser = null,
    gain: ?u32 = null,
    last_pts: ?i64 = null,
    stepping: bool = false,
    scrub_playing: ?bool = null,

    fn closeMovie(self: *Player) void {
        self.stopAudio();
        const media = self.pipe.media;
        self.pipe.deinit();
        media.deinit();
        a.destroy(media);
        if (self.pending) |pic| pic.free();
        self.pending = null;
    }

    fn openMovie(self: *Player, path: [:0]const u8) !void {
        const sys = @import("c");
        var st: sys.struct_stat = undefined;
        if (sys.stat(path.ptr, &st) < 0 or (st.st_mode & sys.S_IFMT) != sys.S_IFREG) return error.InvalidFile;
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        const media = try load(path);
        errdefer {
            media.deinit();
            a.destroy(media);
        }
        if (self.audio_running) {
            const t = clocks.now();
            self.clock.set(self.position(t), t, true);
            self.stopAudio();
        }
        const pipe = try Pipeline.init(media, self.pipe.device, 0, false, self.pipe);
        self.closeMovie();
        self.pipe = pipe;
        a.free(self.path);
        self.path = owned;
        self.clock = .{};
        self.paused = false;
        self.started = false;
        self.ended = false;
        self.audio_finished = false;
        self.preview = true;
        self.last_pts = null;
        self.stepping = false;
        self.scrub_playing = null;
        self.gain = null;
        self.window.osd.movieChanged();
        self.window.setTitle(std.fs.path.basename(path));
        self.window.setVideoSize(media.width, media.height);
        if (self.window.configured) self.window.layout();
    }

    fn readChoice(self: *Player) void {
        const dialog = if (self.chooser) |*dlg| dlg else return;
        defer {
            dialog.deinit(self.io);
            self.chooser = null;
        }
        const selected = dialog.take(self.io) catch {
            self.window.osd.message(tr("Could not open file"));
            return;
        };
        if (selected) |path| {
            defer a.free(path);
            self.openMovie(path) catch self.window.osd.message(tr("Could not open file"));
        }
    }

    fn readDrop(self: *Player) void {
        const drop = &self.window.drop;
        const selected = drop.read() catch {
            self.window.osd.message(tr("Invalid dropped list"));
            return;
        };
        if (selected) |path| {
            defer a.free(path);
            self.openMovie(path) catch {
                self.window.osd.message(tr("Could not open file"));
                drop.end(false);
                return;
            };
            drop.end(true);
        }
    }

    fn deinit(self: *Player) void {
        if (self.chooser) |*dlg| dlg.deinit(self.io);
        self.closeMovie();
        a.free(self.path);
        self.pool.deinit();
        if (self.cache) |*cache| cache.deinit();
        std.log.info("dropped {d} late video frames", .{self.dropped});
    }

    fn position(self: *Player, t: i64) i64 {
        if (self.audio_running) {
            const pts = self.pipe.output.?.rv_audio_clock();
            if (pts != std.math.minInt(i64)) return @max(self.pipe.target, pts);
        }
        return self.clock.position(t);
    }

    fn stopAudio(self: *Player) void {
        if (self.audio_running) self.pipe.output.?.rv_audio_stop();
        self.audio_running = false;
    }

    fn seek(self: *Player, pos: i64, software: bool) void {
        self.seekMode(pos, software, .exact);
    }

    fn seekMode(self: *Player, pos: i64, software: bool, mode: pipeline.SeekMode) void {
        self.stopAudio();
        if (self.pending) |pic| pic.free();
        self.pending = null;
        const target = clampSeek(self.pipe.media, pos);
        self.pipe.seek(target, software, self.paused, mode);
        self.clock.set(target, clocks.now(), false);
        self.preview = true;
        self.started = false;
        self.ended = false;
        self.audio_finished = false;
    }

    fn controls(self: *Player) void {
        const input = &self.window.osd;
        if (input.open) {
            input.open = false;
            if (self.chooser == null) {
                self.chooser = Chooser.open(self.io, std.fs.path.dirname(self.path) orelse "") catch null;
                if (self.chooser == null) input.message(tr("Could not open the file chooser."));
            }
        }
        if (input.fullscreen) {
            input.fullscreen = false;
            if (self.window.input.fullscreen) self.window.toplevel.unsetFullscreen() else self.window.toplevel.setFullscreen(null);
        }
        const gain: u32 = @intCast(if (input.muted) @as(i32, 0) else input.volume);
        if (gain != self.gain) {
            if (self.pipe.output) |out| out.rv_audio_volume(gain);
            self.gain = gain;
            input.dirty = true;
        }
        if (input.scrub_end) {
            input.scrub_end = false;
            if (self.scrub_playing) |playing| self.paused = !playing;
            self.scrub_playing = null;
            self.seek(self.sliderPosition(input.seek_to orelse input.seekValue()), false);
            input.seek_to = null;
        } else if (input.dragSeek() and input.seek_to != null and (self.scrub_playing == null or !self.preview)) {
            if (self.scrub_playing == null) self.scrub_playing = !self.paused and !self.ended;
            self.paused = true;
            self.seekMode(self.sliderPosition(input.seek_to.?), false, .keyframe);
            input.seek_to = null;
        }
        if (input.relative != 0) {
            self.seek(self.position(clocks.now()) +| input.relative *| std.time.ns_per_s, false);
            input.relative = 0;
        }
        if (!self.paused) input.steps = 0;
        if (input.steps != 0 and !self.preview) {
            const forward = input.steps > 0;
            input.steps += if (forward) @as(i32, -1) else 1;
            const pts = self.last_pts orelse self.clock.media;
            self.stepping = true;
            self.seekMode(if (forward) pts +| 1 else pts, false, if (forward) .exact else .previous);
        }
        if (!input.toggle) return;
        input.toggle = false;
        if (self.ended) {
            self.paused = false;
            self.seek(0, false);
            return;
        }
        const t = clocks.now();
        const pos = self.position(t);
        self.paused = !self.paused;
        // A paused seek primes only video. Otherwise an audio lead longer
        // than both bounded queues could block delivery of the still frame.
        if (!self.paused and self.pipe.preview_only and self.pipe.output != null) {
            self.seek(pos, false);
            return;
        }
        if (self.paused) self.stopAudio();
        self.clock.set(pos, t, self.started and !self.paused);
    }

    fn sliderPosition(self: *Player, value: f32) i64 {
        return std.math.lossyCast(i64, @as(f64, @floatFromInt(self.pipe.media.duration)) * value);
    }

    fn loop(self: *Player) !void {
        const display = self.window.display;
        const sys = @import("c");
        const timer = sys.timerfd_create(sys.CLOCK_MONOTONIC, sys.TFD_CLOEXEC | sys.TFD_NONBLOCK);
        if (timer < 0) return error.TimerFailed;
        defer _ = std.c.close(timer);
        var armed: ?i64 = null;
        while (!self.window.closed) {
            if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
            if (self.window.closed) break;
            const w = self.window;
            const t = clocks.now();
            var deadline = w.osd.tick(t);
            self.controls();
            deadline = earlier(deadline, try self.advance());
            if (w.configured) deadline = earlier(deadline, try w.osd.draw(self.position(t), self.pipe.media.duration, self.paused or self.ended));
            w.input.syncCursor();
            w.playing(self.started and !self.preview and !self.paused and !self.ended);
            if (w.drop.deadline) |end| {
                if (t >= end) w.drop.end(false) else deadline = earlier(deadline, end);
            }
            if (armed != deadline) {
                var spec = std.mem.zeroes(sys.struct_itimerspec);
                if (deadline) |due| {
                    const ns = @max(1, due);
                    spec.it_value = .{ .tv_sec = @intCast(@divTrunc(ns, std.time.ns_per_s)), .tv_nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
                }
                if (sys.timerfd_settime(timer, sys.TFD_TIMER_ABSTIME, &spec, null) != 0) return error.TimerFailed;
                armed = deadline;
            }
            if (!display.prepareRead()) continue;
            const flushed = display.flush();
            if (flushed != .SUCCESS and flushed != .AGAIN) {
                display.cancelRead();
                return error.DisplayFailed;
            }
            var fds = [_]std.posix.pollfd{
                .{ .fd = display.getFd(), .events = std.posix.POLL.IN | @as(i16, if (flushed == .AGAIN) std.posix.POLL.OUT else 0), .revents = 0 },
                .{ .fd = timer, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.pipe.main_fd, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.watch.fd(), .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = if (self.chooser) |dlg| dlg.handle.fd else -1, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = w.drop.fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = std.posix.poll(&fds, -1) catch |err| {
                display.cancelRead();
                return err;
            };
            if (fds[0].revents & std.posix.POLL.IN != 0) {
                if (display.readEvents() != .SUCCESS) return error.DisplayFailed;
            } else display.cancelRead();
            if (fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) return error.DisplayFailed;
            if (fds[1].revents != 0) {
                pipeline.drain(timer);
                armed = null;
            }
            if (fds[2].revents != 0) pipeline.drain(self.pipe.main_fd);
            if (fds[3].revents != 0 and self.watch.poll() and w.configured) w.layout();
            if (fds[4].revents != 0) self.readChoice();
            if (fds[5].revents != 0) self.readDrop();
        }
    }

    fn advance(self: *Player) !?i64 {
        if (!self.window.configured) return null;
        const pipe = self.pipe;
        const t = clocks.now();
        pipe.lock();
        const err = pipe.failure;
        const retry = pipe.retry_software;
        const ready = pipe.audio_ready;
        const audio_eof = pipe.audio_eof;
        const has_picture = pipe.pictures.count > 0;
        const first_audio = if (ready and !self.audio_running and !self.audio_finished) pipe.output.?.rv_audio_first() else std.math.minInt(i64);
        pipe.unlock();
        if (err) |failure| return failure;
        if (retry) {
            self.fallback();
            return null;
        }
        if (!self.started and (has_picture or ready)) {
            self.clock.set(self.clock.media, t, !self.paused);
            self.started = true;
        }

        var deadline: ?i64 = null;
        if (!self.paused and !self.audio_finished) {
            const pos = self.position(t);
            if (self.audio_running and pipe.output.?.rv_audio_drained() != 0) {
                self.stopAudio();
                self.clock.set(pos, clocks.now(), true);
                self.audio_finished = true;
            } else if (!self.audio_running and first_audio != std.math.minInt(i64)) {
                if (first_audio <= pos) {
                    if (pipe.output.?.rv_audio_start() == 0) return error.AudioStartFailed;
                    self.audio_running = true;
                } else deadline = t +| (first_audio - pos);
            } else if (audio_eof and !self.audio_running) self.audio_finished = true;
        }

        const pos = self.position(t);
        pipe.lock();
        while (pipe.pictures.first()) |next| {
            if (self.paused) {
                if (!self.preview or self.pending != null) break;
            } else if (self.window.pacing.waitUntil(next.pts, pos, t)) |due| {
                deadline = @min(deadline orelse due, due);
                break;
            }
            if (self.pending) |old| {
                old.free();
                self.dropped += 1;
            }
            self.pending = pipe.pictures.pop();
            pipe.broadcast();
        }
        const exhausted = pipe.video_eof and pipe.pictures.count == 0;
        pipe.unlock();
        if (self.pending) |pic| {
            if (!try self.present(pic.frame)) return deadline;
            self.last_pts = pic.pts;
            if (self.stepping) {
                self.clock.set(pic.pts, t, false);
                self.stepping = false;
            }
            pic.free();
            self.pending = null;
            self.preview = false;
            if (self.window.osd.steps != 0 or self.window.osd.seek_to != null) deadline = t;
        }
        if (exhausted and self.preview) return error.NoFrames;
        if (exhausted and (pipe.output == null or self.audio_finished) and !self.ended and !self.paused) {
            self.ended = true;
            self.clock.set(pos, t, false);
        }
        return deadline;
    }

    fn fallback(self: *Player) void {
        std.log.info("switching to software decoding and shm", .{});
        self.seek(self.position(clocks.now()), true);
    }

    fn present(self: *Player, frame: *c.AVFrame) !bool {
        const window = self.window;
        const shown: window_mod.Frame = if (frame.format == c.AV_PIX_FMT_VAAPI) blk: {
            const cache = if (self.cache) |*cache| cache else return error.NoHardwareDevice;
            const buffer = cache.show(frame, &window.feedback) orelse {
                self.fallback();
                return false;
            };
            break :blk .{
                .buffer = buffer,
                .crop_x = @intCast(frame.crop_left),
                .crop_y = @intCast(frame.crop_top),
                .crop_w = frame.width - @as(i32, @intCast(frame.crop_left)),
                .crop_h = frame.height - @as(i32, @intCast(frame.crop_top)),
                .coefficients = coefficientsOf(frame),
                .range = if (frame.color_range == c.AVCOL_RANGE_JPEG) .full else .limited,
            };
        } else try self.pool.show(window.shm.?, window.ten_bit, frame) orelse return false;
        if (!self.paused) window.pacing.request(window.video);
        window.show(shown);
        return true;
    }
};

/// The matrix of `frame`; unspecified follows the usual convention (BT.709
/// for HD sizes, BT.601 below).
fn coefficientsOf(frame: *const c.AVFrame) window_mod.Coefficients {
    return switch (frame.colorspace) {
        c.AVCOL_SPC_BT709 => .bt709,
        c.AVCOL_SPC_BT470BG, c.AVCOL_SPC_SMPTE170M => .bt601,
        c.AVCOL_SPC_BT2020_NCL => .bt2020,
        c.AVCOL_SPC_BT2020_CL => .bt2020_cl,
        c.AVCOL_SPC_SMPTE240M => .smpte240,
        c.AVCOL_SPC_FCC => .fcc,
        else => if (frame.width >= 1280 or frame.height > 576) .bt709 else .bt601,
    };
}

fn earlier(a_time: ?i64, b_time: ?i64) ?i64 {
    return @min(a_time orelse return b_time, b_time orelse return a_time);
}
