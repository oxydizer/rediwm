// Global undo state for spatial operations (Super + Z).
// Pure logic over plain structs — no compositor dependency. See plan-undo.md.
const std = @import("std");
const Layout = @import("snap.zig").Layout;

pub const Kind = enum { move, resize, window_zoom, pan, camera_zoom, focus };

pub const WindowState = struct {
    id: u64,
    x: i32,
    y: i32,
    width: i32, // CLIENT geometry (what clientGeometry()/rememberGeometry() returns)
    height: i32,
    zoom_index: usize,
    /// Maximized or tiled: undo puts the window back into that layout.
    layout: Layout = .floating,
};

pub const CameraState = struct {
    offset_x: f64,
    offset_y: f64,
    zoom_index: usize,
    focus_zoom: ?f64 = null,
};

pub const Live = union(enum) {
    none,
    window: WindowState,
    camera: CameraState,
};

pub const Change = struct {
    kind: Kind,
    press_seq: u64, // which pointer press produced this; used for press folding
    at_ms: i64, // raw CLOCK_MONOTONIC milliseconds, NOT anim.nowMs()
    focus: ?u64 = null, // window id that held keyboard focus before this change
    window: ?WindowState = null,
    camera: ?CameraState = null,
};

pub const Undo = struct {
    slot: ?Change = null,
    pending: ?Change = null, // gesture currently in flight; not yet committed
    press_seq: u64 = 0,
    applying: bool = false, // re-entrancy guard: record() is a no-op while set

    /// Call on every pointer .pressed event (before gesture begin) to bump
    /// the sequence counter. Each new gesture inherits this value.
    pub fn nextPress(undo: *Undo) void {
        undo.press_seq += 1;
    }

    /// Snapshot `change` as the start of an in-flight gesture.
    /// If `slot` already holds a change with the SAME `press_seq`, the new
    /// gesture inherits the old focus id so a title-bar press (focus + move)
    /// folds into one undo entry. `pending` is never clobbered when already
    /// set (a focus change inside an active gesture cannot displace it).
    pub fn begin(undo: *Undo, change: Change) void {
        if (undo.applying) return;
        if (undo.pending != null) return; // gesture already in flight
        var c = change;
        if (undo.slot) |prev| {
            if (prev.press_seq == change.press_seq) {
                // Same press: inherit the previously recorded focus id so the
                // drag and the focus change it caused form one undo entry.
                c.focus = prev.focus;
            }
        }
        undo.pending = c;
    }

    /// Commit the in-flight gesture as the new undo slot. Applies no-op
    /// filtering (equal state), coalescing (same kind + target within 600 ms),
    /// and is a no-op when `pending` is null.
    pub fn commit(undo: *Undo, now_ms: i64, live: Live) void {
        if (undo.applying) return;
        const change = undo.pending orelse return;
        undo.pending = null;

        // No-op detection against live state:
        switch (change.kind) {
            .move => {
                if (live == .window and change.window != null) {
                    const snap = change.window.?;
                    if (snap.x == live.window.x and snap.y == live.window.y and snap.layout.eql(live.window.layout)) {
                        // Position did not change. If focus changed on press,
                        // keep that focus change as the undoable action.
                        if (change.focus != null) {
                            var c = change;
                            c.kind = .focus;
                            c.window = null;
                            undo.commitChange(c, now_ms);
                        }
                        return;
                    }
                }
            },
            .resize => {
                if (live == .window and change.window != null) {
                    const snap = change.window.?;
                    if (snap.x == live.window.x and snap.y == live.window.y and
                        snap.width == live.window.width and snap.height == live.window.height and
                        snap.layout.eql(live.window.layout))
                    {
                        if (change.focus != null) {
                            var c = change;
                            c.kind = .focus;
                            c.window = null;
                            undo.commitChange(c, now_ms);
                        }
                        return;
                    }
                }
            },
            .pan => {
                if (live == .camera and change.camera != null) {
                    const snap = change.camera.?;
                    if (snap.offset_x == live.camera.offset_x and snap.offset_y == live.camera.offset_y and snap.zoom_index == live.camera.zoom_index) {
                        return;
                    }
                }
            },
            else => {},
        }

        undo.commitChange(change, now_ms);
    }

    /// Discrete operations (focus, zoom steps) begin and commit in one call.
    pub fn record(undo: *Undo, change: Change, now_ms: i64) void {
        if (undo.applying) return;
        if (change.kind == .focus and change.focus == null) return;
        var c = change;
        if (undo.slot) |prev| {
            if (prev.press_seq == change.press_seq) {
                c.focus = prev.focus;
            }
        }
        undo.commitChange(c, now_ms);
    }

    /// Drop the in-flight gesture without recording it (e.g. cancelResize).
    pub fn drop(undo: *Undo) void {
        undo.pending = null;
    }

    /// Commit any pending gesture before applying an undo. The plan requires
    /// this when Super+Z fires while a Super pan is live: the pan is committed
    /// first so a late endPan cannot clobber the restored state.
    pub fn commitPending(undo: *Undo, now_ms: i64, live: Live) void {
        if (undo.pending != null) undo.commit(now_ms, live);
    }

    fn commitChange(undo: *Undo, change: Change, now_ms: i64) void {
        // Coalesce: if the same kind + target arrives within 600 ms, keep the
        // OLDER snapshot and only refresh at_ms.
        if (undo.slot) |*prev| {
            if (prev.kind == change.kind and now_ms - prev.at_ms < 600) {
                const same_window = windowId(prev.*) == windowId(change) and windowId(change) != 0;
                const same_camera = prev.camera != null and change.camera != null and prev.window == null and change.window == null;
                if (same_window or same_camera) {
                    prev.at_ms = now_ms;
                    return;
                }
            }
        }
        var c = change;
        c.at_ms = now_ms;
        undo.slot = c;
    }

    fn windowId(c: Change) u64 {
        return if (c.window) |w| w.id else 0;
    }

    /// Clear the slot and pending gesture (e.g. on lock / unlock).
    pub fn clear(undo: *Undo) void {
        undo.slot = null;
        undo.pending = null;
    }
};

