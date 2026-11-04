//! UI input tests: hit testing, click cycles, scrolling, caret motion and selection.

const std = @import("std");
const anim = @import("anim.zig");
const layout = @import("layout.zig");
const theme = @import("theme.zig");
const Widget = layout.Widget;
const scroll_widget = @import("widgets/scroll_container.zig");
const hitTest = @import("input.zig").hitTest;
const CaretConfig = @import("input.zig").CaretConfig;
const multi_click_ms = @import("input.zig").multi_click_ms;
const multi_click_slop = @import("input.zig").multi_click_slop;
const caret_snap_distance = @import("input.zig").caret_snap_distance;
const Caret = @import("input.zig").Caret;
const Dispatcher = @import("input.zig").Dispatcher;
const reset = @import("input.zig").reset;
const pointerMotion = @import("input.zig").pointerMotion;
const pointerLeave = @import("input.zig").pointerLeave;
const scrollWheel = @import("input.zig").scrollWheel;
const keyEvent = @import("input.zig").keyEvent;
const input_src = @import("input.zig");

test "button proximity samples visible nested-scroll rectangles and skips unchanged values" {
    var button = Widget{
        .kind = .{ .button = .{ .label = "Visible" } },
    };
    button.computed_x = 25;
    button.computed_y = 0;
    button.computed_width = 20;
    button.computed_height = 20;

    var clipped_button = Widget{
        .kind = .{ .button = .{ .label = "Clipped" } },
    };
    clipped_button.computed_x = 75;
    clipped_button.computed_y = 10;
    clipped_button.computed_width = 10;
    clipped_button.computed_height = 10;

    var inner_children = [_]Widget{button};
    var inner = Widget{
        .kind = .{ .scroll_container = .{} },
        .children = &inner_children,
    };
    inner.computed_x = 20;
    inner.computed_y = 5;
    inner.computed_width = 40;
    inner.computed_height = 30;

    var outer_children = [_]Widget{ inner, clipped_button };
    var outer = Widget{
        .kind = .{ .scroll_container = .{} },
        .children = &outer_children,
    };
    outer.computed_x = 10;
    outer.computed_y = 10;
    outer.computed_width = 60;
    outer.computed_height = 40;

    var root_children = [_]Widget{outer};
    var root = Widget{
        .kind = .container,
        .children = &root_children,
    };
    root.computed_x = 0;
    root.computed_y = 0;
    root.computed_width = 100;
    root.computed_height = 100;
    root.linkParents();

    const viewport: input_src.ProximityRect = .{
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 100,
    };

    // The visible button is clipped by both scroll ancestors:
    // its visible rectangle begins at y=10, five pixels below the cursor.
    try std.testing.expect(input_src.updateButtonProximity(&root, 30, 5, viewport));
    try std.testing.expectEqual(
        @as(f32, 5),
        root.children[0].children[0].children[0].kind.button.proximity_distance,
    );

    // The sibling lies entirely outside the outer scroll viewport.
    try std.testing.expect(std.math.isInf(
        root.children[0].children[1].kind.button.proximity_distance,
    ));

    // Repeating the same sample must not dirty widgets or advance the revision.
    const revision = layout.paint_revision;
    try std.testing.expect(!input_src.updateButtonProximity(&root, 30, 5, viewport));
    try std.testing.expectEqual(revision, layout.paint_revision);

    // Moving inside the visible portion changes the sample to zero.
    try std.testing.expect(input_src.updateButtonProximity(&root, 30, 15, viewport));
    try std.testing.expectEqual(
        @as(f32, 0),
        root.children[0].children[0].children[0].kind.button.proximity_distance,
    );

    // Moving away from the button updates its distance and local sample.
    try std.testing.expect(input_src.updateButtonProximity(&root, 50, 15, viewport));
    const visible_button = &root.children[0].children[0].children[0].kind.button;
    try std.testing.expectEqual(@as(f32, 5), visible_button.proximity_distance);
    try std.testing.expectEqual(@as(f32, 25), visible_button.proximity_x);
    try std.testing.expectEqual(@as(f32, 15), visible_button.proximity_y);

    // A distant pointer position is retained without repeatedly dirtying paint.
    try std.testing.expect(input_src.updateButtonProximity(&root, 120, 15, viewport));
    try std.testing.expect(std.math.isInf(visible_button.proximity_distance));
    try std.testing.expectEqual(@as(f32, 0), visible_button.proximity_x);
    try std.testing.expectEqual(@as(f32, 0), visible_button.proximity_y);
    const distant_revision = layout.paint_revision;
    try std.testing.expect(!input_src.updateButtonProximity(&root, 120, 15, viewport));
    try std.testing.expectEqual(distant_revision, layout.paint_revision);
}

