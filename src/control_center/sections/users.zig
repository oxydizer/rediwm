//! Account overview and automatic-login settings.
const std = @import("std");
const Child = @import("../../session/child.zig");
const panel = @import("../panel.zig");
const model = @import("../../accounts/model.zig");
const validation = @import("../../accounts/validation.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});
const secret_input = ui.widgets.secret_input;
extern fn rediwm_polkit_secret_new() ?*anyopaque;
extern fn rediwm_polkit_secret_free(*anyopaque) void;
extern fn rediwm_polkit_clear([*]u8, usize) void;

const Form = enum { none, add, details, password, delete_confirm };
const max_groups = 256;
const curated_groups = [_][]const u8{ "video", "audio", "input", "network", "uucp", "dialout", "lp", "docker", "libvirt", "plugdev" };

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    message: []const u8 = "",
    unlocked: bool = false,
    auth: ?*AuthRequest = null,
    form: Form = .none,
    target: [32]u8 = undefined,
    target_len: usize = 0,
    password_memory: ?*anyopaque = null,
    confirm_memory: ?*anyopaque = null,
    password: secret_input.Input = .{ .storage = @constCast(&[_]u8{}) },
    confirm_password: secret_input.Input = .{ .storage = @constCast(&[_]u8{}) },
    new_full_name: ?*W = null,
    new_username: ?*W = null,
    details_full_name: ?*W = null,
    details_name_draft: [256]u8 = undefined,
    details_name_len: usize = 0,
    details_name_dirty: bool = false,
    password_field: ?*W = null,
    new_admin: bool = false,
    username_manual: bool = false,
    show_all_groups: bool = false,
    group_count: usize = 0,
    group_names: [max_groups][65]u8 = undefined,
    group_name_lens: [max_groups]usize = undefined,
    group_checked: [max_groups]bool = undefined,
    groups_truncated: bool = false,
    group_gids: [max_groups]u32 = undefined,
    group_admin: [max_groups]bool = undefined,
    group_target: [32]u8 = undefined,
    group_target_len: usize = 0,
};

const AuthRequest = struct {
    allocator: std.mem.Allocator,
    cc: ?*panel.ControlCenter,
    io: std.Io,
    child: *Child,
    is_authorization: bool,
};

fn text(value: []const u8, size: f32, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
}

fn buildCard(a: std.mem.Allocator, children: []const W) !W {
    return .{ .kind = .{ .rect = .{ .color = ui.theme.global.app_item, .radius = 9, .border_width = 1, .border_color = ui.theme.global.app_item_border } }, .direction = .column, .padding = ui.layout.Edges.all(14), .gap = 9, .width = .{ .percent = 1 }, .children = try a.dupe(W, children) };
}

pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    freeTextFields(s);
    _ = s.arena.reset(.retain_capacity);
    s.new_full_name = null;
    s.new_username = null;
    s.details_full_name = null;
    s.password_field = null;
    s.root = tree(s, cc, s.arena.allocator()) catch blk: {
        // No field of a tree that was never shown may keep focus or text.
        freeTextFields(s);
        s.password_field = null;
        break :blk panel.outOfMemory();
    };
}

