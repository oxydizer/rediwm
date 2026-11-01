const std = @import("std");
const theme_file = @import("theme_file.zig");
const theme = @import("theme.zig");
const Theme = theme.Theme;
const taskbarTokensEql = theme.taskbarTokensEql;
const applyTaskbarKey = theme.applyTaskbarKey;
const RadiusPreset = theme.RadiusPreset;
const applyRadiusPreset = theme.applyRadiusPreset;
const radiusPreset = theme.radiusPreset;
const chrome_base = theme.chrome_base;
const chromeDarkness = theme.chromeDarkness;
const withChromeDarkness = theme.withChromeDarkness;
const color_keys = theme.color_keys;
const number_keys = theme.number_keys;
const optional_color_keys = theme.optional_color_keys;
const parse = theme.parse;
const applyKey = theme.applyKey;
const writeInto = theme.writeInto;
const writeTaskbarInto = theme.writeTaskbarInto;
const parseColor = theme.parseColor;

test "parseColor hex with and without alpha" {
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 1 }, try parseColor("#ffffff"));
    const with_alpha = try parseColor("#ffffff80");
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), with_alpha[3], 1e-6);
}

test "parseColor rgba" {
    for ([_][]const u8{ "rgba(nan,0,0,1)", "rgba(0,0,0,inf)", "rgba(256,0,0,1)", "rgba(0,0,0,2)", "rgba(-1,0,0,1)" }) |bad| {
        try std.testing.expectError(error.InvalidColor, parseColor(bad));
    }
    const c = try parseColor("rgba(255,255,255,0.045)");
    try std.testing.expectEqual(@as(f32, 1), c[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.045), c[3], 1e-6);
}

test "parse reads the spec's example theme file" {
    const sample =
        \\[theme]
        \\font         = "Manrope"
        \\mono_font    = "JetBrains Mono"
        \\font_size    = 13.0
        \\radius       = 5.0
        \\bg           = "#090b18"
        \\accent       = "#5eead4"
        \\surface      = "rgba(255,255,255,0.045)"
        \\border_focus = "rgba(94,234,212,0.40)"
    ;
    const t = try parse(std.testing.allocator, sample);
    defer std.testing.allocator.free(t.font);
    defer std.testing.allocator.free(t.mono_font);

    try std.testing.expectEqualStrings("Manrope", t.font);
    try std.testing.expectEqualStrings("JetBrains Mono", t.mono_font);
    try std.testing.expectEqual(@as(f32, 13.0), t.font_size);
    try std.testing.expectEqual(@as(f32, 5.0), t.radius);
    try std.testing.expectApproxEqAbs(@as(f32, 0.045), t.surface[3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.40), t.border_focus[3], 1e-6);
}

