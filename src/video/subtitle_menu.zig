//! Subtitle and audio-track choices in the controls subsurface. Rows use the
//! same retained buttons and pointer dispatcher as the toolbar.
const ui = @import("ui");
const tr = @import("app_kit").i18n.tr;
const Widget = ui.layout.Widget;

pub const Action = enum { menu, off, track, load };
/// Audio tracks listed at most; the strip has little room above it.
pub const max_audio_tracks = 8;

pub const Menu = struct {
    open: bool = false,
    root: Widget = .{
        .kind = .container,
        .direction = .column,
        .@"align" = .stretch,
        .padding = ui.layout.Edges.all(ui.context_menu.padding),
    },
    rows: [max_audio_tracks + 1]Widget = undefined,
    choice: ?Action = null,
    /// Whether the open menu lists audio tracks rather than subtitles.
    audio: bool = false,
    /// Index of the audio track picked.
    audio_choice: ?usize = null,

    fn heading(title: []const u8) Widget {
        return .{
            .height = .{ .flex = 1 },
            .margin = .{ .left = 10 },
            .kind = .{ .text = .{
                .content = title,
                .font_size = ui.cairo.textSize(),
                .weight = 600,
                .color = ui.theme.global.window_fg,
            } },
        };
    }

    /// `names` are the track labels; `selected` is the one in use.
    pub fn showAudio(self: *Menu, names: []const []const u8, selected: ?usize) void {
        self.open = true;
        self.audio = true;
        self.rows[0] = heading(tr("Audio track"));
        var count: usize = 1;
        if (names.len == 0) {
            self.rows[count] = self.option(0, tr("No audio"), true, null);
            count += 1;
        }
        for (names[0..@min(names.len, max_audio_tracks)], 0..) |label, i| {
            self.rows[count] = self.option(i, label, selected == i, null);
            count += 1;
        }
        self.root.children = self.rows[0..count];
        self.root.linkParents();
    }

    pub fn show(self: *Menu, name: ?[]const u8, enabled: bool) void {
        self.open = true;
        self.audio = false;
        self.rows[0] = heading(tr("Subtitles"));
        self.rows[1] = self.option(@backingInt(Action.off), tr("Off"), !enabled, null);
        var count: usize = 2;
        if (name) |label| {
            self.rows[count] = self.option(@backingInt(Action.track), label, enabled, null);
            count += 1;
        }
        self.rows[count] = self.option(@backingInt(Action.load), tr("Load subtitle file…"), false, .folder);
        self.root.children = self.rows[0 .. count + 1];
        self.root.linkParents();
    }

    fn option(self: *Menu, id: usize, label: []const u8, selected: bool, leading: ?ui.layout.IconId) Widget {
        return .{ .height = .{ .flex = 1 }, .kind = .{ .button = .{
            .owner = self,
            .id = id,
            .on_click = clicked,
            .label = label,
            .alignment = .left,
            .size = .sm,
            .variant = .ghost,
            .selected = selected,
            .leading_icon = leading,
            .trailing_icon = if (selected) .checkmark else null,
        } } };
    }

    fn clicked(raw: ?*anyopaque, id: usize) void {
        const self: *Menu = @ptrCast(@alignCast(raw.?));
        if (self.audio) {
            self.audio_choice = id;
        } else self.choice = @fromBackingInt(@intCast(id));
    }

    pub fn height(self: *const Menu) i32 {
        const row: i32 = @intFromFloat(@ceil(ui.widgets.select.rowHeight()));
        return row * @as(i32, @intCast(self.root.children.len)) + 2 * ui.context_menu.padding;
    }

    pub fn layout(self: *Menu, right: f32, width: f32, available: f32) void {
        const w = @min(width, ui.context_menu.width);
        const h = @min(available, @as(f32, @floatFromInt(self.height())));
        const x = @max(0, right - w);
        self.root.kind = .{ .rect = .{ .color = ui.theme.global.app_toolbar, .radius = 8, .border_width = 1, .border_color = ui.theme.global.app_item_border } };
        ui.arrange.arrange(&self.root, x, 0, w, h);
    }
};
