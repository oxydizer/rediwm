//! rediwm-video: plays one local video file per window.
const std = @import("std");

const usage =
    \\Usage: rediwm-video [--start SECONDS] [--paused] [--hwdec=no] [FILE]
    \\
    \\Plays a local video file.
    \\  --start SECONDS  begin at this time
    \\  --paused         show the first frame and wait
    \\  --hwdec=no       decode in software
    \\
    \\Space pauses or resumes. Left/Right seek 5 s (Shift for 60 s).
    \\Click to pause or resume. Double-click or F toggles fullscreen. Escape leaves it.
    \\Up/Down adjust volume; M mutes. Comma/period step frames while paused.
    \\Ctrl+O opens a video. You can also drop a local file onto the window.
    \\
;

pub fn main(init: std.process.Init) !void {
    const kit = @import("app_kit");
    defer if (kit.memory.deinit()) std.log.err("video player memory leaks reported above", .{});
    kit.i18n.init(init.minimal.environ);
    const args = init.minimal.args.vector;
    var options: @import("video/player.zig").Options = .{ .path = undefined };
    var path: ?[:0]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, arg, "--start")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.start = std.fmt.parseFloat(f64, std.mem.span(args[i])) catch return error.InvalidArgument;
            if (!(options.start >= 0) or !std.math.isFinite(options.start)) return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--paused")) {
            options.paused = true;
        } else if (std.mem.eql(u8, arg, "--hwdec=no")) {
            options.hardware = false;
        } else if (std.mem.eql(u8, arg, "--")) {
            if (i + 1 < args.len) path = std.mem.span(args[i + 1]);
            break;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("{s}", .{usage});
            return error.UnexpectedArgument;
        } else path = std.mem.span(args[i]);
    }
    var selected: ?[:0]u8 = null;
    defer if (selected) |file| std.heap.c_allocator.free(file);
    if (path == null) {
        var dialog = try @import("video/chooser.zig").Chooser.open(init.io, "");
        defer dialog.deinit(init.io);
        selected = try dialog.take(init.io);
        path = selected orelse return;
    }
    options.path = path.?;
    try @import("video/player.zig").run(init, options);
}
