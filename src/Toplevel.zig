const std = @import("std");
const glass = @import("glass.zig");

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");
const sn = @import("node.zig");

const Decoration = @import("Decoration.zig");
const Server = @import("Server.zig");
const ControlCenter = @import("control_center/panel.zig").ControlCenter;
const chrome = @import("chrome.zig");
const geometry = @import("geometry.zig");
const tiling = @import("snap.zig");
const scene_data = @import("scene_data.zig");
const events = @import("ipc/events.zig");
const xdg = @import("xdg.zig");
const xwayland_surface = @import("xwayland_surface.zig");
const gpa = @import("main.zig").gpa;
const window_rules = @import("config").window_rules;
const anim = @import("ui").anim;
const toplevel_create = @import("toplevel/create.zig");
const Child = @import("session/child.zig");
const toplevel_info = @import("toplevel/info.zig");
const toplevel_focus_close = @import("toplevel/focus_close.zig");
const toplevel_configure = @import("toplevel/configure.zig");
const toplevel_position = @import("toplevel/position.zig");
const toplevel_motion = @import("toplevel/motion.zig");
const toplevel_open_close = @import("toplevel/open_close.zig");
const toplevel_chrome_metrics = @import("toplevel/chrome_metrics.zig");
const toplevel_zoom = @import("toplevel/zoom.zig");
const toplevel_lifecycle = @import("toplevel/lifecycle.zig");
const toplevel_chrome_sync = @import("toplevel/chrome_sync.zig");
const toplevel_appearance = @import("toplevel/appearance.zig");
const toplevel_chrome_actions = @import("toplevel/chrome_actions.zig");
const toplevel_placement = @import("toplevel/placement.zig");
const toplevel_layout = @import("toplevel/layout.zig");
const toplevel_tabs = @import("toplevel/tabs.zig");

const Toplevel = @This();

const log = std.log.scoped(.toplevel);

pub const Placeholder = struct {
    desktop_id: [:0]const u8,
    name: [:0]const u8,
    app_id: [:0]const u8,
    startup_wm_class: ?[:0]const u8 = null,
    icon: ?[:0]const u8 = null,
    token: ?[:0]const u8 = null,
    pid: ?i32 = null,
    client_width: i32,
    client_height: i32,
    body_rect: *sn.Rect,
    delay_timer: ?*wl.EventSource = null,

    timeout_timer: ?*wl.EventSource = null,
    /// Watches the launched process; the services manager owns its status.
    child: ?*Child = null,
    launch_time_ms: i64,
    matched: bool = false,
    cancelled: bool = false,

    pub fn setPid(self: *Placeholder, toplevel: *Toplevel, pid: i32) void {
        self.pid = pid;
        if (pid <= 0 or self.child != null) return;
        self.child = Child.observe(gpa, toplevel.server.wl_server.getEventLoop(), pid, toplevel, handleChildExit) catch null;
    }

    pub fn deinit(self: *Placeholder) void {
        if (self.delay_timer) |t| {
            t.remove();
            self.delay_timer = null;
        }
        if (self.timeout_timer) |t| {
            t.remove();
            self.timeout_timer = null;
        }
        if (self.child) |child| child.cancel();
        gpa.free(self.desktop_id);
        gpa.free(self.name);
        gpa.free(self.app_id);
        if (self.startup_wm_class) |wmc| gpa.free(wmc);
        if (self.icon) |ico| gpa.free(ico);
        if (self.token) |tok| gpa.free(tok);
    }

    pub fn cancel(self: *Placeholder, toplevel: *Toplevel) void {
        if (self.cancelled or self.matched) return;
        self.cancelled = true;
        if (self.pid) |p| {
            if (p > 0) {
                _ = std.posix.kill(p, std.posix.SIG.TERM) catch {};
            }
        }
        if (toplevel.server.ipc) |ipc| {
            events.onLaunchTimeout(ipc, self.desktop_id, self.pid);
        }
        toplevel.destroyNow();
    }
};

