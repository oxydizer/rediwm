//! VT switching and activation for rediwm-dm.
//! Raw Linux syscalls with linux.errno (AGENTS.md, "Build and platform gotchas").
const std = @import("std");
const linux = std.os.linux;

pub const VT_ACTIVATE: usize = 0x5606;
pub const VT_WAITACTIVE: usize = 0x5607;

pub fn activate(vtnr: u32) !void {
    const paths = [_][*:0]const u8{ "/dev/tty0", "/dev/console" };
    var fd: i32 = -1;
    for (paths) |path| {
        const rc = linux.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                fd = @intCast(rc);
                break;
            },
            else => continue,
        }
    }
    if (fd < 0) return error.OpenTtyFailed;
    defer _ = linux.close(fd);

    const act_rc = linux.ioctl(fd, VT_ACTIVATE, vtnr);
    switch (linux.errno(act_rc)) {
        .SUCCESS => {},
        else => return error.VtActivateFailed,
    }

    const wait_rc = linux.ioctl(fd, VT_WAITACTIVE, vtnr);
    switch (linux.errno(wait_rc)) {
        .SUCCESS => {},
        else => return error.VtWaitActiveFailed,
    }
}

/// Clears the VT's text (and scrollback) and hides its cursor. Between the
/// greeter's exit and the session's first frame logind puts the VT back in
/// text mode; without this that gap shows the boot log instead of black.
/// Writing while a compositor holds the VT in graphics mode only updates the
/// hidden text buffer, so this can run ahead of the switch.
pub fn blank(vtnr: u32) !void {
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/dev/tty{d}", .{vtnr});
    const rc = linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .NOCTTY = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenTtyFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    // Home, clear screen, clear scrollback, hide cursor.
    const seq = "\x1b[H\x1b[2J\x1b[3J\x1b[?25l";
    if (linux.errno(linux.write(fd, seq, seq.len)) != .SUCCESS) return error.WriteFailed;
}