test "dispatcher pointer motion updates button proximity samples" {
    var children = [_]Widget{.{
        .kind = .{ .button = .{ .label = "Button" } },
        .computed_width = 40,
        .computed_height = 20,
    }};
    var root: Widget = .{
        .kind = .container,
        .computed_width = 100,
        .computed_height = 80,
        .children = &children,
    };
    root.linkParents();

    var dispatcher: Dispatcher = .{};
    dispatcher.pointerMotion(&root, 45, 10);

    const button = &root.children[0].kind.button;
    try std.testing.expectEqual(@as(f32, 5), button.proximity_distance);
    try std.testing.expectEqual(@as(f32, 45), button.proximity_x);
    try std.testing.expectEqual(@as(f32, 10), button.proximity_y);

    const revision = layout.paint_revision;
    dispatcher.pointerMotion(&root, 45, 10);
    try std.testing.expectEqual(revision, layout.paint_revision);

    dispatcher.pointerMotion(&root, 10, 10);
    try std.testing.expectEqual(@as(f32, 0), button.proximity_distance);
}

test "dispatcher forwards retained-tree hits to the interaction surface" {
    const text = Widget{
        .kind = .{ .text = .{
            .content = "Child",
            .font_size = 12,
            .color = .{ 1, 1, 1, 1 },
        } },
        .computed_x = 15,
        .computed_y = 15,
        .computed_width = 30,
        .computed_height = 10,
    };
    var row_children = [_]Widget{text};
    const row = Widget{
        .kind = .{ .row = .{} },
        .computed_x = 10,
        .computed_y = 10,
        .computed_width = 60,
        .computed_height = 30,
        .children = &row_children,
    };
    var root_children = [_]Widget{row};
    var root = Widget{
        .kind = .container,
        .computed_width = 100,
        .computed_height = 80,
        .children = &root_children,
    };
    root.linkParents();

    var dispatcher = Dispatcher{};
    dispatcher.pointerMotion(&root, 20, 20);

    try std.testing.expectEqual(@as(?*Widget, &root.children[0]), dispatcher.hovered);
    try std.testing.expect(dispatcher.surface.hovered != null);

    const target = dispatcher.surface.hovered.?;
    try std.testing.expectEqual(
        @as(u64, @intCast(@intFromPtr(&root.children[0]))),
        target.id,
    );
    try std.testing.expectEqual(@as(f32, 10), target.rect.x);
    try std.testing.expectEqual(@as(f32, 10), target.rect.y);
    try std.testing.expectEqual(@as(f32, 60), target.rect.w);
    try std.testing.expectEqual(@as(f32, 30), target.rect.h);

    // A passive hit clears the shared target and the old widget hover.
    dispatcher.pointerMotion(&root, 90, 70);
    try std.testing.expect(dispatcher.surface.hovered == null);
    try std.testing.expect(root.children[0].kind.row.state != .hover);

    // Returning to the row restores the target; leaving clears its snapshot.
    dispatcher.pointerMotion(&root, 20, 20);
    try std.testing.expect(dispatcher.surface.hovered != null);
    dispatcher.pointerLeave(&root);
    try std.testing.expect(dispatcher.surface.hovered == null);
}

test "proximity samples shared widget surfaces and clears on pointer leave" {
    const TextSink = struct {
        fn call(_: ?*anyopaque, _: usize, _: []const u8) void {}
    };
    const CheckSink = struct {
        fn call(_: ?*anyopaque, _: usize, _: bool) void {}
    };

    var children = [_]Widget{
        .{
            .kind = .{ .text_input = .{
                .placeholder = "",
                .value = &.{},
                .on_change = TextSink.call,
            } },
            .computed_x = 10,
            .computed_y = 10,
            .computed_width = 60,
            .computed_height = 30,
        },
        .{
            .kind = .{ .checkbox = .{
                .label = "Enabled",
                .checked = false,
                .on_change = CheckSink.call,
            } },
            .computed_x = 100,
            .computed_y = 10,
            .computed_width = 80,
            .computed_height = 30,
        },
        .{
            .kind = .{ .checkbox = .{
                .label = "Disabled",
                .checked = false,
                .disabled = true,
                .on_change = CheckSink.call,
            } },
            .computed_x = 200,
            .computed_y = 10,
            .computed_width = 80,
            .computed_height = 30,
        },
    };
    var root: Widget = .{
        .kind = .container,
        .computed_width = 300,
        .computed_height = 60,
        .children = &children,
    };
    root.linkParents();

    var dispatcher = Dispatcher{};
    dispatcher.pointerMotion(&root, 20, 20);

    const field = &root.children[0];
    try std.testing.expectEqual(@as(f32, 0), field.proximity.distance);
    try std.testing.expectEqual(@as(f32, 10), field.proximity.x);
    try std.testing.expectEqual(@as(f32, 10), field.proximity.y);

    // The checkbox illuminates its square, not the label's whole row.
    const checkbox = &root.children[1];
    try std.testing.expect(std.math.isInf(checkbox.proximity.distance));
    dispatcher.pointerMotion(&root, 105, 20);
    try std.testing.expectEqual(@as(f32, 0), checkbox.proximity.distance);
    try std.testing.expectEqual(@as(f32, 100), checkbox.proximity.rect.x);
    try std.testing.expectEqual(@as(f32, 16), checkbox.proximity.rect.y);
    try std.testing.expectEqual(@as(f32, 18), checkbox.proximity.rect.w);
    try std.testing.expectEqual(@as(f32, 18), checkbox.proximity.rect.h);
    try std.testing.expectEqual(@as(f32, 5), checkbox.proximity.x);
    try std.testing.expectEqual(@as(f32, 4), checkbox.proximity.y);

    // Disabled controls never acquire a proximity sample.
    try std.testing.expect(std.math.isInf(root.children[2].proximity.distance));

    dispatcher.pointerLeave(&root);
    try std.testing.expect(std.math.isInf(field.proximity.distance));
    try std.testing.expect(std.math.isInf(checkbox.proximity.distance));
}

