//! External SubRip tracks. FFmpeg demuxes the file once. Cue times stay on
//! the movie's relative clock, including while paused or seeking backwards.
const std = @import("std");
const c = @import("c_av");
const a = std.heap.c_allocator;
const ns_base = @import("media.zig").ns_base;

const Cue = struct {
    start: i64,
    end: i64,
    // A seek can stop looking backwards once all earlier cues have ended.
    latest_end: i64 = 0,
    text: []const u8,

    fn before(_: void, l: Cue, r: Cue) bool {
        return l.start < r.start;
    }
    fn compareStart(pos: i64, cue: Cue) std.math.Order {
        return std.math.order(pos, cue.start);
    }
};

pub const Track = struct {
    cues: std.ArrayList(Cue) = .empty,
    active: std.ArrayList(u8) = .empty,
    sampled: ?i64 = null,
    next: ?i64 = null,

    pub fn load(io: std.Io, path: [:0]const u8) !Track {
        const fd = try std.posix.openatZ(std.c.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, 0);
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.size > 8 * 1024 * 1024) return error.InvalidSubtitles;

        // Pass the verified local descriptor to the SRT demuxer.
        var options: ?*c.AVDictionary = null;
        defer c.av_dict_free(&options);
        if (c.av_dict_set_int(&options, "fd", fd, 0) < 0 or c.av_dict_set(&options, "protocol_whitelist", "fd", 0) < 0) return error.OutOfMemory;
        const srt = c.av_find_input_format("srt") orelse return error.MissingDemuxer;
        var raw: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&raw, "fd:", srt, &options) < 0) return error.InvalidSubtitles;
        defer c.avformat_close_input(&raw);
        const fmt = raw.?;
        var packet: ?*c.AVPacket = c.av_packet_alloc() orelse return error.OutOfMemory;
        defer c.av_packet_free(&packet);
        const pkt = packet.?;
        var track: Track = .{};
        errdefer track.deinit();
        while (true) {
            const rc = c.av_read_frame(fmt, pkt);
            if (rc == c.AVERROR_EOF) break;
            if (rc < 0) return error.InvalidSubtitles;
            defer c.av_packet_unref(pkt);
            if (pkt.size <= 0 or pkt.duration <= 0 or pkt.pts < 0) continue;
            const text = pkt.data[0..@intCast(pkt.size)];
            if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.UnsupportedEncoding;
            const base = fmt.streams[@intCast(pkt.stream_index)].*.time_base;
            const start = c.av_rescale_q(pkt.pts, base, ns_base);
            const end = c.av_rescale_q(pkt.pts +| pkt.duration, base, ns_base);
            if (start < 0 or end <= start) continue;
            try track.cues.ensureUnusedCapacity(a, 1);
            track.cues.appendAssumeCapacity(.{ .start = start, .end = end, .text = try plainText(text) });
        }
        if (track.cues.items.len == 0) return error.InvalidSubtitles;
        std.mem.sort(Cue, track.cues.items, {}, Cue.before);
        var latest: i64 = 0;
        for (track.cues.items) |*cue| {
            latest = @max(latest, cue.end);
            cue.latest_end = latest;
        }
        return track;
    }

    pub fn deinit(self: *Track) void {
        for (self.cues.items) |cue| a.free(cue.text);
        self.cues.deinit(a);
        self.active.deinit(a);
    }

    /// Rebuild the displayed lines only on a seek or cue boundary. The end
    /// is exclusive, so back-to-back cues switch on the same clock tick.
    pub fn update(self: *Track, pos: i64) !bool {
        if (self.sampled) |last| {
            if (pos >= last and (self.next == null or pos < self.next.?)) return false;
        }
        const cues = self.cues.items;
        const limit = std.sort.upperBound(Cue, cues, pos, Cue.compareStart);
        var first = limit;
        while (first > 0 and cues[first - 1].latest_end > pos) first -= 1;
        self.active.clearRetainingCapacity();
        self.next = if (limit < cues.len) cues[limit].start else null;
        for (cues[first..limit]) |cue| {
            if (cue.end <= pos) continue;
            self.next = @min(self.next orelse cue.end, cue.end);
            if (self.active.items.len > 0) try self.active.append(a, '\n');
            try self.active.appendSlice(a, cue.text);
        }
        self.sampled = pos;
        return true;
    }
};

// SubRip commonly carries inline formatting. Render the dialogue as plain
// text, keeping literal angle brackets that do not introduce a known tag.
fn plainText(raw: []const u8) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    var rest = raw;
    while (std.mem.indexOfScalar(u8, rest, '<')) |start| {
        try text.appendSlice(a, rest[0..start]);
        rest = rest[start..];
        const stop = std.mem.indexOfAny(u8, rest[1..], "<>\n") orelse break;
        const tag = std.mem.trim(u8, rest[1 .. stop + 1], " /\t");
        var name = std.mem.tokenizeAny(u8, tag, " \t");
        const word = name.next() orelse "";
        var known = false;
        for ([_][]const u8{ "i", "b", "u", "s", "font" }) |style| {
            if (std.ascii.eqlIgnoreCase(word, style)) known = true;
        }
        if (rest[stop + 1] == '>' and known) {
            rest = rest[stop + 2 ..];
        } else {
            try text.append(a, '<');
            rest = rest[1..];
        }
    }
    try text.appendSlice(a, rest);
    return text.toOwnedSlice(a);
}

test "external SubRip timing, overlap, seek, line breaks and invalid replacement" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "film.srt", .data = "\xef\xbb\xbf1\r\n00:00:02,250 --> 00:00:04,500\r\nJosé < 5\r\n\r\n" ++
        "2\r\n00:00:01,125 --> 00:00:03,000\r\n<i>First</i>\r\nline\r\n\r\n" ++
        "3\r\n00:00:04,500 --> 00:00:05,000\r\nLast" });
    const path = try tmp.dir.realPathFileAlloc(io, "film.srt", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var track = try Track.load(io, path);
    defer track.deinit();
    const ms = std.time.ns_per_ms;
    for ([_]struct { i64, []const u8, ?i64 }{
        .{ 0, "", 1125 },        .{ 1125, "First\nline", 2250 },
        .{ 2250, "First\nline\nJosé < 5", 3000 },
        .{ 3000, "José < 5", 4500 },
        .{ 4500, "Last", 5000 }, .{ 5000, "", null },
        .{ 2400, "First\nline\nJosé < 5", 3000 },
    }) |sample| {
        try std.testing.expect(try track.update(sample[0] * ms));
        try std.testing.expectEqualStrings(sample[1], track.active.items);
        try std.testing.expectEqual(if (sample[2]) |t| t * ms else null, track.next);
        try std.testing.expect(!try track.update(sample[0] * ms + 1));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "film.srt", .data = "not a subtitle file\n" });
    try std.testing.expectError(error.InvalidSubtitles, Track.load(io, path));
}