fn tree(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const snapshot = model.load(a, cc.server.io) catch {
        return buildCard(a, &.{ text("Could not read login accounts.", 14, false), text("Check NSS and /etc/login.defs.", 12, true) });
    };
    const rows = try a.alloc(W, snapshot.users.len + 32);
    var count: usize = 0;
    const header = try a.alloc(W, 2);
    header[0] = text("Accounts", 16, false);
    header[0].width = .{ .flex = 1 };
    header[1] = .{ .kind = .{ .button = .{
        .label = if (s.unlocked) "Lock" else "Unlock",
        .leading_icon = if (s.unlocked) .checkmark else .lock,
        .owner = cc,
        .on_click = lockClicked,
        .state = if (s.auth != null) .disabled else .idle,
    } }, .height = .{ .fixed = 34 } };
    rows[count] = .{ .kind = .container, .direction = .row, .gap = 10, .@"align" = .center, .width = .{ .percent = 1 }, .children = header };
    count += 1;
    rows[count] = text(if (s.message.len > 0) s.message else if (s.auth != null) "Waiting for authentication…" else if (s.unlocked) "Account settings are unlocked for this session." else "Unlock to make account changes.", 12, true);
    count += 1;
    if (snapshot.users.len == 0) {
        rows[count] = text("No login accounts were found.", 13, true);
        count += 1;
    } else {
        for (snapshot.users, 0..) |user, user_index| {
            const full_name = if (user.full_name.len == 0) user.name else user.full_name;
            const kind = if (user.admin) "Administrator" else "Standard";
            const row = try a.alloc(W, 4);
            row[0] = .{ .kind = .avatar, .width = .{ .fixed = 28 }, .height = .{ .fixed = 28 } };
            row[1] = .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = try a.dupe(W, &.{ text(full_name, 14, false), text(user.name, 12, true) }) };
            row[2] = text(if (user.is_current) "You" else kind, 11, true);
            row[3] = actionButton(cc, if (user.local) "Details" else "Read only", user_index, detailsClicked, !user.local or !s.unlocked or s.auth != null or s.form != .none);
            rows[count] = .{ .kind = .container, .direction = .row, .gap = 12, .@"align" = .center, .width = .{ .percent = 1 }, .height = .{ .fixed = 44 }, .children = row };
            count += 1;
        }
    }
    rows[count] = actionButton(cc, "Add user…", 0, addUserClicked, !s.unlocked or s.auth != null or s.form != .none);
    count += 1;
    switch (s.form) {
        .add => {
            rows[count] = try buildAddForm(s, cc, a);
            count += 1;
        },
        .details => {
            if (findUser(snapshot.users, s.target[0..s.target_len])) |user| {
                rows[count] = try buildDetailsForm(s, cc, a, user, snapshot.groups);
                count += 1;
            }
        },
        .password => {
            rows[count] = try buildPasswordForm(s, cc, a);
            count += 1;
        },
        .delete_confirm => {
            rows[count] = try buildDeleteForm(s, cc, a);
            count += 1;
        },
        .none => {},
    }
    rows[count] = text("Automatic login", 16, false);
    count += 1;
    const user_labels = try a.alloc([]const u8, snapshot.users.len + 1);
    user_labels[0] = "Off";
    var selected_user: usize = 0;
    for (snapshot.users, 0..) |user, i| {
        user_labels[i + 1] = user.name;
        if (snapshot.autologin_user) |name| {
            if (std.mem.eql(u8, name, user.name)) selected_user = i + 1;
        }
    }
    rows[count] = try selectRow(cc, a, "User", "autologin_user", user_labels, selected_user, s.auth != null or s.form != .none or !s.unlocked or snapshot.sessions.len == 0, autologinUserChanged);
    count += 1;
    const session_labels = try a.alloc([]const u8, @max(snapshot.sessions.len, 1));
    var selected_session: usize = 0;
    if (snapshot.sessions.len == 0) {
        session_labels[0] = "No sessions available";
    } else {
        for (snapshot.sessions, 0..) |session, i| {
            session_labels[i] = session.name;
            if (snapshot.autologin_session) |id| {
                if (std.mem.eql(u8, id, session.id)) selected_session = i;
            }
        }
    }
    rows[count] = try selectRow(cc, a, "Session", "autologin_session", session_labels, selected_session, s.auth != null or s.form != .none or !s.unlocked or snapshot.sessions.len == 0 or snapshot.autologin_user == null, autologinSessionChanged);
    count += 1;
    rows[count] = text("Takes effect at next boot. The keyring will not unlock automatically.", 12, true);
    count += 1;
    return buildCard(a, rows[0..count]);
}

fn freeTextFields(s: *Section) void {
    inline for (.{ "new_full_name", "new_username", "details_full_name" }) |field| {
        if (@field(s.*, field)) |widget| {
            if (widget.kind == .text_input) gpa.free(widget.kind.text_input.value);
            @field(s.*, field) = null;
        }
    }
}

fn clearSecrets(s: *Section) void {
    if (s.password_memory) |memory| {
        s.password.clear();
        rediwm_polkit_secret_free(memory);
    }
    if (s.confirm_memory) |memory| {
        s.confirm_password.clear();
        rediwm_polkit_secret_free(memory);
    }
    s.password_memory = null;
    s.confirm_memory = null;
    s.password = .{ .storage = @constCast(&[_]u8{}) };
    s.confirm_password = .{ .storage = @constCast(&[_]u8{}) };
}

