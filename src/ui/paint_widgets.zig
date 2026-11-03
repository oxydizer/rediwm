//! UI widget painters: rows, buttons, fields, sliders, pills and containers.

const std = @import("std");
const layout = @import("layout.zig");
const Widget = layout.Widget;
const TextStyle = layout.TextStyle;
const ButtonData = layout.ButtonData;
const CheckboxData = layout.CheckboxData;
const TextInputData = layout.TextInputData;
const ScrollState = layout.ScrollState;
const ToggleData = layout.ToggleData;
const SliderData = layout.SliderData;
const SegmentedData = layout.SegmentedData;
const SwatchData = layout.SwatchData;
const StepperData = layout.StepperData;
const RowData = layout.RowData;
const anim = @import("paint.zig").anim;
const text_mod = @import("paint.zig").text_mod;
const theme = @import("paint.zig").theme;
const ui_input = @import("paint.zig").ui_input;
const field_widget = @import("paint.zig").field_widget;
const button_widget = @import("paint.zig").button_widget;
const checkbox_widget = @import("paint.zig").checkbox_widget;
const scrollbar = @import("paint.zig").scrollbar;
const ClipRect = @import("paint.zig").ClipRect;
const Renderer = @import("paint.zig").Renderer;
const lerp4 = @import("paint.zig").lerp4;
const paintTree = @import("paint.zig").paintTree;

pub fn paintRow(widget: *const Widget, data: RowData, renderer: *Renderer) void {
    if (data.underlay) return;
    const t = renderer.palette orelse theme.global;
    if (data.background) |base| {
        const style = if (data.selected) data.hover_background orelse base else switch (data.state) {
            .hover => data.hover_background orelse base,
            .press => data.press_background orelse data.hover_background orelse base,
            else => base,
        };
        renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, style);
        return;
    }
    if (data.selected) {
        renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, .{
            .color = t.start_menu_selected_bg,
            .radius = t.radius,
            .border_width = 1,
            .border_color = t.start_menu_selected_border,
            .relief = t.row_selected_relief,
        });
        const marker_h = @max(10, widget.computed_height - 18);
        const marker_y = widget.computed_y + (widget.computed_height - marker_h) / 2;
        renderer.fillRect(widget.computed_x + 3, marker_y, 3, marker_h, .{
            .color = t.start_menu_selected_marker,
            .radius = 1.5,
        });
    } else if (data.state == .hover or data.state == .press) {
        renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, .{
            .color = t.surface_hover,
            .radius = t.radius,
            .border_width = 1,
            .border_color = t.border_soft,
            .relief = t.row_hover_relief,
        });
    }
}

pub fn paintButton(widget: *const Widget, data: ButtonData, renderer: *Renderer) void {
    button_widget.paint(renderer, .{
        .x = widget.computed_x,
        .y = widget.computed_y,
        .w = widget.computed_width,
        .h = widget.computed_height,
    }, button_widget.optionsOf(data), .{
        .pointer = data.state,
        .focused = ui_input.isFocused(widget),
        .proximity_distance = data.proximity_distance,
        .proximity_x = data.proximity_x,
        .proximity_y = data.proximity_y,
        .hover_elevation = data.hover_elevation.value(@import("anim.zig").nowMs()),
    });
}

fn paintProximitySample(widget: *const Widget, renderer: *Renderer) void {
    const disabled = switch (widget.kind) {
        .button => |data| data.state == .disabled,
        .row => |data| data.state == .disabled,
        .checkbox => |data| data.disabled,
        .toggle => |data| data.disabled,
        .select => |data| data.disabled,
        else => false,
    };
    if (disabled) return;

    const sample = widget.proximity;
    if (sample.distance >= std.math.inf(f32)) return;

    const box: button_widget.Rect = .{
        .x = sample.rect.x,
        .y = sample.rect.y,
        .w = sample.rect.w,
        .h = sample.rect.h,
    };
    const t = renderer.palette orelse theme.global;
    const radius: f32 = switch (widget.kind) {
        .row => |data| if (data.background) |style| style.radius else t.radius,
        .checkbox => t.checkbox_radius,
        .text_input => |data| field_widget.metrics(data.field.size, t).radius,
        .secret_input => |data| field_widget.metrics(data.field.size, t).radius,
        .toggle => |data| if (data.style == .settings) t.toggle_radius else box.h / 2,
        .slider => box.h / 2,
        .select, .segmented, .stepper, .arrangement => t.radius,
        .swatch => t.swatch_radius,
        else => return,
    };

    button_widget.paintProximityGlowAt(
        renderer, box, radius, sample.distance, sample.x, sample.y,
    );
}

