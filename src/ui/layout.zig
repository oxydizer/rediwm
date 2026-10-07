// Core data model for the compositor-drawn UI layout engine (shell chrome
// only: taskbar, control panel, file manager, search palette — never a
// client surface). A `Widget` tree is built once by the caller, then driven
// through three passes each frame it is dirty:
//
//   measure.zig  — bottom-up intrinsic sizing
//   arrange.zig  — top-down placement (authoritative computed_* rect)
//   paint.zig    — tree-order draw-call emission
//
// The tree is retained, not rebuilt per frame: callers mutate `kind`'s
// payload (a checkbox's `checked`, a button's `state`, …) in place and call
// `Widget.markDirty` so the next frame re-lays-out only what needs it.
//
// `children` is a slice owned by the parent. Build a tree once (typically
// out of an arena) and call `Widget.linkParents` on the root before the
// first `measure`/`arrange` pass — `parent` pointers point *into* that
// slice, so appending to `children` after linking invalidates them until
// `linkParents` runs again.
const std = @import("std");
const anim = @import("anim.zig");

// Changes to widget visuals, including mutations inside callbacks that rebuild a tree.
pub var paint_revision: u64 = 0;

pub const SizeConstraint = union(enum) {
    fixed: f32,
    percent: f32,
    flex: f32,
    auto,
};

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(v: f32) Edges {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn xy(x: f32, y: f32) Edges {
        return .{ .top = y, .right = x, .bottom = y, .left = x };
    }
};

pub const Direction = enum { row, column };
pub const Align = enum { start, center, end, stretch };
pub const Justify = enum { start, center, end, space_between, space_around };

// Shell glyph identities. Supplied SVGs are embedded and cached as alpha
// masks by shell_icons.zig; remaining glyphs use paint.zig's SDF primitives.
// App icons still use the separate XDG-theme lookup keyed by app_id.
pub const IconId = enum {
    git_branch,
    generic,
    folder,
    document,
    terminal,
    settings,
    keyboard,
    edit,
    browser,
    search,
    chevron_up,
    chevron_down,
    close,
    minimize,
    maximize,
    checkmark,
    /// Speaker + two waves — also used as "high" for the mic level, since
    /// there is no separate low/high distinction for input devices.
    volume,
    volume_low,
    volume_muted,
    mic,
    mic_outline,
    mic_muted,
    brightness,
    caps_lock,
    wifi,
    ethernet,
    globe,
    mouse,
    display,
    music,
    headphones,
    bluetooth,
    battery,
    notification,
    plus,
    grid,
    drag_handle,
    power,
    reboot,
    restart_shell,
    clock,
    logout,
    lock,
    @"suspend",
    /// Gauge whose needle points low, centre and high for the three power
    /// profiles.
    power_saver,
    power_balanced,
    power_performance,
    /// Password reveal toggle: `eye` while the secret is shown, `eye_off`
    /// while it is hidden.
    eye,
    eye_off,
    chevron_left,
    chevron_right,
    /// A capture region: four corner brackets.
    region,
    // Files' toolbar.
    refresh,
    cut,
    copy,
    paste,
    trash,
    /// Filled bin used by the desktop's built-in Trash icon.
    trash_can,
    view_grid,
    view_list,
    sort,
    filter,
    // Images' toolbar.
    zoom_in,
    zoom_out,
    rotate,
    crop,
    undo,
    save,
    fit,
    print,
    home,
    open,
    // Files' devices.
    usb_stick,
    drive,
    eject,
    more,
    users,
    squares,
};

pub const ButtonState = enum { idle, hover, press, disabled };

// Only `.sans` and `.mono` exist as bundled faces (text.zig); `weight` only
// has an effect for `.mono`, which has a real bold face (`mono_bold`).
// Manrope is embedded as a single (variable-font default) instance, so a
// `.sans` run with weight >= 600 still draws at regular weight — there is no
// bold Manrope face bundled to switch to.
pub const TextFamily = enum { sans, mono };

