//! Legacy application side of the input-method-v2 relay. V1 identifies its
//! field and surface explicitly and supplies its own edit serial.
const std = @import("std");
const wayland = @import("wayland").server;
const wl = wayland.wl;
const zwp = wayland.zwp;
const wlr = @import("wlroots");
const Relay = @import("text_input.zig");
const gpa = @import("../main.zig").gpa;
const Self = @This();

relay: *Relay,
resource: *zwp.TextInputV1,
link: wl.list.Link = undefined,
target: ?*wlr.Surface = null,
entered: bool = false,
has_preedit: bool = false,
serial: u32 = 0,
surface_destroy: wl.Listener(*wlr.Surface) = .init(surfaceDestroyed),
current: wlr.TextInputV3.State = .{
    .surrounding = .{ .text = null, .cursor = 0, .anchor = 0 },
    .text_change_cause = 0,
    .content_type = .{ .hint = 0x7, .purpose = 0 }, // V1 default hints and normal purpose.
    .cursor_rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    .features = .{ .surrounding_text = true, .content_type = true },
},

pub fn createGlobal(relay: *Relay) !*wl.Global {
    return wl.Global.create(relay.server.wl_server, zwp.TextInputManagerV1, 1, *Relay, relay, bind);
}

fn bind(client: *wl.Client, relay: *Relay, version: u32, id: u32) void {
    const manager = zwp.TextInputManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    manager.setHandler(*Relay, managerRequest, null, relay);
}

fn managerRequest(manager: *zwp.TextInputManagerV1, request: zwp.TextInputManagerV1.Request, relay: *Relay) void {
    const client = manager.getClient();
    const input = gpa.create(Self) catch {
        client.postNoMemory();
        return;
    };
    const resource = zwp.TextInputV1.create(client, manager.getVersion(), request.create_text_input.id) catch {
        gpa.destroy(input);
        client.postNoMemory();
        return;
    };
    input.* = .{ .resource = resource, .relay = relay };
    relay.v1_inputs.append(input);
    resource.setHandler(*Self, handleRequest, resourceDestroyed, input);
}

fn ownsSeat(self: *Self, seat: *wl.Seat) bool {
    const client = wlr.Seat.Client.fromWlSeat(seat) orelse return false;
    return client.client == self.resource.getClient() and client.seat == self.relay.server.input.seat;
}

fn handleRequest(_: *zwp.TextInputV1, request: zwp.TextInputV1.Request, self: *Self) void {
    switch (request) {
        .activate => |args| {
            if (self.relay.blocked() or !self.ownsSeat(args.seat) or args.surface.getClient() != self.resource.getClient()) return;
            const surface = wlr.Surface.fromWlSurface(args.surface);
            if (self.target != surface) {
                self.release(true);
                self.target = surface;
                surface.events.destroy.add(&self.surface_destroy);
            }
            self.link.remove();
            self.relay.v1_inputs.prepend(self);
            self.relay.syncFocus();
        },
        .deactivate => |args| if (self.ownsSeat(args.seat)) self.release(true),
        .set_surrounding_text => |args| {
            const context = surroundingWindow(std.mem.span(args.text), args.cursor, args.anchor);
            const copy = gpa.dupeSentinel(u8, context.text, 0) catch {
                self.resource.getClient().postNoMemory();
                return;
            };
            self.freeText();
            self.current.surrounding = .{ .text = copy.ptr, .cursor = context.cursor, .anchor = context.anchor };
            self.stateChanged();
        },
        .set_content_type => |args| {
            // The ten v1 hint bits have the same meanings in v3.
            self.current.content_type = .{ .hint = @as(u32, @bitCast(args.hint)) & 0x3ff, .purpose = purposeV3(args.purpose) };
            self.stateChanged();
        },
        .set_cursor_rectangle => |args| {
            self.current.cursor_rectangle = .{ .x = args.x, .y = args.y, .width = args.width, .height = args.height };
            self.current.features.cursor_rectangle = true;
            if (self.relay.isActive(.{ .v1 = self })) self.relay.updatePopups();
        },
        .commit_state => |args| {
            self.serial = args.serial;
            self.stateChanged();
        },
        .reset => {
            if (!self.relay.isActive(.{ .v1 = self })) return;
            self.clearPreedit();
            self.relay.deactivate();
            self.relay.activate(.{ .v1 = self });
        },
        // Input-method-v2 has no messages for these optional client requests.
        .set_preferred_language, .invoke_action, .show_input_panel, .hide_input_panel => {},
    }
}

fn stateChanged(self: *Self) void {
    // V1 setters take effect without commit_state (as used by Chromium).
    if (self.relay.isActive(.{ .v1 = self })) self.relay.sendState();
}

/// V3 inserted PIN before date, shifting four otherwise identical purposes.
fn purposeV3(purpose: zwp.TextInputV1.ContentPurpose) u32 {
    const mapped: zwp.TextInputV3.ContentPurpose = switch (purpose) {
        inline .normal, .alpha, .digits, .number, .phone, .url, .email, .name, .password, .date, .time, .datetime, .terminal => |tag| @field(zwp.TextInputV3.ContentPurpose, @tagName(tag)),
        else => .normal,
    };
    return @intCast(@backingInt(mapped));
}

