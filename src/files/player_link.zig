//! Files' view of rediwm-player: what it is playing, over the GLib thread in
//! player_link.c (which only transports).
const std = @import("std");
const c = @import("c_player_link");

pub const State = struct {
    /// No player, playing or paused.
    status: enum { none, playing, paused } = .none,
    /// The current track's file name.
    path: [1024]u8 = @splat(0),
    position_us: i64 = 0,
    length_us: i64 = 0,
    /// CLOCK_MONOTONIC milliseconds of the position reading (`app_draw.nowMs`'s clock).
    stamp_ms: i64 = 0,

    pub fn file(self: *const State) []const u8 {
        return std.mem.sliceTo(&self.path, 0);
    }

    pub fn isTrack(self: *const State, path: []const u8) bool {
        return self.status != .none and std.mem.eql(u8, self.file(), path);
    }

    /// Where the track is at `now_ms` (the same clock as `stamp_ms`), as a
    /// fraction of its length; 0 when the length is unknown.
    pub fn fraction(self: *const State, now_ms: i64) f64 {
        if (self.length_us <= 0) return 0;
        var position: f64 = @floatFromInt(self.position_us);
        if (self.status == .playing) position += @as(f64, @floatFromInt(@max(0, now_ms - self.stamp_ms))) * 1000;
        return std.math.clamp(position / @as(f64, @floatFromInt(self.length_us)), 0, 1);
    }
};

pub const Playlist = struct {
    handle: *c.pl_playlist,
    pub fn deinit(self: Playlist) void {
        c.pl_playlist_free(self.handle);
    }
    pub fn count(self: Playlist) usize {
        return c.pl_playlist_count(self.handle);
    }
    pub fn path(self: Playlist, index: usize) []const u8 {
        return std.mem.span(c.pl_playlist_path(self.handle, @intCast(index)));
    }
};

pub const Link = struct {
    handle: *c.pl_link,

    pub fn start() ?Link {
        return .{ .handle = c.pl_start() orelse return null };
    }

    /// Ends the thread without waiting for it; the link is unusable after.
    pub fn stop(self: Link) void {
        c.pl_stop_link(self.handle);
    }

    pub fn wakeFd(self: Link) c_int {
        return c.pl_wake_fd(self.handle);
    }

    pub fn clearWake(self: Link) void {
        c.pl_clear_wake(self.handle);
    }

    /// Updates `state` if it changed since the last call; true if so.
    pub fn take(self: Link, state: *State) bool {
        var raw: c.pl_state = undefined;
        if (c.pl_take(self.handle, &raw) == 0) return false;
        state.* = .{
            .status = switch (raw.status) {
                1 => .playing,
                2 => .paused,
                else => .none,
            },
            .path = @bitCast(raw.path[0..1024].*),
            .position_us = raw.position_us,
            .length_us = raw.length_us,
            .stamp_ms = raw.stamp_ms,
        };
        return true;
    }

    /// `executable` and `path` must be NUL-terminated.
    pub fn play(self: Link, path: [*:0]const u8, executable: [*:0]const u8, scope: bool) void {
        c.pl_play(self.handle, path, executable, @intFromBool(scope));
    }

    pub fn stopPlayback(self: Link) void {
        c.pl_stop_playback(self.handle);
    }

    pub fn seek(self: Link, offset: i64) void {
        c.pl_seek(self.handle, offset);
    }

    pub fn playlist(self: Link) ?Playlist {
        return .{ .handle = c.pl_get_playlist(self.handle) orelse return null };
    }

    pub fn playPause(self: Link) void {
        c.pl_play_pause(self.handle);
    }
};
