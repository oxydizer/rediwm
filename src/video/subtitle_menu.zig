//! Subtitle choices in the controls subsurface. Rows use the same retained
//! buttons and pointer dispatcher as the toolbar.
const ui = @import("ui");
const tr = @import("app_kit").i18n.tr;
const Widget = ui.layout.Widget;

pub const Action = enum { menu, off, track, load };

pub const Menu = struct {
    open: bool = false,
    root: Widget = .{
        .kind = .container,
        .direction = .column,
        .@"align" = .stretch,
        .padding = ui.layout.Edges.all(ui.context_menu.padding),
    },
    rows: [4]Widget = undefined,
    choice: ?Action = null,

    pub fn show(self: *Menu, name: ?[]const u8, enabled: bool) void {
        self.open = true;
        self.rows[0] = .{
            .height = .{ .flex = 1 },
            .margin = .{ .left = 10 },
            .kind = .{ .text = .{
                .content = tr("Subtitles"),
                .font_size = ui.cairo.textSize(),
                .weight = 600,
                .color = ui.theme.global.window_fg,
            } },
        };
        self.rows[1] = self.option(.off, tr("Off"), !enabled);
        var count: usize = 2;
        if (name) |label| {
            self.rows[count] = self.option(.track, label, enabled);
            count += 1;
        }
        self.rows[count] = self.option(.load, tr("Load subtitle file…"), false);
        self.root.children = self.rows[0 .. count + 1];
        self.root.linkParents();
    }

    fn option(self: *Menu, action: Action, label: []const u8, selected: bool) Widget {
        return .{ .height = .{ .flex = 1 }, .kind = .{ .button = .{
            .owner = self,
            .id = @backingInt(action),
            .on_click = clicked,
            .label = label,
            .alignment = .left,
            .size = .sm,
            .variant = .ghost,
            .selected = selected,
            .leading_icon = if (action == .load) .folder else null,
            .trailing_icon = if (selected) .checkmark else null,
        } } };
    }

    fn clicked(raw: ?*anyopaque, id: usize) void {
        const self: *Menu = @ptrCast(@alignCast(raw.?));
        self.choice = @fromBackingInt(@intCast(id));
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
