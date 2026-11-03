//! Circular presentation of the switcher's frozen MRU list, grouped by app.
//! Tab/Shift+Tab exhausts a multi-window group's own windows (`advance`,
//! member by member in first-seen order) before moving to the next app; the
//! linear style keeps the flat MRU order untouched. A group's stack fans open
//! (`State.expand`) only while it holds the selection.
const std = @import("std");
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const Switcher = @import("../Switcher.zig");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const PanelBuffer = @import("../panel_buffer.zig").PanelBuffer;
const projection = @import("../projection.zig");
const col = @import("../color.zig");
const ui = @import("ui");
const theme = ui.theme;
const Anim = ui.anim.Anim;
const i18n = @import("i18n");
const gpa = @import("../main.zig").gpa;
pub const layout = @import("layout.zig");
const tau = 2 * std.math.pi;
const page_size = 8;

const Group = struct { first: usize, front: usize, count: usize = 0, members: std.ArrayList(usize) = .empty };
pub const State = struct {
    enabled: bool = false,
    groups: std.ArrayList(Group) = .empty,
    page: usize = 0,
    hub: ?*sn.Buffer = null,
    hub_icon: ?*sn.Buffer = null,
    hub_icon_source: ?*wlr.Buffer = null,
    hub_storage: ?*wlr.Buffer = null,
    hub_key: ?u64 = null,
    /// The window-count badge, now drawn over the focused window's own
    /// sector instead of inside the hub (see `updateBadge`).
    badge: ?*sn.Buffer = null,
    badge_storage: ?*wlr.Buffer = null,
    badge_key: ?usize = null,
    /// The group the selected card belonged to last frame, so entering a
    /// different group (including the very first selection) can be told
    /// apart from cycling within the one already open.
    current_group: ?usize = null,
    /// 0 = idle stack, 1 = the selected group's windows fanned fully open.
    /// Retargeted in `select` whenever `current_group` changes.
    expand: Anim = .{},
    /// 0 = nothing shown, 1 = fully open. Runs once from 0->1 in `open`
    /// (the hub appears, then windows grow out of it) and, while `closing`,
    /// back from 1->0 before `tick` actually tears the switcher down.
    appear: Anim = .{},
    /// Set by `Switcher.dismiss` for an animated close; `tick` finishes the
    /// real `Switcher.cancel` once `appear` settles at 0. Forced teardowns
    /// (`Switcher.cancel` called directly, e.g. on output loss or session
    /// lock) ignore this and tear down synchronously instead.
    closing: bool = false,
    /// The hub's arrow, in radians clockwise from "points up at the
    /// selected card" (always true at rest, since the selection sits at
    /// twelve o'clock). Orbits the hub rim toward the hovered sector.
    arrow_angle: Anim = .{},
    hub_arrow: ?*sn.Buffer = null,
    hub_arrow_storage: ?*wlr.Buffer = null,

    pub fn deinit(self: *State) void {
        if (self.hub_storage) |buffer| buffer.unlock();
        if (self.badge_storage) |buffer| buffer.unlock();
        if (self.hub_arrow_storage) |buffer| buffer.unlock();
        for (self.groups.items) |*group| group.members.deinit(gpa);
        self.groups.deinit(gpa);
    }
};