pub fn deinit(cc: *panel.ControlCenter) void {
    const s = &cc.users;
    cancelAuthorization(cc);
    freeTextFields(s);
    clearSecrets(s);
    s.arena.deinit();
}

fn selectRow(cc: *panel.ControlCenter, a: std.mem.Allocator, title: []const u8, name: []const u8, labels: []const []const u8, selected: usize, disabled: bool, callback: *const fn (?*anyopaque, usize, usize) void) !W {
    var row = W{ .name = name, .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .gap = 12, .children = try a.dupe(W, &.{
        text(title, 13, false),
        .{ .kind = .{ .select = .{ .labels = labels, .selected = selected, .disabled = disabled, .owner = cc, .on_change = callback } }, .width = .{ .fixed = 190 } },
    }) };
    row.width = .{ .percent = 1 };
    return row;
}

fn actionButton(cc: *panel.ControlCenter, label_text: []const u8, id: usize, callback: *const fn (?*anyopaque, usize) void, disabled: bool) W {
    return .{ .kind = .{ .button = .{
        .label = label_text,
        .owner = cc,
        .id = id,
        .on_click = callback,
        .state = if (disabled) .disabled else .idle,
    } }, .height = .{ .fixed = 34 } };
}

fn textInputRow(cc: *panel.ControlCenter, a: std.mem.Allocator, title: []const u8, value: []const u8, placeholder: []const u8, callback: *const fn (?*anyopaque, usize, []const u8) void, slot: *?*W) !W {
    const children = try a.alloc(W, 2);
    children[0] = text(title, 13, false);
    children[1] = .{ .kind = .{ .text_input = .{
        .field = .{},
        .placeholder = placeholder,
        .value = try gpa.dupe(u8, value),
        .cursor_pos = value.len,
        .owner = cc,
        .on_change = callback,
    } }, .width = .{ .flex = 1 }, .height = .{ .fixed = 44 } };
    slot.* = &children[1];
    return .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .gap = 12, .width = .{ .percent = 1 }, .children = children };
}

fn secretInputRow(a: std.mem.Allocator, title: []const u8, input: *secret_input.Input, placeholder: []const u8) !W {
    const children = try a.alloc(W, 2);
    children[0] = text(title, 13, false);
    children[1] = .{ .kind = .{ .secret_input = .{ .field = .{}, .placeholder = placeholder, .input = input } }, .width = .{ .flex = 1 }, .height = .{ .fixed = 44 } };
    return .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .gap = 12, .width = .{ .percent = 1 }, .children = children };
}

fn secretInputRowFocus(a: std.mem.Allocator, title: []const u8, input: *secret_input.Input, placeholder: []const u8, slot: *?*W) !W {
    const row = try secretInputRow(a, title, input, placeholder);
    slot.* = &row.children[1];
    return row;
}

fn formButtons(a: std.mem.Allocator, cc: *panel.ControlCenter, left_label: []const u8, left_id: usize, left_callback: *const fn (?*anyopaque, usize) void, right_label: []const u8, right_id: usize, right_callback: *const fn (?*anyopaque, usize) void) !W {
    const buttons = try a.alloc(W, 2);
    buttons[0] = actionButton(cc, left_label, left_id, left_callback, cc.users.auth != null);
    buttons[1] = actionButton(cc, right_label, right_id, right_callback, cc.users.auth != null);
    return .{ .kind = .container, .direction = .row, .justify = .end, .@"align" = .center, .gap = 10, .width = .{ .percent = 1 }, .children = buttons };
}

