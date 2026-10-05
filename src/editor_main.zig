const std = @import("std");
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.log.err("rediwm-editor: {}", .{err});
        std.process.exit(1);
    };
}
fn run(init: std.process.Init) !void {
    var paths: std.ArrayList([:0]const u8) = .empty;
    defer paths.deinit(init.gpa);
    var activation: []const u8 = init.minimal.environ.getPosix("XDG_ACTIVATION_TOKEN") orelse "";
    var args = init.minimal.args.vector[1..];
    if (args.len >= 2 and std.mem.eql(u8, std.mem.span(args[0]), "--activation-token")) {
        activation = std.mem.span(args[1]);
        args = args[2..];
    }
    var literal = false;
    for (args) |arg| {
        const value = std.mem.span(arg);
        if (!literal and std.mem.eql(u8, value, "--help")) {
            std.debug.print("Usage: rediwm-editor [FILE ...]\nCtrl+N: new tab  Ctrl+O: open  Ctrl+S: save  Ctrl+Shift+S: Save As\nCtrl+W: close tab  Ctrl+Page Up/Down: switch tabs  Ctrl+F: find\n", .{});
            return;
        }
        if (!literal and std.mem.eql(u8, value, "--")) {
            literal = true;
            continue;
        }
        try paths.append(init.gpa, value);
    }
    var instance = try @import("editor/instance.zig").Instance.init(init.minimal.environ);
    defer instance.deinit();
    if (!instance.primary) {
        if (paths.items.len == 0) try instance.send(.{ .token = activation });
        for (paths.items) |path| {
            const absolute = try std.Io.Dir.cwd().realPathFileAlloc(init.io, path, init.gpa);
            defer init.gpa.free(absolute);
            try instance.send(.{ .path = absolute, .token = activation });
            activation = "";
        }
        return;
    }
    try @import("editor/main.zig").run(init, paths.items, &instance, activation);
}
