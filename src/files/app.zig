const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const scrollbar = @import("ui").widgets.scrollbar;
const splitter = @import("ui").widgets.splitter;
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const platform = @import("platform");
const worker_mod = @import("worker.zig");
const history_mod = @import("history.zig");
const ops_mod = @import("ops.zig");
const dirsize = @import("dirsize.zig");
const thumbs_mod = @import("thumbs.zig");
const thumb_decode = @import("thumb_decode.zig");
const volumes_mod = @import("volumes.zig");
const theme = @import("../icon_theme.zig");
const Allocator = std.mem.Allocator;
const header = @import("header.zig");
const hover_glide = @import("ui").hover_glide;
const Preferences = @import("preferences.zig").Preferences;
const pins_mod = @import("pins.zig");
const chooser_mod = @import("chooser.zig");
const Editor = @import("editor.zig").Editor;
const app_hover = @import("app_hover.zig");
const app_listing = @import("app_listing.zig");
const app_dialogs = @import("app_dialogs.zig");
const app_fileops = @import("app_fileops.zig");
const app_chooser = @import("app_chooser.zig");
const app_layout = @import("app_layout.zig");
const app_folder_size = @import("app_folder_size.zig");
const app_places = @import("app_places.zig");
const app_sidebar_paint = @import("app_sidebar_paint.zig");
const app_scroll = @import("app_scroll.zig");
const app_torrents = @import("app_torrents.zig");
const app_torrent_rows = @import("app_torrent_rows.zig");
const app_git_sidebar = @import("app_git_sidebar.zig");
const app_opening = @import("app_opening.zig");
const app_pointer = @import("app_pointer.zig");
const app_keyboard = @import("app_keyboard.zig");
const app_menu = @import("app_menu.zig");
const app_paint = @import("app_paint.zig");
const app_items = @import("app_items.zig");
const app_model = @import("app_model.zig");
const app_draw = @import("app_draw.zig");
const app_terminal = @import("app_terminal.zig");
const DeviceOp = app_model.DeviceOp;
const MenuKind = app_model.MenuKind;
const Sort = app_model.Sort;
pub const SizeState = app_model.SizeState;
const SelectionFade = app_model.SelectionFade;
const ToolbarHover = app_model.ToolbarHover;
pub const ViewItem = app_model.ViewItem;
const ThumbRequest = app_model.ThumbRequest;
pub const Focus = app_model.Focus;
pub const DialogKind = app_model.DialogKind;
pub const Dialog = app_model.Dialog;
pub const formatSize = app_draw.formatSize;
pub const nowMs = app_draw.nowMs;
pub const setSource = app_draw.setSource;
pub const roundedRect = app_draw.roundedRect;
pub const drawSpinner = app_draw.drawSpinner;
pub const clipDamage = app_draw.clipDamage;
pub const drawEllipsis = app_draw.drawEllipsis;
pub const drawText = app_draw.drawText;
pub const FontMetrics = app_draw.FontMetrics;
pub const fontMetrics = app_draw.fontMetrics;
pub const measureText = app_draw.measureText;
pub const App = struct {
    terminal: app_terminal.Drawer = .{},
    closed: bool = false,
    torrents: @import("torrents.zig").Client = .{},
    transfer_view: app_torrents.View = .{},
    children: platform.child.Set = .{},
    chooser: ?chooser_mod.Options = null,
    filename: Editor = .{},
    chooser_done: bool = false,
    chooser_accepted: bool = false,
    chooser_paths: std.ArrayList([]const u8) = .empty,
    chooser_choices: std.ArrayList([]const u8) = .empty,
    chooser_filter_labels: std.ArrayList([]const u8) = .empty,
    overwrite_pending: bool = false,
    chooser_choice_index: usize = 0,
    allocator: Allocator,
    io: std.Io,
    environ: std.process.Environ,
    theme_cfg: theme.Config,
    worker: *worker_mod.Worker,
    history: history_mod.History,
    home_dir: []const u8,

    trash_dir: ?[]const u8 = null,
    preferences_path: ?[]u8 = null,
    restore_view: bool = false,

    // Read end for a preview's user-authorized return-focus token.
    preview_return_fd: ?c_int = null,
    editor_path: ?[:0]u8 = null,

    // Window dimensions
    w: i32 = 960,
    h: i32 = 540,
    dirty: bool = true,
    paint_damage: ?header.Rect = null,
    scale: i32 = 1,

    // Items and state
    items: std.ArrayList(ViewItem) = .empty,
    items_arena: std.heap.ArenaAllocator,
    active_request_id: u64 = 1,
    loading: bool = true,
    /// When `loading` last became true. Most folders list instantly, so the
    /// "Scanning folder..." notice waits `scan_notice_delay_ms` from here.
    loading_since: i64 = 0,
    scan_notice_shown: bool = false,
    /// A file passed at startup is selected once its parent folder is listed.
    initial_selection: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    show_hidden: bool = false,
    list_view: bool = false,
    non_git_list_view: ?bool = null,
    git_expanded: bool = true,
    /// The "Git View" checkbox: off shows a repository like any other folder.
    git_view: bool = true,
    column_widths: ?[5]f64 = null,
    git_column_widths: ?[5]f64 = null,
    column_resize: ?struct { column: usize, x: f64, widths: [5]f64 } = null,
    sort_mode: Sort = .name,
    recent_sort_mode: Sort = .modified,
    folders_only: bool = false,
    // Only meaningful inside a Git repository; on by default there.
    changed_only: bool = true,
    // In the flat list of changed files: show each path from the folder.
    full_paths: bool = true,
    snapshot: ?*worker_mod.Snapshot = null,
    search: Editor = .{},
    search_visible: bool = false,
    menu: ?MenuKind = null,
    menu_x: f64 = 0,
    menu_y: f64 = 0,
    menu_selected: usize = 0,
    file_menu_labels: [12][]const u8 = undefined,
    menu_label_text: [8][]const u8 = undefined,
    column_label_text: [5][]const u8 = undefined,
    place_menu_labels: [4][]const u8 = undefined,
    menu_place: usize = 0,
    unpinned_places: u8 = 0,
    /// Folders and files the user dropped into PLACES (see pins.zig); they sit
    /// after Projects. `pins_path` is null without a home.
    pins: pins_mod.List = .{},
    pins_path: ?[]u8 = null,
    /// While a drag hovers PLACES: the gap, among the pins, where a drop lands.
    pin_drop: ?usize = null,
    folder_drop: ?usize = null,

    // Removable and external volumes (see volumes.zig), listed under DEVICES.
    // The monitor starts once the window exists; without it the list is empty.
    devices: ?volumes_mod.Monitor = null,
    device_list: volumes_mod.List = .{},
    /// The mount or eject in flight. One at a time: a polkit prompt may be waiting.
    device_op: ?DeviceOp = null,
    /// Counts navigations, so a mount can tell the view moved on while it ran.
    navigation_count: u32 = 0,
    folder_sizes: std.StringHashMap(SizeState) = undefined,
    dirsize_pool: ?*dirsize.Pool = null,

    // Image thumbnails, made on worker threads (see thumbs.zig). The service
    // is created when a folder first shows an image.
    thumbs: ?*thumbs_mod.Service = null,
    thumbs_enabled: bool = true,
    /// Bumped whenever `items` is rebuilt, so the visible files are re-asked.
    view_revision: u64 = 0,
    thumb_request: ThumbRequest = .{},
    thumb_wants: std.ArrayList(thumbs_mod.Want) = .empty,
    thumb_arrived: std.ArrayList(u64) = .empty,

    // Selection & scroll
    selection_anchor: ?usize = null,
    focused_index: ?usize = null,
    type_select_buffer: [256]u8 = undefined,
    type_select_len: usize = 0,
    type_select_last_ms: i64 = 0,
    scroll_y: i32 = 0,
    wheel_glide: anim.Anim = .{},
    wheel_sidebar: bool = false,
    // Hover highlights: each fades in where the pointer lands and glides
    // between cells while visible. `stepHover` samples them once per loop and
    // damages only what changed; the painters draw `frame`, never the pointer.
    toolbar_hover: ToolbarHover = .{},
    nav_hover: hover_glide.Glide = .{},
    item_hover: hover_glide.Glide = .{},
    // Each path section fades independently, including when crossing a separator.
    breadcrumb_hover: [128]hover_glide.Glide = @splat(.{}),
    /// What the item glide's cells meant when it was last sampled.
    item_hover_layout: HoverLayout = .{},
    /// A highlight was still in flight at the last `stepHover`: the loop keeps
    /// its frame clock only for that.
    hover_active: bool = false,
    sort_feedback: SelectionFade = .{},
    drag_origin: ?struct { x: f64, y: f64 } = null,
    drag_ready: bool = false,
    collapse_on_release: ?usize = null,
    deselect_on_release: ?usize = null,
    open_on_release: ?usize = null,
    single_click_open: bool = true,
    selection_band: ?struct {
        x: f64,
        y: f64, // Content coordinates, so the anchor survives edge scrolling.
        active: bool = false,
        toggle: bool,
        extend: bool,
        last_ms: i64,
    } = null,
    sidebar_scroll: i32 = 0,
    /// User width for this window; responsive layouts still hide the pane.
    sidebar_requested: ?i32 = null,
    sidebar_resize: ?splitter.Drag = null,
    /// Eased sidebar width and place pitch (-1 until the first `stepLayout`,
    /// which adopts the current targets without animating).
    sidebar_glide: anim.Anim = .{},
    sidebar_px: i32 = -1,
    place_glide: anim.Anim = .{},
    place_px: i32 = -1,
    layout_active: bool = false,
    sidebar_scroll_drag: scrollbar.Drag = .{},
    sidebar_scroll_appearance: scrollbar.Appearance = .{},
    sidebar_scroll_observed: i32 = 0,
    scrollbar_width: f32 = 8,
    scroll_x: f64 = 0,
    horizontal_drag: scrollbar.Drag = .{},
    horizontal_appearance: scrollbar.Appearance = .{},
    horizontal_observed: f64 = 0,
    scroll_drag: scrollbar.Drag = .{},
    scroll_appearance: scrollbar.Appearance = .{},
    scroll_observed: i32 = 0,

    // Focus & location field
    focus: Focus = .file_view,
    location: Editor = .{},
    text_dragging: bool = false,
    edit_revision: usize = 0,
    text_paste_requested: bool = false,
    clipboard_text: std.ArrayList(u8) = .empty,
    clipboard_is_text: bool = false,
    // Operations & Jobs
    dialog: ?Dialog = null,
    job_runner: ?*ops_mod.JobRunner = null,
    job_was_running: bool = false,
    archive_preview: bool = false,
    archive_open_navigation: u32 = 0,
    extract_picker_fd: ?c_int = null,
    extract_picker_source: ?[]u8 = null,
    extract_picker_bytes: std.ArrayList(u8) = .empty,
    job_cut_revision: ?usize = null,
    job_progress: usize = std.math.maxInt(usize),
    job_state: ops_mod.JobState = .idle,
    status_notice: ?[]u8 = null,
    status_notice_until: i64 = 0,
    status_is_error: bool = false,

    // Clipboard
    clipboard_paths: std.ArrayList([]const u8) = .empty,
    clipboard_cut: bool = false,
    clipboard_revision: usize = 0,
    paste_requested: bool = false,

    // Mouse & input
    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
    last_click_time: i64 = 0,
    last_click_index: ?usize = null,
    /// The item a single-click last opened, and when: the second click of a
    /// double-click on its icon must not open it again.
    last_open_index: ?usize = null,
    last_open_time: i64 = 0,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,

    // Title notification
    title_changed: bool = true,
    title_z: [256:0]u8 = @splat(0),

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        environ: std.process.Environ,
        theme_cfg: theme.Config,
        worker: *worker_mod.Worker,
        initial_dir: []const u8,
        home_dir: []const u8,
    ) !App {
        var hist = try history_mod.History.init(allocator, initial_dir);
        errdefer hist.deinit();

        var self = App{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .theme_cfg = theme_cfg,
            .worker = worker,
            .history = hist,
            .home_dir = home_dir,
            .items_arena = std.heap.ArenaAllocator.init(allocator),
            .job_runner = ops_mod.JobRunner.init(allocator) catch null,
            .folder_sizes = std.StringHashMap(SizeState).init(allocator),
            .thumbs_enabled = !thumb_decode.disabled(environ),
            .single_click_open = @import("settings.zig").singleClickOpen(),
        };

        self.theme_cfg.override_root = @import("settings.zig").iconRoot();
        const icon_base = @import("settings.zig").iconTheme();
        if (icon_base.len > 0) self.theme_cfg.theme_name = icon_base;
        const data_home = environ.getPosix("XDG_DATA_HOME");
        self.trash_dir = if (data_home != null and std.fs.path.isAbsolute(data_home.?))
            try std.fs.path.join(allocator, &.{ data_home.?, "Trash", "files" })
        else
            try std.fs.path.join(allocator, &.{ home_dir, ".local", "share", "Trash", "files" });
        errdefer allocator.free(self.trash_dir.?);
        try self.location.text.appendSlice(allocator, initial_dir);
        self.location.cursor = initial_dir.len;
        self.updateTitle();
        self.preferences_path = Preferences.path(allocator, environ) catch null;
        if (self.preferences_path) |path| {
            const prefs = Preferences.load(allocator, io, path);
            self.list_view = prefs.list;
            self.unpinned_places = prefs.unpinned_places;
            self.git_view = prefs.git_view;
            self.terminal.requested_height = @intCast(prefs.terminal_height);
            self.sort_mode = @enumFromInt(prefs.sort);
        }
        self.pins_path = pins_mod.statePath(allocator, environ) catch null;
        if (self.pins_path) |path| self.pins = pins_mod.List.load(allocator, io, path);
        self.location.anchor = self.location.cursor;
        self.loading_since = nowMs();
        return self;
    }

    pub fn deinit(self: *App) void {
        self.torrents.deinit();
        self.terminal.deinit(self.allocator);
        self.children.deinit(self.allocator);
        self.closeExtractPicker();
        self.extract_picker_bytes.deinit(self.allocator);
        if (self.trash_dir) |path| self.allocator.free(path);
        self.filename.deinit(self.allocator);
        for (self.chooser_paths.items) |path| self.allocator.free(path);
        self.chooser_paths.deinit(self.allocator);
        self.chooser_choices.deinit(self.allocator);
        self.chooser_filter_labels.deinit(self.allocator);
        if (self.preferences_path) |path| self.allocator.free(path);
        if (self.pins_path) |path| self.allocator.free(path);
        self.pins.deinit(self.allocator);
        if (self.preview_return_fd) |fd| _ = c.close(fd);
        if (self.editor_path) |path| self.allocator.free(path);
        if (self.job_runner) |runner| runner.deinit();
        self.clearFolderSizes();
        self.folder_sizes.deinit();
        if (self.dirsize_pool) |p| p.deinit();
        if (self.thumbs) |t| t.deinit();
        if (self.devices) |monitor| monitor.stop();
        self.device_list.deinit();
        if (self.device_op) |op| self.allocator.free(op.id);
        self.thumb_wants.deinit(self.allocator);
        self.thumb_arrived.deinit(self.allocator);
        self.clearClipboard();
        self.clipboard_paths.deinit(self.allocator);
        self.closeDialog();
        if (self.status_notice) |sn| self.allocator.free(sn);

        if (self.snapshot) |snap| snap.destroy();
        self.search.deinit(self.allocator);
        self.clipboard_text.deinit(self.allocator);
        self.history.deinit();
        self.items.deinit(self.allocator);
        self.items_arena.deinit();
        self.location.deinit(self.allocator);
    }

    pub fn clearClipboard(self: *App) void {
        for (self.clipboard_paths.items) |p| self.allocator.free(p);
        self.clipboard_paths.clearRetainingCapacity();
    }

    pub fn getTitle(self: *App) [*:0]const u8 {
        return &self.title_z;
    }

    pub fn updateTitle(self: *App) void {
        if (self.chooser) |opts| {
            const title = if (opts.title.len > 0) opts.title else switch (opts.mode) {
                .open => tr("Open File"),
                .save => tr("Save As"),
                .folder => tr("Choose Folder"),
            };
            const len = @min(title.len, self.title_z.len - 1);
            @memcpy(self.title_z[0..len], title[0..len]);
            self.title_z[len] = 0;
            self.title_changed = true;
            return;
        }
        const cur = self.history.current;
        const name = if (self.transfer_view.active) tr("Transfers") else if (self.isRecent()) tr("Recent") else if (self.trash_dir != null and std.mem.eql(u8, cur, self.trash_dir.?)) tr("Trash") else if (std.mem.eql(u8, cur, "/")) "/" else std.fs.path.basename(cur);
        _ = i18n.fmtZ(&self.title_z, tr("{name} — RediWM Files"), .{ .name = name }) catch {
            _ = i18n.fmtZ(&self.title_z, tr("RediWM Files"), .{}) catch unreachable;
        };
        self.title_changed = true;
    }

    pub fn invalidate(self: *App) void {
        self.dirty = true;
        self.paint_damage = null;
    }

    pub const scan_notice_delay_ms: i64 = 500;

    pub fn beginLoading(self: *App) void {
        self.loading = true;
        self.loading_since = nowMs();
        self.scan_notice_shown = false;
    }

    pub fn stepScanNotice(self: *App, now: i64) void {
        const at = self.scanNoticeDeadline() orelse return;
        if (now < at) return;
        self.scan_notice_shown = true;
        self.invalidate();
    }

    /// The moment "Scanning folder..." should appear, while an empty view is
    /// still waiting for its listing and the notice is not yet up. The poll
    /// loop sleeps until then; `stepScanNotice` shows it. Null: nothing to wait for.
    pub fn scanNoticeDeadline(self: *const App) ?i64 {
        if (!self.loading or self.scan_notice_shown or self.items.items.len != 0) return null;
        return self.loading_since + scan_notice_delay_ms;
    }

    // app_hover.zig
    pub const hoverBounds = app_hover.hoverBounds;
    pub const addDamage = app_hover.addDamage;
    pub const invalidateHover = app_hover.invalidateHover;
    pub const clipToViewport = app_hover.clipToViewport;
    pub const hoveredPlace = app_hover.hoveredPlace;
    pub const hoveredItem = app_hover.hoveredItem;
    pub const navHighlight = app_hover.navHighlight;
    pub const itemHighlight = app_hover.itemHighlight;
    pub const toolbarButtonVisible = app_hover.toolbarButtonVisible;
    pub const toolbarButtonEnabled = app_hover.toolbarButtonEnabled;
    pub const hoveredToolbarButton = app_hover.hoveredToolbarButton;
    pub const stepHover = app_hover.stepHover;
    pub const damageHighlight = app_hover.damageHighlight;
    pub const unionRect = app_hover.unionRect;

    pub const HoverLayout = struct { columns: i32 = 1, list: bool = false };

    pub fn resize(self: *App, new_w: i32, new_h: i32) void {
        if (self.w != new_w or self.h != new_h) {
            self.cancelWheel();
            self.cancelDrag();
            self.sidebar_scroll_drag.end();
            self.w = @max(360, new_w);
            self.h = @max(240, new_h);
            if (self.sidebar_requested != null and self.w >= 500) self.syncSidebarWidth();
            self.clampScroll();
            self.clampSidebarScroll();
            if (self.menu) |kind| self.openMenu(kind, self.menu_x, self.menu_y);
            self.invalidate();
        }
    }

    pub fn savePreferences(self: *App) void {
        const path = self.preferences_path orelse return;
        (Preferences{ .list = self.non_git_list_view orelse self.list_view, .sort = @intFromEnum(self.sort_mode), .unpinned_places = self.unpinned_places, .git_view = self.git_view, .terminal_height = @intCast(self.terminal.requested_height) }).save(self.allocator, self.io, path) catch {
            self.setStatusNotice(tr("Could not save view preferences"), true);
        };
    }

    pub fn rememberView(self: *App) void {
        if (self.loading or self.transfer_view.active) return;
        var view: history_mod.View = .{ .scroll = self.scroll_y };
        for (self.items.items, 0..) |item, i| {
            if (item.selected) {
                const path = self.allocator.dupe(u8, item.path) catch continue;
                view.selected.append(self.allocator, path) catch self.allocator.free(path);
            }
            if (self.focused_index == i) view.focus = self.allocator.dupe(u8, item.path) catch null;
            if (self.selection_anchor == i) view.anchor = self.allocator.dupe(u8, item.path) catch null;
        }
        self.history.view.deinit(self.allocator);
        self.history.view = view;
    }

    pub fn restoreView(self: *App) void {
        const view = &self.history.view;
        var selected = std.StringHashMap(void).init(self.allocator);
        defer selected.deinit();
        for (view.selected.items) |path| selected.put(path, {}) catch {};
        for (self.items.items, 0..) |*item, i| {
            item.selected = selected.contains(item.path);
            if (view.focus) |path| {
                if (std.mem.eql(u8, path, item.path)) self.focused_index = i;
            }
            if (view.anchor) |path| {
                if (std.mem.eql(u8, path, item.path)) self.selection_anchor = i;
            }
        }
        self.scroll_y = view.scroll;
        self.clampScroll();
        self.restore_view = false;
    }

    // app_listing.zig
    pub const navigate = app_listing.navigate;
    pub const refresh = app_listing.refresh;
    pub const toggleHidden = app_listing.toggleHidden;
    pub const selectOnLoad = app_listing.selectOnLoad;
    pub const back = app_listing.back;
    pub const forward = app_listing.forward;
    pub const up = app_listing.up;
    pub const home = app_listing.home;
    pub const applyHistoryNav = app_listing.applyHistoryNav;
    pub const isStaleSnapshot = app_listing.isStaleSnapshot;
    pub const sync = app_listing.sync;
    pub const syncGitLayout = app_listing.syncGitLayout;
    pub const setGitView = app_listing.setGitView;
    pub const shownName = app_listing.shownName;
    pub const matches = app_listing.matches;
    pub const lessThan = app_listing.lessThan;
    pub const rebuildView = app_listing.rebuildView;

    pub fn setStatusNotice(self: *App, msg: []const u8, is_error: bool) void {
        if (self.status_notice) |sn| self.allocator.free(sn);
        self.status_notice = self.allocator.dupe(u8, msg) catch null;
        self.status_notice_until = nowMs() + 4000;
        self.status_is_error = is_error;
        self.invalidate();
    }

    // app_dialogs.zig
    pub const closeDialog = app_dialogs.closeDialog;
    pub const openProperties = app_dialogs.openProperties;
    pub const openSelectedProperties = app_dialogs.openSelectedProperties;
    pub const propertiesAction = app_dialogs.propertiesAction;
    pub const canOpenWith = app_dialogs.canOpenWith;
    pub const openWithDialog = app_dialogs.openWithDialog;
    pub const openWithAction = app_dialogs.openWithAction;
    pub const openNewFolderDialog = app_dialogs.openNewFolderDialog;
    pub const openNewBranchDialog = app_dialogs.openNewBranchDialog;
    pub const switchBranch = app_dialogs.switchBranch;
    pub const openNewFileDialog = app_dialogs.openNewFileDialog;
    pub const openRenameDialog = app_dialogs.openRenameDialog;
    pub const openEmptyTrashDialog = app_dialogs.openEmptyTrashDialog;
    pub const openTrashConfirmDialog = app_dialogs.openTrashConfirmDialog;
    pub const openTrashConfirmDialogWithMode = app_dialogs.openTrashConfirmDialogWithMode;
    pub const openConflictDialog = app_dialogs.openConflictDialog;
    pub const confirmDialog = app_dialogs.confirmDialog;
    pub const handleDialogKey = app_dialogs.handleDialogKey;

    // app_fileops.zig
    pub const copySelected = app_fileops.copySelected;
    pub const cutSelected = app_fileops.cutSelected;
    pub const calculateSizeSelected = app_fileops.calculateSizeSelected;
    pub const executePaste = app_fileops.executePaste;
    pub const executeTransfer = app_fileops.executeTransfer;
    pub const executePasteLocal = app_fileops.executePasteLocal;
    pub const executePasteExternal = app_fileops.executePasteExternal;
    pub const deleteAction = app_fileops.deleteAction;
    pub const executeDeletion = app_fileops.executeDeletion;

    // app_chooser.zig
    pub const configureChooser = app_chooser.configureChooser;
    pub const setChooserName = app_chooser.setChooserName;
    pub const chooserRect = app_chooser.chooserRect;
    pub const cycleChooserFilter = app_chooser.cycleChooserFilter;
    pub const chooserClick = app_chooser.chooserClick;
    pub const chooserKey = app_chooser.chooserKey;
    pub const acceptChooser = app_chooser.acceptChooser;
    pub const collectChooser = app_chooser.collectChooser;
    pub const renderChooser = app_chooser.renderChooser;

    pub const BreadcrumbHit = struct { path: []const u8, index: usize };

    // app_layout.zig
    pub const breadcrumbs = app_layout.breadcrumbs;
    pub const footerHeight = app_layout.footerHeight;
    pub const sidebarFooter = app_layout.sidebarFooter;
    pub const contentTop = app_layout.contentTop;
    pub const viewTop = app_layout.viewTop;
    pub const compactList = app_layout.compactList;
    pub const itemInset = app_layout.itemInset;
    pub const rowHeight = app_layout.rowHeight;
    pub const cardHeight = app_layout.cardHeight;
    pub const listBaseline = app_layout.listBaseline;
    pub const sidebarTargetWidth = app_layout.sidebarTargetWidth;
    pub const sidebarWidth = app_layout.sidebarWidth;
    pub const syncSidebarWidth = app_layout.syncSidebarWidth;
    pub const sidebarDivider = app_layout.sidebarDivider;
    pub const overSidebarDivider = app_layout.overSidebarDivider;
    pub const damageSidebarDivider = app_layout.damageSidebarDivider;
    pub const placeTargetStep = app_layout.placeTargetStep;
    pub const glideInt = app_layout.glideInt;
    pub const stepLayout = app_layout.stepLayout;
    pub const clampSidebarScroll = app_layout.clampSidebarScroll;
    pub const scrollbarGutter = app_layout.scrollbarGutter;
    pub const columns = app_layout.columns;
    pub const cellWidth = app_layout.cellWidth;
    pub const contentHeight = app_layout.contentHeight;
    pub const itemAt = app_layout.itemAt;
    pub const foundRepository = app_layout.foundRepository;
    pub const repository = app_layout.repository;
    pub const inRepository = app_layout.inRepository;
    pub const changedOnly = app_layout.changedOnly;
    pub const columnLabels = app_layout.columnLabels;
    pub const columnMinimums = app_layout.columnMinimums;
    pub const listWidths = app_layout.listWidths;
    pub const listColumn = app_layout.listColumn;
    pub const columnBoundary = app_layout.columnBoundary;
    pub const resizeColumn = app_layout.resizeColumn;
    pub const gitColumnMinimums = app_layout.gitColumnMinimums;
    pub const sizeButtonRect = app_layout.sizeButtonRect;

    pub const GridCard = struct {
        pub const padding_x: f64 = 10;
        pub const padding_top: f64 = 8;
        pub const icon_size: f64 = 54;
        pub const name_baseline: f64 = 78;
        pub const detail_baseline: f64 = 101;
        pub const height: i32 = 112;
    };
    pub const column_labels = [_][]const u8{ "Name", "Size", "Type", "Modified", "Permissions" };
    // app_folder_size.zig
    pub const getOrInitDirsizePool = app_folder_size.getOrInitDirsizePool;
    pub const startFolderSize = app_folder_size.startFolderSize;
    pub const cancelFolderSize = app_folder_size.cancelFolderSize;
    pub const toggleFolderSize = app_folder_size.toggleFolderSize;
    pub const cancelRunningFolderSizes = app_folder_size.cancelRunningFolderSizes;
    pub const clearFolderSizes = app_folder_size.clearFolderSizes;
    pub const hasRunningFolderSize = app_folder_size.hasRunningFolderSize;
    pub const damagePathSize = app_folder_size.damagePathSize;
    pub const syncFolderSizes = app_folder_size.syncFolderSizes;
    pub const itemSizeDisplay = app_folder_size.itemSizeDisplay;

    pub const ItemSizeDisplay = struct {
        text: []const u8,
        is_running: bool,
    };

    // app_listing.zig
    pub const sortColumn = app_listing.sortColumn;
    pub const sortDescending = app_listing.sortDescending;
    pub const startSortFeedback = app_listing.startSortFeedback;
    pub const paintSortFeedback = app_listing.paintSortFeedback;
    pub const sortByColumn = app_listing.sortByColumn;
    pub const renderColumns = app_listing.renderColumns;
    pub const itemType = app_listing.itemType;
    pub const isRecent = app_listing.isRecent;
    pub const recentAvailable = app_listing.recentAvailable;
    pub const effectiveSort = app_listing.effectiveSort;
    pub const setSort = app_listing.setSort;

    pub const places = [_][]const u8{ "Home", "Trash", "Recent", "Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos", "Projects" };
    pub const place_labels = [_]i18n.Message{ i18n.msg("Home"), i18n.msg("Trash"), i18n.msg("Recent"), i18n.msg("Desktop"), i18n.msg("Documents"), i18n.msg("Downloads"), i18n.msg("Pictures"), i18n.msg("Music"), i18n.msg("Videos"), i18n.msg("Projects") };

    pub const places_start = 3;

    /// Where the pins start: the built-in places come first.
    pub const pin_base = places.len;

    /// A sidebar row. Indices run in drawn order, which the hover glide relies
    /// on: the built-in places, the pins, then the devices.
    pub const Row = union(enum) { builtin: usize, pin: usize, device: usize };

    // app_places.zig
    pub const deviceBase = app_places.deviceBase;
    pub const rowCount = app_places.rowCount;
    pub const rowKind = app_places.rowKind;
    pub const pinIndex = app_places.pinIndex;
    pub const isDeviceRow = app_places.isDeviceRow;
    pub const placeStep = app_places.placeStep;
    pub const placeRect = app_places.placeRect;
    pub const placePinnable = app_places.placePinnable;
    pub const placeVisible = app_places.placeVisible;
    pub const openPlace = app_places.openPlace;
    pub const openPlaceWindow = app_places.openPlaceWindow;
    pub const openPin = app_places.openPin;
    pub const placeAt = app_places.placeAt;
    pub const placeActive = app_places.placeActive;
    pub const deviceAt = app_places.deviceAt;
    pub const deviceBlock = app_places.deviceBlock;
    pub const ejectRect = app_places.ejectRect;
    pub const ejectAt = app_places.ejectAt;
    pub const pinBoundary = app_places.pinBoundary;
    pub const pinSlotAt = app_places.pinSlotAt;
    pub const setPinDrop = app_places.setPinDrop;
    pub const dropMotion = app_places.dropMotion;
    pub const dropDirectoryAt = app_places.dropDirectoryAt;
    pub const highlightDrop = app_places.highlightDrop;
    pub const dropLeave = app_places.dropLeave;
    pub const takePinDrop = app_places.takePinDrop;
    pub const builtinPlacePath = app_places.builtinPlacePath;
    pub const pinDropped = app_places.pinDropped;
    pub const removePin = app_places.removePin;
    pub const savePins = app_places.savePins;
    pub const reloadPins = app_places.reloadPins;
    pub const pinsChanged = app_places.pinsChanged;
    pub const refreshPins = app_places.refreshPins;
    pub const deviceLabel = app_places.deviceLabel;
    pub const startDevices = app_places.startDevices;
    pub const devicesWakeFd = app_places.devicesWakeFd;
    pub const drainDevices = app_places.drainDevices;
    pub const startDeviceOp = app_places.startDeviceOp;
    pub const activateDevice = app_places.activateDevice;
    pub const ejectDevice = app_places.ejectDevice;
    pub const deviceResult = app_places.deviceResult;

    // app_sidebar_paint.zig
    pub const renderDevices = app_sidebar_paint.renderDevices;
    pub const placeY = app_sidebar_paint.placeY;
    pub const pinRowY = app_sidebar_paint.pinRowY;
    pub const sidebarScrollbar = app_sidebar_paint.sidebarScrollbar;

    // app_scroll.zig
    pub const maxHorizontalScroll = app_scroll.maxHorizontalScroll;
    pub const horizontalOffset = app_scroll.horizontalOffset;
    pub const contentBottom = app_scroll.contentBottom;
    pub const horizontalScrollbar = app_scroll.horizontalScrollbar;
    pub const scrollbarGeometry = app_scroll.scrollbarGeometry;

    // app_sidebar_paint.zig
    pub const placePath = app_sidebar_paint.placePath;
    pub const drawPackPlaceIcon = app_sidebar_paint.drawPackPlaceIcon;
    pub const renderSidebar = app_sidebar_paint.renderSidebar;
    pub const renderPinDrop = app_sidebar_paint.renderPinDrop;

    // app_sidebar_paint.zig
    pub const sidebarExtent = app_sidebar_paint.sidebarExtent;

    pub const startTorrents = app_torrents.startTorrents;
    pub const stepTorrents = app_torrents.stepTorrents;
    pub const torrentForItem = app_torrent_rows.torrentForItem;
    pub const hasFolderTransfers = app_torrent_rows.hasFolderTransfers;
    pub const appendTorrentRows = app_torrent_rows.appendTorrentRows;
    pub const inlineTorrentWidth = app_torrent_rows.inlineTorrentWidth;
    pub const renderInlineTorrent = app_torrent_rows.renderInlineTorrent;
    pub const inlineTorrentHit = app_torrent_rows.inlineTorrentHit;
    pub const inlineTorrentClick = app_torrent_rows.inlineTorrentClick;
    pub const renderTorrentTip = app_torrent_rows.renderTorrentTip;
    pub const toggleTorrent = app_torrents.toggleTorrent;
    pub const openTorrentDetails = app_torrents.openTorrentDetails;
    pub const openTransfers = app_torrents.openTransfers;
    pub const leaveTransfers = app_torrents.leaveTransfers;
    pub const renderTransferToolbar = app_torrents.renderTransferToolbar;
    pub const renderTransferList = app_torrents.renderTransferList;
    pub const transferPaneClick = app_torrents.transferPaneClick;
    pub const transferPaneKey = app_torrents.transferPaneKey;
    pub const transferPaneHover = app_torrents.transferPaneHover;
    pub const torrentSource = app_torrents.torrentSource;
    pub const confirmTorrent = app_torrents.confirmTorrent;
    pub const torrentSidebarHeight = app_torrents.torrentSidebarHeight;
    pub const torrentSidebarHit = app_torrents.torrentSidebarHit;
    pub const renderTorrentSidebar = app_torrents.renderTorrentSidebar;
    pub const transfersHover = app_torrents.transfersHover;
    pub const transfersClick = app_torrents.transfersClick;
    pub const transfersKey = app_torrents.transfersKey;
    pub const renderTransfers = app_torrents.renderTransfers;

    // app_git_sidebar.zig
    pub const gitSidebarHeight = app_git_sidebar.gitSidebarHeight;
    pub const gitHeadExtra = app_git_sidebar.gitHeadExtra;
    pub const gitBranchRowCount = app_git_sidebar.gitBranchRowCount;
    pub const gitBranchRow = app_git_sidebar.gitBranchRow;
    pub const gitCardHeight = app_git_sidebar.gitCardHeight;
    pub const gitCard = app_git_sidebar.gitCard;
    pub const renderGitSidebar = app_git_sidebar.renderGitSidebar;
    pub const renderGitStatus = app_git_sidebar.renderGitStatus;

    pub const git_header_h: f64 = 32;
    pub const git_row_h: f64 = 28;

    pub const GitBranchRow = struct { name: []const u8, current: bool };

    // app_sidebar_paint.zig
    pub const renderSidebarScrollbar = app_sidebar_paint.renderSidebarScrollbar;

    // app_scroll.zig
    pub const clampScroll = app_scroll.clampScroll;
    pub const maxScroll = app_scroll.maxScroll;
    pub const revealIndex = app_scroll.revealIndex;

    // app_opening.zig
    pub const addApplication = app_opening.addApplication;
    pub const previewSelected = app_opening.previewSelected;
    pub const launchEditor = app_opening.launchEditor;
    pub const launchPreview = app_opening.launchPreview;
    pub const launchImageList = app_opening.launchImageList;
    pub const writePreviewBytes = app_opening.writePreviewBytes;
    pub const isPdf = app_opening.isPdf;
    pub const openFile = app_opening.openFile;
    pub const browseArchive = app_opening.browseArchive;
    pub const startExtraction = app_opening.startExtraction;
    pub const openArchiveMember = app_opening.openArchiveMember;
    pub const openExtracted = app_opening.openExtracted;
    pub const previewExtracted = app_opening.previewExtracted;
    pub const closeExtractPicker = app_opening.closeExtractPicker;
    pub const chooseExtractionFolder = app_opening.chooseExtractionFolder;
    pub const extractionFolderReady = app_opening.extractionFolderReady;
    pub const activateItem = app_opening.activateItem;
    pub const activateSelected = app_opening.activateSelected;

    // app_pointer.zig
    pub const hoverKey = app_pointer.hoverKey;
    pub const handleMotion = app_pointer.handleMotion;
    pub const cancelDrag = app_pointer.cancelDrag;
    pub const bandRect = app_pointer.bandRect;
    pub const updateSelectionBand = app_pointer.updateSelectionBand;
    pub const bandScrollDirection = app_pointer.bandScrollDirection;
    pub const selectionNeedsScroll = app_pointer.selectionNeedsScroll;
    pub const stepSelection = app_pointer.stepSelection;
    pub const renderSelectionBand = app_pointer.renderSelectionBand;

    // app_scroll.zig
    pub const cancelWheel = app_scroll.cancelWheel;
    pub const wheelMax = app_scroll.wheelMax;
    pub const handleWheel = app_scroll.handleWheel;
    pub const stepWheel = app_scroll.stepWheel;
    pub const handleScroll = app_scroll.handleScroll;
    pub const handleHorizontalScroll = app_scroll.handleHorizontalScroll;

    // app_pointer.zig
    pub const handleButton = app_pointer.handleButton;

    // app_terminal.zig
    pub const terminalHeight = app_terminal.terminalHeight;
    pub const terminalMaximum = app_terminal.terminalMaximum;
    pub const terminalRect = app_terminal.terminalRect;
    pub const terminalBody = app_terminal.terminalBody;
    pub const terminalDropAt = app_terminal.terminalDropAt;
    pub const terminalDropPaths = app_terminal.terminalDropPaths;
    pub const terminalControl = app_terminal.terminalControl;
    pub const terminalHit = app_terminal.terminalHit;
    pub const terminalRestartable = app_terminal.terminalRestartable;
    pub const terminalDivider = app_terminal.terminalDivider;
    pub const overTerminalDivider = app_terminal.overTerminalDivider;
    pub const terminalScopes = app_terminal.terminalScopes;
    pub const terminalHelper = app_terminal.terminalHelper;
    pub const terminalStart = app_terminal.terminalStart;
    pub const terminalToggle = app_terminal.terminalToggle;
    pub const terminalStep = app_terminal.terminalStep;
    pub const terminalDamage = app_terminal.terminalDamage;
    pub const terminalScrollbar = app_terminal.terminalScrollbar;
    pub const terminalKey = app_terminal.terminalKey;
    pub const terminalModifiers = app_terminal.terminalModifiers;
    pub const terminalCopy = app_terminal.terminalCopy;
    pub const terminalMotion = app_terminal.terminalMotion;
    pub const terminalButton = app_terminal.terminalButton;
    pub const terminalCancelPointer = app_terminal.terminalCancelPointer;
    pub const terminalWheel = app_terminal.terminalWheel;
    pub const terminalRequestClose = app_terminal.terminalRequestClose;
    pub const terminalConfirmClose = app_terminal.terminalConfirmClose;
    pub const terminalFinishClose = app_terminal.terminalFinishClose;
    pub const terminalExternal = app_terminal.terminalExternal;
    pub const renderTerminal = app_terminal.renderTerminal;

    // app_keyboard.zig
    pub const keyRepeats = app_keyboard.keyRepeats;
    pub const handleKey = app_keyboard.handleKey;
    pub const typeSelectAt = app_keyboard.typeSelectAt;
    pub const selectIndex = app_keyboard.selectIndex;
    pub const handleLocationKey = app_keyboard.handleLocationKey;
    pub const activeEditor = app_keyboard.activeEditor;
    pub const editKey = app_keyboard.editKey;
    pub const pasteText = app_keyboard.pasteText;
    pub const hasSelection = app_keyboard.hasSelection;

    // app_menu.zig
    pub const runHeader = app_menu.runHeader;
    pub const menuRowHeight = app_menu.menuRowHeight;
    pub const isContextMenu = app_menu.isContextMenu;
    pub const menuWidth = app_menu.menuWidth;
    pub const menuPadding = app_menu.menuPadding;
    pub const menuSeparatorBefore = app_menu.menuSeparatorBefore;
    pub const menuSeparatorSpace = app_menu.menuSeparatorSpace;
    pub const menuHeight = app_menu.menuHeight;
    pub const menuRowRect = app_menu.menuRowRect;
    pub const menuIcon = app_menu.menuIcon;
    pub const menuHint = app_menu.menuHint;
    pub const hasSizeSelection = app_menu.hasSizeSelection;
    pub const selectedArchive = app_menu.selectedArchive;
    pub const selectedAppImage = app_menu.selectedAppImage;
    pub const fileActions = app_menu.fileActions;
    pub const placeActions = app_menu.placeActions;
    pub const menuLabels = app_menu.menuLabels;
    pub const openMenu = app_menu.openMenu;
    pub const menuHit = app_menu.menuHit;
    pub const runMenu = app_menu.runMenu;
    pub const renderMenu = app_menu.renderMenu;

    // app_keyboard.zig
    pub const handleSearchKey = app_keyboard.handleSearchKey;

    // app_paint.zig
    pub const renderHeader = app_paint.renderHeader;
    pub const renderToolbarHover = app_paint.renderToolbarHover;
    pub const renderGitViewToggle = app_paint.renderGitViewToggle;
    pub const render = app_paint.render;
    pub const renderButton = app_paint.renderButton;
    pub const fieldFontSize = app_paint.fieldFontSize;
    pub const renderLocationBar = app_paint.renderLocationBar;
    pub const fieldOptions = app_paint.fieldOptions;
    pub const textArea = app_paint.textArea;
    pub const editorTextArea = app_paint.editorTextArea;
    pub const pointerCursor = app_paint.pointerCursor;
    pub const singleClickIconAt = app_paint.singleClickIconAt;
    pub const renameCard = app_paint.renameCard;
    pub const renderRenameCard = app_paint.renderRenameCard;
    pub const editorRect = app_paint.editorRect;
    pub const placeCaret = app_paint.placeCaret;
    pub const renderEditor = app_paint.renderEditor;

    // app_items.zig
    pub const renderFileItems = app_items.renderFileItems;
    pub const renderFilenameTip = app_items.renderFilenameTip;
    pub const itemIconRect = app_items.itemIconRect;
    pub const thumbnailable = app_items.thumbnailable;
    pub const thumbService = app_items.thumbService;
    pub const thumbWakeFd = app_items.thumbWakeFd;
    pub const collectThumbRow = app_items.collectThumbRow;
    pub const stepThumbs = app_items.stepThumbs;
    pub const drainThumbs = app_items.drainThumbs;
    pub const drawThumb = app_items.drawThumb;
    pub const itemIcon = app_items.itemIcon;
    pub const drawItemIcon = app_items.drawItemIcon;
    pub const drawSymlinkEmblem = app_items.drawSymlinkEmblem;

    // app_scroll.zig
    pub const stepScrollbar = app_scroll.stepScrollbar;
    pub const renderScrollEdges = app_scroll.renderScrollEdges;
    pub const renderScrollbar = app_scroll.renderScrollbar;

    // app_paint.zig
    pub const renderStatusBar = app_paint.renderStatusBar;
    pub const renderDialog = app_paint.renderDialog;
};

test {
    _ = @import("app_tests.zig");
}