fn buildAddForm(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    if (s.password_memory == null or s.confirm_memory == null) {
        return buildCard(a, &.{text("Could not allocate locked password storage.", 13, true)});
    }
    const items = try a.alloc(W, 7);
    items[0] = text("Add user", 16, false);
    items[1] = try textInputRow(cc, a, "Full name", "", "Full name", addFullNameChanged, &s.new_full_name);
    items[2] = try textInputRow(cc, a, "Username", "", "lowercase username", addUsernameChanged, &s.new_username);
    items[3] = try secretInputRowFocus(a, "Password", &s.password, "Enter password", &s.password_field);
    items[4] = try secretInputRow(a, "Confirm", &s.confirm_password, "Confirm password");
    items[5] = .{ .kind = .{ .checkbox = .{ .label = "Administrator", .checked = s.new_admin, .owner = cc, .on_change = addAdminChanged } } };
    items[6] = try formButtons(a, cc, "Cancel", 0, cancelFormClicked, "Create user", 0, createUserClicked);
    return buildCard(a, items);
}

fn buildDetailsForm(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator, user: model.User, groups: []const model.Group) !W {
    populateGroupChoices(s, user, groups);
    const visible_count = visibleGroupCount(s);
    const items = try a.alloc(W, 9);
    items[0] = text(try std.fmt.allocPrint(a, "Account details · {s}", .{user.name}), 16, false);
    const displayed_full_name = if (s.details_name_dirty) s.details_name_draft[0..s.details_name_len] else user.full_name;
    items[1] = try textInputRow(cc, a, "Full name", displayed_full_name, "Full name", detailsNameChanged, &s.details_full_name);
    const type_labels = [_][]const u8{ "Standard", "Administrator" };
    items[2] = try selectRow(cc, a, "Account type", "account_type", &type_labels, @intFromBool(user.admin), s.auth != null, accountTypeChanged);
    const actions = try a.alloc(W, 3);
    actions[0] = actionButton(cc, "Save name", 0, saveFullNameClicked, s.auth != null);
    actions[1] = actionButton(cc, "Change password…", 0, changePasswordClicked, s.auth != null);
    actions[2] = actionButton(cc, "Delete user…", 0, beginDeleteClicked, s.auth != null);
    items[3] = .{ .kind = .container, .direction = .row, .justify = .space_between, .gap = 8, .children = actions };
    const group_header = try a.alloc(W, 2);
    group_header[0] = text("Groups", 16, false);
    group_header[1] = actionButton(cc, if (s.show_all_groups) "Show curated" else "Show all groups", 0, groupVisibilityClicked, s.auth != null);
    items[4] = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = group_header };
    const group_widgets = try a.alloc(W, visible_count);
    var row_count: usize = 0;
    for (0..s.group_count) |i| {
        const name = s.group_names[i][0..s.group_name_lens[i]];
        if (!s.show_all_groups and !isCuratedGroup(name, s.group_admin[i])) continue;
        group_widgets[row_count] = .{ .name = name, .kind = .{ .checkbox = .{
            .label = if (user.primary_gid == s.group_gids[i]) std.fmt.allocPrint(a, "{s} · primary", .{name}) catch name else name,
            .checked = s.group_checked[i],
            .disabled = s.auth != null or user.primary_gid == s.group_gids[i],
            .on_change = groupChecked,
            .owner = cc,
            .id = i,
        } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 34 } };
        row_count += 1;
    }
    items[5] = .{ .name = "user_groups", .kind = .container, .direction = .column, .gap = 4, .children = group_widgets[0..row_count] };
    items[6] = text(if (s.groups_truncated) "Some groups cannot be safely shown; group changes are disabled." else "", 12, true);
    items[7] = try formButtons(a, cc, "Save groups", 0, saveGroupsClicked, "Done", 0, cancelFormClicked);
    items[7].children[0].kind.button.state = if (s.auth != null or s.groups_truncated) .disabled else .idle;
    items[8] = text(user.home, 12, true);
    return buildCard(a, items);
}

fn buildPasswordForm(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    if (s.password_memory == null or s.confirm_memory == null) return buildCard(a, &.{text("Could not allocate locked password storage.", 13, true)});
    const items = try a.alloc(W, 4);
    items[0] = text(try std.fmt.allocPrint(a, "Change password · {s}", .{s.target[0..s.target_len]}), 16, false);
    items[1] = try secretInputRowFocus(a, "New password", &s.password, "Enter new password", &s.password_field);
    items[2] = try secretInputRow(a, "Confirm", &s.confirm_password, "Confirm new password");
    items[3] = try formButtons(a, cc, "Cancel", 0, cancelFormClicked, "Save password", 0, changePasswordSubmit);
    return buildCard(a, items);
}

