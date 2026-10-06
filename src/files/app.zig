const std = @import("std");
const archive = @import("archive.zig");
const scrollbar = @import("ui").widgets.scrollbar;
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const git = @import("git.zig");
const worker_mod = @import("worker.zig");
const history_mod = @import("history.zig");
const recent = @import("recent.zig");
const ops_mod = @import("ops.zig");
const clipboard_mod = @import("clipboard.zig");
const dirsize = @import("dirsize.zig");
const thumbs_mod = @import("thumbs.zig");
const thumb_decode = @import("thumb_decode.zig");
const volumes_mod = @import("volumes.zig");
const image_formats = @import("../images/formats.zig");
const icons = @import("../icon_cache.zig");
const theme = @import("../icon_theme.zig");
const Allocator = std.mem.Allocator;
const deletion = @import("../delete_dialog.zig");
const header = @import("header.zig");
const shell_ui = @import("ui").cairo;
const context_menu = @import("ui").context_menu;
const shell_key_repeat = @import("ui").key_repeat;
const hover_glide = @import("ui").hover_glide;
const ui_field = @import("ui").widgets.field;
const ui_button = @import("ui").widgets.button;
const ui_checkbox = @import("ui").widgets.checkbox;
const ui_dialog = @import("ui").widgets.dialog;
const ui_theme = @import("ui").theme;
const IconId = @import("ui").layout.IconId;
const Preferences = @import("preferences.zig").Preferences;
const pins_mod = @import("pins.zig");
const chooser_mod = @import("chooser.zig");
const open_with = @import("open_with.zig");
const properties = @import("properties.zig");
const Editor = @import("editor.zig").Editor;
const DeviceOp = struct { id: []u8, unmount: bool, open: bool, navigation: u32 };

const MenuKind = enum { new, sort, filter, file, background, sidebar, device, chooser_filter };
const FileAction = enum {
    open,
    open_with,
    extract,
    extract_to,
    cut,
    copy,
    paste,
    rename,
    trash,
    size,
    properties,
    fn label(self: FileAction) []const u8 {
        return switch (self) {
            .open => "Open",
            .open_with => "Open With…",
            .extract => "Extract",
            .extract_to => "Extract to…",
            .cut => "Cut",
            .copy => "Copy",
            .paste => "Paste",
            .rename => "Rename",
            .trash => "Move to Trash",
            .size => "Calculate size",
            .properties => "Properties",
        };
    }
    fn icon(self: FileAction) IconId {
        return switch (self) {
            .open => .chevron_right,
            .open_with => .grid,
            .extract, .extract_to => .folder,
            .cut => .cut,
            .copy => .copy,
            .paste => .paste,
            .rename => .edit,
            .trash => .trash,
            .size, .properties => .view_list,
        };
    }
};
const Sort = enum { name, name_desc, size, modified, type, size_asc, modified_asc, type_desc };

pub const SizeState = union(enum) {
    running: *dirsize.Job,
    done: struct {
        bytes: i64,
        partial: bool,
    },
};

const SelectionFade = struct {
    animation: anim.Anim = .{ .property = .opacity },
    alpha: f32 = 0,

    fn step(self: *SelectionFade, now: i64, visible: bool) bool {
        const target: f32 = if (visible) 1 else 0;
        if (self.animation.to != target) self.animation.retargetTo(now, target, anim.curveFor(.start_glide_fade));
        const value = self.animation.value(now);
        const next = if (self.animation.settled(now)) value else @round(value / anim.rasterAlphaQuantum()) * anim.rasterAlphaQuantum();
        const changed = next != self.alpha;
        self.alpha = next;
        return changed;
    }
};

// Titlebar timing, with a rectangle that also fits labelled toolbar buttons.
const ToolbarHover = struct {
    geometry: [4]anim.Anim = @splat(.{}),
    alpha: anim.Anim = .{ .property = .opacity },
    frame: [4]f32 = @splat(0),
    opacity: f32 = 0,

    fn step(self: *ToolbarHover, now: i64, target: ?header.Rect, pixel: f32) bool {
        if (target) |r| {
            const values = [4]f32{ @floatCast(r.x), @floatCast(r.y), @floatCast(r.w), @floatCast(r.h) };
            for (&self.geometry, values) |*a, value| {
                if (self.alpha.value(now) <= 0.01) a.cancel(value) else if (a.to != value)
                    a.retargetTo(now, value, anim.curveFor(.titlebar_chip));
            }
        }
        const opacity: f32 = if (target != null) 1 else 0;
        if (self.alpha.to != opacity) self.alpha.retargetTo(now, opacity, anim.curveFor(.titlebar_chip_fade));
        const old_frame = self.frame;
        const old_opacity = self.opacity;
        for (&self.geometry, &self.frame) |*a, *value| {
            value.* = if (a.settled(now)) a.value(now) else @round(a.value(now) / pixel) * pixel;
        }
        const quantum = anim.rasterAlphaQuantum();
        self.opacity = if (self.alpha.settled(now)) self.alpha.value(now) else @round(self.alpha.value(now) / quantum) * quantum;
        return (old_opacity > 0 or self.opacity > 0) and
            (old_opacity != self.opacity or !std.meta.eql(old_frame, self.frame));
    }

    fn active(self: ToolbarHover, now: i64) bool {
        if (!self.alpha.settled(now)) return true;
        for (self.geometry) |a| if (!a.settled(now)) return true;
        return false;
    }
};

pub const ViewItem = struct {
    git_status: git.Status = .clean,
    git_lines: ?git.LineCounts = null,
    missing: bool = false,
    name: []const u8,
    /// Path from the listed folder, shown instead of `name` in the Git view's
    /// flat list. `name` stays the file's own name: renaming and opening use it.
    label: []const u8 = "",
    path: []const u8,
    is_dir: bool,
    is_symlink: bool,
    is_broken: bool,
    bytes: i64,
    mtime: i64,
    opened: i64 = 0,
    mode: c.mode_t = 0,
    permissions_text: []const u8 = "",
    icon_name: []const u8,
    icon_candidates: []const []const u8 = &.{},
    selected: bool = false,
    selection_fill: SelectionFade = .{},
    selection_border: SelectionFade = .{},
    selected_before_band: bool = false,

    /// What the Name column shows and sorts by.
    fn text(self: ViewItem) []const u8 {
        return if (self.label.len > 0) self.label else self.name;
    }
};

/// The part of the view the last thumbnail request described.
const ThumbRequest = struct {
    revision: u64 = std.math.maxInt(u64),
    row0: i32 = 0,
    row1: i32 = 0,
    cols: i32 = 0,
};

pub const Focus = enum {
    file_view,
    location_bar,
    search,
    filename,
    chooser_accept,
    chooser_cancel,
    chooser_filter,
    chooser_choice,
};

pub const DialogKind = enum {
    new_folder,
    new_file,
    new_branch,
    rename,
    trash_confirm,
    conflict,
    open_with,
    properties,
};

pub const Dialog = struct {
    kind: DialogKind,
    edit: Editor = .{},
    title: []const u8,
    target_path: ?[]u8 = null,
    conflict_name: ?[]u8 = null,
    deletion: deletion.State = .{},
    applications: ?open_with.State = null,
    properties: ?properties.State = null,
};

const RenameCard = struct { panel: header.Rect, field: header.Rect, confirm: header.Rect, cancel: header.Rect };

