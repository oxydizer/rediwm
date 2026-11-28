const i18n = @import("i18n");
const std = @import("std");
const keys = @import("config").keybinds;
const catalogue = @import("shortcut_catalogue.zig");
const Filter = @import("shortcut_filter.zig").Filter;
const saving = @import("config").shortcut_save;
const panel = @import("../panel.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;
const xkb = @import("xkbcommon");
const wlr = @import("wlroots");

const names = [_]i18n.Message{ i18n.msg("Window Management"), i18n.msg("Canvas & Focus"), i18n.msg("Launcher"), i18n.msg("Screenshots"), i18n.msg("Media"), i18n.msg("System"), i18n.msg("Workspaces"), i18n.msg("Custom Commands"), i18n.msg("Disabled Shortcuts") };
const icons = [_]ui.layout.IconId{ .display, .grid, .grid, .document, .volume, .power, .grid, .document, .keyboard };
const Target = struct {
    action: keys.Action,
    index: ?usize,
};
const Pending = union(enum) { record, reset: ?keys.Action, save_command, delete_command };

const CommandEditor = struct {
    id: ?[]const u8 = null,
    original: ?[]const u8 = null,
    focus: bool = true,
    confirm_delete: bool = false,

    fn deinit(editor: *CommandEditor) void {
        if (editor.id) |id| gpa.free(id);
        if (editor.original) |command| gpa.free(command);
    }
};

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    groups: [names.len + 2]W = undefined,
    group_count: usize = 0,
    search_field: W = .{ .kind = .container },
    search_clear: W = .{ .kind = .container },
    search_focus: bool = false,
    command_editor: ?CommandEditor = null,
    command_field: W = .{ .kind = .container },
    command_field_visible: bool = false,
    collapsed: [names.len]bool = @splat(false),
    targets: std.ArrayList(Target) = .empty,
    editing: ?Target = null,
    candidate: ?keys.Keybind = null,
    message: []const u8 = "",
    pending: ?Pending = null,
    confirm_reset: bool = false,
    held_keycode: ?u32 = null,
    held_sym: xkb.Keysym = .NoSymbol,
    held_mods: wlr.Keyboard.ModifierMask = .{},

    pub fn deinit(s: *Section) void {
        s.closeCommandEditor();
        if (s.command_field.kind == .text_input) gpa.free(s.command_field.kind.text_input.value);
        if (s.search_field.kind == .text_input) gpa.free(s.search_field.kind.text_input.value);
        s.arena.deinit();
    }

    pub fn cancel(s: *Section) void {
        s.cancelRecording();
        s.closeCommandEditor();
    }

    pub fn cancelRecording(s: *Section) void {
        s.pending = null;
        s.confirm_reset = false;
        s.held_keycode = null;
        s.editing = null;
        s.candidate = null;
        s.message = "";
    }

    fn closeCommandEditor(s: *Section) void {
        if (s.command_editor) |*editor| editor.deinit();
        s.command_editor = null;
    }

    pub fn cancelCommand(s: *Section) bool {
        if (s.command_editor == null) return false;
        s.cancel();
        return true;
    }

    pub fn takeCommandFocus(s: *Section) bool {
        const editor = if (s.command_editor) |*active| active else return false;
        defer editor.focus = false;
        return editor.focus;
    }

    pub fn release(s: *Section, keycode: u32) void {
        if (s.held_keycode == keycode) s.held_keycode = null;
    }

    pub fn modifiers(s: *Section, cc: *panel.ControlCenter, mods: wlr.Keyboard.ModifierMask) void {
        if (s.held_keycode == null) return;
        // Include modifiers pressed after the main key, retaining the chord
        // as keys are released in either order.
        const combined = keys.relevantMods(@as(wlr.Keyboard.ModifierMask, @bitCast(@as(u32, @bitCast(s.held_mods)) | @as(u32, @bitCast(mods)))));
        if (keys.pack(combined, s.held_sym) == keys.pack(s.held_mods, s.held_sym)) return;
        s.capture(cc, s.held_keycode.?, s.held_sym, @bitCast(combined));
    }

    pub fn capture(s: *Section, cc: *panel.ControlCenter, keycode: u32, sym: xkb.Keysym, mods: wlr.Keyboard.ModifierMask) void {
        switch (sym) {
            xkb.Keysym.Escape => {
                s.cancel();
                cc.refresh();
                return;
            },
            xkb.Keysym.Super_L, xkb.Keysym.Super_R, xkb.Keysym.Control_L, xkb.Keysym.Control_R, xkb.Keysym.Shift_L, xkb.Keysym.Shift_R, xkb.Keysym.Alt_L, xkb.Keysym.Alt_R, xkb.Keysym.Caps_Lock, xkb.Keysym.Num_Lock => return,
            else => {},
        }
        const target = s.editing orelse return;
        s.held_keycode = keycode;
        s.held_sym = sym;
        s.held_mods = @bitCast(keys.relevantMods(mods));
        const candidate: keys.Keybind = .{ .sym = keys.normalizeSym(sym), .modifiers = keys.relevantMods(mods), .action = target.action };
        s.message = "";
        s.candidate = candidate;
        const binds = cc.server.config.activeKeybinds();
        var i = binds.len;
        while (i > 0) {
            i -= 1;
            const bind = binds[i];
            if (keys.pack(bind.modifiers, bind.sym) != keys.pack(candidate.modifiers, candidate.sym)) continue;
            if (i != target.index and bind.action != .noop) {
                s.candidate = null;
                s.message = i18n.tr("Shortcut already in use. Try another.");
            }
            break;
        }
        cc.refresh();
    }

    pub fn apply(s: *Section, cc: *panel.ControlCenter) void {
        const pending = s.pending orelse return;
        s.pending = null;
        const config = &cc.server.config;
        const result = switch (pending) {
            .record => saving.saveMode(gpa, cc.server.io, config.path, config.activeKeybinds(), (s.editing orelse return).index, s.candidate orelse return, config.compositor.desktop_mode),
            .reset => |target| saving.saveReset(gpa, cc.server.io, config.path, config.activeKeybinds(), config.compositor.desktop_mode, target),
            .save_command => s.saveCommand(cc, false),
            .delete_command => s.saveCommand(cc, true),
        };
        result catch |err| {
            s.message = switch (err) {
                error.ShortcutConflict => i18n.tr("A factory shortcut is in use. Unassign it before resetting."),
                error.InvalidCommand => i18n.tr("Enter an executable and check the command’s quoting and expansions."),
                error.CommandChanged => i18n.tr("This command changed on disk. Reopen it before saving."),
                else => i18n.tr("Could not save. Check the configuration file and try again."),
            };
            cc.refresh();
            return;
        };
        s.cancel();
        @import("../../config_runtime/watcher.zig").reloadConfig(cc.server);
        cc.refresh();
    }

    fn saveCommand(s: *Section, cc: *panel.ControlCenter, deleting: bool) !void {
        const editor = if (s.command_editor) |*active| active else return;
        const config = &cc.server.config;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const id = editor.id orelse try nextCommandId(a, config);
        if (editor.original) |original| {
            const current = config.shortcut_commands.get(id) orelse return error.CommandChanged;
            if (!std.mem.eql(u8, current, original)) return error.CommandChanged;
        }
        const command = if (deleting) null else s.command_field.kind.text_input.value;
        if (command) |value| _ = try @import("../../config_runtime/actions.zig").customCommandArgs(cc.server, a, value);
        try saving.saveCustomCommand(gpa, cc.server.io, config, id, command);
    }
};