fn buildDeleteForm(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const items = try a.alloc(W, 3);
    items[0] = text(try std.fmt.allocPrint(a, "Delete {s}?", .{s.target[0..s.target_len]}), 16, false);
    items[1] = text("Choose whether to keep the home folder or remove its files.", 12, true);
    items[2] = try formButtons(a, cc, "Keep home", 0, deleteKeepHomeClicked, "Delete files", 0, deleteFilesClicked);
    return buildCard(a, items);
}

fn targetName(s: *const Section) []const u8 {
    return s.target[0..s.target_len];
}

fn setTarget(s: *Section, name: []const u8) bool {
    if (name.len == 0 or name.len > s.target.len) return false;
    @memcpy(s.target[0..name.len], name);
    s.target_len = name.len;
    return true;
}

fn findUser(users: []const model.User, name: []const u8) ?model.User {
    for (users) |user| if (std.mem.eql(u8, user.name, name)) return user;
    return null;
}

fn isCuratedGroup(name: []const u8, admin: bool) bool {
    if (admin) return true;
    for (curated_groups) |curated| if (std.mem.eql(u8, curated, name)) return true;
    return false;
}

fn populateGroupChoices(s: *Section, user: model.User, groups: []const model.Group) void {
    const same_user = s.group_target_len == s.target_len and std.mem.eql(u8, s.group_target[0..s.group_target_len], targetName(s));
    const old_names = s.group_names;
    const old_lens = s.group_name_lens;
    const old_checked = s.group_checked;
    const old_count = s.group_count;
    s.group_count = 0;
    s.groups_truncated = false;
    for (groups) |group| {
        if (!group.local) continue;
        if (!validation.validGroupName(group.name) or s.group_count == max_groups) {
            s.groups_truncated = true;
            continue;
        }
        const index = s.group_count;
        @memcpy(s.group_names[index][0..group.name.len], group.name);
        s.group_name_lens[index] = group.name.len;
        s.group_gids[index] = group.gid;
        s.group_admin[index] = group.admin;
        s.group_checked[index] = containsName(user.groups, group.name);
        if (same_user) {
            for (0..old_count) |old| {
                if (old_lens[old] == group.name.len and std.mem.eql(u8, old_names[old][0..old_lens[old]], group.name)) {
                    s.group_checked[index] = old_checked[old];
                    break;
                }
            }
        }
        s.group_count += 1;
    }
    @memcpy(s.group_target[0..s.target_len], targetName(s));
    s.group_target_len = s.target_len;
}

fn visibleGroupCount(s: *const Section) usize {
    var count: usize = 0;
    for (0..s.group_count) |i| {
        if (s.show_all_groups or isCuratedGroup(s.group_names[i][0..s.group_name_lens[i]], s.group_admin[i])) count += 1;
    }
    return count;
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn groupChecked(owner: ?*anyopaque, id: usize, checked: bool) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (id >= cc.users.group_count) return;
    cc.users.group_checked[id] = checked;
}

fn groupVisibilityClicked(owner: ?*anyopaque, _: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    cc.users.show_all_groups = !cc.users.show_all_groups;
    cc.refresh();
}

fn saveGroupsClicked(owner: ?*anyopaque, _: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    var groups: std.ArrayList([]const u8) = .empty;
    defer groups.deinit(gpa);
    for (0..cc.users.group_count) |i| {
        if (!cc.users.group_checked[i]) continue;
        groups.append(gpa, cc.users.group_names[i][0..cc.users.group_name_lens[i]]) catch {
            cc.users.message = "Could not prepare the group update.";
            cc.refresh();
            return;
        };
    }
    startHelper(cc, .{ .op = "set-groups", .username = targetName(&cc.users), .groups = groups.items }, false) catch {
        cc.users.message = "Could not start the request.";
        cc.refresh();
    };
}