pub const App = struct {
    children: @import("../child_set.zig") = .{},
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
    column_weights: ?[5]f64 = null,
    git_column_weight: ?f64 = null,
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
    selection_band: ?struct {
        x: f64,
        y: f64, // Content coordinates, so the anchor survives edge scrolling.
        active: bool = false,
        toggle: bool,
        extend: bool,
        last_ms: i64,
    } = null,
    sidebar_scroll: i32 = 0,
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
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,

    // Title notification
    title_changed: bool = true,
    title_z: [256:0]u8 = [1:0]u8{0} ** 256,

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
        };

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
            self.sort_mode = @enumFromInt(prefs.sort);
        }
        self.pins_path = pins_mod.statePath(allocator, environ) catch null;
        if (self.pins_path) |path| self.pins = pins_mod.List.load(allocator, io, path);
        self.location.anchor = self.location.cursor;
        self.loading_since = nowMs();
        return self;
    }

    pub fn deinit(self: *App) void {
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

    fn updateTitle(self: *App) void {
        if (self.chooser) |opts| {
            const title = if (opts.title.len > 0) opts.title else switch (opts.mode) {
                .open => "Open File",
                .save => "Save As",
                .folder => "Choose Folder",
            };
            const len = @min(title.len, self.title_z.len - 1);
            @memcpy(self.title_z[0..len], title[0..len]);
            self.title_z[len] = 0;
            self.title_changed = true;
            return;
        }
        const cur = self.history.current;
        const name = if (self.isRecent()) "Recent" else if (self.trash_dir != null and std.mem.eql(u8, cur, self.trash_dir.?)) "Trash" else if (std.mem.eql(u8, cur, "/")) "/" else std.fs.path.basename(cur);
        _ = std.fmt.bufPrintZ(&self.title_z, "{s} — RediWM Files", .{name}) catch {
            @memcpy(self.title_z[0..12], "RediWM Files");
            self.title_z[12] = 0;
        };
        self.title_changed = true;
    }

    pub fn invalidate(self: *App) void {
        self.dirty = true;
        self.paint_damage = null;
    }

    const scan_notice_delay_ms: i64 = 500;

    fn beginLoading(self: *App) void {
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

    fn hoverBounds(self: *App, key: usize) ?header.Rect {
        if (key == 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (key >= 2_000_000) {
            const index = key - 2_000_000;
            return self.sizeButtonRect(index);
        }
        if (key >= 1000) {
            const index = key - 1000;
            if (index >= self.items.items.len or self.items.items[index].text().len > 8) return null; // May show a full-name tooltip.
            const i: i32 = @intCast(index);
            return .{ .x = @floatFromInt(self.sidebarWidth() + 19 + @mod(i, self.columns()) * self.cellWidth()), .y = @floatFromInt(self.viewTop() + self.itemInset() - 1 + @divTrunc(i, self.columns()) * self.rowHeight() - self.scroll_y), .w = @floatFromInt(self.cellWidth() - 18), .h = @floatFromInt(self.cardHeight() + 2) };
        }
        if (self.chooser != null and key >= 500 and key < 513) {
            if (key > 500) return self.chooserRect(key - 501);
            return .{ .x = 0, .y = @floatFromInt(self.h - self.footerHeight()), .w = @floatFromInt(self.w), .h = @floatFromInt(self.footerHeight()) };
        }
        if (key >= 300 and key < 300 + places.len) {
            const row = self.placeRect(key - 300);
            return .{ .x = row.x - 1, .y = row.y - 1, .w = row.w + 2, .h = row.h + 2 };
        }
        if (key >= 800 and key < 800 + pins_mod.max) {
            if (key - 800 >= self.pins.items.items.len) return null;
            const row = self.placeRect(pin_base + key - 800);
            return .{ .x = row.x - 1, .y = row.y - 1, .w = row.w + 2, .h = row.h + 2 };
        }
        if (key >= 600 and key < 800) {
            const index = self.deviceBase() + key % 100;
            if (!self.placeVisible(index)) return null;
            const row = if (key < 700) self.placeRect(index) else self.ejectRect(index);
            return .{ .x = row.x - 1, .y = row.y - 1, .w = row.w + 2, .h = row.h + 2 };
        }
        if (key >= 400 and key < 400 + column_labels.len) return self.listColumn(key - 400);
        if (key >= 200 and key < 200 + std.meta.tags(header.Action).len) {
            var rect = header.rect(self.w, self.inRepository(), @enumFromInt(key - 200));
            rect.x -= 1;
            rect.y -= 1;
            rect.w += 2;
            rect.h += 2;
            return rect;
        }
        return null;
    }

    const HoverLayout = struct { columns: i32 = 1, list: bool = false };

    /// Queues `rect` for the next partial repaint. A queued full repaint
    /// absorbs it; damage left over from the last paint is not pending, or
    /// every hover would grow the next repaint by all the ones before it.
    fn addDamage(self: *App, rect: header.Rect) void {
        if (self.dirty and self.paint_damage == null) return;
        self.paint_damage = if (self.dirty) unionRect(self.paint_damage.?, rect) else rect;
        self.dirty = true;
    }

    fn invalidateHover(self: *App, old: usize, new: usize) void {
        if (self.dirty and self.paint_damage == null) return;
        const before = self.hoverBounds(old) orelse {
            self.invalidate();
            return;
        };
        const after = self.hoverBounds(new) orelse {
            self.invalidate();
            return;
        };
        var rect = unionRect(before, after);
        // Out-of-viewport rows must not repaint over the pinned header or status.
        if ((old == 0 or old >= 1000) and (new == 0 or new >= 1000)) rect = self.clipToViewport(rect);
        self.addDamage(rect);
    }

    fn clipToViewport(self: *App, rect: header.Rect) header.Rect {
        const top: f64 = @floatFromInt(self.viewTop());
        const bottom = @min(rect.y + rect.h, @as(f64, @floatFromInt(self.h - self.footerHeight())));
        const y = @max(rect.y, top);
        return .{ .x = rect.x, .y = y, .w = rect.w, .h = @max(0, bottom - y) };
    }

    /// The pointer's sidebar row, unless that is the current place, which
    /// paints its own fill.
    fn hoveredPlace(self: *App) ?usize {
        if (self.dialog != null or self.menu != null) return null;
        const width: f64 = @floatFromInt(self.sidebarWidth());
        if (self.mouse_x < 0 or self.mouse_x >= width) return null;
        if (self.sidebarScrollbar()) |bar| if (self.mouse_x >= @as(f64, bar.track.x)) return null;
        if (self.mouse_y < @as(f64, @floatFromInt(self.contentTop())) or self.mouse_y >= @as(f64, @floatFromInt(self.h - self.footerHeight()))) return null;
        for (0..self.rowCount()) |i| {
            if (!self.placeVisible(i)) continue;
            const row = self.placeRect(i);
            if (self.mouse_y < row.y or self.mouse_y >= row.y + row.h) continue;
            return if (self.placeActive(i)) null else i;
        }
        return null;
    }

    /// The pointer's item, unless it is selected, which paints its own fill.
    fn hoveredItem(self: *App) ?usize {
        if (self.dialog != null or self.menu != null) return null;
        const idx = self.itemAt(self.mouse_x, self.mouse_y) orelse return null;
        return if (self.items.items[idx].selected) null else idx;
    }

    /// The sidebar highlight at fractional place `frame.row`, between the
    /// rows' real positions (they are not evenly spaced).
    fn navHighlight(self: *App, frame: hover_glide.Frame) header.Rect {
        const last = self.rowCount() - 1;
        const row = std.math.clamp(frame.row, 0, @as(f32, @floatFromInt(last)));
        const low: usize = @min(@as(usize, @intFromFloat(@floor(row))), last);
        const high = @min(low + 1, last);
        const t: f64 = row - @floor(row);
        var rect = self.placeRect(low);
        rect.y += (self.placeRect(high).y - rect.y) * t;
        return rect;
    }

    /// The item highlight at fractional cell (`frame.col`, `frame.row`).
    fn itemHighlight(self: *App, frame: hover_glide.Frame) header.Rect {
        const cell: f64 = @floatFromInt(self.cellWidth());
        return .{
            .x = @as(f64, @floatFromInt(self.sidebarWidth() + 20)) + frame.col * cell,
            .y = @as(f64, @floatFromInt(self.viewTop() + self.itemInset() - self.scroll_y)) + frame.row * @as(f64, @floatFromInt(self.rowHeight())),
            .w = cell - 20,
            .h = @floatFromInt(self.cardHeight()),
        };
    }

    fn toolbarButtonVisible(self: *App, action: header.Action) bool {
        return action != .git_view and !(self.chooser != null and
            (action == .cut or action == .copy or action == .paste or action == .trash));
    }

    fn toolbarButtonEnabled(self: *App, action: header.Action) bool {
        if (self.isRecent() and (action == .new or action == .paste)) return false;
        if (self.history.archive_len > 0) switch (action) {
            .new, .cut, .copy, .paste, .trash => return false,
            else => {},
        };
        return switch (action) {
            .back => self.history.canBack(),
            .forward => self.history.canForward(),
            .up => self.history.canUp(),
            .cut, .copy, .trash => self.hasSelection(),
            else => true,
        };
    }

    fn hoveredToolbarButton(self: *App) ?header.Rect {
        if (self.dialog != null or self.menu != null) return null;
        const action = header.hit(self.w, self.inRepository(), self.mouse_x, self.mouse_y) orelse return null;
        if (!self.toolbarButtonVisible(action) or !self.toolbarButtonEnabled(action)) return null;
        return header.rect(self.w, self.inRepository(), action);
    }

    /// Samples the hover highlights and queues damage for what moved or
    /// faded. Once per loop, before painting: the painters draw the sampled
    /// `frame`, so a partial repaint and a complete one agree.
    pub fn stepHover(self: *App, now: i64) void {
        const pixel = anim.rasterPixelQuantum(@floatFromInt(self.scale));

        if (self.sidebarWidth() > 0) {
            const before = self.nav_hover.frame;
            self.nav_hover.setTarget(now, if (self.hoveredPlace()) |i| .{ .col = 0, .row = @intCast(i) } else null);
            // Rows are at least 32 px apart, so this is at most a pixel.
            if (self.nav_hover.step(now, pixel, pixel / 32)) {
                const side: header.Rect = .{ .x = 0, .y = @floatFromInt(self.contentTop()), .w = @floatFromInt(self.sidebarWidth()), .h = @floatFromInt(self.h - self.contentTop() - self.footerHeight()) };
                self.damageHighlight(side, if (before.alpha > 0) self.navHighlight(before) else null, if (self.nav_hover.frame.alpha > 0) self.navHighlight(self.nav_hover.frame) else null);
            }
        } else self.nav_hover.reset();

        // Cells mean something else once the grid reflows or becomes a list.
        const layout: HoverLayout = .{ .columns = self.columns(), .list = self.list_view };
        if (!std.meta.eql(layout, self.item_hover_layout)) {
            self.item_hover_layout = layout;
            if (self.item_hover.frame.alpha > 0) self.invalidate();
            self.item_hover.reset();
        }
        const before = self.item_hover.frame;
        const per_row: usize = @intCast(self.columns());
        self.item_hover.setTarget(now, if (self.hoveredItem()) |idx| .{ .col = @intCast(idx % per_row), .row = @intCast(idx / per_row) } else null);
        const cell: f32 = @floatFromInt(@max(1, self.cellWidth()));
        const row: f32 = @floatFromInt(@max(1, self.rowHeight()));
        if (self.item_hover.step(now, pixel / cell, pixel / row)) {
            const view: header.Rect = self.clipToViewport(.{ .x = @floatFromInt(self.sidebarWidth()), .y = 0, .w = @floatFromInt(self.w - self.sidebarWidth()), .h = @floatFromInt(self.h) });
            self.damageHighlight(view, if (before.alpha > 0) self.itemHighlight(before) else null, if (self.item_hover.frame.alpha > 0) self.itemHighlight(self.item_hover.frame) else null);
        }
        if (self.toolbar_hover.step(now, self.hoveredToolbarButton(), pixel)) {
            self.addDamage(.{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.contentTop()) });
        }
        self.hover_active = self.nav_hover.animating(now) or self.item_hover.animating(now) or self.toolbar_hover.active(now);
        if (self.sort_feedback.step(now, false) and self.list_view) {
            // Full rows avoid cutting neighbouring rounded selection outlines.
            self.addDamage(.{ .x = @floatFromInt(self.sidebarWidth()), .y = @floatFromInt(self.contentTop()), .w = @floatFromInt(self.w - self.sidebarWidth()), .h = @floatFromInt(@max(0, self.h - self.contentTop() - self.footerHeight())) });
        }
        self.hover_active = self.hover_active or !self.sort_feedback.animation.settled(now);
        // Only visible cards need samples or a frame clock. Logical selection
        // changes immediately; painting and damage share these sampled fades.
        const viewport_h = @max(0, self.h - self.viewTop() - self.footerHeight());
        const first: usize = @min(self.items.items.len, @as(usize, @intCast(@divTrunc(self.scroll_y, self.rowHeight()))) * per_row);
        const last: usize = @min(self.items.items.len, @as(usize, @intCast(@divTrunc(self.scroll_y + viewport_h, self.rowHeight()) + 1)) * per_row);
        for (self.items.items[first..last], first..) |*item, idx| {
            const fill_changed = item.selection_fill.step(now, item.selected);
            const border_changed = item.selection_border.step(now, item.selected or self.focused_index == idx);
            if (fill_changed or border_changed) {
                var rect = self.itemHighlight(.{ .col = @floatFromInt(idx % per_row), .row = @floatFromInt(idx / per_row) });
                // Repair the whole row: a merged header/hover clip can otherwise
                // cut a neighbouring rounded card and change Cairo's antialiasing.
                rect.x = @floatFromInt(self.sidebarWidth());
                rect.w = @floatFromInt(self.w - self.sidebarWidth());
                rect.y -= 1;
                rect.h += 2;
                self.addDamage(self.clipToViewport(rect));
            }
            self.hover_active = self.hover_active or !item.selection_fill.animation.settled(now) or !item.selection_border.animation.settled(now);
        }
        const field = header.field(self.w);
        const hit = if (!self.search_visible and self.focus != .location_bar and
            self.dialog == null and self.menu == null and field.contains(self.mouse_x, self.mouse_y))
            self.breadcrumbs(null, self.mouse_x)
        else
            null;
        for (&self.breadcrumb_hover, 0..) |*fade, i| {
            fade.setTarget(now, if (hit != null and hit.?.index == i) .{ .col = 0, .row = 0 } else null);
            if (fade.step(now, 1, 1)) self.addDamage(field);
            self.hover_active = self.hover_active or fade.animating(now);
        }
    }

    /// Damage for a highlight that moved from `old` to `new` (null when it
    /// was not drawn), inside `area`; a pixel wider for the border's edge.
    fn damageHighlight(self: *App, area: header.Rect, old: ?header.Rect, new: ?header.Rect) void {
        var rect: header.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        for ([_]?header.Rect{ old, new }) |candidate| {
            const r = candidate orelse continue;
            rect = unionRect(rect, .{ .x = r.x - 1, .y = r.y - 1, .w = r.w + 2, .h = r.h + 2 });
        }
        const x1 = @max(rect.x, area.x);
        const y1 = @max(rect.y, area.y);
        const x2 = @min(rect.x + rect.w, area.x + area.w);
        const y2 = @min(rect.y + rect.h, area.y + area.h);
        if (x2 <= x1 or y2 <= y1) return;
        self.addDamage(.{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 });
    }

    fn unionRect(a: header.Rect, b: header.Rect) header.Rect {
        if (a.w == 0 or a.h == 0) return b;
        if (b.w == 0 or b.h == 0) return a;
        const x = @min(a.x, b.x);
        const y = @min(a.y, b.y);
        return .{ .x = x, .y = y, .w = @max(a.x + a.w, b.x + b.w) - x, .h = @max(a.y + a.h, b.y + b.h) - y };
    }

    pub fn resize(self: *App, new_w: i32, new_h: i32) void {
        if (self.w != new_w or self.h != new_h) {
            self.cancelWheel();
            self.cancelDrag();
            self.sidebar_scroll_drag.end();
            self.w = @max(360, new_w);
            self.h = @max(240, new_h);
            self.clampScroll();
            self.clampSidebarScroll();
            if (self.menu) |kind| self.openMenu(kind, self.menu_x, self.menu_y);
            self.invalidate();
        }
    }

    fn savePreferences(self: *App) void {
        const path = self.preferences_path orelse return;
        (Preferences{ .list = self.non_git_list_view orelse self.list_view, .sort = @intFromEnum(self.sort_mode), .unpinned_places = self.unpinned_places, .git_view = self.git_view }).save(self.allocator, self.io, path) catch {
            self.setStatusNotice("Could not save view preferences", true);
        };
    }

    fn rememberView(self: *App) void {
        if (self.loading) return;
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

    fn restoreView(self: *App) void {
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

    pub fn navigate(self: *App, new_path: []const u8) void {
        if (self.chooser != null and recent.isLocation(new_path)) return;
        self.rememberView();
        self.history.navigate(new_path) catch return;
        self.applyHistoryNav(self.history.current);
    }

    pub fn refresh(self: *App) void {
        self.clearFolderSizes();
        self.beginLoading();
        self.active_request_id = self.worker.refresh();
        self.invalidate();
    }

    pub fn toggleHidden(self: *App) void {
        self.show_hidden = !self.show_hidden;
        self.beginLoading();
        self.active_request_id = self.worker.setShowHidden(self.show_hidden);
        self.invalidate();
    }

    pub fn selectOnLoad(self: *App, path: []const u8) void {
        self.initial_selection = path;
        if (std.mem.startsWith(u8, std.fs.path.basename(path), ".")) self.toggleHidden();
    }

    pub fn back(self: *App) void {
        self.rememberView();
        if (self.history.back() catch null) |path| {
            self.applyHistoryNav(path);
        }
    }

    pub fn forward(self: *App) void {
        self.rememberView();
        if (self.history.forward() catch null) |path| {
            self.applyHistoryNav(path);
        }
    }

    pub fn up(self: *App) void {
        self.rememberView();
        if (self.history.up() catch null) |path| {
            self.applyHistoryNav(path);
        }
    }

    pub fn home(self: *App) void {
        self.rememberView();
        if (self.history.home(self.home_dir) catch null) |path| {
            self.applyHistoryNav(path);
        }
    }

    fn applyHistoryNav(self: *App, path: []const u8) void {
        self.navigation_count +%= 1;
        self.overwrite_pending = false;
        if (self.chooser != null and self.chooser.?.mode == .open) self.setChooserName("");
        self.cancelWheel();
        self.cancelDrag();
        self.cancelRunningFolderSizes();
        self.restore_view = true;
        self.edit_revision += 1;
        self.text_dragging = false;
        self.updateTitle();
        self.menu = null;
        self.search.text.clearRetainingCapacity();
        self.search.cursor = 0;
        self.search_visible = false;
        self.items.clearRetainingCapacity();
        if (self.snapshot) |snap| snap.destroy();
        self.snapshot = null;
        self.scroll_y = 0;
        self.selection_anchor = null;
        self.focused_index = null;
        self.beginLoading();
        self.error_message = null;

        self.location.text.clearRetainingCapacity();
        self.location.text.appendSlice(self.allocator, path) catch {};
        self.location.cursor = self.location.text.items.len;
        self.location.select_all = false;
        self.location.anchor = self.location.cursor;
        self.location.scroll = 0;

        self.active_request_id = self.worker.navigateLocation(path, self.show_hidden, self.history.archive_len);
        self.invalidate();
    }

    // A navigate()/refresh()/toggleHidden() call bumps active_request_id and
    // tags the worker request with it; the worker may still be finishing a
    // scan for an earlier request when the new one lands. Applying that
    // snapshot anyway would flash the previous directory's listing (or an
    // empty/error state from a request that's since been superseded).
    pub fn isStaleSnapshot(snapshot_request_id: u64, active_request_id: u64) bool {
        return snapshot_request_id < active_request_id;
    }

    pub fn sync(self: *App) void {
        self.syncFolderSizes();
        _ = c.pthread_mutex_lock(&self.worker.mutex);
        const animation_settings = self.worker.animation_settings;
        const new_theme = self.worker.theme;
        self.worker.theme = null;
        _ = c.pthread_mutex_unlock(&self.worker.mutex);
        if (new_theme) |t| {
            t.apply();
            self.invalidate();
        }
        if (!anim.currentSettings().eql(animation_settings)) {
            self.cancelWheel();
            anim.applySettings(animation_settings);
        }
        const width: f32 = @bitCast(self.worker.scrollbar_width.load(.acquire));
        if (width != self.scrollbar_width) {
            self.scrollbar_width = width;
            self.clampScroll();
            self.invalidate();
        }
        if (self.job_runner) |runner| {
            const progress = runner.pollProgress();
            if (progress.state == .waiting_conflict) {
                if (self.dialog == null or self.dialog.?.kind != .conflict) {
                    self.openConflictDialog(progress.conflict_item_name);
                }
            } else if (self.dialog != null and self.dialog.?.kind == .conflict and progress.state != .waiting_conflict) {
                self.closeDialog();
            }

            if (progress.state == .finished) {
                if (self.job_was_running) {
                    self.job_was_running = false;
                    self.setStatusNotice(progress.status_message, progress.is_error);
                    if (self.clipboard_cut and !self.clipboard_is_text and self.job_cut_revision == self.clipboard_revision) {
                        var i: usize = 0;
                        var changed = false;
                        while (i < self.clipboard_paths.items.len) {
                            if (runner.movedSuccessfully(self.clipboard_paths.items[i])) {
                                self.allocator.free(self.clipboard_paths.orderedRemove(i));
                                changed = true;
                            } else i += 1;
                        }
                        if (self.clipboard_paths.items.len == 0) self.clipboard_cut = false;
                        if (changed) self.clipboard_revision += 1;
                    }
                    if (runner.kind == .open_archive_member) {
                        if (runner.result_path) |path| {
                            if (self.archive_open_navigation == self.navigation_count) self.openExtracted(path, self.archive_preview);
                        }
                    } else self.refresh();
                }
            } else if (progress.state == .running or progress.state == .waiting_conflict) {
                self.job_was_running = true;
                if (self.job_progress != progress.processed_items or self.job_state != progress.state) self.invalidate();
            }
            self.job_progress = progress.processed_items;
            self.job_state = progress.state;
        }
        if (self.status_notice != null and nowMs() >= self.status_notice_until) {
            self.allocator.free(self.status_notice.?);
            self.status_notice = null;
            self.invalidate();
        }

        // A background refresh must not reorder items or cancel a gesture
        // while the button is held. The worker retains its latest snapshot;
        // the first loop after release applies it.
        if (self.selection_band != null or self.drag_origin != null) return;
        const snap = self.worker.takeSnapshot() orelse return;
        if (isStaleSnapshot(snap.request_id, self.active_request_id)) {
            snap.destroy();
            return;
        }
        if (self.snapshot) |old| old.destroy();
        self.snapshot = snap;
        self.syncGitLayout();
        self.column_resize = null;
        self.clampSidebarScroll();
        self.loading = false;
        self.rebuildView();
        if (self.restore_view) self.restoreView();
        if (self.initial_selection) |path| {
            self.initial_selection = null;
            for (self.items.items, 0..) |*item, i| {
                if (!std.mem.eql(u8, item.path, path)) continue;
                item.selected = true;
                self.focused_index = i;
                self.selection_anchor = i;
                self.revealIndex(i);
                break;
            }
        }
    }

    /// Repositories list as one Git column and ignore the grid, but the user's
    /// own grid/list choice returns as soon as the Git view is not in effect.
    fn syncGitLayout(self: *App) void {
        if (self.repository() != null) {
            if (self.non_git_list_view == null) self.non_git_list_view = self.list_view;
            self.list_view = true;
        } else if (self.non_git_list_view) |previous| {
            self.list_view = previous;
            self.non_git_list_view = null;
        }
    }

    fn setGitView(self: *App, on: bool) void {
        if (self.git_view == on) return;
        self.git_view = on;
        self.savePreferences();
        self.syncGitLayout();
        self.column_resize = null;
        self.scroll_y = 0;
        self.nav_hover = .{};
        self.rebuildView();
        self.clampSidebarScroll();
        self.last_click_index = null;
    }

    /// The Git view with only changed files lists them flat, from any depth.
    fn shownName(self: *App, item: worker_mod.Item) []const u8 {
        return if (self.changedOnly() and self.full_paths and item.label.len > 0) item.label else item.name;
    }

    fn matches(self: *App, item: worker_mod.Item) bool {
        // Deleted tracked files are rows of the Git view only.
        if (item.missing and self.repository() == null) return false;
        if (self.chooser) |opts| {
            if (!item.is_dir) {
                if (opts.mode == .folder) return false;
                if (opts.filters.len > 0 and !chooser_mod.matches(opts.filters[@min(opts.filter_index, opts.filters.len - 1)], item.name)) return false;
            }
        }
        if (self.folders_only and !item.is_dir) return false;
        return std.ascii.indexOfIgnoreCase(self.shownName(item), self.search.text.items) != null;
    }

    fn lessThan(mode: Sort, a: ViewItem, b: ViewItem) bool {
        // Sorting by date mixes folders and files; every other order groups folders first.
        if (mode != .modified and mode != .modified_asc and a.is_dir != b.is_dir) return a.is_dir;
        if (mode == .size or mode == .size_asc) {
            if (a.is_dir and b.is_dir) {
                const a_calc = a.bytes >= 0;
                const b_calc = b.bytes >= 0;
                if (a_calc != b_calc) return a_calc;
                if (a_calc and b_calc and a.bytes != b.bytes) {
                    return if (mode == .size) a.bytes > b.bytes else a.bytes < b.bytes;
                }
            } else if (a.bytes != b.bytes) {
                return if (mode == .size) a.bytes > b.bytes else a.bytes < b.bytes;
            }
        }
        const a_date = if (a.opened != 0) a.opened else a.mtime;
        const b_date = if (b.opened != 0) b.opened else b.mtime;
        if (mode == .modified and a_date != b_date) return a_date > b_date;
        if (mode == .modified_asc and a_date != b_date) return a_date < b_date;
        if (mode == .type or mode == .type_desc) {
            const order = std.mem.order(u8, itemType(a), itemType(b));
            if (order != .eq) return if (mode == .type) order == .lt else order == .gt;
        }
        const order = std.mem.order(u8, a.text(), b.text());
        return if (mode == .name_desc) order == .gt else order == .lt;
    }

    pub fn rebuildView(self: *App) void {
        const snap = self.snapshot orelse return;
        // Keep old storage alive until names, selection and focus have been copied.
        // Both a worker refresh and a local filter can rebuild this view.
        self.cancelWheel();
        self.cancelDrag();
        self.view_revision +%= 1;
        var old_arena = self.items_arena;
        defer old_arena.deinit();
        var old_items = self.items;
        defer old_items.deinit(self.allocator);
        const old_focus = if (self.focused_index) |i| (if (i < old_items.items.len) old_items.items[i].path else null) else null;
        const old_anchor = if (self.selection_anchor) |i| (if (i < old_items.items.len) old_items.items[i].path else null) else null;
        var selected_paths = std.StringHashMap(ViewItem).init(self.allocator);
        defer selected_paths.deinit();
        for (old_items.items) |item| {
            if (item.selected or item.selection_fill.alpha > 0 or item.selection_border.alpha > 0) selected_paths.put(item.path, item) catch {};
        }
        self.items_arena = std.heap.ArenaAllocator.init(self.allocator);
        const mem = self.items_arena.allocator();
        self.items = .empty;
        self.error_message = snap.err_msg;
        self.focused_index = null;
        self.selection_anchor = null;
        self.last_click_index = null;
        if (snap.err_msg == null) {
            for (if (self.changedOnly()) snap.changed else snap.items) |it| {
                if (!self.matches(it)) continue;
                const previous = selected_paths.get(it.path);
                const selected = if (previous) |item| item.selected else false;
                var bytes = it.bytes;
                if (it.is_dir and !it.is_symlink) {
                    if (self.folder_sizes.get(it.path)) |sz| {
                        switch (sz) {
                            .done => |d| bytes = d.bytes,
                            else => bytes = -1,
                        }
                    } else {
                        bytes = -1;
                    }
                }
                self.items.append(self.allocator, .{
                    .name = mem.dupe(u8, it.name) catch continue,
                    .label = mem.dupe(u8, if (self.changedOnly() and self.full_paths) it.label else "") catch continue,
                    .path = mem.dupe(u8, it.path) catch continue,
                    .is_dir = it.is_dir,
                    .is_symlink = it.is_symlink,
                    .is_broken = it.is_broken,
                    .git_status = it.git_status,
                    .git_lines = it.git_lines,
                    .missing = it.missing,
                    .bytes = bytes,
                    .mtime = it.mtime,
                    .opened = it.opened,
                    .mode = it.mode,
                    .permissions_text = std.fmt.allocPrint(mem, "{s} ({s})", .{ formatPermissions(it.mode), it.owner }) catch continue,
                    .icon_name = mem.dupe(u8, it.icon_name) catch continue,
                    .icon_candidates = @import("associations.zig").dupeCandidates(mem, it.icon_candidates) catch continue,
                    .selected = selected,
                    .selection_fill = if (previous) |item| item.selection_fill else .{},
                    .selection_border = if (previous) |item| item.selection_border else .{},
                }) catch continue;
            }
            std.mem.sort(ViewItem, self.items.items, self.effectiveSort(), lessThan);
            for (self.items.items, 0..) |item, i| {
                if (old_focus) |path| {
                    if (std.mem.eql(u8, path, item.path)) self.focused_index = i;
                }
                if (old_anchor) |path| {
                    if (std.mem.eql(u8, path, item.path)) self.selection_anchor = i;
                }
            }
        }
        self.clampScroll();
        self.invalidate();
    }

    pub fn setStatusNotice(self: *App, msg: []const u8, is_error: bool) void {
        if (self.status_notice) |sn| self.allocator.free(sn);
        self.status_notice = self.allocator.dupe(u8, msg) catch null;
        self.status_notice_until = nowMs() + 4000;
        self.status_is_error = is_error;
        self.invalidate();
    }

    pub fn closeDialog(self: *App) void {
        self.text_dragging = false;
        self.edit_revision += 1;
        if (self.dialog) |*dlg| {
            dlg.deletion.deinit();
            if (dlg.applications) |*apps| apps.deinit();
            if (dlg.properties) |*props| props.deinit();
            dlg.edit.text.deinit(self.allocator);
            if (dlg.target_path) |tp| self.allocator.free(tp);
            if (dlg.conflict_name) |cn| self.allocator.free(cn);
            self.dialog = null;
            self.invalidate();
        }
    }

    fn openProperties(self: *App, path: []const u8, preview: ?icons.Entry) void {
        const state = properties.State.init(self.allocator, path, preview) catch {
            self.setStatusNotice("Could not read file properties", true);
            return;
        };
        self.closeDialog();
        self.dialog = .{ .kind = .properties, .title = "Properties", .properties = state };
        self.invalidate();
    }

    fn openSelectedProperties(self: *App) void {
        if (self.history.archive_len > 0) return;
        var selected: ?ViewItem = null;
        for (self.items.items) |item| {
            if (!item.selected or item.missing) continue;
            if (selected != null) {
                self.setStatusNotice("Select one item to view its properties", false);
                return;
            }
            selected = item;
        }
        if (selected) |item| self.openProperties(item.path, self.itemIcon(item, 48 * self.scale));
    }

    fn propertiesAction(self: *App, action: properties.Action) void {
        switch (action) {
            .none => self.invalidate(),
            .close => {
                const changed = self.dialog.?.properties.?.changed;
                self.closeDialog();
                if (changed) self.refresh();
            },
            .open => {
                const props = &self.dialog.?.properties.?;
                const path = self.allocator.dupe(u8, props.path) catch return;
                defer self.allocator.free(path);
                const folder = props.isDirectory();
                const changed = props.changed;
                self.closeDialog();
                if (folder) self.navigate(path) else {
                    if (changed) self.refresh();
                    self.openFile(path);
                }
            },
        }
    }

    fn canOpenWith(self: *const App) bool {
        if (self.history.archive_len > 0) return false;
        if (self.chooser != null) return false;
        var found = false;
        for (self.items.items) |item| {
            if (!item.selected) continue;
            if (item.is_dir or item.missing or item.is_broken) return false;
            found = true;
        }
        return found;
    }

    fn openWithDialog(self: *App) void {
        if (!self.canOpenWith()) return;
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.allocator);
        for (self.items.items) |item| {
            if (item.selected) paths.append(self.allocator, item.path) catch return;
        }
        const state = open_with.State.init(self.allocator, paths.items) catch {
            self.setStatusNotice("Could not load applications", true);
            return;
        };
        self.closeDialog();
        self.dialog = .{ .kind = .open_with, .title = "Open With", .applications = state };
        self.invalidate();
    }

    fn openWithAction(self: *App, action: open_with.Action) void {
        switch (action) {
            .cancel => self.closeDialog(),
            .open => {
                if (self.dialog.?.applications.?.open()) {
                    const message = self.dialog.?.applications.?.message;
                    if (message.len == 0) {
                        for (self.dialog.?.applications.?.apps.paths) |path| self.worker.recordOpened(path);
                    }
                    self.closeDialog();
                    if (message.len > 0) self.setStatusNotice(message, true);
                    self.refresh();
                }
            },
            .none => {},
        }
        self.invalidate();
    }

    pub fn openNewFolderDialog(self: *App) void {
        if (self.isRecent() or self.history.archive_len > 0) return;
        self.closeDialog();
        var dlg = Dialog{
            .kind = .new_folder,
            .title = "New Folder",
        };
        dlg.edit.text.appendSlice(self.allocator, "New Folder") catch return;
        dlg.edit.cursor = dlg.edit.text.items.len;
        dlg.edit.select_all = true;
        self.dialog = dlg;
        self.invalidate();
    }

    pub fn openNewBranchDialog(self: *App) void {
        self.closeDialog();
        self.dialog = Dialog{ .kind = .new_branch, .title = "New Branch" };
        self.invalidate();
    }

    fn switchBranch(self: *App, repo: git.Repository, name: []const u8, create: bool) void {
        const outcome = git.switchBranch(self.allocator, self.io, self.environ, repo.directory, name, create);
        var buf: [256]u8 = undefined;
        if (outcome.ok) {
            const msg = std.fmt.bufPrint(&buf, "{s} {s}", .{ if (create) "Created and switched to" else "Switched to", name }) catch "Switched branch";
            self.setStatusNotice(msg, false);
        } else {
            self.setStatusNotice(outcome.text(), true);
        }
        self.refresh();
    }

    pub fn openNewFileDialog(self: *App) void {
        if (self.isRecent() or self.history.archive_len > 0) return;
        self.closeDialog();
        var dlg = Dialog{
            .kind = .new_file,
            .title = "New File",
        };
        dlg.edit.text.appendSlice(self.allocator, "New File.txt") catch return;
        dlg.edit.cursor = dlg.edit.text.items.len;
        dlg.edit.select_all = true;
        self.dialog = dlg;
        self.invalidate();
    }

    pub fn openRenameDialog(self: *App) void {
        if (self.history.archive_len > 0) return;
        const idx = self.focused_index orelse blk: {
            for (self.items.items, 0..) |it, i| {
                if (it.selected) break :blk i;
            }
            return;
        };
        if (idx >= self.items.items.len) return;
        const item = self.items.items[idx];
        if (item.missing) return;

        self.closeDialog();
        const target_path = self.allocator.dupe(u8, item.path) catch return;
        var dlg = Dialog{
            .kind = .rename,
            .title = "Rename",
            .target_path = target_path,
        };
        dlg.edit.text.appendSlice(self.allocator, item.name) catch {
            self.allocator.free(target_path);
            return;
        };
        // Select the stem, so typing keeps the extension; folders and dotfiles
        // select the whole name.
        const dot = std.mem.lastIndexOfScalar(u8, item.name, '.') orelse item.name.len;
        const end = if (!item.is_dir and dot > 0) dot else item.name.len;
        dlg.edit.cursor = end;
        dlg.edit.anchor = 0;
        self.dialog = dlg;
        self.invalidate();
    }

    pub fn openTrashConfirmDialog(self: *App) void {
        if (self.history.archive_len > 0) return;
        var count: usize = 0;
        for (self.items.items) |it| {
            if (it.selected and !it.missing) count += 1;
        }
        if (count == 0) {
            if (self.focused_index) |idx| {
                if (idx < self.items.items.len and !self.items.items[idx].missing) {
                    self.items.items[idx].selected = true;
                    count = 1;
                }
            }
        }
        if (count == 0) return;

        self.closeDialog();
        self.dialog = Dialog{
            .kind = .trash_confirm,
            .title = "Move to Trash?",
        };
        for (self.items.items) |it| {
            if (!it.selected or it.missing) continue;
            const preview = if (self.dialog.?.deletion.paths.items.len == 0) self.itemIcon(it, 64 * self.scale) else null;
            self.dialog.?.deletion.add(it.path, it.name, it.is_dir and !it.is_symlink, it.bytes, preview) catch {
                self.closeDialog();
                self.setStatusNotice("Unable to prepare deletion", true);
                return;
            };
        }
        self.invalidate();
    }

    pub fn openConflictDialog(self: *App, conflict_name: []const u8) void {
        self.closeDialog();
        self.dialog = Dialog{
            .kind = .conflict,
            .title = "File Conflict",
            .conflict_name = self.allocator.dupe(u8, conflict_name) catch null,
        };
        self.invalidate();
    }

    pub fn confirmDialog(self: *App) void {
        const dlg = self.dialog orelse return;
        switch (dlg.kind) {
            .open_with => self.openWithAction(.open),
            .properties => {},
            .new_folder => {
                const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
                ops_mod.createFolder(self.allocator, self.history.current, name) catch |err| {
                    const msg = switch (err) {
                        error.PathAlreadyExists => "Folder already exists",
                        error.AccessDenied => "Permission denied",
                        error.EmptyName => "Name cannot be empty",
                        error.InvalidCharacter => "Invalid characters in name",
                        error.ReservedName => "Reserved folder name",
                        else => "Failed to create folder",
                    };
                    self.setStatusNotice(msg, true);
                    self.closeDialog();
                    return;
                };
                self.closeDialog();
                self.setStatusNotice("Folder created", false);
                self.refresh();
            },
            .new_branch => {
                const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
                // `name` borrows the dialog's text: use it before closing.
                if (self.repository()) |repo| self.switchBranch(repo, name, true);
                self.closeDialog();
            },
            .new_file => {
                const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
                ops_mod.createFile(self.allocator, self.history.current, name) catch |err| {
                    const msg = switch (err) {
                        error.PathAlreadyExists => "File already exists",
                        error.AccessDenied => "Permission denied",
                        error.EmptyName => "Name cannot be empty",
                        error.InvalidCharacter => "Invalid characters in name",
                        error.ReservedName => "Reserved file name",
                        else => "Failed to create file",
                    };
                    self.setStatusNotice(msg, true);
                    self.closeDialog();
                    return;
                };
                self.closeDialog();
                self.setStatusNotice("File created", false);
                self.refresh();
            },
            .rename => {
                const name = std.mem.trim(u8, dlg.edit.text.items, " \t\r\n");
                const target = dlg.target_path orelse "";
                ops_mod.renameItem(self.allocator, target, name) catch |err| {
                    const msg = switch (err) {
                        error.PathAlreadyExists => "Target name already exists",
                        error.AccessDenied => "Permission denied",
                        error.EmptyName => "Name cannot be empty",
                        error.InvalidCharacter => "Invalid characters in name",
                        else => "Failed to rename",
                    };
                    self.setStatusNotice(msg, true);
                    self.closeDialog();
                    return;
                };
                self.closeDialog();
                self.setStatusNotice("Renamed successfully", false);
                self.refresh();
            },
            .trash_confirm => {
                self.executeDeletion();
                self.closeDialog();
            },
            .conflict => {
                if (self.job_runner) |runner| {
                    runner.resolveConflict(.skip);
                }
                self.closeDialog();
            },
        }
    }

    fn handleDialogKey(self: *App, sym: u32, utf8: []const u8) void {
        var dlg = &(self.dialog orelse return);

        if (dlg.kind == .properties) {
            const action = self.dialog.?.properties.?.key(sym, self.shift, self.w, self.h);
            self.propertiesAction(action);
            return;
        }
        if (dlg.kind == .open_with) {
            const action = self.dialog.?.applications.?.key(sym, self.shift, self.w, self.h);
            self.openWithAction(action);
            return;
        }
        if (dlg.kind == .trash_confirm) {
            self.deleteAction(self.dialog.?.deletion.key(sym));
            return;
        }
        if (dlg.kind == .conflict) {
            if (sym == c.XKB_KEY_s or sym == c.XKB_KEY_S) {
                if (self.job_runner) |runner| runner.resolveConflict(.skip);
                self.closeDialog();
                return;
            } else if (sym == c.XKB_KEY_r or sym == c.XKB_KEY_R) {
                if (self.job_runner) |runner| runner.resolveConflict(.rename);
                self.closeDialog();
                return;
            } else if (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C or sym == c.XKB_KEY_Escape) {
                if (self.job_runner) |runner| runner.resolveConflict(.cancel);
                self.closeDialog();
                return;
            }
            return;
        }

        if (sym == c.XKB_KEY_Escape) {
            self.closeDialog();
            return;
        } else if (sym == c.XKB_KEY_Return) {
            self.confirmDialog();
            return;
        }

        self.editKey(&dlg.edit, sym, utf8);
    }

    pub fn copySelected(self: *App) void {
        if (self.history.archive_len > 0) return;
        if (!self.hasSelection()) return;
        self.clipboard_is_text = false;
        self.clearClipboard();
        for (self.items.items) |it| {
            if (it.selected and !it.missing) {
                self.clipboard_paths.append(self.allocator, self.allocator.dupe(u8, it.path) catch continue) catch continue;
            }
        }
        if (self.clipboard_paths.items.len > 0) {
            self.clipboard_cut = false;
            self.clipboard_revision += 1;
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Copied {d} item(s)", .{self.clipboard_paths.items.len}) catch "Copied";
            self.setStatusNotice(msg, false);
            self.invalidate();
        }
    }

    pub fn cutSelected(self: *App) void {
        if (self.history.archive_len > 0) return;
        if (!self.hasSelection()) return;
        self.clipboard_is_text = false;
        self.clearClipboard();
        for (self.items.items) |it| {
            if (it.selected and !it.missing) {
                self.clipboard_paths.append(self.allocator, self.allocator.dupe(u8, it.path) catch continue) catch continue;
            }
        }
        if (self.clipboard_paths.items.len > 0) {
            self.clipboard_cut = true;
            self.clipboard_revision += 1;
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Cut {d} item(s)", .{self.clipboard_paths.items.len}) catch "Cut";
            self.setStatusNotice(msg, false);
            self.invalidate();
        }
    }

    pub fn calculateSizeSelected(self: *App) void {
        if (self.history.archive_len > 0) return;
        var any = false;
        for (self.items.items, 0..) |it, idx| {
            if (it.selected and it.is_dir and !it.is_symlink) {
                self.startFolderSize(idx);
                any = true;
            }
        }
        if (!any) {
            if (self.focused_index) |idx| {
                if (idx < self.items.items.len) {
                    const it = self.items.items[idx];
                    if (it.is_dir and !it.is_symlink) {
                        self.startFolderSize(idx);
                    }
                }
            }
        }
    }

    pub fn executePaste(self: *App, kind: ops_mod.OpKind, paths: []const []const u8) bool {
        if (self.isRecent()) return false;
        return self.executeTransfer(kind, paths, self.history.current, true);
    }

    pub fn executeTransfer(self: *App, kind: ops_mod.OpKind, paths: []const []const u8, directory: []const u8, clipboard: bool) bool {
        if (self.history.archive_len > 0 or recent.isLocation(directory)) return false;
        if (paths.len == 0) return false;
        const runner = self.job_runner orelse return false;
        runner.start(kind, paths, directory, .ask) catch {
            self.setStatusNotice("Failed to start transfer job", true);
            return false;
        };
        self.job_cut_revision = if (clipboard and kind == .move and self.clipboard_cut) self.clipboard_revision else null;
        self.job_was_running = true;
        self.invalidate();
        return true;
    }

    pub fn executePasteLocal(self: *App) void {
        if (self.clipboard_paths.items.len == 0) return;
        const kind: ops_mod.OpKind = if (self.clipboard_cut) .move else .copy;
        _ = self.executePaste(kind, self.clipboard_paths.items);
    }

    pub fn executePasteExternal(self: *App, mode: clipboard_mod.ClipboardMode, paths: []const []const u8) void {
        const kind: ops_mod.OpKind = if (mode == .cut) .move else .copy;
        if (!self.executePaste(kind, paths)) return;
        // Retain external cut entries too; completion republishes only remaining items.
        if (mode == .cut) {
            self.clearClipboard();
            for (paths) |path| {
                const owned = self.allocator.dupe(u8, path) catch continue;
                self.clipboard_paths.append(self.allocator, owned) catch self.allocator.free(owned);
            }
            self.clipboard_cut = true;
            self.clipboard_is_text = false;
            self.clipboard_revision += 1;
            self.job_cut_revision = self.clipboard_revision;
        }
    }

    fn deleteAction(self: *App, action: deletion.Action) void {
        switch (action) {
            .cancel => self.closeDialog(),
            .confirm => self.confirmDialog(),
            .toggle => {
                self.dialog.?.deletion.permanent = !self.dialog.?.deletion.permanent;
                self.dialog.?.deletion.focus = .toggle;
            },
            .none => {},
        }
        self.invalidate();
    }

    fn executeDeletion(self: *App) void {
        const state = &self.dialog.?.deletion;
        const result = if (state.permanent) ops_mod.deleteItems(self.io, state.paths.items) else ops_mod.trashItems(self.io, state.paths.items);
        result catch |err| {
            self.setStatusNotice(if (state.permanent) "Could not delete all items" else if (err == error.GioNotAvailable) "Trash unavailable (gio not installed)" else "Could not move all items to Trash", true);
            self.refresh();
            return;
        };
        self.setStatusNotice(if (state.permanent) "Items permanently deleted" else "Items moved to Trash", false);
        self.refresh();
    }

    pub fn configureChooser(self: *App, options: chooser_mod.Options) !void {
        self.chooser = options;
        if (options.filters.len > 0) self.chooser.?.filter_index = @min(options.filter_index, options.filters.len - 1);
        for (options.filters) |filter| try self.chooser_filter_labels.append(self.allocator, filter.name);
        self.list_view = true;
        if (self.preferences_path) |path| self.allocator.free(path);
        self.preferences_path = null;
        self.setChooserName(options.current_name);
        for (options.choices) |choice| {
            var selected: []const u8 = if (choice.values.len == 0) "false" else choice.values[0].id;
            if (choice.values.len == 0 and std.mem.eql(u8, choice.selected, "true")) selected = "true";
            for (choice.values) |value| if (std.mem.eql(u8, choice.selected, value.id)) {
                selected = value.id;
            };
            try self.chooser_choices.append(self.allocator, selected);
        }
        self.h = @max(self.h, self.footerHeight() + 300);
        self.focus = if (options.mode == .save) .filename else .file_view;
        self.filename.select_all = true;
        self.updateTitle();
    }

    fn setChooserName(self: *App, name: []const u8) void {
        self.filename.text.clearRetainingCapacity();
        self.filename.text.appendSlice(self.allocator, name) catch {};
        self.filename.cursor = self.filename.text.items.len;
        self.filename.anchor = self.filename.cursor;
        self.filename.select_all = false;
        self.filename.scroll = 0;
        self.overwrite_pending = false;
    }

    fn chooserRect(self: *App, index: usize) header.Rect {
        const width: f64 = @floatFromInt(self.w);
        const top: f64 = @floatFromInt(self.h - self.footerHeight());
        if (self.w >= 800) return switch (index) {
            0 => .{ .x = 96, .y = top + 24, .w = width - 508, .h = 36 },
            1 => .{ .x = width - 108, .y = top + 24, .w = 92, .h = 36 },
            2 => .{ .x = width - 210, .y = top + 24, .w = 92, .h = 36 },
            3 => .{ .x = width - 400, .y = top + 24, .w = 178, .h = 36 },
            else => .{ .x = 16, .y = top + 82 + @as(f64, @floatFromInt(index - 4)) * 36, .w = width - 32, .h = 32 },
        };
        return switch (index) {
            0 => .{ .x = 96, .y = top + 12, .w = width - 112, .h = 34 },
            1 => .{ .x = width - 108, .y = top + 60, .w = 92, .h = 36 },
            2 => .{ .x = width - 210, .y = top + 60, .w = 92, .h = 36 },
            3 => .{ .x = 16, .y = top + 60, .w = width - 242, .h = 36 },
            else => .{ .x = 16, .y = top + 108 + @as(f64, @floatFromInt(index - 4)) * 36, .w = width - 32, .h = 32 },
        };
    }

    fn cycleChooserFilter(self: *App, reverse: bool) void {
        const opts = &self.chooser.?;
        if (opts.filters.len == 0) return;
        opts.filter_index = (opts.filter_index + opts.filters.len + (if (reverse) @as(usize, 0) else 2) - 1) % opts.filters.len;
        self.rebuildView();
        self.invalidate();
    }

    fn chooserClick(self: *App, x: f64, y: f64, button: u32) bool {
        if (y < @as(f64, @floatFromInt(self.h - self.footerHeight()))) {
            self.overwrite_pending = false;
            return false;
        }
        if (button != 0x110) return true;
        if (self.chooserRect(1).contains(x, y)) self.acceptChooser() else if (self.chooserRect(2).contains(x, y)) {
            if (self.overwrite_pending) self.overwrite_pending = false else self.chooser_done = true;
        } else if (self.chooserRect(0).contains(x, y) and self.chooser.?.mode != .folder) {
            self.overwrite_pending = false;
            self.focus = .filename;
            self.placeCaret(x, self.shift);
            self.text_dragging = true;
        } else if (self.chooserRect(3).contains(x, y)) {
            self.focus = .chooser_filter;
            if (self.chooser.?.filters.len > 0) {
                const r = self.chooserRect(3);
                self.openMenu(.chooser_filter, r.x, r.y - @as(f64, @floatFromInt(self.chooser.?.filters.len * 30 + 12)));
            }
        } else for (self.chooser.?.choices, 0..) |choice, i| {
            if (!self.chooserRect(i + 4).contains(x, y)) continue;
            if (choice.values.len == 0) {
                self.chooser_choices.items[i] = if (std.mem.eql(u8, self.chooser_choices.items[i], "true")) "false" else "true";
            } else {
                var next: usize = 0;
                for (choice.values, 0..) |value, j| if (std.mem.eql(u8, value.id, self.chooser_choices.items[i])) {
                    next = (j + 1) % choice.values.len;
                };
                self.chooser_choices.items[i] = choice.values[next].id;
            }
            break;
        }
        self.invalidate();
        return true;
    }

    fn chooserKey(self: *App, sym: u32, utf8: []const u8) bool {
        if (sym == c.XKB_KEY_Escape and self.focus != .location_bar and self.focus != .search) {
            if (self.overwrite_pending) self.overwrite_pending = false else self.chooser_done = true;
            self.invalidate();
            return true;
        }
        if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) {
            var order_buf: [14]Focus = undefined;
            const base = [_]Focus{ .location_bar, .file_view, .filename, .chooser_filter };
            @memcpy(order_buf[0..base.len], &base);
            const choices = self.chooser.?.choices.len;
            @memset(order_buf[4 .. 4 + choices], .chooser_choice);
            order_buf[4 + choices] = .chooser_cancel;
            order_buf[5 + choices] = .chooser_accept;
            const order = order_buf[0 .. 6 + choices];
            var index: usize = 0;
            for (order, 0..) |focus, i| if (focus == self.focus) {
                index = i;
            };
            if (self.focus == .chooser_choice) index = 4 + self.chooser_choice_index;
            index = (index + (if (self.shift) order.len - 1 else 1)) % order.len;
            self.focus = order[index];
            if (self.focus == .chooser_choice) self.chooser_choice_index = index - 4;
            if (self.focus == .filename) self.filename.select_all = true;
            if (self.focus == .location_bar and self.search_visible) {
                self.search_visible = false;
                self.search.text.clearRetainingCapacity();
                self.search.cursor = 0;
                self.rebuildView();
            }
            self.invalidate();
            return true;
        }
        if (self.ctrl and (sym == c.XKB_KEY_l or sym == c.XKB_KEY_L or sym == c.XKB_KEY_f or sym == c.XKB_KEY_F)) return false;
        if (self.focus == .filename) {
            if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) self.acceptChooser() else {
                self.overwrite_pending = false;
                self.editKey(&self.filename, sym, utf8);
            }
            return true;
        }
        if (self.focus == .chooser_choice) {
            if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space or sym == c.XKB_KEY_Right) {
                const r = self.chooserRect(self.chooser_choice_index + 4);
                _ = self.chooserClick(r.x + 1, r.y + 1, 0x110);
            }
            return true;
        }
        if (self.focus == .chooser_filter) {
            if (sym == c.XKB_KEY_space or sym == c.XKB_KEY_Return or sym == c.XKB_KEY_Right or sym == c.XKB_KEY_Left) self.cycleChooserFilter(sym == c.XKB_KEY_Left);
            return true;
        }
        if (self.focus == .chooser_accept or self.focus == .chooser_cancel) {
            if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space) {
                if (self.focus == .chooser_accept) self.acceptChooser() else self.chooser_done = true;
            }
            return true;
        }
        if (self.focus == .file_view) {
            if (sym == c.XKB_KEY_F2 or sym == c.XKB_KEY_Delete or sym == c.XKB_KEY_Menu or sym == c.XKB_KEY_F10) return true;
            if (self.ctrl) switch (sym) {
                c.XKB_KEY_n, c.XKB_KEY_N => {
                    if (self.shift) self.openNewFolderDialog();
                    return true;
                },
                c.XKB_KEY_x, c.XKB_KEY_X, c.XKB_KEY_c, c.XKB_KEY_C, c.XKB_KEY_v, c.XKB_KEY_V => return true,
                c.XKB_KEY_a, c.XKB_KEY_A => if (!self.chooser.?.multiple) {
                    return true;
                },
                else => {},
            };
            if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
                if (self.focused_index) |idx| {
                    if (idx < self.items.items.len and self.items.items[idx].is_dir) {
                        self.activateItem(idx);
                        return true;
                    }
                }
                self.acceptChooser();
                return true;
            }
        }
        return false;
    }

    pub fn acceptChooser(self: *App) void {
        self.collectChooser() catch {
            self.setStatusNotice("Choose an accessible file or folder and a valid filename.", true);
        };
        self.invalidate();
    }

    fn collectChooser(self: *App) !void {
        const opts = self.chooser orelse return;
        for (self.chooser_paths.items) |path| self.allocator.free(path);
        self.chooser_paths.clearRetainingCapacity();
        if (opts.mode == .save or (opts.mode == .open and !opts.multiple and self.filename.text.items.len > 0)) {
            const name = self.filename.text.items;
            if (!chooser_mod.validName(name)) return error.InvalidName;
            const path = try std.fs.path.join(self.allocator, &.{ self.history.current, name });
            defer self.allocator.free(path);
            const zpath = try self.allocator.dupeZ(u8, path);
            defer self.allocator.free(zpath);
            var stat: c.struct_stat = undefined;
            const exists = c.stat(zpath, &stat) == 0;
            if (exists and stat.st_mode & c.S_IFMT == c.S_IFDIR) {
                self.navigate(path);
                return;
            }
            if (opts.mode == .open and (!exists or c.access(zpath, c.R_OK) != 0)) return error.Inaccessible;
            if (opts.mode == .save) {
                const parent = try self.allocator.dupeZ(u8, self.history.current);
                defer self.allocator.free(parent);
                if (c.access(parent, c.W_OK | c.X_OK) != 0) return error.Inaccessible;
            }
            // lstat also detects a dangling symlink, which saving would replace.
            if (opts.mode == .save and c.lstat(zpath, &stat) == 0 and !self.overwrite_pending) {
                self.overwrite_pending = true;
                return;
            }
            try self.chooser_paths.append(self.allocator, try self.allocator.dupe(u8, path));
        } else {
            for (self.items.items) |item| {
                if (!item.selected or item.is_broken or item.is_dir != (opts.mode == .folder)) continue;
                const zpath = try self.allocator.dupeZ(u8, item.path);
                defer self.allocator.free(zpath);
                var stat: c.struct_stat = undefined;
                if (c.stat(zpath, &stat) != 0 or c.access(zpath, c.R_OK) != 0 or (stat.st_mode & c.S_IFMT == c.S_IFDIR) != (opts.mode == .folder)) return error.Inaccessible;
                const path = try self.allocator.dupe(u8, item.path);
                errdefer self.allocator.free(path);
                try self.chooser_paths.append(self.allocator, path);
                if (!opts.multiple) break;
            }
            if (opts.mode == .folder and self.chooser_paths.items.len == 0 and !self.loading and self.error_message == null) {
                try self.chooser_paths.append(self.allocator, try self.allocator.dupe(u8, self.history.current));
            }
        }
        if (self.chooser_paths.items.len == 0) return error.NoSelection;
        if (opts.files.len > 0) {
            const folder = self.chooser_paths.items[0];
            defer self.allocator.free(folder);
            self.chooser_paths.clearRetainingCapacity();
            for (opts.files) |name| {
                if (!chooser_mod.validName(name)) return error.InvalidName;
                var index: usize = 0;
                while (true) : (index += 1) {
                    if (index > 10000) return error.TooManyFiles;
                    const path = if (index == 0) try std.fs.path.join(self.allocator, &.{ folder, name }) else try std.fmt.allocPrint(self.allocator, "{s}/{s}.{d}", .{ folder, name, index });
                    const zpath = try self.allocator.dupeZ(u8, path);
                    defer self.allocator.free(zpath);
                    var stat: c.struct_stat = undefined;
                    var exists = c.lstat(zpath, &stat) == 0;
                    for (self.chooser_paths.items) |chosen| if (std.mem.eql(u8, chosen, path)) {
                        exists = true;
                    };
                    if (exists) {
                        self.allocator.free(path);
                        continue;
                    }
                    try self.chooser_paths.append(self.allocator, path);
                    break;
                }
            }
        }
        self.chooser_done = true;
        self.chooser_accepted = true;
    }

    fn renderChooser(self: *App, cr: *c.cairo_t) void {
        const opts = self.chooser.?;
        const top: f64 = @floatFromInt(self.h - self.footerHeight());
        setSource(cr, ui_theme.global.app_bar);
        c.cairo_rectangle(cr, 0, top, @floatFromInt(self.w), @floatFromInt(self.footerHeight()));
        c.cairo_fill(cr);
        setSource(cr, ui_theme.global.app_divider);
        c.cairo_rectangle(cr, 0, top, @floatFromInt(self.w), 1);
        c.cairo_fill(cr);
        setSource(cr, ui_theme.global.window_fg);
        drawText(cr, if (opts.mode == .folder) "Folder:" else "File name:", 16, self.chooserRect(0).y + 23, shell_ui.textSize(), false);
        if (opts.mode == .folder) {
            drawEllipsis(cr, self.history.current, 96, self.chooserRect(0).y + 23, self.chooserRect(0).w, shell_ui.textSize(), false);
        } else self.renderEditor(cr, &self.filename, self.chooserRect(0), self.focus == .filename, false);
        for (1..4) |i| {
            const r = self.chooserRect(i);
            const text = switch (i) {
                1 => if (self.overwrite_pending) "Replace" else if (opts.accept_label.len > 0) opts.accept_label else switch (opts.mode) {
                    .open => "Open",
                    .save => "Save",
                    .folder => "Select",
                },
                2 => "Cancel",
                else => if (opts.filters.len == 0) "All files" else opts.filters[opts.filter_index].name,
            };
            var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse continue;
            ui_button.paint(&layer.renderer, layer.local(), .{ .label = text, .variant = if (i == 1) .primary else .secondary, .alignment = if (i == 3) .left else .center, .trailing_icon = if (i == 3 and opts.filters.len > 0) .chevron_down else null }, .{ .pointer = if (i == 3 and opts.filters.len == 0) .disabled else if (r.contains(self.mouse_x, self.mouse_y)) .hover else .idle, .selected = self.focus == (switch (i) {
                1 => Focus.chooser_accept,
                2 => Focus.chooser_cancel,
                else => Focus.chooser_filter,
            }) });
            layer.finish();
        }
        for (opts.choices, 0..) |choice, i| {
            var buf: [512]u8 = undefined;
            var value_label = self.chooser_choices.items[i];
            for (choice.values) |value| if (std.mem.eql(u8, value.id, value_label)) {
                value_label = value.label;
                break;
            };
            const label = std.fmt.bufPrint(&buf, "{s}: {s}", .{ choice.label, value_label }) catch choice.label;
            const r = self.chooserRect(i + 4);
            var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse continue;
            ui_button.paint(&layer.renderer, layer.local(), .{ .label = label }, .{ .selected = self.focus == .chooser_choice and self.chooser_choice_index == i, .pointer = if (r.contains(self.mouse_x, self.mouse_y)) .hover else .idle });
            layer.finish();
        }
        if (self.overwrite_pending or self.status_notice != null) {
            setSource(cr, ui_theme.global.window_fg);
            drawEllipsis(cr, if (self.overwrite_pending) "A file with this name exists. Replace it?" else self.status_notice.?, 16, top + (if (self.w >= 800) @as(f64, 78) else 56), @floatFromInt(self.w - 32), shell_ui.textSize(), false);
        }
    }

    const BreadcrumbHit = struct { path: []const u8, index: usize };

    /// Same measurement for drawing and hit testing. Long paths show their
    /// rightmost components; Ctrl+L always exposes the complete path.
    fn breadcrumbs(self: *App, target: ?*c.cairo_t, hit_x: ?f64) ?BreadcrumbHit {
        const surface = if (target == null) c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1) else null;
        defer if (surface) |s| c.cairo_surface_destroy(s);
        const cr = target orelse (c.cairo_create(surface) orelse return null);
        defer if (target == null) c.cairo_destroy(cr);
        const r = header.field(self.w);
        var ends: [128]usize = undefined;
        var labels: [128][]const u8 = undefined;
        var widths: [128]f64 = undefined;
        var count: usize = 1;
        const path = self.history.current;
        const at_home = std.mem.eql(u8, path, self.home_dir) or (std.mem.startsWith(u8, path, self.home_dir) and path.len > self.home_dir.len and path[self.home_dir.len] == '/');
        const at_trash = if (self.trash_dir) |trash| std.mem.eql(u8, path, trash) or
            (std.mem.startsWith(u8, path, trash) and path.len > trash.len and path[trash.len] == '/') else false;
        ends[0] = if (self.isRecent()) path.len else if (at_trash) self.trash_dir.?.len else if (at_home) self.home_dir.len else 1;
        labels[0] = if (self.isRecent()) "Recent" else if (at_trash) "Trash" else if (at_home) "Home" else "/";
        var start = ends[0];
        while (start < path.len and count < ends.len) {
            if (path[start] == '/') {
                start += 1;
                continue;
            }
            const end = if (std.mem.indexOfScalarPos(u8, path, start, '/')) |n| n else path.len;
            ends[count] = end;
            labels[count] = path[start..end];
            count += 1;
            start = end;
        }
        var total: f64 = 0;
        for (labels[0..count], 0..) |label, i| {
            widths[i] = measureText(cr, label, shell_ui.textSize(), false) + 28 + @as(f64, if (ends[i] == self.history.archive_len) 22 else 0);
            total += widths[i];
        }
        var first: usize = 0;
        while (first + 1 < count and total > r.w - 16) : (first += 1) total -= widths[first];
        if (target != null) {
            var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse return null;
            _ = ui_field.paintFrame(&layer.renderer, layer.local(), .{}, .{});
            layer.finish();
            c.cairo_save(cr);
            c.cairo_rectangle(cr, r.x + 4, r.y, r.w - 8, r.h);
            c.cairo_clip(cr);
        }
        defer if (target != null) c.cairo_restore(cr);
        var x = r.x + 8;
        for (first..count) |i| {
            if (hit_x) |hit| {
                if (hit >= x and hit < @min(x + widths[i] - 10, r.x + r.w - 8)) return .{ .path = path[0..ends[i]], .index = i };
            }
            if (target != null) {
                const alpha = self.breadcrumb_hover[i].frame.alpha;
                if (alpha > 0) {
                    roundedRect(cr, x, r.y + 4, @min(widths[i] - 10, r.x + r.w - 8 - x), r.h - 8, 5);
                    setSource(cr, withAlpha(ui_theme.global.app_item_hover, alpha));
                    c.cairo_fill(cr);
                }
                setSource(cr, ui_theme.global.window_fg);
                const archive_crumb = ends[i] == self.history.archive_len;
                if (archive_crumb) {
                    if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(x + 4), .y = @floatCast(r.y + 10), .w = 18, .h = 18 })) |icon_layer| {
                        var layer = icon_layer;
                        layer.renderer.drawIcon(0, 0, 18, 18, .{ .id = .folder, .color = ui_theme.global.window_fg });
                        layer.finish();
                    }
                }
                drawText(cr, labels[i], x + 4 + @as(f64, if (archive_crumb) 22 else 0), r.y + 23, shell_ui.textSize(), false);
                if (i + 1 < count) drawText(cr, "›", x + widths[i] - 20, r.y + 23, shell_ui.textSize(), false);
            }
            x += widths[i];
        }
        return null;
    }

    // Shared geometry for painting, pointer input and keyboard navigation.
    pub fn footerHeight(self: *const App) i32 {
        return if (self.chooser) |opts| (if (self.w >= 800) @as(i32, 88) else 114) + @as(i32, @intCast(opts.choices.len)) * 36 else 26;
    }
    fn contentTop(self: *App) i32 {
        return header.height(self.w, self.inRepository());
    }
    fn viewTop(self: *App) i32 {
        return self.contentTop() + if (self.list_view) @as(i32, 30) else 0;
    }
    fn compactList(self: *App) bool {
        return self.list_view and self.h - self.viewTop() - self.footerHeight() < 80;
    }
    fn itemInset(self: *App) i32 {
        return if (self.compactList()) 0 else 20;
    }
    fn rowHeight(self: *App) i32 {
        return if (self.compactList()) 32 else if (self.list_view) 38 else 144;
    }
    fn cardHeight(self: *App) i32 {
        return if (self.compactList()) 30 else if (self.list_view) 36 else 136;
    }
    /// Text baseline of a list row, from the row's top.
    fn listBaseline(self: *App) f64 {
        return if (self.compactList()) 21 else 24;
    }

    fn sidebarTargetWidth(self: *App) i32 {
        return if (self.w >= 700) 208 else if (self.w >= 500) 160 else 0;
    }

    /// The width being drawn: it eases toward `sidebarTargetWidth` when a
    /// resize crosses a threshold.
    fn sidebarWidth(self: *App) i32 {
        return if (self.sidebar_px >= 0) self.sidebar_px else self.sidebarTargetWidth();
    }

    fn placeTargetStep(self: *App) i32 {
        return if (self.h - self.contentTop() < 480) 32 else 40;
    }

    /// Moves `px` toward `target` along the panel slide curve; true when the
    /// whole-pixel value changed.
    fn glideInt(glide: *anim.Anim, px: *i32, target: i32, now: i64) bool {
        if (px.* < 0) {
            glide.cancel(@floatFromInt(target));
            px.* = target;
            return false;
        }
        const target_f: f32 = @floatFromInt(target);
        if (glide.to != target_f) glide.retargetTo(now, target_f, anim.curveFor(.panel_slide));
        const next: i32 = if (glide.settled(now)) target else @intFromFloat(@round(glide.value(now)));
        const changed = next != px.*;
        px.* = next;
        return changed;
    }

    /// Eases the sidebar's compact steps (width and row pitch) instead of
    /// snapping them. Once per loop, before painting.
    pub fn stepLayout(self: *App, now: i64) void {
        const width_changed = glideInt(&self.sidebar_glide, &self.sidebar_px, self.sidebarTargetWidth(), now);
        const pitch_changed = glideInt(&self.place_glide, &self.place_px, self.placeTargetStep(), now);
        if (width_changed or pitch_changed) {
            self.clampScroll();
            self.clampSidebarScroll();
            self.invalidate();
        }
        self.layout_active = !self.sidebar_glide.settled(now) or !self.place_glide.settled(now);
    }

    fn clampSidebarScroll(self: *App) void {
        self.sidebar_scroll = std.math.clamp(self.sidebar_scroll, 0, @max(0, self.sidebarExtent() - (self.h - self.footerHeight())));
    }

    fn scrollbarGutter(self: *const App) i32 {
        return @intFromFloat(scrollbar.gutter(self.scrollbar_width));
    }

    fn columns(self: *App) i32 {
        return if (self.list_view) 1 else @max(1, @divTrunc(self.w - self.sidebarWidth() - 20 - self.scrollbarGutter(), 210));
    }

    fn cellWidth(self: *App) i32 {
        return @divTrunc(self.w - self.sidebarWidth() - 20 - self.scrollbarGutter(), self.columns());
    }

    fn contentHeight(self: *App) i32 {
        const count: i32 = @intCast(self.items.items.len);
        return 2 * self.itemInset() + @divTrunc(count + self.columns() - 1, self.columns()) * self.rowHeight();
    }

    fn itemAt(self: *App, x: f64, y: f64) ?usize {
        const gx = @as(i32, @intFromFloat(x)) - self.sidebarWidth() - 20;
        if (y < @as(f64, @floatFromInt(self.viewTop())) or y >= @as(f64, @floatFromInt(self.h - self.footerHeight()))) return null;
        const gy = @as(i32, @intFromFloat(y)) - self.viewTop() - self.itemInset() + self.scroll_y;
        if (gx < 0 or gy < 0) return null;
        const col = @divTrunc(gx, self.cellWidth());
        if (col >= self.columns() or @mod(gx, self.cellWidth()) >= self.cellWidth() - 20 or @mod(gy, self.rowHeight()) >= self.cardHeight()) return null;
        const idx: usize = @intCast(@divTrunc(gy, self.rowHeight()) * self.columns() + col);
        return if (idx < self.items.items.len) idx else null;
    }

    /// The repository the folder belongs to, whether or not Git View is on.
    fn foundRepository(self: *App) ?git.Repository {
        if (self.chooser != null) return null;
        return if (self.snapshot) |snap| snap.repository else null;
    }

    /// The repository to present as such: none while Git View is off.
    fn repository(self: *App) ?git.Repository {
        return if (self.git_view) self.foundRepository() else null;
    }

    fn inRepository(self: *App) bool {
        return self.foundRepository() != null;
    }

    fn changedOnly(self: *App) bool {
        return self.changed_only and self.repository() != null;
    }

    fn columnLabels(self: *App) []const []const u8 {
        return if (self.repository() != null) &.{ "Name", "Git" } else if (self.isRecent()) &.{ "Name", "Size", "Type", "Opened", "Permissions" } else &column_labels;
    }

    const column_labels = [_][]const u8{ "Name", "Size", "Type", "Modified", "Permissions" };
    fn columnMinimums(width: f64) [5]f64 {
        if (width < 224) {
            const scale = width / 224;
            return .{ 64 * scale, 40 * scale, 40 * scale, 40 * scale, 40 * scale };
        }
        // Keep enough room for the full date and time when the view is wide
        // enough; below that, let the Modified column yield space to Name.
        return .{ 64, 40, 40, @min(136, width - 184), 40 };
    }

    fn columnMinimumTotal(minimum: [5]f64) f64 {
        var total: f64 = 0;
        for (minimum) |value| total += value;
        return total;
    }

    fn listWidths(self: *App) [5]f64 {
        const width: f64 = @floatFromInt(self.cellWidth() - 20);
        if (self.repository() != null) {
            const minimum = gitColumnMinimums(width);
            const extra = @max(0, width - minimum[0] - minimum[1]);
            const name = if (self.git_column_weight) |weight| minimum[0] + weight * extra else @max(minimum[0], width - 164);
            return .{ name, width - name, 0, 0, 0 };
        }
        if (self.column_weights) |weights| {
            const minimum = columnMinimums(width);
            const extra = @max(0, width - columnMinimumTotal(minimum));
            var widths: [5]f64 = undefined;
            for (weights, 0..) |weight, i| widths[i] = minimum[i] + weight * extra;
            return widths;
        }
        const minimum = columnMinimums(width);
        const detail = @max(minimum[1], @min(110, width * 0.14));
        const modified = @max(minimum[3], @min(160, width * 0.20));
        const permissions = @min(200, width * 0.26);
        var widths: [5]f64 = .{ 0, detail, detail, modified, @max(minimum[4], permissions) };
        var overflow = widths[1] + widths[2] + widths[3] + widths[4] - (width - minimum[0]);
        for ([_]usize{ 4, 2, 1 }) |i| {
            const shrink = @min(@max(0, overflow), widths[i] - minimum[i]);
            widths[i] -= shrink;
            overflow -= shrink;
        }
        widths[0] = width - widths[1] - widths[2] - widths[3] - widths[4];
        return widths;
    }

    fn listColumn(self: *App, column: usize) header.Rect {
        const widths = self.listWidths();
        var x: f64 = @floatFromInt(self.sidebarWidth() + 20);
        for (widths[0..column]) |width| x += width;
        return .{ .x = x, .y = @floatFromInt(self.contentTop()), .w = widths[column], .h = 30 };
    }

    fn columnBoundary(self: *App, x: f64, y: f64) ?usize {
        if (!self.list_view or self.dialog != null or self.menu != null) return null;
        for (0..self.columnLabels().len - 1) |i| {
            const rect = self.listColumn(i);
            if (y >= rect.y and y < rect.y + rect.h and @abs(x - (rect.x + rect.w)) <= 4) return i;
        }
        return null;
    }

    fn resizeColumn(self: *App, x: f64) void {
        const drag = self.column_resize orelse return;
        var widths = drag.widths;
        var total: f64 = 0;
        for (widths) |width| total += width;
        if (self.repository() != null) {
            const minimum = gitColumnMinimums(total);
            const extra = total - minimum[0] - minimum[1];
            if (extra <= 0) return;
            const delta = std.math.clamp(x - drag.x, minimum[0] - widths[0], widths[1] - minimum[1]);
            self.git_column_weight = (widths[0] + delta - minimum[0]) / extra;
            self.invalidate();
            return;
        }
        const minimum = columnMinimums(total);
        const extra = total - columnMinimumTotal(minimum);
        if (extra <= 0) return;
        const delta = std.math.clamp(x - drag.x, minimum[drag.column] - widths[drag.column], widths[drag.column + 1] - minimum[drag.column + 1]);
        widths[drag.column] += delta;
        widths[drag.column + 1] -= delta;
        var weights: [5]f64 = undefined;
        for (widths, 0..) |width, i| weights[i] = (width - minimum[i]) / extra;
        self.column_weights = weights;
        self.invalidate();
    }

    fn gitColumnMinimums(width: f64) [2]f64 {
        const scale = @min(1, width / 160);
        return .{ 96 * scale, 64 * scale };
    }

    pub fn sizeButtonRect(self: *App, idx: usize) ?header.Rect {
        if (self.history.archive_len > 0) return null;
        if (self.repository() != null) return null;
        if (idx >= self.items.items.len) return null;
        const item = self.items.items[idx];
        if (!item.is_dir or item.is_symlink) return null;
        const cols = self.columns();
        const cell = self.cellWidth();
        const i: i32 = @intCast(idx);
        const x: f64 = @floatFromInt(self.sidebarWidth() + 20 + @mod(i, cols) * cell);
        const y: f64 = @floatFromInt(self.viewTop() + self.itemInset() + @divTrunc(i, cols) * self.rowHeight() - self.scroll_y);
        if (self.list_view) {
            const sz = self.listColumn(1);
            const baseline = self.listBaseline();
            return .{
                .x = sz.x,
                .y = y + baseline - 15,
                .w = sz.w,
                .h = 22,
            };
        } else {
            const width: f64 = @floatFromInt(cell - 20);
            return .{
                .x = x + 22,
                .y = y + 102,
                .w = @max(32, width - 44),
                .h = 22,
            };
        }
    }

    pub fn getOrInitDirsizePool(self: *App) !*dirsize.Pool {
        if (self.dirsize_pool) |p| return p;
        const p = try dirsize.Pool.init(self.allocator);
        self.dirsize_pool = p;
        return p;
    }

    pub fn startFolderSize(self: *App, idx: usize) void {
        if (self.history.archive_len > 0) return;
        if (idx >= self.items.items.len) return;
        const it = self.items.items[idx];
        if (!it.is_dir or it.is_symlink) return;
        if (self.folder_sizes.get(it.path)) |sz| {
            switch (sz) {
                .running => return,
                .done => {},
            }
        }
        const pool = self.getOrInitDirsizePool() catch return;
        const job = pool.startJob(it.path) catch return;
        if (self.folder_sizes.getPtr(it.path)) |entry| {
            entry.* = .{ .running = job };
        } else {
            const key = self.allocator.dupe(u8, it.path) catch {
                job.cancel();
                job.unref();
                return;
            };
            self.folder_sizes.put(key, .{ .running = job }) catch {
                self.allocator.free(key);
                job.cancel();
                job.unref();
                return;
            };
        }
        self.damagePathSize(it.path);
    }

    pub fn cancelFolderSize(self: *App, idx: usize) void {
        if (idx >= self.items.items.len) return;
        const it = self.items.items[idx];
        if (self.folder_sizes.fetchRemove(it.path)) |kv| {
            self.allocator.free(kv.key);
            switch (kv.value) {
                .running => |job| {
                    job.cancel();
                    job.unref();
                },
                .done => {},
            }
            self.damagePathSize(it.path);
        }
    }

    pub fn toggleFolderSize(self: *App, idx: usize) void {
        if (idx >= self.items.items.len) return;
        const it = self.items.items[idx];
        if (!it.is_dir or it.is_symlink) return;
        if (self.folder_sizes.get(it.path)) |sz| {
            switch (sz) {
                .running => self.cancelFolderSize(idx),
                .done => {},
            }
        } else {
            self.startFolderSize(idx);
        }
    }

    pub fn cancelRunningFolderSizes(self: *App) void {
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);
        var it = self.folder_sizes.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .running => |job| {
                    job.cancel();
                    job.unref();
                    to_remove.append(self.allocator, entry.key_ptr.*) catch {};
                },
                .done => {},
            }
        }
        for (to_remove.items) |key| {
            if (self.folder_sizes.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }

    pub fn clearFolderSizes(self: *App) void {
        var it = self.folder_sizes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .running => |job| {
                    job.cancel();
                    job.unref();
                },
                .done => {},
            }
        }
        self.folder_sizes.clearRetainingCapacity();
        self.invalidate();
    }

    pub fn hasRunningFolderSize(self: *App) bool {
        var it = self.folder_sizes.valueIterator();
        while (it.next()) |sz| {
            switch (sz.*) {
                .running => return true,
                .done => {},
            }
        }
        return false;
    }

    pub fn damagePathSize(self: *App, path: []const u8) void {
        for (self.items.items, 0..) |it, idx| {
            if (std.mem.eql(u8, it.path, path)) {
                if (self.sizeButtonRect(idx)) |r| {
                    var rect = r;
                    rect.x -= 2;
                    rect.y -= 2;
                    rect.w += 4;
                    rect.h += 4;
                    self.addDamage(rect);
                }
                break;
            }
        }
    }

    pub fn syncFolderSizes(self: *App) void {
        var it = self.folder_sizes.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .running => |job| {
                    if (job.isDone()) {
                        const bytes = job.bytes.load(.acquire);
                        const partial = job.partial.load(.acquire);
                        entry.value_ptr.* = .{ .done = .{ .bytes = bytes, .partial = partial } };
                        job.unref();
                        self.damagePathSize(entry.key_ptr.*);
                    } else {
                        self.damagePathSize(entry.key_ptr.*);
                    }
                },
                .done => {},
            }
        }
    }

    pub const ItemSizeDisplay = struct {
        text: []const u8,
        is_running: bool,
    };

    pub fn itemSizeDisplay(self: *App, item: ViewItem, buf: *[64]u8) ItemSizeDisplay {
        if (!item.is_dir) {
            return .{ .text = formatSize(item.bytes, buf), .is_running = false };
        }
        if (item.is_symlink) {
            return .{ .text = "—", .is_running = false };
        }
        if (self.folder_sizes.get(item.path)) |sz| {
            switch (sz) {
                .running => |job| {
                    const bytes = job.bytes.load(.acquire);
                    var sbuf: [64]u8 = undefined;
                    const formatted = formatSize(bytes, &sbuf);
                    const str = std.fmt.bufPrint(buf, "{s}", .{formatted}) catch "—";
                    return .{ .text = str, .is_running = true };
                },
                .done => |d| {
                    if (d.partial) {
                        var sbuf: [64]u8 = undefined;
                        const formatted = formatSize(d.bytes, &sbuf);
                        const str = std.fmt.bufPrint(buf, "≥ {s}", .{formatted}) catch "—";
                        return .{ .text = str, .is_running = false };
                    } else {
                        return .{ .text = formatSize(d.bytes, buf), .is_running = false };
                    }
                },
            }
        }
        return .{ .text = "—", .is_running = false };
    }

    fn sortColumn(self: *App) usize {
        return switch (self.effectiveSort()) {
            .name, .name_desc => 0,
            .size, .size_asc => 1,
            .type, .type_desc => 2,
            .modified, .modified_asc => 3,
        };
    }
    fn sortDescending(self: *App) bool {
        return switch (self.effectiveSort()) {
            .name_desc, .size, .modified, .type_desc => true,
            else => false,
        };
    }
    fn startSortFeedback(self: *App, now: i64) void {
        if (!self.list_view) return;
        self.sort_feedback.animation.pulse(now, 1, 0, 220);
        _ = self.sort_feedback.step(now, false);
        self.invalidate();
    }

    fn paintSortFeedback(self: *App, cr: *c.cairo_t, rect: header.Rect) void {
        if (self.sort_feedback.alpha <= 0) return;
        setSource(cr, withAlpha(ui_theme.shellPalette().accent, 0.10 * self.sort_feedback.alpha));
        c.cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h);
        c.cairo_fill(cr);
    }

    fn sortByColumn(self: *App, column: usize) void {
        if (column >= 4 or (self.repository() != null and column != 0)) return;
        const reverse = self.sortColumn() == column and !self.sortDescending();
        const mode: Sort = switch (column) {
            0 => if (reverse) .name_desc else .name,
            1 => if (reverse) .size else .size_asc,
            2 => if (reverse) .type_desc else .type,
            else => if (reverse) .modified else .modified_asc,
        };
        self.setSort(mode);
        self.rebuildView();
        self.savePreferences();
        self.startSortFeedback(nowMs());
    }
    fn renderColumns(self: *App, cr: *c.cairo_t) void {
        if (!self.list_view) return;
        setSource(cr, ui_theme.global.app_bar);
        c.cairo_rectangle(cr, @floatFromInt(self.sidebarWidth()), @floatFromInt(self.contentTop()), @floatFromInt(self.w - self.sidebarWidth()), 30);
        c.cairo_fill(cr);
        for (self.columnLabels(), 0..) |label, i| {
            const rect = self.listColumn(i);
            if (i + 1 < self.columnLabels().len) {
                setSource(cr, withAlpha(ui_theme.global.window_fg, 0.2));
                c.cairo_rectangle(cr, rect.x + rect.w - 0.5, rect.y + 6, 1, rect.h - 12);
                c.cairo_fill(cr);
            }
            const sorted = self.sortColumn() == i and (self.repository() == null or i == 0);
            const hovered = self.hoverKey() == 400 + i;
            if (sorted) {
                setSource(cr, ui_theme.global.surface);
                c.cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h);
                c.cairo_fill(cr);
            }
            if (hovered) {
                setSource(cr, ui_theme.global.surface_hover);
                c.cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h);
                c.cairo_fill(cr);
            }
            if (sorted) self.paintSortFeedback(cr, rect);
            // Narrow columns step down one more, so "Modified" still fits.
            const size: f64 = if (rect.w < 75) shell_ui.headingSize() - 1 else shell_ui.headingSize();
            const label_width = @max(0, rect.w - (if (sorted) @as(f64, 20) else 8));
            setSource(cr, ui_theme.global.window_fg);
            drawEllipsis(cr, label, rect.x + 4, rect.y + 20, label_width, size, true);
            if (sorted) {
                // Six pixels between the label's advance and the triangle.
                const x = rect.x + 4 + @min(measureText(cr, label, size, true), label_width) + 9;
                const y = rect.y + 15;
                const direction: f64 = if (self.sortDescending()) 1 else -1;
                c.cairo_move_to(cr, x - 3, y - 2 * direction);
                c.cairo_line_to(cr, x + 3, y - 2 * direction);
                c.cairo_line_to(cr, x, y + 2 * direction);
                c.cairo_close_path(cr);
                c.cairo_fill(cr);
            }
        }
    }
    fn itemType(item: ViewItem) []const u8 {
        if (item.is_broken) return "Broken link";
        if (item.is_symlink) return "Link";
        if (item.is_dir) return "Folder";
        const ext = std.fs.path.extension(item.name);
        return if (ext.len > 1) ext[1..] else "File";
    }

    const places = [_][]const u8{ "Home", "Trash", "Recent", "Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos", "Projects" };

    const places_start = 3;

    fn isRecent(self: *const App) bool {
        return recent.isLocation(self.history.current);
    }

    fn effectiveSort(self: *const App) Sort {
        return if (self.isRecent()) self.recent_sort_mode else self.sort_mode;
    }

    fn setSort(self: *App, mode: Sort) void {
        if (self.isRecent()) self.recent_sort_mode = mode else self.sort_mode = mode;
    }

    /// Where the pins start: the built-in places come first.
    const pin_base = places.len;

    /// A sidebar row. Indices run in drawn order, which the hover glide relies
    /// on: the built-in places, the pins, then the devices.
    const Row = union(enum) { builtin: usize, pin: usize, device: usize };

    fn deviceBase(self: *const App) usize {
        return pin_base + self.pins.items.items.len;
    }

    fn rowCount(self: *const App) usize {
        return self.deviceBase() + self.device_list.items.len;
    }

    fn rowKind(self: *const App, index: usize) Row {
        if (index < pin_base) return .{ .builtin = index };
        if (index < self.deviceBase()) return .{ .pin = index - pin_base };
        return .{ .device = index - self.deviceBase() };
    }

    fn pinIndex(self: *const App, index: usize) ?usize {
        return switch (self.rowKind(index)) {
            .pin => |j| j,
            else => null,
        };
    }

    fn isDeviceRow(self: *const App, index: usize) bool {
        return switch (self.rowKind(index)) {
            .device => true,
            else => false,
        };
    }

    fn placeStep(self: *App) i32 {
        return if (self.place_px >= 0) self.place_px else self.placeTargetStep();
    }

    // Fill each row's pitch, centred on the existing icon and label, so adjacent
    // entries share a hit boundary instead of briefly fading out between rows.
    fn placeRect(self: *App, index: usize) header.Rect {
        const height = self.placeStep();
        return .{
            .x = 10,
            .y = @floatFromInt(self.placeY(index) - @divTrunc(height - 30, 2)),
            .w = @floatFromInt(self.sidebarWidth() - 20 - (if (self.sidebarScrollbar() != null) self.scrollbarGutter() else @as(i32, 0))),
            .h = @floatFromInt(height),
        };
    }

    fn placePinnable(index: usize) bool {
        return index >= places_start and index < pin_base;
    }

    fn placeVisible(self: *App, index: usize) bool {
        return switch (self.rowKind(index)) {
            .builtin => if (index == 2 and self.chooser != null) false else !placePinnable(index) or self.unpinned_places & (@as(u8, 1) << @as(u3, @intCast(index - places_start))) == 0,
            .pin => true,
            .device => |k| k < self.device_list.items.len,
        };
    }

    fn openPlace(self: *App, index: usize) void {
        if (index == 2) {
            self.navigate(recent.location);
            self.focus = .file_view;
            return;
        }
        switch (self.rowKind(index)) {
            .device => |k| {
                self.activateDevice(k);
                return;
            },
            .pin => |j| {
                self.openPin(j);
                return;
            },
            else => {},
        }
        var buf: [4096]u8 = undefined;
        if (self.placePath(index, &buf)) |path| {
            if (index == 1) std.Io.Dir.cwd().createDirPath(self.io, path) catch {
                self.setStatusNotice("Could not open Trash", true);
                return;
            };
            self.navigate(path);
        }
        self.focus = .file_view;
    }

    /// A click on a pin: a folder is browsed, a file opened as a double-click
    /// would (a file chooser browses the folder holding it instead).
    fn openPin(self: *App, j: usize) void {
        if (j >= self.pins.items.items.len) return;
        const pin = &self.pins.items.items[j];
        pin.kind = pins_mod.kindOf(pin.path);
        self.focus = .file_view;
        switch (pin.kind) {
            .dir => self.navigate(pin.path),
            .file => if (self.chooser != null) {
                self.navigate(std.fs.path.dirname(pin.path) orelse "/");
            } else self.openFile(pin.path),
            .missing => {
                var buf: [160]u8 = undefined;
                self.setStatusNotice(std.fmt.bufPrint(&buf, "{s} is no longer there", .{pin.name()}) catch "Not found", true);
                self.invalidate();
            },
        }
    }

    fn placeAt(self: *App, x: f64, y: f64) ?usize {
        if (x < 0 or x >= @as(f64, @floatFromInt(self.sidebarWidth())) or
            y < @as(f64, @floatFromInt(self.contentTop())) or y >= @as(f64, @floatFromInt(self.h - self.footerHeight()))) return null;
        if (self.sidebarScrollbar()) |bar| {
            if (bar.overTrack(@floatCast(x), @floatCast(y))) return null;
        }
        for (0..self.rowCount()) |i| {
            if (!self.placeVisible(i)) continue;
            const row = self.placeRect(i);
            if (y >= row.y and y < row.y + row.h) return i;
        }
        return null;
    }

    /// Whether place `index` is the folder being shown; a device also when the
    /// folder is inside it.
    fn placeActive(self: *App, index: usize) bool {
        if (self.deviceAt(index)) |volume| {
            const mount = volume.mount orelse return false;
            return volumes_mod.contains(mount, self.history.current);
        }
        var buf: [4096]u8 = undefined;
        const path = self.placePath(index, &buf) orelse return false;
        return std.mem.eql(u8, path, self.history.current);
    }

    fn deviceAt(self: *App, index: usize) ?*const volumes_mod.Volume {
        return switch (self.rowKind(index)) {
            .device => |k| if (k < self.device_list.items.len) &self.device_list.items[k] else null,
            else => null,
        };
    }

    /// Height DEVICES adds below Places, heading included.
    fn deviceBlock(self: *App) i32 {
        const count: i32 = @intCast(self.device_list.items.len);
        return if (count == 0) 0 else 44 + count * self.placeStep();
    }

    /// The eject button at a mounted device row's right edge.
    fn ejectRect(self: *App, index: usize) header.Rect {
        const row = self.placeRect(index);
        return .{ .x = row.x + row.w - 30, .y = row.y + (row.h - 26) / 2, .w = 26, .h = 26 };
    }

    /// The device whose eject button is at (`x`, `y`).
    fn ejectAt(self: *App, x: f64, y: f64) ?usize {
        const index = self.placeAt(x, y) orelse return null;
        const volume = self.deviceAt(index) orelse return null;
        if (volume.mount == null or !self.ejectRect(index).contains(x, y)) return null;
        return index - self.deviceBase();
    }

    /// The y between pin rows `slot - 1` and `slot`: where the drop line sits.
    fn pinBoundary(self: *App, slot: usize) f64 {
        return @floatFromInt(self.pinRowY(slot) - @divTrunc(self.placeStep() - 30, 2));
    }

    /// The gap among the pins where a drop at (`x`, `y`) would land, or null
    /// off PLACES. Anywhere on the section snaps to the nearest gap, so the
    /// first pin can be dropped without aiming at the strip under Projects.
    fn pinSlotAt(self: *App, x: f64, y: f64) ?usize {
        if (self.dialog != null) return null;
        if (x < 0 or x >= @as(f64, @floatFromInt(self.sidebarWidth()))) return null;
        if (y < @as(f64, @floatFromInt(self.contentTop())) or y >= @as(f64, @floatFromInt(self.h - self.footerHeight()))) return null;
        if (self.sidebarScrollbar()) |bar| {
            if (x >= @as(f64, bar.track.x)) return null;
        }
        const step: f64 = @floatFromInt(self.placeStep());
        const count = self.pins.items.items.len;
        const top: f64 = @floatFromInt(self.placeY(places_start) - 30);
        if (y < top or y >= self.pinBoundary(count) + 16) return null;
        const nearest = @round((y - self.pinBoundary(0)) / step);
        return @intFromFloat(std.math.clamp(nearest, 0, @as(f64, @floatFromInt(count))));
    }

    fn setPinDrop(self: *App, slot: ?usize) void {
        if (std.meta.eql(self.pin_drop, slot)) return;
        const area: header.Rect = .{ .x = 0, .y = @floatFromInt(self.contentTop()), .w = @floatFromInt(self.sidebarWidth()), .h = @floatFromInt(self.h - self.contentTop() - self.footerHeight()) };
        for ([_]?usize{ self.pin_drop, slot }) |gap| {
            const at = gap orelse continue;
            self.damageHighlight(area, .{ .x = 0, .y = self.pinBoundary(at) - 6, .w = area.w, .h = 12 }, null);
        }
        self.pin_drop = slot;
    }

    /// A drag is over the window at (`x`, `y`). True when a drop there pins.
    pub fn dropMotion(self: *App, x: f64, y: f64) bool {
        const slot = self.pinSlotAt(x, y);
        self.setPinDrop(slot);
        return slot != null;
    }

    /// Content drops use the folder under the pointer, or the displayed folder
    /// on empty space. Archives, dialogs, and file choosers are not targets.
    pub fn dropDirectoryAt(self: *App, x: f64, y: f64) ?[]const u8 {
        if (self.chooser != null or self.dialog != null or self.menu != null or self.history.archive_len > 0) return null;
        if (self.job_state == .running or self.job_state == .waiting_conflict) return null;
        if (x < @as(f64, @floatFromInt(self.sidebarWidth())) or x >= @as(f64, @floatFromInt(self.w - self.scrollbarGutter())) or
            y < @as(f64, @floatFromInt(self.viewTop())) or y >= @as(f64, @floatFromInt(self.h - self.footerHeight()))) return null;
        if (self.itemAt(x, y)) |idx| {
            const item = self.items.items[idx];
            if (!item.is_dir or item.missing or item.is_broken) return null;
            return item.path;
        }
        return if (self.isRecent()) null else self.history.current;
    }

    pub fn highlightDrop(self: *App, x: f64, y: f64, accepted: bool) void {
        const idx = if (accepted) self.itemAt(x, y) else null;
        if (self.folder_drop == idx) return;
        const per_row: usize = @intCast(self.columns());
        for ([_]?usize{ self.folder_drop, idx }) |index| {
            const i = index orelse continue;
            var rect = self.itemHighlight(.{ .col = @floatFromInt(i % per_row), .row = @floatFromInt(i / per_row) });
            rect.x -= 2;
            rect.y -= 2;
            rect.w += 4;
            rect.h += 4;
            self.addDamage(self.clipToViewport(rect));
        }
        self.folder_drop = idx;
    }

    pub fn dropLeave(self: *App) void {
        self.highlightDrop(0, 0, false);
        self.setPinDrop(null);
    }

    /// The drop happened: the gap it chose, with the line gone.
    pub fn takePinDrop(self: *App) ?usize {
        const slot = self.pin_drop;
        self.setPinDrop(null);
        return slot;
    }

    fn builtinPlacePath(self: *App, path: []const u8) bool {
        var buf: [4096]u8 = undefined;
        for (0..self.deviceBase()) |i| {
            if (self.pinIndex(i) != null or !self.placeVisible(i)) continue;
            const known = self.placePath(i, &buf) orelse continue;
            if (std.mem.eql(u8, known, path)) return true;
        }
        return false;
    }

    /// Pins what was dropped on gap `slot`, in order; what is already listed
    /// or gone is skipped.
    pub fn pinDropped(self: *App, slot: usize, paths: []const []const u8) void {
        self.reloadPins();
        var at = @min(slot, self.pins.items.items.len);
        var added: usize = 0;
        var listed = false;
        var full = false;
        var first: []const u8 = "";
        for (paths) |raw| {
            const path = pins_mod.normalize(raw) orelse continue;
            if (self.builtinPlacePath(path)) {
                listed = true;
                continue;
            }
            if (self.pins.insert(self.allocator, at, path)) {
                if (added == 0) first = self.pins.items.items[at].name();
                at += 1;
                added += 1;
            } else |err| switch (err) {
                error.Duplicate => listed = true,
                error.Full => full = true,
                error.OutOfMemory => break,
                error.Invalid, error.Missing => {},
            }
        }
        var buf: [200]u8 = undefined;
        if (added > 0) {
            self.savePins();
            self.pinsChanged();
            self.setStatusNotice(if (added == 1)
                std.fmt.bufPrint(&buf, "Added {s} to Places", .{first}) catch "Added to Places"
            else
                std.fmt.bufPrint(&buf, "Added {d} items to Places", .{added}) catch "Added to Places", false);
        } else {
            self.setStatusNotice(if (full) "Places is full" else if (listed) "Already in Places" else "Nothing to add to Places", true);
        }
    }

    fn removePin(self: *App, j: usize) void {
        if (j >= self.pins.items.items.len) return;
        // Another window may have changed the list since: find the pin by path.
        const path = self.allocator.dupe(u8, self.pins.items.items[j].path) catch return;
        defer self.allocator.free(path);
        self.reloadPins();
        if (self.pins.find(path)) |found| self.pins.remove(self.allocator, found);
        self.savePins();
        self.pinsChanged();
    }

    fn savePins(self: *App) void {
        const file = self.pins_path orelse return;
        self.pins.save(self.allocator, self.io, file) catch self.setStatusNotice("Could not save Places", true);
    }

    fn reloadPins(self: *App) void {
        const file = self.pins_path orelse return;
        var fresh = pins_mod.List.load(self.allocator, self.io, file);
        std.mem.swap(pins_mod.List, &self.pins, &fresh);
        fresh.deinit(self.allocator);
    }

    /// Rows moved: nothing indexed by one may outlive this.
    fn pinsChanged(self: *App) void {
        if (self.menu == .sidebar) self.menu = null;
        self.nav_hover = .{};
        self.clampSidebarScroll();
        self.invalidate();
    }

    /// Picks up pins another window added or removed, and targets that came
    /// or went. Cheap enough for every focus gain.
    pub fn refreshPins(self: *App) void {
        const file = self.pins_path orelse return;
        var before = self.pins;
        defer before.deinit(self.allocator);
        self.pins = pins_mod.List.load(self.allocator, self.io, file);
        const a = before.items.items;
        const b = self.pins.items.items;
        if (a.len == b.len) {
            for (a, b) |x, y| {
                if (x.kind != y.kind or !std.mem.eql(u8, x.path, y.path)) break;
            } else return;
        }
        self.pinsChanged();
    }

    /// What the sidebar and status line call a volume.
    fn deviceLabel(volume: *const volumes_mod.Volume, buf: []u8) []const u8 {
        if (volume.label.len > 0) return volume.label;
        var size: [32]u8 = undefined;
        const bytes: i64 = @intCast(@min(volume.size, std.math.maxInt(i64)));
        return std.fmt.bufPrint(buf, "{s} Volume", .{formatSize(bytes, &size)}) catch "Volume";
    }

    /// Starts watching for volumes. Once, after the window exists.
    pub fn startDevices(self: *App) void {
        if (self.devices != null or volumes_mod.disabled(self.environ)) return;
        self.devices = volumes_mod.Monitor.start();
    }

    /// Readable when `drainDevices` has news; -1 before `startDevices`.
    pub fn devicesWakeFd(self: *const App) c_int {
        return if (self.devices) |monitor| monitor.wakeFd() else -1;
    }

    pub fn drainDevices(self: *App) void {
        const monitor = self.devices orelse return;
        // Clear first: anything that lands after is a wake for the next loop.
        monitor.clearWake();
        const changed = monitor.take(self.allocator, &self.device_list) catch false;
        if (changed) {
            // Row indices moved: nothing indexed by one may outlive this.
            if (self.menu == .device) self.menu = null;
            self.nav_hover = .{};
            self.clampSidebarScroll();
            self.invalidate();
        }
        while (monitor.nextResult()) |result| self.deviceResult(&result);
    }

    fn startDeviceOp(self: *App, volume: *const volumes_mod.Volume, unmount: bool, open: bool) void {
        const monitor = self.devices orelse return;
        if (self.device_op != null) return;
        const id = self.allocator.dupe(u8, volume.id) catch return;
        self.device_op = .{ .id = id, .unmount = unmount, .open = open, .navigation = self.navigation_count };
        if (unmount) monitor.unmount(volume.id) else monitor.mount(volume.id);
        // Unmounting waits for pending writes, which can take a while.
        self.setStatusNotice(if (unmount) "Ejecting…" else "Mounting…", false);
    }

    /// A click on a device row: browse it, mounting it first when it is not.
    fn activateDevice(self: *App, k: usize) void {
        if (k >= self.device_list.items.len) return;
        const volume = &self.device_list.items[k];
        self.focus = .file_view;
        if (volume.mount) |mount| {
            self.navigate(mount);
        } else {
            self.startDeviceOp(volume, false, true);
        }
    }

    /// Unmounts a device. It stays listed, unmounted, while it is attached.
    fn ejectDevice(self: *App, k: usize) void {
        if (k >= self.device_list.items.len) return;
        const volume = &self.device_list.items[k];
        const mount = volume.mount orelse return;
        if (self.device_op != null) return;
        if (self.job_state == .running) {
            self.setStatusNotice("Finish the running file operation first", true);
            return;
        }
        // The window must not be what keeps the volume busy.
        if (volumes_mod.contains(mount, self.history.current)) self.home();
        self.startDeviceOp(volume, true, false);
    }

    fn deviceResult(self: *App, result: *const volumes_mod.Result) void {
        const op = self.device_op orelse return;
        self.device_op = null;
        defer self.allocator.free(op.id);
        var label_buf: [96]u8 = undefined;
        const name = if (self.device_list.find(volumes_mod.resultId(result))) |volume| deviceLabel(volume, &label_buf) else "Device";
        var buf: [160]u8 = undefined;
        if (result.ok == 0) {
            self.setStatusNotice(volumes_mod.failureMessage(&buf, result, name), true);
        } else if (op.unmount) {
            self.setStatusNotice(std.fmt.bufPrint(&buf, "{s} can be safely removed", .{name}) catch "Ejected", false);
        } else if (op.open and op.navigation == self.navigation_count and volumes_mod.resultPath(result).len > 0) {
            self.navigate(volumes_mod.resultPath(result));
        } else {
            self.setStatusNotice(std.fmt.bufPrint(&buf, "{s} mounted", .{name}) catch "Mounted", false);
        }
    }

    /// DEVICES: a heading and one row per volume, dimmed while unmounted, with
    /// an eject button on the mounted ones.
    fn renderDevices(self: *App, cr: *c.cairo_t, content_width: f64) void {
        if (self.device_list.items.len == 0) return;
        setSource(cr, ui_theme.global.window_fg);
        drawText(cr, "DEVICES", 24, @floatFromInt(self.placeY(self.deviceBase()) - 12), shell_ui.headingSize(), true);
        const accent = ui_theme.shellPalette().accent;
        const hovered = self.hoverKey();
        for (self.device_list.items, 0..) |*volume, k| {
            const index = self.deviceBase() + k;
            const y: f64 = @floatFromInt(self.placeY(index));
            const mounted = volume.mount != null;
            const alpha: f32 = if (mounted) 1 else 0.5;
            if (self.placeActive(index)) {
                const row = self.placeRect(index);
                roundedRect(cr, row.x, row.y, row.w, row.h, 5);
                setSource(cr, ui_theme.global.app_nav_selected);
                c.cairo_fill(cr);
                roundedRect(cr, 10, y + 3, 3, 24, 1.5);
                setSource(cr, accent);
                c.cairo_fill(cr);
            }
            if (shell_ui.Layer.begin(cr, .{ .x = 21, .y = @floatCast(y + 3), .w = 24, .h = 24 })) |icon_layer| {
                var layer = icon_layer;
                layer.renderer.drawIcon(0, 0, 24, 24, .{ .id = if (volume.kind == .stick) .usb_stick else .drive, .color = withAlpha(ui_theme.global.app_icon, alpha) });
                layer.finish();
            }
            setSource(cr, withAlpha(ui_theme.global.window_fg, alpha));
            const metrics = fontMetrics(cr, shell_ui.textSize());
            var label_buf: [96]u8 = undefined;
            const reserve: f64 = if (mounted) 28 else 0;
            drawEllipsis(cr, deviceLabel(volume, &label_buf), 54, y + (30 - metrics.ascent - metrics.descent) / 2 + metrics.ascent, content_width - 64 - reserve, shell_ui.textSize(), false);
            if (!mounted) continue;
            const button = self.ejectRect(index);
            if (hovered == 700 + k) {
                roundedRect(cr, button.x, button.y, button.w, button.h, 5);
                setSource(cr, ui_theme.global.app_item_hover);
                c.cairo_fill(cr);
            }
            if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(button.x + 5), .y = @floatCast(button.y + 5), .w = 16, .h = 16 })) |icon_layer| {
                var layer = icon_layer;
                layer.renderer.drawIcon(0, 0, 16, 16, .{ .id = .eject, .color = ui_theme.global.app_icon });
                layer.finish();
            }
        }
    }

    fn placeY(self: *App, index: usize) i32 {
        const step = self.placeStep();
        switch (self.rowKind(index)) {
            .pin => |j| return self.pinRowY(j),
            .device => |k| return self.pinRowY(self.pins.items.items.len) + 44 + @as(i32, @intCast(k)) * step,
            .builtin => {},
        }
        var hidden: i32 = 0;
        for (0..index) |i| {
            if (!self.placeVisible(i)) hidden += 1;
        }
        return self.contentTop() - self.sidebar_scroll - hidden * step + (if (index < places_start) 16 + @as(i32, @intCast(index)) * step else 80 + @as(i32, @intCast(index - 1)) * step);
    }

    /// Where pin `j` is drawn; `j` == the pin count is the slot under the last
    /// one, where the next section's heading gap starts.
    fn pinRowY(self: *App, j: usize) i32 {
        const step = self.placeStep();
        var hidden: i32 = 0;
        for (0..pin_base) |i| {
            if (!self.placeVisible(i)) hidden += 1;
        }
        return self.contentTop() - self.sidebar_scroll - hidden * step + 80 + @as(i32, @intCast(pin_base - 1 + j)) * step;
    }

    /// The sidebar's bar, along its right edge; null while its places fit.
    fn sidebarScrollbar(self: *App) ?scrollbar.Geometry {
        const width = self.sidebarWidth();
        if (width == 0) return null;
        const viewport: f32 = @floatFromInt(self.h - self.contentTop() - self.footerHeight());
        const gutter: f32 = @floatFromInt(self.scrollbarGutter());
        const track: scrollbar.Rect = .{ .x = @as(f32, @floatFromInt(width)) - gutter, .y = @floatFromInt(self.contentTop()), .w = gutter, .h = viewport };
        return scrollbar.Geometry.compute(.vertical, track, viewport, @floatFromInt(self.sidebarExtent() - self.contentTop()), @floatFromInt(self.sidebar_scroll));
    }

    /// The file view's bar, along the window's right edge below the header.
    fn scrollbarGeometry(self: *App) ?scrollbar.Geometry {
        const viewport: f32 = @floatFromInt(@max(0, self.h - self.viewTop() - self.footerHeight()));
        const gutter: f32 = @floatFromInt(self.scrollbarGutter());
        const track: scrollbar.Rect = .{ .x = @as(f32, @floatFromInt(self.w)) - gutter, .y = @floatFromInt(self.viewTop()), .w = gutter, .h = viewport };
        return scrollbar.Geometry.compute(.vertical, track, viewport, @floatFromInt(self.contentHeight()), @floatFromInt(self.scroll_y));
    }

    fn placePath(self: *App, index: usize, buf: []u8) ?[]const u8 {
        return switch (self.rowKind(index)) {
            .builtin => |i| switch (i) {
                0 => self.home_dir,
                1 => self.trash_dir orelse std.fmt.bufPrint(buf, "{s}/.local/share/Trash/files", .{self.home_dir}) catch null,
                2 => recent.location,
                else => std.fmt.bufPrint(buf, "{s}/{s}", .{ self.home_dir, places[i] }) catch null,
            },
            .pin => |j| self.pins.items.items[j].path,
            .device => null,
        };
    }

    fn renderSidebar(self: *App, cr: *c.cairo_t) void {
        const width: f64 = @floatFromInt(self.sidebarWidth());
        if (width == 0) return;
        const bar = self.sidebarScrollbar();
        // Labels keep their final layout while the panel grows or shrinks.
        const content_width = if (bar) |b| @as(f64, b.track.x) else @as(f64, @floatFromInt(self.sidebarTargetWidth()));
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        c.cairo_rectangle(cr, 0, @floatFromInt(self.contentTop()), width, @floatFromInt(self.h - self.contentTop() - self.footerHeight()));
        c.cairo_clip(cr);
        const accent = ui_theme.shellPalette().accent;
        setSource(cr, ui_theme.global.app_sidebar);
        c.cairo_paint(cr);
        self.renderGitSidebar(cr, content_width);
        // Under the labels: the glide passes over the PLACES heading.
        const glide = self.nav_hover.frame;
        if (glide.alpha > 0) {
            const box = self.navHighlight(glide);
            roundedRect(cr, box.x, box.y, box.w, box.h, 5);
            setSource(cr, withAlpha(ui_theme.global.app_item_hover, glide.alpha));
            c.cairo_fill(cr);
        }
        setSource(cr, ui_theme.global.window_fg);
        drawText(cr, "PLACES", 24, @floatFromInt(self.placeY(places_start) - 12), shell_ui.headingSize(), true);
        for (0..self.deviceBase()) |i| {
            if (!self.placeVisible(i)) continue;
            const y: f64 = @floatFromInt(self.placeY(i));
            var buf: [4096]u8 = undefined;
            const path = self.placePath(i, &buf) orelse continue;
            const pin: ?pins_mod.Pin = if (self.pinIndex(i)) |j| self.pins.items.items[j] else null;
            const label = switch (self.rowKind(i)) {
                .builtin => |b| places[b],
                .pin => pin.?.name(),
                .device => unreachable,
            };
            // A pin whose target is gone stays, dimmed, until it is removed.
            const alpha: f32 = if (pin != null and pin.?.kind == .missing) 0.5 else 1;
            const active = std.mem.eql(u8, path, self.history.current);
            if (active) {
                const row = self.placeRect(i);
                roundedRect(cr, row.x, row.y, row.w, row.h, 5);
                setSource(cr, ui_theme.global.app_nav_selected);
                c.cairo_fill(cr);
                roundedRect(cr, 10, y + 3, 3, 24, 1.5);
                setSource(cr, accent);
                c.cairo_fill(cr);
            }
            setSource(cr, withAlpha(ui_theme.global.app_icon, alpha));
            if (i < places_start) {
                if (shell_ui.Layer.begin(cr, .{ .x = 21, .y = @floatCast(y + 3), .w = 24, .h = 24 })) |icon_layer| {
                    var layer = icon_layer;
                    layer.renderer.drawIcon(0, 0, 24, 24, .{ .id = switch (i) {
                        0 => .home,
                        1 => .trash,
                        else => .clock,
                    }, .color = withAlpha(ui_theme.global.app_icon, alpha) });
                    layer.finish();
                }
            } else if (pin != null and pin.?.kind == .file) {
                // A page with a folded corner, like the folder beside it a plain shape.
                c.cairo_save(cr);
                c.cairo_set_line_width(cr, 1.5);
                c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
                c.cairo_move_to(cr, 29, y + 6.5);
                c.cairo_line_to(cr, 34.5, y + 6.5);
                c.cairo_line_to(cr, 39.5, y + 11.5);
                c.cairo_line_to(cr, 39.5, y + 21.5);
                c.cairo_line_to(cr, 29, y + 21.5);
                c.cairo_close_path(cr);
                c.cairo_fill_preserve(cr);
                c.cairo_stroke(cr);
                setSource(cr, withAlpha(ui_theme.global.app_icon, alpha * 0.5));
                c.cairo_move_to(cr, 34.5, y + 6.5);
                c.cairo_line_to(cr, 39.5, y + 11.5);
                c.cairo_line_to(cr, 34.5, y + 11.5);
                c.cairo_close_path(cr);
                c.cairo_fill(cr);
                c.cairo_restore(cr);
            } else {
                roundedRect(cr, 25, y + 7.5, 8, 5, 1);
                c.cairo_fill(cr);
                roundedRect(cr, 25, y + 10.5, 17, 12, 2);
                c.cairo_fill(cr);
            }
            setSource(cr, withAlpha(ui_theme.global.window_fg, alpha));
            const metrics = fontMetrics(cr, shell_ui.textSize());
            drawEllipsis(cr, label, 54, y + (30 - metrics.ascent - metrics.descent) / 2 + metrics.ascent, content_width - 64, shell_ui.textSize(), false);
        }
        self.renderDevices(cr, content_width);
        self.renderPinDrop(cr);
    }

    /// The line a drag shows between pins: where a drop would put its pin.
    fn renderPinDrop(self: *App, cr: *c.cairo_t) void {
        const slot = self.pin_drop orelse return;
        const y = self.pinBoundary(slot);
        const row = self.placeRect(0);
        setSource(cr, ui_theme.shellPalette().accent);
        roundedRect(cr, row.x + 5, y - 1.5, row.w - 10, 3, 1.5);
        c.cairo_fill(cr);
        c.cairo_arc(cr, row.x + 5, y, 3.5, 0, 2 * std.math.pi);
        c.cairo_fill(cr);
    }

    // Bottom of the sidebar content in scrolled coordinates: the Git card is the last section.
    fn sidebarExtent(self: *App) i32 {
        return self.pinRowY(self.pins.items.items.len) + self.sidebar_scroll + 8 + self.deviceBlock() + self.gitSidebarHeight();
    }

    fn gitSidebarHeight(self: *App) i32 {
        return if (self.repository() != null) 44 + @as(i32, @intFromFloat(self.gitCardHeight())) else 0;
    }

    const git_header_h: f64 = 32;
    const git_row_h: f64 = 28;

    const GitBranchRow = struct { name: []const u8, current: bool };

    // HEAD is listed first when it is not a branch (detached or unborn).
    fn gitHeadExtra(repo: git.Repository) usize {
        for (repo.branches) |name| {
            if (std.mem.eql(u8, name, repo.branch)) return 0;
        }
        return 1;
    }

    fn gitBranchRowCount(repo: git.Repository) usize {
        return repo.branches.len + gitHeadExtra(repo);
    }

    fn gitBranchRow(repo: git.Repository, i: usize) GitBranchRow {
        const extra = gitHeadExtra(repo);
        if (i < extra) return .{ .name = repo.branch, .current = true };
        const name = repo.branches[i - extra];
        return .{ .name = name, .current = std.mem.eql(u8, name, repo.branch) };
    }

    // Branch rows followed by the "New branch" row.
    fn gitCardHeight(self: *App) f64 {
        const repo = self.repository() orelse return git_header_h;
        if (!self.git_expanded) return git_header_h;
        return git_header_h + @as(f64, @floatFromInt(gitBranchRowCount(repo) + 1)) * git_row_h + 4;
    }

    fn gitCard(self: *App) header.Rect {
        return .{ .x = 10, .y = @floatFromInt(self.pinRowY(self.pins.items.items.len) + 44 + self.deviceBlock()), .w = @floatFromInt(self.sidebarWidth() - 20 - self.scrollbarGutter()), .h = self.gitCardHeight() };
    }

    fn renderGitSidebar(self: *App, cr: *c.cairo_t, content_width: f64) void {
        const repo = self.repository() orelse return;
        const card = self.gitCard();
        setSource(cr, ui_theme.global.window_fg);
        drawText(cr, "GIT", 24, card.y - 10, shell_ui.headingSize(), true);
        if (shell_ui.Layer.begin(cr, .{ .x = 23, .y = @floatCast(card.y + 6), .w = 20, .h = 20 })) |icon_layer| {
            var layer = icon_layer;
            layer.renderer.drawIcon(0, 0, 20, 20, .{ .id = .git_branch, .color = ui_theme.global.window_fg });
            layer.finish();
        }
        setSource(cr, ui_theme.global.window_fg);
        drawEllipsis(cr, std.fs.path.basename(repo.root), 50, card.y + 22, content_width - 80, shell_ui.textSize(), false);
        if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(content_width - 28), .y = @floatCast(card.y + 9), .w = 14, .h = 14 })) |icon_layer| {
            var layer = icon_layer;
            layer.renderer.drawIcon(0, 0, 14, 14, .{ .id = if (self.git_expanded) .chevron_down else .chevron_right, .color = ui_theme.global.window_fg });
            layer.finish();
        }
        if (!self.git_expanded) return;
        const right = content_width - 18;
        const rows = gitBranchRowCount(repo);
        for (0..rows + 1) |i| {
            const row_y = card.y + git_header_h + @as(f64, @floatFromInt(i)) * git_row_h;
            const baseline = row_y + 19;
            setSource(cr, ui_theme.global.window_fg);
            if (i == rows) {
                if (shell_ui.Layer.begin(cr, .{ .x = 24, .y = @floatCast(row_y + 7), .w = 14, .h = 14 })) |icon_layer| {
                    var layer = icon_layer;
                    layer.renderer.drawIcon(0, 0, 14, 14, .{ .id = .plus, .color = ui_theme.global.window_fg });
                    layer.finish();
                }
                drawText(cr, "New branch", 44, baseline, shell_ui.textSize(), false);
                break;
            }
            const row = gitBranchRow(repo, i);
            var counts_width: f64 = 0;
            if (row.current) {
                if (shell_ui.Layer.begin(cr, .{ .x = 24, .y = @floatCast(row_y + 7), .w = 14, .h = 14 })) |icon_layer| {
                    var layer = icon_layer;
                    layer.renderer.drawIcon(0, 0, 14, 14, .{ .id = .checkmark, .color = ui_theme.global.window_fg });
                    layer.finish();
                }
                if (repo.upstream) {
                    var counts_buf: [80]u8 = undefined;
                    const counts = std.fmt.bufPrint(&counts_buf, "↑{d}  ↓{d}", .{ repo.ahead, repo.behind }) catch "";
                    counts_width = measureText(cr, counts, shell_ui.statusSize(), false);
                    drawText(cr, counts, right - counts_width, baseline, shell_ui.statusSize(), false);
                }
            }
            var detached_buf: [40]u8 = undefined;
            const label = if (row.current and std.mem.eql(u8, row.name, "(detached)")) std.fmt.bufPrint(&detached_buf, "Detached {s}", .{repo.oid[0..@min(7, repo.oid.len)]}) catch "Detached" else row.name;
            drawEllipsis(cr, label, 44, baseline, @max(0, right - counts_width - 50), shell_ui.textSize(), row.current);
        }
    }

    fn renderGitStatus(self: *App, cr: *c.cairo_t, item: ViewItem, y: f64) void {
        const column = self.listColumn(1);
        const x = column.x + 4;
        const status = item.git_status;
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        c.cairo_rectangle(cr, column.x, y, column.w, @floatFromInt(self.cardHeight()));
        c.cairo_clip(cr);
        if (status != .clean) {
            roundedRect(cr, x, y + 5, 26, @as(f64, @floatFromInt(self.cardHeight())) - 10, 5);
            const tint = if (status == .deleted or status == .conflict) ui_theme.global.danger else ui_theme.global.accent;
            setSource(cr, withAlpha(tint, 0.25));
            c.cairo_fill(cr);
        }
        setSource(cr, ui_theme.global.window_fg);
        drawText(cr, status.label(), x + (26 - measureText(cr, status.label(), shell_ui.textSize(), true)) / 2, y + self.listBaseline(), shell_ui.textSize(), true);
        if (item.git_lines) |lines| {
            if (lines.added == 0 and lines.removed == 0) return;
            var buf: [32]u8 = undefined;
            var pen = x + 36;
            if (lines.added > 0) {
                const label = std.fmt.bufPrint(&buf, "+{d}", .{lines.added}) catch "";
                setSource(cr, ui_theme.global.app_git_added);
                drawText(cr, label, pen, y + self.listBaseline(), shell_ui.textSize(), false);
                pen += measureText(cr, label, shell_ui.textSize(), false) + 8;
            }
            if (lines.removed > 0) {
                const label = std.fmt.bufPrint(&buf, "−{d}", .{lines.removed}) catch "";
                setSource(cr, ui_theme.global.danger);
                drawText(cr, label, pen, y + self.listBaseline(), shell_ui.textSize(), false);
            }
        }
    }

    fn renderSidebarScrollbar(self: *App, cr: *c.cairo_t) void {
        const bar = self.sidebarScrollbar() orelse return;
        shell_ui.drawScrollbar(cr, scrollbar.look(bar, self.sidebar_scroll_appearance, self.scrollbar_width, ui_theme.shellPalette()));
    }

    fn clampScroll(self: *App) void {
        const max_scroll = self.maxScroll();
        self.scroll_y = std.math.clamp(self.scroll_y, 0, max_scroll);
    }

    fn maxScroll(self: *App) i32 {
        const total_h = self.contentHeight();
        const viewport_h = self.h - self.viewTop() - self.footerHeight();
        return @max(0, total_h - viewport_h);
    }

    fn revealIndex(self: *App, idx: usize) void {
        const row = @divTrunc(@as(i32, @intCast(idx)), self.columns());
        const row_top = if (row == 0) 0 else self.itemInset() + row * self.rowHeight();
        const row_bottom = self.itemInset() + row * self.rowHeight() + self.cardHeight();
        const viewport_h = self.h - self.viewTop() - self.footerHeight();

        if (row_top < self.scroll_y) {
            self.scroll_y = row_top;
        } else if (row_bottom > self.scroll_y + viewport_h) {
            self.scroll_y = row_bottom - viewport_h;
        }
        self.clampScroll();
        self.invalidate();
    }

    fn previewSelected(self: *App) void {
        if (self.chooser != null) return;
        const formats = @import("../images/formats.zig");
        const selected = self.focused_index orelse return;
        if (selected >= self.items.items.len) return;
        const item = self.items.items[selected];
        if (!item.selected or item.missing or item.is_broken) return;
        if (self.history.archive_len > 0) {
            if (item.is_dir) self.navigate(item.path) else self.openArchiveMember(item.path, true);
            return;
        }
        if (!item.is_dir and archive.candidate(item.name)) {
            self.browseArchive(item.path);
            return;
        }
        if (item.is_dir) return;
        if (isPdf(item.path)) {
            self.openFile(item.path);
            return;
        }
        if (!formats.candidate(item.path)) {
            if (!@import("../editor/formats.zig").candidate(item.path)) return;
            if (self.editor_path == null) self.editor_path = self.allocator.dupeZ(u8, item.path) catch null;
            return;
        }
        if (self.preview_return_fd != null) return;
        self.launchPreview(selected) catch |err| {
            std.log.warn("could not launch image preview: {}", .{err});
            self.setStatusNotice("Could not open image viewer", true);
        };
    }

    pub fn launchEditor(self: *App, token: []const u8) void {
        const path = self.editor_path orelse return;
        self.editor_path = null;
        defer self.allocator.free(path);
        var exe: [4096]u8 = undefined;
        var child = std.process.spawn(self.io, .{
            .argv = &.{ @import("../editor/operation.zig").executable(&exe, "rediwm-editor"), "--activation-token", token, "--", path },
        }) catch {
            self.setStatusNotice("Could not open Text Editor", true);
            return;
        };
        self.worker.recordOpened(path);
        self.children.add(self.allocator, child.id.?) catch child.kill(self.io);
    }

    fn launchPreview(self: *App, selected: usize) !void {
        // A seekable anonymous file avoids argv limits and blocking the UI on
        // a pipe. stdin carries NUL-separated absolute paths, including newlines.
        const fd = c.memfd_create("rediwm-image-list", c.MFD_CLOEXEC);
        if (fd < 0) return error.CreateListFailed;
        defer _ = c.close(fd);
        var index: usize = 0;
        var current: usize = 0;
        var size: usize = 0;
        for (self.items.items, 0..) |item, i| {
            if (item.is_dir or !@import("../images/formats.zig").candidate(item.path)) continue;
            if (i == selected) index = current;
            current += 1;
            size += item.path.len + 1;
            if (size > 16 * 1024 * 1024) return error.ListTooLarge;
            try writePreviewBytes(fd, item.path);
            try writePreviewBytes(fd, "\x00");
        }
        if (c.lseek(fd, 0, c.SEEK_SET) < 0) return error.SeekFailed;
        try self.launchImageList(fd, index);
        self.worker.recordOpened(self.items.items[selected].path);
    }

    fn launchImageList(self: *App, fd: c_int, index: usize) !void {
        var index_buf: [32]u8 = undefined;
        const index_arg = try std.fmt.bufPrint(&index_buf, "{d}", .{index});
        var exe_buf: [4096]u8 = undefined;
        var sibling_buf: [4096]u8 = undefined;
        var executable: []const u8 = "rediwm-images";
        const n = c.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
        if (n > 0 and n < exe_buf.len) {
            if (std.fs.path.dirname(exe_buf[0..@intCast(n)])) |dir| {
                const sibling = try std.fmt.bufPrintZ(&sibling_buf, "{s}/rediwm-images", .{dir});
                if (c.access(sibling, c.X_OK) == 0) executable = sibling;
            }
        }
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ executable, "--list-stdin", index_arg },
            .stdin = .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } },
            .stdout = .pipe,
        });
        self.preview_return_fd = child.stdout.?.handle;
        child.stdout = null; // the client event loop now owns this fd
        self.children.add(self.allocator, child.id.?) catch |err| {
            _ = c.close(self.preview_return_fd.?);
            self.preview_return_fd = null;
            child.kill(self.io);
            return err;
        };
    }

    fn writePreviewBytes(fd: c_int, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n <= 0) return error.WriteFailed;
            offset += @intCast(n);
        }
    }

    fn isPdf(path: []const u8) bool {
        return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".pdf");
    }

    pub fn openFile(self: *App, path: []const u8) void {
        if (self.chooser != null) return;
        const pdf = isPdf(path) and !@import("associations.zig").hasAlternativeDefault(path, "rediwm-pdf.desktop");
        if (!pdf) {
            @import("associations.zig").launchDefault(path) catch |err| {
                std.log.warn("failed to open '{s}': {}", .{ path, err });
                self.setStatusNotice("Could not open file", true);
                return;
            };
            self.worker.recordOpened(path);
            return;
        }
        var executable: []const u8 = "rediwm-pdf";
        var exe_buf: [4096]u8 = undefined;
        var sibling_buf: [4096]u8 = undefined;
        const n = c.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
        if (n > 0 and n < exe_buf.len) {
            if (std.fs.path.dirname(exe_buf[0..@intCast(n)])) |dir| {
                if (std.fmt.bufPrintZ(&sibling_buf, "{s}/rediwm-pdf", .{dir})) |sibling| {
                    if (c.access(sibling, c.X_OK) == 0) executable = sibling;
                } else |_| {}
            }
        }
        var child = std.process.spawn(self.io, .{
            .argv = &.{ executable, "--", path },
        }) catch |err| {
            std.log.warn("failed to open '{s}': {}", .{ path, err });
            self.setStatusNotice("Could not open file", true);
            return;
        };

        self.worker.recordOpened(path);
        self.children.add(self.allocator, child.id.?) catch child.kill(self.io);
    }

    fn browseArchive(self: *App, path: []const u8) void {
        self.rememberView();
        self.history.navigateLocation(path, path.len) catch return;
        self.worker.recordOpened(path);
        self.applyHistoryNav(self.history.current);
    }

    fn startExtraction(self: *App, path: []const u8, destination: []const u8) void {
        const runner = self.job_runner orelse return;
        runner.startArchive(path, destination, null) catch |err| {
            self.setStatusNotice(if (err == error.Busy) "A file operation is already running" else "Could not start extraction", true);
            return;
        };
        self.job_was_running = true;
        self.job_cut_revision = null;
        self.invalidate();
    }

    fn openArchiveMember(self: *App, path: []const u8, preview: bool) void {
        const len = self.history.archive_len;
        if (len == 0 or path.len <= len) return;
        const runner = self.job_runner orelse return;
        runner.startArchive(self.history.current[0..len], "/tmp", path[len + 1 ..]) catch |err| {
            self.setStatusNotice(if (err == error.Busy) "A file operation is already running" else "Could not open archive member", true);
            return;
        };
        self.archive_preview = preview;
        self.archive_open_navigation = self.navigation_count;
        self.job_was_running = true;
        self.job_cut_revision = null;
        self.invalidate();
    }

    fn openExtracted(self: *App, path: []const u8, preview: bool) void {
        if (preview and image_formats.candidate(path)) {
            self.previewExtracted(path) catch self.setStatusNotice("Could not open image viewer", true);
        } else if (preview and @import("../editor/formats.zig").candidate(path)) {
            if (self.editor_path == null) self.editor_path = self.allocator.dupeZ(u8, path) catch null;
        } else if (!preview or isPdf(path)) self.openFile(path);
    }

    fn previewExtracted(self: *App, path: []const u8) !void {
        if (self.preview_return_fd != null) return;
        const fd = c.memfd_create("rediwm-archive-preview", c.MFD_CLOEXEC);
        if (fd < 0) return error.CreateListFailed;
        defer _ = c.close(fd);
        try writePreviewBytes(fd, path);
        try writePreviewBytes(fd, "\x00");
        if (c.lseek(fd, 0, c.SEEK_SET) < 0) return error.SeekFailed;
        try self.launchImageList(fd, 0);
    }

    fn closeExtractPicker(self: *App) void {
        if (self.extract_picker_fd) |fd| _ = c.close(fd);
        if (self.extract_picker_source) |path| self.allocator.free(path);
        self.extract_picker_fd = null;
        self.extract_picker_source = null;
        self.extract_picker_bytes.clearRetainingCapacity();
    }

    fn chooseExtractionFolder(self: *App) void {
        if (self.extract_picker_fd != null) return;
        const path = self.selectedArchive() orelse return;
        const source = self.allocator.dupe(u8, path) catch return;
        var exe: [4096]u8 = undefined;
        const n = c.readlink("/proc/self/exe", &exe, exe.len);
        const executable: []const u8 = if (n > 0 and n < exe.len) exe[0..@intCast(n)] else "rediwm-files";
        var child = std.process.spawn(self.io, .{
            .argv = &.{ executable, "--folder", std.fs.path.dirname(path) orelse "/" },
            .stdout = .pipe,
        }) catch {
            self.allocator.free(source);
            self.setStatusNotice("Could not open folder picker", true);
            return;
        };
        const fd = child.stdout.?.handle;
        child.stdout = null;
        const flags = c.fcntl(fd, c.F_GETFL);
        if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) {
            _ = c.close(fd);
            child.kill(self.io);
            self.allocator.free(source);
            self.setStatusNotice("Could not open folder picker", true);
            return;
        }
        self.children.add(self.allocator, child.id.?) catch {
            _ = c.close(fd);
            child.kill(self.io);
            self.allocator.free(source);
            return;
        };
        self.extract_picker_source = source;
        self.extract_picker_fd = fd;
    }

    pub fn extractionFolderReady(self: *App) void {
        const fd = self.extract_picker_fd orelse return;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buffer, buffer.len);
            if (n < 0) switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return,
                else => {
                    self.closeExtractPicker();
                    self.setStatusNotice("Could not read folder picker result", true);
                    return;
                },
            };
            if (n == 0) break;
            if (self.extract_picker_bytes.items.len + @as(usize, @intCast(n)) > 65536) {
                self.closeExtractPicker();
                self.setStatusNotice("Invalid folder picker result", true);
                return;
            }
            self.extract_picker_bytes.appendSlice(self.allocator, buffer[0..@intCast(n)]) catch {
                self.closeExtractPicker();
                return;
            };
        }
        defer self.closeExtractPicker();
        if (self.extract_picker_bytes.items.len == 0) return;
        const parsed = std.json.parseFromSlice(chooser_mod.Result, self.allocator, self.extract_picker_bytes.items, .{}) catch {
            self.setStatusNotice("Invalid folder picker result", true);
            return;
        };
        defer parsed.deinit();
        if (parsed.value.paths.len == 1 and std.fs.path.isAbsolute(parsed.value.paths[0])) {
            self.startExtraction(self.extract_picker_source.?, parsed.value.paths[0]);
        }
    }

    pub fn activateItem(self: *App, idx: usize) void {
        if (idx >= self.items.items.len) return;
        const item = self.items.items[idx];
        if (item.is_broken or item.missing) {
            return;
        }
        if (item.is_dir) {
            self.navigate(item.path);
        } else if (self.chooser != null) {
            self.setChooserName(item.name);
            for (self.items.items, 0..) |*it, i| it.selected = i == idx or (self.chooser.?.multiple and it.selected);
            self.acceptChooser();
        } else if (self.history.archive_len > 0) {
            self.openArchiveMember(item.path, false);
        } else if (archive.candidate(item.name)) {
            self.browseArchive(item.path);
        } else {
            self.openFile(item.path);
        }
    }

    pub fn activateSelected(self: *App) void {
        if (self.focused_index) |idx| {
            self.activateItem(idx);
            return;
        }
        for (self.items.items, 0..) |it, idx| {
            if (it.selected and !it.missing) {
                self.activateItem(idx);
                return;
            }
        }
    }

    // Input handlers
    fn hoverKey(self: *App) usize {
        const x = self.mouse_x;
        const y = self.mouse_y;
        if (self.dialog) |dlg| {
            if (dlg.kind == .properties) return dlg.properties.?.hit(self.w, self.h, x, y);
            if (dlg.kind == .open_with) return dlg.applications.?.hit(self.w, self.h, x, y);
            if (dlg.kind == .trash_confirm) return @intFromEnum(dlg.deletion.geometry(self.w, self.h).target(x, y));
            const dw: f64 = @min(440, @as(f64, @floatFromInt(self.w)) - 24);
            const dx = (@as(f64, @floatFromInt(self.w)) - dw) / 2;
            const dy = (@as(f64, @floatFromInt(self.h)) - 130) / 2;
            if (y < dy + 84 or y > dy + 112) return 0;
            if (dlg.kind == .conflict) {
                for (0..3) |i| {
                    const left = dx + 16 + @as(f64, @floatFromInt(i)) * ((dw - 48) / 3 + 8);
                    if (x >= left and x <= left + (dw - 48) / 3) return i + 1;
                }
            } else {
                if (x >= dx + dw - 184 and x <= dx + dw - 104) return 1;
                if (x >= dx + dw - 96 and x <= dx + dw - 16) return 2;
            }
            return 0;
        }
        if (self.menu != null) return 100 + (self.menuHit(x, y) orelse 99);
        if (self.chooser) |opts| {
            if (y >= @as(f64, @floatFromInt(self.h - self.footerHeight()))) {
                for (0..4 + opts.choices.len) |i| {
                    if (self.chooserRect(i).contains(x, y)) return 501 + i;
                }
                return 500;
            }
        }
        if (header.hit(self.w, self.inRepository(), x, y)) |action| return 200 + @as(usize, @intFromEnum(action));
        if (self.list_view) {
            for (self.columnLabels(), 0..) |_, i| {
                if (i < 4 and self.listColumn(i).contains(x, y)) return 400 + i;
            }
        }
        if (x >= 0 and x < @as(f64, @floatFromInt(self.sidebarWidth())) and y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.h - self.footerHeight()))) {
            if (self.ejectAt(x, y)) |k| return 700 + k;
            for (0..self.rowCount()) |i| {
                if (!self.placeVisible(i)) continue;
                const row = self.placeRect(i);
                if (y >= row.y and y < row.y + row.h) return switch (self.rowKind(i)) {
                    .builtin => |b| 300 + b,
                    .pin => |j| 800 + j,
                    .device => |k| 600 + k,
                };
            }
        }
        if (self.itemAt(x, y)) |i| {
            if (self.sizeButtonRect(i)) |rect| {
                if (rect.contains(x, y)) {
                    if (self.folder_sizes.get(self.items.items[i].path)) |sz| {
                        switch (sz) {
                            .running => return 2_000_000 + i,
                            .done => {},
                        }
                    } else {
                        return 2_000_000 + i;
                    }
                }
            }
            return 1000 + i;
        }
        return 0;
    }

    pub fn handleMotion(self: *App, x: f64, y: f64) void {
        if (self.dialog) |*dlg| {
            const moved = switch (dlg.kind) {
                .properties => dlg.properties.?.motion(self.w, self.h, x, y),
                .open_with => dlg.applications.?.motion(self.w, self.h, x, y),
                .trash_confirm => dlg.deletion.motion(self.w, self.h, x, y),
                else => false,
            };
            if (moved) self.invalidate();
        }
        if (self.column_resize != null) {
            self.mouse_x = x;
            self.mouse_y = y;
            self.resizeColumn(x);
            return;
        }
        if (self.drag_origin) |origin| {
            const dx = x - origin.x;
            const dy = y - origin.y;
            if (dx * dx + dy * dy >= 64) {
                self.drag_ready = self.history.archive_len == 0;
                self.drag_origin = null;
                self.collapse_on_release = null;
                self.deselect_on_release = null;
                self.last_click_index = null;
            }
        }
        const old_hover = self.hoverKey();
        self.mouse_x = x;
        self.mouse_y = y;
        if (self.selection_band != null) self.updateSelectionBand();
        if (self.text_dragging) {
            self.placeCaret(x, true);
            self.edit_revision += 1;
            self.invalidate();
        }
        if (self.menu != null) {
            if (self.menuHit(x, y)) |row| self.menu_selected = row;
        }
        if (old_hover != self.hoverKey()) self.invalidateHover(old_hover, self.hoverKey());

        if (self.sidebar_scroll_drag.active) {
            if (self.sidebarScrollbar()) |bar| {
                const offset = self.sidebar_scroll_drag.offsetAt(bar, @floatCast(x), @floatCast(y));
                self.sidebar_scroll = @intFromFloat(@round(offset));
                self.invalidate();
            }
        }
        if (self.scroll_drag.active) {
            if (self.scrollbarGeometry()) |bar| {
                self.scroll_y = std.math.clamp(@as(i32, @intFromFloat(@round(self.scroll_drag.offsetAt(bar, @floatCast(x), @floatCast(y))))), 0, self.maxScroll());
                self.invalidate();
            }
        }
    }

    pub fn cancelDrag(self: *App) void {
        if (self.dialog) |*dlg| {
            dlg.deletion.placement.grab = null;
            if (dlg.properties) |*props| props.placement.grab = null;
            if (dlg.applications) |*apps| apps.placement.grab = null;
        }
        self.column_resize = null;
        if (self.selection_band != null) self.invalidate();
        self.selection_band = null;
        self.drag_origin = null;
        self.drag_ready = false;
        self.collapse_on_release = null;
        self.deselect_on_release = null;
    }

    fn bandRect(self: *App) header.Rect {
        const band = self.selection_band.?;
        const x = std.math.clamp(self.mouse_x, @as(f64, @floatFromInt(self.sidebarWidth())), @as(f64, @floatFromInt(self.w - self.scrollbarGutter())));
        const y = std.math.clamp(self.mouse_y, @as(f64, @floatFromInt(self.viewTop())), @as(f64, @floatFromInt(self.h - self.footerHeight()))) + @as(f64, @floatFromInt(self.scroll_y));
        return .{ .x = @min(band.x, x), .y = @min(band.y, y), .w = @abs(x - band.x), .h = @abs(y - band.y) };
    }

    fn updateSelectionBand(self: *App) void {
        const band = if (self.selection_band) |*b| b else return;
        const rect = self.bandRect();
        if (!band.active and rect.w * rect.w + rect.h * rect.h < 16) return;
        band.active = true;
        const cols = self.columns();
        for (self.items.items, 0..) |*item, i| {
            const index: i32 = @intCast(i);
            const x: f64 = @floatFromInt(self.sidebarWidth() + 20 + @mod(index, cols) * self.cellWidth());
            const y: f64 = @floatFromInt(self.viewTop() + self.itemInset() + @divTrunc(index, cols) * self.rowHeight());
            const hit = rect.x < x + @as(f64, @floatFromInt(self.cellWidth() - 20)) and rect.x + rect.w > x and
                rect.y < y + @as(f64, @floatFromInt(self.cardHeight())) and rect.y + rect.h > y;
            item.selected = if (band.toggle) item.selected_before_band != hit else hit or (band.extend and item.selected_before_band);
        }
        self.invalidate();
    }

    fn bandScrollDirection(self: *App) i32 {
        const band = self.selection_band orelse return 0;
        if (!band.active) return 0;
        if (self.mouse_y < @as(f64, @floatFromInt(self.viewTop() + 20)) and self.scroll_y > 0) return -1;
        if (self.mouse_y > @as(f64, @floatFromInt(self.h - 46)) and self.scroll_y < self.maxScroll()) return 1;
        return 0;
    }

    pub fn selectionNeedsScroll(self: *App) bool {
        return self.bandScrollDirection() != 0;
    }

    pub fn stepSelection(self: *App, now: i64) void {
        const band = if (self.selection_band) |*b| b else return;
        const elapsed = std.math.clamp(now - band.last_ms, 0, 50);
        band.last_ms = now;
        const direction = self.bandScrollDirection();
        if (direction == 0 or elapsed == 0) return;
        self.scroll_y = std.math.clamp(self.scroll_y + direction * @as(i32, @intCast(@max(1, @divTrunc(elapsed * 600, 1000)))), 0, self.maxScroll());
        self.updateSelectionBand();
    }

    fn renderSelectionBand(self: *App, cr: *c.cairo_t) void {
        const band = self.selection_band orelse return;
        if (!band.active) return;
        const rect = self.bandRect();
        const palette = ui_theme.shellPalette();
        setSource(cr, palette.selectionColor());
        c.cairo_rectangle(cr, rect.x, rect.y - @as(f64, @floatFromInt(self.scroll_y)), rect.w, rect.h);
        c.cairo_fill_preserve(cr);
        setSource(cr, palette.accent);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
    }

    pub fn cancelWheel(self: *App) void {
        self.wheel_glide.cancel(@floatFromInt(if (self.wheel_sidebar) self.sidebar_scroll else self.scroll_y));
    }

    fn wheelMax(self: *App) i32 {
        return if (self.wheel_sidebar) @max(0, self.sidebarExtent() - (self.h - self.footerHeight())) else self.maxScroll();
    }

    pub fn handleWheel(self: *App, delta_px: f64, now: i64) void {
        if (self.dialog) |*dlg| {
            if (dlg.properties) |*props| {
                props.wheel(delta_px, self.w, self.h);
                self.invalidate();
            }
            if (dlg.applications) |*apps| {
                apps.wheel(delta_px, self.w, self.h);
                self.invalidate();
            }
            return;
        }
        if (delta_px == 0) return;
        self.menu = null;
        const sidebar = self.mouse_x < @as(f64, @floatFromInt(self.sidebarWidth())) and self.mouse_y >= @as(f64, @floatFromInt(self.contentTop()));
        if (sidebar != self.wheel_sidebar) self.cancelWheel();
        self.wheel_sidebar = sidebar;
        if (!self.wheel_glide.active()) self.cancelWheel();
        const current = self.wheel_glide.value(now);
        const step: f32 = @floatCast(delta_px);
        if ((self.wheel_glide.to - current) * step < 0) self.wheel_glide.cancel(current);
        const target = std.math.clamp(self.wheel_glide.to + step, 0, @as(f32, @floatFromInt(self.wheelMax())));
        self.wheel_glide.retargetTo(now, target, anim.curveFor(.wheel_scroll));
        if (self.wheel_glide.settled(now)) {
            if (sidebar) self.sidebar_scroll = @intFromFloat(@round(target)) else self.scroll_y = @intFromFloat(@round(target));
            self.wheel_glide.cancel(target);
            self.invalidate();
        } else self.stepWheel(now);
    }

    pub fn stepWheel(self: *App, now: i64) void {
        if (!self.wheel_glide.active()) return;
        const value = std.math.clamp(self.wheel_glide.value(now), 0, @as(f32, @floatFromInt(self.wheelMax())));
        const offset = if (self.wheel_sidebar) &self.sidebar_scroll else &self.scroll_y;
        const next: i32 = @intFromFloat(@round(value));
        if (offset.* != next) {
            offset.* = next;
            self.invalidate();
        }
        if (self.wheel_glide.settled(now)) self.wheel_glide.cancel(value);
    }

    pub fn handleScroll(self: *App, delta_px: f64) void {
        if (self.dialog != null) {
            self.handleWheel(delta_px, nowMs());
            return;
        }
        self.cancelWheel();
        self.menu = null;
        const step: i32 = @intFromFloat(delta_px);
        if (self.mouse_x < @as(f64, @floatFromInt(self.sidebarWidth())) and self.mouse_y >= @as(f64, @floatFromInt(self.contentTop()))) {
            const max_sidebar = @max(0, self.sidebarExtent() - (self.h - self.footerHeight()));
            const next = std.math.clamp(self.sidebar_scroll + step, 0, max_sidebar);
            if (next != self.sidebar_scroll) self.invalidate();
            self.sidebar_scroll = next;
            return;
        }
        self.scroll_y = std.math.clamp(self.scroll_y + step, 0, self.maxScroll());
        self.invalidate();
    }

    pub fn handleButton(self: *App, button: u32, pressed: bool) void {
        // Mice report side buttons either as SIDE/EXTRA or BACK/FORWARD.
        if (button == 0x113 or button == 0x116 or button == 0x114 or button == 0x115) {
            if (!pressed or self.dialog != null) return;
            self.cancelWheel();
            self.cancelDrag();
            self.text_dragging = false;
            self.scroll_drag.end();
            self.sidebar_scroll_drag.end();
            if (self.menu != null) {
                self.menu = null;
                self.invalidate();
            }
            if (button == 0x113 or button == 0x116) self.back() else self.forward();
            return;
        }
        if (button != 0x110 and button != 0x111) return;

        self.cancelWheel();
        if (button == 0x110) {
            if (self.dialog) |*dlg| {
                const consumed = switch (dlg.kind) {
                    .properties => dlg.properties.?.pointerButton(self.w, self.h, self.mouse_x, self.mouse_y, pressed),
                    .open_with => dlg.applications.?.pointerButton(self.w, self.h, self.mouse_x, self.mouse_y, pressed),
                    .trash_confirm => dlg.deletion.pointerButton(self.w, self.h, self.mouse_x, self.mouse_y, pressed),
                    else => false,
                };
                if (consumed) return;
            }
        }
        if (!pressed) {
            if (button == 0x110) {
                if (self.collapse_on_release) |idx| {
                    for (self.items.items, 0..) |*it, i| it.selected = i == idx;
                    self.invalidate();
                }
                if (self.deselect_on_release) |idx| {
                    if (idx < self.items.items.len) self.items.items[idx].selected = false;
                    self.invalidate();
                }
                self.cancelDrag();
            }
            self.text_dragging = false;
            self.scroll_drag.end();
            self.sidebar_scroll_drag.end();
            return;
        }

        self.cancelDrag();
        self.edit_revision += 1;
        const now = nowMs();
        const x = self.mouse_x;
        const y = self.mouse_y;
        if (button == 0x110) {
            if (self.columnBoundary(x, y)) |column| {
                self.column_resize = .{ .column = column, .x = x, .widths = self.listWidths() };
                self.last_click_index = null;
                return;
            }
        }
        if (self.chooser != null and self.dialog == null and self.menu == null) {
            if (self.chooserClick(x, y, button)) return;
            if (button == 0x111) return;
        }

        // Modal Dialog click handling
        if (self.dialog != null and button != 0x110) return;
        if (self.dialog) |dlg| {
            if (dlg.kind == .properties) {
                const action = self.dialog.?.properties.?.click(self.w, self.h, x, y);
                self.propertiesAction(action);
                return;
            }
            if (dlg.kind == .open_with) {
                const action = self.dialog.?.applications.?.click(self.w, self.h, x, y);
                self.openWithAction(action);
                return;
            }
            if (dlg.kind == .trash_confirm) {
                self.deleteAction(dlg.deletion.geometry(self.w, self.h).hit(x, y));
                return;
            }
            if (self.renameCard()) |card| {
                if (card.confirm.contains(x, y)) {
                    self.confirmDialog();
                } else if (card.cancel.contains(x, y)) {
                    self.closeDialog();
                } else if (card.field.contains(x, y)) {
                    self.placeCaret(x, self.shift);
                    self.text_dragging = true;
                    self.invalidate();
                } else if (!card.panel.contains(x, y)) {
                    self.closeDialog();
                }
                return;
            }
            const dw: f64 = @min(440, @as(f64, @floatFromInt(self.w)) - 24);
            const dh: f64 = 130;
            const dx = (@as(f64, @floatFromInt(self.w)) - dw) / 2.0;
            const dy = (@as(f64, @floatFromInt(self.h)) - dh) / 2.0;

            if (dlg.kind == .conflict) {
                // Skip [dx + 16 .. dx + 16 + (dw - 48) / 3]
                if (x >= dx + 16 and x <= dx + 16 + (dw - 48) / 3 and y >= dy + 84 and y <= dy + 112) {
                    if (self.job_runner) |runner| runner.resolveConflict(.skip);
                    self.closeDialog();
                    return;
                }
                // Rename [dx + 24 + (dw - 48) / 3 .. dx + 24 + 2 * (dw - 48) / 3]
                if (x >= dx + 24 + (dw - 48) / 3 and x <= dx + 24 + 2 * (dw - 48) / 3 and y >= dy + 84 and y <= dy + 112) {
                    if (self.job_runner) |runner| runner.resolveConflict(.rename);
                    self.closeDialog();
                    return;
                }
                // Cancel [dx + 32 + 2 * (dw - 48) / 3 .. dx + dw - 16]
                if (x >= dx + 32 + 2 * (dw - 48) / 3 and x <= dx + dw - 16 and y >= dy + 84 and y <= dy + 112) {
                    if (self.job_runner) |runner| runner.resolveConflict(.cancel);
                    self.closeDialog();
                    return;
                }
            } else {
                // OK [dx + dw - 184 .. dx + dw - 104]
                if (x >= dx + dw - 184 and x <= dx + dw - 104 and y >= dy + 84 and y <= dy + 112) {
                    self.confirmDialog();
                    return;
                }
                // Cancel [dx + dw - 96 .. dx + dw - 16]
                if (x >= dx + dw - 96 and x <= dx + dw - 16 and y >= dy + 84 and y <= dy + 112) {
                    self.closeDialog();
                    return;
                }
            }

            if (self.activeEditor() != null and x >= dx + 16 and x < dx + dw - 16 and y >= dy + 42 and y < dy + 72) {
                self.placeCaret(x, self.shift);
                self.text_dragging = true;
                self.invalidate();
            }
            // Click outside dialog box closes
            if (x < dx or x > dx + dw or y < dy or y > dy + dh) {
                if (dlg.kind == .conflict) {
                    if (self.job_runner) |runner| runner.resolveConflict(.cancel);
                }
                self.closeDialog();
            }
            return;
        }

        if (self.menu != null) {
            if (button == 0x110) {
                if (self.menuHit(x, y)) |row| {
                    self.runMenu(row);
                    return;
                }
            }
            self.menu = null;
            self.invalidate();
            if (button == 0x110) return;
        }
        if (button == 0x111) {
            if (self.placeAt(x, y)) |index| {
                self.menu_place = index;
                self.openMenu(if (self.isDeviceRow(index)) .device else .sidebar, x, y);
                return;
            }
            if (y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.h - self.footerHeight())) and x >= @as(f64, @floatFromInt(self.sidebarWidth()))) {
                const hit = self.itemAt(x, y);
                if (hit) |idx| {
                    if (!self.items.items[idx].selected) {
                        for (self.items.items, 0..) |*it, i| it.selected = i == idx;
                    }
                    self.focused_index = idx;
                    self.selection_anchor = idx;
                } else {
                    for (self.items.items) |*it| it.selected = false;
                    self.focused_index = null;
                    self.selection_anchor = null;
                }
                self.focus = .file_view;
                self.openMenu(if (hit != null) .file else .background, x, y);
            }
            return;
        }
        if (header.hit(self.w, self.inRepository(), x, y)) |action| {
            self.runHeader(action);
            return;
        }
        if (header.field(self.w).contains(x, y)) {
            if (!self.search_visible and self.focus != .location_bar) {
                if (self.breadcrumbs(null, x)) |hit| {
                    self.navigate(hit.path);
                    return;
                }
            }
            self.focus = if (self.search_visible) .search else .location_bar;
            self.placeCaret(x, self.shift);
            self.text_dragging = true;
            self.invalidate();
            return;
        }

        if (self.sidebarScrollbar()) |bar| {
            if (scrollbar.press(bar, @floatCast(x), @floatCast(y), @floatFromInt(self.sidebar_scroll))) |action| {
                switch (action) {
                    .grab => self.sidebar_scroll_drag.begin(bar, @floatCast(x), @floatCast(y), @floatFromInt(self.sidebar_scroll)),
                    .page => |offset| {
                        self.sidebar_scroll = @intFromFloat(@round(offset));
                        self.invalidate();
                    },
                }
                return;
            }
        }
        if (self.ejectAt(x, y)) |k| {
            self.ejectDevice(k);
            return;
        }
        if (self.placeAt(x, y)) |index| {
            self.openPlace(index);
            return;
        }
        if (self.repository()) |repo| {
            if (y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.h - self.footerHeight())) and self.gitCard().contains(x, y)) {
                const card = self.gitCard();
                if (self.git_expanded and y >= card.y + git_header_h) {
                    const row: usize = @intFromFloat((y - card.y - git_header_h) / git_row_h);
                    const rows = gitBranchRowCount(repo);
                    if (row == rows) {
                        self.openNewBranchDialog();
                    } else if (row < rows) {
                        const branch = gitBranchRow(repo, row);
                        if (!branch.current) self.switchBranch(repo, branch.name, false);
                    }
                } else if (x >= card.x + card.w - 24) {
                    self.git_expanded = !self.git_expanded;
                    self.clampSidebarScroll();
                    self.invalidate();
                } else self.navigate(repo.root);
                return;
            }
        }
        if (x < @as(f64, @floatFromInt(self.sidebarWidth()))) return;

        if (self.list_view and y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.viewTop()))) {
            for (self.columnLabels(), 0..) |_, i| {
                if (self.listColumn(i).contains(x, y)) {
                    self.sortByColumn(i);
                    return;
                }
            }
        }

        // Use the same scrollbar gutter for input and content layout.
        if (x >= @as(f64, @floatFromInt(self.w - self.scrollbarGutter())) and y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.h - self.footerHeight()))) {
            if (self.scrollbarGeometry()) |bar| {
                if (scrollbar.press(bar, @floatCast(x), @floatCast(y), @floatFromInt(self.scroll_y))) |action| {
                    switch (action) {
                        .grab => self.scroll_drag.begin(bar, @floatCast(x), @floatCast(y), @floatFromInt(self.scroll_y)),
                        .page => |offset| {
                            self.scroll_y = @intFromFloat(@round(offset));
                            self.invalidate();
                        },
                    }
                }
            }
            return;
        }

        // File view area
        if (y >= @as(f64, @floatFromInt(self.contentTop())) and y < @as(f64, @floatFromInt(self.h - self.footerHeight())) and x < @as(f64, @floatFromInt(self.w - self.scrollbarGutter()))) {
            self.focus = .file_view;
            if (self.itemAt(x, y)) |idx| {
                if (button == 0x110) {
                    if (self.sizeButtonRect(idx)) |rect| {
                        if (rect.contains(x, y)) {
                            if (self.folder_sizes.get(self.items.items[idx].path)) |sz| {
                                switch (sz) {
                                    .running => {
                                        self.toggleFolderSize(idx);
                                        return;
                                    },
                                    .done => {},
                                }
                            } else {
                                self.toggleFolderSize(idx);
                                return;
                            }
                        }
                    }
                }

                // Double click check
                if (button == 0x110 and self.last_click_index == idx and (now - self.last_click_time < 400)) {
                    self.activateItem(idx);
                    self.last_click_index = null;
                    self.last_click_time = 0;
                    return;
                }

                self.last_click_index = idx;
                self.last_click_time = now;
                self.focused_index = idx;

                if (self.shift and self.selection_anchor != null and (self.chooser == null or self.chooser.?.multiple)) {
                    const start = @min(self.selection_anchor.?, idx);
                    const end = @max(self.selection_anchor.?, idx);
                    for (self.items.items, 0..) |*it, i| {
                        it.selected = (i >= start and i <= end);
                    }
                } else if (self.ctrl and (self.chooser == null or self.chooser.?.multiple)) {
                    if (button == 0x110 and self.chooser == null and self.items.items[idx].selected) {
                        self.deselect_on_release = idx;
                    } else {
                        self.items.items[idx].selected = !self.items.items[idx].selected;
                    }
                    self.selection_anchor = idx;
                } else {
                    if (button == 0x110 and self.items.items[idx].selected) {
                        self.collapse_on_release = idx;
                    } else {
                        for (self.items.items, 0..) |*it, i| it.selected = i == idx;
                    }
                    self.selection_anchor = idx;
                }
                if (self.chooser != null and !self.items.items[idx].is_dir) self.setChooserName(self.items.items[idx].name);
                if (self.chooser == null and button == 0x110 and self.items.items[idx].selected) self.drag_origin = .{ .x = x, .y = y };
            } else {
                // A background press starts a rubber-band selection; pressing
                // an item still starts an outgoing file drag.
                if (button == 0x110 and (self.chooser == null or self.chooser.?.multiple)) {
                    for (self.items.items) |*it| it.selected_before_band = it.selected;
                    self.selection_band = .{ .x = x, .y = y + @as(f64, @floatFromInt(self.scroll_y)), .toggle = self.ctrl, .extend = self.shift, .last_ms = now };
                    self.last_click_index = null;
                }
                if (!self.ctrl and !self.shift) {
                    for (self.items.items) |*it| it.selected = false;
                    self.selection_anchor = null;
                    self.focused_index = null;
                }
            }
            self.invalidate();
            return;
        }

        // Click outside location bar unfocuses it
        if (self.focus == .location_bar) {
            self.focus = .file_view;
            self.invalidate();
        }
    }

    /// Which held keys the client repeats: typing and caret keys in the
    /// search box, the location bar and dialog fields; moving through menus
    /// and the file list. Delete, Return, Space and every shortcut fire once:
    /// a held Delete must not trash file after file.
    pub fn keyRepeats(self: *const App, sym: u32, utf8: []const u8) bool {
        if (self.ctrl or self.alt) return false;
        const vertical = sym == c.XKB_KEY_Up or sym == c.XKB_KEY_Down;
        const typing = shell_key_repeat.editingKey(switch (sym) {
            c.XKB_KEY_BackSpace, c.XKB_KEY_Delete, c.XKB_KEY_Left, c.XKB_KEY_Right => true,
            else => false,
        }, utf8);
        if (self.dialog) |dlg| return if (dlg.kind == .open_with) vertical else dlg.kind != .properties and dlg.kind != .trash_confirm and dlg.kind != .conflict and typing;
        if (self.menu != null) return vertical;
        if (self.focus == .search or self.focus == .location_bar or self.focus == .filename) return typing;
        return vertical or sym == c.XKB_KEY_Left or sym == c.XKB_KEY_Right or
            sym == c.XKB_KEY_Page_Up or sym == c.XKB_KEY_Page_Down;
    }

    pub fn handleKey(self: *App, sym: u32, utf8: []const u8) void {
        self.cancelWheel();
        if (sym == c.XKB_KEY_Escape and self.selection_band != null) {
            for (self.items.items) |*it| it.selected = it.selected_before_band;
            self.cancelDrag();
            return;
        }
        self.cancelDrag();
        self.edit_revision += 1;
        if (self.dialog != null) {
            self.handleDialogKey(sym, utf8);
            return;
        }

        if (self.menu != null) {
            const count = self.menuLabels().len;
            if (sym == c.XKB_KEY_Escape) self.menu = null else if (sym == c.XKB_KEY_Down) self.menu_selected = (self.menu_selected + 1) % count else if (sym == c.XKB_KEY_Up) self.menu_selected = (self.menu_selected + count - 1) % count else if (sym == c.XKB_KEY_Return) self.runMenu(self.menu_selected);
            self.invalidate();
            return;
        }
        if (self.chooser != null and self.chooserKey(sym, utf8)) return;
        if (self.ctrl and (sym == c.XKB_KEY_f or sym == c.XKB_KEY_F)) {
            self.search_visible = true;
            self.focus = .search;
            self.search.select_all = true;
            self.invalidate();
            return;
        }
        if (self.ctrl and (sym == c.XKB_KEY_l or sym == c.XKB_KEY_L)) {
            self.search_visible = false;
            self.search.text.clearRetainingCapacity();
            self.search.cursor = 0;
            self.rebuildView();
            self.focus = .location_bar;
            self.location.select_all = true;
            self.invalidate();
            return;
        }
        if (self.focus == .search) {
            self.handleSearchKey(sym, utf8);
            return;
        }
        if (sym == c.XKB_KEY_Menu or (self.shift and sym == c.XKB_KEY_F10)) {
            self.openMenu(if (self.hasSelection()) .file else .background, @floatFromInt(self.sidebarWidth() + 24), @floatFromInt(self.contentTop() + 24));
            return;
        }
        if (self.focus == .location_bar) {
            self.handleLocationKey(sym, utf8);
            return;
        }

        // Navigation shortcuts with Alt
        if (self.alt) {
            if (sym == c.XKB_KEY_Return) {
                self.openSelectedProperties();
                return;
            }
            if (sym == c.XKB_KEY_Left) {
                self.back();
                return;
            } else if (sym == c.XKB_KEY_Right) {
                self.forward();
                return;
            } else if (sym == c.XKB_KEY_Up) {
                self.up();
                return;
            }
        }

        // Ctrl shortcuts
        if (self.ctrl) {
            if (self.shift and (sym == c.XKB_KEY_n or sym == c.XKB_KEY_N)) {
                self.openNewFolderDialog();
                return;
            } else if (sym == c.XKB_KEY_n or sym == c.XKB_KEY_N) {
                self.openNewFileDialog();
                return;
            } else if (sym == c.XKB_KEY_o or sym == c.XKB_KEY_O) {
                self.activateSelected();
                return;
            } else if (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C) {
                self.copySelected();
                return;
            } else if (sym == c.XKB_KEY_x or sym == c.XKB_KEY_X) {
                self.cutSelected();
                return;
            } else if (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V) {
                if (!self.isRecent()) self.paste_requested = true;
                return;
            } else if (sym == c.XKB_KEY_l or sym == c.XKB_KEY_L) {
                self.focus = .location_bar;
                self.location.select_all = true;
                self.invalidate();
                return;
            } else if (sym == c.XKB_KEY_h or sym == c.XKB_KEY_H) {
                self.toggleHidden();
                return;
            } else if (sym == c.XKB_KEY_a or sym == c.XKB_KEY_A) {
                for (self.items.items) |*it| it.selected = true;
                self.invalidate();
                return;
            }
        }

        if (sym == c.XKB_KEY_space and !self.ctrl and !self.alt and !self.shift) {
            self.previewSelected();
            return;
        }

        // General shortcuts
        if (sym == c.XKB_KEY_F5) {
            self.refresh();
            return;
        } else if (sym == c.XKB_KEY_F2) {
            self.openRenameDialog();
            return;
        } else if (sym == c.XKB_KEY_Delete) {
            self.openTrashConfirmDialog();
            return;
        } else if (sym == c.XKB_KEY_Return) {
            self.activateSelected();
            return;
        } else if (sym == c.XKB_KEY_Escape) {
            if (self.search_visible) {
                self.runHeader(.search);
                return;
            }
            if (self.job_runner) |runner| {
                const prog = runner.pollProgress();
                if (prog.state == .running or prog.state == .waiting_conflict) {
                    runner.cancel();
                    self.setStatusNotice("Cancelling operation...", false);
                    self.invalidate();
                    return;
                }
            }
            for (self.items.items) |*it| it.selected = false;
            self.selection_anchor = null;
            self.focused_index = null;
            self.invalidate();
            return;
        } else if (sym == c.XKB_KEY_Tab) {
            self.focus = if (self.search_visible) .search else .location_bar;
            self.location.select_all = true;
            self.invalidate();
            return;
        }

        // Arrow keys and scrolling in file view
        if (self.items.items.len == 0) return;

        if (sym == c.XKB_KEY_Down or sym == c.XKB_KEY_Right) {
            const step: usize = if (sym == c.XKB_KEY_Down) @intCast(self.columns()) else 1;
            const next_idx = if (self.focused_index) |idx| @min(self.items.items.len - 1, idx + step) else 0;
            self.selectIndex(next_idx);
        } else if (sym == c.XKB_KEY_Up or sym == c.XKB_KEY_Left) {
            const step: usize = if (sym == c.XKB_KEY_Up) @intCast(self.columns()) else 1;
            const prev_idx = if (self.focused_index) |idx| (if (idx > step) idx - step else 0) else 0;
            self.selectIndex(prev_idx);
        } else if (sym == c.XKB_KEY_Home) {
            self.selectIndex(0);
        } else if (sym == c.XKB_KEY_End) {
            const last_idx = self.items.items.len - 1;
            self.selectIndex(last_idx);
        } else if (sym == c.XKB_KEY_Page_Down) {
            const page_rows = @max(1, @divTrunc(self.h - self.viewTop() - self.footerHeight(), self.rowHeight())) * self.columns();
            const cur = self.focused_index orelse 0;
            const new_idx = @min(self.items.items.len - 1, cur + @as(usize, @intCast(@max(1, page_rows))));
            self.selectIndex(new_idx);
        } else if (sym == c.XKB_KEY_Page_Up) {
            const page_rows = @max(1, @divTrunc(self.h - self.viewTop() - self.footerHeight(), self.rowHeight())) * self.columns();
            const cur = self.focused_index orelse 0;
            const page_u = @as(usize, @intCast(@max(1, page_rows)));
            const new_idx = if (cur > page_u) cur - page_u else 0;
            self.selectIndex(new_idx);
        }
    }

    fn selectIndex(self: *App, index: usize) void {
        if (self.shift and (self.chooser == null or self.chooser.?.multiple)) {
            const anchor = self.selection_anchor orelse self.focused_index orelse index;
            self.selection_anchor = anchor;
            for (self.items.items, 0..) |*it, i| {
                const in_range = i >= @min(anchor, index) and i <= @max(anchor, index);
                it.selected = in_range or (self.ctrl and it.selected);
            }
        } else if (!self.ctrl or (self.chooser != null and !self.chooser.?.multiple)) {
            for (self.items.items, 0..) |*it, i| it.selected = i == index;
            self.selection_anchor = index;
        }
        self.focused_index = index;
        if (self.chooser != null and !self.items.items[index].is_dir) self.setChooserName(self.items.items[index].name);
        self.revealIndex(index);
    }

    fn handleLocationKey(self: *App, sym: u32, utf8: []const u8) void {
        if (sym == c.XKB_KEY_Escape) {
            self.location.text.clearRetainingCapacity();
            self.location.text.appendSlice(self.allocator, self.history.current) catch {};
            self.location.cursor = self.location.text.items.len;
            self.location.select_all = false;
            self.focus = .file_view;
            self.invalidate();
            return;
        } else if (sym == c.XKB_KEY_Return) {
            var raw = std.mem.trim(u8, self.location.text.items, " \t\r\n");
            if (raw.len == 0) raw = "/";

            // Expand ~ to home_dir
            var target_buf: [4096]u8 = undefined;
            var target: []const u8 = raw;
            if (std.mem.startsWith(u8, raw, "~")) {
                target = std.fmt.bufPrint(&target_buf, "{s}{s}", .{ self.home_dir, raw[1..] }) catch raw;
            }

            // Clean path
            const resolved = if (recent.isLocation(target)) target else std.fs.path.resolve(self.allocator, &.{target}) catch target;
            defer if (resolved.ptr != target.ptr) self.allocator.free(resolved);

            self.navigate(resolved);
            self.focus = .file_view;
            self.invalidate();
            return;
        } else if (sym == c.XKB_KEY_Tab) {
            self.focus = .file_view;
            self.invalidate();
            return;
        }
        self.editKey(&self.location, sym, utf8);
    }

    pub fn activeEditor(self: *App) ?*Editor {
        if (self.dialog) |*dlg| return switch (dlg.kind) {
            .new_folder, .new_file, .new_branch, .rename => &dlg.edit,
            else => null,
        };
        return switch (self.focus) {
            .location_bar => &self.location,
            .search => &self.search,
            .filename => &self.filename,
            else => null,
        };
    }

    fn editKey(self: *App, edit: *Editor, sym: u32, utf8: []const u8) void {
        if (self.ctrl and (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C or sym == c.XKB_KEY_x or sym == c.XKB_KEY_X)) {
            const sel = edit.selection();
            if (sel[0] != sel[1]) {
                self.clipboard_text.clearRetainingCapacity();
                self.clipboard_text.appendSlice(self.allocator, edit.text.items[sel[0]..sel[1]]) catch return;
                self.clearClipboard();
                self.clipboard_cut = false;
                self.clipboard_is_text = true;
                self.clipboard_revision += 1;
                if (sym == c.XKB_KEY_x or sym == c.XKB_KEY_X) edit.insert(self.allocator, "") catch {};
            }
        } else if (self.ctrl and (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V)) {
            self.text_paste_requested = true;
        } else edit.key(self.allocator, sym, utf8, self.ctrl, self.shift, self.alt);
        self.invalidate();
    }

    pub fn pasteText(self: *App, bytes: []const u8) void {
        const edit = self.activeEditor() orelse return;
        if (self.focus == .filename) self.overwrite_pending = false;
        edit.insert(self.allocator, bytes) catch {
            self.setStatusNotice("Clipboard text is invalid or too long", true);
            return;
        };
        self.edit_revision += 1;
        if (self.focus == .search and self.dialog == null) self.rebuildView();
        self.invalidate();
    }

    fn hasSelection(self: *App) bool {
        for (self.items.items) |item| {
            if (item.selected) return true;
        }
        return false;
    }

    fn runHeader(self: *App, action: header.Action) void {
        if (!self.toolbarButtonEnabled(action)) return;
        if (self.chooser != null) switch (action) {
            .cut, .copy, .paste, .trash => return,
            .new => {
                self.openNewFolderDialog();
                return;
            },
            else => {},
        };
        if ((action == .cut or action == .copy or action == .trash) and !self.hasSelection()) return;
        self.focus = .file_view;
        switch (action) {
            .back => self.back(),
            .forward => self.forward(),
            .up => self.up(),
            .refresh => self.refresh(),
            .cut => self.cutSelected(),
            .copy => self.copySelected(),
            .paste => self.paste_requested = true,
            .trash => self.openTrashConfirmDialog(),
            .git_view => {
                self.setGitView(!self.git_view);
            },
            .grid, .list => {
                if (self.repository() != null) return;
                self.list_view = action == .list;
                self.savePreferences();
                self.last_click_index = null;
                self.clampScroll();
                if (self.focused_index) |idx| self.revealIndex(idx);
            },
            .new, .sort, .filter => {
                const r = header.rect(self.w, self.inRepository(), action);
                self.openMenu(switch (action) {
                    .new => .new,
                    .sort => .sort,
                    else => .filter,
                }, r.x, r.y + r.h + 4);
            },
            .search => {
                self.search_visible = !self.search_visible;
                if (self.search_visible) {
                    self.focus = .search;
                    self.search.select_all = true;
                } else {
                    self.search.text.clearRetainingCapacity();
                    self.search.cursor = 0;
                    self.rebuildView();
                }
            },
        }
        self.invalidate();
    }

    fn menuRowHeight(self: *App) usize {
        if (self.isContextMenu()) {
            // Keep all actions reachable at the client's minimum height.
            const available: usize = @intCast(@max(0, self.h - 8));
            const spacing = 2 * self.menuPadding() + self.menuSeparatorSpace();
            return @min(context_menu.row_height, (available -| spacing) / self.menuLabels().len);
        }
        return if (self.menu == .sort) 24 else 30;
    }

    fn isContextMenu(self: *App) bool {
        return self.menu == .file or self.menu == .background or self.menu == .sidebar or self.menu == .device;
    }

    fn menuWidth(self: *App) f64 {
        return if (self.isContextMenu()) context_menu.width else 220;
    }

    fn menuPadding(_: *App) usize {
        return context_menu.padding;
    }

    fn menuSeparatorBefore(self: *App, row: usize) bool {
        return switch (self.menu orelse return false) {
            .file => switch (self.fileActions()[row]) {
                .cut, .extract, .properties => true,
                else => false,
            },
            .background => row == 2,
            .sidebar => row == self.menuLabels().len - 1,
            else => false,
        };
    }

    fn menuSeparatorSpace(self: *App) usize {
        var count: usize = 0;
        for (0..self.menuLabels().len) |row| {
            if (self.menuSeparatorBefore(row)) count += 7;
        }
        return count;
    }

    fn menuHeight(self: *App) f64 {
        return @floatFromInt(self.menuLabels().len * self.menuRowHeight() +
            2 * self.menuPadding() + self.menuSeparatorSpace());
    }

    // Painting and hit testing share the row geometry, including separator gaps.
    fn menuRowRect(self: *App, row: usize) header.Rect {
        var offset = self.menuPadding() + row * self.menuRowHeight();
        for (0..row + 1) |i| {
            if (self.menuSeparatorBefore(i)) offset += 7;
        }
        const pad: f64 = @floatFromInt(self.menuPadding());
        return .{
            .x = self.menu_x + pad,
            .y = self.menu_y + @as(f64, @floatFromInt(offset)),
            .w = self.menuWidth() - 2 * pad,
            .h = @floatFromInt(self.menuRowHeight()),
        };
    }

    fn menuIcon(self: *App, row: usize) ?IconId {
        // Reuse the shell glyphs until dedicated file-action artwork is available.
        return switch (self.menu orelse return null) {
            .file => self.fileActions()[row].icon(),
            .background => if (self.history.archive_len > 0 or self.isRecent()) .refresh else ([_]IconId{ .plus, .edit, .paste, .refresh })[row],
            else => null,
        };
    }

    // Faint shortcut text shown on the right of a context-menu row.
    fn menuHint(self: *App, row: usize) ?[]const u8 {
        const label = self.menuLabels()[row];
        if (std.mem.eql(u8, label, "Properties")) return "ALT+ENTER";
        if (self.menu != .file and self.menu != .background) return null;
        const hints = [_][2][]const u8{
            .{ "Open", "CTRL+O" },
            .{ "Cut", "CTRL+X" },
            .{ "Copy", "CTRL+C" },
            .{ "Paste", "CTRL+V" },
            .{ "Rename", "F2" },
            .{ "Move to Trash", "DELETE" },
            .{ "Refresh", "F5" },
        };
        for (hints) |hint| {
            if (std.mem.eql(u8, label, hint[0])) return hint[1];
        }
        return null;
    }

    fn hasSizeSelection(self: *App) bool {
        for (self.items.items) |item| {
            if (item.selected and item.is_dir and !item.is_symlink) return true;
        }
        return false;
    }

    fn selectedArchive(self: *App) ?[]const u8 {
        if (self.chooser != null or self.history.archive_len > 0) return null;
        var selected: ?[]const u8 = null;
        for (self.items.items) |item| {
            if (!item.selected) continue;
            if (selected != null or item.is_dir or item.is_broken or item.missing or !archive.candidate(item.name)) return null;
            selected = item.path;
        }
        return selected;
    }

    fn fileActions(self: *App) []const FileAction {
        if (self.history.archive_len > 0) return &.{.open};
        if (self.isRecent()) {
            if (self.selectedArchive() != null) return &.{ .open, .open_with, .extract, .extract_to, .cut, .copy, .rename, .trash, .properties };
            if (self.canOpenWith()) return &.{ .open, .open_with, .cut, .copy, .rename, .trash, .properties };
            return &.{ .open, .cut, .copy, .rename, .trash, .properties };
        }
        if (self.selectedArchive() != null) return &.{ .open, .open_with, .extract, .extract_to, .cut, .copy, .paste, .rename, .trash, .properties };
        if (self.canOpenWith()) return &.{ .open, .open_with, .cut, .copy, .paste, .rename, .trash, .properties };
        if (self.hasSizeSelection()) return &.{ .open, .cut, .copy, .paste, .rename, .trash, .size, .properties };
        return &.{ .open, .cut, .copy, .paste, .rename, .trash, .properties };
    }

    fn menuLabels(self: *App) []const []const u8 {
        return switch (self.menu orelse return &.{}) {
            .new => &.{ "New Folder", "New File" },
            .sort => &.{ "Name: A to Z", "Name: Z to A", "Largest first", "Newest first", "Type: A to Z", "Smallest first", "Oldest first", "Type: Z to A" },
            .filter => if (self.repository() != null)
                &.{ "Folders only", "Show hidden files", "Show changed files", "Show full paths" }
            else
                &.{ "Folders only", "Show hidden files" },
            .file => blk: {
                const actions = self.fileActions();
                for (actions, 0..) |action, i| self.file_menu_labels[i] = action.label();
                break :blk self.file_menu_labels[0..actions.len];
            },
            .sidebar => if (self.menu_place == 2) &.{"Open"} else if (placePinnable(self.menu_place))
                &.{ "Open", "Unpin", "Properties" }
            else switch (self.rowKind(self.menu_place)) {
                .pin => &.{ "Open", "Remove from Places", "Properties" },
                else => &.{ "Open", "Properties" },
            },
            .device => if (self.deviceAt(self.menu_place)) |volume|
                (if (volume.mount != null) &.{ "Open", "Eject" } else &.{"Mount"})
            else
                &.{},
            .background => if (self.history.archive_len > 0 or self.isRecent()) &.{"Refresh"} else &.{ "New Folder", "New File", "Paste", "Refresh" },
            .chooser_filter => self.chooser_filter_labels.items,
        };
    }

    fn openMenu(self: *App, kind: MenuKind, x: f64, y: f64) void {
        self.menu = kind;
        const height = self.menuHeight();
        self.menu_x = std.math.clamp(x, 4, @max(4, @as(f64, @floatFromInt(self.w)) - self.menuWidth() - 4));
        self.menu_y = std.math.clamp(y, 4, @max(4, @as(f64, @floatFromInt(self.h)) - height - 4));
        self.menu_selected = 0;
        self.last_click_index = null;
        self.invalidate();
    }

    fn menuHit(self: *App, x: f64, y: f64) ?usize {
        for (0..self.menuLabels().len) |row| {
            if (self.menuRowRect(row).contains(x, y)) return row;
        }
        return null;
    }

    fn runMenu(self: *App, row: usize) void {
        const kind = self.menu orelse return;
        const properties_row = self.menuLabels().len - 1;
        const file_action: ?FileAction = if (kind == .file and row < self.fileActions().len) self.fileActions()[row] else null;
        self.menu = null;
        switch (kind) {
            .sidebar => {
                if (row == 0) {
                    self.openPlace(self.menu_place);
                } else if (row == 1 and placePinnable(self.menu_place)) {
                    self.unpinned_places |= @as(u8, 1) << @as(u3, @intCast(self.menu_place - places_start));
                    self.sidebar_scroll = std.math.clamp(self.sidebar_scroll, 0, @max(0, self.sidebarExtent() - (self.h - self.footerHeight())));
                    self.nav_hover = .{};
                    self.savePreferences();
                } else if (row == 1 and self.pinIndex(self.menu_place) != null) {
                    self.removePin(self.pinIndex(self.menu_place).?);
                } else if (row == properties_row) {
                    var buf: [4096]u8 = undefined;
                    if (self.placePath(self.menu_place, &buf)) |path| self.openProperties(path, null);
                }
            },
            .device => if (self.deviceAt(self.menu_place) != null) {
                const k = self.menu_place - self.deviceBase();
                if (self.device_list.items[k].mount == null or row == 0) self.activateDevice(k) else self.ejectDevice(k);
            },
            .chooser_filter => {
                if (row < self.chooser.?.filters.len) self.chooser.?.filter_index = row;
                self.rebuildView();
            },
            .new => switch (row) {
                0 => self.openNewFolderDialog(),
                1 => self.openNewFileDialog(),
                else => {},
            },
            .sort => {
                if (row < 8) self.setSort(@enumFromInt(row));
                self.rebuildView();
                self.savePreferences();
                self.scroll_y = 0;
                if (self.focused_index) |idx| self.revealIndex(idx);
                self.startSortFeedback(nowMs());
            },
            .filter => {
                if (row == 0) {
                    self.folders_only = !self.folders_only;
                    self.scroll_y = 0;
                    self.rebuildView();
                } else if (row == 1) {
                    self.toggleHidden();
                } else if (row == 2 and self.repository() != null) {
                    self.changed_only = !self.changed_only;
                    self.scroll_y = 0;
                    self.rebuildView();
                } else if (row == 3 and self.repository() != null) {
                    self.full_paths = !self.full_paths;
                    self.rebuildView();
                }
            },
            .file => if (file_action) |action| switch (action) {
                .open => self.activateSelected(),
                .open_with => self.openWithDialog(),
                .extract => if (self.selectedArchive()) |path| self.startExtraction(path, std.fs.path.dirname(path) orelse "/"),
                .extract_to => self.chooseExtractionFolder(),
                .cut => self.cutSelected(),
                .copy => self.copySelected(),
                .paste => self.paste_requested = true,
                .rename => self.openRenameDialog(),
                .trash => self.openTrashConfirmDialog(),
                .size => self.calculateSizeSelected(),
                .properties => self.openSelectedProperties(),
            },
            .background => if (self.history.archive_len > 0 or self.isRecent()) self.refresh() else switch (row) {
                0 => self.openNewFolderDialog(),
                1 => self.openNewFileDialog(),
                2 => self.paste_requested = true,
                3 => self.refresh(),
                else => {},
            },
        }
        self.invalidate();
    }

    fn renderMenu(self: *App, cr: *c.cairo_t) void {
        const labels = self.menuLabels();
        const context = self.isContextMenu();
        const width = self.menuWidth();
        const height = self.menuHeight();
        context_menu.frame(cr, .{ .x = self.menu_x, .y = self.menu_y, .w = width, .h = height }, context);
        for (labels, 0..) |label, i| {
            const row = self.menuRowRect(i);
            const checked = (self.menu == .sort and i == @intFromEnum(self.effectiveSort())) or
                (self.menu == .filter and ((i == 0 and self.folders_only) or (i == 1 and self.show_hidden) or (i == 2 and self.changed_only) or (i == 3 and self.full_paths)));
            context_menu.row(cr, .{ .x = row.x, .y = row.y, .w = row.w, .h = row.h }, .{
                .label = label,
                .icon = self.menuIcon(i) orelse if (checked) @as(?IconId, .checkmark) else null,
                .hint = if (context) self.menuHint(i) else null,
                .selected = self.menu_selected == i,
                .separator = self.menuSeparatorBefore(i),
            }, context);
        }
    }

    fn handleSearchKey(self: *App, sym: u32, utf8: []const u8) void {
        if (sym == c.XKB_KEY_Escape) {
            self.search.text.clearRetainingCapacity();
            self.search.cursor = 0;
            self.search_visible = false;
            self.focus = .file_view;
        } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_Down) {
            self.focus = .file_view;
            if (self.items.items.len > 0) {
                self.focused_index = 0;
                self.selection_anchor = 0;
                for (self.items.items, 0..) |*item, i| item.selected = i == 0;
                self.revealIndex(0);
            }
            self.invalidate();
            return;
        } else {
            self.editKey(&self.search, sym, utf8);
            self.scroll_y = 0;
        }
        self.rebuildView();
        self.invalidate();
    }

    fn renderHeader(self: *App, cr: *c.cairo_t) void {
        const width: f64 = @floatFromInt(self.w);
        setSource(cr, ui_theme.global.app_toolbar);
        c.cairo_rectangle(cr, 0, 0, width, @floatFromInt(self.contentTop()));
        c.cairo_fill(cr);
        setSource(cr, ui_theme.global.app_divider);
        c.cairo_set_line_width(cr, 1);
        c.cairo_move_to(cr, 0, 54.5);
        c.cairo_line_to(cr, width, 54.5);
        c.cairo_move_to(cr, 0, @as(f64, @floatFromInt(self.contentTop())) - 0.5);
        c.cairo_line_to(cr, width, @as(f64, @floatFromInt(self.contentTop())) - 0.5);
        c.cairo_stroke(cr);
        const in_repo = self.inRepository();
        for ([_]bool{ false, true }) |content| {
            if (content) self.renderToolbarHover(cr);
            for (std.meta.tags(header.Action)) |action| {
                if (!self.toolbarButtonVisible(action)) continue;
                const r = header.rect(self.w, in_repo, action);
                const enabled = self.toolbarButtonEnabled(action);
                const active = (action == .grid and !self.list_view) or (action == .list and self.list_view) or
                    (action == .filter and (self.folders_only or self.show_hidden or self.changedOnly())) or (action == .search and self.search_visible);
                const opts: ui_button.Options = switch (action) {
                    .new => .{ .leading_icon = .plus, .label = "New" },
                    .sort => .{ .leading_icon = .sort, .label = switch (self.effectiveSort()) {
                        .name, .name_desc => "Name",
                        .size, .size_asc => "Size",
                        .modified, .modified_asc => "Date",
                        .type, .type_desc => "Type",
                    } },
                    .filter => .{ .leading_icon = .filter, .label = "Filter" },
                    else => .{ .variant = .ghost, .icon = header.glyph(action), .icon_scale = 0.56, .label = @tagName(action) },
                };
                var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse continue;
                const state: ui_button.State = .{ .pointer = if (enabled) .idle else .disabled, .selected = active };
                if (content) ui_button.paintContent(&layer.renderer, layer.local(), opts, state) else ui_button.paintBackground(&layer.renderer, layer.local(), opts, state);
                layer.finish();
            }
        }
        if (header.visible(self.w, in_repo, .git_view)) self.renderGitViewToggle(cr);
        const field = header.field(self.w);
        self.renderLocationBar(cr, field.x, field.y, field.w, field.h);
    }

    fn renderToolbarHover(self: *App, cr: *c.cairo_t) void {
        const hover = self.toolbar_hover;
        if (hover.opacity <= 0) return;
        const r = hover.frame;
        if (shell_ui.Layer.begin(cr, .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] })) |value| {
            var layer = value;
            var palette = layer.renderer.palette.?;
            palette.surface_hover[3] *= hover.opacity;
            layer.renderer.palette = palette;
            ui_button.paintBackground(&layer.renderer, layer.local(), .{ .variant = .ghost }, .{ .pointer = .hover });
            layer.finish();
        }
    }

    /// "Git View" checkbox and the faint rule that sets it apart from the view buttons.
    fn renderGitViewToggle(self: *App, cr: *c.cairo_t) void {
        const rule = header.gitSeparator(self.w);
        setSource(cr, ui_theme.global.app_divider);
        c.cairo_set_line_width(cr, 1);
        c.cairo_move_to(cr, rule.x + 0.5, rule.y);
        c.cairo_line_to(cr, rule.x + 0.5, rule.y + rule.h);
        c.cairo_stroke(cr);
        const r = header.rect(self.w, true, .git_view);
        var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse return;
        ui_checkbox.paint(&layer.renderer, layer.local(), "Git View", .{
            .checked = self.git_view,
            .focused = r.contains(self.mouse_x, self.mouse_y),
        });
        layer.finish();
    }

    // Cairo Rendering
    pub fn render(self: *App, cr: *c.cairo_t) void {
        const w_f = @as(f64, @floatFromInt(self.w));
        const h_f = @as(f64, @floatFromInt(self.h));

        // 1. Background
        setSource(cr, ui_theme.global.app_bg);
        c.cairo_paint(cr);

        self.renderHeader(cr);

        self.renderSidebar(cr);
        self.renderSidebarScrollbar(cr);

        // 3. Content Area (Files View)
        const viewport_h = self.h - self.viewTop() - self.footerHeight();
        c.cairo_save(cr);
        c.cairo_rectangle(cr, @floatFromInt(self.sidebarWidth()), @floatFromInt(self.viewTop()), w_f - @as(f64, @floatFromInt(self.sidebarWidth())), @as(f64, @floatFromInt(viewport_h)));
        c.cairo_clip(cr);

        if (self.list_view) {
            const column = self.listColumn(if (self.repository() != null) 0 else self.sortColumn());
            setSource(cr, ui_theme.global.surface);
            c.cairo_rectangle(cr, column.x, @floatFromInt(self.viewTop()), column.w, @floatFromInt(viewport_h));
            c.cairo_fill(cr);
            self.paintSortFeedback(cr, .{ .x = column.x, .y = @floatFromInt(self.viewTop()), .w = column.w, .h = @floatFromInt(viewport_h) });
        }

        if (self.error_message) |err| {
            setSource(cr, ui_theme.global.file_broken);
            drawText(cr, err, @floatFromInt(self.sidebarWidth() + 24), @floatFromInt(self.viewTop() + 36), shell_ui.textSize(), true);
        } else if (self.loading and self.items.items.len == 0) {
            // A quick listing never shows this; see `scan_notice_delay_ms`.
            if (self.scan_notice_shown) {
                setSource(cr, ui_theme.global.window_fg);
                drawText(cr, "Scanning folder...", @floatFromInt(self.sidebarWidth() + 24), @floatFromInt(self.viewTop() + 36), shell_ui.textSize(), false);
            }
        } else if (self.items.items.len == 0) {
            setSource(cr, ui_theme.global.window_fg);
            drawText(cr, if (self.search.text.items.len > 0 or self.folders_only) "No matching items" else if (self.changedOnly()) "No changed files" else if (self.isRecent()) "No recent files" else "This folder is empty", @floatFromInt(self.sidebarWidth() + 24), @floatFromInt(self.viewTop() + 36), shell_ui.textSize(), false);
        } else {
            self.renderFileItems(cr, viewport_h);
        }
        self.renderSelectionBand(cr);
        self.renderScrollEdges(cr, viewport_h);
        c.cairo_restore(cr);

        self.renderColumns(cr);

        // 4. Scrollbar
        self.renderScrollbar(cr);

        // 5. Status Bar
        if (self.chooser != null) self.renderChooser(cr) else self.renderStatusBar(cr, h_f);

        if (self.menu == null and self.dialog == null and self.selection_band == null) self.renderFilenameTip(cr);
        if (self.menu != null) self.renderMenu(cr);

        // 6. Modal Dialog
        if (self.dialog != null) {
            self.renderDialog(cr);
        }
    }

    fn renderButton(self: *App, cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, label_text: []const u8, enabled: bool) void {
        const hovered = enabled and self.mouse_x >= x and self.mouse_x <= x + w and self.mouse_y >= y and self.mouse_y <= y + h;
        var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(x), .y = @floatCast(y), .w = @floatCast(w), .h = @floatCast(h) }) orelse return;
        ui_button.paint(&layer.renderer, layer.local(), .{ .label = label_text }, .{ .pointer = if (!enabled) .disabled else if (hovered) .hover else .idle });
        layer.finish();
    }

    // The field's text size. Everything positioned against the text — the
    // caret, the select-all highlight — must be measured at this same size:
    // measuring at one size and drawing at another puts the caret a
    // proportion of the prefix width away from the glyph it belongs to, so
    // the error grows with every character typed.
    fn fieldFontSize() f64 {
        return shell_ui.textSize();
    }

    fn renderLocationBar(self: *App, cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
        if (!self.search_visible and self.focus != .location_bar) {
            _ = self.breadcrumbs(cr, null);
            return;
        }
        const is_focused = if (self.search_visible) self.focus == .search else self.focus == .location_bar;
        self.renderEditor(cr, if (self.search_visible) &self.search else &self.location, .{ .x = x, .y = y, .w = w, .h = h }, is_focused, self.search_visible);
    }

    /// The shared field look: the search box carries the search icon.
    fn fieldOptions(search: bool) ui_field.Options {
        return .{ .leading_icon = if (search) .search else null };
    }

    /// Where an editor's text runs inside its field.
    fn textArea(rect: header.Rect, search: bool) header.Rect {
        const area = ui_field.arrange(.{ .x = @floatCast(rect.x), .y = @floatCast(rect.y), .w = @floatCast(rect.w), .h = @floatCast(rect.h) }, fieldOptions(search), ui_theme.shellPalette()).text;
        return .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h };
    }

    /// The active editor's text area, for pointer hit testing.
    fn editorTextArea(self: *App) header.Rect {
        return textArea(self.editorRect(), self.dialog == null and self.focus == .search);
    }

    pub fn pointerCursor(self: *App, x: f64, y: f64) [*:0]const u8 {
        if (self.text_dragging) return "text";
        if (self.menu != null or self.selection_band != null or self.drag_origin != null or self.scroll_drag.active or self.sidebar_scroll_drag.active) return "default";
        if (self.dialog != null) {
            return if (self.activeEditor() != null and self.editorRect().contains(x, y)) "text" else "default";
        }
        if (self.column_resize != null or self.columnBoundary(x, y) != null) return "col-resize";
        if (self.chooser != null and self.chooserRect(0).contains(x, y)) return "text";
        if (self.focus != .location_bar and !self.search_visible and header.field(self.w).contains(x, y)) return "pointer";
        return if (header.field(self.w).contains(x, y)) "text" else "default";
    }

    /// The rename card, anchored to the item being renamed: the same inline
    /// popover the desktop uses (field plus confirm / cancel buttons), clamped
    /// to the file view.
    fn renameCard(self: *App) ?RenameCard {
        const dlg = self.dialog orelse return null;
        if (dlg.kind != .rename) return null;
        const left: f64 = @floatFromInt(self.sidebarWidth());
        const right: f64 = @floatFromInt(self.w);
        const top: f64 = @floatFromInt(self.viewTop());
        const bottom: f64 = @floatFromInt(self.h - self.footerHeight());
        const w = @min(340, right - left - 16);
        const h: f64 = 44;
        var x = left + 8;
        var y = top + 8;
        if (dlg.target_path) |target| for (self.items.items, 0..) |item, i| {
            if (!std.mem.eql(u8, item.path, target)) continue;
            const icon = self.itemIconRect(@intCast(i));
            if (self.list_view) {
                x = left + 8;
                y = icon.y + icon.h / 2 - h / 2;
            } else {
                x = icon.x + icon.w / 2 - w / 2;
                y = icon.y + 54;
            }
            break;
        };
        x = std.math.clamp(x, left + 4, @max(left + 4, right - w - 4));
        y = std.math.clamp(y, top + 4, @max(top + 4, bottom - h - 4));
        return .{
            .panel = .{ .x = x, .y = y, .w = w, .h = h },
            .field = .{ .x = x + 6, .y = y + 6, .w = w - 70, .h = 32 },
            .confirm = .{ .x = x + w - 62, .y = y + 6, .w = 28, .h = 32 },
            .cancel = .{ .x = x + w - 34, .y = y + 6, .w = 28, .h = 32 },
        };
    }

    fn renderRenameCard(self: *App, cr: *c.cairo_t, card: RenameCard) void {
        const p = card.panel;
        if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(p.x), .y = @floatCast(p.y), .w = @floatCast(p.w), .h = @floatCast(p.h) })) |begun| {
            var layer = begun;
            ui_dialog.paintFrameWithBackground(&layer.renderer, layer.local(), ui_theme.global.app_toolbar);
            layer.finish();
        }
        self.renderEditor(cr, &self.dialog.?.edit, card.field, true, false);
        for ([_]header.Rect{ card.confirm, card.cancel }, 0..) |rect, i| {
            var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(rect.x), .y = @floatCast(rect.y), .w = @floatCast(rect.w), .h = @floatCast(rect.h) }) orelse continue;
            ui_button.paint(&layer.renderer, layer.local(), .{
                .variant = .ghost,
                .icon = if (i == 0) .checkmark else .close,
                .icon_scale = 0.55,
                .label = if (i == 0) "Rename" else "Cancel",
            }, .{ .pointer = if (rect.contains(self.mouse_x, self.mouse_y)) .hover else .idle });
            layer.finish();
        }
    }

    fn editorRect(self: *App) header.Rect {
        if (self.renameCard()) |card| return card.field;
        if (self.dialog != null) {
            const dw: f64 = @min(440, @as(f64, @floatFromInt(self.w)) - 24);
            return .{ .x = (@as(f64, @floatFromInt(self.w)) - dw) / 2 + 16, .y = (@as(f64, @floatFromInt(self.h)) - 130) / 2 + 42, .w = dw - 32, .h = 30 };
        }
        if (self.focus == .filename and self.chooser != null) return self.chooserRect(0);
        return header.field(self.w);
    }

    fn placeCaret(self: *App, x: f64, extend: bool) void {
        const edit = self.activeEditor() orelse return;
        const surf = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1) orelse return;
        defer c.cairo_surface_destroy(surf);
        const cr = c.cairo_create(surf) orelse return;
        defer c.cairo_destroy(cr);
        // Measure at the buffer scale, as renderEditor does: hinting moves
        // advances per ppem.
        c.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));
        const rect = self.editorTextArea();
        if (self.text_dragging) edit.scroll = @max(0, edit.scroll + if (x < rect.x) @as(f64, -24) else if (x > rect.x + rect.w) @as(f64, 24) else @as(f64, 0));
        const target = x - rect.x + edit.scroll;
        var p: usize = 0;
        var previous: f64 = 0;
        while (p < edit.text.items.len) {
            const n = Editor.next(edit.text.items, p);
            const pen = measureText(cr, edit.text.items[0..n], fieldFontSize(), false);
            if (target < (previous + pen) / 2) break;
            previous = pen;
            p = n;
        }
        edit.move(p, extend);
    }

    /// A whole text field: the shared frame (ui/widgets/field.zig), then the
    /// editor's text, selection and caret in the theme's colours.
    fn renderEditor(self: *App, cr: *c.cairo_t, edit: *Editor, rect: header.Rect, focused: bool, search: bool) void {
        _ = self;
        if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(rect.x), .y = @floatCast(rect.y), .w = @floatCast(rect.w), .h = @floatCast(rect.h) })) |begun| {
            var layer = begun;
            _ = ui_field.paintFrame(&layer.renderer, layer.local(), fieldOptions(search), .{ .focused = focused });
            layer.finish();
        }
        const t = ui_theme.shellPalette();
        const area = textArea(rect, search);
        const text = edit.text.items;
        const sel = edit.selection();
        const metrics = fontMetrics(cr, fieldFontSize());
        const ink_h = metrics.ascent + metrics.descent;
        const top = area.y + (area.h - ink_h) / 2;
        const view_w = area.w;
        const text_w = measureText(cr, text, fieldFontSize(), false);
        const pen = measureText(cr, text[0..@min(edit.cursor, text.len)], fieldFontSize(), false);
        if (focused) {
            const margin = @min(view_w / 4, 12);
            if (pen - edit.scroll > view_w - margin) edit.scroll = pen - view_w + margin;
            if (pen - edit.scroll < margin) edit.scroll = pen - margin;
            edit.scroll = @round(std.math.clamp(edit.scroll, 0, @max(0, text_w - view_w + margin)));
        }
        const x = area.x - if (focused) edit.scroll else 0;
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        c.cairo_rectangle(cr, area.x, area.y + 2, view_w, area.h - 4);
        c.cairo_clip(cr);
        if (focused and sel[0] != sel[1]) {
            const left = measureText(cr, text[0..sel[0]], fieldFontSize(), false);
            const right = measureText(cr, text[0..sel[1]], fieldFontSize(), false);
            setSource(cr, t.selectionColor());
            c.cairo_rectangle(cr, x + left, top, right - left, ink_h);
            c.cairo_fill(cr);
        }
        const placeholder = search and text.len == 0;
        // Half-strength white, not the shell's blue-grey `faint`.
        setSource(cr, if (placeholder) withAlpha(t.fg, 0.5) else t.fg);
        drawText(cr, if (placeholder) "Search this folder" else text, x, top + metrics.ascent, fieldFontSize(), false);
        if (focused) {
            setSource(cr, t.caretColor());
            c.cairo_rectangle(cr, x + pen, top, t.caret_width, ink_h);
            c.cairo_fill(cr);
        }
    }

    fn renderFileItems(self: *App, cr: *c.cairo_t, viewport_h: i32) void {
        const accent = ui_theme.shellPalette().accent;
        const cols = self.columns();
        const cell = self.cellWidth();
        const first = @divTrunc(self.scroll_y, self.rowHeight()) * cols;
        const last = @min(@as(i32, @intCast(self.items.items.len)), (@divTrunc(self.scroll_y + viewport_h, self.rowHeight()) + 1) * cols);
        // The hover glide sits under every item, since mid-glide it straddles two.
        const glide = self.item_hover.frame;
        if (glide.alpha > 0) {
            const box = self.itemHighlight(glide);
            roundedRect(cr, box.x, box.y, box.w, box.h, 6);
            setSource(cr, withAlpha(ui_theme.global.app_item_hover, glide.alpha));
            c.cairo_fill_preserve(cr);
            setSource(cr, withAlpha(ui_theme.global.app_item_border, glide.alpha));
            c.cairo_set_line_width(cr, 1);
            c.cairo_stroke(cr);
        }
        var index = first;
        while (index < last) : (index += 1) {
            const idx: usize = @intCast(index);
            const item = self.items.items[idx];
            const baseline = self.listBaseline();
            const x: f64 = @floatFromInt(self.sidebarWidth() + 20 + @mod(index, cols) * cell);
            const y: f64 = @floatFromInt(self.viewTop() + self.itemInset() + @divTrunc(index, cols) * self.rowHeight() - self.scroll_y);
            const width: f64 = @floatFromInt(cell - 20);
            // Items sit on the list itself; only selection and keyboard focus
            // draw a card here (hover is the glide above).
            if (item.selection_fill.alpha > 0 or item.selection_border.alpha > 0) {
                roundedRect(cr, x, y, width, @floatFromInt(self.cardHeight()), 6);
                if (item.selection_fill.alpha > 0) {
                    setSource(cr, withAlpha(ui_theme.global.app_item_selected, item.selection_fill.alpha));
                    c.cairo_fill_preserve(cr);
                }
                setSource(cr, withAlpha(accent, item.selection_border.alpha));
                c.cairo_set_line_width(cr, 1);
                c.cairo_stroke(cr);
            }
            if (self.folder_drop == idx) {
                roundedRect(cr, x, y, width, @floatFromInt(self.cardHeight()), 6);
                setSource(cr, accent);
                c.cairo_set_line_width(cr, 2);
                c.cairo_stroke(cr);
            }
            var cut = false;
            if (self.clipboard_cut) {
                for (self.clipboard_paths.items) |path| {
                    if (std.mem.eql(u8, path, item.path)) {
                        cut = true;
                        break;
                    }
                }
            }
            if (cut) c.cairo_push_group(cr);
            const icon = self.itemIconRect(index);
            self.drawItemIcon(cr, item, icon.x, icon.y, icon.w);
            const label_x = x + (if (self.list_view) @as(f64, 42) else 26);
            setSource(cr, ui_theme.global.window_fg);
            const name_width = if (self.list_view) self.listColumn(0).w - 46 else width - 42;
            // A path that does not fit loses its head, so the file's own name stays readable.
            const name_y = y + (if (self.list_view) baseline else 94);
            if (item.label.len > 0) drawHeadEllipsis(cr, item.label, label_x, name_y, name_width, shell_ui.textSize(), false) else drawEllipsis(cr, item.name, label_x, name_y, name_width, shell_ui.textSize(), false);
            var buf: [64]u8 = undefined;
            var size_buf: [64]u8 = undefined;
            const disp = self.itemSizeDisplay(item, &size_buf);
            const is_size_hovered = (self.hoverKey() == 2_000_000 + idx);
            if (self.list_view and self.repository() != null) {
                self.renderGitStatus(cr, item, y);
            } else if (self.list_view) {
                const sz = self.listColumn(1);
                if (disp.is_running) {
                    const text_w = @max(0.0, sz.w - 24);
                    setSource(cr, ui_theme.global.window_fg);
                    drawEllipsis(cr, disp.text, sz.x + 4, y + baseline, text_w, shell_ui.textSize(), false);
                    drawSpinner(cr, sz.x + sz.w - 10, y + baseline - 4, 4.5);
                } else if (item.is_dir and !item.is_symlink and is_size_hovered and std.mem.eql(u8, disp.text, "—")) {
                    roundedRect(cr, sz.x + 2, y + baseline - 14, 24, 18, 4);
                    setSource(cr, ui_theme.global.surface_hover);
                    c.cairo_fill(cr);
                    setSource(cr, ui_theme.global.window_fg);
                    drawEllipsis(cr, "—", sz.x + 8, y + baseline, sz.w - 12, shell_ui.textSize(), false);
                } else {
                    setSource(cr, ui_theme.global.window_fg);
                    drawEllipsis(cr, disp.text, sz.x + 4, y + baseline, sz.w - 8, shell_ui.textSize(), false);
                }
                setSource(cr, ui_theme.global.window_fg);
                const ty = self.listColumn(2);
                drawEllipsis(cr, itemType(item), ty.x + 4, y + baseline, ty.w - 8, shell_ui.textSize(), false);
                const mt = self.listColumn(3);
                const timestamp = @import("settings.zig").dateTime(if (self.isRecent()) item.opened else item.mtime, &buf);
                drawEllipsis(cr, timestamp, mt.x + 4, y + baseline, mt.w - 8, shell_ui.textSize(), false);
                const permissions = self.listColumn(4);
                const mode = formatPermissions(item.mode);
                drawEllipsis(cr, if (item.permissions_text.len > 0) item.permissions_text else &mode, permissions.x + 4, y + baseline, permissions.w - 8, shell_ui.textSize(), false);
            } else {
                if (item.is_symlink) {
                    setSource(cr, ui_theme.global.window_fg);
                    drawText(cr, itemType(item), x + 26, y + 117, shell_ui.textSize(), false);
                } else if (item.is_dir) {
                    if (disp.is_running) {
                        setSource(cr, ui_theme.global.window_fg);
                        drawText(cr, disp.text, x + 26, y + 117, shell_ui.textSize(), false);
                        const tw = measureText(cr, disp.text, shell_ui.textSize(), false);
                        drawSpinner(cr, x + 26 + tw + 10, y + 117 - 4, 4.5);
                    } else if (is_size_hovered and std.mem.eql(u8, disp.text, "—")) {
                        roundedRect(cr, x + 22, y + 117 - 14, 24, 18, 4);
                        setSource(cr, ui_theme.global.surface_hover);
                        c.cairo_fill(cr);
                        setSource(cr, ui_theme.global.window_fg);
                        drawText(cr, "—", x + 28, y + 117, shell_ui.textSize(), false);
                    } else {
                        setSource(cr, ui_theme.global.window_fg);
                        drawText(cr, disp.text, x + 26, y + 117, shell_ui.textSize(), false);
                    }
                } else {
                    setSource(cr, ui_theme.global.window_fg);
                    drawText(cr, formatSize(item.bytes, &buf), x + 26, y + 117, shell_ui.textSize(), false);
                }
            }
            if (cut) {
                c.cairo_pop_group_to_source(cr);
                c.cairo_paint_with_alpha(cr, 0.45);
            }
        }
    }

    fn renderFilenameTip(self: *App, cr: *c.cairo_t) void {
        const index = self.itemAt(self.mouse_x, self.mouse_y) orelse return;
        const name = self.items.items[index].text();
        const available: f64 = if (self.list_view) self.listColumn(0).w - 46 else @as(f64, @floatFromInt(self.cellWidth() - 62));
        if (measureText(cr, name, shell_ui.textSize(), false) <= available) return;
        const width = @min(@as(f64, @floatFromInt(self.w - 24)), @max(180, measureText(cr, name, shell_ui.textSize(), false) + 20));
        var lines: [32][]const u8 = undefined;
        var count: usize = 0;
        var start: usize = 0;
        while (start < name.len and count < lines.len) {
            var end = Editor.next(name, start);
            while (end < name.len) {
                const next = Editor.next(name, end);
                if (measureText(cr, name[start..next], shell_ui.textSize(), false) > width - 20) break;
                end = next;
            }
            lines[count] = name[start..end];
            count += 1;
            start = end;
        }
        const height: f64 = @floatFromInt(count * 17 + 10);
        // Anchor to the item, so motion within it does not require a repaint.
        const row = @divTrunc(@as(i32, @intCast(index)), self.columns());
        const y = std.math.clamp(@as(f64, @floatFromInt(self.viewTop() + self.itemInset() + row * self.rowHeight() - self.scroll_y + self.cardHeight())), 4, @max(4, @as(f64, @floatFromInt(self.h - self.footerHeight())) - height));
        const x: f64 = @floatFromInt(@min(self.sidebarWidth() + 20, self.w - @as(i32, @intFromFloat(width)) - 12));
        roundedRect(cr, x, y, width, height, 4);
        setSource(cr, ui_theme.global.app_divider);
        c.cairo_fill(cr);
        setSource(cr, ui_theme.global.window_fg);
        for (lines[0..count], 0..) |line, i| drawText(cr, line, x + 10, y + 17 + @as(f64, @floatFromInt(i * 17)), shell_ui.textSize(), false);
    }

    /// Where an item's icon (or thumbnail) is drawn, in window coordinates.
    fn itemIconRect(self: *App, index: i32) header.Rect {
        const cols = self.columns();
        const size: f64 = if (self.list_view) 24 else 48;
        return .{
            .x = @as(f64, @floatFromInt(self.sidebarWidth() + 20 + @mod(index, cols) * self.cellWidth())) + (if (self.list_view) @as(f64, 12) else 26),
            .y = @as(f64, @floatFromInt(self.viewTop() + self.itemInset() + @divTrunc(index, cols) * self.rowHeight() - self.scroll_y)) + (if (self.compactList()) @as(f64, 3) else if (self.list_view) @as(f64, 6) else 20),
            .w = size,
            .h = size,
        };
    }

    /// Files that show a picture of themselves instead of a type icon.
    fn thumbnailable(item: ViewItem) bool {
        return !item.is_dir and !item.is_broken and image_formats.candidate(item.name);
    }

    fn thumbService(self: *App) ?*thumbs_mod.Service {
        if (!self.thumbs_enabled) return null;
        if (self.thumbs) |service| return service;
        const cache_dir = thumb_decode.cacheDir(self.allocator, self.environ);
        defer if (cache_dir) |dir| self.allocator.free(dir);
        self.thumbs = thumbs_mod.Service.create(cache_dir) catch {
            self.thumbs_enabled = false;
            return null;
        };
        return self.thumbs;
    }

    /// Readable when finished thumbnails wait in `drainThumbs`; -1 before any.
    pub fn thumbWakeFd(self: *const App) c_int {
        return if (self.thumbs) |service| service.wakeFd() else -1;
    }

    fn collectThumbRow(self: *App, row: i32, cols: i32) void {
        const limit = 192;
        var col: i32 = 0;
        while (col < cols and self.thumb_wants.items.len < limit) : (col += 1) {
            const index = row * cols + col;
            if (index >= self.items.items.len) return;
            const item = self.items.items[@intCast(index)];
            if (!thumbnailable(item)) continue;
            self.thumb_wants.append(self.allocator, .{ .path = item.path, .mtime = item.mtime, .bytes = item.bytes, .is_symlink = item.is_symlink }) catch return;
        }
    }

    /// Asks for thumbnails of the visible files, then of a screenful on each
    /// side, whenever the visible rows or the listing change. Cheap otherwise:
    /// one comparison per loop.
    pub fn stepThumbs(self: *App) void {
        if (self.history.archive_len > 0) return;
        if (!self.thumbs_enabled) return;
        const cols = self.columns();
        const row_h = self.rowHeight();
        const viewport_h = @max(0, self.h - self.viewTop() - self.footerHeight());
        const row0 = @divTrunc(self.scroll_y, row_h);
        const row1 = @divTrunc(self.scroll_y + viewport_h, row_h);
        const request: ThumbRequest = .{ .revision = self.view_revision, .row0 = row0, .row1 = row1, .cols = cols };
        if (std.meta.eql(request, self.thumb_request)) return;
        self.thumb_request = request;

        self.thumb_wants.clearRetainingCapacity();
        const margin = row1 - row0 + 1;
        var row = row0;
        while (row <= row1 + margin) : (row += 1) self.collectThumbRow(row, cols);
        row = row0 - 1;
        while (row >= @max(0, row0 - margin)) : (row -= 1) self.collectThumbRow(row, cols);
        // Nothing to show and no service to tell: do not start the workers.
        if (self.thumb_wants.items.len == 0 and self.thumbs == null) return;
        const service = self.thumbService() orelse return;
        service.request(self.thumb_wants.items);
    }

    /// Takes finished thumbnails and repaints only the icons they fill.
    pub fn drainThumbs(self: *App) void {
        const service = self.thumbs orelse return;
        self.thumb_arrived.clearRetainingCapacity();
        service.drain(&self.thumb_arrived);
        if (self.thumb_arrived.items.len == 0) return;
        const cols = self.columns();
        const row_h = self.rowHeight();
        const viewport_h = @max(0, self.h - self.viewTop() - self.footerHeight());
        const first = @divTrunc(self.scroll_y, row_h) * cols;
        const last = @min(@as(i32, @intCast(self.items.items.len)), (@divTrunc(self.scroll_y + viewport_h, row_h) + 1) * cols);
        var index = first;
        while (index < last) : (index += 1) {
            const item = self.items.items[@intCast(index)];
            if (!thumbnailable(item)) continue;
            const hash = thumbs_mod.pathHash(item.path);
            if (std.mem.indexOfScalar(u64, self.thumb_arrived.items, hash) == null) continue;
            var rect = self.itemIconRect(index);
            rect.x -= 1;
            rect.y -= 1;
            rect.w += 2;
            rect.h += 2;
            self.addDamage(self.clipToViewport(rect));
        }
    }

    fn drawThumb(cr: *c.cairo_t, thumb: thumbs_mod.Thumb, x: f64, y: f64, size: f64) void {
        const tw: f64 = @floatFromInt(thumb.w);
        const th: f64 = @floatFromInt(thumb.h);
        const fit = size / @max(tw, th);
        const w = @max(1, @round(tw * fit));
        const h = @max(1, @round(th * fit));
        const ox = x + @floor((size - w) / 2);
        const oy = y + @floor((size - h) / 2);
        const surface = c.cairo_image_surface_create_for_data(
            @ptrCast(@constCast(thumb.pixels.ptr)),
            c.CAIRO_FORMAT_ARGB32,
            thumb.w,
            thumb.h,
            thumb.w * 4,
        ) orelse return;
        defer c.cairo_surface_destroy(surface);
        c.cairo_save(cr);
        roundedRect(cr, ox, oy, w, h, 3);
        c.cairo_clip(cr);
        c.cairo_translate(cr, ox, oy);
        c.cairo_scale(cr, w / tw, h / th);
        c.cairo_set_source_surface(cr, surface, 0, 0);
        const pattern = c.cairo_get_source(cr);
        c.cairo_pattern_set_filter(pattern, c.CAIRO_FILTER_GOOD);
        c.cairo_pattern_set_extend(pattern, c.CAIRO_EXTEND_PAD);
        c.cairo_paint(cr);
        c.cairo_restore(cr);
        // A hairline keeps pale pictures from dissolving into the list.
        roundedRect(cr, ox + 0.5, oy + 0.5, w - 1, h - 1, 2.5);
        setSource(cr, ui_theme.global.app_item_border);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
    }

    fn itemIcon(self: *App, item: ViewItem, raster_size: i32) ?icons.Entry {
        for (item.icon_candidates) |name| {
            if (icons.get(self.theme_cfg, self.io, name, raster_size)) |entry| return entry;
        }
        return icons.get(self.theme_cfg, self.io, item.icon_name, raster_size);
    }

    pub fn drawItemIcon(self: *App, cr: *c.cairo_t, item: ViewItem, x: f64, y: f64, size: f64) void {
        if (self.thumbs) |service| {
            if (thumbnailable(item)) {
                if (service.lookup(item.path, item.mtime, item.bytes)) |thumb| {
                    drawThumb(cr, thumb, x, y, size);
                    if (item.is_symlink) {
                        c.cairo_save(cr);
                        defer c.cairo_restore(cr);
                        c.cairo_translate(cr, x, y);
                        self.drawSymlinkEmblem(cr, size);
                    }
                    return;
                }
            }
        }
        const raster_size = @as(i32, @intFromFloat(size)) * self.scale;
        const maybe_icon = if (item.is_dir) null else self.itemIcon(item, raster_size);

        if (maybe_icon) |entry| {
            const surf = c.cairo_image_surface_create_for_data(
                @ptrCast(@constCast(entry.pixels.ptr)),
                c.CAIRO_FORMAT_ARGB32,
                entry.size,
                entry.size,
                entry.size * 4,
            );
            if (surf != null) {
                defer c.cairo_surface_destroy(surf);
                c.cairo_save(cr);
                defer c.cairo_restore(cr);
                c.cairo_translate(cr, x, y);
                const s = size / @as(f64, @floatFromInt(entry.size));
                c.cairo_scale(cr, s, s);
                c.cairo_set_source_surface(cr, surf, 0, 0);
                c.cairo_paint(cr);
                if (item.is_symlink) self.drawSymlinkEmblem(cr, size);
                return;
            }
        }

        // Fallback vector icon
        if (item.is_broken) {
            setSource(cr, ui_theme.global.file_broken);
            roundedRect(cr, x + 2, y + 2, size - 4, size - 4, 4);
            c.cairo_fill(cr);
            setSource(cr, ui_theme.global.window_fg);
            drawText(cr, "!", x + 10, y + 17, 14, true);
        } else if (item.is_dir) {
            // Folder icon
            setSource(cr, ui_theme.global.file_folder_back);
            roundedRect(cr, x + 2, y + size * 0.1, size * 0.42, size * 0.25, size * 0.0625);
            c.cairo_fill(cr);
            setSource(cr, ui_theme.global.file_folder_front);
            roundedRect(cr, x + 2, y + size * 0.29, size - 4, size * 0.625, size * 0.0625);
            c.cairo_fill(cr);
        } else {
            // Document icon
            setSource(cr, ui_theme.global.file_document);
            roundedRect(cr, x + 4, y + 2, size - 8, size - 4, 2);
            c.cairo_fill(cr);
            setSource(cr, ui_theme.global.file_document_lines);
            c.cairo_rectangle(cr, x + 7, y + 8, size - 14, 2);
            c.cairo_rectangle(cr, x + 7, y + 13, size - 14, 2);
            c.cairo_rectangle(cr, x + 7, y + 18, size - 18, 2);
            c.cairo_fill(cr);
        }

        if (item.is_symlink) {
            c.cairo_save(cr);
            defer c.cairo_restore(cr);
            c.cairo_translate(cr, x, y);
            self.drawSymlinkEmblem(cr, size);
        }
    }

    fn drawSymlinkEmblem(_: *App, cr: *c.cairo_t, size: f64) void {
        const lx = size - 9;
        const ly = size - 9;
        const bg = ui_theme.global.app_bg;
        setSource(cr, .{ bg[0], bg[1], bg[2], 0.85 });
        c.cairo_arc(cr, lx + 4, ly + 4, 5, 0, 2 * std.math.pi);
        c.cairo_fill(cr);

        setSource(cr, ui_theme.shellPalette().accent);
        c.cairo_set_line_width(cr, 1.2);
        c.cairo_move_to(cr, lx + 2, ly + 6);
        c.cairo_line_to(cr, lx + 6, ly + 2);
        c.cairo_move_to(cr, lx + 3, ly + 2);
        c.cairo_line_to(cr, lx + 6, ly + 2);
        c.cairo_line_to(cr, lx + 6, ly + 5);
        c.cairo_stroke(cr);
    }

    pub fn stepScrollbar(self: *App, now: i64) void {
        const bar = self.scrollbarGeometry();
        const idle = self.menu == null and self.dialog == null;
        const hovered = if (bar) |b| idle and b.overThumb(@floatCast(self.mouse_x), @floatCast(self.mouse_y)) else false;
        if (self.scroll_appearance.step(now, self.scroll_y != self.scroll_observed, hovered, self.scroll_drag.active, bar != null)) {
            const viewport: f64 = @floatFromInt(@max(0, self.h - self.viewTop() - self.footerHeight()));
            self.addDamage(.{ .x = @floatFromInt(self.w - self.scrollbarGutter()), .y = @floatFromInt(self.viewTop()), .w = @floatFromInt(self.scrollbarGutter()), .h = viewport });
        }
        self.scroll_observed = self.scroll_y;
        const side = self.sidebarScrollbar();
        const side_hovered = if (side) |b| idle and b.overThumb(@floatCast(self.mouse_x), @floatCast(self.mouse_y)) else false;
        if (self.sidebar_scroll_appearance.step(now, self.sidebar_scroll != self.sidebar_scroll_observed, side_hovered, self.sidebar_scroll_drag.active, side != null)) {
            if (side) |b| self.addDamage(.{ .x = b.track.x, .y = b.track.y, .w = b.track.w, .h = b.track.h });
        }
        self.sidebar_scroll_observed = self.sidebar_scroll;
    }

    fn renderScrollEdges(self: *App, cr: *c.cairo_t, viewport_h: i32) void {
        if (viewport_h <= 0 or self.maxScroll() == 0) return;
        const depth: f64 = @min(12, @as(f64, @floatFromInt(viewport_h)) / 2);
        for ([_]bool{ true, false }) |top| {
            if (if (top) self.scroll_y <= 0 else self.scroll_y >= self.maxScroll()) continue;
            const edge: f64 = @floatFromInt(if (top) self.viewTop() else self.h - self.footerHeight());
            const inner = edge + if (top) depth else -depth;
            const gradient = c.cairo_pattern_create_linear(0, edge, 0, inner) orelse continue;
            defer c.cairo_pattern_destroy(gradient);
            c.cairo_pattern_add_color_stop_rgba(gradient, 0, 0, 0, 0, 0.16);
            c.cairo_pattern_add_color_stop_rgba(gradient, 1, 0, 0, 0, 0);
            c.cairo_set_source(cr, gradient);
            c.cairo_rectangle(cr, @floatFromInt(self.sidebarWidth()), @min(edge, inner), @floatFromInt(@max(0, self.w - self.sidebarWidth() - self.scrollbarGutter())), depth);
            c.cairo_fill(cr);
        }
    }

    fn renderScrollbar(self: *App, cr: *c.cairo_t) void {
        const bar = self.scrollbarGeometry() orelse return;
        shell_ui.drawScrollbar(cr, scrollbar.look(bar, self.scroll_appearance, self.scrollbar_width, ui_theme.shellPalette()));
    }

    fn renderStatusBar(self: *App, cr: *c.cairo_t, h_f: f64) void {
        const w_f = @as(f64, @floatFromInt(self.w));
        const y = h_f - 26;

        const accent = ui_theme.shellPalette().accent;
        setSource(cr, ui_theme.global.app_bar);
        c.cairo_rectangle(cr, 0, y, w_f, 26);
        c.cairo_fill(cr);

        setSource(cr, ui_theme.global.app_divider);
        c.cairo_set_line_width(cr, 1);
        c.cairo_move_to(cr, 0, y + 0.5);
        c.cairo_line_to(cr, w_f, y + 0.5);
        c.cairo_stroke(cr);

        var status_buf: [256]u8 = undefined;
        var status_text: []const u8 = "";

        var prog: ?ops_mod.ProgressInfo = null;
        if (self.job_runner) |runner| {
            const p = runner.pollProgress();
            if (p.state == .running or p.state == .waiting_conflict) {
                prog = p;
            }
        }

        if (prog) |p| {
            setSource(cr, accent);
            status_text = std.fmt.bufPrint(
                &status_buf,
                "{s} {d}/{d}: {s}... (Esc to cancel)",
                .{ if (self.job_runner.?.kind == .extract or self.job_runner.?.kind == .open_archive_member) @as([]const u8, "Extracting") else "Transferring", p.processed_items + 1, p.total_items, p.current_name },
            ) catch "Transferring...";
        } else if (self.status_notice != null and nowMs() < self.status_notice_until) {
            if (self.status_is_error) {
                setSource(cr, ui_theme.global.danger);
            } else {
                setSource(cr, accent);
            }
            status_text = self.status_notice.?;
        } else if (self.error_message) |err| {
            setSource(cr, ui_theme.global.danger);
            status_text = std.fmt.bufPrint(&status_buf, "Error: {s}", .{err}) catch err;
        } else {
            setSource(cr, ui_theme.global.window_fg);
            var sel_count: usize = 0;
            var sel_bytes: i64 = 0;
            for (self.items.items) |it| {
                if (it.selected and !it.missing) {
                    sel_count += 1;
                    if (!it.is_dir) sel_bytes += it.bytes;
                }
            }

            if (sel_count > 0) {
                var size_buf: [64]u8 = undefined;
                const sz = formatSize(sel_bytes, &size_buf);
                status_text = std.fmt.bufPrint(
                    &status_buf,
                    "{d} item{s} selected  ·  {s}",
                    .{ sel_count, if (sel_count == 1) "" else "s", sz },
                ) catch "Selected items";
            } else {
                const more = if (self.changedOnly() and self.snapshot != null and self.snapshot.?.changed_truncated) "+" else "";
                status_text = std.fmt.bufPrint(
                    &status_buf,
                    "{d}{s} item{s}",
                    .{ self.items.items.len, more, if (self.items.items.len == 1 and more.len == 0) "" else "s" },
                ) catch "Items";
            }
        }

        drawText(cr, status_text, 14, y + 17, shell_ui.statusSize(), false);
    }

    fn renderDialog(self: *App, cr: *c.cairo_t) void {
        const dlg = self.dialog orelse return;
        if (dlg.kind == .properties) {
            self.dialog.?.properties.?.draw(cr, self.w, self.h, self.mouse_x, self.mouse_y, self.theme_cfg, self.io);
            return;
        }
        if (dlg.kind == .open_with) {
            self.dialog.?.applications.?.draw(cr, self.w, self.h, self.mouse_x, self.mouse_y, self.theme_cfg, self.io);
            return;
        }
        if (dlg.kind == .trash_confirm) {
            dlg.deletion.draw(cr, self.w, self.h, self.mouse_x, self.mouse_y, ui_theme.global.app_toolbar);
            return;
        }
        if (self.renameCard()) |card| {
            self.renderRenameCard(cr, card);
            return;
        }
        const w_f = @as(f64, @floatFromInt(self.w));
        const h_f = @as(f64, @floatFromInt(self.h));

        // Dim backdrop
        @import("ui").cairo.setSource(cr, ui_dialog.backdropColor());
        c.cairo_rectangle(cr, 0, 0, w_f, h_f);
        c.cairo_fill(cr);

        // Modal box
        const dw: f64 = @min(440, @as(f64, @floatFromInt(self.w)) - 24);
        const dh: f64 = 130;
        const dx = (w_f - dw) / 2.0;
        const dy = (h_f - dh) / 2.0;

        if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(dx), .y = @floatCast(dy), .w = @floatCast(dw), .h = @floatCast(dh) })) |begun| {
            var layer = begun;
            ui_dialog.paintFrameWithBackground(&layer.renderer, layer.local(), ui_theme.global.app_toolbar);
            layer.finish();
        }
        const t = ui_theme.shellPalette();

        // Title
        setSource(cr, t.fg);
        drawText(cr, dlg.title, dx + 16, dy + 26, shell_ui.textSize(), true);

        var buf: [256]u8 = undefined;

        if (dlg.kind == .conflict) {
            const conflict_str = dlg.conflict_name orelse "";
            const conflict_msg = std.fmt.bufPrint(&buf, "File '{s}' already exists in destination.", .{conflict_str}) catch "Conflict";
            setSource(cr, t.fg);
            drawEllipsis(cr, conflict_msg, dx + 16, dy + 56, dw - 32, shell_ui.textSize(), false);

            self.renderButton(cr, dx + 16, dy + 84, (dw - 48) / 3, 28, "Skip (S)", true);
            self.renderButton(cr, dx + 24 + (dw - 48) / 3, dy + 84, (dw - 48) / 3, 28, "Rename (R)", true);
            self.renderButton(cr, dx + 32 + 2 * (dw - 48) / 3, dy + 84, (dw - 48) / 3, 28, "Cancel (C)", true);
        } else {
            self.renderEditor(cr, &self.dialog.?.edit, self.editorRect(), true, false);

            setSource(cr, t.fg);
            if (dw >= 420) drawText(cr, "Enter confirms · Esc cancels", dx + 16, dy + 102, shell_ui.textSize(), false);

            self.renderButton(cr, dx + dw - 184, dy + 84, 80, 28, "OK", true);
            self.renderButton(cr, dx + dw - 96, dy + 84, 80, 28, "Cancel", true);
        }
    }
};