test "scrollbar groove proximity follows the visible inset groove" {
    const saved_theme = theme.global;
    defer theme.global = saved_theme;
    theme.global.scrollbar_width = 8;
    theme.global.scrollbar_track_relief = .inset;

    var root: Widget = .{
        .kind = .{ .scroll_container = .{ .content_size = 200 } },
        .direction = .column,
        .computed_x = 20,
        .computed_y = 20,
        .computed_width = 100,
        .computed_height = 100,
    };

    var dispatcher = Dispatcher{};
    dispatcher.pointerMotion(&root, 110, 90);

    // The 14 px gutter produces a 12 px inset groove at x=107.
    try std.testing.expectEqual(@as(f32, 0), root.proximity.distance);
    try std.testing.expectEqual(@as(f32, 107), root.proximity.rect.x);
    try std.testing.expectEqual(@as(f32, 20), root.proximity.rect.y);
    try std.testing.expectEqual(@as(f32, 12), root.proximity.rect.w);
    try std.testing.expectEqual(@as(f32, 100), root.proximity.rect.h);
    try std.testing.expectEqual(@as(f32, 3), root.proximity.x);
    try std.testing.expectEqual(@as(f32, 70), root.proximity.y);

    // Sampling is independent of relief so making the groove visible again
    // does not require another pointer movement. The painter gates flat tracks.
    theme.global.scrollbar_track_relief = .flat;
    dispatcher.pointerMotion(&root, 110, 90);
    try std.testing.expectEqual(@as(f32, 0), root.proximity.distance);
}

test "hitTest returns the topmost overlapping widget" {
    var kids = [_]Widget{
        .{ .kind = .container },
        .{ .kind = .container },
    };
    kids[0].computed_x = 0;
    kids[0].computed_y = 0;
    kids[0].computed_width = 100;
    kids[0].computed_height = 100;
    kids[1].computed_x = 20;
    kids[1].computed_y = 20;
    kids[1].computed_width = 30;
    kids[1].computed_height = 30;

    var root = Widget{ .kind = .container, .children = &kids };
    root.computed_width = 100;
    root.computed_height = 100;
    root.linkParents();

    // Compare optionals directly: `.?` would panic the test harness on a miss
    // instead of reporting an assertion failure.
    try std.testing.expectEqual(@as(?*Widget, &root.children[1]), hitTest(&root, 25, 25));
    try std.testing.expectEqual(@as(?*Widget, &root.children[0]), hitTest(&root, 60, 60));
    try std.testing.expect(hitTest(&root, 200, 200) == null);
}

test "full click cycle fires on_click only when released over the button" {
    const Counter = struct {
        var count: u32 = 0;
        fn call(_: ?*anyopaque, _: usize) void {
            count += 1;
        }
    };
    Counter.count = 0;

    var kids = [_]Widget{.{ .kind = .{ .button = .{ .label = "Go", .on_click = &Counter.call } } }};
    kids[0].computed_x = 0;
    kids[0].computed_y = 0;
    kids[0].computed_width = 50;
    kids[0].computed_height = 20;
    var root = Widget{ .kind = .container, .children = &kids };
    root.computed_width = 50;
    root.computed_height = 20;
    root.linkParents();

    var d = Dispatcher{};
    d.pointerMotion(&root, 10, 10);
    try std.testing.expectEqual(layout.ButtonState.hover, root.children[0].kind.button.state);

    d.pointerButtonDown(&root, 10, 10);
    try std.testing.expectEqual(layout.ButtonState.press, root.children[0].kind.button.state);

    d.pointerButtonUp(&root, 10, 10);
    try std.testing.expectEqual(@as(u32, 1), Counter.count);

    // Press, then release off the button: no click.
    d.pointerButtonDown(&root, 10, 10);
    d.pointerButtonUp(&root, 999, 999);
    try std.testing.expectEqual(@as(u32, 1), Counter.count);
}

