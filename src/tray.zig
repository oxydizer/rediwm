//! StatusNotifier watcher/host. All bus traffic is asynchronous and updates are
//! signal driven. Requests carry numeric identities, never borrowed item pointers.
//! Protocol: https://specifications.freedesktop.org/status-notifier-item/latest-single/
const std = @import("std");
const wlr = @import("wlroots");
const col = @import("color.zig");
const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("Server.zig");
const Taskbar = @import("Taskbar.zig");
const Buffer = @import("panel_buffer.zig").PanelBuffer;
const text = @import("ui").text;
const theme = @import("ui").theme;
const gpa = @import("main.zig").gpa;
const watcher = "org.kde.StatusNotifierWatcher";
const path = "/StatusNotifierWatcher";
const item_iface = "org.kde.StatusNotifierItem";
const props_iface = "org.freedesktop.DBus.Properties";
const menu_iface = "com.canonical.dbusmenu";
const bus = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";
const max_items = 64;

pub const Item = struct {
    id: u64,
    service: []const u8,
    path: []const u8,
    owner: []const u8 = "",
    icon: []const u8 = "",
    icon_theme_path: []const u8 = "",
    attention_icon: []const u8 = "",
    menu: []const u8 = "",
    pixels: []u32 = &.{},
    width: i32 = 0,
    height: i32 = 0,
    attention_pixels: []u32 = &.{},
    attention_width: i32 = 0,
    attention_height: i32 = 0,
    interface: []const u8 = item_iface,
    passive: bool = false,
    attention: bool = false,
    is_menu: bool = false,
    ready: bool = false,
    fetching: bool = false,
    refresh_again: bool = false,

    fn deinit(item: *Item) void {
        inline for (.{ "service", "path", "owner", "icon", "icon_theme_path", "attention_icon", "menu" }) |field| {
            const s = @field(item, field);
            if (s.len > 0) gpa.free(s);
        }
        if (item.pixels.len > 0) gpa.free(item.pixels);
        if (item.attention_pixels.len > 0) gpa.free(item.attention_pixels);
    }
};

const Request = struct { tray: *Tray, id: u64, epoch: u64 = 0 };
const Row = struct {
    id: i32,
    label: []const u8,
    enabled: bool = true,
    separator: bool = false,
    submenu: bool = false,
    toggle: bool = false,
    checked: bool = false,
};

