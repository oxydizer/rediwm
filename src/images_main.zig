const std = @import("std");
const c = @import("files/c.zig").api;
const formats = @import("images/formats.zig");
const a = std.heap.c_allocator;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.log.err("rediwm-images: {}", .{err});
        std.process.exit(1);
    };
}
fn less(_: void, lhs: [:0]const u8, rhs: [:0]const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
fn run(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len < 2 or std.mem.eql(u8, std.mem.span(args[1]), "--help") or std.mem.eql(u8, std.mem.span(args[1]), "-h")) {
        std.debug.print("Usage: rediwm-images IMAGE [IMAGE ...]\n\nSpace/Esc: close   Left/Right: browse   R: rotate   C: crop\nEnter: apply crop   Ctrl+S: save PNG copy   Ctrl+Z: undo edits\nDelete: move to Trash   Mouse wheel over thumbnails: scroll\n+/-: zoom   F/0: fit   1: actual pixels   Drag: pan\n\nOne image opens with neighbouring images from its folder.\nGIF and other animated formats show a still frame.\n", .{});
        return;
    }
    var paths: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (paths.items) |p| a.free(p);
        paths.deinit(a);
    }
    var selected: usize = 0;
    if (std.mem.eql(u8, std.mem.span(args[1]), "--list-stdin")) {
        if (args.len != 3) return error.InvalidArguments;
        selected = try std.fmt.parseInt(usize, std.mem.span(args[2]), 10);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(a);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = c.read(0, &buf, buf.len);
            if (n == 0) break;
            if (n < 0) {
                if (std.posix.errno(n) == .INTR) continue;
                return error.ReadFailed;
            }
            if (bytes.items.len + @as(usize, @intCast(n)) > 16 * 1024 * 1024) return error.ListTooLarge;
            try bytes.appendSlice(a, buf[0..@intCast(n)]);
        }
        if (bytes.items.len == 0 or bytes.items[bytes.items.len - 1] != 0) return error.InvalidList;
        var it = std.mem.splitScalar(u8, bytes.items[0 .. bytes.items.len - 1], 0);
        while (it.next()) |p| {
            if (p.len == 0 or !std.fs.path.isAbsolute(p)) return error.InvalidList;
            try paths.append(a, try a.dupeZ(u8, p));
        }
    } else {
        var first: usize = 1;
        if (std.mem.eql(u8, std.mem.span(args[1]), "--")) first = 2;
        for (args[first..]) |arg| {
            const real = c.realpath(arg, null) orelse return error.FileNotFound;
            defer c.free(real);
            try paths.append(a, try a.dupeZ(u8, std.mem.span(real)));
        }
        if (paths.items.len == 1) {
            const target = try a.dupeZ(u8, paths.items[0]);
            defer a.free(target);
            const dir = try a.dupeZ(u8, std.fs.path.dirname(target).?);
            defer a.free(dir);
            if (c.opendir(dir)) |directory| {
                defer _ = c.closedir(directory);
                while (c.readdir(directory)) |entry| {
                    const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
                    if (name.len == 0 or name[0] == '.' or !formats.candidate(name)) continue;
                    const p = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
                    if (std.mem.eql(u8, p, target)) {
                        a.free(p);
                        continue;
                    }
                    if (entry.*.d_type != c.DT_REG) {
                        var st: c.struct_stat = undefined;
                        if (c.stat(p, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) {
                            a.free(p);
                            continue;
                        }
                    }
                    try paths.append(a, p);
                }
                std.mem.sort([:0]const u8, paths.items, {}, less);
                for (paths.items, 0..) |p, i| if (std.mem.eql(u8, p, target)) {
                    selected = i;
                    break;
                };
            }
        }
    }
    if (paths.items.len == 0 or selected >= paths.items.len) return error.InvalidSelection;
    try @import("images/main.zig").run(init, paths.items, selected, std.mem.eql(u8, std.mem.span(args[1]), "--list-stdin"));
}
