//! Taskbar tick: animation, capture indicator and live repaint scheduling.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const anim = @import("ui").anim;
const battery = @import("../taskbar/battery.zig");
const taskbar_items = @import("config").taskbar_items;
const start_button = @import("../taskbar/start_button.zig");
const protocol = @import("../ipc/protocol.zig");
const Anim = Taskbar.Anim;
const paint_start = Taskbar.paint_start;
const paint_chips = Taskbar.paint_chips;
const paint_tray = Taskbar.paint_tray;
const paint_hover = Taskbar.paint_hover;
const paint_press = Taskbar.paint_press;
const paint_audio = Taskbar.paint_audio;
const paint_capture = Taskbar.paint_capture;
const TrayKind = Taskbar.TrayKind;
const tray_count = Taskbar.tray_count;
const battery_width = Taskbar.battery_width;
const chipSize = Taskbar.chipSize;
const trayHit = Taskbar.trayHit;

// Runs once per output frame while anything is unsettled. Returns whether
// the caller should schedule another frame to keep the animation going.
pub fn tick(bar: *Taskbar, now_ms: i64) bool {
    var causes = bar.paint_causes;
    bar.paint_causes = 0;

    if (bar.server.audio) |mgr| {
        const gen = mgr.generation.load(.monotonic);
        if (gen != bar.audio_generation_seen) {
            bar.audio_generation_seen = gen;
            bar.audio_volume = mgr.getMasterVolume();
            bar.audio_muted = mgr.isMasterMuted();
            bar.tray_dirty[@intFromEnum(TrayKind.volume)] = true;
            causes |= paint_audio;
            bar.dirty = true;
        }
    }

    const sessions = if (bar.server.capture_mgr) |cm| cm.activeCount() else 0;
    if (sessions != bar.capture_sessions) {
        bar.capture_sessions = sessions;
        bar.capture_dirty = true;
        causes |= paint_capture | paint_chips;
        bar.dirty = true;
        _ = bar.reconcile(now_ms);
    }

    var animating = false;
    if (bar.battery_shimmer.sweep.sampleChanged(now_ms, anim.rasterPixelQuantum(bar.wlr_output.scale) / (battery_width + 46))) {
        if (bar.battery_state.percent != null) {
            bar.battery_dirty = true;
            causes |= paint_tray;
        }
    }
    if (!bar.battery_shimmer.sweep.settled(now_ms)) animating = true;
    // Press scales around the centre: convert the device-pixel step to the
    // amount that moves the outer edge by that distance.
    const press_quantum = 2 * anim.rasterPixelQuantum(bar.wlr_output.scale);
    const start_hover = bar.start.hover.sampleChanged(now_ms, anim.rasterAlphaQuantum());
    const start_open = bar.start.open_amt.sampleChanged(now_ms, anim.rasterAlphaQuantum());
    if (start_hover or start_open) {
        causes |= paint_start;
        if (start_hover) causes |= paint_hover;
        bar.start_dirty = true;
    }
    if (bar.start.animating(now_ms)) animating = true;

    for (bar.chips.items) |*chip| {
        const hover_moved = chip.hover.sampleChanged(now_ms, anim.rasterAlphaQuantum());
        const press_moved = chip.press.sampleChanged(now_ms, press_quantum / @max(chip.width, @as(f32, @floatFromInt(chipSize()))));
        if (hover_moved or press_moved) {
            causes |= paint_chips;
            if (hover_moved) causes |= paint_hover;
            if (press_moved) causes |= paint_press;
            chip.dirty = true;
        }
        // `flip` is the one chip curve with no `sampleChanged` above it (the
        // node position is applied straight from `renderX`), so it has to
        // record its own observation or it re-arms the output invisibly.
        const flip_live = anim.observeUnsettled(chip.flip, now_ms);
        if (flip_live or !chip.hover.settled(now_ms) or !chip.press.settled(now_ms)) {
            animating = true;
        }
        if (chip.buffer_node) |node| {
            node.node.setPosition(@as(i32, @intFromFloat(@round(chip.renderX(now_ms)))) - 2, 0);
        }
    }
    for (&bar.tray, 0..) |*t, i| {
        const hover_moved = t.hover.sampleChanged(now_ms, anim.rasterAlphaQuantum());
        const press_moved = t.press.sampleChanged(now_ms, press_quantum / @as(f32, @floatFromInt(trayHit())));
        if (hover_moved or press_moved) {
            causes |= paint_tray;
            if (hover_moved) causes |= paint_hover;
            if (press_moved) causes |= paint_press;
            bar.tray_dirty[i] = true;
        }
        if (!t.hover.settled(now_ms) or !t.press.settled(now_ms)) animating = true;
    }
    const cap_hover = bar.capture_hover.sampleChanged(now_ms, anim.rasterAlphaQuantum());
    const cap_press = bar.capture_press.sampleChanged(now_ms, press_quantum / @as(f32, @floatFromInt(@max(bar.captureWidth(), trayHit()))));
    if (cap_hover or cap_press) {
        causes |= paint_capture;
        if (cap_hover) causes |= paint_hover;
        if (cap_press) causes |= paint_press;
        bar.capture_dirty = true;
    }
    if (!bar.capture_hover.settled(now_ms) or !bar.capture_press.settled(now_ms)) animating = true;
    // A final changed sample still needs painting after the spring settles;
    // an unsettled sub-pixel tail alone does not need a raster pass.
    if (bar.dirty or causes != 0) {
        bar.render(now_ms, causes);
        bar.dirty = false;
        // An audio/capture event or `markDirty` repaints with no curve behind
        // it; say the picture moved or the frame reads as a wasted wakeup.
        anim.observeNoteChanged();
    }
    return animating;
}

