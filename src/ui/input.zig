// Widget-tree hit-testing and pointer/keyboard dispatch. This does not touch
// wlroots at all — `scene_data.hitTest` (used by Input.zig for the existing
// chrome/taskbar/toplevel scene graph) is a separate concern; a shell
// surface built on this engine plugs into that existing pointer/keyboard
// event path by forwarding surface-local coordinates into `pointerMotion`
// etc. below, and xkb keysyms into `keyEvent`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const anim = @import("anim.zig");
const text_mod = @import("text.zig");
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

/// Walks the tree in reverse paint order (topmost/last-drawn first) and
/// returns the deepest widget whose computed rect contains `(x, y)`.
pub fn hitTest(root: *Widget, x: f32, y: f32) ?*Widget {
    return hitTestWithScrollAncestor(root, x, y).widget;
}

pub const HitResult = struct {
    widget: ?*Widget,
    /// The nearest enclosing `.scroll_container`, if any — its scrollbar is
    /// painted as an overlay rather than a tree node, so thumb/wheel
    /// interaction needs this in addition to the plain hit target. Wheel
    /// events over a non-scrolling sibling (search box, footer) fall back
    /// to the panel's scroll container instead of being dropped.
    scroll_ancestor: ?*Widget,
};

pub fn hitTestWithScrollAncestor(root: *Widget, x: f32, y: f32) HitResult {
    if (openSelect(root)) |w| {
        const b = select_widget.popupBounds(w);
        if (x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h)
            return .{ .widget = w, .scroll_ancestor = null };
    }
    return hitTestInner(root, x, y, null);
}

pub fn openSelect(root: *Widget) ?*Widget {
    if (root.kind == .select and root.kind.select.open) return root;
    for (root.children) |*child| if (openSelect(child)) |found| return found;
    return null;
}

fn hitTestInner(root: *Widget, x: f32, y: f32, scroll_ancestor: ?*Widget) HitResult {
    if (!root.contains(x, y)) return .{ .widget = null, .scroll_ancestor = null };
    const next_ancestor = if (std.meta.activeTag(root.kind) == .scroll_container) root else scroll_ancestor;

    var i = root.children.len;
    while (i > 0) {
        i -= 1;
        const result = hitTestInner(&root.children[i], x, y, next_ancestor);
        if (result.widget != null) return result;
    }
    return .{ .widget = root, .scroll_ancestor = next_ancestor };
}

fn dragCoord(scroll: *const Widget, x: f32, y: f32) f32 {
    return if (scroll.direction == .row) x else y;
}

pub fn findInteractive(start: ?*Widget) ?*Widget {
    var cur = start;
    while (cur) |w| {
        switch (w.kind) {
            .button, .row, .toggle, .slider, .select, .segmented, .swatch, .stepper, .text_input, .secret_input, .arrangement => return w,
            .checkbox => if (!w.kind.checkbox.disabled) return w,
            .scroll_container => return null,
            else => cur = w.parent,
        }
    }
    return start;
}

fn isInteractiveButtonOrRow(widget: *const Widget) bool {
    return switch (widget.kind) {
        .button => |data| data.state != .disabled,
        .row => |data| data.state != .disabled,
        else => false,
    };
}

fn setButtonOrRowState(widget: *Widget, state: layout.ButtonState) void {
    switch (widget.kind) {
        .button => |data| {
            if (data.state != .disabled) button_widget.setState(widget, state);
        },
        .row => |*data| {
            if (data.state != .disabled and data.state != state) {
                data.state = state;
                widget.markDirty();
            }
        },
        else => {},
    }
}

fn fireRowClick(widget: *Widget) void {
    switch (widget.kind) {
        .row => |data| {
            if (data.state != .disabled) {
                if (data.on_click) |cb| {
                    cb(data.owner, data.id);
                }
            }
        },
        else => {},
    }
}