/// Paints proximity illumination during the normal tree pass. A dropdown
/// popup sample is deferred to the overlay pass below.
pub fn paintInteractiveProximity(widget: *const Widget, renderer: *Renderer) void {
    if (widget.kind == .select and widget.kind.select.open) {
        const popup = @import("widgets/select.zig").popupBounds(widget);
        const sample = widget.proximity.rect;
        if (sample.x == popup.x and sample.y == popup.y and
            sample.w == popup.w and sample.h == popup.h) return;
    }
    paintProximitySample(widget, renderer);
}

fn paintSelectPopupProximity(widget: *const Widget, renderer: *Renderer) void {
    if (!(widget.kind == .select and widget.kind.select.open)) return;
    const popup = @import("widgets/select.zig").popupBounds(widget);
    const sample = widget.proximity.rect;
    if (sample.x != popup.x or sample.y != popup.y or
        sample.w != popup.w or sample.h != popup.h) return;
    paintProximitySample(widget, renderer);
}

pub fn paintCheckbox(widget: *const Widget, data: CheckboxData, renderer: *Renderer) void {
    checkbox_widget.paint(renderer, .{
        .x = widget.computed_x,
        .y = widget.computed_y,
        .w = widget.computed_width,
        .h = widget.computed_height,
    }, data.label, .{ .icon = data.icon, .checked = data.checked, .disabled = data.disabled, .focused = ui_input.isFocused(widget) });
}