test "scrollWheel routes through the nearest scroll ancestor" {
    var row = Widget{ .kind = .container, .width = .{ .fixed = 50 }, .height = .{ .fixed = 200 } };
    row.computed_width = 50;
    row.computed_height = 200;
    var kids = [_]Widget{row};
    var scroll = Widget{ .kind = .{ .scroll_container = .{ .content_size = 200 } }, .direction = .column, .children = &kids };
    scroll.computed_x = 0;
    scroll.computed_y = 0;
    scroll.computed_width = 50;
    scroll.computed_height = 100;
    scroll.linkParents();

    var d = Dispatcher{};
    try std.testing.expect(!d.scrollWheel(&scroll, 10, 10, scroll_widget.wheel_step_px, null));
    try std.testing.expectEqual(@as(f32, scroll_widget.wheel_step_px), scroll.kind.scroll_container.scroll_offset);
}

test "scrollWheel on a non-scroll sibling still scrolls the panel's list" {
    var row = Widget{ .kind = .container, .width = .{ .fixed = 50 }, .height = .{ .fixed = 200 } };
    row.computed_width = 50;
    row.computed_height = 200;
    var scroll_kids = [_]Widget{row};
    var scroll = Widget{ .kind = .{ .scroll_container = .{ .content_size = 200 } }, .direction = .column, .children = &scroll_kids };
    scroll.computed_x = 0;
    scroll.computed_y = 50;
    scroll.computed_width = 50;
    scroll.computed_height = 100;

    var header = Widget{ .kind = .container };
    header.computed_x = 0;
    header.computed_y = 0;
    header.computed_width = 50;
    header.computed_height = 50;

    var kids = [_]Widget{ header, scroll };
    var root = Widget{ .kind = .container, .children = &kids };
    root.computed_width = 50;
    root.computed_height = 150;
    root.linkParents();

    var d = Dispatcher{};
    try std.testing.expect(d.scrollWheel(&root, 10, 10, scroll_widget.wheel_step_px, 0));
    const offset = &root.children[1].kind.scroll_container.scroll_offset;
    try std.testing.expectEqual(@as(f32, 0), offset.*);
    try std.testing.expect(scroll_widget.stepGlides(&root, 60, 1));
    try std.testing.expect(offset.* > 0 and offset.* < scroll_widget.wheel_step_px);
    try std.testing.expect(!scroll_widget.stepGlides(&root, 1000, 1));
    try std.testing.expectEqual(@as(f32, scroll_widget.wheel_step_px), offset.*);
}

test "pointerMotion after the previous tree is gone does not switch on a freed kind" {
    // Mirrors control-center close/reopen: hover the overlay thumb, free that
    // tree, then motion on a new one. Poisoning the old WidgetKind is what
    // gpa.destroy leaves behind; without bindTree this panics the same way
    // the compositor did (`switch on corrupt value` in setThumbHover).
    var d = Dispatcher{};
    var old = Widget{ .kind = .{ .scroll_container = .{ .content_size = 200 } }, .direction = .column };
    old.computed_width = 50;
    old.computed_height = 100;
    d.pointerMotion(&old, 48, 10);
    try std.testing.expectEqual(@as(?*Widget, &old), d.thumb_hover);

    @memset(std.mem.asBytes(&old), 0xff);

    var next = Widget{ .kind = .{ .scroll_container = .{ .content_size = 200 } }, .direction = .column };
    next.computed_width = 50;
    next.computed_height = 100;
    d.pointerMotion(&next, 10, 10);
    try std.testing.expect(d.tree == &next);
    try std.testing.expect(d.thumb_hover == null);
}

test "pointerLeave unhovers the thumb of its own tree and nobody else's" {
    var d = Dispatcher{};
    var tree = Widget{ .kind = .{ .scroll_container = .{ .content_size = 200 } }, .direction = .column };
    tree.computed_width = 50;
    tree.computed_height = 100;
    d.pointerMotion(&tree, 48, 10);
    try std.testing.expect(tree.kind.scroll_container.thumb_hover);
    var other = Widget{ .kind = .{ .scroll_container = .{ .content_size = 200 } }, .direction = .column };
    d.pointerLeave(&other);
    try std.testing.expect(tree.kind.scroll_container.thumb_hover);
    d.pointerLeave(&tree);
    try std.testing.expect(!tree.kind.scroll_container.thumb_hover);
    try std.testing.expect(d.thumb_hover == null);
}

test "reset drops hover pointers without dereferencing the tree" {
    var d = Dispatcher{};
    var old = Widget{ .kind = .{ .scroll_container = .{ .content_size = 200 } }, .direction = .column };
    old.computed_width = 50;
    old.computed_height = 100;
    d.pointerMotion(&old, 48, 10);
    @memset(std.mem.asBytes(&old), 0xff);
    d.reset();
    try std.testing.expect(d.thumb_hover == null);
    try std.testing.expect(d.tree == null);
}