pub fn open(self: *Switcher, server: *Server) !void {
    _ = projection.setTreeInert(&self.tree.?.node, true);
    var r: ui.paint.Renderer = undefined;
    if (server.config.compositor.switcher_circle_bg) {
        const diameter: f32 = @floatFromInt(self.width);
        const bg = try PanelBuffer.create(self.width, self.width, self.scale);
        defer bg.base.drop();
        r = ui.paint.Renderer.init(bg.pixels, bg.width, bg.height, self.scale);
        // Darkness and opacity come from the window chrome, not a switcher-local
        // setting, so the disc matches whatever chrome look the user picked.
        const chrome = theme.global.window_bg;
        r.fillRect(4, 4, diameter - 8, diameter - 8, .{ .color = .{ chrome[0], chrome[1], chrome[2], 1 }, .radius = diameter / 2, .border_width = 1, .border_color = theme.global.switcher_border });
        self.background = try self.makeNode(&bg.base, self.width, self.width);
    }
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |tl| {
        if (!tl.isMapped() or tl.tab_hidden or !@import("../workspaces.zig").visible(tl)) continue;
        const index = self.cards.items.len;
        const group_index = try groupFor(self, server, tl.appId(), index);
        const group = &self.circle.groups.items[group_index];
        const tree = try self.tree.?.createSceneTree();
        const fill = try col.createRect(tree, 1, 1, col.Straight.fromRgba(theme.global.switcher_item_bg).premultiply());
        const preview = try tree.createSceneBuffer(null);
        preview.setFilterMode(.bilinear);
        preview.point_accepts_input = Switcher.ignoreInput;
        const icon_image = try PanelBuffer.create(40, 40, self.scale);
        defer icon_image.base.drop();
        r = ui.paint.Renderer.init(icon_image.pixels, icon_image.width, icon_image.height, self.scale);
        r.fillRect(0, 0, 40, 40, .{ .color = theme.global.switcher_icon_bg, .radius = theme.global.switcher_icon_radius });
        r.drawIcon(5, 5, 30, 30, .{ .id = .generic, .color = theme.global.switcher_fg });
        const icon = try self.makeNode(&icon_image.base, 40, 40);
        // Only the hub presents an icon. Keep this node as the shared icon
        // loader's storage while the sector itself shows uninterrupted content.
        icon.node.setEnabled(false);
        var card: Switcher.Card = .{
            .id = tl.id,
            .icon = icon,
            .icon_buffer = &icon_image.base,
            .icon_source = .{ .x = 0, .y = 0, .width = @floatFromInt(icon_image.width), .height = @floatFromInt(icon_image.height) },
            .tree = tree,
            .fill = fill,
            .preview = preview,
            .group = group_index,
            .member = group.count,
        };
        Switcher.updatePreview(&card, tl);
        try self.cards.append(gpa, card);
        try group.members.append(gpa, index);
        group.count += 1;
    }
    // Seed every card's animated stack slot at its resting depth so an
    // unselected group's cascade renders correctly without having to wait
    // for a `select()` retarget (which only ever touches the group it enters).
    for (self.cards.items) |*card| card.stack.cancel(@floatFromInt(stackDepth(self, card)));
    self.circle.hub = try self.tree.?.createSceneBuffer(null);
    self.circle.hub.?.setFilterMode(.bilinear);
    self.circle.hub.?.point_accepts_input = Switcher.ignoreInput;
    self.circle.hub_icon = try self.tree.?.createSceneBuffer(null);
    self.circle.hub_icon.?.setFilterMode(.bilinear);
    self.circle.hub_icon.?.point_accepts_input = Switcher.ignoreInput;
    self.circle.badge = try self.tree.?.createSceneBuffer(null);
    self.circle.badge.?.setFilterMode(.bilinear);
    self.circle.badge.?.point_accepts_input = Switcher.ignoreInput;
    self.circle.hub_arrow = try self.tree.?.createSceneBuffer(null);
    self.circle.hub_arrow.?.setFilterMode(.bilinear);
    self.circle.hub_arrow.?.point_accepts_input = Switcher.ignoreInput;
    self.circle.appear.retargetTo(@import("../Taskbar.zig").nowMs(), 1, ui.anim.curveFor(.switcher_open));
}

/// Called from `Switcher.dismiss` for a normal, user-driven close (releasing
/// the modifier, Escape, accepting a selection). Plays the open animation in
/// reverse; `tick` finishes the real teardown once it settles. Forced
/// teardowns keep calling `Switcher.cancel` directly and skip this.
pub fn beginClose(self: *Switcher, now: i64) void {
    self.circle.closing = true;
    self.circle.appear.retargetTo(now, 0, ui.anim.curveFor(.switcher_close));
    self.hovered = null;
}

/// 0 while the hub is still fading in (or has already faded past, on close)
/// and windows have not started growing; 1 once they should be fully grown.
/// The 0.15 head start is the "hub appears first" beat the cards wait out.
fn cardGrowth(appear: f64) f64 {
    return std.math.clamp((appear - 0.15) / 0.85, 0, 1);
}

/// The hub, its icon, the badge and the backdrop disc fade in over the first
/// third of `appear` and are the last things to fade out on close, so cards
/// visibly grow out of the hub both ways.
fn hubFade(appear: f64) f32 {
    return @floatCast(std.math.clamp(appear / 0.3, 0, 1));
}