test "writeInto then parse round-trips every field" {
    var t: Theme = .{};
    t.clock_bold = true;
    t.clock_italic = true;
    // Exercise every registered field with a non-default value, so omission
    // from either parser or serializer cannot pass as a default round-trip.
    // Keys defaulting to 0 (automatic sizes) would stay at the default under *= 0.9.
    inline for (number_keys) |name| @field(t, name) = if (@field(t, name) == 0) 500 else @field(t, name) * 0.9;
    inline for (color_keys) |name| @field(t, name) = .{ 16.0 / 255.0, 32.0 / 255.0, 48.0 / 255.0, 0.321 };
    inline for (optional_color_keys) |name| @field(t, name) = .{ 16.0 / 255.0, 32.0 / 255.0, 48.0 / 255.0, 0.321 };
    t.accent = .{ 167.0 / 255.0, 139.0 / 255.0, 250.0 / 255.0, 1 };
    t.radius = 8;
    t.font_size = 14;
    t.radius_md = 9;
    t.radius_lg = 12;
    t.glass = .{ 0.2, 0.4, 0.6, 0.56 };
    t.taskbar_bg = .{ 0.1, 0.2, 0.3, 0.62 };
    t.start_button_icon = "/tmp/custom logo.svg";
    t.shadow_size = 32;
    t.shadow = .{ 0, 0, 0, 0.45 };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeInto(std.testing.allocator, &buf, t);

    const parsed = try parse(std.testing.allocator, buf.items);
    // writeInto omits unchanged fonts; parse keeps their borrowed defaults.
    defer std.testing.allocator.free(parsed.start_button_icon);
    try std.testing.expectEqualStrings(t.start_button_icon, parsed.start_button_icon);
    try std.testing.expect(parsed.clock_bold and parsed.clock_italic);

    var taskbar_buf: std.ArrayList(u8) = .empty;
    defer taskbar_buf.deinit(std.testing.allocator);
    try writeTaskbarInto(std.testing.allocator, &taskbar_buf, t);
    var taskbar_theme: Theme = .{};
    var lines = std.mem.tokenizeScalar(u8, taskbar_buf.items, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        try std.testing.expect(try applyTaskbarKey(std.testing.allocator, &taskbar_theme, std.mem.trim(u8, line[0..eq], " "), std.mem.trim(u8, line[eq + 1 ..], " ")));
    }
    try std.testing.expect(taskbarTokensEql(t, taskbar_theme));

    inline for (number_keys) |name| try std.testing.expectEqual(@field(t, name), @field(parsed, name));
    inline for (color_keys) |name| {
        for (@field(t, name), @field(parsed, name)) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 1.0 / 255.0);
        }
    }
    inline for (optional_color_keys) |name| try std.testing.expectEqual(@field(t, name), @field(parsed, name));
    try std.testing.expectEqual(@as(f32, 8), parsed.radius);
    try std.testing.expectEqual(@as(f32, 14), parsed.font_size);
    try std.testing.expectApproxEqAbs(t.accent[0], parsed.accent[0], 1.0 / 255.0);
    try std.testing.expectApproxEqAbs(t.accent[1], parsed.accent[1], 1.0 / 255.0);
    try std.testing.expectApproxEqAbs(t.accent[2], parsed.accent[2], 1.0 / 255.0);
    try std.testing.expectApproxEqAbs(t.border_focus[3], parsed.border_focus[3], 1e-3);
}

test "writeInto omits defaults except the explicit frame radius" {
    var t: Theme = .{};
    t.radius = 9;
    t.window_bg[3] = 0.5;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeInto(std.testing.allocator, &buf, t);
    try std.testing.expectEqualStrings("[theme]\nradius = 9\nradius_lg = 10\nwindow_bg = \"rgba(8,9,11,0.500)\"\n", buf.items);
}

test "theme sizes reject non-finite and unsafe geometry" {
    for ([_][]const u8{ "nan", "inf", "-1", "1000000" }) |value| {
        var t: Theme = .{};
        try std.testing.expectError(error.InvalidSize, applyKey(std.testing.allocator, &t, "radius_lg", value));
    }
}

test "floating taskbar tokens check their ranges and sit outside the radius presets" {
    var t: Theme = .{};
    try applyKey(std.testing.allocator, &t, "taskbar_edge_gap", "12");
    try applyKey(std.testing.allocator, &t, "taskbar_length", "60");
    try applyKey(std.testing.allocator, &t, "taskbar_radius", "22");
    try applyKey(std.testing.allocator, &t, "taskbar_outline_width", "2");
    try applyKey(std.testing.allocator, &t, "taskbar_outline", "\"#ff0000\"");
    try std.testing.expectEqual(@as(f32, 60), t.taskbar_length);
    try std.testing.expectEqual(@as(f32, 2), t.taskbar_outline_width);
    try std.testing.expect(t.taskbar_outline != null);
    for ([_][2][]const u8{ .{ "taskbar_length", "19" }, .{ "taskbar_length", "101" }, .{ "taskbar_outline_width", "9" }, .{ "taskbar_edge_gap", "-1" } }) |bad| {
        try std.testing.expectError(error.InvalidSize, applyKey(std.testing.allocator, &t, bad[0], bad[1]));
    }
    // A preset rescales window radii; the taskbar's own corner is neither
    // reset by it nor stops the preset from being recognised.
    applyRadiusPreset(&t, .round);
    try std.testing.expectEqual(@as(f32, 22), t.taskbar_radius);
    try std.testing.expectEqual(RadiusPreset.round, radiusPreset(t).?);
    // The default look is the flush, full-width, square bar.
    const flush: Theme = .{};
    try std.testing.expectEqual(@as(f32, 0), flush.taskbar_edge_gap);
    try std.testing.expectEqual(@as(f32, 100), flush.taskbar_length);
    try std.testing.expectEqual(@as(f32, 0), flush.taskbar_radius);
}