pub fn captureAnimations(
    bar: *Taskbar,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(anim.LiveCapture),
    now_ms: i64,
) !void {
    try anim.captureIfLive(allocator, list, &bar.start.hover, .taskbar_hover, now_ms);
    try anim.captureIfLive(allocator, list, &bar.start.open_amt, .start_button, now_ms);
    try anim.captureIfLive(allocator, list, &bar.capture_hover, .taskbar_hover, now_ms);
    try anim.captureIfLive(allocator, list, &bar.capture_press, .taskbar_press, now_ms);
    for (bar.chips.items) |*chip| {
        try anim.captureIfLive(allocator, list, &chip.hover, .taskbar_hover, now_ms);
        try anim.captureIfLive(allocator, list, &chip.press, .taskbar_press, now_ms);
        try anim.captureIfLive(allocator, list, &chip.flip, .taskbar_flip, now_ms);
    }
    for (&bar.tray) |*t| {
        try anim.captureIfLive(allocator, list, &t.hover, .taskbar_hover, now_ms);
        try anim.captureIfLive(allocator, list, &t.press, .taskbar_press, now_ms);
    }
}

pub fn appendAnimations(
    bar: *const Taskbar,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(protocol.AnimationData),
    now_ms: i64,
) !void {
    try appendLive(allocator, list, "taskbar.battery.highlight", bar.battery_shimmer.sweep, now_ms);
    try appendLive(allocator, list, "taskbar.start.hover", bar.start.hover, now_ms);
    try appendLive(allocator, list, "taskbar.start.open", bar.start.open_amt, now_ms);
    try appendLive(allocator, list, "taskbar.capture.hover", bar.capture_hover, now_ms);
    try appendLive(allocator, list, "taskbar.capture.press", bar.capture_press, now_ms);
    for (bar.chips.items) |chip| {
        const id = chip.toplevel.id;
        const hover_site = try std.fmt.allocPrint(allocator, "taskbar.chip.{d}.hover", .{id});
        try appendLive(allocator, list, hover_site, chip.hover, now_ms);
        const press_site = try std.fmt.allocPrint(allocator, "taskbar.chip.{d}.press", .{id});
        try appendLive(allocator, list, press_site, chip.press, now_ms);
        const flip_site = try std.fmt.allocPrint(allocator, "taskbar.chip.{d}.flip", .{id});
        try appendLive(allocator, list, flip_site, chip.flip, now_ms);
    }
    for (&bar.tray) |t| {
        const hover_site = try std.fmt.allocPrint(allocator, "taskbar.tray.{s}.hover", .{@tagName(t.kind)});
        try appendLive(allocator, list, hover_site, t.hover, now_ms);
        const press_site = try std.fmt.allocPrint(allocator, "taskbar.tray.{s}.press", .{@tagName(t.kind)});
        try appendLive(allocator, list, press_site, t.press, now_ms);
    }
}

pub fn appendLive(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(protocol.AnimationData),
    site: []const u8,
    a: Anim,
    now_ms: i64,
) !void {
    if (!a.active()) return;
    try list.append(allocator, .{
        .site = site,
        .value = a.value(now_ms),
        .velocity = a.velocity(now_ms),
        .target = a.to,
        .settled = a.settled(now_ms),
        .curve = a.curveName(),
    });
}

pub fn trayPositions(bar: *Taskbar) [tray_count]f32 {
    const positions = bar.rightLayout().x;
    return .{ positions[@intFromEnum(taskbar_items.Item.volume)] orelse 0, positions[@intFromEnum(taskbar_items.Item.wifi)] orelse 0, positions[@intFromEnum(taskbar_items.Item.power)] orelse 0, positions[@intFromEnum(taskbar_items.Item.wired)] orelse 0, positions[@intFromEnum(taskbar_items.Item.input_source)] orelse 0 };
}
