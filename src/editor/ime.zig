//! text-input-v3 batches are applied only to the document state advertised to the IM.
const std = @import("std");
const wl = @import("wayland").client.wl;
const zwp = @import("wayland").client.zwp;
const App = @import("app.zig").App;
const a = std.heap.c_allocator;
pub const Ime = struct {
    app: *App,
    manager: ?*zwp.TextInputManagerV3 = null,
    input: ?*zwp.TextInputV3 = null,
    entered: bool = false,
    enabled: bool = false,
    serial: u32 = 0,
    tab: usize = 0,
    revision: usize = std.math.maxInt(usize),
    cursor: usize = 0,
    anchor: usize = 0,
    before: usize = 0,
    after: usize = 0,
    commit: std.ArrayList(u8) = .empty,
    preedit: std.ArrayList(u8) = .empty,
    has_commit: bool = false,
    has_preedit: bool = false,
    waiting_for_done: bool = false,
    method_change: bool = false,
    rectangle: @import("pango.zig").Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    pub fn setup(self: *Ime, seat: *wl.Seat) !void {
        if (self.manager) |m| {
            self.input = try m.getTextInput(seat);
            self.input.?.setListener(*Ime, event, self);
        }
    }
    pub fn deinit(self: *Ime) void {
        if (self.input) |i| i.destroy();
        if (self.manager) |m| m.destroy();
        self.commit.deinit(a);
        self.preedit.deinit(a);
    }
    fn clear(self: *Ime) void {
        self.before = 0;
        self.after = 0;
        self.has_commit = false;
        self.has_preedit = false;
        self.commit.clearRetainingCapacity();
        self.preedit.clearRetainingCapacity();
    }
    fn event(_: *zwp.TextInputV3, ev: zwp.TextInputV3.Event, self: *Ime) void {
        switch (ev) {
            .enter => {
                self.entered = true;
                self.revision = std.math.maxInt(usize);
            },
            .leave => {
                self.waiting_for_done = false;
                self.entered = false;
                self.enabled = false;
                self.clear();
                self.app.preedit.clearRetainingCapacity();
                self.app.dirty = true;
            },
            .preedit_string => |e| {
                self.preedit.clearRetainingCapacity();
                if (e.text) |s| {
                    const bytes = std.mem.span(s);
                    if (bytes.len <= 4096 and std.unicode.utf8ValidateSlice(bytes)) self.preedit.appendSlice(a, bytes) catch {};
                }
                self.has_preedit = true;
            },
            .commit_string => |e| {
                self.commit.clearRetainingCapacity();
                if (e.text) |s| {
                    const bytes = std.mem.span(s);
                    if (bytes.len <= 4096 and std.unicode.utf8ValidateSlice(bytes)) self.commit.appendSlice(a, bytes) catch {};
                }
                self.has_commit = true;
            },
            .delete_surrounding_text => |e| {
                self.before = e.before_length;
                self.after = e.after_length;
            },
            .done => |e| {
                defer self.clear();
                self.waiting_for_done = e.serial != self.serial;
                if (!self.enabled or self.app.closed or self.app.tabId() != self.tab or self.app.editRevision() != self.revision or self.app.document().cursor != self.cursor or self.app.document().anchor != self.anchor) return;
                self.app.preedit.clearRetainingCapacity();
                self.app.dirty = true;
                self.method_change = true;
                const d = self.app.document();
                if (self.before > 0 or self.after > 0) {
                    const selected = d.selection();
                    if (self.before > selected[0] or self.after > d.text.items.len - selected[1]) return;
                    const start = selected[0] - self.before;
                    const end = selected[1] + self.after;
                    if ((start < d.text.items.len and d.text.items[start] & 0xc0 == 0x80) or (end < d.text.items.len and d.text.items[end] & 0xc0 == 0x80)) return;
                    d.anchor = start;
                    d.cursor = end;
                }
                if (self.has_commit or self.before > 0 or self.after > 0 or (self.has_preedit and self.preedit.items.len > 0 and d.cursor != d.anchor)) self.app.pasteText(self.commit.items);
                if (self.has_preedit) {
                    self.app.preedit.clearRetainingCapacity();
                    self.app.preedit.appendSlice(a, self.preedit.items) catch {};
                    self.app.dirty = true;
                }
            },
        }
    }
    pub fn sync(self: *Ime, titlebar: i32) void {
        const input = self.input orelse return;
        const enabled = self.entered and !self.app.menu_open and !self.app.find_open and self.app.close_tab == null;
        if (!enabled) {
            if (self.enabled) {
                input.disable();
                input.commit();
                self.serial +%= 1;
                self.clear();
                self.app.preedit.clearRetainingCapacity();
            }
            self.enabled = false;
            return;
        }
        if (self.waiting_for_done) return;
        const d = self.app.document();
        var rect = self.app.inputRectangle();
        rect.y += titlebar;
        if (self.enabled and self.tab == self.app.tabId() and self.revision == d.revision and self.cursor == d.cursor and self.anchor == d.anchor and std.meta.eql(rect, self.rectangle)) return;
        if (!self.enabled or self.tab != self.app.tabId()) {
            input.enable();
            self.app.preedit.clearRetainingCapacity();
            self.clear();
        }
        self.enabled = true;
        self.tab = self.app.tabId();
        self.revision = d.revision;
        self.cursor = d.cursor;
        self.anchor = d.anchor;
        const selected = d.selection();
        // Protocol requires the whole selection. Re-enable without surrounding
        // text when it exceeds the message limit, rather than advertising a false anchor.
        if (selected[1] - selected[0] > 3800) input.enable();
        if (selected[1] - selected[0] <= 3800) {
            const spare = (3800 - (selected[1] - selected[0])) / 2;
            var start = selected[0] -| spare;
            while (start < d.text.items.len and d.text.items[start] & 0xc0 == 0x80) start += 1;
            var end = @min(d.text.items.len, start + 3800);
            while (end < d.text.items.len and d.text.items[end] & 0xc0 == 0x80) end -= 1;
            var surrounding: [4000:0]u8 = @splat(0);
            @memcpy(surrounding[0 .. end - start], d.text.items[start..end]);
            input.setSurroundingText(&surrounding, @intCast(d.cursor - start), @intCast(d.anchor - start));
        }
        input.setTextChangeCause(if (self.method_change) .input_method else .other);
        self.method_change = false;
        input.setContentType(.{ .multiline = true }, .normal);
        self.rectangle = rect;
        input.setCursorRectangle(rect.x, rect.y, @max(1, rect.width), @max(1, rect.height));
        input.commit();
        self.serial +%= 1;
    }
};