test "row widget click fires on_click with context and owner" {
    const Context = struct {
        clicked_id: usize = 999,
        clicked_owner: ?*anyopaque = null,
        retire: ?*Widget = null,
        fn callback(owner: ?*anyopaque, id: usize) void {
            if (owner) |o| {
                const self: *@This() = @ptrCast(@alignCast(o));
                self.clicked_id = id;
                self.clicked_owner = o;
                if (self.retire) |widget| {
                    self.retire = null;
                    std.testing.allocator.destroy(widget);
                }
            }
        }
    };
    var ctx = Context{};
    const row_child = Widget{
        .kind = .{ .text = .{ .content = "Click me", .font_size = 12, .color = .{ 1, 1, 1, 1 } } },
        .computed_x = 10,
        .computed_y = 5,
        .computed_width = 80,
        .computed_height = 20,
    };
    var row_children = [_]Widget{row_child};
    var row_widget = Widget{
        .kind = .{ .row = .{ .owner = &ctx, .id = 42, .on_click = &Context.callback } },
        .computed_x = 0,
        .computed_y = 0,
        .computed_width = 100,
        .computed_height = 30,
        .children = &row_children,
    };
    row_widget.linkParents();

    var d = Dispatcher{};
    // Click over the child text widget: bubbles to row
    d.pointerMotion(&row_widget, 15, 10);
    try std.testing.expectEqual(layout.ButtonState.hover, row_widget.kind.row.state);

    d.pointerButtonDown(&row_widget, 15, 10);
    try std.testing.expectEqual(layout.ButtonState.press, row_widget.kind.row.state);

    d.pointerButtonUp(&row_widget, 15, 10);
    try std.testing.expectEqual(@as(usize, 42), ctx.clicked_id);
    try std.testing.expectEqual(@as(?*anyopaque, &ctx), ctx.clicked_owner);
    // A callback can retire the pressed widget. Dispatch must finish all
    // state updates before invoking it, and the host then drops tree pointers.
    const transient = try std.testing.allocator.create(Widget);
    transient.* = .{
        .kind = .{ .button = .{ .owner = &ctx, .id = 73, .on_click = Context.callback } },
        .computed_width = 100,
        .computed_height = 30,
    };
    ctx.retire = transient;
    d.reset();
    d.pointerMotion(transient, 15, 10);
    d.pointerButtonDown(transient, 15, 10);
    d.pointerButtonUp(transient, 15, 10);
    d.reset();
    try std.testing.expect(ctx.retire == null);
    try std.testing.expectEqual(@as(usize, 73), ctx.clicked_id);
}

// ---- Caret ----

fn withCaretConfig(cfg: CaretConfig) void {
    input_src.caret_config = cfg;
}

test "blink is a square wave over the time since the last edit" {
    defer withCaretConfig(.{});
    withCaretConfig(.{ .blink_ms = 1000, .blink_timeout_s = 10, .motion_ms = 0 });

    var caret = Caret{};
    caret.noteEdit(0);
    // Solid the instant you type, and for the first half cycle: that is what
    // stops a caret from blinking out from under the character you just hit.
    try std.testing.expect(caret.visible(0));
    try std.testing.expect(caret.visible(499));
    try std.testing.expect(!caret.visible(500));
    try std.testing.expect(!caret.visible(999));
    try std.testing.expect(caret.visible(1000));

    // The phase origin follows the edit, so typing mid-off-phase turns the
    // caret back on rather than waiting out the cycle.
    caret.noteEdit(700);
    try std.testing.expect(caret.visible(700));
    try std.testing.expect(caret.visible(1199));
    try std.testing.expect(!caret.visible(1200));
}

test "blinking stops for good once the timeout passes, and so does the frame pump" {
    defer withCaretConfig(.{});
    withCaretConfig(.{ .blink_ms = 1000, .blink_timeout_s = 5, .motion_ms = 0 });

    var caret = Caret{};
    caret.noteEdit(0);
    try std.testing.expect(caret.animating(4999));
    try std.testing.expect(!caret.visible(4500)); // still winking just before

    // Past the timeout the caret is solid forever and wants no more frames —
    // this, not the blink itself, is what lets a focused idle field cost
    // nothing.
    try std.testing.expect(caret.visible(5000));
    try std.testing.expect(caret.visible(5500));
    try std.testing.expect(caret.visible(60_000));
    try std.testing.expect(!caret.animating(5000));
    try std.testing.expect(!caret.animating(60_000));
}

test "blink_timeout 0 blinks forever, blink_ms 0 never blinks" {
    defer withCaretConfig(.{});

    var caret = Caret{};
    caret.noteEdit(0);

    withCaretConfig(.{ .blink_ms = 1000, .blink_timeout_s = 0, .motion_ms = 0 });
    try std.testing.expect(!caret.visible(3_600_500));
    try std.testing.expect(caret.animating(3_600_500));

    // The hard off switch, and the accessibility escape hatch: solid caret,
    // no repaints at all.
    withCaretConfig(.{ .blink_ms = 0, .blink_timeout_s = 10, .motion_ms = 0 });
    try std.testing.expect(caret.visible(500));
    try std.testing.expect(caret.visible(5_000_000));
    try std.testing.expect(!caret.animating(500));
}