pub fn paintTextInput(widget: *const Widget, data: TextInputData, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    const focused = ui_input.isFocused(widget);
    const frame = field_widget.paintFrame(renderer, .{
        .x = widget.computed_x,
        .y = widget.computed_y,
        .w = widget.computed_width,
        .h = widget.computed_height,
    }, data.field, .{ .focused = focused });

    const inner_x = frame.text.x;
    const inner_w = frame.text.w;
    const font_size = frame.font_size;
    const shown = if (data.value.len > 0) data.value else data.placeholder;

    // Measure at the renderer's scale, not at 1.0: hinting quantizes advances
    // per ppem, so a prefix measured at 1x is not where the same prefix's pen
    // lands when drawn at 1.5x, and the caret drifts off the text.
    const scale = renderer.scale;
    const caret_pen = if (focused)
        text_mod.measureWidthF(data.value[0..@min(data.value.len, data.cursor_pos)], .manrope, font_size, scale) catch 0
    else
        0;

    // Scroll to caret. Without this an overlong value ellipsizes while the
    // caret keeps its unclipped position, i.e. draws outside the field.
    const caret = ui_input.activeCaret();
    const scroll_before = caret.scroll;
    const scroll_x = if (focused and data.value.len > 0)
        caret.scrollTo(caret_pen, inner_w, text_mod.measureWidthF(data.value, .manrope, font_size, scale) catch 0)
    else
        0;

    const text_style = TextStyle{
        .content = shown,
        .font_size = font_size,
        .color = if (data.value.len > 0) t.fg else t.faint,
    };
    const field_clip = intersectClip(
        renderer.clip,
        .{ .x = inner_x, .y = widget.computed_y, .w = inner_w, .h = widget.computed_height },
    );

    if (!focused) {
        // An unfocused field has no caret to keep in view, so it keeps the
        // ellipsis rather than an arbitrary scroll position.
        renderer.drawText(inner_x, widget.computed_y, inner_w, widget.computed_height, text_style);
        return;
    }

    // Span the face's own ascender..descender rather than a multiple of the
    // font size: `text.draw` centers that same ink box, so this is the only
    // extent that lines the caret and the selection up with the glyphs for any
    // face.
    const metrics = text_mod.verticalMetrics(.manrope, font_size, scale) catch
        text_mod.VMetrics{ .ascent = font_size * 0.8, .descent = font_size * 0.2 };
    const ink_h = metrics.ascent + metrics.descent;
    const ink_y = widget.computed_y + (widget.computed_height - ink_h) / 2;

    const now = anim.nowMs();
    // Scrolling moves the text immediately, so the caret must follow it.
    if (scroll_x != scroll_before) caret.snap = true;
    caret.track(now, caret_pen);
    const caret_x = inner_x + caret.offset(now) - scroll_x;

    // Selection highlight, under the text.
    const selection: ?ClipRect = if (data.selection()) |range| blk: {
        const start = text_mod.measureWidthF(data.value[0..range.start], .manrope, font_size, scale) catch 0;
        const end = text_mod.measureWidthF(data.value[0..range.end], .manrope, font_size, scale) catch 0;
        break :blk .{ .x = inner_x + start - scroll_x, .y = ink_y, .w = end - start, .h = ink_h };
    } else null;
    if (selection) |rect| {
        const prev = renderer.clip;
        renderer.clip = field_clip;
        renderer.fillRect(rect.x, rect.y, rect.w, rect.h, .{ .color = t.selectionColor() });
        renderer.clip = prev;
    }

    var run = Renderer.ScrolledText{
        .x = inner_x,
        .y = widget.computed_y,
        .w = inner_w,
        .h = widget.computed_height,
        .scroll_x = scroll_x,
        .style = text_style,
    };
    if (caret.revealing and caret.offset(now) < caret_pen) {
        // Keep the full shaped run in place and uncover it behind the caret.
        // Round inward: the text clip uses whole logical pixels, and rounding
        // out could expose ink ahead of the caret at fractional positions.
        const left = @floor(inner_x);
        run.clip = .{ .x = left, .y = widget.computed_y, .w = @max(0, @floor(caret_x) - left), .h = widget.computed_height };
        renderer.drawTextScrolled(run);
        // Inserting in the middle must not hide the existing suffix.
        if (data.cursor_pos < data.value.len) {
            const right = @ceil(inner_x + caret_pen - scroll_x);
            run.clip = .{ .x = right, .y = widget.computed_y, .w = @max(0, inner_x + inner_w - right), .h = widget.computed_height };
            renderer.drawTextScrolled(run);
        }
    } else {
        renderer.drawTextScrolled(run);
    }

    // Selected text in its own colour, if the theme asks for one: the same run
    // again, clipped to the highlight, so nothing is reshaped or re-measured
    // and the two passes cannot disagree about where a glyph sits.
    if (t.selection_fg) |selected_color| {
        if (selection) |rect| renderer.drawTextScrolled(.{
            .x = inner_x,
            .y = widget.computed_y,
            .w = inner_w,
            .h = widget.computed_height,
            .scroll_x = scroll_x,
            .clip = rect,
            .style = .{ .content = shown, .font_size = font_size, .color = selected_color },
        });
    }

    // Record what pointer hit testing will need: it has no palette and no
    // renderer, so this is the only place the two can agree on where the text
    // actually starts and at what size it was shaped.
    caret.field = .{ .text_x = inner_x, .font_size = font_size, .scale = scale };

    if (!caret.visible(now)) return;
    const caret_y = ink_y + caret.y.value(now);
    // Clipped like the text: a caret at the far end of a scrolled value must
    // not paint over the field's padding or its border.
    const prev_clip = renderer.clip;
    renderer.clip = field_clip;
    renderer.fillRect(caret_x, caret_y, t.caret_width, ink_h, .{ .color = t.caretColor() });
    renderer.clip = prev_clip;
}

pub fn paintToggle(widget: *const Widget, data: ToggleData, renderer: *Renderer) void {
    @import("widgets/toggle.zig").paint(renderer, .{
        .x = widget.computed_x,
        .y = widget.computed_y,
        .w = widget.computed_width,
        .h = widget.computed_height,
    }, .{
        .on = data.on,
        .position = if (std.math.isNan(data.shown)) null else data.shown,
        .style = data.style,
        .disabled = data.disabled,
        .focused = ui_input.isFocused(widget),
    });
}