fn nextCommandId(a: std.mem.Allocator, config: *const @import("config").loader.Config) ![]const u8 {
    var n: usize = 1;
    while (true) : (n += 1) {
        var buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "command-{d}", .{n});
        const action: keys.Action = .{ .custom_command = id };
        if (config.shortcut_commands.contains(id)) continue;
        for ([_][]const keys.Keybind{ config.keybinds, config.workspace_keybinds }) |binds| {
            for (binds) |bind| {
                if (keys.actionEql(bind.action, action)) break;
            } else continue;
            break;
        } else return a.dupe(u8, id);
    }
}

fn text(value: []const u8, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = if (dim) 12 else 13, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
}
fn button(cc: *panel.ControlCenter, id: usize, value: []const u8, icon: ?ui.layout.IconId, callback: *const fn (?*anyopaque, usize) void) W {
    return .{ .kind = .{ .button = .{ .label = value, .icon = icon, .owner = cc, .id = id, .on_click = callback } }, .height = .{ .fixed = 32 }, .width = if (icon != null) .{ .fixed = 32 } else .auto };
}
fn children(a: std.mem.Allocator, values: []const W) ![]W {
    return a.dupe(W, values);
}

pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    _ = s.arena.reset(.retain_capacity);
    s.targets = .empty;
    s.group_count = 0;
    s.command_field_visible = false;
    buildGroups(s, cc, s.arena.allocator()) catch {
        s.groups[0] = panel.outOfMemory();
        s.group_count = 1;
        s.command_field_visible = false;
        return;
    };
}