// ─── Unit tests ──────────────────────────────────────────────────────────────

test "begin/commit records a move" {
    var u: Undo = .{};
    u.begin(.{ .kind = .move, .press_seq = 1, .at_ms = 0, .window = .{ .id = 5, .x = 10, .y = 20, .width = 800, .height = 600, .zoom_index = 0 } });
    u.commit(100, .{ .window = .{ .id = 5, .x = 50, .y = 20, .width = 800, .height = 600, .zoom_index = 0 } });
    const s = u.slot orelse return error.NoSlot;
    try std.testing.expectEqual(Kind.move, s.kind);
    try std.testing.expectEqual(@as(u64, 5), s.window.?.id);
    try std.testing.expectEqual(@as(i32, 10), s.window.?.x);
}

test "zero-pixel drag without focus change is dropped as no-op" {
    var u: Undo = .{};
    u.begin(.{ .kind = .move, .press_seq = 1, .at_ms = 0, .window = .{ .id = 5, .x = 10, .y = 20, .width = 800, .height = 600, .zoom_index = 0 } });
    u.commit(100, .{ .window = .{ .id = 5, .x = 10, .y = 20, .width = 800, .height = 600, .zoom_index = 0 } });
    try std.testing.expect(u.slot == null);
}

test "a drag that only changes the layout is kept" {
    var u: Undo = .{};
    u.begin(.{ .kind = .move, .press_seq = 1, .at_ms = 0, .window = .{ .id = 5, .x = 0, .y = 0, .width = 1280, .height = 640, .zoom_index = 0, .layout = .maximized } });
    u.commit(100, .{ .window = .{ .id = 5, .x = 0, .y = 0, .width = 640, .height = 480, .zoom_index = 0 } });
    const s = u.slot orelse return error.NoSlot;
    try std.testing.expect(s.window.?.layout.eql(.maximized));
}

test "zero-pixel drag with folded focus becomes focus undo" {
    var u: Undo = .{};
    u.record(.{ .kind = .focus, .press_seq = 2, .at_ms = 0, .focus = 99 }, 0);
    u.begin(.{ .kind = .move, .press_seq = 2, .at_ms = 0, .window = .{ .id = 5, .x = 10, .y = 20, .width = 800, .height = 600, .zoom_index = 0 } });
    // Live x,y same as snapshot
    u.commit(100, .{ .window = .{ .id = 5, .x = 10, .y = 20, .width = 800, .height = 600, .zoom_index = 0 } });
    const s = u.slot orelse return error.NoSlot;
    try std.testing.expectEqual(Kind.focus, s.kind);
    try std.testing.expectEqual(@as(u64, 99), s.focus.?);
    try std.testing.expect(s.window == null);
}

test "zero-delta pan is dropped as no-op" {
    var u: Undo = .{};
    u.begin(.{ .kind = .pan, .press_seq = 1, .at_ms = 0, .camera = .{ .offset_x = 10, .offset_y = 20, .zoom_index = 0 } });
    u.commit(100, .{ .camera = .{ .offset_x = 10, .offset_y = 20, .zoom_index = 0 } });
    try std.testing.expect(u.slot == null);
}

test "drop discards in-flight gesture" {
    var u: Undo = .{};
    u.begin(.{ .kind = .move, .press_seq = 1, .at_ms = 0, .window = .{ .id = 5, .x = 10, .y = 20, .width = 800, .height = 600, .zoom_index = 0 } });
    u.drop();
    try std.testing.expect(u.pending == null);
    try std.testing.expect(u.slot == null);
}