fn openSecrets(s: *Section) !void {
    if (s.password_memory != null and s.confirm_memory != null) {
        clearSecrets(s);
    }
    const password_memory = rediwm_polkit_secret_new() orelse return error.SecretMemory;
    errdefer rediwm_polkit_secret_free(password_memory);
    const confirm_memory = rediwm_polkit_secret_new() orelse return error.SecretMemory;
    errdefer rediwm_polkit_secret_free(confirm_memory);
    s.password_memory = password_memory;
    s.confirm_memory = confirm_memory;
    s.password = .{ .storage = @as([*]u8, @ptrCast(password_memory))[0..510] };
    s.confirm_password = .{ .storage = @as([*]u8, @ptrCast(confirm_memory))[0..510] };
}

fn addUserClicked(owner: ?*anyopaque, _: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (!cc.users.unlocked) return;
    openSecrets(&cc.users) catch {
        cc.users.message = "Could not allocate locked password storage.";
        cc.refresh();
        return;
    };
    cc.users.form = .add;
    cc.users.new_admin = false;
    cc.users.username_manual = false;
    cc.users.message = "";
    cc.refresh();
}

fn detailsClicked(owner: ?*anyopaque, id: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (!cc.users.unlocked) return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snapshot = model.load(arena.allocator(), cc.server.io) catch return;
    if (id >= snapshot.users.len or !snapshot.users[id].local) return;
    if (!setTarget(&cc.users, snapshot.users[id].name)) return;
    cc.users.details_name_len = @min(snapshot.users[id].full_name.len, cc.users.details_name_draft.len);
    @memcpy(cc.users.details_name_draft[0..cc.users.details_name_len], snapshot.users[id].full_name[0..cc.users.details_name_len]);
    cc.users.details_name_dirty = false;
    cc.users.form = .details;
    cc.users.message = "";
    cc.refresh();
}

fn cancelFormClicked(owner: ?*anyopaque, _: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    closeForm(&cc.users);
    cc.refresh();
}

fn closeForm(s: *Section) void {
    clearSecrets(s);
    s.form = .none;
    s.target_len = 0;
    s.group_target_len = 0;
    s.new_admin = false;
    s.username_manual = false;
    s.details_name_dirty = false;
    s.details_name_len = 0;
    s.message = "";
}

pub fn escapeForm(cc: *panel.ControlCenter) bool {
    if (cc.users.form == .none) return false;
    closeForm(&cc.users);
    cc.refresh();
    return true;
}

pub fn initialFormFocus(s: *const Section) ?*W {
    return switch (s.form) {
        .add => s.new_full_name,
        .details => s.details_full_name,
        .password => s.password_field,
        .delete_confirm, .none => null,
    };
}

fn addFullNameChanged(owner: ?*anyopaque, _: usize, value: []const u8) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    const s = &cc.users;
    if (s.username_manual) return;
    const field = s.new_username orelse return;
    var derived: [32]u8 = undefined;
    var len: usize = 0;
    for (value) |byte| {
        if (len == derived.len) break;
        const lower = std.ascii.toLower(byte);
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9') or lower == '_') {
            derived[len] = lower;
            len += 1;
        } else if ((lower == ' ' or lower == '-' or lower == '.') and len > 0 and derived[len - 1] != '_') {
            derived[len] = '_';
            len += 1;
        }
    }
    while (len > 0 and derived[len - 1] == '_') len -= 1;
    if (len > 0 and derived[0] >= '0' and derived[0] <= '9') {
        if (len < derived.len) {
            std.mem.copyBackwards(u8, derived[1 .. len + 1], derived[0..len]);
            derived[0] = '_';
            len += 1;
        }
    }
    replaceTextValue(field, derived[0..len]);
}

fn addUsernameChanged(owner: ?*anyopaque, _: usize, _: []const u8) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    cc.users.username_manual = true;
}

fn ignoreTextChanged(_: ?*anyopaque, _: usize, _: []const u8) void {}

fn detailsNameChanged(owner: ?*anyopaque, _: usize, value: []const u8) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    const s = &cc.users;
    if (value.len > s.details_name_draft.len) return;
    @memcpy(s.details_name_draft[0..value.len], value);
    s.details_name_len = value.len;
    s.details_name_dirty = true;
}

fn replaceTextValue(widget: *W, value: []const u8) void {
    if (widget.kind != .text_input) return;
    const owned = gpa.dupe(u8, value) catch return;
    gpa.free(widget.kind.text_input.value);
    widget.kind.text_input.value = owned;
    widget.kind.text_input.cursor_pos = owned.len;
    widget.kind.text_input.selection_anchor = null;
    widget.markDirty();
}

