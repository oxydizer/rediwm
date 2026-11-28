//! The PTY, title, selection, and shutdown state owned by each RediTerm tab.
const std = @import("std");
const c = @import("c_gfx");
const platform = @import("platform");
const ui = @import("ui");
const model = @import("../files/terminal/model.zig");
const paint = @import("../files/terminal/paint.zig");
const App = @import("app.zig").App;
const tc = model.c;
const gpa = @import("memory").gpa;
const nowMs = ui.key_repeat.nowMs;

pub const max_tabs = 128;
const fds_per_tab = 3;
pub const poll_slots = max_tabs * fds_per_tab;
/// Time allowed for a shell to save its history, and again after a forced exit.
const hangup_ms = 750;

pub const Tab = struct {
    id: u32,
    session: ?*tc.FT = null,
    failure: ?[]const u8 = null,
    title: [256:0]u8 = @splat(0),
    selection: ?model.Selection = null,
    hangup_at: ?i64 = null,
    forced: bool = false,
    poll_index: ?usize = null,

    pub fn deinit(self: Tab) void {
        if (self.session) |session| tc.ft_free(session);
    }

    pub fn name(self: *const Tab) [:0]const u8 {
        const title = std.mem.sliceTo(&self.title, 0);
        return if (title.len > 0) title else "RediTerm";
    }

    /// The shell's OSC 0/2 title, cut to whole UTF-8 characters.
    fn refreshTitle(self: *Tab, session: *tc.FT) bool {
        const raw = std.mem.span(tc.ft_title(session));
        var len = @min(raw.len, self.title.len);
        while (len > 0 and !std.unicode.utf8ValidateSlice(raw[0..len])) len -= 1;
        const title = std.mem.trim(u8, raw[0..len], " ");
        if (std.mem.eql(u8, title, std.mem.sliceTo(&self.title, 0))) return false;
        @memset(&self.title, 0);
        @memcpy(self.title[0..title.len], title);
        return true;
    }

    fn start(self: *Tab, app: *const App, command: App.Command) void {
        const session = tc.ft_new(app.rows, app.cols) orelse {
            self.failure = "Could not allocate the terminal";
            return;
        };
        self.session = session;
        paint.applyPalette(session);
        var helper_buf: [4096]u8 = undefined;
        const helper = platform.exe.sibling(&helper_buf, "rediwm-files-terminal") orelse {
            self.failure = "The terminal helper is unavailable";
            return;
        };
        if (command) |argv|
            _ = tc.ft_start_command(session, helper, app.directory, @ptrCast(argv))
        else
            _ = tc.ft_start(session, helper, "", app.directory, false);
    }

    fn requestClose(self: *Tab, now: i64) void {
        if (self.hangup_at != null) return;
        if (self.session) |session| {
            if (tc.ft_running(session)) {
                tc.ft_close(session, false);
                self.hangup_at = now + hangup_ms;
                return;
            }
        }
        self.hangup_at = now;
    }

    fn finished(self: *Tab, now: i64) bool {
        const session = self.session orelse return self.hangup_at != null;
        if (tc.ft_exited(session)) return true;
        const at = self.hangup_at orelse return false;
        if (!tc.ft_running(session)) return true;
        if (now < at) return false;
        if (self.forced) return true;
        tc.ft_close(session, true);
        self.forced = true;
        self.hangup_at = now + hangup_ms;
        return false;
    }

    pub fn resize(self: *Tab, rows: i32, cols: i32) void {
        const session = self.session orelse return;
        if (cols != tc.ft_cols(session)) self.selection = null;
        tc.ft_resize(session, rows, cols);
    }
};

pub fn current(self: *App) ?*Tab {
    if (self.tabs.items.len == 0) return null;
    return &self.tabs.items[self.selected];
}

pub fn inputTab(self: *App) ?*Tab {
    const tab = self.current() orelse return null;
    return if (tab.hangup_at == null) tab else null;
}

fn find(self: *const App, id: u32) ?usize {
    for (self.tabs.items, 0..) |tab, i| if (tab.id == id) return i;
    return null;
}

