//! The text caret: blink timing, multi-click selection and snapping.

const std = @import("std");
const anim = @import("anim.zig");
const text_mod = @import("text.zig");
const input = @import("input.zig");

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
    /// Glide duration when the caret moves. 0 snaps. The editor's lines glide
    /// 1.5 times as long when an edit moves them (`editor/reflow.zig`).
    motion_ms: u32 = 80,
};

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
        const motion_ms: i64 = @intCast(input.caret_config.motion_ms);
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
        if (input.caret_config.blink_ms == 0) return true;
        if (self.moving(now_ms)) return true;
        const elapsed = now_ms - self.last_edit_ms;
        if (elapsed < 0) return true;
        if (self.blinkExpired(now_ms)) return true;
        const half: i64 = @intCast(input.caret_config.blink_ms / 2);
        if (half <= 0) return true;
        return @rem(@divFloor(elapsed, half), 2) == 0;
    }

    /// Whether blinking has timed out and the caret has gone permanently
    /// solid. This — not the blink itself — is what stops the frame pump.
    pub fn blinkExpired(self: Caret, now_ms: i64) bool {
        if (input.caret_config.blink_timeout_s == 0) return false;
        const timeout_ms: i64 = @as(i64, input.caret_config.blink_timeout_s) * 1000;
        return now_ms - self.last_edit_ms >= timeout_ms;
    }

    /// Whether the caret still needs frames: mid-glide, or blinking within
    /// the timeout window.
    pub fn animating(self: Caret, now_ms: i64) bool {
        if (self.moving(now_ms)) return true;
        return input.caret_config.blink_ms != 0 and !self.blinkExpired(now_ms);
    }
};
