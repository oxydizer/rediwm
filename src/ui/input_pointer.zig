//! Dispatcher pointer handling: motion and hover, presses (including into text), releases and the wheel.

const std = @import("std");
const anim = @import("anim.zig");
const layout = @import("layout.zig");
const Widget = layout.Widget;
const button_widget = @import("widgets/button.zig");
const checkbox_widget = @import("widgets/checkbox.zig");
const scroll_widget = @import("widgets/scroll_container.zig");
const text_input_widget = @import("widgets/text_input.zig");
const toggle_widget = @import("widgets/toggle.zig");
const slider_widget = @import("widgets/slider.zig");
const select_widget = @import("widgets/select.zig");
const segmented_widget = @import("widgets/segmented.zig");
const swatch_widget = @import("widgets/swatch.zig");
const stepper_widget = @import("widgets/stepper.zig");
const arrangement_widget = @import("widgets/arrangement.zig");
const input_mod = @import("input.zig");
const Dispatcher = input_mod.Dispatcher;
const hitTest = input_mod.hitTest;
const hitTestWithScrollAncestor = input_mod.hitTestWithScrollAncestor;
const openSelect = input_mod.openSelect;
const dragCoord = input_mod.dragCoord;
const findInteractive = input_mod.findInteractive;
const isInteractiveButtonOrRow = input_mod.isInteractiveButtonOrRow;
const setButtonOrRowState = input_mod.setButtonOrRowState;
const fireRowClick = input_mod.fireRowClick;
const multi_click_ms = input_mod.multi_click_ms;
const multi_click_slop = input_mod.multi_click_slop;
const setThumbHover = input_mod.setThumbHover;
const findScrollContainer = input_mod.findScrollContainer;

pub fn pointerMotion(self: *Dispatcher, root: *Widget, x: f32, y: f32) void {
    self.bindTree(root);
    _ = input_mod.updateButtonProximity(root, x, y, .{
        .x = root.computed_x,
        .y = root.computed_y,
        .w = root.computed_width,
        .h = root.computed_height,
    });
    if (self.text_drag) |field| {
        // Sweeping a selection: the pointer may be well outside the field
        // by now, and `offsetAtX` clamps to the ends, so no hit test.
        const value = field.kind.text_input.value;
        if (self.caret.offsetAt(value, x)) |offset| {
            const before = field.kind.text_input;
            text_input_widget.setCursor(field, offset, true);
            const after = field.kind.text_input;
            if (before.cursor_pos != after.cursor_pos or before.selection_anchor != after.selection_anchor)
                field.markDirty();
        }
        return;
    }
    if (self.slider_drag) |slider| {
        slider_widget.dragTo(slider, x);
        return;
    }
    if (self.arrangement_drag) |arrangement| {
        arrangement_widget.dragTo(arrangement, x, y);
        return;
    }
    if (self.scroll_drag) |scroll| {
        scroll_widget.dragTo(scroll, dragCoord(scroll, x, y));
        return;
    }

    if (openSelect(root)) |w| {
        if (select_widget.optionAt(w, x, y)) |index| select_widget.highlight(w, index);
    }
    const result = hitTestWithScrollAncestor(root, x, y);
    const target = findInteractive(result.widget);
    const change = self.surface.pointerMotion(input_mod.interactionHit(root, target, x, y));
    if (change.hover_changed or self.hovered != target) self.setHovered(target);

    // Safer than `.?` on `scroll_ancestor`: over_thumb is only true when
    // that pointer is non-null, but a hit-test race must not crash.
    if (result.scroll_ancestor) |scroll| {
        const over_thumb = scroll_widget.hitTestThumb(scroll, x, y);
        if (self.thumb_hover) |prev| {
            if (!over_thumb or prev != scroll) setThumbHover(prev, false);
        }
        if (over_thumb) {
            setThumbHover(scroll, true);
            self.thumb_hover = scroll;
        } else {
            self.thumb_hover = null;
        }
    } else {
        if (self.thumb_hover) |prev| setThumbHover(prev, false);
        self.thumb_hover = null;
    }
}

pub fn pointerButtonDown(self: *Dispatcher, root: *Widget, x: f32, y: f32) void {
    self.bindTree(root);
    if (openSelect(root)) |w| {
        if (!w.contains(x, y) and select_widget.optionAt(w, x, y) == null) {
            select_widget.close(w);
            self.pressed = null;
            return;
        }
    }
    const result = hitTestWithScrollAncestor(root, x, y);

    if (result.scroll_ancestor) |scroll| {
        switch (scroll_widget.pressBar(scroll, x, y)) {
            .grabbed => {
                self.scroll_drag = scroll;
                return;
            },
            .paged => return,
            .none => {},
        }
    }

    const target = findInteractive(result.widget);
    if (target) |w| {
        if (std.meta.activeTag(w.kind) == .slider) {
            self.slider_drag = w;
            slider_widget.beginDrag(w, x);
            return;
        }
        if (std.meta.activeTag(w.kind) == .arrangement) {
            self.setFocused(null);
            arrangement_widget.beginDrag(w, x, y);
            if (w.kind.arrangement.drag != null) self.arrangement_drag = w;
            return;
        }
    }

    self.pressed = target;
    const widget = target orelse {
        self.setFocused(null);
        return;
    };
    switch (widget.kind) {
        .button, .row => setButtonOrRowState(widget, .press),
        .checkbox => if (!widget.kind.checkbox.disabled) {
            self.setFocused(widget);
        },
        .select => if (!widget.kind.select.disabled) {
            self.setFocused(widget);
        },
        .text_input => {
            self.setFocused(widget);
            self.pressInText(widget, x, y);
        },
        .secret_input => {
            self.setFocused(widget);
            widget.kind.secret_input.input.cursor = widget.kind.secret_input.input.len;
            widget.markDirty();
        },
        else => if (self.focused) |f| {
            if (f != widget) self.setFocused(null);
        },
    }
}

