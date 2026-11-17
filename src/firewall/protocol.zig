//! Requests from Settings to `rediwm-firewall-helper`, one per run, on stdin.
//! The helper answers with a `Reply` on stdout. Everything in a request is
//! untrusted: the helper validates each field before it reaches a tool.
const model = @import("model.zig");

pub const Op = enum {
    /// Read everything (the `read` polkit action).
    status,
    /// Recent blocked connections from the kernel log or pflog (`read`).
    blocks,
    /// Changes nothing; proves the password for the `manage` action.
    authorize,
    enable,
    disable,
    set_defaults,
    add_rule,
    remove_rule,
    set_option,
    set_trust,
    lockdown,
    /// Keep a change that is waiting to revert.
    confirm,
    /// Re-apply our saved table or anchor (NetworkManager dispatcher, boot).
    sync,
};

pub const Option = enum { ping, logging, ssh_limit, boot };

pub const Request = struct {
    op: Op = .status,
    rule: ?model.Rule = null,
    incoming: ?model.Policy = null,
    outgoing: ?model.Policy = null,
    forward: ?model.Policy = null,
    option: ?Option = null,
    on: bool = false,
    logging: ?model.Logging = null,
    /// `set_trust`: a NetworkManager connection uuid, or an interface.
    uuid: []const u8 = "",
    iface: []const u8 = "",
    trust: model.Trust = .public,
    /// Undo the change after this many seconds unless `confirm` arrives.
    revert_after: u32 = 0,
    /// `enable` with no manager: which one to set up (`own` by default).
    backend: model.Backend = .own,
};

pub const Reply = struct {
    status: model.Status = .{},
    /// Why the operation failed, in words for the page; null on success.
    failure: ?[]const u8 = null,
};

/// Which operations the read-only polkit action may run.
pub fn readOnly(op: Op) bool {
    return op == .status or op == .blocks;
}