test "motion glides between offsets and holds the caret solid in flight" {
    defer withCaretConfig(.{});
    withCaretConfig(.{ .blink_ms = 1000, .blink_timeout_s = 10, .motion_ms = 80 });

    var caret = Caret{};
    caret.noteEdit(0);
    caret.track(0, 10); // first sample always snaps: there is no "from" yet
    try std.testing.expectEqual(@as(f32, 10), caret.offset(0));

    caret.noteEdit(0);
    caret.track(0, 40);
    const mid = caret.offset(40);
    try std.testing.expect(mid > 10 and mid < 40);
    try std.testing.expect(caret.moving(40));
    // A caret that winks out mid-glide reads as a rendering fault, so motion
    // overrides the blink phase even at what would be the off half.
    try std.testing.expect(caret.visible(40));

    try std.testing.expectEqual(@as(f32, 40), caret.offset(80));
    try std.testing.expect(!caret.moving(80));
}

test "motion_ms 0 snaps, and a long jump snaps even when motion is on" {
    defer withCaretConfig(.{});

    var caret = Caret{};
    withCaretConfig(.{ .blink_ms = 1000, .blink_timeout_s = 10, .motion_ms = 0 });
    caret.track(0, 10);
    caret.track(0, 90);
    try std.testing.expectEqual(@as(f32, 90), caret.offset(0));
    try std.testing.expect(!caret.moving(0));

    // Home/End, a focus change or a click across the field move the caret
    // further than any glide should cover; sweeping that distance reads as
    // lag, not as motion. The threshold is measured from where the caret
    // actually is right now, so it is right mid-glide too.
    withCaretConfig(.{ .blink_ms = 1000, .blink_timeout_s = 10, .motion_ms = 80 });
    caret.track(0, 0); // glides down from 90
    try std.testing.expectEqual(@as(f32, 0), caret.offset(80));
    caret.track(80, caret_snap_distance + 1);
    try std.testing.expectEqual(caret_snap_distance + 1, caret.offset(80));
    try std.testing.expect(!caret.moving(80));

    // Just under the threshold is a glide, not a snap.
    caret.track(80, caret_snap_distance * 2);
    try std.testing.expect(caret.moving(80));
}

test "a burst of moves keeps up with the text instead of gliding behind it" {
    defer withCaretConfig(.{});
    withCaretConfig(.{ .blink_ms = 1000, .blink_timeout_s = 10, .motion_ms = 80 });

    var caret = Caret{};
    caret.track(0, 10);
    // An isolated move glides.
    caret.track(1000, 20);
    try std.testing.expect(caret.moving(1016));
    // Key repeat every 35 ms: each move lands before the last glide ends.
    // Retargeting would chase the text a character behind for as long as the
    // key is held; a burst snaps to where the text is.
    var at: i64 = 1035;
    var offset: f32 = 30;
    while (at < 1400) : ({
        at += 35;
        offset += 10;
    }) {
        caret.track(at, offset);
        try std.testing.expectEqual(offset, caret.offset(at));
    }
    // Repainting at the same offset is not a move and doesn't extend the
    // burst: once the key is let go, the next move glides again.
    caret.track(at + 10, offset - 10);
    caret.track(at + 60, offset);
    try std.testing.expect(caret.moving(at + 76));
}

test "keyEvent holds the caret solid, and Home/End snap rather than sweep" {
    defer withCaretConfig(.{});
    defer anim.setNowMs(null);
    withCaretConfig(.{ .blink_ms = 1000, .blink_timeout_s = 10, .motion_ms = 80 });

    const Ignore = struct {
        fn call(_: ?*anyopaque, _: usize, _: []const u8) void {}
    };
    var value = [_]u8{ 'a', 'b', 'c' };
    var field = Widget{ .kind = .{ .text_input = .{
        .placeholder = "",
        .value = &value,
        .cursor_pos = 0,
        .on_change = &Ignore.call,
    } } };

    var d = Dispatcher{};
    d.focused = &field;
    d.caret.noteEdit(0);
    d.caret.track(0, 0);
    d.caret.snap = false;

    anim.setNowMs(5000);
    _ = try d.keyEvent(std.testing.allocator, .right, .{});
    // Typing or moving restarts the blink phase, so the caret is solid at the
    // moment you act on it however long the field had been idle.
    try std.testing.expectEqual(@as(i64, 5000), d.caret.last_edit_ms);
    try std.testing.expect(d.caret.visible(5000));
    try std.testing.expect(!d.caret.snap);
    try std.testing.expectEqual(@as(usize, 1), field.kind.text_input.cursor_pos);

    anim.setNowMs(6000);
    _ = try d.keyEvent(std.testing.allocator, .end, .{});
    try std.testing.expect(d.caret.snap);
    try std.testing.expectEqual(@as(usize, 3), field.kind.text_input.cursor_pos);
}