/// Text-caret behaviour. Appearance (width, colour) lives in `theme.Theme`;
/// these are the timings, which belong with `key_repeat_delay`/`_rate` in the
/// compositor's `[input]` section. The engine keeps its own copy rather than
/// importing `config/loader.zig`, the way `theme.global` does — `ui/` must not
/// depend on the compositor, and `applyInputConfig` pushes changes in on every
/// load and hot reload.
pub const CaretConfig = struct {
    /// Full on+off cycle. 0 disables blinking (the accessibility escape
    /// hatch), leaving a solid caret.
    blink_ms: u32 = 1060,
    /// Seconds of no editing after which blinking stops and the caret goes
    /// solid. This is what lets the frame pump stop on a focused idle field;
    /// 0 means blink forever, which costs a repaint every half cycle for as
    /// long as the field keeps focus.
    blink_timeout_s: u32 = 10,
    /// Glide duration when the caret moves. 0 snaps.
    motion_ms: u32 = 80,
};

/// Process-wide, like `theme.global`, and for the same reason: widgets read
/// it at paint time, so there is nothing to thread through the tree.
pub var caret_config: CaretConfig = .{};

/// Window for a double or triple click, and how far the pointer may drift
/// between them. Matches the usual toolkit defaults closely enough that a
/// double click feels the same here as in a client.
pub const multi_click_ms: i64 = 400;
pub const multi_click_slop: f32 = 4;

/// Beyond this many logical pixels a move is a jump, not a glide — a focus
/// change, Home/End, or a click across the field. Animating those reads as
/// lag rather than as motion, so they snap.
pub const caret_snap_distance: f32 = 120;