pub const Tray = struct {
    server: *Server,
    conn: *dbus.Connection,
    items: std.ArrayList(Item) = .empty,
    next_id: u64 = 1,
    generation: u64 = 1,
    host_name: []const u8 = "",
    owns_watcher: bool = false,
    closing: bool = false,
    menu_item: u64 = 0,
    menu_epoch: u64 = 0,
    menu_parent: i32 = 0,
    parents: std.ArrayList(i32) = .empty,
    rows: std.ArrayList(Row) = .empty,
    menu_node: ?*wlr.SceneBuffer = null,
    menu_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    menu_bounds: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    menu_scale: f32 = 1,
    selected: ?usize = null,
    row_offset: usize = 0,
    menu_fetching: bool = false,
    menu_again: bool = false,

    pub fn create(server: *Server, conn: *dbus.Connection) !*Tray {
        const self = try gpa.create(Tray);
        self.* = .{ .server = server, .conn = conn };
        // Once handlers are registered their owner must live until connection
        // teardown, including initialization failures.
        server.tray = self;
        self.host_name = try std.fmt.allocPrint(gpa, "org.kde.StatusNotifierHost-RediWM-{d}", .{std.c.getpid()});
        _ = try conn.requestName(self.host_name, 4, null, ignoreReply);
        inline for (.{ watcher, "org.freedesktop.StatusNotifierWatcher" }) |iface| {
            try conn.register(.{ .path = path, .interface = iface, .member = "RegisterStatusNotifierItem", .owner = self, .callback = registerItem });
            try conn.register(.{ .path = path, .interface = iface, .member = "RegisterStatusNotifierHost", .owner = self, .callback = registerHost });
        }
        inline for (.{ "Get", "GetAll" }) |member| try conn.register(.{ .path = path, .interface = props_iface, .member = member, .owner = self, .callback = properties });
        _ = try conn.subscribe(.{ .sender = bus, .path = bus_path, .interface = bus, .member = "NameOwnerChanged", .owner = self, .callback = nameChanged }, null, null);
        _ = try conn.subscribe(.{ .interface = "org.freedesktop.StatusNotifierItem", .owner = self, .callback = itemChanged }, null, null);
        _ = try conn.subscribe(.{ .interface = item_iface, .owner = self, .callback = itemChanged }, null, null);
        _ = try conn.subscribe(.{ .interface = props_iface, .member = "PropertiesChanged", .owner = self, .callback = itemChanged }, null, null);
        _ = try conn.subscribe(.{ .interface = menu_iface, .owner = self, .callback = menuChanged }, null, null);
        _ = try conn.subscribe(.{ .interface = watcher, .owner = self, .callback = watcherChanged }, null, null);
        try conn.register(.{ .path = path, .interface = "org.freedesktop.DBus.Introspectable", .member = "Introspect", .owner = self, .callback = introspect });
        _ = try conn.requestName(watcher, 4, self, acquired);
        return self;
    }

    /// Called after the shared connection closes and drains pending callbacks.
    pub fn deinit(self: *Tray) void {
        self.closeMenu();
        for (self.items.items) |*item| item.deinit();
        self.items.deinit(gpa);
        self.rows.deinit(gpa);
        self.parents.deinit(gpa);
        if (self.host_name.len > 0) gpa.free(self.host_name);
        gpa.destroy(self);
    }

    pub fn changed(self: *Tray) void {
        if (self.closing) return;
        self.generation +%= 1;
        var it = self.server.outputs.iterator(.forward);
        while (it.next()) |output| if (output.taskbar) |bar| {
            bar.notifyToplevelsChanged();
        };
        self.server.scheduleFrames();
    }

    fn find(self: *Tray, id: u64) ?*Item {
        for (self.items.items) |*item| if (item.id == id) return item;
        return null;
    }

    pub fn visibleCount(self: *Tray) usize {
        var count: usize = 0;
        for (self.items.items) |item| if (item.ready and !item.passive) {
            count += 1;
        };
        return count;
    }

    pub fn visibleItem(self: *Tray, index: usize) ?*Item {
        var n: usize = 0;
        for (self.items.items) |*item| {
            if (!item.ready or item.passive) continue;
            if (n == index) return item;
            n += 1;
        }
        return null;
    }

    fn request(self: *Tray, id: u64) !*Request {
        const req = try gpa.create(Request);
        req.* = .{ .tray = self, .id = id, .epoch = self.menu_epoch };
        return req;
    }

    fn add(self: *Tray, service: []const u8, object_path: []const u8) !void {
        if (!wire.validPath(object_path) or service.len == 0) return error.InvalidItem;
        for (self.items.items) |item| if (std.mem.eql(u8, item.service, service) and std.mem.eql(u8, item.path, object_path)) return;
        if (self.items.items.len >= max_items) return error.TooManyItems;
        const s = try gpa.dupe(u8, service);
        errdefer gpa.free(s);
        const p = try gpa.dupe(u8, object_path);
        errdefer gpa.free(p);
        const id = self.next_id;
        self.next_id += 1;
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        try body.string(service);
        const req = try self.request(id);
        errdefer gpa.destroy(req);
        try self.items.append(gpa, .{ .id = id, .service = s, .path = p });
        errdefer _ = self.items.pop();
        _ = try self.conn.call(bus, bus_path, bus, "GetNameOwner", "s", &body, req, resolved, 3000);
    }

    fn remove(self: *Tray, id: u64) void {
        for (self.items.items, 0..) |*item, i| {
            if (item.id != id) continue;
            if (self.menu_item == id) self.closeMenu();
            if (self.owns_watcher and item.owner.len > 0) self.itemSignal("StatusNotifierItemUnregistered", item);
            item.deinit();
            _ = self.items.orderedRemove(i);
            self.changed();
            return;
        }
    }

    fn itemSignal(self: *Tray, member: []const u8, item: *Item) void {
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        const full = std.fmt.allocPrint(gpa, "{s}{s}", .{ item.service, item.path }) catch return;
        defer gpa.free(full);
        body.string(full) catch return;
        self.conn.signal(path, watcher, member, "s", &body) catch {};
        self.conn.signal(path, "org.freedesktop.StatusNotifierWatcher", member, "s", &body) catch {};
    }

    fn refresh(self: *Tray, item: *Item) void {
        if (self.closing or item.owner.len == 0) return;
        if (item.fetching) {
            item.refresh_again = true;
            return;
        }
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        body.string(item.interface) catch return;
        const req = self.request(item.id) catch return;
        _ = self.conn.call(item.owner, item.path, props_iface, "GetAll", "s", &body, req, gotProperties, 3000) catch {
            gpa.destroy(req);
            return;
        };
        item.fetching = true;
    }

    pub fn click(self: *Tray, index: usize, button: u32, bar: *Taskbar, x: i32, y: i32) void {
        const item = self.visibleItem(index) orelse return;
        if (button == 0x111 or (button == 0x110 and item.is_menu)) {
            if (item.menu.len > 0 and !std.mem.eql(u8, item.menu, "/")) {
                self.closeMenu();
                self.menu_item = item.id;
                self.menu_scale = bar.wlr_output.scale;
                self.menu_bounds = bar.box;
                if (@import("Output.zig").fromWlr(bar.wlr_output)) |out| self.menu_bounds = out.usableBox();
                self.menu_box.x = x;
                self.menu_box.y = bar.box.y;
                self.showLevel(0);
                return;
            }
            self.invoke(item, "ContextMenu", x, y);
        } else if (button == 0x112) {
            self.invoke(item, "SecondaryActivate", x, y);
        } else if (button == 0x110) self.invoke(item, "Activate", x, y);
    }

    fn invoke(self: *Tray, item: *Item, member: []const u8, x: i32, y: i32) void {
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        body.int(i32, x) catch return;
        body.int(i32, y) catch return;
        _ = self.conn.call(item.owner, item.path, item.interface, member, "ii", &body, null, null, 3000) catch {};
    }

    pub fn scroll(self: *Tray, index: usize, delta: i32, horizontal: bool) void {
        const item = self.visibleItem(index) orelse return;
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        // Wayland axis positive means down; SNI positive means up.
        body.int(i32, -delta) catch return;
        body.string(if (horizontal) "horizontal" else "vertical") catch return;
        _ = self.conn.call(item.owner, item.path, item.interface, "Scroll", "is", &body, null, null, 3000) catch {};
    }

    pub fn closeMenu(self: *Tray) void {
        self.menu_epoch +%= 1;
        self.menu_item = 0;
        self.menu_fetching = false;
        self.menu_again = false;
        if (self.menu_node) |node| node.node.destroy();
        self.menu_node = null;
        self.clearRows();
        self.parents.clearRetainingCapacity();
        self.selected = null;
    }

    fn clearRows(self: *Tray) void {
        for (self.rows.items) |row| gpa.free(row.label);
        self.rows.clearRetainingCapacity();
    }

    fn showLevel(self: *Tray, parent: i32) void {
        self.menu_epoch +%= 1;
        self.menu_parent = parent;
        self.menu_fetching = false;
        self.menu_again = false;
        self.row_offset = 0;
        self.selected = null;
        self.clearRows();
        if (self.menu_node) |node| {
            node.node.destroy();
            self.menu_node = null;
        }
        const item = self.find(self.menu_item) orelse return;
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        body.int(i32, parent) catch return;
        const req = self.request(item.id) catch return;
        _ = self.conn.call(item.owner, item.menu, menu_iface, "AboutToShow", "i", &body, req, aboutToShow, 3000) catch {
            gpa.destroy(req);
            self.fetchMenu();
            return;
        };
    }

    fn fetchMenu(self: *Tray) void {
        if (self.closing) return;
        if (self.menu_fetching) {
            self.menu_again = true;
            return;
        }
        const item = self.find(self.menu_item) orelse return;
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        body.int(i32, self.menu_parent) catch return;
        body.int(i32, 1) catch return;
        const a = body.beginArray(4) catch return;
        body.endArray(a) catch return;
        const req = self.request(item.id) catch return;
        _ = self.conn.call(item.owner, item.menu, menu_iface, "GetLayout", "iias", &body, req, gotMenu, 3000) catch {
            gpa.destroy(req);
            return;
        };
        self.menu_fetching = true;
    }

    fn pageSize(self: *Tray) usize {
        return @intCast(@max(1, @divTrunc(self.menu_bounds.height - 16, 30)));
    }

    pub fn menuContains(self: *Tray, x: f64, y: f64) bool {
        const b = self.menu_box;
        return self.menu_node != null and x >= @as(f64, @floatFromInt(b.x)) and y >= @as(f64, @floatFromInt(b.y)) and x < @as(f64, @floatFromInt(b.x + b.width)) and y < @as(f64, @floatFromInt(b.y + b.height));
    }

    pub fn menuMotion(self: *Tray, x: f64, y: f64) void {
        const selected: ?usize = if (self.menuContains(x, y)) @as(usize, @intFromFloat(@max(0, y - @as(f64, @floatFromInt(self.menu_box.y)) - 8))) / 30 + self.row_offset else null;
        const valid = if (selected != null and selected.? < self.rows.items.len) selected else null;
        if (self.selected == valid) return;
        self.selected = valid;
        self.paintMenu();
    }

    pub fn menuScroll(self: *Tray, delta: f64) void {
        const max_offset = self.rows.items.len -| self.pageSize();
        self.row_offset = if (delta > 0) @min(max_offset, self.row_offset + 1) else self.row_offset -| 1;
        self.selected = null;
        self.paintMenu();
    }

    pub fn menuClick(self: *Tray, x: f64, y: f64, button: u32) void {
        if (!self.menuContains(x, y)) {
            self.closeMenu();
            return;
        }
        if (button != 0x110) return;
        self.menuMotion(x, y);
        self.activateSelected();
    }

    pub fn key(self: *Tray, sym: u32) void {
        switch (sym) {
            0xff1b => self.closeMenu(), // Escape
            0xff51 => self.back(),
            0xff0d, 0xff53, 0x20 => self.activateSelected(),
            0xff52, 0xff54 => {
                if (self.rows.items.len == 0) return;
                const n = self.rows.items.len;
                var idx = self.selected orelse (if (sym == 0xff54) n - 1 else 0);
                for (0..n) |_| {
                    idx = if (sym == 0xff54) (idx + 1) % n else (idx + n - 1) % n;
                    if (self.rows.items[idx].enabled and !self.rows.items[idx].separator) break;
                }
                self.selected = idx;
                if (idx < self.row_offset) self.row_offset = idx;
                if (idx >= self.row_offset + self.pageSize()) self.row_offset = idx + 1 - self.pageSize();
                self.paintMenu();
            },
            else => {},
        }
    }

    fn back(self: *Tray) void {
        const parent = self.parents.pop() orelse {
            self.closeMenu();
            return;
        };
        self.showLevel(parent);
    }

    fn activateSelected(self: *Tray) void {
        const idx = self.selected orelse return;
        if (idx >= self.rows.items.len) return;
        const row = self.rows.items[idx];
        if (!row.enabled or row.separator) return;
        if (row.id == -1) {
            self.back();
            return;
        }
        if (row.submenu) {
            if (self.parents.items.len >= 32) return;
            self.parents.append(gpa, self.menu_parent) catch return;
            self.showLevel(row.id);
            return;
        }
        const item = self.find(self.menu_item) orelse return;
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        body.int(i32, row.id) catch return;
        body.string("clicked") catch return;
        body.variant("i") catch return;
        body.int(i32, 0) catch return;
        body.uint32(@truncate(@as(u64, @bitCast(@import("ui").anim.nowMs())))) catch return;
        _ = self.conn.call(item.owner, item.menu, menu_iface, "Event", "isvu", &body, null, null, 3000) catch {};
        self.closeMenu();
    }

    fn paintMenu(self: *Tray) void {
        if (self.rows.items.len == 0 or self.menu_item == 0 or self.closing) return;
        self.row_offset = @min(self.row_offset, self.rows.items.len -| self.pageSize());
        const count = @min(self.rows.items.len - self.row_offset, self.pageSize());
        const width = @min(280, self.menu_bounds.width);
        const height: i32 = @intCast(count * 30 + 16);
        if (width <= 0) return;
        self.menu_box.width = width;
        self.menu_box.height = height;
        self.menu_box.x = std.math.clamp(self.menu_box.x, self.menu_bounds.x, self.menu_bounds.x + self.menu_bounds.width - width);
        self.menu_box.y = if (self.server.config.compositor.taskbar_position == .top) self.menu_bounds.y else self.menu_bounds.y + self.menu_bounds.height - height;
        const buf = Buffer.create(width, height, self.menu_scale) catch return;
        defer buf.base.drop();
        const colors = theme.global;
        const bg = argb(colors.window_bg);
        const h = colors.surface_hover;
        const b = colors.window_bg;
        const hover = argb(.{ h[0] * h[3] + b[0] * (1 - h[3]), h[1] * h[3] + b[1] * (1 - h[3]), h[2] * h[3] + b[2] * (1 - h[3]), 1 });
        const radius = @min(7.0, @as(f32, @floatFromInt(width)) / 2);
        for (buf.pixels, 0..) |*pixel, i| {
            const x = (@as(f32, @floatFromInt(i % @as(usize, @intCast(buf.width)))) + 0.5) / self.menu_scale;
            const y = (@as(f32, @floatFromInt(i / @as(usize, @intCast(buf.width)))) + 0.5) / self.menu_scale;
            const d = @import("chrome.zig").sdRoundedBox(x, y, 0, 0, @floatFromInt(width), @floatFromInt(height), radius);
            const coverage = std.math.clamp(0.5 - d * self.menu_scale, 0, 1);
            pixel.* = scalePixel(bg, coverage);
        }
        for (self.rows.items[self.row_offset..][0..count], 0..) |row, i| {
            const y: i32 = @intCast(8 + i * 30);
            if (self.selected == i + self.row_offset and row.enabled and !row.separator) {
                const top: usize = @intFromFloat(@as(f32, @floatFromInt(y)) * self.menu_scale);
                const bottom: usize = @intFromFloat(@as(f32, @floatFromInt(y + 30)) * self.menu_scale);
                @memset(buf.pixels[top * @as(usize, @intCast(buf.width)) .. @min(buf.pixels.len, bottom * @as(usize, @intCast(buf.width)))], hover);
            }
            const fg = colors.window_fg;
            const color: text.Color = .{ .r = fg[0], .g = fg[1], .b = fg[2], .a = if (row.enabled) fg[3] else fg[3] * 0.4 };
            text.draw(buf.pixels, buf.width, buf.height, .{ .x = 30, .y = y, .w = width - 58, .h = 30 }, if (row.separator) "──────────────────" else row.label, color, self.menu_scale, .manrope, 13) catch {};
            if (row.checked or row.submenu or row.id == -1) text.draw(buf.pixels, buf.width, buf.height, .{ .x = if (row.submenu) width - 24 else 9, .y = y, .w = 20, .h = 30 }, if (row.submenu) "›" else if (row.id == -1) "‹" else "✓", color, self.menu_scale, .manrope, 14) catch {};
        }
        const node = self.menu_node orelse blk: {
            const node = self.server.overlay_tree.createSceneBuffer(null) catch return;
            node.setFilterMode(.bilinear);
            self.menu_node = node;
            break :blk node;
        };
        node.setBuffer(&buf.base);
        node.setDestSize(width, height);
        node.node.setPosition(self.menu_box.x, self.menu_box.y);
        node.node.raiseToTop();
        self.server.scheduleFrames();
    }
};

