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
const Track = @import("subtitles.zig").Track;
const max_audio_tracks = @import("subtitle_menu.zig").max_audio_tracks;
const a = std.heap.c_allocator;
const Pool = @import("software.zig").Pool;

pub const Options = struct {
    path: ?[:0]const u8 = null,
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

    var player: Player = .{
        .window = &window,
        .io = init.io,
        .watch = &watch,
        .hardware = options.hardware,
        .paused = options.paused,
        .clock = .{ .media = std.math.lossyCast(i64, options.start * std.time.ns_per_s) },
    };
    defer player.deinit();
    if (options.path) |path| try player.loadMovie(path);
    window.osd.empty = player.pipe == null;
    if (window.osd.empty) window.osd.reveal();
    try window.map(if (options.path) |path| std.fs.path.basename(path) else tr("Videos"), "rediwm-video");
    defer window.deinit();
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
    pipe: ?*Pipeline = null,
    hardware: bool,
    device: ?hw.Device = null,
    cache: ?Cache = null,
    pool: Pool = .{},
    // A shm release may be needed before this frame can be committed.
    pending: ?Picture = null,
    preview: bool = true,
    started: bool = false,
    audio_track: ?usize = null,
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
    subtitles: ?Track = null,
    show_subtitles: bool = false,
    gain: ?u32 = null,
    last_pts: ?i64 = null,
    stepping: bool = false,
    scrub_playing: ?bool = null,

    fn closeMovie(self: *Player) void {
        const pipe = self.pipe orelse return;
        if (self.subtitles) |*track| track.deinit();
        self.subtitles = null;
        self.show_subtitles = false;
        self.stopAudio();
        const media = pipe.media;
        pipe.deinit();
        self.pipe = null;
        media.deinit();
        a.destroy(media);
        if (self.pending) |pic| pic.free();
        self.pending = null;
        a.free(self.path);
        self.path = "";
    }

    fn decodeDevice(self: *Player) ?*const hw.Device {
        // Keep a software fallback in effect across movie changes.
        if (self.pipe) |pipe| return pipe.device;
        if (!self.hardware) return null;
        if (self.device) |*device| return device;
        const dmabuf = self.window.dmabuf orelse return null;
        const dev = self.window.feedback.main_device orelse return null;
        var buf: [64]u8 = undefined;
        const node = hw.renderNode(dev, &buf) orelse return null;
        self.device = hw.Device.open(node) orelse return null;
        self.cache = .{ .display = self.window.display, .dmabuf = dmabuf, .va = self.device.?.display };
        return &self.device.?;
    }

    fn loadMovie(self: *Player, path: [:0]const u8) !void {
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
        const target = if (self.pipe == null) clampSeek(media, self.clock.media) else 0;
        const paused = self.pipe == null and self.paused;
        const pipe = try Pipeline.init(media, self.decodeDevice(), target, paused, self.pipe);
        self.closeMovie();
        self.pipe = pipe;
        self.audio_track = media.default_track;
        self.path = owned;
        self.clock = .{ .media = target };
        self.paused = paused;
        self.started = false;
        self.ended = false;
        self.audio_finished = false;
        self.preview = true;
        self.last_pts = null;
        self.stepping = false;
        self.scrub_playing = null;
        self.gain = null;
        self.window.setVideoSize(media.width, media.height);
    }

    fn openMovie(self: *Player, path: [:0]const u8) !void {
        const sys = @import("c");
        var st: sys.struct_stat = undefined;
        if (sys.stat(path.ptr, &st) < 0 or (st.st_mode & sys.S_IFMT) != sys.S_IFREG) return error.InvalidFile;
        try self.loadMovie(path);
        self.window.osd.movieChanged();
        self.window.setTitle(std.fs.path.basename(path));
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
            _ = self.openFile(path, dialog.kind);
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
            drop.end(self.openFile(path, .video_or_subtitles));
        }
    }

    fn openFile(self: *Player, path: [:0]const u8, kind: Chooser.Kind) bool {
        if (kind == .subtitles or std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".srt")) {
            if (self.pipe == null) {
                self.window.osd.message(tr("Open a video before loading subtitles"));
                return false;
            }
            self.loadSubtitles(path) catch {
                self.window.osd.message(tr("Could not load subtitles"));
                return false;
            };
        } else self.openMovie(path) catch {
            self.window.osd.message(tr("Could not open file"));
            return false;
        };
        return true;
    }

    fn loadSubtitles(self: *Player, path: [:0]const u8) !void {
        const track = try Track.load(self.io, path);
        if (self.subtitles) |*old| old.deinit();
        self.subtitles = track;
        self.setSubtitles(true);
    }

    fn setSubtitles(self: *Player, enabled: bool) void {
        self.show_subtitles = enabled;
        self.window.osd.setSubtitlesEnabled(enabled);
        self.window.osd.message(if (enabled) tr("Subtitles on") else tr("Subtitles off"));
    }

    fn openChooser(self: *Player, kind: Chooser.Kind) void {
        if (self.chooser != null) return;
        self.chooser = Chooser.open(self.io, std.fs.path.dirname(self.path) orelse "", kind) catch null;
        if (self.chooser == null) self.window.osd.message(tr("Could not open the file chooser."));
    }

    fn discoverSubtitles(self: *Player) !void {
        if (self.subtitles != null) return;
        const ext = std.fs.path.extension(self.path);
        const sidecar = try std.fmt.allocPrintSentinel(a, "{s}.srt", .{self.path[0 .. self.path.len - ext.len]}, 0);
        defer a.free(sidecar);
        self.subtitles = try Track.load(self.io, sidecar);
    }

    fn toggleSubtitles(self: *Player) void {
        self.discoverSubtitles() catch |err| return switch (err) {
            error.FileNotFound => self.openChooser(.subtitles),
            else => self.window.osd.message(tr("Could not load subtitles")),
        };
        self.setSubtitles(!self.show_subtitles);
    }

    fn drawSubtitles(self: *Player, pos: i64, t: i64) !?i64 {
        const w = self.window;
        var text: []const u8 = "";
        var deadline: ?i64 = null;
        if (self.show_subtitles and !self.ended) {
            const track = &self.subtitles.?;
            const time = if (self.scrub_playing != null) self.last_pts orelse pos else pos;
            if (try track.update(time)) w.subtitles.dirty = true;
            text = track.active.items;
            if (self.started and !self.paused) {
                if (track.next) |next| deadline = t +| (next -| time);
            }
        }
        try w.subtitles.draw(w.root, text, w.osd.density, if (w.osd.visible) w.osd.top() else null);
        return deadline;
    }

    fn deinit(self: *Player) void {
        if (self.chooser) |*dlg| dlg.deinit(self.io);
        self.closeMovie();
        self.pool.deinit();
        if (self.cache) |*cache| cache.deinit();
        if (self.device) |*device| device.deinit();
        std.log.info("dropped {d} late video frames", .{self.dropped});
    }

    fn position(self: *Player, t: i64) i64 {
        if (self.audio_running) {
            const pipe = self.pipe.?;
            const pts = pipe.output.?.rv_audio_clock();
            if (pts != std.math.minInt(i64)) return @max(pipe.target, pts);
        }
        return self.clock.position(t);
    }

    fn stopAudio(self: *Player) void {
        if (self.audio_running) self.pipe.?.output.?.rv_audio_stop();
        self.audio_running = false;
    }

    fn seek(self: *Player, pos: i64, software: bool) void {
        self.seekMode(pos, software, .exact);
    }

    fn seekMode(self: *Player, pos: i64, software: bool, mode: pipeline.SeekMode) void {
        self.stopAudio();
        if (self.pending) |pic| pic.free();
        self.pending = null;
        const pipe = self.pipe.?;
        const target = clampSeek(pipe.media, pos);
        pipe.seek(target, software, self.paused, mode);
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
            self.openChooser(if (self.pipe == null) .video else .video_or_subtitles);
        }
        if (input.fullscreen) {
            input.fullscreen = false;
            if (self.window.input.fullscreen) self.window.toplevel.unsetFullscreen() else self.window.toplevel.setFullscreen(null);
        }
        const pipe = self.pipe orelse return;
        if (input.audio_menu) {
            input.audio_menu = false;
            var names: [max_audio_tracks][]const u8 = undefined;
            const tracks = pipe.media.tracks;
            const count = @min(tracks.len, names.len);
            for (tracks[0..count], 0..) |*track, i| names[i] = track.name();
            input.showAudioMenu(names[0..count], self.audio_track);
        }
        if (input.audio_pick) |index| {
            input.audio_pick = null;
            self.selectAudio(pipe, index);
        }
        if (input.toggle_subtitles) {
            input.toggle_subtitles = false;
            self.toggleSubtitles();
        }
        if (input.subtitle_action) |action| {
            input.subtitle_action = null;
            switch (action) {
                .menu => {
                    // Opening the menu can discover a matching file without
                    // enabling captions until the viewer selects it.
                    self.discoverSubtitles() catch {};
                    input.showMenu(if (self.subtitles) |track| track.name else null, self.show_subtitles);
                },
                .off => self.setSubtitles(false),
                .track => if (self.subtitles != null) self.setSubtitles(true),
                .load => self.openChooser(.subtitles),
            }
        }
        const gain: u32 = @intCast(if (input.muted) @as(i32, 0) else input.volume);
        if (gain != self.gain) {
            if (pipe.output) |out| out.rv_audio_volume(gain);
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
        if (!self.paused and pipe.preview_only and pipe.output != null) {
            self.seek(pos, false);
            return;
        }
        if (self.paused) self.stopAudio();
        self.clock.set(pos, t, self.started and !self.paused);
    }

    /// Switch the decoded audio stream and resume from where we are; after
    /// the end, the next replay uses the new stream.
    fn selectAudio(self: *Player, pipe: *Pipeline, index: usize) void {
        const tracks = pipe.media.tracks;
        if (index >= tracks.len or self.audio_track == index) return;
        self.audio_track = index;
        pipe.selectAudio(tracks[index]);
        if (!self.ended) self.seek(self.position(clocks.now()), false);
        self.window.osd.message(tracks[index].name());
    }

    fn sliderPosition(self: *Player, value: f32) i64 {
        return std.math.lossyCast(i64, @as(f64, @floatFromInt(self.pipe.?.media.duration)) * value);
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
            if (w.configured) {
                if (self.pipe) |pipe| {
                    deadline = earlier(deadline, try self.advance(pipe));
                    const now = clocks.now();
                    const pos = self.position(now);
                    deadline = earlier(deadline, try self.drawSubtitles(pos, now));
                    deadline = earlier(deadline, try w.osd.draw(pos, pipe.media.duration, self.paused or self.ended));
                } else deadline = earlier(deadline, try w.osd.draw(0, 0, true));
            }
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
                .{ .fd = if (self.pipe) |pipe| pipe.main_fd else -1, .events = std.posix.POLL.IN, .revents = 0 },
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
            if (fds[2].revents != 0) pipeline.drain(fds[2].fd);
            if (fds[3].revents != 0 and self.watch.poll() and w.configured) w.layout();
            if (fds[4].revents != 0) self.readChoice();
            if (fds[5].revents != 0) self.readDrop();
        }
    }

    fn advance(self: *Player, pipe: *Pipeline) !?i64 {
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
        const timed = !self.paused and !self.preview and self.window.pacing.timed();
        var revisit = false;
        pipe.lock();
        while (pipe.pictures.first()) |next| {
            if (self.paused) {
                if (!self.preview or self.pending != null) break;
            } else if (self.window.pacing.waitUntil(next.pts, pos, t, timed)) |due| {
                deadline = @min(deadline orelse due, due);
                break;
            } else if (timed and self.pending != null and next.pts > pos) {
                // Show the due picture before consuming a future one.
                revisit = true;
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
            if (!try self.present(pic.frame, if (timed) t +| (pic.pts -| pos) else null)) return deadline;
            if (revisit) deadline = earlier(deadline, @max(t, self.window.pacing.submitted_until));
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

    fn present(self: *Player, frame: *c.AVFrame, target: ?i64) !bool {
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
        window.show(shown, target);
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