fn groupFor(self: *Switcher, server: *Server, raw: []const u8, index: usize) !usize {
    const identity = @import("../window_tabs.zig").identity;
    const app = identity(raw);
    // Unidentified clients need independent slots, not one anonymous stack.
    if (app.len > 0) for (self.circle.groups.items, 0..) |group, i| {
        const first = server.findToplevelById(self.cards.items[group.first].id) orelse continue;
        if (std.mem.eql(u8, app, identity(first.appId()))) return i;
    };
    try self.circle.groups.append(gpa, .{ .first = index, .front = index });
    return self.circle.groups.items.len - 1;
}

/// Replaces the flat `(selected ± 1) % n` step for the circular style: a
/// multi-window group is exhausted member by member, in the order its
/// windows were first seen, before the wheel moves on to the next group.
/// Forward and backward are exact mirrors, so a full lap in either direction
/// revisits every window exactly once, same as the flat styles.
pub fn advance(self: *Switcher, reverse: bool) void {
    const groups = self.circle.groups.items;
    if (groups.len == 0) return;
    const card = self.cards.items[self.selected];
    const group = groups[card.group];
    const next_member: ?usize = if (reverse)
        (if (card.member == 0) null else card.member - 1)
    else
        (if (card.member + 1 >= group.count) null else card.member + 1);
    if (next_member) |member| {
        self.selected = group.members.items[member];
        return;
    }
    const next_group = if (reverse) (card.group + groups.len - 1) % groups.len else (card.group + 1) % groups.len;
    const entry: usize = if (reverse) groups[next_group].count - 1 else 0;
    self.selected = groups[next_group].members.items[entry];
}

pub fn select(self: *Switcher, opening: bool) void {
    const now = @import("../Taskbar.zig").nowMs();
    const card = self.cards.items[self.selected];
    const group = &self.circle.groups.items[card.group];
    group.front = self.selected;
    // Advancing the front shifts every member of this group by exactly one
    // stack slot (`stackDepth` is relative to `front`), so retargeting all of
    // them here slides the newly-front card's preview over the old one
    // instead of popping straight to the new arrangement.
    for (group.members.items) |member_index| {
        const member = &self.cards.items[member_index];
        member.stack.retargetTo(now, @floatFromInt(stackDepth(self, member)), ui.anim.curveFor(.switcher_scroll));
    }
    const entering_group = opening or self.circle.current_group != card.group;
    if (entering_group) {
        self.circle.current_group = card.group;
        if (group.count > 1) {
            self.circle.expand.cancel(0);
            self.circle.expand.retargetTo(now, 1, ui.anim.curveFor(.switcher_scroll));
        } else {
            self.circle.expand.cancel(0);
        }
    }
    const page = card.group / page_size;
    const slots = @min(page_size, self.circle.groups.items.len - page * page_size);
    const target: f32 = @floatCast(@as(f64, @floatFromInt(card.group % page_size)) * tau / @as(f64, @floatFromInt(slots)));
    if (opening or page != self.circle.page) {
        self.scroll = .{ .to = target };
    } else {
        // Cross the twelve-o'clock seam by the shorter arc.
        const delta = @mod(target - self.scroll.to + std.math.pi, tau) - std.math.pi;
        self.scroll.retargetTo(now, self.scroll.to + delta, ui.anim.curveFor(.switcher_scroll));
    }
    self.circle.page = page;
    // Only restack on selection. Repeating this every frame would damage an
    // otherwise idle switcher and keep its frame loop awake.
    var depth: usize = 3;
    while (depth > 0) {
        depth -= 1;
        for (self.cards.items) |*item| {
            if (stackDepth(self, item) == depth) item.tree.?.node.raiseToTop();
        }
    }
    self.circle.hub.?.node.raiseToTop();
    self.circle.hub_icon.?.node.raiseToTop();
    self.circle.badge.?.node.raiseToTop();
    self.circle.hub_arrow.?.node.raiseToTop();
}

fn stackDepth(self: *const Switcher, card: *const Switcher.Card) usize {
    const group = self.circle.groups.items[card.group];
    const front = self.cards.items[group.front];
    return (card.member + group.count - front.member) % group.count;
}

