const i18n = @import("i18n");
const std = @import("std");
const config_mod = @import("config");
const keys = config_mod.keybinds;
const Config = config_mod.loader.Config;
const DesktopMode = config_mod.loader.DesktopMode;
const catalogue = @import("shortcut_catalogue.zig");
const Filter = @import("shortcut_filter.zig").Filter;
const saving = @import("config").shortcut_save;
const slots = config_mod.shortcut_slots;
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
    chord: ?u64 = null,
    slot: ?slots.Slot = null,
    assigned: ?slots.Slots = null,
    mode: DesktopMode,
    command: ?[]const u8 = null,

    fn copy(target: Target, a: std.mem.Allocator) !Target {
        var owned = target;
        owned.action = switch (target.action) {
            .spawn => |str| .{ .spawn = try a.dupe(u8, str) },
            .save_layout => |str| .{ .save_layout = try a.dupe(u8, str) },
            .restore_layout => |str| .{ .restore_layout = try a.dupe(u8, str) },
            .custom_command => |str| .{ .custom_command = try a.dupe(u8, str) },
            else => target.action,
        };
        if (target.command) |str| owned.command = try a.dupe(u8, str);
        return owned;
    }

    fn commandSnapshot(target: Target) ?saving.CommandSnapshot {
        return if (target.action == .custom_command)
            .{ .id = target.action.custom_command, .text = target.command }
        else
            null;
    }

    fn resolve(target: Target, cfg: *const Config) error{ConfigChanged}!?usize {
        if (target.mode != cfg.compositor.desktop_mode) return error.ConfigChanged;
        if (target.commandSnapshot()) |command| {
            if (!command.matches(cfg)) return error.ConfigChanged;
        }
        if (target.slot) |slot| {
            var factory = saving.factoryConfig(gpa, target.mode) catch
                return error.ConfigChanged;
            defer factory.deinit();
            const current = slots.resolve(
                cfg.activeKeybinds(),
                factory.activeKeybinds(),
                target.action,
                cfg.storedShortcutSlots(target.action),
            );
            const expected = target.assigned orelse
                return error.ConfigChanged;
            if (!current.eql(expected) or
                current.get(slot) != target.chord)
                return error.ConfigChanged;
        }
        const chord = target.chord orelse return null;
        const binds = cfg.activeKeybinds();
        var i = binds.len;
        while (i > 0) {
            i -= 1;
            const bind = binds[i];
            if (keys.pack(bind.modifiers, bind.sym) != chord) continue;
            if (keys.actionEql(bind.action, target.action)) return i;
            break;
        }
        return error.ConfigChanged;
    }

    fn eql(x: Target, y: Target) bool {
        if (x.mode != y.mode or x.chord != y.chord or !keys.actionEql(x.action, y.action)) return false;
        if (x.slot != y.slot) return false;
        if ((x.assigned == null) != (y.assigned == null)) return false;
        if (x.assigned) |assigned| {
            if (!assigned.eql(y.assigned.?)) return false;
        }
        return if (x.command) |body| y.command != null and std.mem.eql(u8, body, y.command.?) else y.command == null;
    }
};
const Pending = union(enum) { record, reset: ?Target, save_command, delete_command };

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