/// Protocol-specific window backend. Shared chrome, taskbar, world geometry,
/// and IPC talk to this tagged union rather than an xdg pointer.
pub const Backend = union(enum) {
    xdg: xdg,
    xwayland: xwayland_surface,
    placeholder: Placeholder,
    shell: Shell,
};

/// A window whose content the compositor draws itself (Settings or Welcome).
/// It has no wl_surface: keyboard focus is "first in the stack with no seat
/// focus", and pointer input reaches the content through its own scene data.
pub const Shell = struct {
    /// Cleared before the window is destroyed; the content owns this window.
    control_center: ?*ControlCenter,
    /// Identity outlives the content, including unmap and the close animation.
    welcome: bool = false,
    client_width: i32,
    client_height: i32,
};

pub const settings_title: [:0]const u8 = "RediWM Settings";
pub const settings_app_id: [:0]const u8 = "rediwm-settings";
pub const welcome_app_id: [:0]const u8 = "rediwm-welcome";

/// Token returned by `requestSize`. xdg waits on a configure serial; X11
/// waits on a surface commit. Never invent an xdg serial for X11.
pub const ConfigureWait = union(enum) {
    none,
    xdg_serial: u32,
    x11_commit,
};

server: *Server,
link: wl.list.Link = undefined,
backend: Backend,
// The frame tree owns compositor-drawn chrome and the client surface tree.
// Keeping it separate lets the client remain entirely undecorated.
frame_tree: *sn.Tree,
shadow_tree: *sn.Tree,
// The analytic shadow's leaf: no buffer, only footprint, opacity and input.
shadow_node: *sn.Buffer,
resize_grab: *sn.Buffer,
glass_effect: ?*glass.Effect = null,
// Backdrop beneath the themed app body; opaque content masks it, leaving only
// the sidebar frosted. The bufferless target owns geometry, never pixels/input.
sidebar_glass_target: ?*sn.Buffer = null,
sidebar_glass_effect: ?*glass.Effect = null,
titlebar_buffer: *sn.Buffer,
// Body under the border ring beside and below the client (left, right, bottom).
frame_fills: [3]*sn.Rect,
corner_accents: @import("toplevel/corner_accents.zig").State = .{},
// The outline of a window that draws its own decorations.
border_rects: [4]*sn.Rect,
content_tree: *sn.Tree,
/// What the client draws into: the surface tree of an xdg or X11 surface, or a
/// bare placeholder tree while there is none.
scene_tree: *sn.Node,
decoration: ?*Decoration = null,
kde_decoration: ?*@import("KdeDecoration.zig") = null,
frame_data: scene_data.SceneData = undefined,
chrome_data: scene_data.SceneData = undefined,

id: u64 = 0,
workspace_id: u8 = 0,
workspace_order: u64 = 0,
workspace_generation: u64 = 0,
canvas_state: ?@import("workspaces.zig").CanvasWindow = null,
// Hidden tabs stay mapped; this is independent of client minimization.
tab_group: u64 = 0,
tab_identity: []const u8 = "",
tab_pending_group: u64 = 0,
tab_hidden: bool = false,
tab_restore: ?RestoreGeometry = null,
tab_notice: @import("window_tabs.zig").Notice = .none,
tab_first: usize = 0,
tab_hover: u64 = 0,

/// Digest of the last window record sent to IPC subscribers; most commits
/// only change pixels, and `events.onWindowChanged` skips those.
ipc_window_digest: ?u64 = null,

/// Published while mapped, xdg-shell-backed only (docs/screen-sharing.md
/// stage 3 leaves Xwayland windows unlisted until their unmanaged
/// menus/tooltips have a tested ownership rule). Created in `handleMapped`,
/// kept in sync in `handleIdentityChanged`, destroyed in `handleUnmapped`.
foreign_handle: ?*wlr.ExtForeignToplevelHandleV1 = null,
/// wlr-foreign-toplevel-management handle for docks and window switchers,
/// every backend but placeholders, while mapped.
wlr_foreign: ?*@import("foreign_toplevel.zig").Handle = null,

