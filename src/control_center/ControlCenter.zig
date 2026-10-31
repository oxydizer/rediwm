//! The Settings window: its state, lifecycle and window plumbing. Building the
//! tree (`tree.zig`), keys (`keys.zig`), relayout (`relayout.zig`) and painting
//! (`paint.zig`) are beside it; `panel.zig` re-exports it as `panel.ControlCenter`.

const i18n = @import("i18n");
const std = @import("std");
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const pixman = @import("pixman");
const gpa = @import("../main.zig").gpa;
const anim = @import("ui").anim;
const panel_buffer = @import("../panel_buffer.zig");
const panel_paint = @import("../panel_paint.zig");
const panel_present = @import("../panel_present.zig");
const scene_data = @import("../scene_data.zig");
const PanelBuffer = panel_buffer.PanelBuffer;
const Server = @import("../Server.zig");
const Toplevel = @import("../Toplevel.zig");
const ui = @import("ui");
const layout = ui.layout;
const Widget = layout.Widget;
const display_section = @import("sections/display.zig");
const sound_section = @import("sections/sound.zig");
const appearance_section = @import("sections/appearance.zig");
const shortcut_section = @import("sections/shortcuts.zig");
const default_apps_section = @import("sections/default_apps.zig");
const portal_section = @import("sections/portals.zig");
const desktop_section = @import("sections/desktop.zig");
const input_section = @import("sections/input.zig");
const services_section = @import("sections/services.zig");
const printers_section = @import("sections/printers.zig");
const systemd = @import("../systemd.zig");
const users_section = @import("sections/users.zig");
const bluetooth_section = @import("sections/bluetooth.zig");
const region_section = @import("sections/region.zig");
const network_section = @import("sections/network.zig");
const log = std.log.scoped(.control_center);
const welcome_section = @import("welcome.zig");
const settings_search = @import("search.zig");
const theme = @import("ui").theme;
const Page = @import("search_index.zig").Page;
const panel = @import("panel.zig");
const default_width = panel.default_width;
const default_height = panel.default_height;
const page_labels = panel.page_labels;
const sidebarWidth = panel.sidebarWidth;
const page_names = panel.page_names;
const page_descriptions = panel.page_descriptions;
const page_icons = panel.page_icons;
const max_devices = panel.max_devices;
const palette = panel.palette;
const label = panel.label;
const sectionTitle = panel.sectionTitle;
const card = panel.card;
const restyle = panel.restyle;
const bodyColor = panel.bodyColor;
const pageClicked = panel.pageClicked;
const deviceClicked = panel.deviceClicked;
const brightnessChanged = panel.brightnessChanged;
const filesSingleClickChanged = panel.filesSingleClickChanged;
const ControlCenter = @This();

server: *Server,
/// The output settings opened on: the Displays page's default and the
/// frame clock for `tick`. Moved to another output if it goes away.
wlr_output: *wlr.Output,
toplevel: *Toplevel,
selected_output_name: [128]u8 = undefined,
selected_output_name_len: usize = 0,
buffer_node: *sn.Buffer,
node_data: scene_data.SceneData = undefined,

dirty: bool = true,
/// A resize waits for the next frame, so a drag relayouts once per frame.
layout_pending: bool = false,
/// Scale of the pixels on `buffer_node`; a new render scale repaints.
painted_scale: f32 = 0,
/// A wheel glide is in flight somewhere in `root` (`stepGlides`).
scroll_gliding: bool = false,
/// Scrollbar feedback still to play out (`stepBars`): `active` is a widening
/// or fade in flight, `deadline` the end of the hold after a scroll.
bars: ui.widgets.scroll_container.BarStep = .{},
/// Row-index positions outlive page rebuilds and follow resized rows.
nav_selection: anim.Anim = .{},
nav_selected_row: f32 = 0,
nav_hover: ui.hover_glide.Glide = .{},
background: panel_paint.Background = .{},
/// Content size; x/y stay 0 (see `screenBox`).
panel_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

