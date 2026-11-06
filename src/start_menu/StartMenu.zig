//! The start menu and the centered launcher: state, lifecycle and closing.
//! Animation, tree building, cards, presentation, keys and pointer input are in
//! `menu_*.zig` beside it; `panel.zig` re-exports it as `panel.StartMenu`.

const i18n = @import("i18n");
const std = @import("std");
const Allocator = std.mem.Allocator;
const glass = @import("../glass.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("../node.zig");
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
pub const launch = @import("launch.zig");
const model_mod = @import("model.zig");
const size_mod = @import("size.zig");
const Model = model_mod.Model;
const Category = model_mod.Category;
const SearchResult = model_mod.SearchResult;
const Anim = anim.Anim;
const log = std.log.scoped(.start_menu);
const panel = @import("panel.zig");
const slide_distance = panel.slide_distance;
const State = panel.State;
const Highlights = panel.Highlights;
const row_pitch = panel.row_pitch;
const updateIcon = panel.updateIcon;
const menuPalette = panel.menuPalette;
const StartMenu = @This();

pub const Mode = enum { start, launcher };
mode: Mode = .start,
card_indices: [5]usize = undefined,
card_count: usize = 0,
card_icons: [5]?u64 = @splat(null),
card_selection: ?usize = null,
server: *Server,
wlr_output: *wlr.Output,
buffer_node: *sn.Buffer,
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
    return createMode(server, wlr_output, .start);
}

pub fn createMode(server: *Server, wlr_output: *wlr.Output, mode: Mode) !*StartMenu {
    const menu = try gpa.create(StartMenu);
    errdefer gpa.destroy(menu);

    const buffer_node = try server.overlay_tree.createSceneBuffer(null);
    errdefer buffer_node.node.destroy();
    buffer_node.setFilterMode(.bilinear);

    menu.* = .{
        .server = server,
        .mode = mode,
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
    server.launcher_history.load(server);
    menu.model.history = &server.launcher_history;
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

pub fn requestWidgetRepaint(menu: *StartMenu) void {
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

const menu_anim = @import("menu_anim.zig");
pub const tick = menu_anim.tick;
pub const stepHighlights = menu_anim.stepHighlights;
pub const resultsScroll = menu_anim.resultsScroll;
pub const syncSelectionGlide = menu_anim.syncSelectionGlide;
pub const setHoverRow = menu_anim.setHoverRow;
pub const syncHoverRow = menu_anim.syncHoverRow;
pub const paintHighlights = menu_anim.paintHighlights;
pub const caretState = menu_anim.caretState;

const menu_tree = @import("menu_tree.zig");
pub const refreshCatalog = menu_tree.refreshCatalog;
pub const currentScrollOffset = menu_tree.currentScrollOffset;
pub const restoreScrollOffset = menu_tree.restoreScrollOffset;
pub const buildTree = menu_tree.buildTree;

// ---- Tree building ----

const menu_cards = @import("menu_cards.zig");
pub const pinButton = menu_cards.pinButton;
pub const buildCards = menu_cards.buildCards;
pub const onCardClick = menu_cards.onCardClick;

const menu_present = @import("menu_present.zig");
pub const wantedSize = menu_present.wantedSize;
pub const relayout = menu_present.relayout;
pub const iconsReady = menu_present.iconsReady;
pub const loadVisibleIcons = menu_present.loadVisibleIcons;
pub const prefetchAhead = menu_present.prefetchAhead;
pub const paintContent = menu_present.paintContent;
pub const applyPresentation = menu_present.applyPresentation;

// ---- Interaction & Actions ----

const menu_keys = @import("menu_keys.zig");
pub const activateSelected = menu_keys.activateSelected;
pub const activateResult = menu_keys.activateResult;
pub const handleKey = menu_keys.handleKey;
pub const keyRepeats = menu_keys.keyRepeats;
pub const editKey = menu_keys.editKey;
pub const syncQueryState = menu_keys.syncQueryState;
pub const navigateResults = menu_keys.navigateResults;
pub const ensureSelectedVisible = menu_keys.ensureSelectedVisible;
pub const onQueryEdited = menu_keys.onQueryEdited;
pub const onQueryChanged = menu_keys.onQueryChanged;

// ---- Callbacks ----

const menu_pointer = @import("menu_pointer.zig");
pub const onRowClick = menu_pointer.onRowClick;
pub const onCategoryAll = menu_pointer.onCategoryAll;
pub const onCategoryApps = menu_pointer.onCategoryApps;
pub const onSettingsButtonClick = menu_pointer.onSettingsButtonClick;
pub const onPowerButtonClick = menu_pointer.onPowerButtonClick;
pub const pointerMotion = menu_pointer.pointerMotion;
pub const pressedApp = menu_pointer.pressedApp;
pub const cancelPress = menu_pointer.cancelPress;
pub const pointerButtonDown = menu_pointer.pointerButtonDown;
pub const pointerLeave = menu_pointer.pointerLeave;
pub const pointerButtonUp = menu_pointer.pointerButtonUp;
pub const scrollWheel = menu_pointer.scrollWheel;
pub const containsPoint = menu_pointer.containsPoint;

// ---- Pointer entry points ----
