// Central Wayland global filter for Xwayland and sandboxed clients (security-context-v1).
const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig");

pub const SandboxGroup = @import("config").sandbox_allow.SandboxGroup;
pub const GroupSet = @import("config").sandbox_allow.GroupSet;

pub const Privilege = struct {
    group: ?SandboxGroup,
};

const KV = struct { []const u8, Privilege };
pub const privileged_globals = std.StaticStringMap(Privilege).initComptime(&[_]KV{
    .{ "zwlr_screencopy_manager_v1", .{ .group = .capture } },
    .{ "ext_image_copy_capture_manager_v1", .{ .group = .capture } },
    .{ "ext_output_image_capture_source_manager_v1", .{ .group = .capture } },
    .{ "ext_foreign_toplevel_image_capture_source_manager_v1", .{ .group = .capture } },
    .{ "ext_foreign_toplevel_list_v1", .{ .group = .windows } },
    .{ "zwlr_foreign_toplevel_manager_v1", .{ .group = .windows } },
    .{ "zwlr_data_control_manager_v1", .{ .group = .clipboard } },
    .{ "ext_data_control_manager_v1", .{ .group = .clipboard } },
    .{ "zwp_virtual_keyboard_manager_v1", .{ .group = .input } },
    .{ "zwlr_virtual_pointer_manager_v1", .{ .group = .input } },
    .{ "zwp_input_method_manager_v2", .{ .group = .input_method } },
    .{ "zwlr_output_manager_v1", .{ .group = .outputs } },
    .{ "zwlr_output_power_manager_v1", .{ .group = .outputs } },
    .{ "ext_session_lock_manager_v1", .{ .group = .lock } },
    .{ "zwlr_layer_shell_v1", .{ .group = .layer_shell } },
    .{ "ext_idle_notifier_v1", .{ .group = .idle } },
    .{ "wp_security_context_manager_v1", .{ .group = null } },
    .{ "ext_workspace_manager_v1", .{ .group = .windows } },
    .{ "wp_drm_lease_device_v1", .{ .group = .outputs } },
    .{ "xwayland_shell_v1", .{ .group = null } },
});

pub fn privileged(name: []const u8) ?Privilege {
    return privileged_globals.get(name);
}

pub fn isPrivileged(name: []const u8) bool {
    return privileged(name) != null;
}

pub fn sandboxed(server: *const Server, client: *const wl.Client) bool {
    const mgr = server.security_context orelse return false;
    return mgr.lookupClient(client) != null;
}

pub fn clientAllowedGroups(server: *const Server, client: *const wl.Client) GroupSet {
    const mgr = server.security_context orelse return GroupSet.initEmpty();
    const state = mgr.lookupClient(client) orelse return GroupSet.initEmpty();
    const app_id = if (state.app_id) |s| std.mem.span(s) else return GroupSet.initEmpty();
    const engine = if (state.sandbox_engine) |s| std.mem.span(s) else null;
    return server.config.sandboxAllowGroups(app_id, engine);
}

pub fn pureFilterDecision(
    is_xwayland_decision: ?bool,
    is_sandboxed: bool,
    allowed: GroupSet,
    global_name: []const u8,
) bool {
    if (is_xwayland_decision) |v| return v;
    if (is_sandboxed) {
        if (privileged(global_name)) |priv| {
            const group = priv.group orelse return false;
            return allowed.contains(group);
        }
    }
    return true;
}

pub fn isGlobalVisible(
    server: *const Server,
    client: *const wl.Client,
    global: *const wl.Global,
) bool {
    if (server.xwayland) |xw| {
        if (xw.globalVisible(client, global)) |v| return v;
    }
    if (sandboxed(server, client)) {
        const name = std.mem.span(global.getInterface().name);
        if (privileged(name)) |priv| {
            const group = priv.group orelse return false;
            const allowed = clientAllowedGroups(server, client);
            return allowed.contains(group);
        }
    }
    return true;
}

pub fn filter(client: *const wl.Client, global: *const wl.Global, server: *Server) bool {
    return isGlobalVisible(server, client, global);
}

pub fn install(server: *Server) void {
    server.wl_server.setGlobalFilter(*Server, filter, server);
}

