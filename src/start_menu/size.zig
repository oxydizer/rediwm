//! The start menu's size. A theme that leaves `start_menu_width` and
//! `start_menu_max_height` at 0 (their default) gets a menu sized to the
//! output; a nonzero value is the user's own and is used as written.
//!
//! The design size is what the menu looks right at on a 2560x1600 panel at
//! scale 1.5. Outputs at least that large (in logical pixels) get exactly that:
//! its rows and text do not grow with the screen, so a bigger menu would only
//! add empty space. Smaller outputs get the same proportion of their screen,
//! down to a floor that still fits the search box, a few rows and the footer.
const std = @import("std");
const Theme = @import("ui").theme.Theme;

pub const design_width: f32 = 560;
pub const design_height: f32 = 600;
/// Logical size of the output the design was judged on (2560x1600 / 1.5).
const design_screen_width: f32 = 1706;
const design_screen_height: f32 = 1066;

/// Smallest size the automatic sizing, and Settings' sliders, will pick.
/// `StartMenu.relayout` keeps its own lower floor (320x240) for sizes a
/// hand-edited theme sets.
pub const min_width: f32 = 400;
pub const min_height: f32 = 360;

pub const Size = struct { width: f32, height: f32 };

/// The automatic size for an output of `output_w` x `output_h` logical pixels.
pub fn automatic(output_w: f32, output_h: f32) Size {
    return .{
        .width = axis(design_width, output_w, design_screen_width, min_width),
        .height = axis(design_height, output_h, design_screen_height, min_height),
    };
}

fn axis(design: f32, output: f32, design_output: f32, floor: f32) f32 {
    if (output <= 0) return design;
    return @round(std.math.clamp(design * output / design_output, floor, design));
}

/// Width and height the theme asks for on this output, before the caps that
/// keep the menu on screen: its own values, else the automatic ones.
pub fn wanted(t: Theme, output_w: f32, output_h: f32) Size {
    const auto = automatic(output_w, output_h);
    return .{
        .width = if (t.start_menu_width > 0) t.start_menu_width else auto.width,
        .height = if (t.start_menu_max_height > 0) t.start_menu_max_height else auto.height,
    };
}

test "the design output gets the design size and larger ones do not grow it" {
    const at_design = automatic(2560.0 / 1.5, 1600.0 / 1.5);
    try std.testing.expectEqual(design_width, at_design.width);
    try std.testing.expectEqual(design_height, at_design.height);
    const uhd = automatic(3840, 2160);
    try std.testing.expectEqual(design_width, uhd.width);
    try std.testing.expectEqual(design_height, uhd.height);
}

test "smaller outputs get the same proportion, down to the floor" {
    // 1366x768 at scale 1: the proportions of the design (33% x 56%).
    const laptop = automatic(1366, 768);
    try std.testing.expectEqual(@as(f32, 448), laptop.width);
    try std.testing.expectEqual(@as(f32, 432), laptop.height);
    const tiny = automatic(800, 600);
    try std.testing.expectEqual(min_width, tiny.width);
    try std.testing.expectEqual(min_height, tiny.height);
    // No output yet: the design size rather than the floor.
    try std.testing.expectEqual(design_width, automatic(0, 0).width);
}

test "a theme's own nonzero values win, per axis" {
    var t: Theme = .{};
    const auto = wanted(t, 1366, 768);
    try std.testing.expectEqual(@as(f32, 448), auto.width);
    t.start_menu_width = 700;
    const mixed = wanted(t, 1366, 768);
    try std.testing.expectEqual(@as(f32, 700), mixed.width);
    try std.testing.expectEqual(@as(f32, 432), mixed.height);
}