test "caret colour follows the accent in effect until the file sets one" {
    var t: Theme = .{};
    // Panels remap `accent` for their own palette; an unset caret has to
    // follow that, which is what it did before the token existed.
    t.accent = .{ 1, 0, 0, 1 };
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, t.caretColor());

    try applyKey(std.testing.allocator, &t, "caret", "\"rgba(0,255,0,1)\"");
    try std.testing.expectEqual([4]f32{ 0, 1, 0, 1 }, t.caretColor());

    // Round-trips only once set, so saving a theme cannot freeze "follow the
    // accent" into a literal colour.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeInto(std.testing.allocator, &buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\ncaret = ") == null);

    buf.clearRetainingCapacity();
    try writeInto(std.testing.allocator, &buf, t);
    const parsed = try parse(std.testing.allocator, buf.items);
    // writeInto omits unchanged fonts; parse keeps their borrowed defaults.
    try std.testing.expectEqual([4]f32{ 0, 1, 0, 1 }, parsed.caret.?);
}

test "bundled RediWM Dark preset round-trips to Theme{}'s defaults field-for-field" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.80), (Theme{}).window_bg[3], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.80), chromeDarkness((Theme{}).window_bg), 1e-5);
    const bytes = @embedFile("theme-rediwm-dark");
    const t = try parse(std.testing.allocator, bytes);
    defer std.testing.allocator.free(t.font);
    defer std.testing.allocator.free(t.mono_font);

    const defaults: Theme = .{};
    try std.testing.expectEqualStrings(defaults.font, t.font);
    try std.testing.expectEqualStrings(defaults.mono_font, t.mono_font);
    inline for (number_keys) |name| try std.testing.expectEqual(@field(defaults, name), @field(t, name));
    inline for (color_keys) |name| {
        for (@field(defaults, name), @field(t, name)) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 1.0 / 255.0);
        }
    }
}

test "scrollbar width validates and survives theme serialization" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "0", "3", "25", "nan", "inf" }) |value| {
        var t: Theme = .{};
        try std.testing.expectError(error.InvalidSize, applyKey(a, &t, "scrollbar_width", value));
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[theme]\nscrollbar_width = 19\n");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try writeInto(a, &buf, t);
    const restored = try parse(arena.allocator(), buf.items);
    try std.testing.expectEqual(@as(f32, 19), restored.scrollbar_width);
}

test "chrome darkness scales the tint's brightness and keeps its hue and alpha" {
    const stock = chrome_base;
    try std.testing.expectEqual(@as(f32, 0), chromeDarkness(stock));
    // Zero darkness is the stock colour exactly, at whatever opacity it had.
    const untouched = withChromeDarkness(.{ stock[0], stock[1], stock[2], 0.37 }, 0);
    try std.testing.expectEqual(stock[0], untouched[0]);
    try std.testing.expectEqual(stock[1], untouched[1]);
    try std.testing.expectEqual(stock[2], untouched[2]);
    try std.testing.expectEqual(@as(f32, 0.37), untouched[3]);

    // Half darkness reads back as half, with the stock hue.
    const half = withChromeDarkness(stock, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), chromeDarkness(half), 1e-5);
    try std.testing.expectApproxEqAbs(stock[0] / stock[2], half[0] / half[2], 1e-5);
    try std.testing.expectApproxEqAbs(stock[1] / stock[2], half[1] / half[2], 1e-5);
    try std.testing.expect(half[0] < stock[0] and half[1] < stock[1] and half[2] < stock[2]);

    // Full darkness is black; going back up recovers the stock hue.
    const black = withChromeDarkness(stock, 1);
    try std.testing.expectEqual(@as(f32, 0), black[0] + black[1] + black[2]);
    const back = withChromeDarkness(black, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), chromeDarkness(back), 1e-5);
    try std.testing.expectApproxEqAbs(stock[0] / stock[2], back[0] / back[2], 1e-5);
}