/// Shared slider styling and feedback, using the surface's theme palette.
pub fn paintSlider(widget: *const Widget, data: SliderData, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    if (t.slider_shaded) return @import("widgets/slider.zig").paintShaded(widget, data, renderer);
    const w = widget.computed_width;
    const cy = widget.computed_y + widget.computed_height / 2;
    const settings = data.style == .settings;
    const track_h = (if (settings) t.slider_settings_track_height else t.slider_track_height) * (1 + t.slider_track_grow * data.feel.wide);
    const thumb_w: f32 = t.slider_thumb_size;
    const thumb_h: f32 = if (settings) t.slider_settings_thumb_height else t.slider_thumb_size;
    const track_y = cy - track_h / 2;

    // The scrollbar's feedback: `accent` is 1 under the pointer or a drag and a
    // faint hold after a change (`widgets/slider.zig`).
    const tint = data.feel.accent;
    const track_color = lerp4(t.slider_track, .{ t.accent[0], t.accent[1], t.accent[2], t.slider_track_tint_alpha * t.accent[3] }, tint);
    renderer.fillRect(widget.computed_x, track_y, w, track_h, .{ .relief = t.slider_track_relief, .color = track_color, .radius = track_h / 2 });

    const frac = if (data.max > data.min) std.math.clamp((data.value - data.min) / (data.max - data.min), 0, 1) else 0;
    const fill_w = frac * w;
    const fill_rest: f32 = if (settings) 1 else t.slider_fill_alpha;
    const fill_color: [4]f32 = .{ t.accent[0], t.accent[1], t.accent[2], t.accent[3] * (fill_rest + (1 - fill_rest) * tint) };
    if (fill_w > 0) renderer.fillRect(widget.computed_x, track_y, fill_w, track_h, .{ .color = fill_color, .radius = track_h / 2 });

    const thumb_x = widget.computed_x + fill_w - thumb_w / 2;
    renderer.fillRect(thumb_x, cy - thumb_h / 2, thumb_w, thumb_h, .{ .relief = t.slider_thumb_relief, .color = t.control_thumb, .radius = if (settings) t.slider_thumb_radius else t.slider_thumb_size / 2 });
}

/// A slider's value readout: the text centred in a rounded label that fades
/// toward the accent while the slider is dragged (`style.glow`).
pub fn paintPill(widget: *const Widget, style: TextStyle, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    const x = widget.computed_x;
    const y = widget.computed_y;
    const w = widget.computed_width;
    const h = widget.computed_height;
    // An unavailable slider's readout is empty: no label at all.
    if (w <= 0 or h <= 0 or style.content.len == 0) return;
    const glow = std.math.clamp(style.glow, 0, 1);
    const wash = lerp4(t.pill_bg, .{ t.accent[0], t.accent[1], t.accent[2], t.pill_active_alpha * t.accent[3] }, glow);
    renderer.fillRect(x, y, w, h, .{
        .color = wash,
        .radius = h / 2,
        .relief = t.pill_relief,
        .border_width = 1,
        .border_color = lerp4(t.border, .{ t.accent[0], t.accent[1], t.accent[2], t.pill_border_active_alpha * t.accent[3] }, glow),
    });
    var text = style;
    text.color = lerp4(style.color, t.fg, glow);
    const text_x = centeredTextX(x, w, style.content, style.font_size);
    renderer.drawText(text_x, y, @max(0, x + w - text_x), h, text);
}

pub fn centeredTextX(cell_x: f32, cell_w: f32, label: []const u8, font_size: f32) f32 {
    return cell_x + @max(0, (cell_w - labelWidth(label, font_size)) / 2);
}

/// Width of a one-line label as `centeredTextX` measures it.
pub fn labelWidth(label: []const u8, font_size: f32) f32 {
    return @floatFromInt(text_mod.measureWidth(label, .manrope, font_size, 1.0) catch 0);
}

pub fn paintSegmented(widget: *const Widget, data: SegmentedData, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, .{
        .color = t.surface,
        .radius = t.radius,
        .border_width = 1,
        .border_color = t.border,
        .relief = t.segmented_relief,
    });
    if (data.labels.len == 0) return;
    const cell_w = widget.computed_width / @as(f32, @floatFromInt(data.labels.len));
    for (data.labels, 0..) |label, i| {
        const cell_x = widget.computed_x + cell_w * @as(f32, @floatFromInt(i));
        const selected = i == data.selected;
        if (selected) {
            const accent_wash: [4]f32 = .{ t.accent[0], t.accent[1], t.accent[2], t.segmented_selected_alpha * t.accent[3] };
            renderer.fillRect(cell_x + 2, widget.computed_y + 2, cell_w - 4, widget.computed_height - 4, .{
                .color = accent_wash,
                .radius = @max(0, t.radius - 2),
                .relief = t.segmented_selected_relief,
                .border_width = 1,
                .border_color = t.accent,
            });
        }
        renderer.drawText(centeredTextX(cell_x, cell_w, label, t.font_size), widget.computed_y, cell_w, widget.computed_height, .{
            .content = label,
            .font_size = t.font_size,
            .weight = 600,
            .color = if (selected) t.fg else t.dim,
        });
    }
}

