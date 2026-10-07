const std = @import("std");
const main_mod = @import("files/main.zig");
const c = @import("files/c.zig").api;

fn printUsage() void {
    const usage =
        \\Usage: rediwm-files [DIRECTORY|FILE]
        \\
        \\A lightweight, standalone file browser for Wayland. A file opens its folder and is selected.
        \\
        \\Options:
        \\  -h, --help    Show this help message and exit
        \\  --open        Choose a file (JSON result on stdout)
        \\  --save        Choose a save destination
        \\  --folder      Choose a folder
        \\  --chooser-stdin  Read chooser options as JSON from stdin
        \\
        \\Keyboard shortcuts:
        \\  Alt+Left      Navigate Back
        \\  Alt+Right     Navigate Forward
        \\  Alt+Up        Navigate Up (Parent directory)
        \\  Ctrl+L        Focus location bar and clear search
        \\  Ctrl+F        Search filenames in this folder
        \\  Shift+F10     Open context menu
        \\  Ctrl+H        Toggle hidden files
        \\  F5            Refresh current directory
        \\  Ctrl+A        Select all files
        \\  Space         Browse archive or open selected image, PDF or text file
        \\  Enter         Open folder/archive or launch file with its application
        \\  Arrow keys    Navigate grid or list
        \\  PageUp/Down   Page up / down file list
        \\  Home / End    Jump to first / last item
        \\  Escape        Dismiss menu/search, cancel edit or clear selection
        \\
    ;
    std.debug.print("{s}", .{usage});
}

const Target = struct {
    path: []const u8,
    directory: []const u8,
    selected: ?[]const u8,
};

fn resolveTarget(allocator: std.mem.Allocator, environ: std.process.Environ, target: ?[]const u8, allow_file: bool) !Target {
    const home = environ.getPosix("HOME") orelse "/";

    if (allow_file and target != null and @import("files/recent.zig").isLocation(target.?)) {
        const path = try allocator.dupe(u8, target.?);
        return .{ .path = path, .directory = path, .selected = null };
    }

    var path_to_check: []const u8 = undefined;
    if (target) |t| {
        if (std.mem.startsWith(u8, t, "~")) {
            path_to_check = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, t[1..] });
        } else {
            path_to_check = try allocator.dupe(u8, t);
        }
    } else {
        path_to_check = try allocator.dupe(u8, home);
    }
    defer allocator.free(path_to_check);

    // Resolve relative path against cwd if necessary
    const resolved = try std.fs.path.resolve(allocator, &.{path_to_check});
    errdefer allocator.free(resolved);

    var zpath_buf: [4096]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&zpath_buf, "{s}", .{resolved}) catch return error.NameTooLong;

    var stat_buf: c.struct_stat = undefined;
    if (c.stat(zpath, &stat_buf) != 0) {
        return error.FileNotFound;
    }

    if ((stat_buf.st_mode & c.S_IFMT) == c.S_IFDIR) return .{ .path = resolved, .directory = resolved, .selected = null };
    if (!allow_file) return error.NotADirectory;
    return .{ .path = resolved, .directory = std.fs.path.dirname(resolved) orelse "/", .selected = resolved };
}

pub fn main(init: std.process.Init) void {
    const raw_args = init.minimal.args.vector;
    var target_arg: ?[]const u8 = null;
    var chooser: ?@import("files/chooser.zig").Options = null;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const arg = std.mem.span(raw_args[i]);
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--chooser-stdin")) {
            var bytes: std.ArrayList(u8) = .empty;
            while (true) {
                var buf: [4096]u8 = undefined;
                const n = c.read(0, &buf, buf.len);
                if (n == 0) break;
                if (n < 0 or bytes.items.len + @as(usize, @intCast(n)) > 1024 * 1024) std.process.exit(1);
                bytes.appendSlice(a, buf[0..@intCast(n)]) catch std.process.exit(1);
            }
            const parsed = std.json.parseFromSlice(@import("files/chooser.zig").Options, a, bytes.items, .{ .allocate = .alloc_always }) catch std.process.exit(1);
            chooser = parsed.value;
            if (chooser.?.choices.len > 8) std.process.exit(1);
            if (chooser.?.current_folder.len > 0) target_arg = chooser.?.current_folder;
        } else if (std.mem.eql(u8, arg, "--open") or std.mem.eql(u8, arg, "--save") or std.mem.eql(u8, arg, "--folder")) {
            chooser = .{ .mode = if (std.mem.eql(u8, arg, "--save")) .save else if (std.mem.eql(u8, arg, "--folder")) .folder else .open };
        } else if (target_arg == null and !std.mem.startsWith(u8, arg, "-")) {
            target_arg = arg;
        } else {
            std.debug.print("rediwm-files: unrecognized argument '{s}'\n\n", .{arg});
            printUsage();
            std.process.exit(1);
        }
    }

    const allocator = std.heap.c_allocator;
    const target = resolveTarget(allocator, init.minimal.environ, target_arg, chooser == null) catch |err| blk: {
        if (chooser != null) break :blk resolveTarget(allocator, init.minimal.environ, null, false) catch resolveTarget(allocator, init.minimal.environ, "/", false) catch std.process.exit(1);
        switch (err) {
            error.FileNotFound => {
                std.debug.print("rediwm-files: '{s}': No such file or directory\n", .{target_arg.?});
            },
            else => {
                std.debug.print("rediwm-files: cannot access '{s}': {}\n", .{ target_arg orelse "", err });
            },
        }
        std.process.exit(1);
    };
    defer allocator.free(target.path);

    main_mod.run(init, target.directory, if (chooser == null) target.selected else null, chooser) catch |err| {
        std.log.err("rediwm-files: {}", .{err});
        std.process.exit(1);
    };
}