is_welcome: bool = false,
welcome: welcome_section.State = .{},
page: Page = .general,
/// The page `root` was last built for; null until the first build, when
/// `root` is still undefined.
built_page: ?Page = null,
pending_page: ?Page = null,
refresh_pending: bool = false,
/// Configs replaced since the page was last built. The tree's strings (the
/// start logo's file name, a font family) point into their arenas, so each
/// is freed only once a rebuild has dropped those pointers (`retireConfig`).
retired_configs: std.ArrayList(@import("config").loader.Config) = .empty,
pointer_down: bool = false,
/// The window is activated; keys arrive only with `hasKeyboardFocus`.
focused: bool = false,
root: Widget = undefined,
root_children: [2]Widget = undefined,
body_children: [2]Widget = undefined,
search: settings_search.State = .{},
sidebar_children: [2]Widget = undefined,
nav_rows: [page_names.len]Widget = undefined,
nav_children: [page_names.len][2]Widget = undefined,
// Sized for the worst case across all pages: 2 (heading + description)
// plus the larger of the Input and Appearance pages.
content_children: [
    2 + @max(
        @typeInfo(@FieldType(input_section.Section, "row_storage")).array.len,
        @typeInfo(@FieldType(appearance_section.Section, "group_cards")).array.len,
    )
]Widget = undefined,
content_count: usize = 0,
general_volume: [2]Widget = undefined,
general_output: [2]Widget = undefined,
general_output_text: [2]Widget = undefined,
general_display: [2]Widget = undefined,
general_display_text: [2]Widget = undefined,
general_files: [2]Widget = undefined,
general_files_text: [2]Widget = undefined,
brightness_children: [2]Widget = undefined,
brightness_row: [3]Widget = undefined,
brightness_percent: [8]u8 = undefined,
device_title: [2]Widget = undefined,
device_rows: [max_devices]Widget = undefined,
device_children: [max_devices][2]Widget = undefined,
device_names: [max_devices][256]u8 = undefined,
device_name_lens: [max_devices]usize = undefined,
device_labels: [max_devices][128]u8 = undefined,
device_count: usize = 0,
display: display_section.Section = .{},
sound: sound_section.Section = .{},
appearance: appearance_section.Section = .{},
shortcuts: shortcut_section.Section = .{},
desktop: desktop_section.Section = .{},
region: region_section.Section = .{},
portals: portal_section.Section = .{},
default_apps: default_apps_section.Section = .{},
input: input_section.Section = .{},
users: users_section.Section = .{},
network: network_section.Section = .{},
bluetooth: bluetooth_section.Section = .{},
services: services_section.Section = .{},
printers: printers_section.Section = .{},
power_settings: @import("sections/power.zig").Section = .{},
systemd_client: ?*systemd.Client = null,

pub const min_width = 420;
pub const min_height = 320;

pub fn minimumWidth(cc: *const ControlCenter) i32 {
    return if (cc.page == .services) 1040 else min_width;
}

pub fn minimumHeight(cc: *const ControlCenter) i32 {
    return if (cc.page == .services) 640 else min_height;
}

/// Creates the settings window on `wlr_output` and maps it focused.
pub fn create(server: *Server, wlr_output: *wlr.Output) !*ControlCenter {
    return createWindow(server, wlr_output, false);
}

pub fn createWelcome(server: *Server, wlr_output: *wlr.Output) !*ControlCenter {
    return createWindow(server, wlr_output, true);
}

fn createWindow(server: *Server, wlr_output: *wlr.Output, welcome: bool) !*ControlCenter {
    const cc = try gpa.create(ControlCenter);
    errdefer gpa.destroy(cc);

    var width: i32 = if (welcome) 820 else default_width;
    var height: i32 = if (welcome) 800 else default_height;
    if (!welcome) if (@import("../window_sizes.zig").load(server.io, server.environ, Toplevel.settings_app_id)) |saved| {
        width = saved.width;
        height = saved.height;
    };
    var box: wlr.Box = undefined;
    server.output_layout.getBox(wlr_output, &box);
    if (box.width > 0 and box.height > 0) {
        // Leave room for the frame and the taskbar on small outputs.
        width = @min(width, box.width - 48);
        height = @min(height, box.height - 140);
    }
    width = @max(min_width, width);
    height = @max(min_height, height);

    const toplevel = try Toplevel.createShell(server, cc, width, height);
    toplevel.backend.shell.welcome = welcome;
    errdefer {
        toplevel.backend.shell.control_center = null;
        toplevel.destroy();
    }
    const buffer_node = try toplevel.scene_tree.tree().?.createSceneBuffer(null);
    // Window zoom and fractional scales change the destination rounding;
    // interpolate glyph coverage instead of dropping rows/columns.
    buffer_node.setFilterMode(.bilinear);

    cc.* = .{
        .server = server,
        .is_welcome = welcome,
        .wlr_output = wlr_output,
        .toplevel = toplevel,
        .buffer_node = buffer_node,
        .panel_box = .{ .x = 0, .y = 0, .width = width, .height = height },
    };
    const host_name = std.mem.span(wlr_output.name);
    cc.selected_output_name_len = @min(host_name.len, cc.selected_output_name.len);
    @memcpy(cc.selected_output_name[0..cc.selected_output_name_len], host_name[0..cc.selected_output_name_len]);
    cc.node_data = .{ .role = .{ .control_center = cc } };
    scene_data.SceneData.attach(&cc.node_data, &buffer_node.node);

    server.input.open_control_center = cc;
    if (!welcome) {
        cc.server.brightness.query(server);
        if (!server.greeter_mode) cc.systemd_client = server.getSystemd() catch null;
    }
    toplevel.mapShell();
    cc.relayout();
    return cc;
}