/// Top-left of the authoritative frame in world coordinates. Panning and
/// desktop zoom leave these unchanged; window zoom repositions the frame to
/// preserve its pointer anchor. Client dimensions remain unscaled.
x: i32 = 0,
y: i32 = 0,
render_scale: f32 = 1,
chrome_width: i32 = 0,
chrome_height: i32 = 0,
/// Compositor activation is immediate; client protocol acknowledgements lag.
activated: bool = false,
zoom_index: usize = 0,
zoom_scale: f64 = 1.0,
/// Presentation-only focus boost. Neither saved geometry nor zoom_index changes.
zoom_boost: anim.Anim = .{},
zoom_boost_value: f64 = 0,
/// Drag lift is presentation only; the grab point stays fixed under the pointer.
drag_lift: anim.Anim = .{ .from = 1, .to = 1 },
drag_lift_value: f64 = 1,
drag_lift_anchor: geometry.Vec2 = .{ .x = 0, .y = 0 },
zoom_anim: @import("ui").anim.Anim = .{ .from = 1, .to = 1 },
zoom_anchor: geometry.Vec2 = .{ .x = 0, .y = 0 },
zoom_local: geometry.Vec2 = .{ .x = 0, .y = 0 },
peek_mix: @import("ui").anim.Anim = .{ .property = .opacity },
peek_level: @import("ui").anim.Anim = .{ .from = 1, .to = 1, .property = .opacity },
map_motion: anim.Anim = .{ .from = 1, .to = 1 },
map_opacity: anim.Anim = .{ .from = 1, .to = 1, .property = .opacity },
/// Set while a window launched from the dock grows out of its icon (a
/// layout-space box): `map_motion` then carries the frame from that box to
/// its place. Presentation only, like `dodge_x`; input follows what is drawn.
launch_origin: ?LaunchOrigin = null,
move_x: anim.Anim = .{},
move_y: anim.Anim = .{},
/// Temporary displacement of the frame in world units (`input/drag_dodge.zig`).
/// Presentation only: `x`/`y`, the canvas bounds, IPC and saved layouts never
/// see it, and it is never folded into `move_x`/`move_y`.
dodge_x: anim.Anim = .{},
dodge_y: anim.Anim = .{},
/// Workspace switch (`workspaces.zig`): an offset in world units and a fade,
/// presentation only like `dodge_*`. A window whose workspace was hidden keeps
/// its frame shown, inert, until they settle (`switch_leaving`).
switch_x: anim.Anim = .{},
switch_y: anim.Anim = .{},
switch_fade: anim.Anim = .{ .from = 1, .to = 1, .property = .opacity },
switch_leaving: bool = false,
size_w: anim.Anim = .{},
size_h: anim.Anim = .{},
/// The size request `size_w`/`size_h` ease toward. Once the client has answered
/// it, a settled animation gives way to the size the client took (one that
/// cannot fit is never clipped to a frame it refused).
size_wait: ConfigureWait = .none,
// Last clip handed to `wlr_scene_subsurface_tree_set_clip`, so an unchanged
// clip is not re-applied. `applySizeClip` runs from `syncChrome`, i.e. on
// every client commit, and wlroots walks the whole subsurface tree on each
// call; once a window's size has settled that call is pure per-commit waste.
last_clip: ?wlr.Box = null,
last_clip_valid: bool = false,
close_snapshot: ?*sn.Tree = null,
closing: bool = false,
in_closing_list: bool = false,
backend_gone: bool = false,
closing_link: wl.list.Link = undefined,
hovered: bool = false,
hovered_control: ?chrome.ControlKind = null,
hover_anim: anim.Anim = .{},
// Window-button hover chip: slot coordinate (chrome.controlSlot) and opacity.
chip_pos: anim.Anim = .{},
chip_alpha: anim.Anim = .{ .property = .opacity },
last_painted_hover: f32 = 0,
/// Edge highlight near the pointer (`setGlow`): `glow_anim` is its strength,
/// eased toward `glow_near`, and (`glow_x`, `glow_y`) the point of the frame's
/// edge it is centred on, in frame units.
glow_anim: anim.Anim = .{ .property = .opacity },
glow_near: f32 = 0,
glow_x: f32 = 0,
glow_y: f32 = 0,
/// The window opacity the border colour of the shape was last given, so a
/// hover or focus repaint keeps the ring as faded as the body.
shape_opacity: f32 = 1,
/// How dimmed the window is while it is not the focus (`applyDim`): 1 is all of
/// `inactive_dim_amount`, eased with focus. `dim_shown` is the fraction of
/// brightness and colour the output pass was last told to take away.
dim_anim: anim.Anim = .{ .property = .opacity },
dim_shown: f32 = 0,
// Inputs that produced the buffers currently attached to the scene nodes.
// syncChrome / syncShadow skip a re-raster when these still match.
last_titlebar: ?chrome.TitlebarMemo = null,
cached_titlebar: ?*chrome.ChromeBuffer = null,
last_shadow: ?chrome.ShadowMemo = null,
// xdg-shell has no minimized state of its own; this is purely a
// compositor-side hint that hides the frame while the client stays mapped.
minimized: bool = false,
needs_attention: bool = false,
maximized: bool = false,
fullscreen: bool = false,
in_world: bool = false,
placed: bool = false,
placeholder_source: ?*Toplevel = null,
rules_resolved: bool = false,
resolved_before_app_id: bool = false,
open_rules: window_rules.OpenRules = .{},
live_rules: window_rules.LiveRules = .{},
matched_rules: std.StaticBitSet(window_rules.max_rules) = std.StaticBitSet(window_rules.max_rules).empty,
maximize_restore: ?RestoreGeometry = null,
fullscreen_restore: ?RestoreGeometry = null,
maximize_target: ?RestoreGeometry = null,
fullscreen_target: ?RestoreGeometry = null,
// Automatic rectangles are independent of manual half/quarter tiles.
// Explicit floating placement opts a member out; overflow can retry later.
auto_target: ?RestoreGeometry = null,
auto_restore: ?RestoreGeometry = null,
auto_float: bool = false,
auto_float_override: ?bool = null,
auto_seen: ?@import("auto_tiling.zig").State = null,
auto_reinsert: ?@import("auto_layout.zig").Placement = null,
/// The window that had focus on this one's workspace when it joined it: a new
/// tile splits that window's tile. Cleared once the window is in the tree.
auto_anchor: ?u64 = null,
tab_resume_group: u64 = 0,
tab_resume_restore: ?RestoreGeometry = null,
// Manual half/quarter tile and the floating geometry to return to.
tile: ?tiling.Tile = null,
tile_target: ?RestoreGeometry = null,
tile_restore: ?RestoreGeometry = null,
pending_restore: ?RestoreGeometry = null,
forced_geometry_timer: ?*wl.EventSource = null,
reconnect_output: [128]u8 = undefined,
reconnect_output_len: usize = 0,
reconnect_expected_x: i32 = 0,
reconnect_expected_y: i32 = 0,
reconnect_offset_x: i32 = 0,
reconnect_offset_y: i32 = 0,
reconnect_maximized: bool = false,
reconnect_fullscreen: bool = false,
reconnect_tile: ?tiling.Tile = null,