pub const RectStyle = struct {
    color: [4]f32,
    radius: f32 = 0,
    border_width: f32 = 0,
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Padding of a value pill (`TextStyle.pill`) around its text.
pub const pill_pad_x: f32 = 8;
pub const pill_pad_y: f32 = 2;

pub const TextStyle = struct {
    sensitive: bool = false,
    content: []const u8,
    font_size: f32,
    weight: u32 = 400,
    color: [4]f32,
    family: TextFamily = .sans,
    /// A slider's value readout: the text sits centred in a rounded label that
    /// `glow` (0..1, driven by the slider's drag, see `widgets/slider.zig`)
    /// tints toward the accent.
    pill: bool = false,
    glow: f32 = 0,
};

pub const IconStyle = struct {
    id: IconId,
    color: [4]f32,
    stroke_width: ?f32 = null,
};

pub const ImageData = struct {
    pixels: ?[]const u32 = null,
    width: i32 = 0,
    height: i32 = 0,
    radius: f32 = 0,
    fallback_color: ?[4]f32 = null,
    fallback_icon: ?IconId = .generic,
};

pub const RowData = struct {
    /// Optional card styling; ordinary list rows retain their theme styling.
    background: ?RectStyle = null,
    hover_background: ?RectStyle = null,
    press_background: ?RectStyle = null,
    owner: ?*anyopaque = null,
    id: usize = 0,
    on_click: ?*const fn (owner: ?*anyopaque, id: usize) void = null,
    state: ButtonState = .idle,
    selected: bool = false,
    /// The parent's `underlay` draws the selected and hover
    /// fills (so they can glide between rows); the row paints neither.
    underlay: bool = false,
};

/// Look and size come from `widgets/button.zig`, which paints it.
/// Callbacks borrow `owner` until this tree is retired; it must outlive dispatch.
/// They may rebuild widgets after resetting their host's dispatcher. Destruction
/// of the host itself must be deferred until its input entry point returns.
pub const ButtonData = struct {
    variant: @import("widgets/button.zig").Variant = .secondary,
    size: @import("widgets/button.zig").Size = .md,
    label: []const u8 = "",
    /// When set, the button paints this glyph centered instead of `label` —
    /// an icon-only button (the start menu footer's power button) rather
    /// than the usual text pill.
    icon: ?IconId = null,
    icon_scale: f32 = 0.5,
    leading_icon: ?IconId = null,
    trailing_icon: ?IconId = null,
    stacked: bool = false,
    on_click: ?*const fn (owner: ?*anyopaque, id: usize) void = null,
    owner: ?*anyopaque = null,
    id: usize = 0,
    state: ButtonState = .idle,
};

pub const CheckboxData = struct {
    icon: ?ImageData = null,
    label: []const u8,
    checked: bool,
    disabled: bool = false,
    on_change: *const fn (?*anyopaque, usize, bool) void,
    owner: ?*anyopaque = null,
    id: usize = 0,
};

pub const TextInputData = struct {
    owner: ?*anyopaque = null,
    id: usize = 0,
    /// Size, leading icon and trailing accessory (`widgets/field.zig`).
    field: @import("widgets/field.zig").Options = .{},
    placeholder: []const u8,
    value: []u8,
    cursor_pos: usize = 0,
    /// The fixed end of a selection; `cursor_pos` is the moving end, so the
    /// anchor may be either side of it. Null means "no selection, just a
    /// caret" — distinct from an empty selection, because a caret that has
    /// never selected and a caret whose selection you just collapsed behave
    /// the same and there is no reason to tell them apart.
    selection_anchor: ?usize = null,
    on_change: *const fn (?*anyopaque, usize, []const u8) void,

    pub const Range = struct { start: usize, end: usize };

    /// The selected byte range, ordered, or null when nothing is selected.
    /// An anchor equal to the cursor is *not* a selection.
    pub fn selection(data: TextInputData) ?Range {
        const anchor = data.selection_anchor orelse return null;
        const cursor = @min(data.cursor_pos, data.value.len);
        const other = @min(anchor, data.value.len);
        if (anchor == cursor) return null;
        return .{ .start = @min(other, cursor), .end = @max(other, cursor) };
    }

    pub fn selectedText(data: TextInputData) []const u8 {
        const range = data.selection() orelse return &.{};
        return data.value[range.start..range.end];
    }
};

pub const SecretInputData = struct {
    field: @import("widgets/field.zig").Options = .{},
    placeholder: []const u8,
    input: *@import("widgets/secret_input.zig").Input,
    revealed: bool = false,
};

pub const Underlay = struct {
    owner: ?*anyopaque,
    paint: *const fn (owner: ?*anyopaque, scroll: *const Widget, renderer: *@import("paint.zig").Renderer) void,
};

pub const ScrollState = struct {
    /// Nested lists can pass wheel motion to their parent at either end.
    chain_at_edge: bool = false,
    scroll_offset: f32 = 0,
    // Total extent along `direction`'s main axis, computed by measure.zig
    // from the (unclamped) sum of children — the arrange pass clamps
    // `scroll_offset` against it, and paint.zig's scrollbar math reads it.
    content_size: f32 = 0,
    /// The pointer is over the scrollbar's thumb.
    thumb_hover: bool = false,
    /// A thumb drag in progress (`widgets/scrollbar.zig`).
    drag: @import("widgets/scrollbar.zig").Drag = .{},
    /// Hover/scroll feedback of the scrollbar, and the offset it last saw
    /// (`scroll_container.stepBars`).
    bar: @import("widgets/scrollbar.zig").Appearance = .{},
    bar_observed: f32 = 0,
    /// Mouse-wheel glide toward a target offset (`scroll_container.glideBy`).
    /// Idle unless `active()`; every other offset change cancels it.
    glide: anim.Anim = .{},
    /// Painted under the children, inside the container's clip: lets a list
    /// draw one highlight that moves across rows instead of per-row fills.
    underlay: ?Underlay = null,
    /// Speed of the current wheel run, for acceleration.
    wheel: @import("wheel.zig").Rate = .{},
};

/// A pill on/off switch (control center's "Natural scroll" / "Tap to click"
/// rows). Distinct from `.checkbox` so the two can carry unrelated visuals
/// (a pill thumb vs. a checked square) without a `style` flag on one type.
pub const ToggleData = struct {
    owner: ?*anyopaque = null,
    id: usize = 0,
    style: enum { standard, settings } = .standard,
    on: bool,
    disabled: bool = false,
    on_change: *const fn (?*anyopaque, usize, bool) void,
};

/// A horizontal drag slider (control center's pointer-speed row). `value` is
/// caller-owned state the widget reads for painting and `on_change` writes
/// back to on drag — there is no internal value storage, matching every
/// other widget's caller-owns-the-model convention.
pub const SliderData = struct {
    owner: ?*anyopaque = null,
    id: usize = 0,
    style: enum { standard, settings } = .standard,
    value: f32,
    min: f32,
    max: f32,
    step: f32 = 0,
    dragging: bool = false,
    /// The pointer is over the slider (`ui/input.zig` keeps it in step).
    hovered: bool = false,
    /// The scrollbar's feedback, reused: hover and drag tint and thicken the
    /// track, a change holds a faint tint for a moment (`widgets/slider.zig`).
    feel: @import("widgets/scrollbar.zig").Appearance = .{},
    /// 1 while dragging: eased into the value pill's highlight.
    glow: anim.Anim = .{},
    /// The `glow` last handed to the pill, so an unchanged one costs no search.
    glow_shown: f32 = 0,
    /// The value `stepBars` last saw; NaN until its first look, so a freshly
    /// built slider doesn't read as changed.
    observed: f32 = std.math.nan(f32),
    on_change: *const fn (?*anyopaque, usize, f32) void,
};

/// An N-way exclusive choice rendered as equal-width segments in one row
/// (control center's font-size/radius pickers). `widgets/segmented.zig`'s
/// `selectAt` updates `selected` in place (matching `.checkbox`'s own
/// toggle-then-notify convention) before calling `on_change` with the newly
/// selected index.
pub const SegmentedData = struct {
    owner: ?*anyopaque = null,
    id: usize = 0,
    labels: []const []const u8,
    /// An index outside `labels` leaves custom values without a preset.
    selected: usize,
    on_change: *const fn (?*anyopaque, usize, usize) void,
};

/// A small selectable color chip (control center's accent-color row). One
/// `on_select` function is shared by every swatch in a row — it receives
/// `color` (this swatch's own) rather than needing per-instance identity,
/// together with its owner and ID.
pub const SwatchData = struct {
    owner: ?*anyopaque = null,
    id: usize = 0,
    color: [4]f32,
    selected: bool,
    on_select: *const fn (?*anyopaque, usize, [4]f32) void,
};

/// A "− value +" numeric input (control center's key-repeat rows). `unit` is
/// appended to the formatted value (e.g. "400 ms"); pass "" for none.
pub const StepperData = struct {
    owner: ?*anyopaque = null,
    id: usize = 0,
    value: f32,
    min: f32,
    max: f32,
    step: f32,
    unit: []const u8 = "",
    on_change: *const fn (?*anyopaque, usize, f32) void,
};

/// Borrowed labels; keep them alive until the tree is destroyed. Callbacks may
/// rebuild the tree. Popup state is transient and resets with the widget.
pub const SelectData = struct {
    /// Explicitly selecting the current choice reapplies its external state.
    notify_on_reselect: bool = false,
    owner: ?*anyopaque = null,
    id: usize = 0,
    /// Visible placeholders that cannot be committed.
    disabled_options: []const usize = &.{},
    labels: []const []const u8,
    selected: ?usize = null,
    placeholder: []const u8 = "Select an option",
    disabled: bool = false,
    on_change: ?*const fn (?*anyopaque, usize, usize) void = null,
    open: bool = false,
    highlighted: usize = 0,
    first_visible: usize = 0,
};

/// One screen in an `.arrangement`, as a box in layout coordinates.
pub const ArrangementItem = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    label: []const u8,
    /// Smaller second line (resolution or model); omitted when it can't fit.
    detail: []const u8 = "",
    /// Drawn with a bar along its top edge, like a menu bar.
    primary: bool = false,
};