test "scrollTo keeps the caret inside the field and stays put while it fits" {
    var caret = Caret{};
    // Text narrower than the field never scrolls, wherever the caret is.
    try std.testing.expectEqual(@as(f64, 0), caret.scrollTo(0, 200, 120));
    try std.testing.expectEqual(@as(f64, 0), caret.scrollTo(120, 200, 120));

    // A caret past the right edge pulls the text left far enough to show it
    // with a margin — this is the bug where an overflowing value ellipsized
    // and the caret was drawn outside the field entirely.
    const scrolled = caret.scrollTo(500, 200, 600);
    try std.testing.expect(scrolled > 0);
    const on_screen = 500 - scrolled;
    try std.testing.expect(on_screen > 0 and on_screen < 200);

    // Scrolling is minimal: a caret already comfortably in view does not move
    // the text at all.
    try std.testing.expectEqual(scrolled, caret.scrollTo(480, 200, 600));

    // Home scrolls back to the start, End to the very end and no further.
    try std.testing.expectEqual(@as(f64, 0), caret.scrollTo(0, 200, 600));
    try std.testing.expectEqual(@as(f64, 400), caret.scrollTo(600, 200, 600));
}

test "caret state survives the tree rebuild that happens on every keystroke" {
    // start_menu/panel.zig rebuilds its whole tree — and so resets its
    // dispatcher — from inside the on_change the edit itself fires. A caret
    // wiped there would restart its glide and its blink phase on every
    // character typed.
    var d = Dispatcher{};
    d.caret.noteEdit(1234);
    d.caret.track(1234, 42);
    d.caret.scroll = 17;

    var root = Widget{ .kind = .container };
    root.computed_width = 50;
    root.computed_height = 50;
    d.pointerMotion(&root, 10, 10);
    d.reset();

    try std.testing.expectEqual(@as(i64, 1234), d.caret.last_edit_ms);
    try std.testing.expectEqual(@as(f32, 42), d.caret.offset(1234));
    try std.testing.expectEqual(@as(f64, 17), d.caret.scroll);
    try std.testing.expect(d.tree == null);
}

test "Ctrl+A, copy and cut report what the shell should put on the clipboard" {
    defer withCaretConfig(.{});
    const allocator = std.testing.allocator;
    const Ignore = struct {
        fn call(_: ?*anyopaque, _: usize, _: []const u8) void {}
    };
    var field = Widget{ .kind = .{ .text_input = .{
        .placeholder = "",
        .value = try allocator.dupe(u8, "hello world"),
        .cursor_pos = 0,
        .on_change = &Ignore.call,
    } } };
    defer allocator.free(field.kind.text_input.value);

    var d = Dispatcher{};
    d.focused = &field;

    // Copy with nothing selected hands back nothing rather than the value:
    // Ctrl+C on an unselected field must not quietly replace the clipboard.
    try std.testing.expectEqual(@as(?[]const u8, null), (try d.keyEvent(allocator, .copy, .{})).copy);

    _ = try d.keyEvent(allocator, .select_all, .{});
    const copied = (try d.keyEvent(allocator, .copy, .{})).copy;
    defer allocator.free(copied.?);
    try std.testing.expectEqualStrings("hello world", copied.?);
    // A copy leaves the value alone.
    try std.testing.expectEqualStrings("hello world", field.kind.text_input.value);

    // A cut hands back an owned copy, because the delete that follows frees
    // the buffer the selection pointed into.
    field.kind.text_input.selection_anchor = 0;
    field.kind.text_input.cursor_pos = 5;
    const cut = (try d.keyEvent(allocator, .cut, .{})).copy;
    defer allocator.free(cut.?);
    try std.testing.expectEqualStrings("hello", cut.?);
    try std.testing.expectEqualStrings(" world", field.kind.text_input.value);

    // And paste puts text in at the caret.
    _ = try d.keyEvent(allocator, .{ .paste = "goodbye" }, .{});
    try std.testing.expectEqualStrings("goodbye world", field.kind.text_input.value);
}

test "shift turns the motion keys into selection, without it they do not" {
    const allocator = std.testing.allocator;
    const Ignore = struct {
        fn call(_: ?*anyopaque, _: usize, _: []const u8) void {}
    };
    var value = "hello".*;
    var field = Widget{ .kind = .{ .text_input = .{
        .placeholder = "",
        .value = &value,
        .cursor_pos = 0,
        .on_change = &Ignore.call,
    } } };

    var d = Dispatcher{};
    d.focused = &field;

    _ = try d.keyEvent(allocator, .end, .{ .shift = true });
    try std.testing.expectEqualStrings("hello", field.kind.text_input.selectedText());

    _ = try d.keyEvent(allocator, .home, .{});
    try std.testing.expect(field.kind.text_input.selection() == null);
    try std.testing.expectEqual(@as(usize, 0), field.kind.text_input.cursor_pos);
}