/// Pure geometry hit test mirroring `tick`'s placement math (without
/// touching scene nodes), so pointer motion/clicks landing between frames
/// still match exactly what's on screen. `lx`/`ly` are local to the
/// switcher's own tree. Prefers whichever matching card sits topmost in its
/// group's stack (`depth`'s raise-to-top order in `select`), since a deeper
/// member's sector mostly sits behind the one in front of it.
pub fn hit(self: *Switcher, now: i64, lx: f64, ly: f64) ?usize {
    const slots = @min(page_size, self.circle.groups.items.len - self.circle.page * page_size);
    if (slots == 0) return null;
    const arc = layout.span(slots);
    const rotation: f64 = self.scroll.value(now);
    const selected_group = self.cards.items[self.selected].group;
    const expand: f64 = @floatCast(self.circle.expand.value(now));
    const growth = cardGrowth(self.circle.appear.value(now));
    var best: ?usize = null;
    var best_depth: f64 = std.math.inf(f64);
    for (self.cards.items, 0..) |*card, i| {
        const depth: f64 = card.stack.value(now);
        if (card.group / page_size != self.circle.page or depth >= 3 or depth >= best_depth) continue;
        const angle = @as(f64, @floatFromInt(card.group % page_size)) * tau / @as(f64, @floatFromInt(slots)) - rotation;
        const progress = if (card.group == selected_group) expand else 0;
        const sector = layout.makeSector(self.width, angle, arc, depth, progress, growth);
        if (inSector(sector, lx, ly)) {
            best = i;
            best_depth = depth;
        }
    }
    return best;
}

fn inSector(sector: layout.Sector, lx: f64, ly: f64) bool {
    const dx = lx - @as(f64, @floatFromInt(sector.x)) - sector.arc.center[0];
    const dy = ly - @as(f64, @floatFromInt(sector.y)) - sector.arc.center[1];
    const radius = @sqrt(dx * dx + dy * dy);
    if (radius < sector.arc.radii[0] or radius > sector.arc.radii[1] or radius == 0) return false;
    const dot = (dx / radius) * sector.arc.axis[0] + (dy / radius) * sector.arc.axis[1];
    return dot >= sector.arc.half_angle[0] - 1e-9;
}

pub fn tick(self: *Switcher, output: *Output, now: i64) bool {
    // The close animation finishes here rather than in `Switcher.dismiss`:
    // it needs a frame boundary to keep sampling `appear` against, and this
    // is the one place already called every frame while the switcher lives.
    if (self.circle.closing and self.circle.appear.settled(now)) {
        self.cancel();
        return false;
    }
    const box = output.usableBox();
    self.tree.?.node.setPosition(box.x + @divTrunc(box.width - self.width, 2), box.y + @divTrunc(box.height - self.width, 2));
    const appear: f64 = self.circle.appear.value(now);
    const growth = cardGrowth(appear);
    const fade = hubFade(appear);
    if (self.background) |bg| bg.setOpacity(theme.global.window_bg[3] * fade);
    const slots = @min(page_size, self.circle.groups.items.len - self.circle.page * page_size);
    const arc = layout.span(slots);
    const rotation: f64 = self.scroll.value(now);
    const selected_group = self.cards.items[self.selected].group;
    const expand: f64 = @floatCast(self.circle.expand.value(now));
    var stack_settled = true;
    var hover_settled = true;
    for (self.cards.items, 0..) |*card, i| {
        card.hover.retargetTo(now, if (self.hovered == i and i != self.selected) 1 else 0, ui.anim.curveFor(.titlebar_hover));
        const hover = std.math.clamp(card.hover.value(now), 0, 1);
        _ = card.hover.sampleChanged(now, ui.anim.quantum_alpha);
        hover_settled = hover_settled and card.hover.settled(now);
        const depth: f64 = card.stack.value(now);
        stack_settled = stack_settled and card.stack.settled(now);
        const visible = card.group / page_size == self.circle.page and depth < 3;
        card.tree.?.node.setEnabled(visible);
        if (!visible) continue;
        const angle = @as(f64, @floatFromInt(card.group % page_size)) * tau / @as(f64, @floatFromInt(slots)) - rotation;
        const progress = if (card.group == selected_group) expand else 0;
        const sector = layout.makeSector(self.width, angle, arc, depth, progress, growth);
        placeCard(self, card, sector, depth, progress, hover);
        if (card.id == self.cards.items[self.selected].id) {
            self.refreshIcon(card);
            updateBadge(self, card, sector) catch |err| std.log.warn("circular switcher badge: {}", .{err});
        }
    }
    paintHub(self, output.server) catch |err| std.log.warn("circular switcher label: {}", .{err});
    updateArrow(self, now);
    self.circle.hub.?.setOpacity(fade);
    self.circle.hub_icon.?.setOpacity(fade);
    self.circle.badge.?.setOpacity(fade);
    self.circle.hub_arrow.?.setOpacity(fade);
    _ = self.scroll.sampleChanged(now, ui.anim.quantum_px);
    _ = self.circle.expand.sampleChanged(now, ui.anim.quantum_px);
    _ = self.circle.appear.sampleChanged(now, ui.anim.quantum_px);
    return !self.scroll.settled(now) or !self.circle.expand.settled(now) or !stack_settled or !self.circle.appear.settled(now) or
        !self.circle.arrow_angle.settled(now) or !hover_settled;
}