pub const RestoreGeometry = @import("undo.zig").Geometry;

pub const ChromeNodes = struct {
    frame_tree: *sn.Tree,
    shadow_tree: *sn.Tree,
    shadow_node: *sn.Buffer,
    resize_grab: *sn.Buffer,
    glass_effect: ?*glass.Effect,
    titlebar_buffer: *sn.Buffer,
    frame_fills: [3]*sn.Rect,
    border_rects: [4]*sn.Rect,
    content_tree: *sn.Tree,
};

// toplevel/create.zig
pub const createChromeNodes = toplevel_create.createChromeNodes;
pub const finishCreate = toplevel_create.finishCreate;
pub const create = toplevel_create.create;
pub const createXwayland = toplevel_create.createXwayland;
pub const handleDelayTimeout = toplevel_create.handleDelayTimeout;
pub const handleLaunchTimeout = toplevel_create.handleLaunchTimeout;
pub const handleChildExit = toplevel_create.handleChildExit;
pub const createPlaceholder = toplevel_create.createPlaceholder;
pub const createShell = toplevel_create.createShell;
pub const mapShell = toplevel_create.mapShell;
pub const findMatchingPlaceholder = toplevel_create.findMatchingPlaceholder;
pub const attachXwaylandScene = toplevel_create.attachXwaylandScene;
pub const detachXwaylandScene = toplevel_create.detachXwaylandScene;
pub const replaceDestroyedXwaylandScene = toplevel_create.replaceDestroyedXwaylandScene;