pub fn add(self: *App, command: App.Command) void {
    if (self.closing or self.tabs.items.len == max_tabs) return;
    self.tabs.ensureUnusedCapacity(gpa, 1) catch {
        if (self.tabs.items.len == 0) self.failure = "Could not allocate the terminal";
        return;
    };
    self.leaveTab();
    while (self.next_id == 0 or find(self, self.next_id) != null) self.next_id +%= 1;
    const tab = self.tabs.addOneAssumeCapacity();
    tab.* = .{ .id = self.next_id };
    self.next_id +%= 1;
    tab.start(self, command);
    self.failure = null;
    self.selected = self.tabs.items.len - 1;
    self.viewChanged();
}

pub fn newTab(self: *App) void {
    add(self, null);
}

pub fn selectTab(self: *App, id: u32) void {
    const i = find(self, id) orelse return;
    if (i == self.selected or self.tabs.items[i].hangup_at != null) return;
    self.leaveTab();
    self.selected = i;
    self.viewChanged();
}

pub fn moveTab(self: *App, id: u32, index: u32) void {
    const from = find(self, id) orelse return;
    const to = @min(index, self.tabs.items.len - 1);
    if (from == to) return;
    const active = self.tabs.items[self.selected].id;
    const tab = self.tabs.orderedRemove(from);
    self.tabs.insertAssumeCapacity(to, tab);
    self.selected = find(self, active).?;
    self.revealTab();
    self.damageStrip();
}

pub fn closeTab(self: *App, id: u32) void {
    const i = find(self, id) orelse return;
    if (i == self.selected) self.leaveTab();
    self.tabs.items[i].requestClose(nowMs());
    self.damageStrip();
}

pub fn requestClose(self: *App) void {
    self.closing = true;
    self.leaveTab();
    const now = nowMs();
    for (self.tabs.items) |*tab| tab.requestClose(now);
    if (self.tabs.items.len == 0) self.closed = true;
}

fn remove(self: *App, i: usize) void {
    const active = i == self.selected;
    if (active) self.leaveTab();
    self.tabs.orderedRemove(i).deinit();
    if (self.tabs.items.len == 0) {
        self.closed = true;
        return;
    }
    if (i < self.selected) self.selected -= 1;
    self.selected = @min(self.selected, self.tabs.items.len - 1);
    if (active) {
        self.viewChanged();
    } else {
        self.revealTab();
        self.damageStrip();
    }
}

pub fn pollFds(self: *App, fds: []c.struct_pollfd) usize {
    var count: usize = 0;
    for (self.tabs.items) |*tab| {
        tab.poll_index = null;
        const session = tab.session orelse continue;
        tab.poll_index = count;
        fds[count] = .{ .fd = tc.ft_pty(session), .events = c.POLLIN };
        if (tc.ft_wants_write(session)) fds[count].events |= c.POLLOUT;
        fds[count + 1] = .{ .fd = tc.ft_channel(session), .events = c.POLLIN };
        if (tc.ft_wants_request(session)) fds[count + 1].events |= c.POLLOUT;
        fds[count + 2] = .{ .fd = tc.ft_exit_fd(session), .events = c.POLLIN };
        count += fds_per_tab;
    }
    return count;
}

pub fn pollReady(self: *App, fds: []const c.struct_pollfd) void {
    // Wayland may add or move tabs after pollFds. Each session keeps its
    // descriptor offset, and all removals wait until after readiness is read.
    for (self.tabs.items, 0..) |*tab, i| {
        const session = tab.session orelse continue;
        if (tab.poll_index) |index| {
            const pty = fds[index].revents;
            tc.ft_io(session, pty & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0, pty & c.POLLOUT != 0, fds[index + 1].revents != 0, fds[index + 2].revents != 0);
        }
        if (!tc.ft_changed(session)) continue;
        if (i == self.selected) self.dirty = true;
        if (tab.refreshTitle(session)) self.damageStrip();
    }
    const now = nowMs();
    var i = self.tabs.items.len;
    while (i > 0) {
        i -= 1;
        if (self.tabs.items[i].finished(now)) remove(self, i);
    }
}

pub fn timeoutMs(self: *App, now: i64) ?i64 {
    var next: ?i64 = null;
    for (self.tabs.items) |tab| if (tab.hangup_at) |at| {
        next = @min(next orelse at, at);
    };
    return if (next) |at| @max(0, at - now) else null;
}