/// Places the caret, or selects a word or the whole value on a double or
/// triple click, and arms a drag-select.
pub fn pressInText(self: *Dispatcher, widget: *Widget, x: f32, y: f32) void {
    const now = anim.nowMs();
    const repeat = now - self.last_click_ms <= multi_click_ms and
        @abs(x - self.last_click_x) <= multi_click_slop and
        @abs(y - self.last_click_y) <= multi_click_slop;
    self.click_count = if (repeat) self.click_count +| 1 else 1;
    self.last_click_ms = now;
    self.last_click_x = x;
    self.last_click_y = y;
    self.caret.noteJump(now);

    const value = widget.kind.text_input.value;
    // Without a paint there is no geometry to hit test against; putting
    // the caret at the end is what clicking an unpainted field should do
    // anyway, and the next frame fills the metrics in.
    const offset = self.caret.offsetAt(value, x) orelse value.len;
    switch (self.click_count) {
        1 => {
            text_input_widget.setCursor(widget, offset, false);
            self.text_drag = widget;
        },
        2 => text_input_widget.selectWordAt(widget, offset),
        else => text_input_widget.selectAll(widget),
    }
}

pub fn pointerButtonUp(self: *Dispatcher, root: *Widget, x: f32, y: f32) void {
    self.bindTree(root);
    self.text_drag = null;
    if (self.slider_drag) |slider| {
        slider_widget.endDrag(slider);
        self.slider_drag = null;
        // Hover wasn't followed during the drag: the pointer may have been
        // released well off the slider.
        self.pointerMotion(root, x, y);
        return;
    }
    if (self.arrangement_drag) |arrangement| {
        arrangement_widget.endDrag(arrangement);
        self.arrangement_drag = null;
        return;
    }
    if (self.scroll_drag) |scroll| {
        scroll_widget.endDrag(scroll);
        self.scroll_drag = null;
        return;
    }

    const pressed = self.pressed orelse return;
    self.pressed = null;
    if (pressed.kind == .select) {
        if (pressed.kind.select.open) {
            if (select_widget.optionAt(pressed, x, y)) |index| {
                select_widget.commit(pressed, index);
            } else if (pressed.contains(x, y)) select_widget.close(pressed);
        } else if (pressed.contains(x, y)) select_widget.open(pressed);
        return;
    }
    const raw_target = hitTest(root, x, y);
    const released_over = findInteractive(raw_target);

    if (isInteractiveButtonOrRow(pressed)) setButtonOrRowState(pressed, if (self.hovered == pressed) .hover else .idle);
    if (released_over) |target| {
        if (target == pressed) {
            switch (pressed.kind) {
                .button => button_widget.press(pressed),
                .row => fireRowClick(pressed),
                .checkbox => checkbox_widget.toggle(pressed),
                .toggle => toggle_widget.toggle(pressed),
                .swatch => swatch_widget.select(pressed),
                .segmented => segmented_widget.selectAt(pressed, x),
                .stepper => stepper_widget.clickAt(pressed, x),
                else => {},
            }
        }
    }
}

/// `glide_now_ms` is set for detented wheel notches, which glide there
/// (`scroll_container.glideBy`); touchpad and other continuous motion is
/// already smooth and moves 1:1. Returns whether a glide started, which
/// the host must then drive with `scroll_container.stepGlides`.
pub fn scrollWheel(self: *Dispatcher, root: *Widget, x: f32, y: f32, delta_px: f32, glide_now_ms: ?i64) bool {
    self.bindTree(root);
    if (openSelect(root)) |w| {
        select_widget.scroll(w, delta_px);
        return false;
    }
    if (!root.contains(x, y)) return false;
    const result = hitTestWithScrollAncestor(root, x, y);
    var scroll = result.scroll_ancestor orelse findScrollContainer(root) orelse return false;
    while (scroll.kind.scroll_container.chain_at_edge and !scroll_widget.canScroll(scroll, delta_px)) {
        var parent = scroll.parent;
        while (parent != null and parent.?.kind != .scroll_container) parent = parent.?.parent;
        scroll = parent orelse return false;
    }
    if (glide_now_ms) |now_ms| return scroll_widget.glideBy(scroll, delta_px, now_ms);
    scroll_widget.scrollBy(scroll, delta_px);
    return false;
}

/// The pointer is over an editable text field, or sweeping a selection
/// in one: the shell shows the text cursor there.
pub fn overText(self: *const Dispatcher) bool {
    if (self.text_drag != null) return true;
    const w = self.hovered orelse return false;
    return w.kind == .text_input;
}

pub fn setHovered(self: *Dispatcher, next: ?*Widget) void {
    if (self.hovered == next) return;
    if (self.hovered) |prev| {
        if (prev.kind == .select) prev.markPaintDirty();
        if (prev.kind == .slider) slider_widget.setHovered(prev, false);
        if (isInteractiveButtonOrRow(prev) and prev != self.pressed) setButtonOrRowState(prev, .idle);
    }
    self.hovered = next;
    if (next) |w| {
        if (w.kind == .select) w.markPaintDirty();
        if (w.kind == .slider) slider_widget.setHovered(w, true);
        if (isInteractiveButtonOrRow(w) and w != self.pressed) setButtonOrRowState(w, .hover);
    }
}