// toplevel/info.zig
pub const fromSurface = toplevel_info.fromSurface;
pub const surface = toplevel_info.surface;
pub const title = toplevel_info.title;
pub const titleOrNull = toplevel_info.titleOrNull;
pub const titlePtr = toplevel_info.titlePtr;
pub const appId = toplevel_info.appId;
pub const appIdOrNull = toplevel_info.appIdOrNull;
pub const appIdPtr = toplevel_info.appIdPtr;
pub const surfaceScale = toplevel_info.surfaceScale;
pub const clientSurfaceGeometry = toplevel_info.clientSurfaceGeometry;
pub const clientGeometry = toplevel_info.clientGeometry;
pub const clientPid = toplevel_info.clientPid;
pub const waylandClient = toplevel_info.waylandClient;
pub const sandboxInfo = toplevel_info.sandboxInfo;
pub const setUrgent = toplevel_info.setUrgent;
pub const isMapped = toplevel_info.isMapped;
pub const isMaximized = toplevel_info.isMaximized;
pub const isFullscreen = toplevel_info.isFullscreen;
pub const isInitialized = toplevel_info.isInitialized;
pub const parentWindow = toplevel_info.parentWindow;
pub const sizeConstraints = toplevel_info.sizeConstraints;

// toplevel/focus_close.zig
pub const raise = toplevel_focus_close.raise;
pub const syncXwaylandStack = toplevel_focus_close.syncXwaylandStack;
pub const setActivated = toplevel_focus_close.setActivated;
pub const syncForeign = toplevel_focus_close.syncForeign;
pub const sendClose = toplevel_focus_close.sendClose;
pub const forceClose = toplevel_focus_close.forceClose;

// toplevel/configure.zig
pub const setResizing = toplevel_configure.setResizing;
pub const requestSize = toplevel_configure.requestSize;
pub const configureCompleted = toplevel_configure.configureCompleted;
pub const scheduledSerial = toplevel_configure.scheduledSerial;
pub const ackSerial = toplevel_configure.ackSerial;
pub const backendName = toplevel_configure.backendName;
pub const x11Class = toplevel_configure.x11Class;
pub const x11Instance = toplevel_configure.x11Instance;
pub const owner = toplevel_configure.owner;
pub const cornerRadius = toplevel_configure.cornerRadius;
pub const shapePolygon = toplevel_configure.shapePolygon;
pub const shapeKey = toplevel_configure.shapeKey;
pub const controlInsets = toplevel_configure.controlInsets;
pub const ownsSurface = toplevel_configure.ownsSurface;
pub const attachSceneData = toplevel_configure.attachSceneData;