pub fn paintSwatch(widget: *const Widget, data: SwatchData, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    const border_width: f32 = if (data.selected) 2 else 1;
    const border_color: [4]f32 = if (data.selected) t.swatch_border_selected else t.swatch_border;
    renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, .{
        .color = data.color,
        .radius = t.swatch_radius,
        .relief = t.swatch_relief,
        .border_width = border_width,
        .border_color = border_color,
    });
    if (data.selected) {
        // A 2px inset glow in the swatch's own color, approximated as an
        // inset ring rather than an actual blurred glow (no blur primitive
        // in this CPU rasterizer).
        const glow: [4]f32 = .{ data.color[0], data.color[1], data.color[2], t.swatch_glow_alpha * data.color[3] };
        renderer.fillRect(widget.computed_x + 3, widget.computed_y + 3, widget.computed_width - 6, widget.computed_height - 6, .{
            .color = .{ 0, 0, 0, 0 },
            .radius = 4,
            .border_width = 1,
            .border_color = glow,
        });
    }
}

pub const stepper_button_width: f32 = 28;

pub fn paintStepper(widget: *const Widget, data: StepperData, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, .{
        .color = t.surface,
        .radius = t.radius,
        .border_width = 1,
        .border_color = t.border,
        .relief = t.stepper_relief,
    });
    renderer.drawIcon(widget.computed_x, widget.computed_y, stepper_button_width, widget.computed_height, .{ .id = .minimize, .color = t.fg });
    renderer.drawIcon(widget.computed_x + widget.computed_width - stepper_button_width, widget.computed_y, stepper_button_width, widget.computed_height, .{ .id = .plus, .color = t.fg });

    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{d} {s}", .{ @as(i32, @intFromFloat(@round(data.value))), data.unit }) catch "";
    const mid_x = widget.computed_x + stepper_button_width;
    const mid_w = @max(0, widget.computed_width - 2 * stepper_button_width);
    renderer.drawText(centeredTextX(mid_x, mid_w, label, t.font_size), widget.computed_y, mid_w, widget.computed_height, .{
        .content = label,
        .font_size = t.font_size,
        .weight = 600,
        .color = t.fg,
    });
}

fn paintScrollbarGrooveProximity(
    widget: *const Widget,
    look: scrollbar.Look,
    renderer: *Renderer,
) void {
    const sample = widget.proximity;
    if (look.track_relief == .flat or sample.distance >= std.math.inf(f32)) return;

    // Only paint a sample that still belongs to this groove's geometry.
    if (sample.rect.x != look.track.x or sample.rect.y != look.track.y or
        sample.rect.w != look.track.w or sample.rect.h != look.track.h) return;

    button_widget.paintProximityGlowAt(
        renderer,
        .{
            .x = look.track.x,
            .y = look.track.y,
            .w = look.track.w,
            .h = look.track.h,
        },
        look.track_radius,
        sample.distance,
        sample.x,
        sample.y,
    );
}

pub fn paintScrollContainer(widget: *const Widget, state: ScrollState, renderer: *Renderer) void {
    const prev_clip = renderer.clip;
    renderer.clip = intersectClip(prev_clip, .{ .x = widget.computed_x, .y = widget.computed_y, .w = widget.computed_width, .h = widget.computed_height });
    if (state.underlay) |under| under.paint(under.owner, widget, renderer);
    const sideways = widget.direction == .row;
    for (widget.children) |*child| {
        const outside = if (sideways)
            child.computed_x + child.computed_width < widget.computed_x or child.computed_x > widget.computed_x + widget.computed_width
        else
            child.computed_y + child.computed_height < widget.computed_y or child.computed_y > widget.computed_y + widget.computed_height;
        if (outside) continue;
        paintTree(child, renderer);
    }
    renderer.clip = prev_clip;

    const g = @import("widgets/scroll_container.zig").geometry(widget) orelse return;
    const t = renderer.palette orelse theme.global;
    const look = scrollbar.look(g, state.bar, theme.global.scrollbar_width, t);
    scrollbar.paintTrack(renderer, look);
    paintScrollbarGrooveProximity(widget, look, renderer);
    scrollbar.paintThumb(renderer, look);
}