const Surrounding = struct { text: []const u8 = "", cursor: u32 = 0, anchor: u32 = 0 };
fn boundary(text: []const u8, offset: usize) bool {
    return offset == text.len or (offset < text.len and text[offset] & 0xc0 != 0x80);
}

/// Input-method-v2 accepts 4000 bytes including the whole selection. Keep
/// both offsets relative to the excerpt and cut only between UTF-8 characters.
fn surroundingWindow(text: []const u8, cursor: u32, anchor: u32) Surrounding {
    const limit = 4000;
    const left = @min(cursor, anchor);
    const selection = @max(cursor, anchor) - left;
    if (selection > limit or !boundary(text, cursor) or !boundary(text, anchor) or !std.unicode.utf8ValidateSlice(text)) return .{};
    var start = @min(left -| (limit - selection) / 2, text.len -| limit);
    while (!boundary(text, start)) start += 1;
    var end = @min(start + limit, text.len);
    while (!boundary(text, end)) end -= 1;
    return .{ .text = text[start..end], .cursor = @intCast(cursor - start), .anchor = @intCast(anchor - start) };
}

pub fn deliver(self: *Self, state: *const wlr.InputMethodV2.State) void {
    const preedit: [*:0]const u8 = state.preedit.text orelse "";
    const deleting = state.delete.before_length != 0 or state.delete.after_length != 0;
    if (deleting or state.commit_text != null or preedit[0] == 0) self.clearPreedit();
    var deleted = false;
    if (deleting) {
        const index = std.math.cast(i32, -@as(i64, state.delete.before_length));
        const length = std.math.cast(u32, @as(u64, state.delete.before_length) + state.delete.after_length);
        if (index != null and length != null) {
            self.resource.sendDeleteSurroundingText(index.?, length.?);
            deleted = true;
        }
    }
    // A v1 delete is buffered until commit_string, even for a deletion alone.
    if (state.commit_text != null or deleted) self.resource.sendCommitString(self.serial, state.commit_text orelse "");
    if (preedit[0] != 0) {
        const text = std.mem.span(preedit);
        const begin = state.preedit.cursor_begin;
        const end = state.preedit.cursor_end;
        const has_cursor = begin >= 0 and boundary(text, @intCast(begin));
        if (has_cursor and end >= 0 and end != begin and boundary(text, @intCast(end))) {
            self.resource.sendPreeditStyling(@intCast(@min(begin, end)), @intCast(@max(begin, end) - @min(begin, end)), .selection);
        }
        self.resource.sendPreeditCursor(if (has_cursor) begin else -1);
        self.resource.sendPreeditString(self.serial, preedit, "");
        self.has_preedit = true;
    }
}

pub fn clearPreedit(self: *Self) void {
    if (self.has_preedit) self.resource.sendPreeditString(self.serial, "", "");
    self.has_preedit = false;
}

pub fn release(self: *Self, notify: bool) void {
    if (self.relay.isActive(.{ .v1 = self })) self.relay.deactivate();
    if (self.entered and notify) {
        self.clearPreedit();
        self.resource.sendLeave();
    }
    if (self.target != null) self.surface_destroy.link.remove();
    self.target = null;
    self.entered = false;
}

fn surfaceDestroyed(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const self: *Self = @fieldParentPtr("surface_destroy", listener);
    self.release(true);
}

fn freeText(self: *Self) void {
    if (self.current.surrounding.text) |text| gpa.free(std.mem.span(text));
}

fn resourceDestroyed(_: *zwp.TextInputV1, self: *Self) void {
    self.release(false);
    self.link.remove();
    self.freeText();
    gpa.destroy(self);
}

test "v1 surrounding text fits the IME message and preserves byte offsets" {
    const characters: [2000][3]u8 = @splat("界".*);
    const text = std.mem.asBytes(&characters);
    const excerpt = surroundingWindow(text, 3003, 3000);
    try std.testing.expect(excerpt.text.len <= 4000 and excerpt.text.len >= 3996);
    try std.testing.expect(std.unicode.utf8ValidateSlice(excerpt.text));
    try std.testing.expectEqualStrings("界", excerpt.text[excerpt.anchor..excerpt.cursor]);
    const tail = surroundingWindow(text, 5997, 6000);
    try std.testing.expectEqual(tail.text.len, tail.anchor);
    try std.testing.expectEqualStrings("界", tail.text[tail.cursor..tail.anchor]);
    for ([_]Surrounding{
        surroundingWindow(text, 0, 4002),
        surroundingWindow(text, 1, 0),
        surroundingWindow(text, 0, std.math.maxInt(u32)),
        surroundingWindow("\xff", 0, 0),
    }) |invalid| try std.testing.expectEqualDeep(Surrounding{}, invalid);
}