// toplevel/position.zig
pub const setPosition = toplevel_position.setPosition;
pub const moveToOutput = toplevel_position.moveToOutput;
pub const moveFromUsableToOutput = toplevel_position.moveFromUsableToOutput;
pub const rememberOutputDisconnect = toplevel_position.rememberOutputDisconnect;
pub const markOutputDisconnectPosition = toplevel_position.markOutputDisconnectPosition;
pub const clearOutputDisconnect = toplevel_position.clearOutputDisconnect;
pub const restoreOutputDisconnect = toplevel_position.restoreOutputDisconnect;
pub const setPositionAnimated = toplevel_position.setPositionAnimated;
pub const commitPosition = toplevel_position.commitPosition;
pub const logicalWidth = toplevel_position.logicalWidth;
pub const logicalHeight = toplevel_position.logicalHeight;
pub const visualX = toplevel_position.visualX;
pub const visualY = toplevel_position.visualY;

// toplevel/motion.zig
pub const finishMoveAnimation = toplevel_motion.finishMoveAnimation;
pub const finishSizeAnimation = toplevel_motion.finishSizeAnimation;
pub const requestSizeAnimated = toplevel_motion.requestSizeAnimated;
pub const animateChromeSize = toplevel_motion.animateChromeSize;
pub const chromeSizeForClient = toplevel_motion.chromeSizeForClient;
pub const ignoreCloseInput = toplevel_motion.ignoreCloseInput;
pub const applyVisualTransform = toplevel_motion.applyVisualTransform;
pub const launchGrowth = toplevel_motion.launchGrowth;
pub const dragLiftOffset = toplevel_motion.dragLiftOffset;
pub const tickDragLift = toplevel_motion.tickDragLift;
pub const clearDragLift = toplevel_motion.clearDragLift;
pub const animOffset = toplevel_motion.animOffset;
pub const setDodge = toplevel_motion.setDodge;
pub const clearDodge = toplevel_motion.clearDodge;
pub const tickDodge = toplevel_motion.tickDodge;
pub const switchIn = toplevel_motion.switchIn;
pub const switchOut = toplevel_motion.switchOut;
pub const retargetSwitch = toplevel_motion.retargetSwitch;
pub const setSwitchLeaving = toplevel_motion.setSwitchLeaving;
pub const finishSwitch = toplevel_motion.finishSwitch;
pub const tickSwitch = toplevel_motion.tickSwitch;
pub const tickMove = toplevel_motion.tickMove;
pub const tickSize = toplevel_motion.tickSize;
pub const tickMap = toplevel_motion.tickMap;
pub const closingFinished = toplevel_motion.closingFinished;
pub const finishClose = toplevel_motion.finishClose;

pub const LaunchOrigin = @import("launch_feedback.zig").Origin;

// toplevel/open_close.zig
pub const setSizeClip = toplevel_open_close.setSizeClip;
pub const applySizeClip = toplevel_open_close.applySizeClip;
pub const beginOpenAnimation = toplevel_open_close.beginOpenAnimation;
pub const beginCloseAnimation = toplevel_open_close.beginCloseAnimation;
pub const copyCloseBuffer = toplevel_open_close.copyCloseBuffer;
pub const snapshotClient = toplevel_open_close.snapshotClient;
pub const cancelClose = toplevel_open_close.cancelClose;

pub const CloseSnapshot = struct {
    tree: *sn.Tree,
    count: u32 = 0,
    ok: bool = true,
};

// toplevel/chrome_metrics.zig
pub const hasServerDecorations = toplevel_chrome_metrics.hasServerDecorations;
pub const chromeDensity = toplevel_chrome_metrics.chromeDensity;
pub const titlebarHeight = toplevel_chrome_metrics.titlebarHeight;
pub const borderWidth = toplevel_chrome_metrics.borderWidth;
pub const hasWorkspaceFocusBorder = toplevel_chrome_metrics.hasWorkspaceFocusBorder;
pub const borderColor = toplevel_chrome_metrics.borderColor;
pub const footerHeight = toplevel_chrome_metrics.footerHeight;
pub const frameLocal = toplevel_chrome_metrics.frameLocal;
pub const frameWorld = toplevel_chrome_metrics.frameWorld;