fn buildGroups(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !void {
    const t = panel.palette();
    const binds = cc.server.config.activeKeybinds();
    const mode = cc.server.config.compositor.desktop_mode;
    var factory = try saving.factoryConfig(a, mode);
    defer factory.deinit();
    const defaults = factory.activeKeybinds();
    const indices = try catalogue.effectiveIndices(a, binds);
    const effective = try a.alloc(keys.Keybind, indices.len);
    for (effective, indices) |*bind, i| bind.* = binds[i];
    const commands = &cc.server.config.shortcut_commands;
    const actions = try catalogue.actions(a, mode, effective, commands.keys());
    const labels = try a.alloc([]const u8, effective.len);
    for (labels, effective) |*label, bind| label.* = saving.format(a, bind) catch i18n.tr("Unknown key");
    const search = try searchField(s, cc);
    const filter = try Filter.init(a, s.search_field.kind.text_input.value, .{ .turkish = i18n.isTurkish() });
    const searching = filter.query.len > 0;
    s.groups[0] = .{ .kind = .container, .direction = .column, .gap = 8, .children = try children(a, &.{
        search,
        try resetBar(s, cc, a, saving.canReset(effective, defaults, null)),
    }) };
    s.group_count = 1;
    for (names, 0..) |name, g| {
        var rows: std.ArrayList(W) = .empty;
        const expanded = searching or !s.collapsed[g];
        try rows.append(a, .{ .kind = .{ .row = .{ .owner = cc, .id = g, .on_click = if (searching) null else collapse } }, .height = .{ .fixed = 40 }, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.xy(12, 0), .gap = 12, .@"align" = .center, .children = try children(a, &.{
            .{ .kind = .{ .icon = .{ .id = icons[g], .color = t.window_fg } }, .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } },
            blk: {
                var title = text(name.get(), false);
                title.width = .{ .flex = 1 };
                break :blk title;
            },
            .{ .kind = .{ .icon = .{ .id = if (expanded) .chevron_down else .chevron_up, .color = t.window_dim } }, .width = .{ .fixed = 16 }, .height = .{ .fixed = 16 } },
        }) });
        if (expanded and g == catalogue.group(.noop)) for (effective, indices, labels) |bind, i, label| {
            const title = i18n.tr("Disabled shortcut.");
            if (bind.action == .noop and !searching) try appendRow(s, cc, a, &rows, title, "", .{ .action = .noop, .index = i }, label, false, false);
        };
        if (expanded) for (actions) |action| {
            if (catalogue.group(action) != g) continue;
            var title_buf: [1024]u8 = undefined;
            var desc_buf: [8192]u8 = undefined;
            const command = if (action == .custom_command) commands.get(action.custom_command) else null;
            const title = try a.dupe(u8, if (command != null and command.?.len != 0)
                command.?
            else
                catalogue.title(action, &title_buf));
            const description = if (command != null) "" else try a.dupe(u8, catalogue.description(action, &desc_buf));
            const matches = filter.text(title, description) or for (effective, labels) |bind, label| {
                if (keys.actionEql(bind.action, action) and filter.binding(label)) break true;
            } else false;
            if (!matches) continue;
            if (s.command_editor) |*editor| {
                if (editor.id != null and action == .custom_command and std.mem.eql(u8, editor.id.?, action.custom_command))
                    try rows.append(a, try commandForm(s, cc, a, editor));
            }
            var first = true;
            for (effective, indices, labels) |bind, i, label| {
                if (!keys.actionEql(bind.action, action)) continue;
                const caption = if (first) description else "";
                try appendRow(s, cc, a, &rows, if (first) title else "", caption, .{ .action = action, .index = i }, label, first, first and saving.canReset(effective, defaults, action));
                first = false;
            }
            const adding = if (s.editing) |target| target.index == null and keys.actionEql(target.action, action) else false;
            if (first or adding) try appendRow(s, cc, a, &rows, if (first) title else "", if (first) description else "", .{ .action = action, .index = null }, i18n.tr("Not assigned"), false, first and saving.canReset(effective, defaults, action));
        };
        if (searching and rows.items.len == 1) continue;
        if (expanded and g == catalogue.group(.{ .custom_command = "" })) {
            try rows.insert(a, 1, .{ .kind = .container, .padding = ui.layout.Edges.xy(12, 8), .children = try children(a, &.{
                button(cc, 0, i18n.tr("Add Custom Command"), null, addCommand),
            }) });
            if (s.command_editor) |*editor| {
                if (!s.command_field_visible) try rows.insert(a, 2, try commandForm(s, cc, a, editor));
            }
        }
        s.groups[s.group_count] = .{ .name = "shortcuts", .kind = .{ .rect = .{ .color = t.settings_card_bg, .radius = t.settings_card_radius, .border_width = 1, .border_color = t.window_divider, .relief = t.settings_card_relief } }, .direction = .column, .width = .{ .percent = 1 }, .children = rows.items };
        s.group_count += 1;
    }
    if (searching and s.group_count == 1) {
        s.groups[1] = text(i18n.tr("No matching shortcuts. Try an action name, command, or key combination."), true);
        s.group_count = 2;
    }
}

