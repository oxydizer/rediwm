const std = @import("std");
const copy_bench = @import("copy_bench");

pub fn main() !void {
    try copy_bench.run(std.heap.page_allocator);
}
