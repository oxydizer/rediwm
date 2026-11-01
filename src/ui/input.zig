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
const input_pointer = @import("input_pointer.zig");
const input_keys = @import("input_keys.zig");

/// Walks the tree in reverse paint order (topmost/last-drawn first) and
/// returns the deepest widget whose computed rect contains `(x, y)`.
pub fn hitTest(root: *Widget, x: f32, y: f32) ?*Widget {
    return hitTestWithScrollAncestor(root, x, y).widget;
}

/// Logical-pixel rectangle used to constrain proximity sampling.
pub const ProximityRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

fn widgetRect(widget: *const Widget) ProximityRect {
    return .{
        .x = widget.computed_x,
        .y = widget.computed_y,
        .w = widget.computed_width,
        .h = widget.computed_height,
    };
}

fn intersectProximityRect(a: ProximityRect, b: ProximityRect) ProximityRect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{
        .x = x0,
        .y = y0,
        .w = @max(0, x1 - x0),
        .h = @max(0, y1 - y0),
    };
}

fn proximityDistance(x: f32, y: f32, rect: ProximityRect) f32 {
    if (rect.w <= 0 or rect.h <= 0) return std.math.inf(f32);

    const right = rect.x + rect.w;
    const bottom = rect.y + rect.h;
    const dx = if (x < rect.x) rect.x - x else if (x > right) x - right else 0;
    const dy = if (y < rect.y) rect.y - y else if (y > bottom) y - bottom else 0;
    return @sqrt(dx * dx + dy * dy);
}

/// Updates every button in the retained tree, not merely the hit-tested one.
/// `viewport` is the host panel's visible content rectangle. Scroll containers
/// add their own paint clip as recursion descends. Returns true only when a
/// button's stored sample actually changes.
pub fn updateButtonProximity(
    root: *Widget,
    x: f32,
    y: f32,
    viewport: ProximityRect,
) bool {
    var changed = false;
    const root_clip = intersectProximityRect(viewport, widgetRect(root));
    sampleButtonProximity(root, x, y, root_clip, &changed);
    return changed;
}

fn sampleButtonProximity(
    widget: *Widget,
    x: f32,
    y: f32,
    clip: ProximityRect,
    changed: *bool,
) void {
    switch (widget.kind) {
        .button => |*data| {
            const visible = intersectProximityRect(widgetRect(widget), clip);
            const distance = proximityDistance(x, y, visible);
            const sample_x = if (distance < std.math.inf(f32)) x - widget.computed_x else data.proximity_x;
            const sample_y = if (distance < std.math.inf(f32)) y - widget.computed_y else data.proximity_y;
            if (data.proximity_distance != distance or
                data.proximity_x != sample_x or data.proximity_y != sample_y)
            {
                data.proximity_distance = distance;
                data.proximity_x = sample_x;
                data.proximity_y = sample_y;
                widget.markPaintDirty();
                changed.* = true;
            }
        },
        else => {},
    }

    // paintScrollContainer clips all descendants to its own full rectangle.
    const child_clip = if (widget.kind == .scroll_container)
        intersectProximityRect(clip, widgetRect(widget))
    else
        clip;

    for (widget.children) |*child| {
        sampleButtonProximity(child, x, y, child_clip, changed);
    }
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

pub fn hitTestInner(root: *Widget, x: f32, y: f32, scroll_ancestor: ?*Widget) HitResult {
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

pub fn dragCoord(scroll: *const Widget, x: f32, y: f32) f32 {
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

pub fn isInteractiveButtonOrRow(widget: *const Widget) bool {
    return switch (widget.kind) {
        .button => |data| data.state != .disabled,
        .row => |data| data.state != .disabled,
        else => false,
    };
}

pub fn setButtonOrRowState(widget: *Widget, state: layout.ButtonState) void {
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

pub fn fireRowClick(widget: *Widget) void {
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

const input_caret = @import("input_caret.zig");
pub const CaretConfig = input_caret.CaretConfig;
pub const multi_click_ms = input_caret.multi_click_ms;
pub const multi_click_slop = input_caret.multi_click_slop;
pub const caret_snap_distance = input_caret.caret_snap_distance;
pub const Caret = input_caret.Caret;

/// Process-wide, like `theme.global`, and for the same reason: widgets read
/// it at paint time, so there is nothing to thread through the tree.
pub var caret_config: CaretConfig = .{};

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

    pub fn bindTree(self: *Dispatcher, root: *Widget) void {
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

    pub fn setFocused(self: *Dispatcher, next: ?*Widget) void {
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

    pub const pointerMotion = input_pointer.pointerMotion;
    pub const pointerButtonDown = input_pointer.pointerButtonDown;
    pub const pressInText = input_pointer.pressInText;
    pub const pointerButtonUp = input_pointer.pointerButtonUp;
    pub const scrollWheel = input_pointer.scrollWheel;
    pub const overText = input_pointer.overText;
    pub const setHovered = input_pointer.setHovered;

    pub const keyEvent = input_keys.keyEvent;
};

pub fn isTabFocusable(widget: *const Widget) bool {
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

pub fn focusableCount(root: *const Widget) usize {
    var count: usize = @intFromBool(isTabFocusable(root));
    for (root.children) |*child| count += focusableCount(child);
    return count;
}

pub fn focusableIndex(root: *const Widget, target: ?*Widget, before: usize) ?usize {
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

pub fn focusableAt(root: *Widget, wanted: usize, before: usize) ?*Widget {
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

pub fn setThumbHover(scroll: *Widget, hover: bool) void {
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

pub fn findScrollContainer(root: *Widget) ?*Widget {
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

test {
    _ = @import("input_tests.zig");
}