// toplevel/zoom.zig
pub const zoom = toplevel_zoom.zoom;
pub const worldScale = toplevel_zoom.worldScale;
pub const setZoomBoost = toplevel_zoom.setZoomBoost;
pub const tickZoomBoost = toplevel_zoom.tickZoomBoost;
pub const clearZoomBoost = toplevel_zoom.clearZoomBoost;
pub const takeZoomBoost = toplevel_zoom.takeZoomBoost;
pub const cameraFocusOpacity = toplevel_zoom.cameraFocusOpacity;
pub const finishZoomAnimation = toplevel_zoom.finishZoomAnimation;
pub const tickZoom = toplevel_zoom.tickZoom;
pub const setZoom = toplevel_zoom.setZoom;
pub const setZoomAnimated = toplevel_zoom.setZoomAnimated;
pub const positionDuringResize = toplevel_zoom.positionDuringResize;

// toplevel/lifecycle.zig
pub const handleSurfaceCommit = toplevel_lifecycle.handleSurfaceCommit;
pub const handleMapped = toplevel_lifecycle.handleMapped;
pub const handleUnmapped = toplevel_lifecycle.handleUnmapped;
pub const destroy = toplevel_lifecycle.destroy;
pub const tryDeferDestroy = toplevel_lifecycle.tryDeferDestroy;
pub const destroyNow = toplevel_lifecycle.destroyNow;

// toplevel/info.zig
pub const insideFrame = toplevel_info.insideFrame;
pub const isResizing = toplevel_info.isResizing;
pub const isGeometrySettled = toplevel_info.isGeometrySettled;
pub const chromeAcceptsInput = toplevel_info.chromeAcceptsInput;

// toplevel/chrome_sync.zig
pub const refreshTheme = toplevel_chrome_sync.refreshTheme;
pub const updateHeldIcon = toplevel_chrome_sync.updateHeldIcon;
pub const releaseIcon = toplevel_chrome_sync.releaseIcon;
pub const syncOutputScale = toplevel_chrome_sync.syncOutputScale;
pub const clearChromeCache = toplevel_chrome_sync.clearChromeCache;
pub const syncChrome = toplevel_chrome_sync.syncChrome;
pub const syncSidebarGlass = toplevel_chrome_sync.syncSidebarGlass;
pub const stretchesTitlebar = toplevel_chrome_sync.stretchesTitlebar;
pub const visualChromeSize = toplevel_chrome_sync.visualChromeSize;
pub const syncShadow = toplevel_chrome_sync.syncShadow;
pub const syncResizeGrab = toplevel_chrome_sync.syncResizeGrab;
pub const applyShape = toplevel_chrome_sync.applyShape;
pub const syncCornerAccents = @import("toplevel/corner_accents.zig").syncCornerAccents;
pub const tickCornerAccents = @import("toplevel/corner_accents.zig").tickCornerAccents;
pub const wakeCornerAccents = @import("toplevel/corner_accents.zig").wakeCornerAccents;
pub const syncBorders = toplevel_chrome_sync.syncBorders;

/// How far an easing frame stretches its titlebar raster before rastering anew.
pub const titlebar_stretch: f32 = 0.12;