test "chrome darkness follows a custom tint and survives 8-bit storage" {
    // A user's own darker charcoal reads as darkened, not as 0.
    const custom: [4]f32 = .{ 16.0 / 255.0, 18.0 / 255.0, 21.0 / 255.0, 0.98 };
    const d = chromeDarkness(custom);
    try std.testing.expect(d > 0.5 and d < 0.7);
    // Moving the slider keeps the tint's hue rather than resetting to stock.
    const moved = withChromeDarkness(custom, 0.5);
    try std.testing.expectApproxEqAbs(custom[0] / custom[2], moved[0] / moved[2], 1e-5);
    try std.testing.expectEqual(@as(f32, 0.98), moved[3]);
    // A lighter-than-stock colour reads 0 and is never pushed past white.
    try std.testing.expectEqual(@as(f32, 0), chromeDarkness(.{ 1, 1, 1, 1 }));
    const white = withChromeDarkness(.{ 1, 1, 1, 1 }, 0);
    try std.testing.expect(white[0] <= 1 and white[1] <= 1 and white[2] <= 1);
    // Reloading from the theme file quantises to 8 bits; the readout stays put.
    const stored: [4]f32 = .{ @round(moved[0] * 255) / 255.0, @round(moved[1] * 255) / 255.0, @round(moved[2] * 255) / 255.0, moved[3] };
    try std.testing.expectApproxEqAbs(chromeDarkness(moved), chromeDarkness(stored), 0.01);
}

test "chrome geometry validates and survives theme serialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "0", "27", "85", "nan", "inf" }) |value| {
        var t: Theme = .{};
        try std.testing.expectError(error.InvalidSize, applyKey(a, &t, "chrome_height", value));
    }
    for ([_][]const u8{ "-1", "25", "nan", "inf" }) |value| {
        var t: Theme = .{};
        try std.testing.expectError(error.InvalidSize, applyKey(a, &t, "chrome_control_gap", value));
    }
    for ([_][]const u8{ "1", "\"true\"", "True" }) |value| {
        var t: Theme = .{};
        try std.testing.expectError(error.InvalidBoolean, applyKey(a, &t, "chrome_round_buttons", value));
    }
    try std.testing.expect(!(try parse(a, "[theme]\nchrome_round_buttons = false\n")).chrome_round_buttons);
    const t = try parse(a, "[theme]\nchrome_height = 28\nchrome_control_gap = 0\nchrome_round_buttons = true\n");
    var buf: std.ArrayList(u8) = .empty;
    try writeInto(a, &buf, t);
    const restored = try parse(a, buf.items);
    try std.testing.expectEqual(@as(f32, 28), restored.chrome_height);
    try std.testing.expectEqual(@as(f32, 0), restored.chrome_control_gap);
    try std.testing.expect(restored.chrome_round_buttons);
}


test "component relief theme keys parse, inherit, and reject invalid values" {
    const Relief = theme.Relief;
    try std.testing.expect(theme_file.knownKey("button_relief"));
    try std.testing.expect(theme_file.knownKey("button_pressed_relief"));
    try std.testing.expect(theme_file.knownKey("field_relief"));
    try std.testing.expect(theme_file.knownKey("dialog_inset_relief"));
    try std.testing.expect(theme_file.knownKey("select_relief"));
    try std.testing.expect(theme_file.knownKey("select_popup_relief"));
    try std.testing.expect(theme_file.knownKey("checkbox_relief"));
    try std.testing.expect(theme_file.knownKey("toggle_track_relief"));
    try std.testing.expect(theme_file.knownKey("toggle_thumb_relief"));
    try std.testing.expect(theme_file.knownKey("slider_track_relief"));
    try std.testing.expect(theme_file.knownKey("slider_thumb_relief"));
    try std.testing.expect(!theme_file.knownKey("fake_relief_key"));

    const toml =
        \\[theme]
        \\button_relief = "flat"
        \\button_pressed_relief = "raised"
        \\checkbox_relief = "inset"
    ;
    var t: Theme = .{};
    try theme_file.overlay(std.testing.allocator, &t, toml);
    try std.testing.expectEqual(Relief.flat, t.button_relief);
    try std.testing.expectEqual(Relief.raised, t.button_pressed_relief);
    try std.testing.expectEqual(Relief.inset, t.checkbox_relief);
    try std.testing.expectEqual(Relief.flat, t.field_relief);
    try std.testing.expectEqual(Relief.flat, t.toggle_track_relief);

    var bad_t: Theme = .{};
    const invalid_relief =
        \\[theme]
        \\button_relief = "concave"
    ;
    try std.testing.expectError(error.InvalidRelief, theme_file.overlay(std.testing.allocator, &bad_t, invalid_relief));
    const unquoted_relief =
        \\[theme]
        \\button_relief = flat
    ;
    try std.testing.expectError(error.ExpectedQuotedString, theme_file.overlay(std.testing.allocator, &bad_t, unquoted_relief));
}