pub fn intersectClip(a: ?ClipRect, b: ClipRect) ClipRect {
    const base = a orelse return b;
    const x0 = @max(base.x, b.x);
    const y0 = @max(base.y, b.y);
    const x1 = @min(base.x + base.w, b.x + b.w);
    const y1 = @min(base.y + base.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

pub fn paintSelect(widget: *const Widget, data: layout.SelectData, r: *Renderer) void {
    const t = r.palette orelse theme.global;
    const hovered = ui_input.activeDispatcher().hovered == widget;
    const focused = ui_input.isFocused(widget) and !data.disabled;
    const x = widget.computed_x;
    const y = widget.computed_y;
    const w = widget.computed_width;
    const h = widget.computed_height;
    r.fillRect(x, y, w, h, .{ .relief = if (data.disabled) .flat else if (data.open) t.button_pressed_relief else t.select_relief, .color = if (hovered and !data.disabled) t.surface_hover else t.surface, .radius = t.radius, .border_width = 1, .border_color = if (focused or data.open) t.accent else if (hovered and !data.disabled) t.border_hover else t.border });
    const valid = if (data.selected) |i| i < data.labels.len else false;
    const icon_width: f32 = if (valid and data.selected.? < data.icons.len) 24 else 0;
    if (icon_width > 0) r.drawIcon(x + 12, y + (h - 16) / 2, 16, 16, .{ .id = data.icons[data.selected.?], .color = if (data.disabled) t.faint else t.dim });
    r.drawText(x + 12 + icon_width, y, @max(0, w - 48 - icon_width), h, .{ .content = if (valid) data.labels[data.selected.?] else data.placeholder, .font_size = t.font_size, .weight = 600, .color = if (data.disabled) t.faint else if (valid) t.fg else t.dim });
    r.drawIcon(x + w - 28, y + (h - 16) / 2, 16, 16, .{ .id = if (data.open) .chevron_up else .chevron_down, .color = if (data.disabled) t.faint else t.dim });
}

/// Paint after the entire ordinary tree, outside scroll-container clips.
pub fn paintOverlays(widget: *const Widget, r: *Renderer) void {
    if (widget.kind == .select and widget.kind.select.open) {
        const select = @import("widgets/select.zig");
        const d = widget.kind.select;
        const b = select.popupBounds(widget);
        const t = r.palette orelse theme.global;
        var bg = t.bg;
        bg[3] = 1;
        r.fillRect(b.x, b.y, b.w, b.h, .{ .relief = t.select_popup_relief, .color = bg, .radius = t.radius, .border_width = 1, .border_color = t.border_hover });
        const row_h = select.rowHeight();
        const visible = select.visibleCount(widget);
        const end = @min(d.labels.len, d.first_visible + visible);
        for (d.first_visible..end) |i| {
            const y = b.y + select.padding + @as(f32, @floatFromInt(i - d.first_visible)) * row_h;
            if (i == d.highlighted) r.fillRect(b.x + 4, y, b.w - 8, row_h, .{ .color = .{ t.accent[0], t.accent[1], t.accent[2], 0.18 }, .radius = @max(0, t.radius - 3) });
            const disabled = std.mem.indexOfScalar(usize, d.disabled_options, i) != null;
            const icon_width: f32 = if (i < d.icons.len) 24 else 0;
            if (icon_width > 0) r.drawIcon(b.x + 12, y + (row_h - 16) / 2, 16, 16, .{ .id = d.icons[i], .color = if (disabled) t.faint else t.dim });
            r.drawText(b.x + 12 + icon_width, y, @max(0, b.w - 46 - icon_width), row_h, .{ .content = d.labels[i], .font_size = t.font_size, .weight = if (d.selected == i) 600 else 400, .color = if (disabled) t.faint else t.fg });
            if (d.selected == i) r.drawIcon(b.x + b.w - 28, y + (row_h - 16) / 2, 16, 16, .{ .id = .checkmark, .color = t.accent });
        }
        if (visible > 0) {
            const strip = scrollbar.gutter(theme.global.scrollbar_width);
            const track: scrollbar.Rect = .{ .x = b.x + b.w - strip, .y = b.y + 6, .w = strip, .h = b.h - 12 };
            if (scrollbar.Geometry.compute(.vertical, track, @floatFromInt(visible), @floatFromInt(d.labels.len), @floatFromInt(d.first_visible))) |g|
                scrollbar.paint(r, scrollbar.look(g, .{}, theme.global.scrollbar_width, t));
        }
        paintSelectPopupProximity(widget, r);
    }
    for (widget.children) |*child| paintOverlays(child, r);
}