/// Closes the window: the content goes now, the frame animates out.
pub fn close(cc: *ControlCenter) void {
    cc.destroy();
}

pub fn destroy(cc: *ControlCenter) void {
    // Dispatcher holds raw pointers into this tree. Drop them before the
    // allocation goes away so a later reopen's first motion doesn't
    // switch on a freed WidgetKind tag.
    ui.input.reset();
    @import("../Keyboard.zig").forgetShellTarget(cc.server, cc);
    if (cc.server.input.open_control_center == cc) cc.server.input.open_control_center = null;
    cc.shortcuts.cancel();
    if (cc.systemd_client) |client| client.detachSettings();
    cc.welcome.deinit();
    cc.search.deinit();
    cc.input.arena.deinit();
    cc.services.deinit();
    cc.printers.deinit();
    cc.network.deinit();
    if (cc.page == .bluetooth) if (cc.server.bluetooth) |m| m.closed();
    cc.bluetooth.deinit();
    users_section.deinit(cc);
    cc.shortcuts.arena.deinit();
    cc.desktop.arena.deinit();
    cc.power_settings.arena.deinit();
    cc.region.deinit();
    cc.portals.arena.deinit();
    cc.default_apps.arena.deinit();
    cc.display.arena.deinit();
    appearance_section.deinit(&cc.appearance);
    cc.appearance.arena.deinit();
    cc.appearance.font_arena.deinit();
    @import("tree.zig").releaseRetired(cc);
    cc.retired_configs.deinit(gpa);
    cc.background.deinit(gpa);
    // The buffer node belongs to the window's tree and may outlive this
    // in the close animation's snapshot pass: unhook it from us first.
    cc.buffer_node.node.data = null;
    const toplevel = cc.toplevel;
    toplevel.backend.shell.control_center = null;
    toplevel.destroy();
    PanelBuffer.drainPool();
    if (cc.server.ipc) |ipc| ipc.wait_mgr.checkAll();
    gpa.destroy(cc);
}

/// The window was activated or deactivated (`Toplevel.setActivated`).
pub fn setActivated(cc: *ControlCenter, activated: bool) void {
    if (cc.focused == activated) return;
    cc.focused = activated;
    if (!activated) {
        cc.shortcuts.cancel();
        cc.requestWidgetRepaint();
    }
}

/// Keys go to settings only while its window is the active one and no
/// surface (layer shell, desktop, popup) took the keyboard since.
pub fn hasKeyboardFocus(cc: *const ControlCenter) bool {
    if (!cc.focused) return false;
    const toplevel = cc.toplevel;
    if (!toplevel.in_world or toplevel.minimized or !@import("../workspaces.zig").visible(toplevel)) return false;
    if (cc.server.world.toplevels.first() != toplevel) return false;
    if (cc.server.input.seat.keyboard_state.focused_surface != null) return false;
    if (cc.server.desktop) |desktop| if (desktop.keyboard_focused) return false;
    return true;
}

/// Raises and focuses the window, restoring it if minimized.
pub fn present(cc: *ControlCenter) void {
    const toplevel = cc.toplevel;
    if (toplevel.minimized) toplevel.restore() else cc.server.world.focus(toplevel);
    const Output = @import("../Output.zig");
    if (Output.fromWlr(cc.wlr_output)) |output| cc.server.world.navigateTo(toplevel, output);
    cc.server.scheduleFrames();
}