fn addAdminChanged(owner: ?*anyopaque, _: usize, enabled: bool) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    cc.users.new_admin = enabled;
}

fn createUserClicked(owner: ?*anyopaque, _: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    const s = &cc.users;
    const full_widget = s.new_full_name orelse return;
    const username_widget = s.new_username orelse return;
    const full = full_widget.kind.text_input.value;
    const username = username_widget.kind.text_input.value;
    const password = s.password.value();
    const confirmation = s.confirm_password.value();
    if (!validation.validUsername(username) or !validation.validFullName(full)) {
        s.message = "Enter a valid username and full name.";
        cc.refresh();
        return;
    }
    if (!validation.validPassword(password) or !std.mem.eql(u8, password, confirmation)) {
        s.message = "Enter matching passwords.";
        cc.refresh();
        return;
    }
    startHelper(cc, .{ .op = "create", .username = username, .fullname = full, .password = password, .administrator = s.new_admin }, false) catch {
        s.message = "Could not start the request.";
        cc.refresh();
        return;
    };
    closeForm(s);
    cc.refresh();
}

fn saveFullNameClicked(owner: ?*anyopaque, _: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    const field = cc.users.details_full_name orelse return;
    if (field.kind != .text_input or !validation.validFullName(field.kind.text_input.value)) {
        cc.users.message = "Enter a valid full name.";
        cc.refresh();
        return;
    }
    startHelper(cc, .{ .op = "set-fullname", .username = targetName(&cc.users), .fullname = field.kind.text_input.value }, false) catch {
        cc.users.message = "Could not start the request.";
        cc.refresh();
    };
}

fn accountTypeChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (index > 1) return;
    startHelper(cc, .{ .op = "set-type", .username = targetName(&cc.users), .administrator = index == 1 }, false) catch {
        cc.users.message = "Could not start the request.";
        cc.refresh();
    };
}

fn changePasswordClicked(owner: ?*anyopaque, _: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    openSecrets(&cc.users) catch {
        cc.users.message = "Could not allocate locked password storage.";
        cc.refresh();
        return;
    };
    cc.users.form = .password;
    cc.refresh();
}

fn changePasswordSubmit(owner: ?*anyopaque, _: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    const s = &cc.users;
    const password = s.password.value();
    if (!validation.validPassword(password) or !std.mem.eql(u8, password, s.confirm_password.value())) {
        s.message = "Enter matching passwords.";
        cc.refresh();
        return;
    }
    startHelper(cc, .{ .op = "set-password", .username = targetName(s), .password = password }, false) catch {
        s.message = "Could not start the request.";
        cc.refresh();
        return;
    };
    closeForm(s);
    cc.refresh();
}

fn beginDeleteClicked(owner: ?*anyopaque, _: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    cc.users.form = .delete_confirm;
    cc.refresh();
}

fn deleteKeepHomeClicked(owner: ?*anyopaque, _: usize) void {
    deleteUser(owner, false);
}

fn deleteFilesClicked(owner: ?*anyopaque, _: usize) void {
    deleteUser(owner, true);
}

fn deleteUser(owner: ?*anyopaque, delete_home: bool) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    const s = &cc.users;
    startHelper(cc, .{ .op = "delete", .username = targetName(s), .delete_home = delete_home }, false) catch {
        s.message = "Could not start the request.";
        cc.refresh();
        return;
    };
    closeForm(s);
    cc.refresh();
}

fn lockClicked(owner: ?*anyopaque, _: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (cc.users.unlocked) {
        cc.users.unlocked = false;
        closeForm(&cc.users);
        cc.refresh();
        return;
    }
    startHelper(cc, .{ .op = "authorize" }, true) catch {
        cc.users.message = "Could not start the authentication request.";
        cc.refresh();
    };
}