pub fn formatSize(bytes: i64, buf: []u8) []const u8 {
    if (bytes < 0) return "—";
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "—";
    }
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kb < 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch "—";
    }
    const mb = kb / 1024.0;
    if (mb < 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "—";
    }
    const gb = mb / 1024.0;
    if (gb < 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} GB", .{gb}) catch "—";
    }
    const tb = gb / 1024.0;
    return std.fmt.bufPrint(buf, "{d:.1} TB", .{tb}) catch "—";
}

pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
}

pub fn setSource(cr: *c.cairo_t, color: [4]f32) void {
    c.cairo_set_source_rgba(cr, color[0], color[1], color[2], color[3]);
}

/// A straight-alpha theme colour at `alpha` of its own opacity.
fn withAlpha(color: [4]f32, alpha: f32) [4]f32 {
    return .{ color[0], color[1], color[2], color[3] * alpha };
}

pub fn roundedRect(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + w - r, y + r, r, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, x + w - r, y + h - r, r, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, x + r, y + h - r, r, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, x + r, y + r, r, std.math.pi, 3 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}

pub fn drawSpinner(cr: *c.cairo_t, cx: f64, cy: f64, r: f64) void {
    const angle = @as(f64, @floatFromInt(@mod(nowMs(), 1000))) / 1000.0 * 2.0 * std.math.pi;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    setSource(cr, ui_theme.global.file_spinner);
    c.cairo_set_line_width(cr, 1.5);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_arc(cr, cx, cy, r, angle, angle + 1.5 * std.math.pi);
    c.cairo_stroke(cr);
}