/// Screens drawn to scale that the user drags into place (Settings →
/// Displays). The caller owns `items`: a drag writes the dragged item's
/// snapped position into it and a click or drop writes `selected`. Callers
/// compare both with what they built after dispatch, like a select's
/// `selected`. See `widgets/arrangement.zig`.
pub const ArrangementData = struct {
    items: []ArrangementItem,
    selected: ?usize = null,
    /// Transient; resets with the widget.
    drag: ?@import("widgets/arrangement.zig").Drag = null,
};

pub const WidgetKind = union(enum) {
    rect: RectStyle,
    text: TextStyle,
    icon: IconStyle,
    image: ImageData,
    avatar,
    battery: @import("widgets/battery.zig").Spec,
    row: RowData,
    button: ButtonData,
    checkbox: CheckboxData,
    text_input: TextInputData,
    secret_input: SecretInputData,
    scroll_container: ScrollState,
    toggle: ToggleData,
    slider: SliderData,
    segmented: SegmentedData,
    select: SelectData,
    swatch: SwatchData,
    stepper: StepperData,
    arrangement: ArrangementData,
    container,
};

pub const Widget = struct {
    // --- Layout inputs (set by caller) ---
    width: SizeConstraint = .auto,
    height: SizeConstraint = .auto,
    min_width: ?f32 = null,
    max_width: ?f32 = null,
    min_height: ?f32 = null,
    max_height: ?f32 = null,
    padding: Edges = Edges.all(0),
    margin: Edges = Edges.all(0),
    gap: f32 = 0,
    direction: Direction = .row,
    // `align` is a Zig keyword, hence the `@""` escape; every access below
    // needs the same escape (`widget.@"align"`).
    @"align": Align = .start,
    justify: Justify = .start,

    // --- Computed by layout passes (do not set manually) ---
    computed_x: f32 = 0,
    computed_y: f32 = 0,
    computed_width: f32 = 0,
    computed_height: f32 = 0,

    // --- Widget identity ---
    name: ?[]const u8 = null,
    kind: WidgetKind,
    children: []Widget = &.{},
    /// Optional artwork above this widget's background and below its children.
    underlay: ?Underlay = null,

    // --- Dirty flag ---
    needs_layout: bool = true,
    needs_paint: bool = true,
    painted_bounds: ?PaintBounds = null,

    // --- Tree bookkeeping (internal; filled in by `linkParents`) ---
    parent: ?*Widget = null,

    pub const PaintBounds = struct { x: f32, y: f32, w: f32, h: f32 };

    pub fn paintBounds(widget: *const Widget) PaintBounds {
        if (widget.kind == .select and widget.kind.select.open) {
            const popup = @import("widgets/select.zig").popupBounds(widget);
            const x = @min(widget.computed_x, popup.x);
            const y = @min(widget.computed_y, popup.y);
            return .{ .x = x, .y = y, .w = @max(widget.computed_x + widget.computed_width, popup.x + popup.w) - x, .h = @max(widget.computed_y + widget.computed_height, popup.y + popup.h) - y };
        }
        return .{ .x = widget.computed_x, .y = widget.computed_y, .w = widget.computed_width, .h = widget.computed_height };
    }

    /// Walks the tree once, pointing every child's `parent` back at this
    /// node. Call after building (or restructuring) a tree, before the
    /// first `measure`/`arrange` pass or any `markDirty`.
    pub fn linkParents(widget: *Widget) void {
        for (widget.children) |*child| {
            child.parent = widget;
            child.linkParents();
        }
    }

    /// Marks this widget and every ancestor up to the root dirty. Cheap and
    /// idempotent — safe to call from any property setter.
    pub fn markDirty(widget: *Widget) void {
        widget.markPaintDirty();
        var current: ?*Widget = widget;
        while (current) |w| {
            w.needs_layout = true;
            current = w.parent;
        }
    }

    pub fn markPaintDirty(widget: *Widget) void {
        widget.needs_paint = true;
        paint_revision +%= 1;
    }

    pub fn clearPaintDirty(widget: *Widget) void {
        widget.needs_paint = false;
        widget.painted_bounds = widget.paintBounds();
        for (widget.children) |*child| child.clearPaintDirty();
    }

    pub fn contains(widget: *const Widget, x: f32, y: f32) bool {
        return x >= widget.computed_x and x < widget.computed_x + widget.computed_width and
            y >= widget.computed_y and y < widget.computed_y + widget.computed_height;
    }

    // --- Axis-generic accessors shared by measure.zig and arrange.zig ---

    pub fn axisConstraint(widget: *const Widget, dir: Direction) SizeConstraint {
        return if (dir == .row) widget.width else widget.height;
    }

    pub fn axisMeasured(widget: *const Widget, dir: Direction) f32 {
        return if (dir == .row) widget.computed_width else widget.computed_height;
    }

    pub fn setAxisMeasured(widget: *Widget, dir: Direction, value: f32) void {
        if (dir == .row) widget.computed_width = value else widget.computed_height = value;
    }

    pub fn crossOf(dir: Direction) Direction {
        return if (dir == .row) .column else .row;
    }

    /// Debug dump of computed rects in tree order (acceptance criterion:
    /// "a test widget tree ... lays out correctly when printed with a debug
    /// dump"). Call after `measure` + `arrange`. Caller owns the result.
    pub fn dump(widget: *const Widget, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try widget.dumpInto(allocator, &buf, 0);
        return buf.toOwnedSlice(allocator);
    }

    fn dumpInto(widget: *const Widget, allocator: std.mem.Allocator, buf: *std.ArrayList(u8), depth: usize) !void {
        for (0..depth) |_| try buf.appendSlice(allocator, "  ");
        var line_buf: [160]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{s} [{d:.0},{d:.0} {d:.0}x{d:.0}]\n", .{
            @tagName(widget.kind),
            widget.computed_x,
            widget.computed_y,
            widget.computed_width,
            widget.computed_height,
        });
        try buf.appendSlice(allocator, line);
        for (widget.children) |*child| try child.dumpInto(allocator, buf, depth + 1);
    }
};