test "component relief theme serialization round-trips and omits defaults" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    var original: Theme = .{};
    const defaults: Theme = .{};
    original.button_relief = .raised;
    original.toggle_track_relief = .inset;
    original.field_relief = .inset;

    try theme_file.writeDiff(std.testing.allocator, &buf, original, defaults, "", false);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "button_relief = \"raised\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "toggle_track_relief = \"inset\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "field_relief = \"inset\"") != null);

    var reloaded: Theme = .{};
    try theme_file.overlay(std.testing.allocator, &reloaded, buf.items);
    try std.testing.expectEqual(original.button_relief, reloaded.button_relief);
    try std.testing.expectEqual(original.toggle_track_relief, reloaded.toggle_track_relief);
    try std.testing.expectEqual(original.field_relief, reloaded.field_relief);
}

test "window edge and button hover glow toggles serialize independently and reload" {
    const cases = [_]struct { edge: bool, button: bool }{
        .{ .edge = false, .button = true },
        .{ .edge = true, .button = false },
        .{ .edge = false, .button = false },
        .{ .edge = true, .button = true },
    };

    for (cases) |case| {
        var original: Theme = .{};
        original.border_glow_enabled = case.edge;
        original.button_hover_glow_enabled = case.button;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(std.testing.allocator);
        try theme_file.writeDiff(std.testing.allocator, &buf, original, .{}, "", false);

        var restored: Theme = .{};
        try theme_file.overlay(std.testing.allocator, &restored, buf.items);
        try std.testing.expectEqual(case.edge, restored.border_glow_enabled);
        try std.testing.expectEqual(case.button, restored.button_hover_glow_enabled);
    }
}

test "relief keys of the remaining widgets parse, default to flat and round-trip" {
    const Relief = theme.Relief;
    const keys = [_][]const u8{ "segmented_relief", "segmented_selected_relief", "stepper_relief", "swatch_relief", "pill_relief", "row_hover_relief", "row_selected_relief", "settings_card_relief", "dialog_frame_relief", "taskbar_chip_relief", "taskbar_chip_active_relief" };
    for (keys) |key| try std.testing.expect(theme_file.knownKey(key));

    const defaults: Theme = .{};
    try std.testing.expectEqual(Relief.flat, defaults.segmented_relief);
    try std.testing.expectEqual(Relief.flat, defaults.segmented_selected_relief);
    try std.testing.expectEqual(Relief.flat, defaults.stepper_relief);
    try std.testing.expectEqual(Relief.flat, defaults.swatch_relief);
    try std.testing.expectEqual(Relief.flat, defaults.pill_relief);
    try std.testing.expectEqual(Relief.flat, defaults.row_hover_relief);
    try std.testing.expectEqual(Relief.flat, defaults.row_selected_relief);

    const toml =
        \\[theme]
        \\segmented_relief = "inset"
        \\segmented_selected_relief = "raised"
        \\row_selected_relief = "inset"
    ;
    var t: Theme = .{};
    try theme_file.overlay(std.testing.allocator, &t, toml);
    try std.testing.expectEqual(Relief.inset, t.segmented_relief);
    try std.testing.expectEqual(Relief.raised, t.segmented_selected_relief);
    try std.testing.expectEqual(Relief.inset, t.row_selected_relief);
    try std.testing.expectEqual(Relief.flat, t.stepper_relief);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try theme_file.writeDiff(std.testing.allocator, &buf, t, defaults, "", false);
    var reloaded: Theme = .{};
    try theme_file.overlay(std.testing.allocator, &reloaded, buf.items);
    try std.testing.expectEqual(t.segmented_relief, reloaded.segmented_relief);
    try std.testing.expectEqual(t.segmented_selected_relief, reloaded.segmented_selected_relief);
    try std.testing.expectEqual(t.row_selected_relief, reloaded.row_selected_relief);
    try std.testing.expectEqual(t.stepper_relief, reloaded.stepper_relief);
    try std.testing.expectEqual(Relief.flat, defaults.settings_card_relief);
    try std.testing.expectEqual(Relief.flat, defaults.taskbar_chip_active_relief);
}