/// A damage scissor must cover whole device pixels. Fractional clip edges
/// blend a second copy of the background over retained pixels and leave seams.
pub fn clipDamage(cr: *c.cairo_t, rect: header.Rect) void {
    var x1 = rect.x;
    var y1 = rect.y;
    var x2 = rect.x + rect.w;
    var y2 = rect.y + rect.h;
    c.cairo_user_to_device(cr, &x1, &y1);
    c.cairo_user_to_device(cr, &x2, &y2);
    var matrix: c.cairo_matrix_t = undefined;
    c.cairo_get_matrix(cr, &matrix);
    c.cairo_identity_matrix(cr);
    c.cairo_rectangle(cr, @floor(x1), @floor(y1), @ceil(x2) - @floor(x1), @ceil(y2) - @floor(y1));
    c.cairo_clip(cr);
    c.cairo_set_matrix(cr, &matrix);
}

/// Like `drawEllipsis`, but keeps the end of `text`: "…/dir/file.zig".
fn drawHeadEllipsis(cr: *c.cairo_t, text: []const u8, x: f64, y: f64, width: f64, size: f64, bold: bool) void {
    if (width <= 0) return;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, x, y - size * 1.5, width, size * 2);
    c.cairo_clip(cr);
    if (measureText(cr, text, size, bold) <= width) return drawText(cr, text, x, y, size, bold);
    const dots = measureText(cr, "…", size, bold);
    var start: usize = 0;
    while (start < text.len and measureText(cr, text[start..], size, bold) + dots > width) start = Editor.next(text, start);
    drawText(cr, "…", x, y, size, bold);
    drawText(cr, text[start..], x + dots, y, size, bold);
}