fn argb(c: [4]f32) u32 {
    return col.Straight.fromRgba(c).argb();
}

fn asTray(owner: ?*anyopaque) *Tray {
    return @ptrCast(@alignCast(owner.?));
}
fn asRequest(owner: ?*anyopaque) *Request {
    return @ptrCast(@alignCast(owner.?));
}
fn replace(dest: *[]const u8, value: []const u8) !void {
    const next = if (value.len > 0) try gpa.dupe(u8, value) else "";
    if (dest.len > 0) gpa.free(dest.*);
    dest.* = next;
}

fn acquired(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self = asTray(owner);
    var msg = result catch return;
    if (msg.kind != .method_return) return;
    const code = msg.body.uint32() catch return;
    self.owns_watcher = code == 1 or code == 4;
    if (self.owns_watcher) {
        _ = conn.requestName("org.freedesktop.StatusNotifierWatcher", 4, null, ignoreReply) catch {};
        var empty: wire.Writer = .{ .allocator = gpa };
        conn.signal(path, watcher, "StatusNotifierHostRegistered", "", &empty) catch {};
    } else {
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        body.string(self.host_name) catch return;
        _ = conn.call(watcher, path, watcher, "RegisterStatusNotifierHost", "s", &body, null, null, 3000) catch {};
        body.bytes.clearRetainingCapacity();
        body.string(watcher) catch return;
        body.string("RegisteredStatusNotifierItems") catch return;
        _ = conn.call(watcher, path, props_iface, "Get", "ss", &body, self, existingItems, 3000) catch {};
    }
}