/// Animation state for the one focused text caret. It lives on the
/// `Dispatcher` rather than in `TextInputData` because widget kinds are
/// copied by value and whole trees are rebuilt on every keystroke (see
/// `start_menu/panel.zig:buildTree`), so per-widget animation state would be
/// discarded before it could be sampled. There is exactly one focused text
/// input, which is exactly the scope of this state.
pub const Caret = struct {
    /// Offset of the caret *within* its field, never an absolute coordinate:
    /// the start menu slides its whole panel while open, and animating the
    /// absolute position would double-animate the caret against that slide.
    x: anim.Anim = .{},
    /// Always retargets to 0 until the engine grows multi-line text. Present
    /// so line motion is a matter of feeding it a line index later, not a
    /// redesign.
    y: anim.Anim = .{},
    /// Blink phase origin. Reset on every edit and every caret move, which is
    /// what makes the caret sit solid while you type and resume blinking only
    /// when you pause — a free-running global phase gets that wrong.
    last_edit_ms: i64 = 0,
    /// Set when the next measured offset must be taken without a glide.
    snap: bool = true,
    /// Reveal inserted text only up to the animated caret. Navigation and
    /// deletion leave the existing text fully visible.
    revealing: bool = false,
    /// When the last glide (or burst snap) retargeted the caret. A move that
    /// lands sooner than `motion_ms` after it is part of a burst — key repeat,
    /// fast typing — and snaps: retargeting an in-flight glide every repeat
    /// leaves the caret permanently a character behind the text. Null after a
    /// forced snap, so the move after a jump still glides.
    last_move_ms: ?i64 = null,
    /// Horizontal scroll of the field's text, in logical pixels. Lives here
    /// for the same reason the animation does — the widget is rebuilt on
    /// every keystroke — and it is what keeps the caret inside a field whose
    /// value is wider than its box.
    scroll: f32 = 0,
    /// Where and how the focused field was last painted. Pointer hit testing
    /// needs the text's origin, size and output scale to map an x back to a
    /// byte offset, and none of that is known at pointer time — the paint pass
    /// is the only place that resolves the palette and the renderer's scale.
    /// Null until the field has been painted once.
    field: ?FieldMetrics = null,

    pub const FieldMetrics = struct {
        /// Absolute x of the text's origin, before scrolling.
        text_x: f32,
        font_size: f32,
        scale: f32,
    };

    /// Byte offset in `value` under an absolute pointer x, using the geometry
    /// of the last paint.
    pub fn offsetAt(self: Caret, value: []const u8, pointer_x: f32) ?usize {
        const field = self.field orelse return null;
        const pen = pointer_x - field.text_x + self.scroll;
        return text_mod.offsetAtX(value, .manrope, field.font_size, field.scale, pen) catch null;
    }

    /// Restarts blinking for navigation or deletion.
    pub fn noteEdit(self: *Caret, now_ms: i64) void {
        self.last_edit_ms = now_ms;
        self.revealing = false;
    }

    pub fn noteInsert(self: *Caret, now_ms: i64) void {
        // Typing during a navigation glide must not hide existing letters
        // between the animated caret and the actual insertion point.
        if (!self.revealing and self.moving(now_ms)) self.snap = true;
        self.last_edit_ms = now_ms;
        self.revealing = true;
    }

    pub fn noteJump(self: *Caret, now_ms: i64) void {
        self.noteEdit(now_ms);
        self.snap = true;
    }

    /// Points the caret at `offset_px` within its field, gliding unless the
    /// move is a jump or motion is disabled. Idempotent, so the paint pass —
    /// the only thing that knows how wide the shaped prefix is — can call it
    /// every frame.
    pub fn track(self: *Caret, now_ms: i64, offset_px: f32) void {
        if (!self.snap and offset_px == self.x.to) return;
        const motion_ms: i64 = @intCast(caret_config.motion_ms);
        const forced = self.snap or motion_ms == 0 or
            (self.revealing and offset_px < self.x.value(now_ms)) or
            @abs(offset_px - self.x.value(now_ms)) > caret_snap_distance;
        const burst = if (self.last_move_ms) |at| now_ms - at < motion_ms else false;
        self.last_move_ms = if (forced) null else now_ms;
        if (forced or burst) {
            self.snap = false;
            // Assign rather than retarget: a jump must also kill whatever
            // glide was in flight, not ease out of it.
            self.x = .{ .from = offset_px, .to = offset_px };
            return;
        }
        self.x.retarget(now_ms, offset_px, motion_ms, .out_cubic);
    }

    pub fn offset(self: Caret, now_ms: i64) f32 {
        return self.x.value(now_ms);
    }

    /// Scrolls the field the least amount that puts a caret at `pen` back
    /// inside a `view_w`-wide window onto `content_w` of text, and returns the
    /// new offset. Whole logical pixels: a fractional scroll re-hints every
    /// glyph each frame, which reads as the text shimmering as you type.
    pub fn scrollTo(self: *Caret, pen: f32, view_w: f32, content_w: f32) f32 {
        const max_scroll = @max(0, content_w - view_w);
        // Never let the caret sit flush against either edge, where the field's
        // padding or border would cut it in half.
        const margin = @min(view_w / 4, 12);
        var s = std.math.clamp(self.scroll, 0, max_scroll);
        if (pen - s > view_w - margin) s = pen - view_w + margin;
        if (pen - s < margin) s = pen - margin;
        self.scroll = @round(std.math.clamp(s, 0, max_scroll));
        return self.scroll;
    }

    /// True while the caret is mid-glide. Callers hold it solid then: a caret
    /// that blinks out mid-flight reads as a rendering fault, not as motion.
    pub fn moving(self: Caret, now_ms: i64) bool {
        return !self.x.settled(now_ms) or !self.y.settled(now_ms);
    }

    /// Square wave over the time since the last edit, not a global phase.
    pub fn visible(self: Caret, now_ms: i64) bool {
        if (caret_config.blink_ms == 0) return true;
        if (self.moving(now_ms)) return true;
        const elapsed = now_ms - self.last_edit_ms;
        if (elapsed < 0) return true;
        if (self.blinkExpired(now_ms)) return true;
        const half: i64 = @intCast(caret_config.blink_ms / 2);
        if (half <= 0) return true;
        return @rem(@divFloor(elapsed, half), 2) == 0;
    }

    /// Whether blinking has timed out and the caret has gone permanently
    /// solid. This — not the blink itself — is what stops the frame pump.
    pub fn blinkExpired(self: Caret, now_ms: i64) bool {
        if (caret_config.blink_timeout_s == 0) return false;
        const timeout_ms: i64 = @as(i64, caret_config.blink_timeout_s) * 1000;
        return now_ms - self.last_edit_ms >= timeout_ms;
    }

    /// Whether the caret still needs frames: mid-glide, or blinking within
    /// the timeout window.
    pub fn animating(self: Caret, now_ms: i64) bool {
        if (self.moving(now_ms)) return true;
        return caret_config.blink_ms != 0 and !self.blinkExpired(now_ms);
    }
};

