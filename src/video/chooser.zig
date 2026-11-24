//! Files owns the dialog. Its process handle wakes the Wayland loop on
//! completion, and closing the player also closes its outstanding chooser.
const std = @import("std");
const c = @import("c");
const platform = @import("platform");
const contract = @import("../files/chooser.zig");
const a = std.heap.c_allocator;

const tr = @import("app_kit").i18n.tr;

const video_types = [_]contract.Rule{
    .{ .kind = 1, .value = "video/mp4" },
    .{ .kind = 1, .value = "video/x-m4v" },
    .{ .kind = 1, .value = "video/matroska" },
    .{ .kind = 1, .value = "video/x-matroska" },
    .{ .kind = 1, .value = "video/webm" },
    .{ .kind = 1, .value = "video/quicktime" },
    .{ .kind = 1, .value = "video/x-msvideo" },
    .{ .kind = 1, .value = "video/mpeg" },
    .{ .kind = 1, .value = "video/mp2t" },
    .{ .kind = 1, .value = "video/ogg" },
    .{ .kind = 1, .value = "video/x-ogm+ogg" },
    .{ .kind = 1, .value = "video/x-flv" },
    .{ .kind = 1, .value = "video/3gpp" },
    .{ .kind = 1, .value = "video/3gpp2" },
    .{ .kind = 1, .value = "video/x-ms-wmv" },
};

pub const Chooser = struct {
    pub const Kind = enum { video, video_or_subtitles, subtitles };
    child: std.process.Child,
    handle: platform.child.Handle,
    result: std.Io.File,
    kind: Kind,

    pub fn open(io: std.Io, directory: []const u8, kind: Kind) !Chooser {
        const srt = [_]contract.Rule{.{ .kind = 0, .value = "*.[sS][rR][tT]" }};
        const all_media = video_types ++ srt;
        const options: contract.Options = .{
            .title = if (kind == .subtitles) tr("Open subtitles") else tr("Open File"),
            .current_folder = directory,
            .filters = &.{
                switch (kind) {
                    .video => .{ .name = tr("Videos"), .rules = &video_types },
                    .video_or_subtitles => .{ .name = tr("Videos and SRT subtitles"), .rules = &all_media },
                    .subtitles => .{ .name = tr("SRT subtitles"), .rules = &srt },
                },
                .{ .name = tr("All files"), .rules = &.{.{ .kind = 0, .value = "*" }} },
            },
        };
        const json = try std.json.Stringify.valueAlloc(a, options, .{});
        defer a.free(json);
        const input = try memFile("video-chooser-options");
        defer input.close(io);
        try input.writeStreamingAll(io, json);
        if (c.lseek(input.handle, 0, c.SEEK_SET) < 0) return error.SeekFailed;
        const result = try memFile("video-chooser-result");
        errdefer result.close(io);
        var buf: [platform.exe.max_path]u8 = undefined;
        var child = try std.process.spawn(io, .{
            .argv = &.{ platform.exe.siblingOrName(&buf, "rediwm-files"), "--chooser-stdin" },
            .stdin = .{ .file = input },
            .stdout = .{ .file = result },
        });
        errdefer child.kill(io);
        return .{ .child = child, .handle = try platform.child.Handle.open(child.id.?), .result = result, .kind = kind };
    }

    pub fn deinit(self: *Chooser, io: std.Io) void {
        if (self.child.id != null) self.child.kill(io);
        self.result.close(io);
        self.handle.close();
    }

    pub fn take(self: *Chooser, io: std.Io) !?[:0]u8 {
        const term = try self.child.wait(io);
        if (term != .exited or term.exited != 0) return error.ChooserFailed;
        const size = try self.result.length(io);
        if (size > 1024 * 1024) return error.InvalidResult;
        const bytes = try a.alloc(u8, @intCast(size));
        defer a.free(bytes);
        if (try self.result.readPositionalAll(io, bytes, 0) != size) return error.InvalidResult;
        const result = try std.json.parseFromSlice(contract.Result, a, bytes, .{ .ignore_unknown_fields = true });
        defer result.deinit();
        if (result.value.paths.len == 0) return null;
        const path = result.value.paths[0];
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        return try a.dupeSentinel(u8, path, 0);
    }
};

fn memFile(name: [*:0]const u8) !std.Io.File {
    const fd = c.memfd_create(name, c.MFD_CLOEXEC);
    if (fd < 0) return error.CreateFailed;
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}