fn autologinUserChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (!cc.users.unlocked) return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snapshot = model.load(arena.allocator(), cc.server.io) catch return;
    if (index == 0) {
        startHelper(cc, .{ .op = "set-autologin", .username = "", .session = "" }, false) catch {
            cc.users.message = "Could not start the request.";
            cc.refresh();
        };
        return;
    }
    if (index > snapshot.users.len) return;
    const user = snapshot.users[index - 1];
    const session = blk: {
        if (snapshot.autologin_session) |selected| {
            for (snapshot.sessions) |candidate| {
                if (std.mem.eql(u8, candidate.id, selected)) break :blk candidate.id;
            }
        }
        if (snapshot.sessions.len == 0) return;
        break :blk snapshot.sessions[0].id;
    };
    startHelper(cc, .{ .op = "set-autologin", .username = user.name, .session = session }, false) catch {
        cc.users.message = "Could not start the request.";
        cc.refresh();
    };
}

fn autologinSessionChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (!cc.users.unlocked) return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snapshot = model.load(arena.allocator(), cc.server.io) catch return;
    const username = snapshot.autologin_user orelse return;
    if (index >= snapshot.sessions.len) return;
    startHelper(cc, .{ .op = "set-autologin", .username = username, .session = snapshot.sessions[index].id }, false) catch {
        cc.users.message = "Could not start the request.";
        cc.refresh();
    };
}

fn startHelper(cc: *panel.ControlCenter, request: anytype, is_authorization: bool) !void {
    if (cc.users.auth != null) return;
    const req = try gpa.create(AuthRequest);
    errdefer gpa.destroy(req);
    req.* = .{ .allocator = gpa, .cc = cc, .io = cc.server.io, .child = undefined, .is_authorization = is_authorization };
    const encoded = try std.json.Stringify.valueAlloc(gpa, request, .{});
    const contains_secret = comptime @hasField(@TypeOf(request), "password");
    defer {
        if (contains_secret) rediwm_polkit_clear(encoded.ptr, encoded.len);
        gpa.free(encoded);
    }
    var sockets: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &sockets) != 0) return error.SocketPairFailed;
    defer {
        if (sockets[0] >= 0) _ = c.close(sockets[0]);
        if (sockets[1] >= 0) _ = c.close(sockets[1]);
    }

    const executable = if (c.access("/usr/bin/pkexec", c.X_OK) == 0) "/usr/bin/pkexec" else "/bin/pkexec";
    var child = try std.process.spawn(cc.server.io, .{
        .argv = &.{ executable, "--disable-internal-agent", "/usr/local/bin/rediwm-accounts-helper" },
        .stdin = .{ .file = .{ .handle = sockets[0], .flags = .{ .nonblocking = false } } },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer {
        child.kill(cc.server.io);
    }
    _ = c.close(sockets[0]);
    sockets[0] = -1;
    var written: usize = 0;
    while (written < encoded.len) {
        const n = c.send(sockets[1], encoded.ptr + written, encoded.len - written, c.MSG_NOSIGNAL);
        if (n <= 0) return error.RequestWriteFailed;
        written += @intCast(n);
    }
    _ = c.close(sockets[1]);
    sockets[1] = -1;
    req.child = try Child.watch(gpa, cc.server.wl_server.getEventLoop(), child.id.?, req, authReady);
    cc.users.auth = req;
    cc.users.message = "";
    cc.refresh();
}

fn authReady(owner: ?*anyopaque, _: *Child, status: ?u32) void {
    const req: *AuthRequest = @ptrCast(@alignCast(owner.?));
    if (req.cc) |cc| {
        if (cc.users.auth == req) {
            cc.users.auth = null;
            if (status != null and status.? == 0) {
                if (req.is_authorization) {
                    cc.users.unlocked = true;
                    cc.users.message = "";
                } else {
                    cc.users.message = "Changes saved.";
                }
            } else {
                if (req.is_authorization) {
                    cc.users.unlocked = false;
                    cc.users.message = "Authentication was cancelled or denied.";
                } else {
                    cc.users.message = "No changes were made. Authentication was cancelled or the request failed.";
                }
            }
            cc.refresh();
        }
    }
    req.allocator.destroy(req);
}

/// Stop a pending pkexec when its Settings window closes.
pub fn cancelAuthorization(cc: *panel.ControlCenter) void {
    if (cc.users.auth) |req| {
        cc.users.auth = null;
        req.cc = null;
        req.child.signal(.TERM);
        req.child.detach();
        req.allocator.destroy(req);
    }
}
