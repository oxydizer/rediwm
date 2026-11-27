const i18n = @import("i18n");
const std = @import("std");
const keys = @import("config").keybinds;
const catalogue = @import("shortcut_catalogue.zig");
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

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    groups: [names.len]W = undefined,
    /// How many of `groups` the page shows: all of them, or one notice
    /// when the tree could not be allocated.
    group_count: usize = 0,
    collapsed: [names.len]bool = @splat(false),
    targets: std.ArrayList(Target) = .empty,
    editing: ?Target = null,
    candidate: ?keys.Keybind = null,
    message: []const u8 = "",
    pending_save: bool = false,
    held_keycode: ?u32 = null,
    held_sym: xkb.Keysym = .NoSymbol,
    held_mods: wlr.Keyboard.ModifierMask = .{},

    pub fn cancel(s: *Section) void {
        s.pending_save = false;
        s.held_keycode = null;
        s.editing = null;
        s.candidate = null;
        s.message = "";
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
        if (!s.pending_save) return;
        s.pending_save = false;
        const candidate = s.candidate orelse return;
        const target = s.editing orelse return;
        saving.saveMode(gpa, cc.server.io, cc.server.config.path, cc.server.config.activeKeybinds(), target.index, candidate, cc.server.config.compositor.desktop_mode) catch {
            s.message = i18n.tr("Could not save. Check the configuration file and try again.");
            cc.refresh();
            return;
        };
        s.cancel();
        @import("../../config_runtime/watcher.zig").reloadConfig(cc.server);
        cc.refresh();
    }
};

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
    buildGroups(s, cc, s.arena.allocator()) catch {
        s.groups[0] = panel.outOfMemory();
        s.group_count = 1;
        return;
    };
    s.group_count = s.groups.len;
}

fn buildGroups(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !void {
    const t = panel.palette();
    const binds = cc.server.config.activeKeybinds();
    const indices = try catalogue.effectiveIndices(a, binds);
    const effective = try a.alloc(keys.Keybind, indices.len);
    for (effective, indices) |*bind, i| bind.* = binds[i];
    const actions = try catalogue.actions(a, cc.server.config.compositor.desktop_mode, effective);
    for (&s.groups, 0..) |*card, g| {
        var rows: std.ArrayList(W) = .empty;
        if (g == 0) {
            try rows.append(a, text(if (cc.server.world.workspaces.active) i18n.tr("Workspaces · Hyprland-style preset") else i18n.tr("Canvas · RediWM preset"), false));
            if (cc.server.world.workspaces.active) try rows.append(a, text(i18n.tr("Super+Q opens Terminal; Super+M opens Power. Arrows focus; numbers switch workspaces."), true));
        }
        try rows.append(a, .{ .kind = .{ .row = .{ .owner = cc, .id = g, .on_click = collapse } }, .height = .{ .fixed = 40 }, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.xy(12, 0), .gap = 12, .@"align" = .center, .children = try children(a, &.{
            .{ .kind = .{ .icon = .{ .id = icons[g], .color = t.window_fg } }, .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } },
            blk: {
                var title = text(names[g].get(), false);
                title.width = .{ .flex = 1 };
                break :blk title;
            },
            .{ .kind = .{ .icon = .{ .id = if (s.collapsed[g]) .chevron_up else .chevron_down, .color = t.window_dim } }, .width = .{ .fixed = 16 }, .height = .{ .fixed = 16 } },
        }) });
        if (!s.collapsed[g] and g == catalogue.group(.noop)) for (effective, indices) |bind, i| {
            if (bind.action == .noop) try appendRow(s, cc, a, &rows, i18n.tr("Disabled shortcut."), "", .{ .action = .noop, .index = i }, false);
        };
        if (!s.collapsed[g]) for (actions) |action| {
            if (catalogue.group(action) != g) continue;
            var title_buf: [1024]u8 = undefined;
            var desc_buf: [8192]u8 = undefined;
            const title = try a.dupe(u8, catalogue.title(action, &title_buf));
            const description = try a.dupe(u8, catalogue.description(action, &desc_buf));
            var first = true;
            for (effective, indices) |bind, i| {
                if (!keys.actionEql(bind.action, action)) continue;
                const caption = if (first) description else "";
                try appendRow(s, cc, a, &rows, if (first) title else "", caption, .{ .action = action, .index = i }, first);
                first = false;
            }
            const adding = if (s.editing) |target| target.index == null and keys.actionEql(target.action, action) else false;
            if (first or adding) try appendRow(s, cc, a, &rows, if (first) title else "", if (first) description else "", .{ .action = action, .index = null }, false);
        };
        card.* = .{ .name = "shortcuts", .kind = .{ .rect = .{ .color = t.settings_card_bg, .radius = t.settings_card_radius, .border_width = 1, .border_color = t.window_divider, .relief = t.settings_card_relief } }, .direction = .column, .width = .{ .percent = 1 }, .children = rows.items };
    }
}
fn appendRow(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator, rows: *std.ArrayList(W), title: []const u8, description: []const u8, target: Target, add: bool) !void {
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
    else if (bind) |assigned|
        saving.format(a, assigned) catch i18n.tr("Unknown key")
    else
        i18n.tr("Not assigned");
    var controls: std.ArrayList(W) = .empty;
    try controls.append(a, .{ .kind = .container, .direction = .column, .width = .{ .flex = 1 }, .gap = 3, .children = try children(a, &.{ text(title, false), text(caption, true) }) });
    var chip = button(cc, id, shortcut, null, edit);
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
    } else if (bind != null) {
        var edit_btn = button(cc, id, i18n.tr("Edit shortcut"), .edit, edit);
        edit_btn.name = "edit";
        try controls.append(a, edit_btn);
        if (bind.?.action != .noop) {
            var disable = button(cc, id, i18n.tr("Disable shortcut"), .close, disableClicked);
            disable.name = "disable";
            try controls.append(a, disable);
        }
    }
    if (add and !editing) try controls.append(a, button(cc, id, i18n.tr("Add shortcut"), .plus, addClicked));
    try rows.append(a, .{ .kind = .{ .rect = .{ .color = t.window_divider } }, .height = .{ .fixed = 1 }, .width = .{ .percent = 1 } });
    try rows.append(a, .{ .kind = .container, .direction = .row, .height = .{ .fixed = 60 }, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.xy(12, 0), .gap = 8, .@"align" = .center, .children = controls.items });
}

fn owner(p: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(p.?));
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
    owner(p).shortcuts.pending_save = true;
}

fn disableClicked(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    const target = cc.shortcuts.targets.items[i];
    const bind = cc.server.config.activeKeybinds()[target.index.?];
    cc.shortcuts.cancel();
    cc.shortcuts.editing = target;
    cc.shortcuts.candidate = .{ .sym = bind.sym, .modifiers = bind.modifiers, .action = .noop };
    cc.shortcuts.pending_save = true;
}