fn placeCard(self: *Switcher, card: *Switcher.Card, sector: layout.Sector, depth: f64, progress: f64, hover: f32) void {
    const selected = self.cards.items[self.selected].id == card.id;
    // Hover reads as "click here to land on this one", the same promise the
    // selected sector's own border makes, so both share its colour.
    const intensity: f32 = if (selected) 1 else hover;
    var color: [4]f32 = undefined;
    for (&color, theme.global.switcher_item_border, theme.global.switcher_selected_border) |*channel, base, accent| {
        channel.* = base + (accent - base) * intensity;
    }
    const tree = card.tree.?;
    tree.node.setPosition(sector.x, sector.y);
    card.fill.?.setSize(sector.width, sector.height);
    _ = projection.setTreeClip(&tree.node, .{
        .width = sector.width,
        .height = sector.height,
        .radii = @splat(0),
        .border = 1 + intensity,
        .border_color = col.Straight.fromRgba(color).premultiply().rgba,
        .sector = sector.arc,
        .sector_texture_height = if (card.pw > 0) layout.previewHeight(sector, card.aspect) else 0,
    });
    // A card behind the front of its stack dims less as the group opens, so a
    // fully fanned-out stack reads clearly instead of staying half-shadowed.
    const dim: f32 = if (depth > 0) @floatCast(0.18 * (1 - 0.7 * progress)) else 0;
    _ = projection.setTreeDim(&tree.node, dim, 0);
    const preview = card.preview.?;
    // A full-size preview supplies the shape's body and ring itself. Drawing
    // the fallback underneath it would apply edge coverage and border twice.
    card.fill.?.node.setEnabled(card.pw <= 0);
    preview.node.setEnabled(card.pw > 0);
    if (card.pw <= 0) return;
    // The shader fans the complete source width around the outer arc, keeping
    // its header visible. The hub crops the bottom of tall windows. Live client
    // buffers still pass straight through, without CPU readback or copies.
    preview.setSourceBox(&card.source);
    preview.setDestSize(sector.width, sector.height);
}

