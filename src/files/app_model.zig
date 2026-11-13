//! Files view model: the enums and records the App and its parts share.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const git = @import("git.zig");
const dirsize = @import("dirsize.zig");
const deletion = @import("../delete_dialog.zig");
const header = @import("header.zig");
const IconId = @import("ui").layout.IconId;
const open_with = @import("open_with.zig");
const properties = @import("properties.zig");
const trash_properties = @import("trash_properties.zig");
const Editor = @import("editor.zig").Editor;

pub const DeviceOp = struct { id: []u8, unmount: bool, open: bool, navigation: u32 };

pub const MenuKind = enum { new, sort, filter, file, background, sidebar, device, chooser_filter };
pub const PlaceAction = enum {
    open,
    open_window,
    empty_trash,
    unpin,
    remove_pin,
    properties,
    mount,
    eject,

    pub fn label(self: PlaceAction) []const u8 {
        return switch (self) {
            .open => tr("Open"),
            .open_window => tr("Open in New Window"),
            .empty_trash => tr("Empty Trash…"),
            .unpin => tr("Unpin"),
            .remove_pin => tr("Remove from Places"),
            .properties => tr("Properties"),
            .mount => tr("Mount"),
            .eject => tr("Eject"),
        };
    }
};
pub const FileAction = enum {
    open,
    open_with,
    add_application,
    extract,
    extract_to,
    cut,
    copy,
    paste,
    rename,
    trash,
    /// In the Trash: put the entry back, or remove it for good.
    restore,
    delete_permanently,
    size,
    properties,
    pub fn label(self: FileAction) []const u8 {
        return switch (self) {
            .open => tr("Open"),
            .open_with => tr("Open With…"),
            .add_application => tr("Add to applications"),
            .extract => tr("Extract"),
            .extract_to => tr("Extract to…"),
            .cut => tr("Cut"),
            .copy => tr("Copy"),
            .paste => tr("Paste"),
            .rename => tr("Rename"),
            .trash => tr("Move to Trash"),
            .restore => tr("Restore"),
            .delete_permanently => tr("Delete Permanently"),
            .size => tr("Calculate size"),
            .properties => tr("Properties"),
        };
    }
    pub fn icon(self: FileAction) IconId {
        return switch (self) {
            .open => .chevron_right,
            .open_with => .grid,
            .add_application => .plus,
            .extract, .extract_to => .folder,
            .cut => .cut,
            .copy => .copy,
            .paste => .paste,
            .rename => .edit,
            .trash, .delete_permanently => .trash,
            .restore => .undo,
            .size, .properties => .view_list,
        };
    }
};
pub const Sort = enum { name, name_desc, size, modified, type, size_asc, modified_asc, type_desc };

/// The four first-class sections in the Files sidebar, in display order.
pub const SidebarSection = enum(u2) {
    places,
    disks,
    git,
    transfers,
};

/// Shared geometry for one sidebar accordion card.
pub const SidebarCardGeometry = struct {
    y: i32,
    header_height: i32,
    body_height: i32,
    visible: bool,
    expanded: bool,

    pub fn height(self: SidebarCardGeometry) i32 {
        if (!self.visible) return 0;
        return self.header_height + (if (self.expanded) self.body_height else 0);
    }
};

/// Vertical layout contract shared by all sidebar cards.
pub const SidebarLayout = struct {
    pub const header_height: i32 = 32;
    pub const gap: i32 = 8;

    cards: [4]SidebarCardGeometry,

    /// Positions visible cards in section order. Every expanded card
    /// receives its body height independently.
    pub fn init(
        top: i32,
        body_heights: [4]i32,
        visible: [4]bool,
        expanded_sections: [4]bool,
    ) SidebarLayout {
        var result: SidebarLayout = .{ .cards = undefined };
        var y = top;

        for (0..4) |i| {
            const expanded = visible[i] and expanded_sections[i];
            const card: SidebarCardGeometry = .{
                .y = y,
                .header_height = header_height,
                .body_height = body_heights[i],
                .visible = visible[i],
                .expanded = expanded,
            };
            result.cards[i] = card;
            if (visible[i]) y += card.height() + gap;
        }

        return result;
    }
};

pub const SizeState = union(enum) {
    running: *dirsize.Job,
    done: struct {
        bytes: i64,
        partial: bool,
    },
};

pub const SelectionFade = @import("ui").hover_glide.Fade;

// Titlebar timing, with a rectangle that also fits labelled toolbar buttons.
pub const ToolbarHover = struct {
    geometry: [4]anim.Anim = @splat(.{}),
    alpha: anim.Anim = .{ .property = .opacity },
    frame: [4]f32 = @splat(0),
    opacity: f32 = 0,

    pub fn step(self: *ToolbarHover, now: i64, target: ?header.Rect, pixel: f32) bool {
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

    pub fn active(self: ToolbarHover, now: i64) bool {
        if (!self.alpha.settled(now)) return true;
        for (self.geometry) |a| if (!a.settled(now)) return true;
        return false;
    }
};

pub const ViewItem = struct {
    git_status: git.Status = .clean,
    git_lines: ?git.LineCounts = null,
    transfer_stub: bool = false,
    missing: bool = false,
    name: []const u8,
    /// Path from the listed folder, shown instead of `name` in the Git view's
    /// flat list. `name` stays the file's own name: renaming and opening use it.
    label: []const u8 = "",
    sort_key: ?[]const u8 = null,
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
    pub fn text(self: ViewItem) []const u8 {
        return if (self.label.len > 0) self.label else self.name;
    }
};

/// The part of the view the last thumbnail request described.
pub const ThumbRequest = struct {
    revision: u64 = std.math.maxInt(u64),
    row0: i32 = 0,
    row1: i32 = 0,
    cols: i32 = 0,
};

pub const Focus = enum {
    terminal,
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
    transfers,
    torrent_source,
    torrent_destination,
    terminal_close,
    new_folder,
    new_file,
    new_branch,
    rename,
    trash_confirm,
    conflict,
    open_with,
    properties,
    trash_properties,
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
    trash_properties: ?trash_properties.State = null,
};

pub const RenameCard = struct { panel: header.Rect, field: header.Rect, confirm: header.Rect, cancel: header.Rect };