/// Frames come from `wlr_output`, or from any output while it is off
/// (see Output.handleFrame).
pub fn scheduleFrame(cc: *ControlCenter) void {
    if (cc.wlr_output.enabled) cc.wlr_output.scheduleFrame() else cc.server.scheduleFrames();
}

/// The window moves to `output` when its own output goes away.
pub fn adoptOutput(cc: *ControlCenter, output: *wlr.Output) void {
    cc.wlr_output = output;
    cc.refresh();
}

/// The content's on-screen box in layout coordinates, for IPC.
pub fn screenBox(cc: *const ControlCenter) wlr.Box {
    const toplevel = cc.toplevel;
    const origin = toplevel.frameWorld(@floatFromInt(toplevel.borderWidth()), @floatFromInt(toplevel.titlebarHeight()));
    const layout_origin = cc.server.world.toLayout(origin.x, origin.y);
    return .{
        .x = @intFromFloat(@round(layout_origin.x)),
        .y = @intFromFloat(@round(layout_origin.y)),
        .width = cc.panel_box.width,
        .height = cc.panel_box.height,
    };
}

/// Content-local coordinates of layout point (lx, ly).
pub fn localPoint(cc: *const ControlCenter, lx: f64, ly: f64) struct { x: f64, y: f64 } {
    const toplevel = cc.toplevel;
    const local = toplevel.frameLocal(lx, ly);
    return .{
        .x = local.x - @as(f64, @floatFromInt(toplevel.borderWidth())),
        .y = local.y - @as(f64, @floatFromInt(toplevel.titlebarHeight())),
    };
}

/// Nothing left to lay out, paint or glide.
pub fn settled(cc: *const ControlCenter) bool {
    return !cc.dirty and !cc.refresh_pending and !cc.layout_pending and !cc.scroll_gliding and !cc.bars.active and
        cc.nav_selection.settled(anim.nowMs()) and !cc.nav_hover.animating(anim.nowMs());
}

/// The window's content size changed (`Toplevel.requestSize`).
pub fn resize(cc: *ControlCenter, width: i32, height: i32) void {
    if (cc.panel_box.width == width and cc.panel_box.height == height) return;
    cc.panel_box.width = width;
    cc.panel_box.height = height;
    cc.layout_pending = true;
    cc.scheduleFrame();
}

const cc_tree = @import("tree.zig");
pub const buildTree = cc_tree.buildTree;
pub const append = cc_tree.append;
pub const retireConfig = cc_tree.retireConfig;
pub const buildGeneral = cc_tree.buildGeneral;
pub const buildDevices = cc_tree.buildDevices;

const cc_keys = @import("keys.zig");
pub const selectPage = cc_keys.selectPage;
pub const selectSearchPage = cc_keys.selectSearchPage;
pub const refresh = cc_keys.refresh;
pub const selectDisplayOutput = cc_keys.selectDisplayOutput;
pub const selectedDisplayOutput = cc_keys.selectedDisplayOutput;
pub const showingPage = cc_keys.showingPage;
pub const focusSearch = cc_keys.focusSearch;
pub const selectKey = cc_keys.selectKey;

const cc_relayout = @import("relayout.zig");
pub const applyOutputPatch = cc_relayout.applyOutputPatch;
pub const applyPending = cc_relayout.applyPending;
pub const rebuildTree = cc_relayout.rebuildTree;
pub const relayout = cc_relayout.relayout;
pub const layoutContent = cc_relayout.layoutContent;
pub const resizeNeedsTree = cc_relayout.resizeNeedsTree;
pub const resizeLayout = cc_relayout.resizeLayout;
pub const navIndex = cc_relayout.navIndex;

const cc_paint = @import("paint.zig");
pub const tick = cc_paint.tick;
pub const syncNavHover = cc_paint.syncNavHover;
pub const stepNavHighlights = cc_paint.stepNavHighlights;
pub const paintNavHighlights = cc_paint.paintNavHighlights;
pub const requestWidgetRepaint = cc_paint.requestWidgetRepaint;
pub const requestRepaint = cc_paint.requestRepaint;
pub const paintContent = cc_paint.paintContent;
