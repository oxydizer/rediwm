// Compositor-drawn start menu panel.
//
// Charcoal panel, red outlined search field, spacious
// two-line application rows, colorful icons, red selection marker, and bottom
// category bar.
const std = @import("std");
const Allocator = std.mem.Allocator;
const glass = @import("../glass.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const gpa = @import("../main.zig").gpa;
const anim = @import("ui").anim;
const geometry = @import("../geometry.zig");
const panel_buffer = @import("../panel_buffer.zig");
const panel_paint = @import("../panel_paint.zig");
const panel_present = @import("../panel_present.zig");
const scene_data = @import("../scene_data.zig");
const PanelBuffer = panel_buffer.PanelBuffer;
const Taskbar = @import("../Taskbar.zig");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const icon_service = @import("../icon_service.zig");
const ui = @import("ui");
const layout = ui.layout;
const Widget = layout.Widget;
const theme = ui.theme;

const clipboard = @import("../clipboard.zig");
const applications = @import("applications.zig");
const AppEntry = applications.AppEntry;
const launch = @import("launch.zig");
const model_mod = @import("model.zig");
const size_mod = @import("size.zig");
const Model = model_mod.Model;
const Category = model_mod.Category;
const SearchResult = model_mod.SearchResult;

const Anim = anim.Anim;
const log = std.log.scoped(.start_menu);

pub const slide_distance: f32 = 20;

const State = enum { opening, open, closing };

const Highlights = struct { sel: f32 = 0, hover: f32 = 0, hover_alpha: f32 = 0 };

// Result row height + list gap; converts the pixel quantum to row units.
const row_pitch: f32 = 60;

pub const StartMenu = struct {
    server: *Server,
    wlr_output: *wlr.Output,
    buffer_node: *wlr.SceneBuffer,
    glass_effect: ?*glass.Effect = null,
    node_data: scene_data.SceneData = undefined,

    state: State = .opening,
    slide: Anim = .{},
    dirty: bool = true,
    /// A wheel glide is in flight somewhere in `root` (`stepGlides`).
    scroll_gliding: bool = false,
    /// Scrollbar feedback still to play out (`stepBars`).
    bars: ui.widgets.scroll_container.BarStep = .{},
    /// Caret blink phase and glide position as of the last paint, so `tick`
    /// can repaint when the caret's pixels actually change rather than on
    /// every frame it happens to be blinking or gliding.
    caret_shown: bool = true,
    caret_offset: f32 = 0,
    /// List highlight glide, in row-index units so it follows the rows through
    /// scrolling and rebuilds (the tree is thrown away on every selection
    /// change; these outlive it). `hl` is what the last tick sampled, which
    /// the scroll container's underlay paints.
    sel_pos: Anim = .{},
    hover_pos: Anim = .{},
    hover_alpha: Anim = .{ .property = .opacity },
    hover_row: ?usize = null,
    hl: Highlights = .{},
    background: panel_paint.Background = .{},
    panel_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    model: Model,
    dispatcher: ui.input.Dispatcher = .{},
    /// Caret and selection into `model.query`. The widget tree is rebuilt on
    /// every keystroke, so the `Widget` that holds them is thrown away and
    /// recreated mid-edit; whoever outlives the tree has to own them. (Before
    /// this, `buildTree` hard-coded the caret to the end of the query, so
    /// typing anywhere but the end teleported it back.)
    query_cursor: usize = 0,
    query_anchor: ?usize = null,

    tree_arena: std.heap.ArenaAllocator,
    root: Widget = undefined,
    visible_icon_ids: []?u64 = &.{},

    // Scroll-direction/query-change prefetch bookkeeping (step 5/6); see
    // `prefetchAhead`. `prefetch_initialized` distinguishes "never ran yet"
    // from a real previous scroll_offset of 0.
    prefetch_results_ptr: [*]const SearchResult = undefined,
    prefetch_scroll_offset: f32 = 0,
    prefetch_initialized: bool = false,

    pub fn create(server: *Server, wlr_output: *wlr.Output) !*StartMenu {
        const menu = try gpa.create(StartMenu);
        errdefer gpa.destroy(menu);

        const buffer_node = try server.overlay_tree.createSceneBuffer(null);
        errdefer buffer_node.node.destroy();
        buffer_node.setFilterMode(.bilinear);

        menu.* = .{
            .server = server,
            .wlr_output = wlr_output,
            .buffer_node = buffer_node,
            .glass_effect = glass.Engine.attach(server.glass_engine, buffer_node, &buffer_node.node, .panel),
            .model = Model.init(gpa),
            .tree_arena = std.heap.ArenaAllocator.init(gpa),
        };
        menu.node_data = .{ .role = .{ .start_menu = menu } };
        scene_data.SceneData.attach(&menu.node_data, &buffer_node.node);

        const snap = server.start_menu_catalog.retainSnapshot();
        defer snap.release();
        try menu.model.bindSnapshot(snap, false);

        menu.buildTree();
        menu.slide.retargetTo(anim.nowMs(), 1, anim.curveFor(.panel_slide));
        menu.relayout();

        return menu;
    }

    pub fn destroy(menu: *StartMenu) void {
        // A Ctrl+V still reading the clipboard would otherwise deliver into
        // this allocation after it is gone.
        clipboard.cancelFor(menu);
        // A menu reopened at this address must not inherit a held key.
        @import("../Keyboard.zig").forgetShellTarget(menu.server, menu);
        menu.dispatcher.reset();
        if (menu.server.input.open_start_menu == menu) {
            menu.server.input.open_start_menu = null;
        }
        menu.model.deinit();
        menu.tree_arena.deinit();
        menu.background.deinit(gpa);
        menu.buffer_node.node.destroy();
        PanelBuffer.drainPool();
        gpa.destroy(menu);
    }

    fn requestWidgetRepaint(menu: *StartMenu) void {
        menu.dirty = true;
        menu.wlr_output.scheduleFrame();
    }

    pub fn requestRepaint(menu: *StartMenu) void {
        menu.background.invalidate();
        menu.dirty = true;
        menu.wlr_output.scheduleFrame();
    }

    pub fn beginClose(menu: *StartMenu) void {
        if (menu.state == .closing) return;
        menu.state = .closing;
        menu.slide.retargetTo(anim.nowMs(), 0, anim.curveFor(.panel_slide));
        menu.wlr_output.scheduleFrame();
    }

    /// Reverses an in-flight close. Animation only — call
    /// `Output.openStartMenu` instead unless you are it, because
    /// `Output.closeStartMenu` also drops `input.open_start_menu` and the
    /// taskbar button's state, and this restores neither. (The control
    /// center's `reopen` needs no such warning: it keeps
    /// `input.open_control_center` until `destroy`.)
    pub fn reopen(menu: *StartMenu) void {
        menu.state = .opening;
        menu.slide.retargetTo(anim.nowMs(), 1, anim.curveFor(.panel_slide));
        menu.wlr_output.scheduleFrame();
    }

    pub fn finishedClosing(menu: *StartMenu, now_ms: i64) bool {
        return menu.state == .closing and menu.slide.settled(now_ms);
    }

    pub fn tick(menu: *StartMenu, now_ms: i64) bool {
        // Before the caret check: this is what promotes `.opening` to `.open`
        // once the slide settles, and the caret only blinks while open.
        menu.applyPresentation(now_ms);
        const caret = menu.caretState(now_ms);
        // Both terms are edge-triggered on what would actually be drawn: a
        // blink repaints on a phase flip, a glide on a changed offset.
        // Repainting on "is animating" instead would cost a whole panel raster
        // per refresh for identical pixels — and under a pinned test clock,
        // where an in-flight glide never settles, it would repaint forever.
        const caret_quantum = anim.rasterPixelQuantum(menu.wlr_output.scale);
        if (menu.scroll_gliding) {
            const revision = ui.layout.paint_revision;
            menu.scroll_gliding = ui.widgets.scroll_container.stepGlides(&menu.root, now_ms, caret_quantum);
            if (revision != ui.layout.paint_revision) menu.dirty = true;
        }
        {
            const revision = ui.layout.paint_revision;
            menu.bars = ui.widgets.scroll_container.stepBars(&menu.root, now_ms);
            if (revision != ui.layout.paint_revision) menu.dirty = true;
        }
        const caret_moved = if (menu.dispatcher.caret.x.settled(now_ms))
            caret.offset != menu.caret_offset
        else
            @round(caret.offset / caret_quantum) != @round(menu.caret_offset / caret_quantum);
        if (caret.visible != menu.caret_shown or caret_moved) {
            menu.caret_shown = caret.visible;
            menu.caret_offset = caret.offset;
            if (menu.dispatcher.focused) |field| field.markPaintDirty();
            menu.dirty = true;
        }
        if (menu.stepHighlights(now_ms)) menu.dirty = true;
        if (menu.dirty) {
            menu.paintContent();
            // A blink phase flip or caret glide repaints without touching any
            // curve, so `sampleChanged` never sees it.
            anim.observeNoteChanged();
        }
        _ = menu.slide.sampleChanged(now_ms, anim.quantum_alpha);
        // The blink is a phase timer, not an Anim: it holds the output awake
        // for the whole timeout window and would otherwise report nothing.
        if (caret.animating) anim.observeNoteActive(menu.dispatcher.caret.last_edit_ms, now_ms);
        const animating = !menu.slide.settled(now_ms) or caret.animating or menu.scroll_gliding or menu.bars.pending() or
            !menu.sel_pos.settled(now_ms) or !menu.hover_pos.settled(now_ms) or !menu.hover_alpha.settled(now_ms);
        // A frozen test clock must not spin the output; the fixture advances
        // time and schedules the next frame itself. A failed paint stays dirty
        // so a later frame can retry.
        return menu.dirty or (animating and !anim.clockOverridden());
    }

    /// Samples the highlight glides; true when what would be painted (the
    /// quantised position or opacity) changed, in which case the results list
    /// repaints (only it). Edge-triggered on drawn state rather than on
    /// `Anim.sampleChanged`: a jump of a pinned test clock must not repaint an
    /// idle list.
    fn stepHighlights(menu: *StartMenu, now_ms: i64) bool {
        const q = anim.rasterPixelQuantum(menu.wlr_output.scale) / row_pitch;
        const next: Highlights = .{
            .sel = quantised(menu.sel_pos, now_ms, q),
            .hover = quantised(menu.hover_pos, now_ms, q),
            .hover_alpha = quantised(menu.hover_alpha, now_ms, anim.rasterAlphaQuantum()),
        };
        if (std.meta.eql(next, menu.hl)) return false;
        menu.hl = next;
        if (menu.resultsScroll()) |scroll| scroll.markPaintDirty();
        return true;
    }

    /// In flight, snapped to `quantum`; at rest, the exact endpoint.
    fn quantised(a: Anim, now_ms: i64, quantum: f32) f32 {
        const v = a.value(now_ms);
        return if (a.settled(now_ms)) v else @round(v / quantum) * quantum;
    }

    fn resultsScroll(menu: *StartMenu) ?*Widget {
        for (menu.root.children) |*kid| {
            if (std.meta.activeTag(kid.kind) == .scroll_container) return kid;
        }
        return null;
    }

    /// The selection glides only for keyboard navigation (`navigateResults`
    /// retargets before rebuilding); any other change of selection or result
    /// set jumps, since the rows underneath are different ones.
    fn syncSelectionGlide(menu: *StartMenu) void {
        const index: f32 = @floatFromInt(menu.model.selected_index);
        if (menu.sel_pos.to != index) menu.sel_pos.cancel(index);
    }

    fn setHoverRow(menu: *StartMenu, row: ?usize) void {
        if (menu.hover_row == row) return;
        menu.hover_row = row;
        const now_ms = anim.nowMs();
        if (row) |r| {
            const pos: f32 = @floatFromInt(r);
            // Appear in place; only glide if the highlight is still visible.
            if (menu.hover_alpha.value(now_ms) <= 0.01) {
                menu.hover_pos.cancel(pos);
            } else {
                menu.hover_pos.retargetTo(now_ms, pos, anim.curveFor(.start_glide));
            }
            menu.hover_alpha.retargetTo(now_ms, 1, anim.curveFor(.start_glide_fade));
        } else {
            menu.hover_alpha.retargetTo(now_ms, 0, anim.curveFor(.start_glide_fade));
        }
        menu.wlr_output.scheduleFrame();
    }

    fn syncHoverRow(menu: *StartMenu) void {
        const row: ?usize = if (menu.dispatcher.hovered) |w| switch (w.kind) {
            .row => |data| if (data.owner == @as(?*anyopaque, menu)) data.id else null,
            else => null,
        } else null;
        menu.setHoverRow(row);
    }

    /// Scroll-container underlay: the selected and hover fills, drawn at
    /// fractional row positions so they can sit between two rows mid-glide.
    fn paintHighlights(owner: ?*anyopaque, scroll: *const Widget, renderer: *ui.paint.Renderer) void {
        const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
        const t = renderer.palette orelse theme.global;
        if (scroll.children.len == 0) return;
        // Fades out as it reaches the selected row, which draws its own fill.
        const apart = std.math.clamp(@abs(menu.hl.hover - menu.hl.sel), 0, 1);
        const hover_alpha = std.math.clamp(menu.hl.hover_alpha, 0, 1) * apart;
        if (hover_alpha > 0) {
            const box = rowBox(scroll, menu.hl.hover);
            renderer.fillRect(box.x, box.y, box.w, box.h, .{
                .color = scaleAlpha(t.surface_hover, hover_alpha),
                .radius = t.radius,
                .border_width = 1,
                .border_color = scaleAlpha(t.border_soft, hover_alpha),
            });
        }
        if (menu.model.results.len == 0) return;
        const box = rowBox(scroll, menu.hl.sel);
        renderer.fillRect(box.x, box.y, box.w, box.h, .{
            .color = t.start_menu_selected_bg,
            .radius = t.radius,
            .border_width = 1,
            .border_color = t.start_menu_selected_border,
        });
        const marker_h = @max(10, box.h - 18);
        renderer.fillRect(box.x + 3, box.y + (box.h - marker_h) / 2, 3, marker_h, .{
            .color = t.start_menu_selected_marker,
            .radius = 1.5,
        });
    }

    const RowBox = struct { x: f32, y: f32, w: f32, h: f32 };

    /// Rect of the (possibly fractional) row `pos`, interpolated between the
    /// two neighbouring rows' actual layout so scrolling stays exact.
    fn rowBox(scroll: *const Widget, pos: f32) RowBox {
        const last: f32 = @floatFromInt(scroll.children.len - 1);
        const clamped = std.math.clamp(pos, 0, last);
        const lo: usize = @intFromFloat(@floor(clamped));
        const hi = @min(lo + 1, scroll.children.len - 1);
        const f = clamped - @as(f32, @floatFromInt(lo));
        const a = &scroll.children[lo];
        const b = &scroll.children[hi];
        return .{
            .x = a.computed_x,
            .y = a.computed_y + (b.computed_y - a.computed_y) * f,
            .w = a.computed_width,
            .h = a.computed_height,
        };
    }

    fn scaleAlpha(color: [4]f32, k: f32) [4]f32 {
        return .{ color[0], color[1], color[2], color[3] * k };
    }

    /// Blink phase and whether the caret still wants frames. Idle unless a
    /// text input actually has focus in a fully open menu: nothing blinks
    /// mid-slide (the caret would be repainting the panel against its own
    /// open/close animation, which is what `panel_present` exists to avoid),
    /// and a menu with no focused field costs no frames at all — which is what
    /// makes `caret_blink_timeout` able to stop the pump.
    fn caretState(menu: *StartMenu, now_ms: i64) CaretState {
        const idle = CaretState{ .visible = menu.caret_shown, .offset = menu.caret_offset, .animating = false };
        if (menu.state != .open) return idle;
        const focused = menu.dispatcher.focused orelse return idle;
        if (std.meta.activeTag(focused.kind) != .text_input) return idle;
        return .{
            .visible = menu.dispatcher.caret.visible(now_ms),
            .offset = menu.dispatcher.caret.offset(now_ms),
            .animating = menu.dispatcher.caret.animating(now_ms),
        };
    }

    const CaretState = struct { visible: bool, offset: f32, animating: bool };

    pub fn refreshCatalog(menu: *StartMenu) void {
        const snap = menu.server.start_menu_catalog.retainSnapshot();
        defer snap.release();
        const scroll = menu.currentScrollOffset();
        menu.model.bindSnapshot(snap, true) catch return;
        menu.buildTree();
        menu.relayout();
        menu.restoreScrollOffset(scroll);
    }

    fn currentScrollOffset(menu: *StartMenu) f32 {
        for (menu.root.children) |*viewport| {
            if (viewport.kind == .scroll_container) return ui.widgets.scroll_container.restingOffset(viewport);
        }
        return 0;
    }

    fn restoreScrollOffset(menu: *StartMenu, offset: f32) void {
        for (menu.root.children) |*viewport| {
            if (viewport.kind == .scroll_container) {
                ui.widgets.scroll_container.scrollBy(viewport, offset - viewport.kind.scroll_container.scroll_offset);
                return;
            }
        }
    }

    // ---- Tree building ----

    pub fn buildTree(menu: *StartMenu) void {
        menu.dispatcher.reset();
        // Fresh rows carry no pointer state; let the hover fill fade out.
        menu.setHoverRow(null);
        menu.syncSelectionGlide();
        _ = menu.tree_arena.reset(.retain_capacity);
        const a = menu.tree_arena.allocator();

        const t = menuPalette();
        // 1. Search Box
        const sw_children = a.alloc(Widget, 1) catch return;
        const query_val = a.dupe(u8, menu.model.query.items) catch return;
        sw_children[0] = .{
            .name = "search_input",
            .kind = .{ .text_input = .{
                .placeholder = "Type to search…",
                .field = .{ .leading_icon = .search, .leading_icon_size = 24, .leading_icon_color = t.window_fg },
                .value = query_val,
                .cursor_pos = @min(menu.query_cursor, query_val.len),
                .selection_anchor = if (menu.query_anchor) |anchor| @min(anchor, query_val.len) else null,
                .on_change = onQueryChanged,
            } },
            .width = .{ .percent = 1 },
        };

        const search_wrapper = a.create(Widget) catch return;
        search_wrapper.* = .{
            .name = "search",
            .kind = .container,
            .width = .{ .percent = 1 },
            .padding = layout.Edges{ .top = 20, .left = 20, .right = 20, .bottom = 10 },
            .children = sw_children,
        };

        // Automatically focus search input
        menu.dispatcher.focused = &sw_children[0];

        // 2. Heading: Grid glyph + "Applications" + count
        const grid_icon = a.create(Widget) catch return;
        grid_icon.* = .{
            .kind = .{ .icon = .{ .id = .grid, .color = t.dim } },
            .width = .{ .fixed = 14 },
            .height = .{ .fixed = 14 },
        };

        const heading_label = a.create(Widget) catch return;
        heading_label.* = .{
            .kind = .{ .text = .{
                .content = "Applications",
                .font_size = 12,
                .weight = 600,
                .color = t.dim,
            } },
        };

        const count_str: []const u8 = if (menu.model.isLoading())
            "…"
        else
            std.fmt.allocPrint(a, "{d}", .{menu.model.countApplications()}) catch "0";
        const heading_count = a.create(Widget) catch return;
        heading_count.* = .{
            .kind = .{ .text = .{
                .content = count_str,
                .font_size = 11,
                .weight = 400,
                .color = t.faint,
            } },
        };

        const heading_children = a.alloc(Widget, 3) catch return;
        heading_children[0] = grid_icon.*;
        heading_children[1] = heading_label.*;
        heading_children[2] = heading_count.*;

        const heading_wrapper = a.create(Widget) catch return;
        heading_wrapper.* = .{
            .kind = .container,
            .direction = .row,
            .@"align" = .center,
            .gap = 8,
            .width = .{ .percent = 1 },
            .height = .{ .fixed = 24 },
            .padding = layout.Edges{ .top = 0, .left = 24, .right = 24, .bottom = 4 },
            .children = heading_children,
        };

        // 3. Results scroll container
        const row_count = menu.model.results.len;
        const row_widgets = a.alloc(Widget, row_count) catch return;
        menu.visible_icon_ids = a.alloc(?u64, row_count) catch return;
        @memset(menu.visible_icon_ids, null);

        for (menu.model.results, 0..) |res, idx| {
            const is_sel = (idx == menu.model.selected_index);

            // Resolve icons only after layout, for rows in the viewport.
            const img_widget = a.create(Widget) catch return;
            img_widget.* = .{
                .kind = .{ .image = .{
                    .pixels = null,
                    .width = 0,
                    .height = 0,
                    .radius = 8,
                    .fallback_icon = if (res.is_settings) .settings else .generic,
                } },
                .width = .{ .fixed = 38 },
                .height = .{ .fixed = 38 },
            };

            // Text column (title + description)
            const title_widget = a.create(Widget) catch return;
            title_widget.* = .{
                .kind = .{ .text = .{
                    .content = res.name,
                    .font_size = 13.5,
                    .weight = 600,
                    .color = t.fg,
                } },
            };

            const desc_widget = a.create(Widget) catch return;
            desc_widget.* = .{
                .kind = .{ .text = .{
                    .content = res.description,
                    .font_size = 11.5,
                    .weight = 400,
                    .color = t.dim,
                } },
            };

            const col_children = a.alloc(Widget, 2) catch return;
            col_children[0] = title_widget.*;
            col_children[1] = desc_widget.*;

            const col_widget = a.create(Widget) catch return;
            col_widget.* = .{
                .kind = .container,
                .direction = .column,
                .gap = 2,
                .width = .{ .flex = 1 },
                .children = col_children,
            };

            // Row children: image, text column, optional enter hint
            var row_kids: []Widget = undefined;
            if (is_sel) {
                const hint_widget = a.create(Widget) catch return;
                hint_widget.* = .{
                    .kind = .{ .text = .{
                        .content = "↵",
                        .font_size = 14,
                        .color = t.accent,
                    } },
                };
                row_kids = a.alloc(Widget, 3) catch return;
                row_kids[0] = img_widget.*;
                row_kids[1] = col_widget.*;
                row_kids[2] = hint_widget.*;
            } else {
                row_kids = a.alloc(Widget, 2) catch return;
                row_kids[0] = img_widget.*;
                row_kids[1] = col_widget.*;
            }

            row_widgets[idx] = .{
                .kind = .{ .row = .{
                    .owner = menu,
                    .id = idx,
                    .on_click = onRowClick,
                    .selected = is_sel,
                    .underlay = true,
                } },
                .direction = .row,
                .@"align" = .center,
                .gap = 16,
                .padding = layout.Edges.xy(theme.global.start_menu_icon_left_pad, theme.global.start_menu_icon_bottom_pad),
                .width = .{ .percent = 1 },
                .height = .{ .fixed = 56 },
                .children = row_kids,
            };
        }

        const scroll_widget = a.create(Widget) catch return;
        scroll_widget.* = .{
            .name = "results",
            .kind = .{ .scroll_container = .{ .underlay = .{ .owner = menu, .paint = paintHighlights } } },
            .direction = .column,
            .gap = 4,
            .padding = layout.Edges.xy(16, 4),
            .width = .{ .percent = 1 },
            .height = .{ .flex = 1 },
            .children = row_widgets,
        };

        // 4. Optional Error Banner
        var error_widget: ?*Widget = null;
        if (menu.model.error_msg) |err_msg| {
            const err_text = a.create(Widget) catch return;
            err_text.* = .{
                .kind = .{ .text = .{
                    .content = err_msg,
                    .font_size = 12,
                    .color = t.danger,
                } },
            };
            const err_children = a.alloc(Widget, 1) catch return;
            err_children[0] = err_text.*;

            const ew = a.create(Widget) catch return;
            ew.* = .{
                .kind = .{ .rect = .{
                    .color = .{ t.danger[0], t.danger[1], t.danger[2], 0.15 },
                    .radius = 6,
                } },
                .padding = layout.Edges.xy(12, 6),
                .margin = layout.Edges.xy(20, 4),
                .width = .{ .percent = 1 },
                .children = err_children,
            };
            error_widget = ew;
        }

        // 5. Footer: Category buttons ("All", "Apps") and the power button,
        // which opens power_menu.zig's Lock/Log Out/Restart/Power Off modal.
        const all_btn = a.create(Widget) catch return;
        const all_sel = (menu.model.category == .all);
        all_btn.* = .{
            .name = "all",
            .kind = .{ .button = .{
                .label = "All",
                .variant = if (all_sel) .primary else .secondary,
                .owner = menu,
                .on_click = onCategoryAll,
            } },
            .height = .{ .fixed = 26 },
        };

        const apps_btn = a.create(Widget) catch return;
        const apps_sel = (menu.model.category == .apps);
        apps_btn.* = .{
            .name = "apps",
            .kind = .{ .button = .{
                .label = "Apps",
                .variant = if (apps_sel) .primary else .secondary,
                .owner = menu,
                .on_click = onCategoryApps,
            } },
            .height = .{ .fixed = 26 },
        };

        const cat_kids = a.alloc(Widget, 2) catch return;
        cat_kids[0] = all_btn.*;
        cat_kids[1] = apps_btn.*;

        const cat_box = a.create(Widget) catch return;
        cat_box.* = .{
            .name = "categories",
            .kind = .container,
            .direction = .row,
            .@"align" = .center,
            .gap = 8,
            .children = cat_kids,
        };

        const power_btn = a.create(Widget) catch return;
        power_btn.* = .{
            .name = "power",
            .kind = .{ .button = .{
                .variant = .ghost,
                .icon = .power,
                .icon_scale = 0.585,
                .label = "Power",
                .owner = menu,
                .on_click = onPowerButtonClick,
            } },
            .width = .{ .fixed = 39 },
            .height = .{ .fixed = 39 },
        };

        const action_kids = a.alloc(Widget, 2) catch return;
        action_kids[0] = .{
            .name = "settings",
            .kind = .{ .button = .{
                .variant = .ghost,
                .icon = .settings,
                .icon_scale = 0.585,
                .label = "Settings",
                .owner = menu,
                .on_click = onSettingsButtonClick,
            } },
            .width = .{ .fixed = 39 },
            .height = .{ .fixed = 39 },
        };
        action_kids[1] = power_btn.*;
        const actions: Widget = .{ .kind = .container, .direction = .row, .gap = 16, .@"align" = .center, .children = action_kids };
        const footer_kids = a.alloc(Widget, 2) catch return;
        footer_kids[0] = cat_box.*;
        footer_kids[1] = actions;

        const footer_widget = a.create(Widget) catch return;
        footer_widget.* = .{
            .kind = .{ .rect = .{
                .color = .{ 0, 0, 0, 0 },
                .border_width = 1,
                .border_color = t.border_soft,
            } },
            .direction = .row,
            .@"align" = .center,
            .justify = .space_between,
            .padding = layout.Edges.xy(20, 20),
            .width = .{ .percent = 1 },
            .height = .{ .fixed = 79 },
            .children = footer_kids,
        };

        // Root container
        const has_err = (error_widget != null);
        const root_kids = a.alloc(Widget, if (has_err) 6 else 5) catch return;
        root_kids[0] = search_wrapper.*;
        root_kids[1] = heading_wrapper.*;
        root_kids[2] = .{
            .kind = .{ .rect = .{ .color = t.border_soft } },
            .width = .{ .percent = 1 },
            .height = .{ .fixed = 1 },
        };
        if (has_err) {
            root_kids[3] = error_widget.?.*;
            root_kids[4] = scroll_widget.*;
            root_kids[5] = footer_widget.*;
        } else {
            root_kids[3] = scroll_widget.*;
            root_kids[4] = footer_widget.*;
        }

        menu.root = .{
            .kind = .{ .rect = .{
                .color = t.start_menu_bg,
                .radius = t.start_menu_radius,
                .border_width = 1,
                .border_color = t.start_menu_border,
            } },
            .direction = .column,
            .width = .{ .fixed = menu.wantedSize().width },
            .height = .auto,
            .children = root_kids,
        };
        menu.root.linkParents();
        // Bind before the opening click release, which otherwise clears search focus.
        menu.dispatcher.tree = &menu.root;
        if (menu.panel_box.width > 0 and menu.panel_box.height > 0) {
            const width: f32 = @floatFromInt(menu.panel_box.width);
            const height: f32 = @floatFromInt(menu.panel_box.height);
            menu.root.width = .{ .fixed = width };
            menu.root.height = .{ .fixed = height };
            ui.measure.measure(&menu.root, width, height);
            ui.arrange.arrange(&menu.root, 0, 0, width, height);
        }
    }

    /// The size the theme asks for on this menu's output, before the caps in
    /// `relayout`: its own values, else the automatic ones (`size.zig`).
    fn wantedSize(menu: *StartMenu) size_mod.Size {
        var box: wlr.Box = undefined;
        menu.server.output_layout.getBox(menu.wlr_output, &box);
        return size_mod.wanted(theme.global, @floatFromInt(box.width), @floatFromInt(box.height));
    }

    pub fn relayout(menu: *StartMenu) void {
        menu.background.invalidate();
        var output_box: wlr.Box = undefined;
        menu.server.output_layout.getBox(menu.wlr_output, &output_box);
        if (output_box.width <= 0 or output_box.height <= 0) return;

        const wanted = menu.wantedSize();
        const max_allowed_h = @min(wanted.height, @as(f32, @floatFromInt(output_box.height)) * 0.85);
        const max_allowed_w = @min(wanted.width, @as(f32, @floatFromInt(output_box.width)) - 40);

        const target_height = @max(240, max_allowed_h);
        const target_width = @max(320, max_allowed_w);

        menu.root.width = .{ .fixed = target_width };
        menu.root.height = .{ .fixed = target_height };
        ui.measure.measure(&menu.root, target_width, target_height);
        ui.arrange.arrange(&menu.root, 0, 0, target_width, target_height);

        const bottom_offset: f32 = @as(f32, @floatFromInt(Taskbar.barHeight())) + theme.global.start_menu_bottom_pad;
        const panel_left: f32 = theme.global.start_menu_left_pad;

        menu.panel_box = .{
            .x = output_box.x + @as(i32, @intFromFloat(panel_left)),
            .y = if (menu.server.config.compositor.taskbar_position == .top) output_box.y + @as(i32, @intFromFloat(bottom_offset)) else output_box.y + output_box.height - @as(i32, @intFromFloat(bottom_offset)) - @as(i32, @intFromFloat(target_height)),
            .width = @intFromFloat(target_width),
            .height = @intFromFloat(target_height),
        };
        menu.dirty = true;
        menu.paintContent();
        menu.applyPresentation(anim.nowMs());
    }

    /// Worker completions also include speculative/offscreen icons. Only a
    /// changed visible raster needs a panel repaint.
    pub fn iconsReady(menu: *StartMenu) void {
        if (menu.loadVisibleIcons()) menu.requestWidgetRepaint();
    }

    fn loadVisibleIcons(menu: *StartMenu) bool {
        var changed = false;
        var scroll_offset: f32 = 0;
        var have_viewport = false;
        var first_visible: ?usize = null;
        var last_visible: usize = 0;

        for (menu.root.children) |*viewport| {
            if (viewport.kind != .scroll_container) continue;
            have_viewport = true;
            scroll_offset = viewport.kind.scroll_container.scroll_offset;
            for (viewport.children, 0..) |*row, index| {
                const img = &row.children[0].kind.image;
                if (row.computed_y + row.computed_height <= viewport.computed_y or
                    row.computed_y >= viewport.computed_y + viewport.computed_height)
                {
                    _ = updateIcon(img, &menu.visible_icon_ids[index], .missing);
                    continue;
                }
                if (first_visible == null) first_visible = index;
                last_visible = index;
                const lookup = if (menu.model.results[index].icon) |name|
                    menu.server.iconLookup(name, geometry.devicePixels(38, menu.wlr_output.scale))
                else
                    icon_service.Lookup.missing;
                if (updateIcon(img, &menu.visible_icon_ids[index], lookup)) {
                    row.children[0].markPaintDirty();
                    changed = true;
                }
            }
        }

        if (have_viewport) menu.prefetchAhead(scroll_offset, first_visible, last_visible);
        return changed;
    }

    // Step 5 (scroll-direction + initial-results prefetch) and step 6
    // (stale-interest cancellation), folded into one pass since they're two
    // halves of the same decision: once the visible viewport or result set
    // has moved since the last paint, whatever was speculatively queued for
    // the *old* one is no longer useful, so cancel it before queuing fresh
    // prefetch for the new one. `results.ptr` changing is a cheap, reliable
    // "new query/category" signal — `Model.update` always rebuilds
    // `results` from a fresh arena allocation, even for identical content.
    // No favourites prefetch: this codebase has no favourites/launch-history
    // source to prefetch from (see plan-performance-4-icon-preparation.md
    // step 5), and none is added here just for this optimization.
    fn prefetchAhead(menu: *StartMenu, scroll_offset: f32, first_visible: ?usize, last_visible: usize) void {
        const results_ptr: [*]const SearchResult = menu.model.results.ptr;
        const results_changed = !menu.prefetch_initialized or results_ptr != menu.prefetch_results_ptr;
        const scroll_changed = menu.prefetch_initialized and scroll_offset != menu.prefetch_scroll_offset;
        const stale = results_changed or scroll_changed;

        defer {
            menu.prefetch_results_ptr = results_ptr;
            menu.prefetch_scroll_offset = scroll_offset;
            menu.prefetch_initialized = true;
        }
        if (!stale) return;
        menu.server.iconCancelSpeculative();

        const first = first_visible orelse return; // nothing on screen (empty results) to prefetch around
        const visible_count = last_visible - first + 1;
        const size_px = geometry.devicePixels(38, menu.wlr_output.scale);
        // A fresh query/category has no established scroll direction of its
        // own yet: prefetch forward from what's visible, matching "initial
        // menu results" in the plan.
        const forward = results_changed or scroll_offset >= menu.prefetch_scroll_offset;

        if (forward) {
            var idx = last_visible + 1;
            var n: usize = 0;
            while (n < visible_count and idx < menu.model.results.len) : ({
                idx += 1;
                n += 1;
            }) {
                if (menu.model.results[idx].icon) |name| menu.server.iconPrefetch(name, size_px);
            }
        } else {
            var idx = first;
            var n: usize = 0;
            while (n < visible_count and idx > 0) : (n += 1) {
                idx -= 1;
                if (menu.model.results[idx].icon) |name| menu.server.iconPrefetch(name, size_px);
            }
        }
    }

    fn paintContent(menu: *StartMenu) void {
        if (menu.panel_box.width <= 0 or menu.panel_box.height <= 0) return;
        const scale = menu.wlr_output.scale;
        const buf = PanelBuffer.createUninitialized(menu.panel_box.width, menu.panel_box.height, scale) catch |err| {
            log.err("StartMenu.paintContent: could not create buffer: {}", .{err});
            return;
        };

        const t0 = panel_present.nowNs();
        _ = menu.loadVisibleIcons();
        var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        renderer.palette = menuPalette();
        ui.input.active_dispatcher = &menu.dispatcher;
        menu.background.paintIncremental(gpa, &menu.root, &renderer);
        ui.input.active_dispatcher = null;
        const elapsed_ns = panel_present.nowNs() -| t0;

        buf.publish(menu.buffer_node, scale, menu.background.damage);
        menu.buffer_node.setDestSize(menu.panel_box.width, menu.panel_box.height);
        buf.base.drop();
        panel_present.addPaint(elapsed_ns);
        menu.dirty = false;
    }

    fn applyPresentation(menu: *StartMenu, now_ms: i64) void {
        if (menu.panel_box.width <= 0 or menu.panel_box.height <= 0) return;
        const t = menu.slide.value(now_ms);
        panel_present.applySlide(menu.buffer_node, menu.panel_box, t, if (menu.server.config.compositor.taskbar_position == .top) -slide_distance else slide_distance);
        glass.Effect.configure(menu.glass_effect, theme.global.start_menu_radius, t);
        if (menu.state == .opening and (menu.slide.settled(now_ms) or panel_present.slideOffset(t, slide_distance) == 0)) menu.state = .open;
    }

    // ---- Interaction & Actions ----

    pub fn activateSelected(menu: *StartMenu) void {
        if (menu.model.selected_index < menu.model.results.len) {
            menu.activateResult(menu.model.selected_index);
        }
    }

    pub fn activateResult(menu: *StartMenu, index: usize) void {
        if (index >= menu.model.results.len or menu.model.launching) return;
        const result = menu.model.results[index];

        if (result.is_loading) return;

        if (result.is_settings) {
            if (Output.fromWlr(menu.wlr_output)) |output| {
                output.closeStartMenu();
                output.toggleControlCenter();
            }
            return;
        }

        if (result.app_entry) |entry| {
            menu.model.launching = true;
            launch.launch(gpa, menu.server, entry) catch |err| {
                menu.model.launching = false;
                menu.model.error_msg = std.fmt.allocPrint(menu.tree_arena.allocator(), "Launch failed: {s}", .{@errorName(err)}) catch "Launch failed";
                menu.buildTree();
                menu.requestRepaint();
                return;
            };

            // Spawn successful: close start menu
            if (Output.fromWlr(menu.wlr_output)) |output| {
                output.closeStartMenu();
            }
        }
    }

    pub fn handleKey(
        menu: *StartMenu,
        keysym: xkb.Keysym,
        state: wl.Keyboard.KeyState,
        utf8: ?[]const u8,
        mods: wlr.Keyboard.ModifierMask,
    ) bool {
        const edit_mods = ui.input.Mods{ .shift = mods.shift };
        if (state == .released) return true;

        // Pressed:
        switch (@intFromEnum(keysym)) {
            xkb.Keysym.Escape => {
                if (Output.fromWlr(menu.wlr_output)) |output| output.closeStartMenu();
                return true;
            },
            xkb.Keysym.Return => {
                menu.activateSelected();
                return true;
            },
            xkb.Keysym.Up => {
                menu.navigateResults(-1);
                return true;
            },
            xkb.Keysym.Down => {
                menu.navigateResults(1);
                return true;
            },
            xkb.Keysym.Page_Up => {
                menu.navigateResults(-5);
                return true;
            },
            xkb.Keysym.Page_Down => {
                menu.navigateResults(5);
                return true;
            },
            xkb.Keysym.Tab => {
                // Cycle category
                const next_cat: Category = if (menu.model.category == .all) .apps else .all;
                const snap = menu.server.start_menu_catalog.retainSnapshot();
                defer snap.release();
                menu.model.setCategorySnapshot(next_cat, snap) catch {};
                menu.syncQueryState();
                menu.buildTree();
                menu.requestRepaint();
                return true;
            },
            xkb.Keysym.BackSpace => return menu.editKey(.backspace, edit_mods),
            xkb.Keysym.Delete => return menu.editKey(.delete, edit_mods),
            xkb.Keysym.Left => return menu.editKey(.left, edit_mods),
            xkb.Keysym.Right => return menu.editKey(.right, edit_mods),
            xkb.Keysym.Home => return menu.editKey(.home, edit_mods),
            xkb.Keysym.End => return menu.editKey(.end, edit_mods),
            else => {
                if (mods.ctrl) {
                    // Match on the *unshifted* keysym so Ctrl+Shift+A is still
                    // select-all, and accept both cases for layouts that
                    // report them differently.
                    switch (@intFromEnum(keysym)) {
                        xkb.Keysym.a, xkb.Keysym.A => return menu.editKey(.select_all, edit_mods),
                        xkb.Keysym.c, xkb.Keysym.C => return menu.editKey(.copy, edit_mods),
                        xkb.Keysym.x, xkb.Keysym.X => return menu.editKey(.cut, edit_mods),
                        xkb.Keysym.v, xkb.Keysym.V => {
                            // Asynchronous: the text arrives from the seat's
                            // selection source down a pipe, and comes back
                            // through `onPasted` as a `.paste` key.
                            clipboard.requestText(menu.server, *StartMenu, onPasted, menu);
                            return true;
                        },
                        else => return false,
                    }
                }
                if (utf8) |txt| {
                    if (txt.len > 0 and txt[0] >= 32) {
                        return menu.editKey(.{ .char = txt }, edit_mods);
                    }
                }
            },
        }
        return false;
    }

    /// Which held keys `Keyboard` repeats into the menu: typing and caret
    /// keys in the search box, and moving through the results. Home/End are
    /// already at the extremes; Return, Escape and Tab are actions.
    pub fn keyRepeats(_: *const StartMenu, keysym: xkb.Keysym, utf8: []const u8) bool {
        const repeat_keys = @import("../input/repeat_keys.zig");
        return repeat_keys.editing(keysym, utf8) or repeat_keys.navigation(keysym);
    }

    /// Runs one editing key against the focused field, then does whatever it
    /// asked for: put text on the clipboard, rebuild the results if the value
    /// changed, or just repaint if only the caret moved.
    fn editKey(menu: *StartMenu, key: ui.input.Key, mods: ui.input.Mods) bool {
        const allocator = menu.tree_arena.allocator();
        const outcome = menu.dispatcher.keyEvent(allocator, key, mods) catch return true;
        // Before any rebuild: this is arena memory, and `onQueryEdited` is
        // about to reset the arena under it. `copyText` keeps its own copy.
        if (outcome.copy) |text| {
            defer allocator.free(text);
            clipboard.copyText(menu.server, text);
        }
        menu.syncQueryState();
        if (editsValue(key)) menu.onQueryEdited() else menu.requestRepaint();
        return true;
    }

    fn editsValue(key: ui.input.Key) bool {
        return switch (key) {
            .char, .paste, .backspace, .delete, .cut => true,
            else => false,
        };
    }

    /// Copies the caret and selection out of the widget, which the next
    /// `buildTree` will destroy, and into the menu, which outlives it.
    fn syncQueryState(menu: *StartMenu) void {
        const focused = menu.dispatcher.focused orelse return;
        if (std.meta.activeTag(focused.kind) != .text_input) return;
        menu.query_cursor = focused.kind.text_input.cursor_pos;
        menu.query_anchor = focused.kind.text_input.selection_anchor;
    }

    /// Clipboard text arriving some frames after the Ctrl+V that asked for
    /// it. The menu may be gone by then; `clipboard` drops the request when
    /// its owner is destroyed, so reaching here means it is still alive.
    fn onPasted(menu: *StartMenu, text: []const u8) void {
        if (text.len == 0) return;
        // Newlines would be invisible in a one-line field and a tab would
        // read as a category switch; take the first line, as GTK does.
        const first_line = text[0 .. std.mem.indexOfAny(u8, text, "\r\n") orelse text.len];
        if (first_line.len == 0) return;
        _ = menu.editKey(.{ .paste = first_line }, .{});
    }

    fn navigateResults(menu: *StartMenu, delta: isize) void {
        if (menu.model.moveSelection(delta)) {
            menu.sel_pos.retargetTo(anim.nowMs(), @floatFromInt(menu.model.selected_index), anim.curveFor(.start_glide));
            menu.syncQueryState();
            menu.buildTree();
            menu.ensureSelectedVisible();
            menu.requestRepaint();
        }
    }

    fn ensureSelectedVisible(menu: *StartMenu) void {
        // Find scroll container and ensure selected row is visible
        const root_kids = menu.root.children;
        for (root_kids) |*kid| {
            if (std.meta.activeTag(kid.kind) == .scroll_container) {
                if (menu.model.selected_index < kid.children.len) {
                    const row_child = &kid.children[menu.model.selected_index];
                    ui.widgets.scroll_container.ensureVisibleChild(kid, row_child);
                }
                break;
            }
        }
    }

    fn onQueryEdited(menu: *StartMenu) void {
        // Read text input value back into model
        if (menu.dispatcher.focused) |focused| {
            if (std.meta.activeTag(focused.kind) == .text_input) {
                const val = focused.kind.text_input.value;
                const snap = menu.server.start_menu_catalog.retainSnapshot();
                defer snap.release();
                menu.model.setQuerySnapshot(val, snap) catch {};
                menu.buildTree();
                menu.requestRepaint();
            }
        }
    }

    // ---- Callbacks ----

    fn onQueryChanged(_: ?*anyopaque, _: usize, _: []const u8) void {}

    fn onRowClick(owner: ?*anyopaque, id: usize) void {
        if (owner) |o| {
            const menu: *StartMenu = @ptrCast(@alignCast(o));
            menu.model.selected_index = id;
            menu.activateResult(id);
        }
    }

    fn onCategoryAll(owner: ?*anyopaque, _: usize) void {
        const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
        const snap = menu.server.start_menu_catalog.retainSnapshot();
        defer snap.release();
        menu.model.setCategorySnapshot(.all, snap) catch {};
        menu.buildTree();
        menu.requestRepaint();
    }

    fn onCategoryApps(owner: ?*anyopaque, _: usize) void {
        const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
        const snap = menu.server.start_menu_catalog.retainSnapshot();
        defer snap.release();
        menu.model.setCategorySnapshot(.apps, snap) catch {};
        menu.buildTree();
        menu.requestRepaint();
    }

    fn onSettingsButtonClick(owner: ?*anyopaque, _: usize) void {
        const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
        if (Output.fromWlr(menu.wlr_output)) |output| {
            output.closeStartMenu();
            output.toggleControlCenter();
        }
    }

    fn onPowerButtonClick(owner: ?*anyopaque, _: usize) void {
        const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
        if (Output.fromWlr(menu.wlr_output)) |output| {
            output.closeStartMenu();
            output.openPowerMenu();
        }
    }

    // ---- Pointer entry points ----

    pub fn pointerMotion(menu: *StartMenu, sx: f64, sy: f64) void {
        const revision = ui.layout.paint_revision;
        menu.dispatcher.pointerMotion(&menu.root, @floatCast(sx), @floatCast(sy));
        menu.syncHoverRow();
        // A click or a drag-select moves the caret, and the next
        // rebuild would otherwise put it back at the end.
        menu.syncQueryState();
        if (revision != ui.layout.paint_revision) menu.requestWidgetRepaint();
    }

    pub fn pointerButtonDown(menu: *StartMenu, sx: f64, sy: f64) void {
        menu.dispatcher.pointerButtonDown(&menu.root, @floatCast(sx), @floatCast(sy));
        // A click or a drag-select moves the caret, and the next
        // rebuild would otherwise put it back at the end.
        menu.syncQueryState();
        menu.requestRepaint();
    }

    /// The pointer is over something else: the scrollbar thumb stops being hovered.
    pub fn pointerLeave(menu: *StartMenu) void {
        const revision = ui.layout.paint_revision;
        menu.dispatcher.pointerLeave(&menu.root);
        if (revision != ui.layout.paint_revision) menu.requestWidgetRepaint();
    }

    pub fn pointerButtonUp(menu: *StartMenu, sx: f64, sy: f64) void {
        menu.dispatcher.pointerButtonUp(&menu.root, @floatCast(sx), @floatCast(sy));
        // A click or a drag-select moves the caret, and the next
        // rebuild would otherwise put it back at the end.
        menu.syncQueryState();
        menu.requestRepaint();
    }

    /// `notch` is a detented wheel click, which glides; see `Dispatcher.scrollWheel`.
    pub fn scrollWheel(menu: *StartMenu, sx: f64, sy: f64, delta_px: f32, notch: bool) void {
        const revision = ui.layout.paint_revision;
        if (menu.dispatcher.scrollWheel(&menu.root, @floatCast(sx), @floatCast(sy), delta_px, if (notch) anim.nowMs() else null)) {
            menu.scroll_gliding = true;
            menu.wlr_output.scheduleFrame();
        }
        if (revision != ui.layout.paint_revision) menu.requestWidgetRepaint();
    }

    pub fn containsPoint(menu: *StartMenu, lx: f64, ly: f64) bool {
        const box = menu.panel_box;
        return lx >= @as(f64, @floatFromInt(box.x)) and lx < @as(f64, @floatFromInt(box.x + box.width)) and
            ly >= @as(f64, @floatFromInt(box.y)) and ly < @as(f64, @floatFromInt(box.y + box.height));
    }
};

// The service can evict unpinned rasters between paints. Never leave borrowed
// pixels in a row after lookup becomes pending/missing, and compare stable IDs
// rather than addresses (allocations can reuse an old raster's address).
fn updateIcon(image: *layout.ImageData, id: *?u64, lookup: icon_service.Lookup) bool {
    const previous = id.*;
    image.pixels = null;
    image.width = 0;
    image.height = 0;
    id.* = null;
    if (lookup == .ready) {
        const entry = lookup.ready;
        image.pixels = entry.pixels;
        image.width = entry.size;
        image.height = entry.size;
        id.* = entry.id;
    }
    return previous != id.*;
}

test "menu icon arrivals repaint only changed rasters and clear evicted pixels" {
    const pixels = [_]u32{0xff123456};
    var image = layout.ImageData{};
    var id: ?u64 = null;
    try std.testing.expect(!updateIcon(&image, &id, .pending));
    const ready: icon_service.Lookup = .{ .ready = .{ .id = 1, .pixels = &pixels, .size = 1 } };
    try std.testing.expect(updateIcon(&image, &id, ready));
    try std.testing.expect(!updateIcon(&image, &id, ready));
    // Same allocation address with a new lifetime must still be noticed.
    try std.testing.expect(updateIcon(&image, &id, .{ .ready = .{ .id = 2, .pixels = &pixels, .size = 1 } }));
    try std.testing.expect(updateIcon(&image, &id, .pending));
    try std.testing.expect(image.pixels == null and image.width == 0 and image.height == 0);
    try std.testing.expect(!updateIcon(&image, &id, .missing));
}

// Keep shared widgets neutral and red within this panel only.
fn menuPalette() theme.Theme {
    var t = theme.shellPalette();
    t.field_bg = t.start_menu_search_bg;
    return t;
}