/// The window-count badge for a multi-window group, held over the focused
/// card's own sector rather than inside the hub. Positioned at the sector's
/// inner, hub-facing edge (its angular bisector at `radii[0]`) so it reads as
/// part of the window being focused, closest to where the hub's arrow points.
fn updateBadge(self: *Switcher, card: *Switcher.Card, sector: layout.Sector) !void {
    const badge = self.circle.badge.?;
    const group = self.circle.groups.items[card.group];
    if (group.count <= 1) {
        badge.node.setEnabled(false);
        return;
    }
    badge.node.setEnabled(true);
    const s: f32 = @max(0.75, @min(1, @as(f32, @floatFromInt(self.width)) / 600));
    const d: f32 = 22 * s * 1.3;
    if (self.circle.badge_key != group.count) {
        const px: i32 = @intFromFloat(@ceil(d));
        const image = try PanelBuffer.create(px, px, self.scale);
        defer image.base.drop();
        var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.scale);
        r.fillRect(0, 0, d, d, .{ .color = theme.global.switcher_selected_border, .radius = d / 2, .border_width = 1, .border_color = theme.global.switcher_item_bg });
        var badge_buf: [8]u8 = undefined;
        const badge_text = std.fmt.bufPrint(&badge_buf, "{d}", .{group.count}) catch "";
        const font_size = 11 * 1.3 * s;
        const text_width = ui.text.measureWidthF(badge_text, .manrope_heavy, font_size, self.scale) catch d;
        const text_height = font_size + 6;
        r.drawText(d / 2 - text_width / 2, d / 2 - text_height / 2, text_width + 4, text_height, .{ .content = badge_text, .font_size = font_size, .weight = 700, .color = theme.global.on_accent });
        badge.setBuffer(&image.base);
        _ = image.base.lock();
        if (self.circle.badge_storage) |old| old.unlock();
        self.circle.badge_storage = &image.base;
        badge.setDestSize(px, px);
        self.circle.badge_key = group.count;
    }
    const inner_x = sector.arc.center[0] + sector.arc.axis[0] * sector.arc.radii[0];
    const inner_y = sector.arc.center[1] + sector.arc.axis[1] * sector.arc.radii[0];
    const half_d: f64 = @floatCast(d / 2);
    badge.node.setPosition(sector.x + @as(i32, @intFromFloat(inner_x - half_d)), sector.y + @as(i32, @intFromFloat(inner_y - half_d)));
}

fn paintHub(self: *Switcher, server: *Server) !void {
    const card = &self.cards.items[self.hovered orelse self.selected];
    self.refreshIcon(card);
    const tl = server.findToplevelById(card.id) orelse return;
    const group = self.circle.groups.items[card.group];
    const key = std.hash.Wyhash.hash(card.id, tl.title()) ^ (@as(u64, tl.workspace_id) << 32);
    const size: i32 = @intFromFloat(@as(f32, @floatFromInt(self.width)) * 0.36 - 16);
    const x = @divTrunc(self.width - size, 2);
    const s: f32 = @min(1, @as(f32, @floatFromInt(size)) / 210);
    const text_scale = @max(0.85, s);
    const d: f32 = @floatFromInt(size);
    const icon_size: i32 = @intFromFloat(52 * s);
    const icon = self.circle.hub_icon.?;
    if (self.circle.hub_icon_source != card.icon_buffer) {
        icon.setBuffer(card.icon_buffer);
        self.circle.hub_icon_source = card.icon_buffer;
    }
    icon.setDestSize(icon_size, icon_size);
    // -78*s keeps the icon's vertical centre where it was before growing it,
    // splitting the extra size between the title below and the arrow above.
    icon.node.setPosition(@divTrunc(self.width - icon_size, 2), x + @as(i32, @intFromFloat(d / 2 - 78 * s)));
    if (self.circle.hub_key != key) {
        const image = try PanelBuffer.create(size, size, self.scale);
        defer image.base.drop();
        var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.scale);
        r.fillRect(0, 0, d, d, .{ .color = theme.global.switcher_item_bg, .radius = d / 2, .border_width = 1, .border_color = theme.global.switcher_border });
        centered(&r, d, d / 2 - 22 * s, tl.title(), theme.global.switcher_title_size * text_scale, theme.global.switcher_fg);
        var workspace_buf: [128]u8 = undefined;
        const workspace = if (server.world.workspaces.active)
            i18n.fmt(&workspace_buf, i18n.tr("Workspace {n}"), .{ .n = tl.workspace_id }) catch ""
        else
            i18n.tr("Window");
        centered(&r, d, d / 2 + 2 * s, workspace, theme.global.switcher_app_size * text_scale, theme.global.switcher_dim);
        var count_buf: [64]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d} / {d}", .{ card.member + 1, group.count }) catch "";
        centered(&r, d, d / 2 + 24 * s, count, theme.global.switcher_app_size * text_scale, theme.global.switcher_fg);
        if (self.circle.groups.items.len > page_size) {
            const pages = (self.circle.groups.items.len + page_size - 1) / page_size;
            const shown = @min(5, pages);
            const first = @min(self.circle.page -| 2, pages - shown);
            for (0..shown) |i| {
                const dot_x = d / 2 + (@as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(shown - 1)) / 2) * 10 - 2;
                r.fillRect(dot_x, d / 2 + 52 * s, 4, 4, .{ .radius = 2, .color = if (first + i == self.circle.page) theme.global.switcher_selected_border else theme.global.switcher_dim });
            }
        }
        self.circle.hub.?.setBuffer(&image.base);
        _ = image.base.lock();
        if (self.circle.hub_storage) |old| old.unlock();
        self.circle.hub_storage = &image.base;
        self.circle.hub.?.setDestSize(size, size);
        self.circle.hub.?.node.setPosition(x, x);
        self.circle.hub_key = key;
    }
}