/// Appends `widget` to a fixed-size row/content buffer (control center's
/// `Section.row_storage`, `ControlCenter.content_children`, and similar):
/// `storage[count.*] = widget; count.* += 1`, but bounds-checked. These
/// buffers are sized by hand to match a section's own row count, and the
/// two numbers can drift when a row is added without bumping its consumer's
/// buffer (see the 2026-09-15 control-center crash: an added Input row
/// overflowed `ControlCenter.content_children`, an out-of-bounds write that
/// panicked the whole compositor). Dropping the overflow row and logging
/// instead turns that class of mismatch into a visibly incomplete panel,
/// not a crash — bump the buffer's size when the log warning shows up.
pub fn appendRow(storage: []Widget, count: *usize, widget: Widget) void {
    if (count.* >= storage.len) {
        std.log.warn("ui: widget row buffer full ({d}); dropping a row — bump the fixed array size", .{storage.len});
        return;
    }
    storage[count.*] = widget;
    count.* += 1;
}

test "Edges.all and xy" {
    const a = Edges.all(4);
    try std.testing.expectEqual(@as(f32, 4), a.top);
    try std.testing.expectEqual(@as(f32, 4), a.left);

    const xy = Edges.xy(2, 3);
    try std.testing.expectEqual(@as(f32, 3), xy.top);
    try std.testing.expectEqual(@as(f32, 3), xy.bottom);
    try std.testing.expectEqual(@as(f32, 2), xy.left);
    try std.testing.expectEqual(@as(f32, 2), xy.right);
}

test "appendRow drops the overflow row instead of indexing out of bounds" {
    var storage: [2]Widget = undefined;
    var count: usize = 0;
    appendRow(&storage, &count, .{ .kind = .container });
    appendRow(&storage, &count, .{ .kind = .container });
    try std.testing.expectEqual(@as(usize, 2), count);
    // A third row would have overflowed `storage` (this is exactly the shape
    // of the 2026-09-15 crash: a row buffer whose size fell out of sync with
    // its section's row count) — appendRow drops it and leaves count alone.
    appendRow(&storage, &count, .{ .kind = .container });
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "markDirty bubbles to root" {
    var kids = [_]Widget{.{ .kind = .container }};
    var root = Widget{ .kind = .container, .children = &kids };
    root.linkParents();
    root.children[0].needs_layout = false;
    root.needs_layout = false;
    root.children[0].markDirty();
    try std.testing.expect(root.needs_layout);
    try std.testing.expect(root.children[0].needs_layout);
}