test "privileged table contains exactly the 20 specified interfaces" {
    try std.testing.expectEqual(@as(usize, 20), privileged_globals.kvs.len);

    // Verify groups for each
    try std.testing.expectEqual(SandboxGroup.capture, privileged("zwlr_screencopy_manager_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.capture, privileged("ext_image_copy_capture_manager_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.capture, privileged("ext_output_image_capture_source_manager_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.capture, privileged("ext_foreign_toplevel_image_capture_source_manager_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.windows, privileged("ext_foreign_toplevel_list_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.windows, privileged("zwlr_foreign_toplevel_manager_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.clipboard, privileged("zwlr_data_control_manager_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.clipboard, privileged("ext_data_control_manager_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.input, privileged("zwp_virtual_keyboard_manager_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.input, privileged("zwlr_virtual_pointer_manager_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.input_method, privileged("zwp_input_method_manager_v2").?.group.?);
    try std.testing.expectEqual(SandboxGroup.outputs, privileged("zwlr_output_manager_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.lock, privileged("ext_session_lock_manager_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.layer_shell, privileged("zwlr_layer_shell_v1").?.group.?);
    try std.testing.expectEqual(SandboxGroup.idle, privileged("ext_idle_notifier_v1").?.group.?);
    try std.testing.expect(privileged("wp_security_context_manager_v1").?.group == null);
    try std.testing.expect(privileged("xwayland_shell_v1").?.group == null);

    // Verify unprivileged globals return null
    try std.testing.expect(privileged("wl_compositor") == null);
    try std.testing.expect(privileged("wl_shm") == null);
    try std.testing.expect(privileged("xdg_wm_base") == null);
    try std.testing.expect(privileged("zwp_keyboard_shortcuts_inhibit_manager_v1") == null);
}

test "privileged table names match generated protocol interface names where available" {
    try std.testing.expectEqualStrings("ext_idle_notifier_v1", std.mem.span(wayland.server.ext.IdleNotifierV1.interface.name));
    try std.testing.expect(isPrivileged(std.mem.span(wayland.server.ext.IdleNotifierV1.interface.name)));

    try std.testing.expectEqualStrings("ext_session_lock_manager_v1", std.mem.span(wayland.server.ext.SessionLockManagerV1.interface.name));
    try std.testing.expect(isPrivileged(std.mem.span(wayland.server.ext.SessionLockManagerV1.interface.name)));
}

test "pure filter decision logic" {
    const empty_groups = GroupSet.initEmpty();

    // 1. Un-sandboxed, normal client: sees everything except when Xwayland denies
    try std.testing.expect(pureFilterDecision(null, false, empty_groups, "wl_compositor"));
    try std.testing.expect(pureFilterDecision(null, false, empty_groups, "zwlr_screencopy_manager_v1"));
    try std.testing.expect(pureFilterDecision(null, false, empty_groups, "wp_security_context_manager_v1"));

    // 2. Xwayland opinion overrides
    try std.testing.expect(!pureFilterDecision(false, false, empty_groups, "xwayland_shell_v1"));
    try std.testing.expect(pureFilterDecision(true, false, empty_groups, "xwayland_shell_v1"));

    // 3. Sandboxed client with no allowances:
    // Core and unprivileged globals visible
    try std.testing.expect(pureFilterDecision(null, true, empty_groups, "wl_compositor"));
    try std.testing.expect(pureFilterDecision(null, true, empty_groups, "xdg_wm_base"));
    try std.testing.expect(pureFilterDecision(null, true, empty_groups, "zwp_keyboard_shortcuts_inhibit_manager_v1"));

    // Privileged globals hidden
    try std.testing.expect(!pureFilterDecision(null, true, empty_groups, "zwlr_screencopy_manager_v1"));
    try std.testing.expect(!pureFilterDecision(null, true, empty_groups, "ext_image_copy_capture_manager_v1"));
    try std.testing.expect(!pureFilterDecision(null, true, empty_groups, "zwlr_data_control_manager_v1"));
    try std.testing.expect(!pureFilterDecision(null, true, empty_groups, "zwlr_foreign_toplevel_manager_v1"));
    try std.testing.expect(!pureFilterDecision(null, true, empty_groups, "ext_session_lock_manager_v1"));
    try std.testing.expect(!pureFilterDecision(null, true, empty_groups, "wp_security_context_manager_v1"));
    try std.testing.expect(!pureFilterDecision(null, true, empty_groups, "xwayland_shell_v1"));

    // 4. Sandboxed client with clipboard allowance:
    var clipboard_only = GroupSet.initEmpty();
    clipboard_only.insert(.clipboard);

    try std.testing.expect(pureFilterDecision(null, true, clipboard_only, "zwlr_data_control_manager_v1"));
    try std.testing.expect(pureFilterDecision(null, true, clipboard_only, "ext_data_control_manager_v1"));
    try std.testing.expect(!pureFilterDecision(null, true, clipboard_only, "zwlr_screencopy_manager_v1"));
    try std.testing.expect(!pureFilterDecision(null, true, clipboard_only, "ext_session_lock_manager_v1"));

    // 5. wp_security_context_manager_v1 and xwayland_shell_v1 can never be granted
    const all_groups = GroupSet.initFull();
    try std.testing.expect(!pureFilterDecision(null, true, all_groups, "wp_security_context_manager_v1"));
    try std.testing.expect(!pureFilterDecision(null, true, all_groups, "xwayland_shell_v1"));
}