pub fn drawEllipsis(cr: *c.cairo_t, text: []const u8, x: f64, y: f64, width: f64, size: f64, bold: bool) void {
    if (width <= 0) return;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, x, y - size * 1.5, width, size * 2);
    c.cairo_clip(cr);
    if (measureText(cr, text, size, bold) <= width) return drawText(cr, text, x, y, size, bold);
    const dots = measureText(cr, "…", size, bold);
    var end = text.len;
    while (end > 0 and measureText(cr, text[0..end], size, bold) + dots > width) end = Editor.prev(text, end);
    drawText(cr, text[0..end], x, y, size, bold);
    drawText(cr, "…", x + measureText(cr, text[0..end], size, bold), y, size, bold);
}

// Text goes through the shell's renderer (text.zig, Manrope), not Cairo's
// toy font API, so Files reads like the rest of the desktop.
pub fn drawText(cr: *c.cairo_t, str: []const u8, x: f64, y: f64, size: f64, bold: bool) void {
    shell_ui.drawText(cr, str, x, y, size, bold);
}

/// The face's own vertical extent at a size, both positive and measured from
/// the baseline. Anything that has to align with drawn text — a caret, a
/// selection highlight — has to come from these; a hand-tuned pixel offset
/// only happens to be right for one font at one size.
pub const FontMetrics = shell_ui.FontMetrics;

