//! Output wallpaper.

const std = @import("std");
const Output = @import("../Output.zig");
const wlr = @import("wlroots");
const Wallpaper = @import("../server/wallpaper.zig").Wallpaper;
const log = std.log.scoped(.output);

// Scales the wallpaper to cover the output, cropping the overhanging axis
// so the image keeps its aspect ratio on any screen shape.
pub fn replaceWallpaper(output: *Output, image: Wallpaper) void {
    if (output.wallpaper) |node| node.node.destroy();
    output.wallpaper = output.server.background_tree.createSceneBuffer(null) catch |err| blk: {
        log.err("replaceWallpaper: could not create wallpaper node: {}", .{err});
        break :blk null;
    };
    if (output.wallpaper) |node| {
        node.setBuffer(image.buffer);
        node.setFilterMode(.bilinear);
    }
    output.syncWallpaper();
    output.wlr_output.scheduleFrame();
}

pub fn syncWallpaper(output: *Output) void {
    const node = output.wallpaper orelse return;
    const image = output.server.wallpaper orelse return;

    var box: wlr.Box = undefined;
    output.server.output_layout.getBox(output.wlr_output, &box);
    if (box.width <= 0 or box.height <= 0) return;

    node.node.setPosition(box.x, box.y);
    image.attach(node, box.width, box.height);

    const image_width: f64 = @floatFromInt(image.width());
    const image_height: f64 = @floatFromInt(image.height());
    const dest_width: f64 = @floatFromInt(box.width);
    const dest_height: f64 = @floatFromInt(box.height);
    const scale = @max(dest_width / image_width, dest_height / image_height);
    const source_width = @min(dest_width / scale, image_width);
    const source_height = @min(dest_height / scale, image_height);
    node.setSourceBox(&.{
        .x = (image_width - source_width) / 2,
        .y = (image_height - source_height) / 2,
        .width = source_width,
        .height = source_height,
    });
}