/// The hub's arrow: normally points up at the selected card (always eased to
/// twelve o'clock by `select`'s own rotation), but orbits inside the rim
/// toward whatever is hovered, so the pointer previews where a click lands.
/// Drawn as its own node rather than baked into the cached hub image:
/// the angle can change every frame, on
/// pointer motion alone, independently of anything that invalidates that key.
fn updateArrow(self: *Switcher, now: i64) void {
    const slots = @min(page_size, self.circle.groups.items.len - self.circle.page * page_size);
    const rotation: f64 = self.scroll.value(now);
    const target: f64 = blk: {
        const h = self.hovered orelse break :blk 0;
        const card = self.cards.items[h];
        if (card.group / page_size != self.circle.page or slots == 0) break :blk 0;
        break :blk @as(f64, @floatFromInt(card.group % page_size)) * tau / @as(f64, @floatFromInt(slots)) - rotation;
    };
    // Cross the twelve-o'clock seam by the shorter arc, same trick `select`
    // uses for the wheel's own rotation.
    const current: f64 = self.circle.arrow_angle.to;
    const delta = @mod(target - current + std.math.pi, tau) - std.math.pi;
    self.circle.arrow_angle.retargetTo(now, @floatCast(current + delta), ui.anim.curveFor(.switcher_scroll));
    // The orbit is much wider than the glyph: sample at subpixel arc steps.
    if (!self.circle.arrow_angle.sampleChanged(now, 0.003)) return;

    const size: i32 = @intFromFloat(@as(f32, @floatFromInt(self.width)) * 0.36 - 16);
    const x = @divTrunc(self.width - size, 2);
    const s: f32 = @min(1, @as(f32, @floatFromInt(size)) / 210);
    const d: f32 = @floatFromInt(size);
    const arrow_size = 28 * s;
    // Generous padding: a square rotated about its own center at any angle
    // still fits a canvas 1.5x its side.
    const canvas: i32 = @intFromFloat(@ceil(arrow_size * 1.5));
    const image = PanelBuffer.create(canvas, canvas, self.scale) catch return;
    defer image.base.drop();
    var r = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.scale);
    const off = (@as(f32, @floatFromInt(canvas)) - arrow_size) / 2;
    r.drawIcon(off, off, arrow_size, arrow_size, .{
        .id = .caret_up,
        .color = theme.global.switcher_selected_border,
        .rotation = self.circle.arrow_angle.value(now),
    });
    self.circle.hub_arrow.?.setBuffer(&image.base);
    _ = image.base.lock();
    if (self.circle.hub_arrow_storage) |old| old.unlock();
    self.circle.hub_arrow_storage = &image.base;
    self.circle.hub_arrow.?.setDestSize(canvas, canvas);
    // Keep the caret just inside the hub's rim, on the angular bisector of
    // the hovered sector. Position and orientation share the eased angle.
    const angle = self.circle.arrow_angle.value(now);
    const radius = d / 2 - 2 * s - arrow_size / 2;
    const center = @as(f32, @floatFromInt(x)) + d / 2;
    const pivot_x = center + @sin(angle) * radius;
    const pivot_y = center - @cos(angle) * radius;
    const half_canvas: f32 = @as(f32, @floatFromInt(canvas)) / 2;
    self.circle.hub_arrow.?.node.setPosition(
        @as(i32, @intFromFloat(@round(pivot_x - half_canvas))),
        @as(i32, @intFromFloat(@round(pivot_y - half_canvas))),
    );
}

fn centered(r: *ui.paint.Renderer, width: f32, y: f32, value: []const u8, size: f32, color: [4]f32) void {
    const x = @max(12, ui.paint.centeredTextX(0, width, value, size));
    r.drawText(x, y, width - x - 12, size + 8, .{ .content = value, .font_size = size, .color = color });
}