pub fn fontMetrics(cr: *c.cairo_t, size: f64) FontMetrics {
    return shell_ui.fontMetrics(cr, size);
}

pub fn measureText(cr: *c.cairo_t, str: []const u8, size: f64, bold: bool) f64 {
    return shell_ui.measureText(cr, str, size, bold);
}

fn formatPermissions(mode: c.mode_t) [10]u8 {
    var result = "----------".*;
    result[0] = switch (mode & c.S_IFMT) {
        c.S_IFDIR => 'd',
        c.S_IFLNK => 'l',
        c.S_IFCHR => 'c',
        c.S_IFBLK => 'b',
        c.S_IFIFO => 'p',
        c.S_IFSOCK => 's',
        c.S_IFREG => '-',
        else => '?',
    };
    for (0..9) |i| {
        const bit = @as(c.mode_t, 0o400) >> @as(u5, @intCast(i));
        if (mode & bit != 0) result[i + 1] = "rwx"[i % 3];
    }
    if (mode & c.S_ISUID != 0) result[3] = if (mode & c.S_IXUSR != 0) 's' else 'S';
    if (mode & c.S_ISGID != 0) result[6] = if (mode & c.S_IXGRP != 0) 's' else 'S';
    if (mode & c.S_ISVTX != 0) result[9] = if (mode & c.S_IXOTH != 0) 't' else 'T';
    return result;
}