fn searchField(s: *Section, cc: *panel.ControlCenter) !W {
    if (s.search_field.kind != .text_input) {
        s.search_field = .{ .name = "shortcut_search", .kind = .{ .text_input = .{
            .field = .{ .leading_icon = .search },
            .placeholder = i18n.tr("Search shortcuts…"),
            .value = try gpa.dupe(u8, ""),
            .owner = cc,
            .on_change = searchChanged,
        } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 }, .justify = .end, .@"align" = .center, .padding = .{ .right = 3 } };
    }
    const has_query = s.search_field.kind.text_input.value.len > 0;
    s.search_field.kind.text_input.placeholder = i18n.tr("Search shortcuts…");
    s.search_field.kind.text_input.field.trailing = if (has_query) .accessory else .none;
    s.search_clear = button(cc, 0, i18n.tr("Clear shortcut search"), .close, clearSearch);
    s.search_field.children = if (has_query) (&s.search_clear)[0..1] else &.{};
    return .{ .kind = .container, .width = .{ .percent = 1 }, .children = (&s.search_field)[0..1] };
}

fn searchChanged(p: ?*anyopaque, _: usize, _: []const u8) void {
    const cc = owner(p);
    cc.shortcuts.cancel();
    cc.shortcuts.search_focus = true;
    cc.refresh();
}

fn clearSearch(p: ?*anyopaque, _: usize) void {
    const cc = owner(p);
    const empty = gpa.dupe(u8, "") catch return;
    const field = &cc.shortcuts.search_field.kind.text_input;
    gpa.free(field.value);
    field.value = empty;
    field.cursor_pos = 0;
    field.selection_anchor = null;
    searchChanged(cc, 0, empty);
}

fn resetBar(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator, enabled: bool) !W {
    var widgets: std.ArrayList(W) = .empty;
    if (s.confirm_reset) {
        try widgets.append(a, text(i18n.tr("Restore factory bindings for built-in actions in this desktop mode. Custom commands are kept."), true));
        try widgets.append(a, .{ .kind = .container, .gap = 8, .children = try children(a, &.{
            button(cc, 0, i18n.tr("Reset built-in shortcuts"), null, confirmReset),
            button(cc, 0, i18n.tr("Cancel"), null, cancelClicked),
        }) });
    } else {
        var reset = button(cc, 0, i18n.tr("Reset All Shortcuts"), null, requestReset);
        if (!enabled) reset.kind.button.state = .disabled;
        try widgets.append(a, reset);
    }
    if (s.editing == null and s.command_editor == null and s.message.len != 0) try widgets.append(a, text(s.message, true));
    return .{ .kind = .container, .direction = .column, .@"align" = .start, .gap = 8, .children = widgets.items };
}