fn existingItems(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self = asTray(owner);
    var msg = result catch return;
    if (msg.kind != .method_return) return;
    const sig = msg.body.variant() catch return;
    if (!std.mem.eql(u8, sig, "as")) return;
    var list = msg.body.array(4) catch return;
    while (list.offset < list.bytes.len) addFull(self, list.string() catch return);
}
fn addFull(self: *Tray, full: []const u8) void {
    const slash = std.mem.indexOfScalar(u8, full, '/') orelse return;
    self.add(full[0..slash], full[slash..]) catch {};
}
fn watcherChanged(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self = asTray(owner);
    if (self.owns_watcher) return;
    if (std.mem.eql(u8, msg.headers.member.?, "StatusNotifierItemRegistered")) {
        var r = msg.body;
        addFull(self, try r.string());
    }
}
fn registerItem(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) anyerror!void {
    if (!std.mem.eql(u8, msg.headers.signature, "s")) return error.BadSignature;
    var r = msg.body;
    const service = try r.string();
    if (service.len == 0) return error.InvalidItem;
    try asTray(owner).add(if (service[0] == '/') msg.headers.sender.? else service, if (service[0] == '/') service else "/StatusNotifierItem");
    var empty: wire.Writer = .{ .allocator = gpa };
    try conn.reply(msg, "", &empty);
}
fn registerHost(_: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) anyerror!void {
    if (!std.mem.eql(u8, msg.headers.signature, "s")) return error.BadSignature;
    var empty: wire.Writer = .{ .allocator = gpa };
    try conn.reply(msg, "", &empty);
}
fn property(self: *Tray, b: *wire.Writer, name: []const u8) !void {
    if (std.mem.eql(u8, name, "IsStatusNotifierHostRegistered")) {
        try b.variant("b");
        try b.boolean(true);
    } else if (std.mem.eql(u8, name, "ProtocolVersion")) {
        try b.variant("i");
        try b.int(i32, 0);
    } else if (std.mem.eql(u8, name, "RegisteredStatusNotifierItems")) {
        try b.variant("as");
        const a = try b.beginArray(4);
        for (self.items.items) |item| {
            if (item.owner.len == 0) continue;
            const full = try std.fmt.allocPrint(gpa, "{s}{s}", .{ item.service, item.path });
            defer gpa.free(full);
            try b.string(full);
        }
        try b.endArray(a);
    } else return error.UnknownProperty;
}
fn properties(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self = asTray(owner);
    const all = std.mem.eql(u8, msg.headers.member.?, "GetAll");
    if (!std.mem.eql(u8, msg.headers.signature, if (all) "s" else "ss")) return error.BadSignature;
    var r = msg.body;
    const iface = try r.string();
    if (!std.mem.eql(u8, iface, watcher) and !std.mem.eql(u8, iface, "org.freedesktop.StatusNotifierWatcher")) return error.UnknownInterface;
    var b: wire.Writer = .{ .allocator = gpa };
    defer b.deinit();
    if (all) {
        const a = try b.beginArray(8);
        inline for (.{ "RegisteredStatusNotifierItems", "IsStatusNotifierHostRegistered", "ProtocolVersion" }) |name| {
            try b.alignTo(8);
            try b.string(name);
            try property(self, &b, name);
        }
        try b.endArray(a);
    } else try property(self, &b, try r.string());
    try conn.reply(msg, if (all) "a{sv}" else "v", &b);
}
fn resolved(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req = asRequest(owner);
    defer gpa.destroy(req);
    const self = req.tray;
    if (self.closing) return;
    const item = self.find(req.id) orelse return;
    var msg = result catch {
        self.remove(req.id);
        return;
    };
    if (msg.kind != .method_return) {
        self.remove(req.id);
        return;
    }
    const unique = msg.body.string() catch return;
    for (self.items.items) |other| {
        if (other.id != item.id and std.mem.eql(u8, other.owner, unique) and std.mem.eql(u8, other.path, item.path)) {
            self.remove(req.id);
            return;
        }
    }
    replace(&item.owner, unique) catch return;
    if (self.owns_watcher) self.itemSignal("StatusNotifierItemRegistered", item);
    self.refresh(item);
}
fn nameChanged(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self = asTray(owner);
    var r = msg.body;
    const name = try r.string();
    const old = try r.string();
    const new = try r.string();
    if (old.len > 0) {
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            const item = self.items.items[i];
            if (std.mem.eql(u8, item.owner, name) or std.mem.eql(u8, item.service, name)) self.remove(item.id);
        }
    }
    if (std.mem.eql(u8, name, watcher) and new.len == 0 and !self.closing) _ = try conn.requestName(watcher, 4, self, acquired);
}
fn itemChanged(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self = asTray(owner);
    for (self.items.items) |*item| if (std.mem.eql(u8, item.owner, msg.headers.sender orelse "") and std.mem.eql(u8, item.path, msg.headers.path orelse "")) self.refresh(item);
}
fn gotProperties(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req = asRequest(owner);
    defer gpa.destroy(req);
    const self = req.tray;
    if (self.closing) return;
    const item = self.find(req.id) orelse return;
    item.fetching = false;
    defer if (item.refresh_again) {
        item.refresh_again = false;
        self.refresh(item);
    };
    var msg = result catch return;
    if (msg.kind != .method_return) {
        if (std.mem.eql(u8, item.interface, item_iface) and
            (std.mem.eql(u8, msg.headers.error_name orelse "", "org.freedesktop.DBus.Error.UnknownInterface") or
                std.mem.eql(u8, msg.headers.error_name orelse "", "org.freedesktop.DBus.Error.UnknownMethod")))
        {
            item.interface = "org.freedesktop.StatusNotifierItem";
            self.refresh(item);
        }
        return;
    }
    if (!std.mem.eql(u8, msg.headers.signature, "a{sv}")) return;
    readProperties(item, &msg.body) catch return;
    item.ready = true;
    if (item.passive and self.menu_item == item.id) self.closeMenu();
    self.changed();
}
fn readProperties(item: *Item, reader: *wire.Reader) !void {
    var entries = try reader.array(8);
    while (entries.offset < entries.bytes.len) {
        try entries.alignTo(8);
        const name = try entries.string();
        const sig = try entries.variant();
        if (std.mem.eql(u8, name, "IconName") and std.mem.eql(u8, sig, "s")) try replace(&item.icon, try entries.string()) else if (std.mem.eql(u8, name, "IconThemePath") and std.mem.eql(u8, sig, "s")) try replace(&item.icon_theme_path, try entries.string()) else if (std.mem.eql(u8, name, "AttentionIconName") and std.mem.eql(u8, sig, "s")) try replace(&item.attention_icon, try entries.string()) else if (std.mem.eql(u8, name, "Menu") and std.mem.eql(u8, sig, "o")) try replace(&item.menu, try entries.objectPath()) else if (std.mem.eql(u8, name, "ItemIsMenu") and std.mem.eql(u8, sig, "b")) item.is_menu = try entries.boolean() else if (std.mem.eql(u8, name, "Status") and std.mem.eql(u8, sig, "s")) {
            const status = try entries.string();
            item.passive = std.mem.eql(u8, status, "Passive");
            item.attention = std.mem.eql(u8, status, "NeedsAttention");
        } else if (std.mem.eql(u8, name, "IconPixmap") and std.mem.eql(u8, sig, "a(iiay)")) try readPixmap(item, &entries, false) else if (std.mem.eql(u8, name, "AttentionIconPixmap") and std.mem.eql(u8, sig, "a(iiay)")) try readPixmap(item, &entries, true) else try entries.skip(sig);
    }
}
fn readPixmap(item: *Item, reader: *wire.Reader, attention: bool) !void {
    var pixmaps = try reader.array(8);
    var best: []const u8 = &.{};
    var bw: i32 = 0;
    var bh: i32 = 0;
    while (pixmaps.offset < pixmaps.bytes.len) {
        try pixmaps.alignTo(8);
        const w = try pixmaps.int(i32);
        const h = try pixmaps.int(i32);
        const bytes = try pixmaps.array(1);
        const data = bytes.bytes[bytes.offset..];
        if (w <= 0 or h <= 0 or w > 512 or h > 512 or data.len != @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4) continue;
        if (best.len == 0 or @abs(w - 32) < @abs(bw - 32)) {
            best = data;
            bw = w;
            bh = h;
        }
    }
    const pixels = try gpa.alloc(u32, best.len / 4);
    for (pixels, 0..) |*pixel, i| {
        const p = best[i * 4 ..][0..4]; // SNI is unpremultiplied ARGB in network byte order.
        const a: u32 = p[0];
        pixel.* = a << 24 | ((@as(u32, p[1]) * a + 127) / 255) << 16 | ((@as(u32, p[2]) * a + 127) / 255) << 8 | ((@as(u32, p[3]) * a + 127) / 255);
    }
    if (attention) {
        if (item.attention_pixels.len > 0) gpa.free(item.attention_pixels);
        item.attention_pixels = pixels;
        item.attention_width = bw;
        item.attention_height = bh;
    } else {
        if (item.pixels.len > 0) gpa.free(item.pixels);
        item.pixels = pixels;
        item.width = bw;
        item.height = bh;
    }
}
fn aboutToShow(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req = asRequest(owner);
    defer gpa.destroy(req);
    _ = result catch {};
    if (!req.tray.closing and req.epoch == req.tray.menu_epoch and req.id == req.tray.menu_item) req.tray.fetchMenu();
}
fn menuChanged(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
    const self = asTray(owner);
    const item = self.find(self.menu_item) orelse return;
    if (std.mem.eql(u8, item.owner, msg.headers.sender orelse "") and std.mem.eql(u8, item.menu, msg.headers.path orelse "")) self.fetchMenu();
}
fn gotMenu(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const req = asRequest(owner);
    defer gpa.destroy(req);
    const self = req.tray;
    if (self.closing or req.epoch != self.menu_epoch or req.id != self.menu_item) return;
    self.menu_fetching = false;
    defer if (self.menu_again) {
        self.menu_again = false;
        self.fetchMenu();
    };
    var msg = result catch {
        self.closeMenu();
        return;
    };
    if (msg.kind != .method_return or !std.mem.eql(u8, msg.headers.signature, "u(ia{sv}av)")) {
        self.closeMenu();
        return;
    }
    parseMenu(self, &msg.body) catch {
        self.closeMenu();
        return;
    };
    if (self.rows.items.len == 0) {
        self.closeMenu();
        return;
    }
    self.paintMenu();
}
fn parseMenu(self: *Tray, r: *wire.Reader) !void {
    _ = try r.uint32();
    try r.alignTo(8);
    _ = try r.int(i32);
    try r.skip("a{sv}");
    var children = try r.array(1);
    self.clearRows();
    if (self.parents.items.len > 0) try self.rows.append(gpa, .{ .id = -1, .label = try gpa.dupe(u8, "Back") });
    while (children.offset < children.bytes.len and self.rows.items.len < 256) {
        const sig = try children.variant();
        if (!std.mem.eql(u8, sig, "(ia{sv}av)")) return error.BadLayout;
        try children.alignTo(8);
        var row: Row = .{ .id = try children.int(i32), .label = "" };
        var label: []const u8 = "";
        var visible = true;
        var properties_ = try children.array(8);
        while (properties_.offset < properties_.bytes.len) {
            try properties_.alignTo(8);
            const name = try properties_.string();
            const s = try properties_.variant();
            if (std.mem.eql(u8, name, "label") and std.mem.eql(u8, s, "s")) label = try properties_.string() else if (std.mem.eql(u8, name, "enabled") and std.mem.eql(u8, s, "b")) row.enabled = try properties_.boolean() else if (std.mem.eql(u8, name, "visible") and std.mem.eql(u8, s, "b")) visible = try properties_.boolean() else if (std.mem.eql(u8, name, "type") and std.mem.eql(u8, s, "s")) row.separator = std.mem.eql(u8, try properties_.string(), "separator") else if (std.mem.eql(u8, name, "children-display") and std.mem.eql(u8, s, "s")) row.submenu = std.mem.eql(u8, try properties_.string(), "submenu") else if (std.mem.eql(u8, name, "toggle-type") and std.mem.eql(u8, s, "s")) row.toggle = (try properties_.string()).len > 0 else if (std.mem.eql(u8, name, "toggle-state") and std.mem.eql(u8, s, "i")) row.checked = (try properties_.int(i32)) == 1 else try properties_.skip(s);
        }
        try children.skip("av");
        if (!visible) continue;
        row.label = try cleanLabel(label);
        errdefer gpa.free(row.label);
        try self.rows.append(gpa, row);
    }
    self.selected = null;
}
fn cleanLabel(label: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < @min(label.len, 4096)) : (i += 1) {
        if (label[i] == '_') {
            if (i + 1 < label.len and label[i + 1] == '_') i += 1 else continue;
        }
        try out.append(gpa, label[i]);
    }
    return out.toOwnedSlice(gpa);
}