const InlineCommand = struct {
    id: []const u8,
    original: []const u8,
    data: ui.layout.TextInputData,
    widget: ?*W = null,

    fn capture(entry: *InlineCommand) void {
        if (entry.widget) |widget| {
            entry.data = widget.kind.text_input;
        }
        entry.widget = null;
    }

    fn current(entry: *const InlineCommand) ui.layout.TextInputData {
        if (entry.widget) |widget| return widget.kind.text_input;
        return entry.data;
    }

    fn isDirty(entry: *const InlineCommand) bool {
        return !std.mem.eql(
            u8,
            entry.original,
            entry.current().value,
        );
    }

    fn sync(entry: *InlineCommand, command: []const u8) !void {
        if (entry.isDirty()) return;
        if (std.mem.eql(u8, entry.original, command)) return;

        const original = try gpa.dupe(u8, command);
        errdefer gpa.free(original);
        const value = try gpa.dupe(u8, command);

        gpa.free(entry.original);
        gpa.free(entry.current().value);

        entry.original = original;
        entry.data.value = value;
        entry.data.cursor_pos = value.len;
        entry.data.selection_anchor = null;
        if (entry.widget) |widget| {
            widget.kind.text_input = entry.data;
            widget.markDirty();
        }
    }

    fn changed(ctx: ?*anyopaque, _: usize, _: []const u8) void {
        const cc: *panel.ControlCenter = @ptrCast(@alignCast(ctx orelse return));
        if (cc.shortcut_autosave_timer) |timer| {
            timer.timerUpdate(2000) catch {};
        }
    }

    fn init(id: []const u8, command: []const u8) !InlineCommand {
        const owned_id = try gpa.dupe(u8, id);
        errdefer gpa.free(owned_id);
        const original = try gpa.dupe(u8, command);
        errdefer gpa.free(original);
        const value = try gpa.dupe(u8, command);

        return .{
            .id = owned_id,
            .original = original,
            .data = .{
                .value = value,
                .cursor_pos = value.len,
                .placeholder = i18n.tr("Executable and arguments"),
                .on_change = changed,
            },
        };
    }

    fn deinit(entry: *InlineCommand) void {
        gpa.free(entry.id);
        gpa.free(entry.original);
        gpa.free(entry.current().value);
    }
};