fn appendRow(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator, rows: *std.ArrayList(W), title: []const u8, description: []const u8, target: Target, label: []const u8, add: bool, reset: bool) !void {
    const t = panel.palette();
    const id = s.targets.items.len;
    try s.targets.append(a, target);
    const bind = if (target.index) |i| cc.server.config.activeKeybinds()[i] else null;
    const editing = if (s.editing) |active| active.index == target.index and keys.actionEql(active.action, target.action) else false;
    const caption = if (editing)
        (if (s.message.len > 0) s.message else i18n.tr("Press keys to record. Esc cancels."))
    else if (description.len == 0 and bind != null and bind.?.inherited)
        i18n.tr("Inherited shortcut")
    else
        description;
    const shortcut = if (editing)
        if (s.candidate) |candidate| saving.format(a, candidate) catch i18n.tr("Unknown key") else i18n.tr("Press new shortcut…")
    else
        label;
    var controls: std.ArrayList(W) = .empty;
    try controls.append(a, .{ .kind = .container, .direction = .column, .width = .{ .flex = 1 }, .gap = 3, .children = try children(a, &.{ text(title, false), text(caption, true) }) });
    var chip = button(cc, id, shortcut, null, edit);
    if (target.action == .noop) chip.kind.button.state = .disabled;
    chip.name = "shortcut";
    chip.width = .{ .fixed = if (cc.panel_box.width < 660) 140 else 190 };
    if (editing) chip.kind.button.variant = .primary;
    try controls.append(a, chip);
    if (editing) {
        var confirm = button(cc, id, i18n.tr("Save shortcut"), .checkmark, confirmClicked);
        confirm.name = "save";
        confirm.kind.button.variant = .primary;
        if (s.candidate == null) confirm.kind.button.state = .disabled;
        try controls.append(a, confirm);
        var cancel_btn = button(cc, id, i18n.tr("Cancel"), .close, cancelClicked);
        cancel_btn.name = "cancel";
        try controls.append(a, cancel_btn);
    } else {
        if (bind != null and target.action != .noop) {
            var remove = button(cc, id, i18n.tr("Unassign shortcut"), .close, disableClicked);
            remove.name = "unassign";
            try controls.append(a, remove);
        }
        if (add) try controls.append(a, button(cc, id, i18n.tr("Add shortcut"), .plus, addClicked));
        if (title.len != 0 and target.action == .custom_command and cc.server.config.shortcut_commands.contains(target.action.custom_command))
            try controls.append(a, button(cc, id, i18n.tr("Edit command"), null, editCommand));
        if (title.len != 0 and keys.isBuiltIn(target.action)) {
            var restore = button(cc, id, i18n.tr("Restore factory bindings"), .refresh, resetClicked);
            if (!reset) restore.kind.button.state = .disabled;
            try controls.append(a, restore);
        }
    }
    try rows.append(a, .{ .kind = .{ .rect = .{ .color = t.window_divider } }, .height = .{ .fixed = 1 }, .width = .{ .percent = 1 } });
    try rows.append(a, .{ .kind = .container, .direction = .row, .height = .{ .fixed = 60 }, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.xy(12, 0), .gap = 8, .@"align" = .center, .children = controls.items });
}

fn owner(p: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(p.?));
}

fn commandForm(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator, editor: *CommandEditor) !W {
    var controls: std.ArrayList(W) = .empty;
    if (editor.confirm_delete) {
        try controls.append(a, button(cc, 0, i18n.tr("Delete command and its shortcuts"), null, confirmDeleteCommand));
    } else {
        try controls.append(a, button(cc, 0, i18n.tr("Save command"), null, saveCommandClicked));
        if (editor.id != null) try controls.append(a, button(cc, 0, i18n.tr("Delete command…"), null, requestDeleteCommand));
    }
    try controls.append(a, button(cc, 0, i18n.tr("Cancel"), null, cancelClicked));
    s.command_field_visible = true;
    return .{ .kind = .container, .direction = .column, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.xy(12, 8), .gap = 8, .children = try children(a, &.{
        .{ .kind = .container, .width = .{ .percent = 1 }, .children = (&s.command_field)[0..1] },
        text(if (s.message.len > 0) s.message else if (editor.confirm_delete)
            i18n.tr("Delete this command and its bindings in all desktop modes?")
        else
            i18n.tr("Commands run directly. Use sh -c to run shell syntax."), true),
        .{ .kind = .container, .gap = 8, .children = controls.items },
    }) };
}