fn ignoreReply(_: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    _ = result catch {};
}

fn introspect(_: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) anyerror!void {
    if (msg.headers.signature.len != 0) return error.BadSignature;
    var body: wire.Writer = .{ .allocator = gpa };
    defer body.deinit();
    try body.string(@embedFile("tray-watcher.xml"));
    try conn.reply(msg, "s", &body);
}

test "SNI pixmaps use network ARGB and premultiply translucent pixels" {
    var b: wire.Writer = .{ .allocator = std.testing.allocator };
    defer b.deinit();
    const a = try b.beginArray(8);
    try b.alignTo(8);
    try b.int(i32, 2);
    try b.int(i32, 1);
    const bytes = try b.beginArray(1);
    try b.raw(&.{ 128, 255, 64, 0, 0, 255, 255, 255 });
    try b.endArray(bytes);
    try b.endArray(a);
    var r: wire.Reader = .{ .bytes = b.bytes.items };
    var item: Item = .{ .id = 1, .service = "", .path = "" };
    defer item.deinit();
    try readPixmap(&item, &r, false);
    try std.testing.expectEqual(@as(i32, 2), item.width);
    try std.testing.expectEqualSlices(u32, &.{ 0x80802000, 0 }, item.pixels);
}

test "SNI malformed pixmap dimensions are ignored" {
    var b: wire.Writer = .{ .allocator = std.testing.allocator };
    defer b.deinit();
    const a = try b.beginArray(8);
    for ([_]i32{ -1, 0, 513, 2147483647, 16 }) |width| {
        try b.alignTo(8);
        try b.int(i32, width);
        try b.int(i32, 16);
        const bytes = try b.beginArray(1);
        try b.byte(0);
        try b.endArray(bytes);
    }
    try b.endArray(a);
    var r: wire.Reader = .{ .bytes = b.bytes.items };
    var item: Item = .{ .id = 1, .service = "", .path = "" };
    defer item.deinit();
    try readPixmap(&item, &r, true);
    try std.testing.expectEqual(@as(usize, 0), item.attention_pixels.len);
}

fn scalePixel(pixel: u32, coverage: f32) u32 {
    var result: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |shift| {
        const channel: f32 = @floatFromInt((pixel >> shift) & 255);
        result |= @as(u32, @intFromFloat(@round(channel * coverage))) << shift;
    }
    return result;
}
