//! RediTerm, the terminal (`rediwm-terminal`). `src/rediterm/`.
const std = @import("std");
const App = @import("rediterm/app.zig").App;
const gpa = @import("memory").gpa;

const usage =
    \\Usage: rediwm-terminal [-e COMMAND [ARGUMENT...]]
    \\
    \\RediTerm, a terminal for RediWM. Starts your shell in the current
    \\directory, or runs COMMAND in the first tab. The window closes when
    \\its last tab exits.
    \\
    \\Ctrl+Shift+T / Ctrl+Shift+W: open / close tab
    \\Ctrl+Shift+C / Ctrl+Shift+V: copy / paste    Shift+Insert: paste
    \\Shift+Page Up / Page Down: scroll history    Shift: select over mouse-aware programs
    \\
;

pub fn main(init: std.process.Init) !void {
    defer {
        if (@import("memory").deinit()) std.log.err("RediTerm memory leaks reported above", .{});
    }
    defer @import("ui").text.deinit();
    defer @import("ui").shell_icons.deinit();
    @import("i18n").init(init.minimal.environ);

    const args = init.minimal.args.vector;
    var command: ?[]?[*:0]const u8 = null;
    defer if (command) |argv| gpa.free(argv);
    if (args.len > 1) {
        const first = std.mem.span(args[1]);
        if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
            std.debug.print("{s}", .{usage});
            return;
        }
        if (!std.mem.eql(u8, first, "-e") or args.len < 3) {
            std.debug.print("{s}", .{usage});
            return error.UnexpectedArgument;
        }
        // NULL-terminated for the helper's execvp.
        const argv = try gpa.alloc(?[*:0]const u8, args.len - 1);
        for (args[2..], 0..) |arg, i| argv[i] = arg;
        argv[argv.len - 1] = null;
        command = argv;
    }

    var cwd_buf: [4096]u8 = undefined;
    const directory: [:0]const u8 = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |cwd|
        std.mem.span(@as([*:0]const u8, @ptrCast(cwd)))
    else
        init.minimal.environ.getPosix("HOME") orelse "/";

    var app: App = .{ .directory = directory, .command = if (command) |argv| @ptrCast(argv.ptr) else null };
    defer app.deinit();
    try @import("app_kit").window.run(App, &app, init, .{
        .app_id = "rediwm-terminal",
        .default_width = 760,
        .default_height = 460,
        .min_width = 240,
        .min_height = 120,
    });
}