// toplevel/appearance.zig
pub const detachInput = toplevel_appearance.detachInput;
pub const effectiveOpacity = toplevel_appearance.effectiveOpacity;
pub const dimTarget = toplevel_appearance.dimTarget;
pub const applyDim = toplevel_appearance.applyDim;
pub const dimAnimating = toplevel_appearance.dimAnimating;
pub const applyOpacity = toplevel_appearance.applyOpacity;
pub const applyHover = toplevel_appearance.applyHover;
pub const retargetChip = toplevel_appearance.retargetChip;
pub const resetChip = toplevel_appearance.resetChip;
pub const glowProbe = toplevel_appearance.glowProbe;
pub const setGlow = toplevel_appearance.setGlow;
pub const tickGlow = toplevel_appearance.tickGlow;
pub const tickHover = toplevel_appearance.tickHover;
pub const nowMs = toplevel_appearance.nowMs;

// Roughly one button pitch in logical px: converts the glide's pixel quantum
// into slot units.
pub const chip_slot_px: f32 = 32;

// toplevel/chrome_actions.zig
pub const controlAt = toplevel_chrome_actions.controlAt;
pub const handleChromeClick = toplevel_chrome_actions.handleChromeClick;
pub const minimize = toplevel_chrome_actions.minimize;
pub const restore = toplevel_chrome_actions.restore;

// toplevel/placement.zig
pub const rememberGeometry = toplevel_placement.rememberGeometry;
pub const restoreGeometryNow = toplevel_placement.restoreGeometryNow;
pub const restoreGeometry = toplevel_placement.restoreGeometry;
pub const forcedGeometry = toplevel_placement.forcedGeometry;
pub const applyForcedGeometry = toplevel_placement.applyForcedGeometry;
pub const scheduleForcedGeometry = toplevel_placement.scheduleForcedGeometry;
pub const toggleMaximize = toplevel_placement.toggleMaximize;
pub const currentIdentity = toplevel_placement.currentIdentity;
pub const resolveTargetOutput = toplevel_placement.resolveTargetOutput;
pub const currentOutput = toplevel_placement.currentOutput;
pub const resolveInitialRules = toplevel_placement.resolveInitialRules;
pub const pickInitialPlacement = toplevel_placement.pickInitialPlacement;
pub const setupInitialRestoreGeometry = toplevel_placement.setupInitialRestoreGeometry;
pub const configureInitialXdgState = toplevel_placement.configureInitialXdgState;

// toplevel/zoom.zig
pub const setZoomOrigin = toplevel_zoom.setZoomOrigin;

// toplevel/layout.zig
pub const setMaximizedOn = toplevel_layout.setMaximizedOn;
pub const setFullscreenOn = toplevel_layout.setFullscreenOn;
pub const setMaximized = toplevel_layout.setMaximized;
pub const layout = toplevel_layout.layout;
pub const floatingGeometry = toplevel_layout.floatingGeometry;
pub const setTiled = toplevel_layout.setTiled;
pub const setTiledOn = toplevel_layout.setTiledOn;
pub const setAutoTile = toplevel_layout.setAutoTile;
pub const clearAutoTile = toplevel_layout.clearAutoTile;
pub const untile = toplevel_layout.untile;
pub const leaveLayout = toplevel_layout.leaveLayout;
pub const applyLayout = toplevel_layout.applyLayout;
pub const snapTo = toplevel_layout.snapTo;
pub const clearMaximized = toplevel_layout.clearMaximized;
pub const dropTile = toplevel_layout.dropTile;
pub const sendTiled = toplevel_layout.sendTiled;
pub const notifyLayoutChanged = toplevel_layout.notifyLayoutChanged;
pub const setFullscreen = toplevel_layout.setFullscreen;
pub const toggleFullscreen = toplevel_layout.toggleFullscreen;
pub const beginMove = toplevel_layout.beginMove;

// toplevel/lifecycle.zig
pub const handleIdentityChanged = toplevel_lifecycle.handleIdentityChanged;

// toplevel/tabs.zig
pub const tabStrip = toplevel_tabs.tabStrip;
pub const tabAt = toplevel_tabs.tabAt;
pub const hoverTab = toplevel_tabs.hoverTab;
pub const stepTab = toplevel_tabs.stepTab;