fn openCommand(cc: *panel.ControlCenter, id: ?[]const u8) !void {
    const original = if (id) |key| cc.server.config.shortcut_commands.get(key) orelse return else null;
    const owned_id = if (id) |key| try gpa.dupe(u8, key) else null;
    errdefer if (owned_id) |key| gpa.free(key);
    const owned_original = if (original) |value| try gpa.dupe(u8, value) else null;
    errdefer if (owned_original) |value| gpa.free(value);
    const value = try gpa.dupe(u8, original orelse "");
    const s = &cc.shortcuts;
    s.cancel();
    if (s.command_field.kind == .text_input) gpa.free(s.command_field.kind.text_input.value);
    s.command_editor = .{
        .id = owned_id,
        .original = owned_original,
    };
    s.command_field = .{ .name = "shortcut_command", .kind = .{ .text_input = .{
        .placeholder = i18n.tr("Executable and arguments"),
        .value = value,
        .cursor_pos = value.len,
        .owner = cc,
        .on_change = commandChanged,
    } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 } };
    cc.refresh();
}

fn addCommand(p: ?*anyopaque, _: usize) void {
    const cc = owner(p);
    openCommand(cc, null) catch return;
}

fn editCommand(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    openCommand(cc, cc.shortcuts.targets.items[i].action.custom_command) catch return;
}

fn commandChanged(p: ?*anyopaque, _: usize, _: []const u8) void {
    const cc = owner(p);
    if (cc.shortcuts.message.len == 0) return;
    cc.shortcuts.message = "";
    cc.refresh();
}

fn saveCommandClicked(p: ?*anyopaque, _: usize) void {
    owner(p).shortcuts.pending = .save_command;
}

fn requestDeleteCommand(p: ?*anyopaque, _: usize) void {
    const cc = owner(p);
    if (cc.shortcuts.command_editor) |*editor| editor.confirm_delete = true;
    cc.shortcuts.message = "";
    cc.refresh();
}

fn confirmDeleteCommand(p: ?*anyopaque, _: usize) void {
    owner(p).shortcuts.pending = .delete_command;
}

fn edit(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    cc.shortcuts.cancel();
    cc.shortcuts.editing = cc.shortcuts.targets.items[i];
    cc.refresh();
}
fn addClicked(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    cc.shortcuts.cancel();
    cc.shortcuts.editing = .{ .action = cc.shortcuts.targets.items[i].action, .index = null };
    cc.refresh();
}
fn collapse(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    cc.shortcuts.collapsed[i] = !cc.shortcuts.collapsed[i];
    cc.shortcuts.cancel();
    cc.refresh();
}
fn cancelClicked(p: ?*anyopaque, _: usize) void {
    const cc = owner(p);
    cc.shortcuts.cancel();
    cc.refresh();
}
fn confirmClicked(p: ?*anyopaque, _: usize) void {
    owner(p).shortcuts.pending = .record;
}

fn resetClicked(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    cc.shortcuts.cancel();
    cc.shortcuts.pending = .{ .reset = cc.shortcuts.targets.items[i].action };
}

fn requestReset(p: ?*anyopaque, _: usize) void {
    const cc = owner(p);
    cc.shortcuts.cancel();
    cc.shortcuts.confirm_reset = true;
    cc.refresh();
}

fn confirmReset(p: ?*anyopaque, _: usize) void {
    const cc = owner(p);
    cc.shortcuts.confirm_reset = false;
    cc.shortcuts.pending = .{ .reset = null };
}

fn disableClicked(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    const target = cc.shortcuts.targets.items[i];
    const bind = cc.server.config.activeKeybinds()[target.index.?];
    cc.shortcuts.cancel();
    cc.shortcuts.editing = target;
    cc.shortcuts.candidate = .{ .sym = bind.sym, .modifiers = bind.modifiers, .action = .noop };
    cc.shortcuts.pending = .record;
}