test "a second press in the same spot selects a word, a third the whole value" {
    defer anim.setNowMs(null);
    const Ignore = struct {
        fn call(_: ?*anyopaque, _: usize, _: []const u8) void {}
    };
    var value = "alpha beta".*;
    var kids = [_]Widget{.{ .kind = .{ .text_input = .{
        .placeholder = "",
        .value = &value,
        .cursor_pos = 0,
        .on_change = &Ignore.call,
    } } }};
    kids[0].computed_width = 200;
    kids[0].computed_height = 30;
    var root = Widget{ .kind = .container, .children = &kids };
    root.computed_width = 200;
    root.computed_height = 30;
    root.linkParents();
    const field = &root.children[0];

    var d = Dispatcher{};
    // Pretend a paint has happened: hit testing needs the geometry, and
    // `offsetAt` has no way to invent it.
    d.caret.field = .{ .text_x = 0, .font_size = 13, .scale = 1 };

    anim.setNowMs(1000);
    d.pointerButtonDown(&root, 20, 10);
    try std.testing.expect(field.kind.text_input.selection() == null);
    d.pointerButtonUp(&root, 20, 10);

    anim.setNowMs(1000 + multi_click_ms - 1);
    d.pointerButtonDown(&root, 20, 10);
    try std.testing.expectEqualStrings("alpha", field.kind.text_input.selectedText());
    d.pointerButtonUp(&root, 20, 10);

    anim.setNowMs(1000 + multi_click_ms);
    d.pointerButtonDown(&root, 20, 10);
    try std.testing.expectEqualStrings("alpha beta", field.kind.text_input.selectedText());
    d.pointerButtonUp(&root, 20, 10);

    // Too slow to continue the run, so it starts over as a single click.
    anim.setNowMs(1000 + multi_click_ms * 10);
    d.pointerButtonDown(&root, 20, 10);
    try std.testing.expect(field.kind.text_input.selection() == null);

    // As does a press that moved too far, even in time.
    d.pointerButtonUp(&root, 20, 10);
    anim.setNowMs(1000 + multi_click_ms * 10 + 10);
    d.pointerButtonDown(&root, 20 + multi_click_slop + 1, 10);
    try std.testing.expect(field.kind.text_input.selection() == null);
}

test "dragging across a field sweeps a selection and releasing ends it" {
    defer anim.setNowMs(null);
    anim.setNowMs(1000);
    const Ignore = struct {
        fn call(_: ?*anyopaque, _: usize, _: []const u8) void {}
    };
    var value = "alpha beta".*;
    var kids = [_]Widget{.{ .kind = .{ .text_input = .{
        .placeholder = "",
        .value = &value,
        .cursor_pos = 0,
        .on_change = &Ignore.call,
    } } }};
    kids[0].computed_width = 200;
    kids[0].computed_height = 30;
    var root = Widget{ .kind = .container, .children = &kids };
    root.computed_width = 200;
    root.computed_height = 30;
    root.linkParents();
    const field = &root.children[0];

    var d = Dispatcher{};
    d.caret.field = .{ .text_x = 0, .font_size = 13, .scale = 1 };

    d.pointerButtonDown(&root, 0, 10);
    try std.testing.expect(d.text_drag == field);
    d.pointerMotion(&root, 60, 10);
    const swept = field.kind.text_input.selectedText();
    try std.testing.expect(swept.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, "alpha beta", swept));

    // A drag can leave the field entirely; the offset clamps rather than
    // dropping the selection.
    d.pointerMotion(&root, 10_000, 10);
    try std.testing.expectEqualStrings("alpha beta", field.kind.text_input.selectedText());

    d.pointerButtonUp(&root, 10_000, 10);
    try std.testing.expect(d.text_drag == null);
    // Motion after the release is plain hover again, so the selection stands.
    d.pointerMotion(&root, 0, 10);
    try std.testing.expectEqualStrings("alpha beta", field.kind.text_input.selectedText());
}

test "pointer motion invalidates changed proximity samples but not repeated samples" {
    var children = [_]Widget{.{ .kind = .{ .button = .{ .label = "Button" } }, .computed_width = 100, .computed_height = 30 }};
    var root: Widget = .{ .kind = .container, .computed_width = 120, .computed_height = 80, .children = &children };
    root.linkParents();
    var dispatcher: Dispatcher = .{};
    dispatcher.pointerMotion(&root, 10, 10);
    var revision = layout.paint_revision;

    dispatcher.pointerMotion(&root, 11, 10);
    try std.testing.expect(revision != layout.paint_revision);
    revision = layout.paint_revision;
    dispatcher.pointerMotion(&root, 11, 10);
    try std.testing.expectEqual(revision, layout.paint_revision);

    dispatcher.pointerMotion(&root, 110, 60);
    try std.testing.expect(revision != layout.paint_revision);
    revision = layout.paint_revision;
    dispatcher.pointerMotion(&root, 110, 60);
    try std.testing.expectEqual(revision, layout.paint_revision);

    var scroll: Widget = .{ .kind = .{ .scroll_container = .{ .content_size = 300 } }, .direction = .column, .computed_width = 100, .computed_height = 100 };
    _ = dispatcher.scrollWheel(&scroll, 10, 10, -40, null);
    try std.testing.expectEqual(revision, layout.paint_revision);
    _ = dispatcher.scrollWheel(&scroll, 10, 10, 40, null);
    try std.testing.expect(revision != layout.paint_revision);
}