pub const Dispatcher = struct {
    hovered: ?*Widget = null,
    pressed: ?*Widget = null,
    focused: ?*Widget = null,
    scroll_drag: ?*Widget = null,
    thumb_hover: ?*Widget = null,
    slider_drag: ?*Widget = null,
    arrangement_drag: ?*Widget = null,
    /// Root last bound to this dispatcher. Pointers above are into that
    /// tree; a different root (control center closed and reopened) means
    /// they dangle, and must be dropped without being dereferenced.
    tree: ?*Widget = null,
    /// Survives `reset`/`bindTree`: it holds no pointers, and the start menu
    /// rebuilds its tree (and so resets its dispatcher) on every keystroke,
    /// which is precisely when a caret must *not* forget where it was.
    caret: Caret = .{},
    /// Text input the pointer is currently sweeping a selection across.
    text_drag: ?*Widget = null,
    /// Multi-click run: a second press close enough in time and space to the
    /// last selects a word, a third the whole value.
    click_count: u8 = 0,
    last_click_ms: i64 = 0,
    last_click_x: f32 = 0,
    last_click_y: f32 = 0,

    /// Drop every pointer into a widget tree. Safe after that tree has
    /// been freed — unlike `pointerMotion`, this does not dereference.
    pub fn reset(self: *Dispatcher) void {
        self.* = .{ .caret = self.caret };
    }

    fn bindTree(self: *Dispatcher, root: *Widget) void {
        if (self.tree == root) return;
        self.* = .{ .tree = root, .caret = self.caret };
    }

    /// The pointer is over something else now, so no scrollbar thumb of `root`
    /// is hovered. Rows keep their last state until the next motion. A no-op
    /// while the dispatcher belongs to another tree: those pointers are not
    /// `root`'s to clear.
    pub fn pointerLeave(self: *Dispatcher, root: *Widget) void {
        if (self.tree != root) return;
        if (self.thumb_hover) |prev| setThumbHover(prev, false);
        self.thumb_hover = null;
        // A slider is only lit while the pointer is over it; forgetting it as
        // hovered lets the pointer coming back light it again.
        if (self.hovered) |prev| if (prev.kind == .slider) {
            slider_widget.setHovered(prev, false);
            self.hovered = null;
        };
    }

    /// Focus moves are jumps: the caret reappears somewhere unrelated, and a
    /// glide across that gap reads as lag.
    pub fn focus(self: *Dispatcher, root: *Widget, next: ?*Widget) void {
        self.bindTree(root);
        self.setFocused(next);
    }

    pub fn focusNext(self: *Dispatcher, root: *Widget, reverse: bool) bool {
        self.bindTree(root);
        const count = focusableCount(root);
        if (count == 0) return false;
        const current_index = focusableIndex(root, self.focused, 0) orelse if (reverse) count else count - 1;
        const next_index = if (reverse)
            if (current_index == 0) count - 1 else current_index - 1
        else
            (current_index + 1) % count;
        const next = focusableAt(root, next_index, 0).?;
        self.setFocused(next);
        var parent = next.parent;
        while (parent) |p| : (parent = p.parent) {
            if (p.kind == .scroll_container) scroll_widget.ensureVisibleChild(p, next);
        }
        return true;
    }

    fn setFocused(self: *Dispatcher, next: ?*Widget) void {
        if (self.focused == next) return;
        if (self.focused) |old| {
            if (old.kind == .select) {
                select_widget.close(old);
                old.markPaintDirty();
            }
        }
        self.focused = next;
        if (next) |w| if (w.kind == .select) {
            w.markPaintDirty();
        };
        self.caret.noteJump(anim.nowMs());
    }

    pub fn pointerMotion(self: *Dispatcher, root: *Widget, x: f32, y: f32) void {
        self.bindTree(root);
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
        self.setHovered(findInteractive(result.widget));

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
    fn pressInText(self: *Dispatcher, widget: *Widget, x: f32, y: f32) void {
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

    fn setHovered(self: *Dispatcher, next: ?*Widget) void {
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

    pub fn keyEvent(self: *Dispatcher, allocator: Allocator, key: Key, mods: Mods) !KeyOutcome {
        const widget = self.focused orelse return .{};
        if (widget.kind == .select) {
            if (widget.kind.select.disabled) return .{};
            switch (key) {
                .escape, .tab => select_widget.close(widget),
                .enter => if (widget.kind.select.open) {
                    select_widget.commit(widget, widget.kind.select.highlighted);
                } else {
                    select_widget.open(widget);
                },
                .char => |chars| {
                    if (std.mem.eql(u8, chars, " ")) {
                        if (widget.kind.select.open) select_widget.commit(widget, widget.kind.select.highlighted) else select_widget.open(widget);
                    } else if (chars.len > 0) {
                        if (!widget.kind.select.open) select_widget.open(widget);
                        const d = widget.kind.select;
                        for (0..d.labels.len) |offset| {
                            const i = (d.highlighted + 1 + offset) % d.labels.len;
                            if (std.ascii.startsWithIgnoreCase(d.labels[i], chars)) {
                                select_widget.highlight(widget, i);
                                break;
                            }
                        }
                    }
                },
                .up, .down, .home, .end, .page_up, .page_down => {
                    if (!widget.kind.select.open) {
                        select_widget.open(widget);
                        return .{};
                    }
                    const d = widget.kind.select;
                    const next = switch (key) {
                        .up => d.highlighted -| 1,
                        .down => d.highlighted +| 1,
                        .home => 0,
                        .end => d.labels.len -| 1,
                        .page_up => d.highlighted -| select_widget.visibleCount(widget),
                        else => d.highlighted +| select_widget.visibleCount(widget),
                    };
                    select_widget.highlight(widget, next);
                },
                else => {},
            }
            return .{};
        }
        if (widget.kind == .secret_input) {
            const input = widget.kind.secret_input.input;
            self.caret.noteEdit(anim.nowMs());
            switch (key) {
                .char => |utf8| _ = input.insert(utf8),
                .backspace => input.backspace(),
                .delete => input.delete(),
                .left => input.left(),
                .right => input.right(),
                .home => input.cursor = 0,
                .end, .select_all => input.cursor = input.len,
                // Secret values never use the clipboard.
                .copy, .cut, .paste => return .{},
                .enter, .up, .down, .page_up, .page_down, .tab, .escape => return .{},
            }
            widget.markDirty();
            return .{};
        }
        if (std.meta.activeTag(widget.kind) != .text_input) return .{};
        // Before the edit: `insertText` and friends call `on_change`, which is
        // what rebuilds the start menu's tree, and the rebuild must already
        // see the caret held solid.
        const now = anim.nowMs();
        switch (key) {
            // These land somewhere unrelated to where the caret was, so they
            // snap rather than sweeping the width of the field.
            .home, .end, .select_all => self.caret.noteJump(now),
            .char, .paste => self.caret.noteInsert(now),
            .backspace, .delete, .left, .right, .cut => self.caret.noteEdit(now),
            .copy, .enter, .up, .down, .page_up, .page_down, .tab, .escape => {},
        }
        switch (key) {
            .char => |utf8| try text_input_widget.insertText(allocator, widget, utf8),
            .paste => |utf8| try text_input_widget.insertText(allocator, widget, utf8),
            .backspace => try text_input_widget.backspace(allocator, widget),
            .delete => try text_input_widget.deleteForward(allocator, widget),
            .left => text_input_widget.moveCursorLeft(widget, mods.shift),
            .right => text_input_widget.moveCursorRight(widget, mods.shift),
            .home => text_input_widget.moveCursorHome(widget, mods.shift),
            .end => text_input_widget.moveCursorEnd(widget, mods.shift),
            .select_all => text_input_widget.selectAll(widget),
            // Null, not an empty slice: Ctrl+C or Ctrl+X with nothing selected
            // must leave the clipboard alone rather than blanking it, and that
            // is easier to get right here than at every caller.
            .copy => {
                const selected = widget.kind.text_input.selectedText();
                if (selected.len == 0) return .{};
                return .{ .copy = try allocator.dupe(u8, selected) };
            },
            .cut => {
                // Duplicated before the delete, which frees the buffer the
                // selection points into.
                const selected = widget.kind.text_input.selectedText();
                if (selected.len == 0) return .{};
                const owned = try allocator.dupe(u8, selected);
                errdefer allocator.free(owned);
                _ = try text_input_widget.deleteSelection(allocator, widget);
                return .{ .copy = owned };
            },
            .enter, .up, .down, .page_up, .page_down, .tab, .escape => {},
        }
        return .{};
    }
};

fn isTabFocusable(widget: *const Widget) bool {
    return switch (widget.kind) {
        .button => |data| data.state != .disabled,
        .row => |data| data.state != .disabled,
        .toggle => |data| !data.disabled,
        .slider, .segmented, .swatch, .stepper, .text_input, .secret_input => true,
        .checkbox => |data| !data.disabled,
        .select => |data| !data.disabled,
        else => false,
    };
}

fn focusableCount(root: *const Widget) usize {
    var count: usize = @intFromBool(isTabFocusable(root));
    for (root.children) |*child| count += focusableCount(child);
    return count;
}

fn focusableIndex(root: *const Widget, target: ?*Widget, before: usize) ?usize {
    var index = before;
    if (isTabFocusable(root)) {
        if (target == root) return index;
        index += 1;
    }
    for (root.children) |*child| {
        if (focusableIndex(child, target, index)) |found| return found;
        index += focusableCount(child);
    }
    return null;
}

fn focusableAt(root: *Widget, wanted: usize, before: usize) ?*Widget {
    var index = before;
    if (isTabFocusable(root)) {
        if (index == wanted) return root;
        index += 1;
    }
    for (root.children) |*child| {
        const count = focusableCount(child);
        if (wanted >= index and wanted < index + count) return focusableAt(child, wanted, index);
        index += count;
    }
    return null;
}

fn setThumbHover(scroll: *Widget, hover: bool) void {
    switch (scroll.kind) {
        .scroll_container => |*state| {
            if (state.thumb_hover == hover) return;
            state.thumb_hover = hover;
            scroll.markDirty();
        },
        else => {},
    }
}

/// One process-wide dispatcher, matching this codebase's other singletons
/// (text.zig's font slots, theme.zig's `global`) — there is one compositor
/// and one shell per process. Build a private `Dispatcher` instead if a
/// second, independent widget tree ever needs its own hover/focus state.
pub var current: Dispatcher = .{};
/// The dispatcher a panel paint or key dispatch is currently running under.
/// Mutable because the caret's target offset is only known to the paint pass
/// — it is the shaped width of the value's prefix, which nothing above paint
/// measures.
pub var active_dispatcher: ?*Dispatcher = null;

pub fn activeDispatcher() *Dispatcher {
    return active_dispatcher orelse &current;
}

pub fn reset() void {
    current.reset();
}

pub fn pointerMotion(root: *Widget, x: f32, y: f32) void {
    current.pointerMotion(root, x, y);
}
pub fn pointerLeave(root: *Widget) void {
    current.pointerLeave(root);
}
/// After a rebuild that kept `widget`'s hover look: the pointer is still over
/// it, and the dispatcher must know, or it would never clear that look.
pub fn adoptHover(root: *Widget, widget: *Widget) void {
    current.bindTree(root);
    current.hovered = widget;
}
pub fn pointerButtonDown(root: *Widget, x: f32, y: f32) void {
    current.pointerButtonDown(root, x, y);
}
pub fn pointerButtonUp(root: *Widget, x: f32, y: f32) void {
    current.pointerButtonUp(root, x, y);
}
pub fn scrollWheel(root: *Widget, x: f32, y: f32, delta_px: f32, glide_now_ms: ?i64) bool {
    return current.scrollWheel(root, x, y, delta_px, glide_now_ms);
}

fn findScrollContainer(root: *Widget) ?*Widget {
    if (std.meta.activeTag(root.kind) == .scroll_container) return root;
    for (root.children) |*child| {
        if (findScrollContainer(child)) |found| return found;
    }
    return null;
}

pub fn isFocused(widget: *const Widget) bool {
    const focused = activeDispatcher().focused orelse return false;
    return @as(*const Widget, focused) == widget;
}

/// The caret belonging to whichever dispatcher is painting, for `paint.zig`.
pub fn activeCaret() *Caret {
    return &activeDispatcher().caret;
}

pub const Key = union(enum) {
    char: []const u8,
    backspace,
    delete,
    left,
    right,
    home,
    end,
    up,
    down,
    page_up,
    page_down,
    tab,
    escape,
    enter,
    /// Editing intents, not keys. The chord that produces each one is the
    /// shell's business (`start_menu/panel.zig` owns the xkb mapping), and
    /// keeping them as intents means `ui/` never has to know that Ctrl+A on
    /// one layout is not the `a` keysym on another.
    select_all,
    copy,
    cut,
    paste: []const u8,
};

/// Modifier state relevant to text editing. Only shift is here because it is
/// the one modifier that changes what an *existing* key does rather than
/// selecting a different intent — every other chord arrives as a `Key` above.
pub const Mods = struct { shift: bool = false };

/// What a key event asks the shell to do afterwards, beyond mutating the
/// widget. Editing is synchronous but the clipboard is not — a paste has to
/// go out to the seat's current selection source and come back down a pipe —
/// so `keyEvent` reports the intent and lets the caller, which owns the
/// compositor handles, carry it out.
pub const KeyOutcome = struct {
    /// Text the widget wants put on the clipboard. **Owned by the caller**,
    /// allocated from the `allocator` it passed in, and its own even for a
    /// plain copy: a cut has to duplicate the selection anyway (the delete
    /// frees the buffer it points into), and one ownership rule for the field
    /// is worth a redundant allocation on the copy path.
    copy: ?[]u8 = null,
};

/// Routes a key event to the focused widget. The compositor's keyboard
/// handler maps xkb keysyms onto `Key` (a printable keysym -> `.char`,
/// Backspace -> `.backspace`, ...) — no xkbcommon dependency belongs here.
pub fn keyEvent(allocator: Allocator, key: Key, mods: Mods) !KeyOutcome {
    return activeDispatcher().keyEvent(allocator, key, mods);
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
    caret_config = cfg;
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

test "stable pointer motion and clamped scrolling leave visual revision unchanged" {
    var children = [_]Widget{.{ .kind = .{ .button = .{ .label = "Button" } }, .computed_width = 100, .computed_height = 30 }};
    var root: Widget = .{ .kind = .container, .computed_width = 120, .computed_height = 80, .children = &children };
    root.linkParents();
    var dispatcher: Dispatcher = .{};
    dispatcher.pointerMotion(&root, 10, 10);
    var revision = layout.paint_revision;
    dispatcher.pointerMotion(&root, 11, 10);
    try std.testing.expectEqual(revision, layout.paint_revision);
    dispatcher.pointerMotion(&root, 110, 60);
    try std.testing.expect(revision != layout.paint_revision);
    revision = layout.paint_revision;
    dispatcher.pointerMotion(&root, 111, 60);
    try std.testing.expectEqual(revision, layout.paint_revision);
    var scroll: Widget = .{ .kind = .{ .scroll_container = .{ .content_size = 300 } }, .direction = .column, .computed_width = 100, .computed_height = 100 };
    _ = dispatcher.scrollWheel(&scroll, 10, 10, -40, null);
    try std.testing.expectEqual(revision, layout.paint_revision);
    _ = dispatcher.scrollWheel(&scroll, 10, 10, 40, null);
    try std.testing.expect(revision != layout.paint_revision);
}