test "focus record overwrites slot" {
    var u: Undo = .{};
    u.record(.{ .kind = .focus, .press_seq = 1, .at_ms = 0, .focus = 7 }, 0);
    u.record(.{ .kind = .focus, .press_seq = 2, .at_ms = 700, .focus = 9 }, 700);
    const s = u.slot orelse return error.NoSlot;
    try std.testing.expectEqual(@as(u64, 9), s.focus.?);
}

test "coalescing keeps older snapshot within 600ms" {
    var u: Undo = .{};
    u.record(.{ .kind = .camera_zoom, .press_seq = 1, .at_ms = 0, .camera = .{ .offset_x = 0, .offset_y = 0, .zoom_index = 0 } }, 0);
    // Second camera_zoom within 600ms: keep the FIRST snapshot, update at_ms
    u.record(.{ .kind = .camera_zoom, .press_seq = 2, .at_ms = 500, .camera = .{ .offset_x = 0, .offset_y = 0, .zoom_index = 1 } }, 500);
    const s = u.slot orelse return error.NoSlot;
    // zoom_index from first snapshot
    try std.testing.expectEqual(@as(usize, 0), s.camera.?.zoom_index);
    try std.testing.expectEqual(@as(i64, 500), s.at_ms);
}

test "coalescing resets after 600ms" {
    var u: Undo = .{};
    u.record(.{ .kind = .camera_zoom, .press_seq = 1, .at_ms = 0, .camera = .{ .offset_x = 0, .offset_y = 0, .zoom_index = 0 } }, 0);
    u.record(.{ .kind = .camera_zoom, .press_seq = 2, .at_ms = 601, .camera = .{ .offset_x = 0, .offset_y = 0, .zoom_index = 1 } }, 601);
    const s = u.slot orelse return error.NoSlot;
    try std.testing.expectEqual(@as(usize, 1), s.camera.?.zoom_index);
}

test "press folding: move inherits focus from same press_seq" {
    var u: Undo = .{};
    // focus change happens first on press_seq 3
    u.record(.{ .kind = .focus, .press_seq = 3, .at_ms = 0, .focus = 42 }, 0);
    // then a move begin on the same press_seq
    u.begin(.{ .kind = .move, .press_seq = 3, .at_ms = 0, .window = .{ .id = 5, .x = 0, .y = 0, .width = 100, .height = 100, .zoom_index = 0 } });
    u.commit(50, .{ .window = .{ .id = 5, .x = 50, .y = 0, .width = 100, .height = 100, .zoom_index = 0 } });
    const s = u.slot orelse return error.NoSlot;
    try std.testing.expectEqual(Kind.move, s.kind);
    try std.testing.expectEqual(@as(u64, 42), s.focus.?);
}

test "re-entrancy guard: record inside apply is a no-op" {
    var u: Undo = .{};
    u.record(.{ .kind = .focus, .press_seq = 1, .at_ms = 0, .focus = 7 }, 0);
    u.applying = true;
    u.record(.{ .kind = .focus, .press_seq = 2, .at_ms = 100, .focus = 9 }, 100);
    u.applying = false;
    const s = u.slot orelse return error.NoSlot;
    try std.testing.expectEqual(@as(u64, 7), s.focus.?); // unchanged
}

test "begin is no-op when pending is set" {
    var u: Undo = .{};
    u.begin(.{ .kind = .move, .press_seq = 1, .at_ms = 0, .window = .{ .id = 5, .x = 0, .y = 0, .width = 100, .height = 100, .zoom_index = 0 } });
    u.begin(.{ .kind = .pan, .press_seq = 2, .at_ms = 10, .camera = .{ .offset_x = 0, .offset_y = 0, .zoom_index = 0 } });
    try std.testing.expectEqual(Kind.move, u.pending.?.kind); // first one wins
}

test "clear empties slot and pending" {
    var u: Undo = .{};
    u.record(.{ .kind = .focus, .press_seq = 1, .at_ms = 0, .focus = 3 }, 0);
    u.begin(.{ .kind = .move, .press_seq = 2, .at_ms = 0, .window = .{ .id = 1, .x = 0, .y = 0, .width = 100, .height = 100, .zoom_index = 0 } });
    u.clear();
    try std.testing.expect(u.slot == null);
    try std.testing.expect(u.pending == null);
}

test "commitPending commits an in-flight gesture" {
    var u: Undo = .{};
    u.begin(.{ .kind = .pan, .press_seq = 1, .at_ms = 0, .camera = .{ .offset_x = 5, .offset_y = 10, .zoom_index = 0 } });
    u.commitPending(100, .{ .camera = .{ .offset_x = 50, .offset_y = 10, .zoom_index = 0 } });
    try std.testing.expect(u.pending == null);
    try std.testing.expect(u.slot != null);
}