pub const Section = struct {
    // Callback targets live with their widget tree. Recording spans rebuilds
    // and owns a separate copy until it is saved or cancelled.
    arena: std.heap.ArenaAllocator = .init(gpa),
    editing_arena: std.heap.ArenaAllocator = .init(gpa),
    groups: [names.len + 2]W = undefined,
    group_count: usize = 0,
    search_field: W = .{ .kind = .container },
    search_clear: W = .{ .kind = .container },
    search_focus: bool = false,
    command_editor: ?CommandEditor = null,
    command_field: W = .{ .kind = .container },
    command_field_visible: bool = false,
    inline_commands: std.ArrayList(*InlineCommand) = .empty,
    collapsed: [names.len]bool = @splat(false),
    targets: std.ArrayList(Target) = .empty,
    editing: ?Target = null,
    candidate: ?keys.Keybind = null,
    message: []const u8 = "",
    pending: ?Pending = null,
    confirm_reset: bool = false,
    rendered_mode: DesktopMode = .canvas,
    held_keycode: ?u32 = null,
    held_sym: xkb.Keysym = .NoSymbol,
    held_mods: wlr.Keyboard.ModifierMask = .{},

    pub fn deinit(s: *Section) void {
        for (s.inline_commands.items) |entry| {
            entry.deinit();
            gpa.destroy(entry);
        }
        s.inline_commands.deinit(gpa);
        s.closeCommandEditor();
        if (s.command_field.kind == .text_input) gpa.free(s.command_field.kind.text_input.value);
        if (s.search_field.kind == .text_input) gpa.free(s.search_field.kind.text_input.value);
        s.arena.deinit();
        s.editing_arena.deinit();
    }

    fn inlineCommand(
        s: *Section,
        id: []const u8,
        command: []const u8,
    ) !*InlineCommand {
        for (s.inline_commands.items) |entry| {
            if (std.mem.eql(u8, entry.id, id)) {
                try entry.sync(command);
                return entry;
            }
        }

        const entry = try gpa.create(InlineCommand);
        errdefer gpa.destroy(entry);

        entry.* = try InlineCommand.init(id, command);
        errdefer entry.deinit();

        try s.inline_commands.append(gpa, entry);
        return entry;
    }

    fn saveInlineCommand(
        cc: *panel.ControlCenter,
        entry: *InlineCommand,
    ) !void {
        if (!entry.isDirty()) return;

        const config = &cc.server.config;
        const current = config.shortcut_commands.get(entry.id) orelse
            return error.CommandChanged;
        if (!std.mem.eql(u8, current, entry.original))
            return error.CommandChanged;

        const value = entry.current().value;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        _ = @import("../../config_runtime/actions.zig").customCommandArgs(cc.server, arena.allocator(), value) catch
            return error.InvalidCommand;

        const original = try gpa.dupe(u8, value);
        errdefer gpa.free(original);

        try saving.saveCustomCommand(
            gpa,
            cc.server.io,
            config,
            entry.id,
            value,
        );

        gpa.free(entry.original);
        entry.original = original;
    }

    pub fn commitInline(
        s: *Section,
        cc: *panel.ControlCenter,
        focused: ?*W,
    ) bool {
        const widget = focused orelse return false;
        for (s.inline_commands.items) |entry| {
            if (widget != entry.widget) continue;
            if (!entry.isDirty()) return true;

            saveInlineCommand(cc, entry) catch |err| {
                s.message = switch (err) {
                    error.InvalidCommand => i18n.tr("Invalid command"),
                    error.CommandChanged => i18n.tr("Command changed externally"),
                    else => i18n.tr("Could not save command"),
                };
                cc.refresh();
                return true;
            };

            s.message = "";
            @import("../../config_runtime/watcher.zig").reloadConfig(cc.server);
            cc.refresh();
            return true;
        }
        return false;
    }

    pub fn autosaveInline(s: *Section, cc: *panel.ControlCenter) void {
        var saved = false;
        for (s.inline_commands.items) |entry| {
            if (!entry.isDirty()) continue;
            saveInlineCommand(cc, entry) catch |err| {
                s.message = switch (err) {
                    error.InvalidCommand => i18n.tr("Invalid command"),
                    error.CommandChanged => i18n.tr("Command changed externally"),
                    else => i18n.tr("Could not save command"),
                };
                continue;
            };
            saved = true;
            @import("../../config_runtime/watcher.zig").reloadConfig(cc.server);
        }
        if (saved or s.message.len != 0) cc.refresh();
    }

    pub fn focusedInlineId(s: *Section, focused: ?*W) ?[]const u8 {
        const widget = focused orelse return null;
        for (s.inline_commands.items) |entry| {
            if (widget == entry.widget) return entry.id;
        }
        return null;
    }

    pub fn visibleInlineField(s: *Section, id: []const u8) ?*W {
        for (s.inline_commands.items) |entry| {
            if (std.mem.eql(u8, entry.id, id))
                return entry.widget;
        }
        return null;
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
        _ = s.editing_arena.reset(.free_all);
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
        const index = target.resolve(&cc.server.config) catch {
            s.cancelRecording();
            cc.refresh();
            return;
        };
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
            if (i != index and bind.action != .noop) {
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
            .record => record: {
                const target = s.editing orelse return;
                const index = target.resolve(config) catch |err| break :record err;
                if (target.slot) |slot| {
                    const candidate = s.candidate orelse return;
                    break :record saving.saveSlot(
                        gpa,
                        cc.server.io,
                        config,
                        target.mode,
                        target.action,
                        slot,
                        if (candidate.action == .noop) null else candidate,
                        target.commandSnapshot(),
                    );
                }
                break :record saving.saveMode(gpa, cc.server.io, config.path, config.activeKeybinds(), index, s.candidate orelse return, target.mode, target.commandSnapshot());
            },
            .reset => |target| reset: {
                if (target) |row| _ = row.resolve(config) catch |err| break :reset err;
                if (s.rendered_mode != config.compositor.desktop_mode) break :reset error.ConfigChanged;
                break :reset saving.saveReset(gpa, cc.server.io, config, config.compositor.desktop_mode, if (target) |row| row.action else null);
            },
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

fn nextCommandId(a: std.mem.Allocator, config: *const Config) ![]const u8 {
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
    for (s.inline_commands.items) |entry| {
        entry.capture();
    }
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
    s.rendered_mode = mode;
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
        try resetBar(s, cc, a, saving.canReset(effective, defaults, null) or saving.canResetSlots(&cc.server.config, null)),
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
        if (expanded and g == catalogue.group(.noop)) for (effective, labels) |bind, label| {
            const title = i18n.tr("Disabled shortcut.");
            if (bind.action == .noop and (filter.text(title, "") or filter.binding(label))) try appendRow(s, cc, a, &rows, title, "", .{ .action = .noop, .mode = mode }, bind, label, false, false);
        };
        if (expanded) for (actions) |action| {
            if (catalogue.group(action) != g) continue;
            var title_buf: [1024]u8 = undefined;
            var desc_buf: [8192]u8 = undefined;
            const command = if (action == .custom_command) commands.get(action.custom_command) else null;
            if (command) |value| {
                _ = try s.inlineCommand(action.custom_command, value);
            }
            const title = try a.dupe(u8, if (command != null and command.?.len != 0)
                command.?
            else
                catalogue.title(action, &title_buf));
            const description = if (command != null) "" else try a.dupe(u8, catalogue.description(action, &desc_buf));
            const matches = filter.text(title, description) or for (effective, labels) |bind, label| {
                if (keys.actionEql(bind.action, action) and filter.binding(label)) break true;
            } else false;
            if (!matches) continue;
            const target = try (Target{ .action = action, .mode = mode, .command = command }).copy(a);
            if (keys.isBuiltIn(action) or command != null) {
                if (s.command_editor) |*editor| {
                    if (editor.id != null and action == .custom_command and std.mem.eql(u8, editor.id.?, action.custom_command))
                        try rows.append(a, try commandForm(s, cc, a, editor));
                }
                const assigned = slots.resolve(
                    binds,
                    defaults,
                    action,
                    cc.server.config.storedShortcutSlots(action),
                );
                try appendSlotRow(
                    s,
                    cc,
                    a,
                    &rows,
                    title,
                    description,
                    target,
                    assigned,
                    saving.canReset(effective, defaults, action) or
                        saving.canResetSlots(&cc.server.config, action),
                );
                for (effective, labels) |bind, label| {
                    if (!slots.isOverflow(binds, action, assigned, slots.chord(bind))) continue;
                    try appendRow(
                        s,
                        cc,
                        a,
                        &rows,
                        "",
                        i18n.tr("Additional shortcut"),
                        target,
                        bind,
                        label,
                        false,
                        false,
                    );
                }
                continue;
            }
            if (s.command_editor) |*editor| {
                if (editor.id != null and action == .custom_command and std.mem.eql(u8, editor.id.?, action.custom_command))
                    try rows.append(a, try commandForm(s, cc, a, editor));
            }
            var first = true;
            for (effective, labels) |bind, label| {
                if (!keys.actionEql(bind.action, action)) continue;
                const caption = if (first) description else "";
                try appendRow(s, cc, a, &rows, if (first) title else "", caption, target, bind, label, first, first and saving.canReset(effective, defaults, action));
                first = false;
            }
            const adding = if (s.editing) |active| active.eql(target) else false;
            if (first or adding) try appendRow(s, cc, a, &rows, if (first) title else "", if (first) description else "", target, null, i18n.tr("Not assigned"), false, first and saving.canReset(effective, defaults, action));
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

fn appendSlotRow(
    s: *Section,
    cc: *panel.ControlCenter,
    a: std.mem.Allocator,
    rows: *std.ArrayList(W),
    title: []const u8,
    description: []const u8,
    action_target: Target,
    assigned: slots.Slots,
    reset: bool,
) !void {
    const t = panel.palette();
    const binds = cc.server.config.activeKeybinds();
    var controls: std.ArrayList(W) = .empty;
    var recorder: ?usize = null;

    if (action_target.action == .custom_command and action_target.command != null) {
        const entry = try s.inlineCommand(
            action_target.action.custom_command,
            action_target.command.?,
        );
        var data = entry.data;
        data.owner = cc;
        const fields = try children(a, &.{
            .{
                .name = "shortcut_command",
                .kind = .{ .text_input = data },
                .width = .{ .percent = 1 },
                .height = .{ .fixed = 36 },
            },
        });
        entry.widget = &fields[0];
        try controls.append(a, .{
            .kind = .container,
            .direction = .column,
            .width = .{ .flex = 1 },
            .children = fields,
        });
    } else {
        try controls.append(a, .{
            .kind = .container,
            .direction = .column,
            .width = .{ .flex = 1 },
            .gap = 3,
            .children = try children(a, &.{
                text(title, false),
                text(description, true),
            }),
        });
    }

    for ([_]slots.Slot{ .primary, .alternate }) |slot| {
        var target = action_target;
        target.slot = slot;
        target.assigned = assigned;
        target.chord = assigned.get(slot);
        const id = s.targets.items.len;
        try s.targets.append(a, target);

        const editing = if (s.editing) |active|
            active.eql(target)
        else
            false;
        const label = if (target.chord) |value|
            if (slots.lookup(binds, value)) |bind|
                saving.format(a, bind) catch i18n.tr("Unknown key")
            else
                i18n.tr("Not assigned")
        else
            i18n.tr("Not assigned");

        var chip = button(cc, id, label, null, edit);
        chip.name = switch (slot) {
            .primary => "shortcut_primary",
            .alternate => "shortcut_alternate",
        };
        chip.width = .{ .fixed = if (cc.panel_box.width < 660) 112 else 156 };
        if (editing) {
            chip.kind.button.variant = .primary;
            recorder = id;
        }
        try controls.append(a, chip);
    }

    const reset_id = s.targets.items.len;
    try s.targets.append(a, action_target);
    var restore = if (action_target.action == .custom_command)
        button(cc, reset_id, i18n.tr("Edit command"), .edit, editCommand)
    else
        button(cc, reset_id, i18n.tr("Restore factory bindings"), .refresh, resetClicked);
    if (action_target.action == .custom_command) {
        restore.name = "edit_command";
    } else {
        restore.name = "reset_shortcut";
        if (!reset) restore.kind.button.state = .disabled;
    }
    try controls.append(a, restore);

    try rows.append(a, .{
        .kind = .{ .rect = .{ .color = t.window_divider } },
        .height = .{ .fixed = 1 },
        .width = .{ .percent = 1 },
    });
    try rows.append(a, .{
        .kind = .container,
        .direction = .row,
        .height = .{ .fixed = 60 },
        .width = .{ .percent = 1 },
        .padding = ui.layout.Edges.xy(12, 0),
        .gap = 8,
        .@"align" = .center,
        .children = controls.items,
    });

    if (recorder) |id| {
        const prompt = if (s.message.len != 0)
            s.message
        else if (s.candidate) |candidate|
            saving.format(a, candidate) catch i18n.tr("Unknown key")
        else
            i18n.tr("Press keys to record. Esc cancels.");

        var confirm = button(
            cc,
            id,
            i18n.tr("Save shortcut"),
            .checkmark,
            confirmClicked,
        );
        confirm.name = "save";
        confirm.kind.button.variant = .primary;
        if (s.candidate == null)
            confirm.kind.button.state = .disabled;

        var clear = button(
            cc,
            id,
            i18n.tr("Clear shortcut"),
            null,
            disableClicked,
        );
        clear.name = "unassign";
        if (s.targets.items[id].chord == null)
            clear.kind.button.state = .disabled;

        var cancel_btn = button(
            cc,
            id,
            i18n.tr("Cancel"),
            .close,
            cancelClicked,
        );
        cancel_btn.name = "cancel";

        var caption = text(prompt, true);
        caption.width = .{ .flex = 1 };
        try rows.append(a, .{
            .kind = .container,
            .direction = .row,
            .height = .{ .fixed = 44 },
            .width = .{ .percent = 1 },
            .padding = ui.layout.Edges.xy(12, 0),
            .gap = 8,
            .@"align" = .center,
            .children = try children(a, &.{
                caption, clear, confirm, cancel_btn,
            }),
        });
    }
}

fn appendRow(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator, rows: *std.ArrayList(W), title: []const u8, description: []const u8, action_target: Target, bind: ?keys.Keybind, label: []const u8, add: bool, reset: bool) !void {
    const t = panel.palette();
    const id = s.targets.items.len;
    var target = action_target;
    if (bind) |binding| target.chord = keys.pack(binding.modifiers, binding.sym);
    try s.targets.append(a, target);
    const editing = if (s.editing) |active| active.eql(target) else false;
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
    const target = cc.shortcuts.targets.items[i];
    _ = target.resolve(&cc.server.config) catch return;
    openCommand(cc, target.action.custom_command) catch return;
}

fn commandChanged(p: ?*anyopaque, _: usize, _: []const u8) void {
    const cc = owner(p);
    if (cc.shortcuts.message.len == 0) return;
    cc.shortcuts.message = "";
    cc.refresh();
}

fn saveCommandClicked(p: ?*anyopaque, _: usize) void {
    const s = &owner(p).shortcuts;
    if (s.command_editor) |editor| {
        if (!editor.confirm_delete) s.pending = .save_command;
    }
}

fn requestDeleteCommand(p: ?*anyopaque, _: usize) void {
    const cc = owner(p);
    if (cc.shortcuts.command_editor) |*editor| editor.confirm_delete = true;
    cc.shortcuts.message = "";
    cc.refresh();
}

fn confirmDeleteCommand(p: ?*anyopaque, _: usize) void {
    const s = &owner(p).shortcuts;
    if (s.command_editor) |editor| {
        if (editor.confirm_delete) s.pending = .delete_command;
    }
}

fn startRecording(cc: *panel.ControlCenter, target: Target) bool {
    const s = &cc.shortcuts;
    s.cancel();
    s.editing = target.copy(s.editing_arena.allocator()) catch {
        s.cancelRecording();
        cc.refresh();
        return false;
    };
    cc.refresh();
    return true;
}

fn edit(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    const target = cc.shortcuts.targets.items[i];
    _ = target.resolve(&cc.server.config) catch return;
    _ = startRecording(cc, target);
}
fn addClicked(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    var target = cc.shortcuts.targets.items[i];
    _ = target.resolve(&cc.server.config) catch return;
    target.chord = null;
    _ = startRecording(cc, target);
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
fn confirmClicked(p: ?*anyopaque, i: usize) void {
    const s = &owner(p).shortcuts;
    if (s.editing) |active| {
        if (active.eql(s.targets.items[i])) s.pending = .record;
    }
}

fn resetClicked(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    cc.shortcuts.cancel();
    cc.shortcuts.pending = .{ .reset = cc.shortcuts.targets.items[i] };
}

fn requestReset(p: ?*anyopaque, _: usize) void {
    const cc = owner(p);
    if (cc.shortcuts.rendered_mode != cc.server.config.compositor.desktop_mode) return;
    cc.shortcuts.cancel();
    cc.shortcuts.confirm_reset = true;
    cc.refresh();
}

fn confirmReset(p: ?*anyopaque, _: usize) void {
    const cc = owner(p);
    if (!cc.shortcuts.confirm_reset) return;
    cc.shortcuts.confirm_reset = false;
    cc.shortcuts.pending = .{ .reset = null };
}

fn disableClicked(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    const target = cc.shortcuts.targets.items[i];
    const index = (target.resolve(&cc.server.config) catch return) orelse return;
    const bind = cc.server.config.activeKeybinds()[index];
    if (!startRecording(cc, target)) return;
    cc.shortcuts.candidate = .{ .sym = bind.sym, .modifiers = bind.modifiers, .action = .noop };
    cc.shortcuts.pending = .record;
}