test "grid hit testing respects gutters, scrolling and responsive columns" {
    var app = App{
        .allocator = std.testing.allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = std.testing.allocator, .current = "/" },
        .home_dir = "/",
        .items_arena = undefined,
    };
    app.w = 960;
    app.h = 640;
    app.list_view = false;
    app.scroll_y = 0;
    var items: [20]ViewItem = undefined;
    app.items = .{ .items = &items, .capacity = items.len };
    try std.testing.expectEqual(@as(i32, 3), app.columns());
    try std.testing.expectEqual(@as(?usize, 0), app.itemAt(250, 158));
    try std.testing.expectEqual(@as(?usize, 1), app.itemAt(490, 158));
    try std.testing.expectEqual(@as(?usize, 3), app.itemAt(250, 308));
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(220, 158));
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(450, 158));
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(250, 273));
    app.scroll_y = 156;
    try std.testing.expectEqual(@as(?usize, 3), app.itemAt(250, 158));
    app.revealIndex(19);
    try std.testing.expect(app.scroll_y > 156);
    app.resize(360, 240);
    try std.testing.expectEqual(@as(i32, 0), app.sidebarWidth());
    try std.testing.expectEqual(@as(i32, 1), app.columns());
    app.scroll_y = 0;
    try std.testing.expectEqual(@as(?usize, 0), app.itemAt(30, 180));
}

test "search and sorting preserve visible selection across snapshot rebuilds" {
    const allocator = std.testing.allocator;
    var source = [_]worker_mod.Item{
        .{ .name = "zeta.txt", .path = "/zeta.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 200, .mtime = 1, .icon_name = "" },
        .{ .name = "alpha.txt", .path = "/alpha.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 2, .icon_name = "" },
        .{ .name = "Documents", .path = "/Documents", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 3, .icon_name = "" },
    };
    var snap = worker_mod.Snapshot{ .arena = undefined, .request_id = 1, .dir = "/", .items = &source };
    var app = App{
        .allocator = allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = std.testing.allocator, .current = "/" },
        .home_dir = "/",
        .items_arena = std.heap.ArenaAllocator.init(allocator),
        .snapshot = &snap,
        .folder_sizes = std.StringHashMap(SizeState).init(allocator),
    };
    defer app.folder_sizes.deinit();
    defer app.items_arena.deinit();
    defer app.items.deinit(allocator);
    defer app.search.text.deinit(allocator);
    app.rebuildView();
    try std.testing.expectEqualStrings("Documents", app.items.items[0].name);
    app.items.items[1].selected = true;
    app.focused_index = 1;
    app.selection_anchor = 1;
    app.sort_mode = .size;
    app.rebuildView();
    try std.testing.expectEqualStrings("zeta.txt", app.items.items[1].name);
    try std.testing.expectEqual(@as(?usize, 2), app.focused_index);
    try std.testing.expect(app.items.items[2].selected);
    try app.search.text.appendSlice(allocator, "ALPHA");
    app.rebuildView();
    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);
    try std.testing.expect(app.items.items[0].selected);
    app.folders_only = true;
    app.rebuildView();
    try std.testing.expectEqual(@as(usize, 0), app.items.items.len);
    try std.testing.expectEqual(@as(?usize, null), app.focused_index);
    app.search.text.clearRetainingCapacity();
    app.rebuildView();
    try std.testing.expectEqualStrings("Documents", app.items.items[0].name);
}

test "context menu stays inside the client and keyboard activation closes it" {
    var app = App{
        .allocator = std.testing.allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = std.testing.allocator, .current = "/" },
        .home_dir = "/",
        .items_arena = undefined,
    };
    app.w = 360;
    for ([_]i32{ 240, 600 }) |height| {
        app.h = height;
        for ([_]MenuKind{ .file, .background }) |kind| {
            app.openMenu(kind, 359, @floatFromInt(height - 1));
            try std.testing.expect(app.menu_x >= 0 and app.menu_x + app.menuWidth() <= 360);
            try std.testing.expect(app.menu_y >= 0 and app.menu_y + app.menuHeight() <= @as(f64, @floatFromInt(height)));
            try std.testing.expectEqual(@as(?usize, null), app.menuHit(app.menu_x - 1, app.menu_y + 10));
            for (0..app.menuLabels().len) |i| {
                const row = app.menuRowRect(i);
                try std.testing.expectEqual(@as(?usize, i), app.menuHit(row.x + 20, row.y + row.h / 2));
                if (app.menuSeparatorBefore(i)) {
                    try std.testing.expectEqual(@as(?usize, null), app.menuHit(row.x + 20, row.y - 5));
                }
            }
        }
    }
    app.dialog = null;
    app.handleKey(c.XKB_KEY_Down, "");
    try std.testing.expectEqual(@as(usize, 1), app.menu_selected);
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expectEqual(@as(?MenuKind, null), app.menu);
}

fn testApp() !App {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = undefined,
        .theme_cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .worker = undefined,
        .history = try history_mod.History.init(std.testing.allocator, "/tmp"),
        .home_dir = "/tmp",
        .items_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .folder_sizes = std.StringHashMap(SizeState).init(std.testing.allocator),
    };
}

fn testItems(app: *App, count: usize) !void {
    for (0..count) |i| {
        const name = try std.fmt.allocPrint(app.items_arena.allocator(), "file-{d}.txt", .{i});
        try app.items.append(app.allocator, .{ .name = name, .path = name, .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = @intCast(i), .mtime = @intCast(i), .icon_name = "" });
    }
}

test "address search and dialog share selection editing without file shortcuts" {
    var app = try testApp();
    defer app.deinit();
    try app.location.set(app.allocator, "/tmp/été");
    app.focus = .location_bar;
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_a, "a");
    app.handleKey(c.XKB_KEY_c, "c");
    try std.testing.expectEqualStrings("/tmp/été", app.clipboard_text.items);
    try std.testing.expect(app.clipboard_is_text);
    app.handleKey(c.XKB_KEY_x, "x");
    try std.testing.expectEqualStrings("", app.location.text.items);
    app.pasteText("/tmp/雪");
    app.ctrl = false;
    app.shift = true;
    app.handleKey(c.XKB_KEY_Left, "");
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_x, "x");
    try std.testing.expectEqualStrings("雪", app.clipboard_text.items);
    try std.testing.expectEqualStrings("/tmp/", app.location.text.items);
    app.handleKey(c.XKB_KEY_v, "v");
    try std.testing.expect(app.text_paste_requested and !app.paste_requested);
    app.ctrl = false;
    app.shift = false;
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expectEqualStrings("/tmp", app.location.text.items);
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_f, "f");
    app.pasteText("query");
    app.handleKey(c.XKB_KEY_a, "a");
    app.handleKey(c.XKB_KEY_c, "c");
    try std.testing.expectEqualStrings("query", app.clipboard_text.items);
    app.openNewFileDialog();
    app.handleKey(c.XKB_KEY_a, "a");
    app.pasteText("filename.txt");
    app.handleKey(c.XKB_KEY_c, "c"); // no selection: leave clipboard alone
    try std.testing.expectEqualStrings("query", app.clipboard_text.items);
    try std.testing.expectEqualStrings("filename.txt", app.dialog.?.edit.text.items);
}

test "pointer caret selection and long-path scrolling at both raster scales" {
    var app = try testApp();
    defer app.deinit();
    app.w = 360;
    app.h = 240;
    try app.location.set(app.allocator, "/tmp/abcdefghijklmnopqrstuvwxyz/abcdefghijklmnopqrstuvwxyz/abcdefghijklmnopqrstuvwxyz/雪");
    app.focus = .location_bar;
    for ([_]i32{ 1, 2 }) |scale| {
        app.scale = scale;
        const surf = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 720, 480).?;
        defer c.cairo_surface_destroy(surf);
        const cr = c.cairo_create(surf).?;
        defer c.cairo_destroy(cr);
        c.cairo_scale(cr, @floatFromInt(scale), @floatFromInt(scale));
        app.renderEditor(cr, &app.location, header.field(app.w), true, false);
        try std.testing.expect(app.location.scroll > 0);
        app.location.scroll = 0;
        app.placeCaret(App.textArea(header.field(app.w), false).x, false);
        try std.testing.expectEqual(@as(usize, 0), app.location.cursor);
        const pen = measureText(cr, "/tmp/", App.fieldFontSize(), false);
        app.placeCaret(App.textArea(header.field(app.w), false).x + pen, true);
        const sel = app.location.selection();
        try std.testing.expectEqualStrings("/tmp/", app.location.text.items[sel[0]..sel[1]]);
        app.location.move(app.location.text.items.len, false);
    }
}

test "keyboard ranges and focus-only movement in grid and list" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 60);
    for ([_]bool{ false, true }) |list| {
        app.list_view = list;
        app.ctrl = false;
        app.shift = false;
        app.handleKey(c.XKB_KEY_Home, "");
        app.shift = true;
        app.handleKey(c.XKB_KEY_Right, "");
        app.handleKey(c.XKB_KEY_Right, "");
        try std.testing.expect(app.items.items[0].selected and app.items.items[1].selected and app.items.items[2].selected);
        app.handleKey(c.XKB_KEY_Left, "");
        try std.testing.expect(!app.items.items[2].selected);
        app.shift = false;
        app.ctrl = true;
        app.handleKey(c.XKB_KEY_End, "");
        try std.testing.expectEqual(@as(?usize, 59), app.focused_index);
        try std.testing.expect(app.items.items[0].selected and !app.items.items[59].selected);
        app.ctrl = false;
        app.shift = true;
        app.handleKey(c.XKB_KEY_Page_Up, "");
        try std.testing.expectEqual(@as(?usize, 0), app.selection_anchor);
        try std.testing.expect(app.items.items[0].selected);
    }
}

test "history restores names and scroll while tolerating removed items" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 80);
    app.loading = false;
    app.scroll_y = 200;
    app.items.items[12].selected = true;
    app.items.items[13].selected = true;
    app.focused_index = 13;
    app.selection_anchor = 12;
    app.rememberView();
    try app.history.navigate("/elsewhere");
    _ = try app.history.back();
    _ = app.items.orderedRemove(13);
    for (app.items.items) |*item| item.selected = false;
    app.focused_index = null;
    app.selection_anchor = null;
    app.scroll_y = 0;
    app.restoreView();
    try std.testing.expectEqual(@as(i32, 200), app.scroll_y);
    try std.testing.expect(app.items.items[12].selected);
    try std.testing.expectEqual(@as(?usize, null), app.focused_index);
    try std.testing.expectEqual(@as(?usize, 12), app.selection_anchor);
}

test "stationary visual hover does no paint work and sidebar can reach bottom" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 12);
    app.handleMotion(250, 160);
    app.dirty = false;
    app.handleMotion(260, 170);
    try std.testing.expect(!app.dirty);
    app.handleMotion(490, 160);
    try std.testing.expect(app.dirty);
    app.h = 240;
    app.handleMotion(70, 175);
    app.handleScroll(800);
    try std.testing.expect(app.sidebar_scroll > 0);
    try std.testing.expect(app.placeY(App.pin_base - 1) + 30 <= app.h - 26);
    app.list_view = true;
    app.w = 360;
    for (App.column_labels, 0..) |_, i| {
        const rect = app.listColumn(i);
        try std.testing.expect(rect.x >= 0 and rect.x + rect.w <= 360 and rect.w > 40);
        if (i == 4) {
            const previous = app.sort_mode;
            app.sortByColumn(i);
            try std.testing.expectEqual(previous, app.sort_mode);
            continue;
        }
        app.sortByColumn(i);
        try std.testing.expectEqual(i, app.sortColumn());
        const descending = app.sortDescending();
        app.sortByColumn(i);
        try std.testing.expect(descending != app.sortDescending());
    }
}

test "retained hover repairs match complete Cairo rasters at scale 1 and 1.5" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    try testItems(&app, 12);
    for ([_]bool{ false, true }) |list| {
        app.list_view = list;
        for ([_]f64{ 1, 1.5 }) |scale| {
            const w: i32 = @intFromFloat(@as(f64, @floatFromInt(app.w)) * scale);
            const h: i32 = @intFromFloat(@as(f64, @floatFromInt(app.h)) * scale);
            const retained = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
            defer c.cairo_surface_destroy(retained);
            const reference = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
            defer c.cairo_surface_destroy(reference);
            const cr = c.cairo_create(retained).?;
            defer c.cairo_destroy(cr);
            const ref = c.cairo_create(reference).?;
            defer c.cairo_destroy(ref);
            c.cairo_scale(cr, scale, scale);
            c.cairo_scale(ref, scale, scale);
            app.stepHover(0);
            app.render(cr);
            app.dirty = false;
            var points: std.ArrayList([2]f64) = .empty;
            defer points.deinit(std.testing.allocator);
            if (list) {
                for (App.column_labels, 0..) |_, i| {
                    const rect = app.listColumn(i);
                    try points.append(std.testing.allocator, .{ rect.x + rect.w / 2, rect.y + rect.h / 2 });
                }
            }
            for (std.meta.tags(header.Action)) |action| {
                const button = header.rect(app.w, false, action);
                try points.append(std.testing.allocator, .{ button.x + button.w / 2, button.y + button.h / 2 });
            }
            const field = header.field(app.w);
            try points.append(std.testing.allocator, .{ field.x + 12, field.y + 18 });
            // Items, the header, the current place, other places and outside.
            try points.appendSlice(std.testing.allocator, &.{ .{ 250, 160 }, .{ 490, 160 }, .{ 70, 140 }, .{ 70, 200 }, .{ 70, 240 }, .{ 70, 500 }, .{ 50, 80 }, .{ 250, 160 }, .{ 250, 300 }, .{ 0, 0 } });
            var clock: i64 = 1000;
            for (points.items, 0..) |point, point_index| {
                // Selection transitions must repair retained pixels just like hover.
                for (app.items.items, 0..) |*item, i| item.selected = i == point_index % app.items.items.len;
                app.invalidate(); // Selection also changes toolbar actions and status.
                if (list) app.startSortFeedback(clock);
                app.handleMotion(point[0], point[1]);
                // From the frame the pointer arrived to well after both glides settle.
                for ([_]i64{ 0, 16, 32, 64, 100, 160, 5000 }) |elapsed| {
                    app.stepHover(clock + elapsed);
                    if (app.dirty) {
                        c.cairo_save(cr);
                        if (app.paint_damage) |rect| clipDamage(cr, rect);
                        app.render(cr);
                        c.cairo_restore(cr);
                        app.dirty = false;
                    }
                    app.render(ref);
                    c.cairo_surface_flush(retained);
                    c.cairo_surface_flush(reference);
                    const len: usize = @intCast(w * h * 4);
                    const actual = c.cairo_image_surface_get_data(retained)[0..len];
                    const expected = c.cairo_image_surface_get_data(reference)[0..len];
                    if (!std.mem.eql(u8, actual, expected)) {
                        const mismatch = std.mem.indexOfDiff(u8, actual, expected).? / 4;
                        std.debug.print("hover mismatch scale={d} point={any} +{d}ms damage={any} pixel={d},{d}\n", .{ scale, point, elapsed, app.paint_damage, mismatch % @as(usize, @intCast(w)), mismatch / @as(usize, @intCast(w)) });
                        _ = c.cairo_surface_write_to_png(retained, "/tmp/files-hover-actual.png");
                        _ = c.cairo_surface_write_to_png(reference, "/tmp/files-hover-expected.png");
                        return error.TestUnexpectedResult;
                    }
                }
                clock += 6000;
            }
        }
    }
}

