const std = @import("std");
const pdf_main = @import("pdf/main.zig");

// Minimal startup avoids copying environment secrets into an extra heap map.
pub fn main(init: std.process.Init.Minimal) void {
    pdf_main.run(init) catch |err| {
        std.log.err("rediwm-pdf: {}", .{err});
        std.process.exit(1);
    };
}