/// A point inside item `idx`'s card, wherever the layout put it.
fn pointOnItem(app: *App, idx: usize) [2]f64 {
    const per_row: usize = @intCast(app.columns());
    const box = app.itemHighlight(.{ .col = @floatFromInt(idx % per_row), .row = @floatFromInt(idx / per_row), .alpha = 1 });
    return .{ box.x + 10, box.y + 10 };
}

test "item hover glides between cells and rests without repaints or wakeups" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    try testItems(&app, 12);
    app.dirty = false;

    // Nothing under the pointer: no highlight, no frame clock.
    app.stepHover(1000);
    try std.testing.expect(!app.hover_active and !app.dirty);

    // It fades in where the pointer landed.
    const first = pointOnItem(&app, 0);
    app.handleMotion(first[0], first[1]);
    app.dirty = false;
    app.stepHover(1000);
    try std.testing.expect(app.hover_active);
    app.stepHover(1050);
    try std.testing.expect(app.dirty and app.paint_damage != null);
    try std.testing.expect(app.item_hover.frame.alpha > 0 and app.item_hover.frame.alpha < 1);
    const card = app.itemHighlight(app.item_hover.frame);
    try std.testing.expect(app.paint_damage.?.contains(card.x + 1, card.y + 1) and app.paint_damage.?.contains(card.x + card.w - 2, card.y + card.h - 2));
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 1), app.item_hover.frame.alpha);
    try std.testing.expect(!app.hover_active);

    // At rest nothing repaints, however often it is sampled.
    app.dirty = false;
    app.stepHover(4100);
    app.stepHover(9000);
    try std.testing.expect(!app.dirty and !app.hover_active);

    // Moving to another item glides there rather than hopping.
    const per_row: usize = @intCast(app.columns());
    const to = pointOnItem(&app, 5);
    app.handleMotion(to[0], to[1]);
    app.stepHover(9100);
    app.stepHover(9150);
    const mid = app.item_hover.frame;
    const end_col: f32 = @floatFromInt(5 % per_row);
    const end_row: f32 = @floatFromInt(5 / per_row);
    try std.testing.expect(mid.col <= end_col and mid.row <= end_row);
    try std.testing.expect(mid.col > 0 or mid.row > 0);
    try std.testing.expect(mid.col < end_col or mid.row < end_row);
    try std.testing.expectEqual(@as(f32, 1), mid.alpha);
    try std.testing.expect(app.hover_active);
    app.stepHover(12000);
    try std.testing.expectEqual(end_col, app.item_hover.frame.col);
    try std.testing.expectEqual(end_row, app.item_hover.frame.row);
    try std.testing.expect(!app.hover_active);

    // A selected item paints its own fill: the highlight fades out.
    app.items.items[5].selected = true;
    app.stepHover(12100);
    app.stepHover(15000);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
    try std.testing.expect(!app.hover_active);

    // Leaving the window fades whatever is showing.
    app.items.items[5].selected = false;
    app.stepHover(15100);
    app.stepHover(18000);
    try std.testing.expectEqual(@as(f32, 1), app.item_hover.frame.alpha);
    app.handleMotion(-1, -1);
    app.stepHover(18100);
    app.stepHover(18150);
    try std.testing.expect(app.item_hover.frame.alpha < 1);
    app.stepHover(21000);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
    try std.testing.expect(!app.hover_active);

    // Modal UI owns the pointer.
    app.handleMotion(first[0], first[1]);
    app.menu = .background;
    app.stepHover(21100);
    app.stepHover(24000);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
}

test "sidebar hover glides between places and leaves the current one to its own fill" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    app.dirty = false;
    // Home is the current place (history starts at home_dir).
    app.handleMotion(70, @as(f64, @floatFromInt(app.placeY(0))) + 10);
    app.dirty = false;
    app.stepHover(1000);
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 0), app.nav_hover.frame.alpha);
    try std.testing.expect(!app.dirty and !app.hover_active);

    app.handleMotion(70, @as(f64, @floatFromInt(app.placeY(1))) + 10);
    app.stepHover(5000);
    app.stepHover(5050);
    try std.testing.expect(app.dirty and app.paint_damage != null);
    app.stepHover(8000);
    try std.testing.expectEqual(@as(f32, 1), app.nav_hover.frame.alpha);
    try std.testing.expectEqual(@as(f32, 1), app.nav_hover.frame.row);
    var box = app.navHighlight(app.nav_hover.frame);
    try std.testing.expectEqual(app.placeRect(1).y, box.y);

    // Every pixel between adjacent entries retains a hover target, at both pitches.
    const original_height = app.h;
    for ([_]i32{ 500, 700 }) |height| {
        app.h = height;
        const first = app.placeRect(App.places_start);
        const next = app.placeRect(App.places_start + 1);
        try std.testing.expectEqual(first.y + first.h, next.y);
        var y = first.y;
        while (y < next.y + next.h) : (y += 1) {
            app.mouse_y = y;
            try std.testing.expect(app.hoveredPlace() != null);
        }
    }
    app.h = original_height;

    // Three places down: partway, the highlight sits between the two rows.
    app.handleMotion(70, @as(f64, @floatFromInt(app.placeY(4))) + 10);
    app.stepHover(8100);
    app.stepHover(8150);
    const mid = app.nav_hover.frame;
    try std.testing.expect(mid.row > 1 and mid.row < 4);
    box = app.navHighlight(mid);
    try std.testing.expect(box.y > @as(f64, @floatFromInt(app.placeY(1))) and box.y < @as(f64, @floatFromInt(app.placeY(4))));
    try std.testing.expect(app.hover_active);
    app.stepHover(11000);
    try std.testing.expectEqual(@as(f32, 4), app.nav_hover.frame.row);
    try std.testing.expect(!app.hover_active);

    // Following scroll: the highlight is a place, not a pixel row.
    app.sidebar_scroll = 20;
    box = app.navHighlight(app.nav_hover.frame);
    try std.testing.expectEqual(app.placeRect(4).y, box.y);
}

test "a grid that reflows forgets its item highlight" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    try testItems(&app, 12);
    const on = pointOnItem(&app, 3);
    app.handleMotion(on[0], on[1]);
    app.stepHover(1000);
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 1), app.item_hover.frame.alpha);

    // Column 3 of a grid is off the edge of a list: it must not slide in.
    app.list_view = true;
    app.dirty = false;
    app.stepHover(4100);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
    try std.testing.expect(app.dirty and app.paint_damage == null);
    const row = pointOnItem(&app, 3);
    app.handleMotion(row[0], row[1]);
    app.stepHover(4200);
    app.stepHover(7000);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.col);
    try std.testing.expectEqual(@as(f32, 3), app.item_hover.frame.row);
}

test "hover damage covers this repaint only" {
    var app = try testApp();
    defer app.deinit();
    // Left over from the last paint: not pending.
    app.dirty = false;
    app.paint_damage = .{ .x = 0, .y = 0, .w = 900, .h = 500 };
    app.addDamage(.{ .x = 10, .y = 10, .w = 5, .h = 5 });
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(header.Rect{ .x = 10, .y = 10, .w = 5, .h = 5 }, app.paint_damage.?);
    // Pending damage accumulates.
    app.addDamage(.{ .x = 100, .y = 100, .w = 5, .h = 5 });
    try std.testing.expectEqual(header.Rect{ .x = 10, .y = 10, .w = 95, .h = 95 }, app.paint_damage.?);
    // A queued full repaint absorbs it.
    app.invalidate();
    app.addDamage(.{ .x = 10, .y = 10, .w = 5, .h = 5 });
    try std.testing.expect(app.dirty and app.paint_damage == null);
}

test "Files wheel follows the shell spring, accumulates and reverses without lag" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.handleMotion(300, 200);
    app.handleWheel(40, 1000);
    try std.testing.expectEqual(@as(i32, 0), app.scroll_y);
    app.stepWheel(1040);
    try std.testing.expect(app.scroll_y > 0 and app.scroll_y < 40);
    app.handleWheel(40, 1040);
    try std.testing.expectEqual(@as(f32, 80), app.wheel_glide.to);
    app.stepWheel(1100);
    const at = app.wheel_glide.value(1100);
    app.handleWheel(-10, 1100);
    try std.testing.expectApproxEqAbs(at - 10, app.wheel_glide.to, 0.01);
    app.stepWheel(5000);
    try std.testing.expect(!app.wheel_glide.active());
    app.handleWheel(100000, 6000);
    app.stepWheel(10000);
    try std.testing.expectEqual(app.maxScroll(), app.scroll_y);
    app.handleWheel(-40, 11000);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.wheel_glide.active());
}

test "file drag threshold preserves multi-selection and ordinary release collapses it" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 10);
    app.items.items[0].selected = true;
    app.items.items[1].selected = true;
    app.handleMotion(250, 158);
    app.handleButton(0x110, true);
    try std.testing.expect(app.items.items[1].selected);
    app.handleMotion(253, 158);
    try std.testing.expect(!app.drag_ready);
    app.handleMotion(270, 158);
    try std.testing.expect(app.drag_ready);
    app.handleButton(0x110, false);
    try std.testing.expect(app.items.items[1].selected);
    app.handleMotion(250, 158);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.items.items[1].selected);

    app.ctrl = true;
    app.last_click_index = null;
    app.handleButton(0x110, true);
    try std.testing.expect(app.items.items[0].selected);
    app.handleMotion(270, 158);
    try std.testing.expect(app.drag_ready);
    app.handleButton(0x110, false);
    try std.testing.expect(app.items.items[0].selected);
    app.handleMotion(250, 158);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.items.items[0].selected);
}

test "Files reduced motion scrolls immediately" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    var settings = saved;
    settings.reduced_motion = .on;
    anim.applySettings(settings);
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.handleMotion(300, 200);
    app.handleWheel(40, 1000);
    try std.testing.expectEqual(@as(i32, 40), app.scroll_y);
    try std.testing.expect(!app.wheel_glide.active());
}

test "background drag selects in grid and list with modifiers and reverse motion" {
    for ([_]bool{ false, true }) |list| {
        var app = try testApp();
        defer app.deinit();
        app.list_view = list;
        try testItems(&app, 20);
        const top: f64 = @floatFromInt(app.viewTop() + app.itemInset());
        // The left gutter is empty in both layouts.
        app.handleMotion(215, top - 5);
        app.handleButton(0x110, true);
        app.handleMotion(300, top + 15);
        try std.testing.expect(app.selection_band.?.active);
        try std.testing.expect(app.items.items[0].selected);
        try std.testing.expect(!app.items.items[1].selected);
        try std.testing.expect(!app.drag_ready);
        // Shrinking the rectangle removes items again.
        app.handleMotion(220, top - 3);
        try std.testing.expect(!app.items.items[0].selected);
        app.handleMotion(300, top + 15);
        app.handleButton(0x110, false);
        try std.testing.expect(app.selection_band == null);
        try std.testing.expect(app.items.items[0].selected);

        app.ctrl = true;
        app.items.items[2].selected = true;
        app.handleMotion(215, top - 5);
        app.handleButton(0x110, true);
        app.handleMotion(300, top + 15);
        try std.testing.expect(!app.items.items[0].selected);
        try std.testing.expect(app.items.items[2].selected);
        app.handleMotion(301, top + 16);
        try std.testing.expect(!app.items.items[0].selected); // No repeated toggling.
        app.handleButton(0x110, false);
        app.ctrl = false;
        app.shift = true;
        app.handleMotion(215, top - 5);
        app.handleButton(0x110, true);
        app.handleMotion(300, top + 15);
        try std.testing.expect(app.items.items[0].selected and app.items.items[2].selected);
        app.handleKey(c.XKB_KEY_Escape, "");
        try std.testing.expect(app.selection_band == null);
        try std.testing.expect(!app.items.items[0].selected and app.items.items[2].selected);
    }
}

test "selection edge scroll keeps a content anchor and stops on release" {
    var app = try testApp();
    defer app.deinit();
    app.list_view = true;
    try testItems(&app, 100);
    app.handleMotion(215, 150);
    app.handleButton(0x110, true);
    const anchor = app.selection_band.?.y;
    app.handleMotion(300, @floatFromInt(app.h - 30));
    try std.testing.expect(app.selectionNeedsScroll());
    app.stepSelection(app.selection_band.?.last_ms + 50);
    try std.testing.expect(app.scroll_y > 0);
    try std.testing.expectEqual(anchor, app.selection_band.?.y);
    app.handleButton(0x110, false);
    const offset = app.scroll_y;
    app.stepSelection(nowMs() + 500);
    try std.testing.expectEqual(offset, app.scroll_y);
    try std.testing.expect(!app.selectionNeedsScroll());
}

test "scrollbar gutter hover, outside drag, release and resize preserve layout" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.list_view = true;
    const column = app.listColumn(0);
    app.handleMotion(@floatFromInt(app.w - 7), @floatFromInt(app.viewTop() + 10));
    app.stepScrollbar(0);
    app.stepScrollbar(180);
    try std.testing.expectEqual(@as(f32, 1), app.scroll_appearance.wide);
    try std.testing.expectEqualDeep(column, app.listColumn(0));
    app.handleButton(0x110, true);
    try std.testing.expect(app.scroll_drag.active);
    app.handleMotion(-20, @floatFromInt(app.h + 100));
    app.stepScrollbar(200);
    try std.testing.expectEqual(app.maxScroll(), app.scroll_y);
    try std.testing.expectEqual(@as(f32, 1), app.scroll_appearance.accent);
    app.handleButton(0x110, false);
    app.stepScrollbar(220);
    app.stepScrollbar(600);
    app.stepScrollbar(800);
    try std.testing.expectEqual(@as(f32, 0), app.scroll_appearance.wide);
    try std.testing.expect(!app.scroll_appearance.active);
    app.h = 10000;
    app.clampScroll();
    app.stepScrollbar(1000);
    try std.testing.expectEqual(@as(i32, 0), app.scroll_y);
    try std.testing.expect(app.scroll_appearance.deadline == null);
}

test "viewport edge shadows at top middle bottom and when content fits" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.list_view = true;
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, app.w, app.h).?;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface).?;
    defer c.cairo_destroy(cr);
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
    const pixels = c.cairo_image_surface_get_data(surface);
    const x: usize = @intCast(app.sidebarWidth() + 10);
    for ([_]i32{ 0, @divTrunc(app.maxScroll(), 2), app.maxScroll() }) |offset| {
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
        app.scroll_y = offset;
        app.renderScrollEdges(cr, app.h - app.viewTop() - app.footerHeight());
        c.cairo_surface_flush(surface);
        const top: usize = @intCast(app.viewTop());
        const bottom: usize = @intCast(app.h - app.footerHeight() - 1);
        try std.testing.expectEqual(offset > 0, pixels[top * stride + x * 4 + 3] > 0);
        try std.testing.expectEqual(offset < app.maxScroll(), pixels[bottom * stride + x * 4 + 3] > 0);
        try std.testing.expectEqual(@as(u8, 0), pixels[(top - 1) * stride + x * 4 + 3]);
        try std.testing.expectEqual(@as(u8, 0), pixels[top * stride + 4 + 3]);
        try std.testing.expectEqual(@as(u8, 0), pixels[(top + 12) * stride + x * 4 + 3]);
    }
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    app.h = 10000;
    app.clampScroll();
    app.renderScrollEdges(cr, app.h - app.viewTop() - app.footerHeight());
    c.cairo_surface_flush(surface);
    try std.testing.expectEqual(@as(u8, 0), pixels[@as(usize, @intCast(app.viewTop())) * stride + x * 4 + 3]);
}

test "sidebar scrollbar pages, drags outside and resets on resize" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.resize(700, 300);
    const bar = app.sidebarScrollbar().?;
    app.handleMotion(@as(f64, bar.thumb.x) + 5, @as(f64, bar.thumb.y) + 5);
    app.stepScrollbar(0);
    app.stepScrollbar(180);
    try std.testing.expectEqual(@as(f32, 1), app.sidebar_scroll_appearance.wide);
    app.handleButton(0x110, true);
    try std.testing.expect(app.sidebar_scroll_drag.active);
    app.handleMotion(-20, 600);
    try std.testing.expectEqual(@as(i32, @intFromFloat(bar.max_offset)), app.sidebar_scroll);
    try std.testing.expectEqual(@as(i32, 0), app.scroll_y);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.sidebar_scroll_drag.active);
    app.handleMotion(@as(f64, bar.track.x) + 5, @as(f64, bar.track.y) + 1);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(@as(f32, @floatFromInt(app.sidebar_scroll)) < bar.max_offset);
    app.resize(700, 900);
    app.stepScrollbar(1000);
    app.stepScrollbar(2000);
    try std.testing.expect(app.sidebarScrollbar() == null);
    try std.testing.expectEqual(@as(i32, 0), app.sidebar_scroll);
    try std.testing.expect(!app.sidebar_scroll_appearance.active);
    try std.testing.expect(app.sidebar_scroll_appearance.deadline == null);
    app.resize(360, 240);
    try std.testing.expect(app.sidebarScrollbar() == null);
}

test "file selection fades in and out while logical selection is immediate" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    app.mouse_x = -1;
    app.mouse_y = -1;
    app.items.items[0].selected = true;
    app.stepHover(1000);
    try std.testing.expect(app.items.items[0].selected);
    try std.testing.expectEqual(@as(f32, 0), app.items.items[0].selection_fill.alpha);
    app.stepHover(1050);
    const alpha = app.items.items[0].selection_fill.alpha;
    try std.testing.expect(alpha > 0 and alpha < 1);
    app.items.items[0].selected = false;
    app.stepHover(1050);
    try std.testing.expectEqual(alpha, app.items.items[0].selection_fill.alpha);
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 0), app.items.items[0].selection_fill.alpha);
    try std.testing.expect(!app.hover_active);
    app.items.items[1].selected = true;
    app.stepHover(5000);
    app.stepHover(8000);
    try std.testing.expectEqual(@as(f32, 1), app.items.items[1].selection_fill.alpha);
    app.dirty = false;
    app.stepHover(9000);
    try std.testing.expect(!app.dirty and !app.hover_active);
    anim.applySettings(.{ .enabled = false });
    app.items.items[1].selected = false;
    app.stepHover(10000);
    try std.testing.expectEqual(@as(f32, 0), app.items.items[1].selection_fill.alpha);
}

test "list column resize keeps adjacent columns bounded and does not sort" {
    var app = try testApp();
    defer app.deinit();
    app.list_view = true;
    const original = app.listWidths();
    const rect = app.listColumn(0);
    const x = rect.x + rect.w;
    const y = rect.y + 15;
    try std.testing.expectEqualStrings("col-resize", std.mem.span(app.pointerCursor(x, y)));
    app.handleMotion(x, y);
    app.handleButton(0x110, true);
    app.handleMotion(x + 25, y + 100);
    try std.testing.expectApproxEqAbs(original[0] + 25, app.listWidths()[0], 0.001);
    try std.testing.expectApproxEqAbs(original[1] - 25, app.listWidths()[1], 0.001);
    try std.testing.expectEqualStrings("col-resize", std.mem.span(app.pointerCursor(x + 25, y + 100)));
    app.handleMotion(x + 1000, y);
    try std.testing.expectApproxEqAbs(@as(f64, 40), app.listWidths()[1], 0.001);
    app.handleButton(0x110, false);
    try std.testing.expect(app.column_resize == null);
    try std.testing.expectEqual(Sort.name, app.sort_mode);
    app.w = 360;
    var total: f64 = 0;
    for (app.listWidths()) |width| {
        try std.testing.expect(width >= 40);
        total += width;
    }
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(app.cellWidth() - 20)), total, 0.001);
    app.list_view = false;
    try std.testing.expectEqualStrings("default", std.mem.span(app.pointerCursor(x, y)));
}

test "sidebar menus unpin only Places and close gaps without changing selection" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    app.items.items[0].selected = true;
    const y = app.placeY(App.places_start);
    const last_place_y = app.placeY(App.pin_base - 1);
    app.handleMotion(70, @floatFromInt(y + 10));
    app.handleButton(0x111, true);
    try std.testing.expectEqual(MenuKind.sidebar, app.menu.?);
    try std.testing.expectEqualStrings("Unpin", app.menuLabels()[1]);
    try std.testing.expectEqualStrings("Properties", app.menuLabels()[2]);
    app.runMenu(2); // Properties must not alter pinned places.
    app.closeDialog();
    try std.testing.expect(app.placeVisible(App.places_start));
    app.openMenu(.sidebar, 70, @floatFromInt(y));
    app.runMenu(1);
    try std.testing.expect(!app.placeVisible(App.places_start));
    try std.testing.expectEqual(y, app.placeY(App.places_start + 1));
    try std.testing.expectEqual(@as(?usize, App.places_start + 1), app.placeAt(70, @floatFromInt(y + 10)));
    try std.testing.expectEqual(last_place_y - app.placeStep(), app.placeY(App.pin_base - 1));
    try std.testing.expect(app.items.items[0].selected);
    for ([_]usize{ 0, 1 }) |index| {
        app.menu_place = index;
        app.openMenu(.sidebar, 70, 140);
        try std.testing.expectEqual(@as(usize, 2), app.menuLabels().len);
        try std.testing.expectEqualStrings("Properties", app.menuLabels()[1]);
        app.runMenu(1);
        try std.testing.expect(app.placeVisible(index));
    }
    app.menu_place = 2;
    app.openMenu(.sidebar, 70, 210);
    try std.testing.expectEqualSlices([]const u8, &.{"Open"}, app.menuLabels());
    app.menu = null;
    try std.testing.expect(app.placeVisible(2));
    try std.testing.expectEqual(app.placeY(1) + app.placeStep(), app.placeY(2));
    for (App.places_start..App.pin_base) |index| {
        app.menu_place = index;
        app.openMenu(.sidebar, 70, 140);
        app.runMenu(1);
    }
    try std.testing.expectEqual(@as(u8, 0x7f), app.unpinned_places);
    try std.testing.expectEqual(@as(?usize, null), app.placeAt(70, @floatFromInt(y + 10)));
    app.closeDialog();
    try app.history.navigate(recent.location);
    try std.testing.expect(!app.history.canUp());
    try std.testing.expect(!app.toolbarButtonEnabled(.new));
    try std.testing.expect(!app.toolbarButtonEnabled(.paste));
    try std.testing.expectEqual(Sort.modified, app.effectiveSort());
    try std.testing.expectEqual(@as(?[]const u8, null), app.dropDirectoryAt(500, 300));
    app.openNewFolderDialog();
    try std.testing.expect(app.dialog == null);
    try std.testing.expect(app.placeActive(2));
}

test "pins sit after Projects, take drops by gap and keep the rows in drawn order" {
    var app = try testApp();
    defer app.deinit();
    app.h = 1000;
    const step = app.placeStep();
    const places_bottom = app.placeY(App.pin_base - 1);
    app.pinDropped(0, &.{ "/usr", "/dev/null", "/usr/", "/nonexistent-rediwm-pin", "relative" });
    try std.testing.expectEqual(@as(usize, 2), app.pins.items.items.len);
    try std.testing.expectEqualStrings("usr", app.pins.items.items[0].name());
    try std.testing.expectEqual(pins_mod.Kind.file, app.pins.items.items[1].kind);

    // Pins take the rows after Projects; the devices follow.
    try std.testing.expectEqual(App.pin_base + 2, app.deviceBase());
    try std.testing.expectEqual(app.placeY(App.pin_base - 1) + step, app.placeY(App.pin_base));
    try std.testing.expectEqual(places_bottom + 2 * step, app.placeY(App.pin_base + 1));
    const volumes = [_]volumes_mod.Volume{.{ .id = "/b/sdb1", .label = "STICK", .mount = null, .size = 1 << 30, .kind = .stick }};
    app.device_list.items = &volumes;
    try std.testing.expectEqual(App.pin_base + 2, app.deviceBase());
    try std.testing.expectEqual(app.placeY(App.pin_base + 1) + 44 + step, app.placeY(app.deviceBase()));
    try std.testing.expectEqual(@as(?usize, App.pin_base + 1), app.placeAt(70, @floatFromInt(app.placeY(App.pin_base + 1) + 10)));
    app.handleMotion(70, @floatFromInt(app.placeY(App.pin_base + 1) + 10));
    try std.testing.expectEqual(@as(usize, 801), app.hoverKey());
    app.device_list.items = &.{};

    // A drag snaps to the nearest gap from anywhere on PLACES, and only there.
    const desktop: f64 = @floatFromInt(app.placeY(App.places_start) + 10);
    const first_gap = app.pinBoundary(0);
    try std.testing.expectEqual(@as(?usize, 0), app.pinSlotAt(70, desktop));
    try std.testing.expectEqual(@as(?usize, 0), app.pinSlotAt(70, first_gap + 4));
    try std.testing.expectEqual(@as(?usize, 1), app.pinSlotAt(70, app.pinBoundary(1) - 4));
    try std.testing.expectEqual(@as(?usize, 2), app.pinSlotAt(70, app.pinBoundary(2) + 10));
    try std.testing.expectEqual(@as(?usize, null), app.pinSlotAt(70, @floatFromInt(app.placeY(0) + 10)));
    try std.testing.expectEqual(@as(?usize, null), app.pinSlotAt(70, app.pinBoundary(2) + 40));
    try std.testing.expectEqual(@as(?usize, null), app.pinSlotAt(400, desktop));
    try std.testing.expect(app.dropMotion(70, first_gap + 4));
    try std.testing.expectEqual(@as(?usize, 0), app.pin_drop);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(?usize, 0), app.takePinDrop());
    try std.testing.expectEqual(@as(?usize, null), app.pin_drop);
    try std.testing.expect(!app.dropMotion(400, desktop));

    // Dropping on a gap inserts there; what is listed already, built in or
    // gone is refused.
    app.pinDropped(1, &.{"/etc"});
    try std.testing.expectEqualStrings("etc", app.pins.items.items[1].name());
    try std.testing.expectEqual(@as(usize, 3), app.pins.items.items.len);
    // The test app's home is /tmp.
    app.pinDropped(0, &.{"/tmp"});
    try std.testing.expectEqual(@as(usize, 3), app.pins.items.items.len);
    try std.testing.expectEqualStrings("Already in Places", app.status_notice.?);

    // Only a pin offers removal, which closes the gap again.
    app.menu_place = App.pin_base + 1;
    app.openMenu(.sidebar, 70, 140);
    try std.testing.expectEqualStrings("Remove from Places", app.menuLabels()[1]);
    app.runMenu(1);
    try std.testing.expectEqual(@as(usize, 2), app.pins.items.items.len);
    try std.testing.expectEqualStrings("null", app.pins.items.items[1].name());
    try std.testing.expectEqual(places_bottom + 2 * step, app.placeY(App.pin_base + 1));
}

test "Sidebar lists devices under Places; only mounted ones eject" {
    var app = try testApp();
    defer app.deinit();
    app.h = 1000;
    const extent = app.sidebarExtent();
    const last_place_y = app.placeY(App.pin_base - 1);
    const volumes = [_]volumes_mod.Volume{
        .{ .id = "/b/sdb1", .label = "STICK", .mount = "/run/media/user/STICK", .size = 1 << 30, .kind = .stick },
        .{ .id = "/b/sda1", .label = "", .mount = null, .size = 500 << 30, .kind = .drive },
    };
    app.device_list.items = &volumes;
    const mounted = app.deviceBase();
    const unmounted = mounted + 1;
    const step = app.placeStep();
    try std.testing.expectEqual(last_place_y + 44 + step, app.placeY(mounted));
    try std.testing.expectEqual(app.placeY(mounted) + step, app.placeY(unmounted));
    try std.testing.expectEqual(extent + 44 + 2 * step, app.sidebarExtent());

    const row_y: f64 = @floatFromInt(app.placeY(mounted) + 10);
    try std.testing.expectEqual(@as(?usize, mounted), app.placeAt(70, row_y));
    const button = app.ejectRect(mounted);
    try std.testing.expectEqual(@as(?usize, 0), app.ejectAt(button.x + 5, button.y + 5));
    try std.testing.expectEqual(@as(?usize, null), app.ejectAt(70, row_y));
    const other = app.ejectRect(unmounted);
    try std.testing.expectEqual(@as(?usize, null), app.ejectAt(other.x + 5, other.y + 5));
    app.handleMotion(button.x + 5, button.y + 5);
    try std.testing.expectEqual(@as(usize, 700), app.hoverKey());
    app.handleMotion(70, row_y);
    try std.testing.expectEqual(@as(usize, 600), app.hoverKey());
    app.handleMotion(70, @floatFromInt(app.placeY(unmounted) + 10));
    try std.testing.expectEqual(@as(usize, 601), app.hoverKey());

    app.menu = .device;
    app.menu_place = mounted;
    try std.testing.expectEqualStrings("Eject", app.menuLabels()[1]);
    app.menu_place = unmounted;
    try std.testing.expectEqual(@as(usize, 1), app.menuLabels().len);
    try std.testing.expectEqualStrings("Mount", app.menuLabels()[0]);

    // Results end the operation and say what happened; a mount only opens
    // the volume if the view has not moved on meanwhile.
    var result = std.mem.zeroes(volumes_mod.Result);
    @memcpy(result.object[0..7], "/b/sdb1");
    app.device_op = .{ .id = try std.testing.allocator.dupe(u8, "/b/sdb1"), .unmount = true, .open = false, .navigation = app.navigation_count };
    result.ok = 1;
    app.deviceResult(&result);
    try std.testing.expect(app.device_op == null);
    try std.testing.expectEqualStrings("STICK can be safely removed", app.status_notice.?);
    app.device_op = .{ .id = try std.testing.allocator.dupe(u8, "/b/sdb1"), .unmount = true, .open = false, .navigation = app.navigation_count };
    result.ok = 0;
    @memcpy(result.code[0.."org.freedesktop.UDisks2.Error.DeviceBusy".len], "org.freedesktop.UDisks2.Error.DeviceBusy");
    app.deviceResult(&result);
    try std.testing.expectEqualStrings("STICK is busy", app.status_notice.?);
    result = std.mem.zeroes(volumes_mod.Result);
    @memcpy(result.object[0..7], "/b/sda1");
    @memcpy(result.path[0..6], "/mnt/a");
    result.ok = 1;
    app.device_op = .{ .id = try std.testing.allocator.dupe(u8, "/b/sda1"), .unmount = false, .open = true, .navigation = app.navigation_count -% 1 };
    app.deviceResult(&result);
    try std.testing.expectEqualStrings("500.0 GB Volume mounted", app.status_notice.?);
}

test "File context actions distinguish files, folders and symlinks" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    app.items.items[0].selected = true;
    app.items.items[0].is_dir = false;
    app.menu = .file;
    try std.testing.expectEqual(@as(usize, 8), app.menuLabels().len);
    try std.testing.expectEqualStrings("Open With…", app.menuLabels()[1]);
    try std.testing.expectEqualStrings("Cut", app.menuLabels()[2]);
    try std.testing.expectEqualStrings("Properties", app.menuLabels()[7]);
    try std.testing.expectEqualStrings("F2", app.menuHint(5).?);
    try std.testing.expectEqual(@as(usize, 14), app.menuSeparatorSpace());
    app.items.items[0].is_symlink = true;
    try std.testing.expect(app.canOpenWith());
    app.items.items[0].is_broken = true;
    try std.testing.expect(!app.canOpenWith());
    app.items.items[0].is_broken = false;
    app.items.items[1].selected = true;
    app.items.items[1].is_dir = true;
    try std.testing.expectEqualStrings("Calculate size", app.menuLabels()[6]);
    try std.testing.expectEqualStrings("Cut", app.menuLabels()[1]);
    app.items.items[1].is_symlink = true;
    try std.testing.expectEqual(@as(usize, 7), app.menuLabels().len);
    app.items.items[1].selected = false;
    app.items.items[0].name = "example.ZIP";
    app.items.items[0].path = "/example.ZIP";
    try std.testing.expectEqualStrings("Extract", app.menuLabels()[2]);
    try std.testing.expectEqualStrings("Extract to…", app.menuLabels()[3]);
    try std.testing.expectEqual(FileAction.rename, app.fileActions()[7]);
    app.items.items[1].selected = true;
    try std.testing.expect(app.selectedArchive() == null);
    app.items.items[1].selected = false;
    try app.history.navigateLocation("/example.ZIP", "/example.ZIP".len);
    app.menu = .file;
    try std.testing.expectEqualSlices(FileAction, &.{.open}, app.fileActions());
    app.openNewFolderDialog();
    app.openRenameDialog();
    try std.testing.expect(app.dialog == null);
    try std.testing.expect(!app.executePaste(.copy, &.{"/tmp/a"}));
}

test "Git layout has two columns, scrollable sidebar and display-only deleted rows" {
    var app = try testApp();
    defer app.deinit();
    var snap: worker_mod.Snapshot = .{ .arena = undefined, .request_id = 1, .dir = "/repo", .items = &.{}, .repository = .{ .root = "/repo", .directory = "/repo", .branch = "main" } };
    app.snapshot = &snap;
    defer app.snapshot = null;
    app.list_view = true;
    try std.testing.expectEqual(@as(usize, 2), app.columnLabels().len);
    try std.testing.expectEqualStrings("Git", app.columnLabels()[1]);
    try std.testing.expectEqual(@as(f64, 164), app.listColumn(1).w);
    try std.testing.expectEqual(@as(f64, 0), app.listColumn(2).w);
    const boundary = app.listColumn(0);
    const boundary_x = boundary.x + boundary.w;
    const boundary_y = boundary.y + 10;
    try std.testing.expectEqual(@as(?usize, 0), app.columnBoundary(boundary_x, boundary_y));
    const sort = app.sort_mode;
    app.handleMotion(boundary_x, boundary_y);
    app.handleButton(0x110, true);
    app.handleMotion(boundary_x - 40, boundary_y + 100);
    try std.testing.expectApproxEqAbs(@as(f64, 204), app.listColumn(1).w, 0.001);
    try std.testing.expectEqualStrings("col-resize", std.mem.span(app.pointerCursor(boundary_x - 40, boundary_y + 100)));
    app.handleMotion(boundary_x + 1000, boundary_y);
    try std.testing.expectApproxEqAbs(@as(f64, 64), app.listColumn(1).w, 0.001);
    app.handleButton(0x110, false);
    try std.testing.expect(app.column_resize == null);
    try std.testing.expectEqual(sort, app.sort_mode);
    app.resize(360, 300);
    const widths = app.listWidths();
    try std.testing.expect(widths[0] >= 96 and widths[1] >= 64);
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(app.cellWidth() - 20)), widths[0] + widths[1], 0.001);
    app.resize(960, 540);
    app.sortByColumn(1);
    try std.testing.expectEqual(sort, app.sort_mode);
    // Turning Git View off presents the repository as an ordinary folder.
    const gone: worker_mod.Item = .{ .name = "gone.txt", .path = "/repo/gone.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = "", .git_status = .deleted, .missing = true };
    try std.testing.expect(app.matches(gone));
    app.git_view = false;
    try std.testing.expect(app.repository() == null and app.inRepository());
    try std.testing.expectEqual(@as(usize, 5), app.columnLabels().len);
    try std.testing.expectEqual(@as(i32, 0), app.gitSidebarHeight());
    try std.testing.expect(!app.matches(gone));
    app.git_view = true;
    // Changed files list flat; search matches the path shown, and full paths can be turned off.
    const nested: worker_mod.Item = .{ .name = "omega.txt", .label = "zdir/inner/omega.txt", .path = "/repo/zdir/inner/omega.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 6, .mtime = 1, .icon_name = "", .git_status = .untracked };
    try app.search.text.appendSlice(app.allocator, "zdir");
    try std.testing.expect(app.matches(nested));
    app.full_paths = false;
    try std.testing.expect(!app.matches(nested));
    app.full_paths = true;
    app.changed_only = false;
    try std.testing.expect(!app.matches(nested));
    app.changed_only = true;
    app.search.text.clearRetainingCapacity();
    // The Git card is the last sidebar section, below the final place.
    try std.testing.expect(app.gitCard().y > @as(f64, @floatFromInt(app.placeY(App.pin_base - 1))));
    const expanded_extent = app.sidebarExtent();
    app.git_expanded = false;
    // Collapsing hides the current-branch row and the "New branch" row (28px each) and the 4px padding.
    try std.testing.expectEqual(expanded_extent - 60, app.sidebarExtent());
    try testItems(&app, 1);
    app.items.items[0].missing = true;
    app.items.items[0].selected = true;
    app.focused_index = 0;
    app.copySelected();
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_paths.items.len);
    app.openRenameDialog();
    try std.testing.expect(app.dialog == null);
    app.openTrashConfirmDialog();
    try std.testing.expect(app.dialog == null);
    app.previewSelected();
    try std.testing.expect(app.editor_path == null);
}
