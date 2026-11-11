//! rediwm-msg reply printing: JSON and the readable text forms.

const std = @import("std");
const protocol = @import("protocol");

pub fn printUnwrappedJson(ok_val: std.json.Value, key: []const u8) !void {
    if (ok_val == .object) {
        if (ok_val.object.get(key)) |inner| {
            try printJsonValue(inner);
            return;
        }
    }
    try printJsonValue(ok_val);
}

pub fn printJsonValue(val: std.json.Value) !void {
    const c = std.posix.system;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.heap.c_allocator);
    var bw = protocol.BufferWriter{ .list = &list, .allocator = std.heap.c_allocator };
    try bw.print("{f}\n", .{std.json.fmt(val, .{})});
    _ = c.write(std.posix.STDOUT_FILENO, list.items.ptr, list.items.len);
}

pub fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |s| {
        _ = std.posix.system.write(std.posix.STDOUT_FILENO, s.ptr, s.len);
    } else |_| {
        if (std.fmt.allocPrint(std.heap.c_allocator, fmt, args)) |s| {
            defer std.heap.c_allocator.free(s);
            _ = std.posix.system.write(std.posix.STDOUT_FILENO, s.ptr, s.len);
        } else |_| {}
    }
}

pub fn printTextReply(val: std.json.Value) void {
    switch (val) {
        .string => |s| printOut("{s}\n", .{s}),
        .object => |obj| {
            if (obj.get("Version")) |v| {
                if (v == .string) printOut("rediwm {s}\n", .{v.string});
            } else if (obj.get("Capabilities")) |caps| {
                printOut("Capabilities:\n", .{});
                if (caps == .array) {
                    for (caps.array.items) |c_val| {
                        if (c_val == .string) printOut("  - {s}\n", .{c_val.string});
                    }
                }
            } else if (obj.get("Windows")) |wins| {
                if (wins == .array) {
                    printOut("Windows ({d}):\n", .{wins.array.items.len});
                    for (wins.array.items) |w| {
                        if (w == .object) {
                            const id = if (w.object.get("id")) |i| if (i == .integer) i.integer else 0 else 0;
                            const title = if (w.object.get("title")) |t| if (t == .string) t.string else "<no title>" else "<no title>";
                            const app = if (w.object.get("app_id")) |a| if (a == .string) a.string else "<no app_id>" else "<no app_id>";
                            const focused = if (w.object.get("is_focused")) |f| if (f == .bool) f.bool else false else false;
                            const urgent = if (w.object.get("is_urgent")) |u| if (u == .bool) u.bool else false else false;
                            const min = if (w.object.get("is_minimized")) |m| if (m == .bool) m.bool else false else false;
                            const x = if (w.object.get("x")) |i| if (i == .integer) i.integer else 0 else 0;
                            const y = if (w.object.get("y")) |i| if (i == .integer) i.integer else 0 else 0;
                            const w_px = if (w.object.get("width")) |i| if (i == .integer) i.integer else 0 else 0;
                            const h_px = if (w.object.get("height")) |i| if (i == .integer) i.integer else 0 else 0;

                            printOut("  [{d}] {s} ({s}) at ({d},{d}) size {d}x{d}{s}{s}{s}\n", .{
                                id,
                                title,
                                app,
                                x,
                                y,
                                w_px,
                                h_px,
                                if (focused) " [focused]" else "",
                                if (min) " [minimized]" else "",
                                if (urgent) " [urgent]" else "",
                            });
                        }
                    }
                }
            } else if (obj.get("Outputs")) |outs| {
                if (outs == .array) {
                    printOut("Outputs ({d}):\n", .{outs.array.items.len});
                    for (outs.array.items) |o| {
                        if (o == .object) {
                            const name = if (o.object.get("name")) |n| if (n == .string) n.string else "?" else "?";
                            const lw = if (o.object.get("logical_width")) |i| if (i == .integer) i.integer else 0 else 0;
                            const lh = if (o.object.get("logical_height")) |i| if (i == .integer) i.integer else 0 else 0;
                            const scale = if (o.object.get("scale")) |s| if (s == .float) s.float else 1.0 else 1.0;
                            const focused = if (o.object.get("is_focused")) |f| if (f == .bool) f.bool else false else false;
                            printOut("  {s}: {d}x{d} @ scale {d:.1}{s}\n", .{ name, lw, lh, scale, if (focused) " [focused]" else "" });
                        }
                    }
                }
            } else if (obj.get("FocusedWindow")) |fw| {
                if (fw == .null) {
                    printOut("No window focused\n", .{});
                } else if (fw == .object) {
                    const id = if (fw.object.get("id")) |i| if (i == .integer) i.integer else 0 else 0;
                    const title = if (fw.object.get("title")) |t| if (t == .string) t.string else "<no title>" else "<no title>";
                    printOut("Focused window [{d}]: {s}\n", .{ id, title });
                }
            } else if (obj.get("Workspaces")) |workspaces| {
                if (workspaces == .array) for (workspaces.array.items) |workspace| {
                    if (workspace != .object) continue;
                    const id = workspace.object.get("id") orelse continue;
                    const name = workspace.object.get("name") orelse continue;
                    if (id == .integer and name == .string) printOut("Workspace [{d}]: {s}\n", .{ id.integer, name.string });
                };
            } else if (obj.get("PanelStats")) |ps| {
                if (ps == .object) {
                    const paints = if (ps.object.get("paints")) |v| if (v == .integer) v.integer else 0 else 0;
                    const allocated = if (ps.object.get("allocated_bytes")) |v| if (v == .integer) v.integer else 0 else 0;
                    const reused = if (ps.object.get("reused_bytes")) |v| if (v == .integer) v.integer else 0 else 0;
                    const paint_ns = if (ps.object.get("paint_ns")) |v| if (v == .integer) v.integer else 0 else 0;
                    printOut("Panel paints: {d}\nAllocated bytes: {d}\nReused bytes: {d}\nPaint ns: {d}\n", .{ paints, allocated, reused, paint_ns });
                }
            } else if (obj.get("AudioState")) |as| {
                if (as == .object) {
                    const vol = if (as.object.get("master_volume")) |v| if (v == .float) v.float else 0 else 0;
                    const muted = if (as.object.get("master_muted")) |m| if (m == .bool) m.bool else false else false;
                    const sink = if (as.object.get("default_sink")) |s| if (s == .string) s.string else "?" else "?";
                    printOut("Output: {s}\nMaster volume: {d:.0}%{s}\n", .{ sink, vol * 100, if (muted) " (muted)" else "" });
                    if (as.object.get("streams")) |streams| {
                        if (streams == .array) {
                            for (streams.array.items) |st| {
                                if (st != .object) continue;
                                const name = if (st.object.get("name")) |n| if (n == .string) n.string else "?" else "?";
                                const svol = if (st.object.get("volume")) |v| if (v == .float) v.float else 0 else 0;
                                const smuted = if (st.object.get("muted")) |m| if (m == .bool) m.bool else false else false;
                                printOut("  {s}: {d:.0}%{s}\n", .{ name, svol * 100, if (smuted) " (muted)" else "" });
                            }
                        }
                    }
                }
            } else if (obj.get("Screenshot")) |sc| {
                if (sc == .object) {
                    const w = if (sc.object.get("width")) |i| if (i == .integer) i.integer else 0 else 0;
                    const h = if (sc.object.get("height")) |i| if (i == .integer) i.integer else 0 else 0;
                    const out_n = if (sc.object.get("output_name")) |n| if (n == .string) n.string else "?" else "?";
                    const mode_s = if (sc.object.get("capture_mode")) |m| if (m == .string) m.string else "?" else "?";
                    const seq = if (sc.object.get("frame_seq")) |s| if (s == .integer) s.integer else 0 else 0;

                    if (sc.object.get("path")) |p| {
                        if (p == .string) {
                            printOut("Screenshot saved: {s} ({d}x{d}, output {s}, mode {s}, frame {d})\n", .{ p.string, w, h, out_n, mode_s, seq });
                            return;
                        }
                    }
                    printOut("Screenshot {d}x{d} (output {s}, mode {s}, frame {d})\n", .{ w, h, out_n, mode_s, seq });
                }
            } else if (obj.get("DescribeIPC")) |d| {
                if (d == .object) {
                    const backend = if (d.object.get("backend")) |b| if (b == .string) b.string else "?" else "?";
                    const renderer = if (d.object.get("renderer")) |r| if (r == .string) r.string else "?" else "?";
                    printOut("Compositor backend: {s}, renderer: {s}\n", .{ backend, renderer });
                    if (d.object.get("commands")) |cmds| {
                        if (cmds == .array) {
                            printOut("Available commands ({d}):\n", .{cmds.array.items.len});
                            for (cmds.array.items) |cmd| {
                                if (cmd == .object) {
                                    const name = if (cmd.object.get("name")) |n| if (n == .string) n.string else "?" else "?";
                                    const kind = if (cmd.object.get("kind")) |k| if (k == .string) k.string else "?" else "?";
                                    const desc = if (cmd.object.get("description")) |ds| if (ds == .string) ds.string else "" else "";
                                    printOut("  [{s}] {s} - {s}\n", .{ kind, name, desc });
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("State")) |st| {
                if (st == .object) {
                    const seq = if (st.object.get("seq")) |s| if (s == .integer) s.integer else 0 else 0;
                    const session = if (st.object.get("session_id")) |s| if (s == .string) s.string else "" else "";
                    printOut("State (seq {d}, session {s}):\n", .{ seq, session });
                    if (st.object.get("windows")) |w| {
                        if (w == .array) printOut("  Windows: {d} mapped\n", .{w.array.items.len});
                    }
                    if (st.object.get("outputs")) |o| {
                        if (o == .array) printOut("  Outputs: {d} active\n", .{o.array.items.len});
                    }
                    if (st.object.get("focused_window_id")) |f| {
                        if (f == .integer) {
                            printOut("  Focused window: [{d}]\n", .{f.integer});
                        } else {
                            printOut("  Focused window: none\n", .{});
                        }
                    }
                }
            } else if (obj.get("WindowDebug")) |wd| {
                if (wd == .object) {
                    const id = if (wd.object.get("id")) |i| if (i == .integer) i.integer else 0 else 0;
                    const title = if (wd.object.get("title")) |t| if (t == .string) t.string else "<none>" else "<none>";
                    const app = if (wd.object.get("app_id")) |a| if (a == .string) a.string else "<none>" else "<none>";
                    const min = if (wd.object.get("minimized")) |m| if (m == .bool) m.bool else false else false;
                    const max = if (wd.object.get("maximized")) |m| if (m == .bool) m.bool else false else false;
                    const fs = if (wd.object.get("fullscreen")) |f| if (f == .bool) f.bool else false else false;
                    const zoom = if (wd.object.get("zoom_percent")) |z| if (z == .integer) z.integer else 100 else 100;
                    const bw = if (wd.object.get("buffer_width")) |w| if (w == .integer) w.integer else 0 else 0;
                    const bh = if (wd.object.get("buffer_height")) |h| if (h == .integer) h.integer else 0 else 0;
                    const bscale = if (wd.object.get("buffer_scale")) |s| if (s == .float) s.float else 1.0 else 1.0;
                    printOut("Window [{d}] \"{s}\" (app: {s}):\n", .{ id, title, app });
                    printOut("  State: minimized={}, maximized={}, fullscreen={}, zoom={d}%\n", .{ min, max, fs, zoom });
                    printOut("  Buffer: {d}x{d} @ scale {d:.1}\n", .{ bw, bh, bscale });
                    if (wd.object.get("client_box")) |cb| {
                        if (cb == .object) {
                            const cx = if (cb.object.get("x")) |v| if (v == .integer) v.integer else 0 else 0;
                            const cy = if (cb.object.get("y")) |v| if (v == .integer) v.integer else 0 else 0;
                            const cw = if (cb.object.get("width")) |v| if (v == .integer) v.integer else 0 else 0;
                            const ch = if (cb.object.get("height")) |v| if (v == .integer) v.integer else 0 else 0;
                            printOut("  Client box: ({d},{d}) {d}x{d}\n", .{ cx, cy, cw, ch });
                        }
                    }
                }
            } else if (obj.get("ShellState")) |ss| {
                if (ss == .object) {
                    printOut("Shell State:\n", .{});
                    const sm = ss.object.get("start_menu");
                    printOut("  Start menu: {s}\n", .{if (sm != null and sm.? != .null) "open" else "closed"});
                    const cc = ss.object.get("control_center");
                    printOut("  Control center: {s}\n", .{if (cc != null and cc.? != .null) "open" else "closed"});
                    const pm = ss.object.get("power_menu");
                    printOut("  Power menu: {s}\n", .{if (pm != null and pm.? != .null) "open" else "closed"});
                    if (ss.object.get("taskbars")) |tb| {
                        if (tb == .array) printOut("  Taskbars: {d} active\n", .{tb.array.items.len});
                    }
                }
            } else if (obj.get("InputState")) |is| {
                if (is == .object) {
                    const px = if (is.object.get("pointer_x")) |x| if (x == .float) x.float else 0 else 0;
                    const py = if (is.object.get("pointer_y")) |y| if (y == .float) y.float else 0 else 0;
                    const cm = if (is.object.get("cursor_mode")) |m| if (m == .string) m.string else "passthrough" else "passthrough";
                    printOut("Input State:\n", .{});
                    printOut("  Pointer: ({d:.1}, {d:.1}) mode: {s}\n", .{ px, py, cm });
                    if (is.object.get("pointer_focused_window_id")) |p_id| {
                        if (p_id == .integer) printOut("  Pointer focus: [{d}]\n", .{p_id.integer});
                    }
                    if (is.object.get("keyboard_focused_window_id")) |k_id| {
                        if (k_id == .integer) printOut("  Keyboard focus: [{d}]\n", .{k_id.integer});
                    }
                }
            } else if (obj.get("HitTest")) |ht| {
                if (ht == .object) {
                    const tt = if (ht.object.get("target_type")) |t| if (t == .string) t.string else "?" else "?";
                    const lx = if (ht.object.get("local_x")) |x| if (x == .float) x.float else 0 else 0;
                    const ly = if (ht.object.get("local_y")) |y| if (y == .float) y.float else 0 else 0;
                    printOut("Hit Test: target={s} local=({d:.1},{d:.1})", .{ tt, lx, ly });
                    if (ht.object.get("window_id")) |w| {
                        if (w == .integer) printOut(" window_id={d}", .{w.integer});
                    }
                    if (ht.object.get("widget")) |wg| {
                        if (wg == .string) printOut(" widget={s}", .{wg.string});
                    }
                    if (ht.object.get("output")) |out| {
                        if (out == .string) printOut(" output={s}", .{out.string});
                    }
                    printOut("\n", .{});
                }
            } else if (obj.get("SceneTree")) |st| {
                if (st == .object) {
                    const total = if (st.object.get("total_nodes")) |t| if (t == .integer) t.integer else 0 else 0;
                    printOut("Scene Tree ({d} nodes):\n", .{total});
                    if (st.object.get("nodes")) |nodes| {
                        if (nodes == .array) {
                            for (nodes.array.items) |node| {
                                if (node == .object) {
                                    const id = if (node.object.get("id")) |i| if (i == .integer) i.integer else 0 else 0;
                                    const role = if (node.object.get("role")) |r| if (r == .string) r.string else "?" else "?";
                                    const ntype = if (node.object.get("node_type")) |t| if (t == .string) t.string else "?" else "?";
                                    const en = if (node.object.get("enabled")) |e| if (e == .bool) e.bool else false else false;
                                    const nx = if (node.object.get("x")) |x| if (x == .integer) x.integer else 0 else 0;
                                    const ny = if (node.object.get("y")) |y| if (y == .integer) y.integer else 0 else 0;
                                    printOut("  [{d}] {s} ({s}) at ({d},{d}) enabled={}\n", .{ id, role, ntype, nx, ny, en });
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("LayerSurfaces")) |ls| {
                if (ls == .object) {
                    if (ls.object.get("surfaces")) |surfs| {
                        if (surfs == .array) {
                            printOut("Layer Surfaces ({d}):\n", .{surfs.array.items.len});
                            for (surfs.array.items) |s| {
                                if (s == .object) {
                                    const ns = if (s.object.get("namespace")) |n| if (n == .string) n.string else "?" else "?";
                                    const layer = if (s.object.get("layer")) |l| if (l == .string) l.string else "?" else "?";
                                    const out = if (s.object.get("output")) |o| if (o == .string) o.string else "?" else "?";
                                    printOut("  [{s}] {s} on {s}\n", .{ layer, ns, out });
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("WidgetTree")) |wt| {
                if (wt == .object) {
                    const pnl = if (wt.object.get("panel")) |p| if (p == .string) p.string else "?" else "?";
                    printOut("Widget Tree ({s}):\n", .{pnl});
                    if (wt.object.get("widgets")) |w_arr| {
                        if (w_arr == .array) {
                            for (w_arr.array.items) |w| {
                                if (w == .object) {
                                    const id = if (w.object.get("id")) |i| if (i == .integer) i.integer else 0 else 0;
                                    const role = if (w.object.get("role")) |r| if (r == .string) r.string else "?" else "?";
                                    const label = if (w.object.get("label")) |l| if (l == .string) l.string else "" else "";
                                    const path = if (w.object.get("path")) |p| if (p == .string) p.string else null else null;
                                    if (path) |p| {
                                        printOut("  [{d}] {s} path={s} \"{s}\"\n", .{ id, role, p, label });
                                    } else {
                                        printOut("  [{d}] {s} \"{s}\"\n", .{ id, role, label });
                                    }
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("ListPanels")) |lp| {
                if (lp == .object) {
                    if (lp.object.get("panels")) |p_arr| {
                        if (p_arr == .array) {
                            printOut("Panels:\n", .{});
                            for (p_arr.array.items) |p| {
                                if (p == .object) {
                                    const name = if (p.object.get("name")) |n| if (n == .string) n.string else "?" else "?";
                                    const is_open = if (p.object.get("open")) |o| if (o == .bool) o.bool else false else false;
                                    printOut("  {s}: {s}\n", .{ name, if (is_open) "open" else "closed" });
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("ConfigStatus")) |cs| {
                if (cs == .object) {
                    const path = if (cs.object.get("config_path")) |p| if (p == .string) p.string else "<default>" else "<default>";
                    const gen = if (cs.object.get("generation")) |g| if (g == .integer) g.integer else 0 else 0;
                    const res = if (cs.object.get("last_reload_result")) |r| if (r == .string) r.string else "ok" else "ok";
                    printOut("Config: {s} (generation {d}, status: {s})\n", .{ path, gen, res });
                    if (cs.object.get("last_reload_error")) |err_val| {
                        if (err_val == .string) printOut("  Error: {s}\n", .{err_val.string});
                    }
                }
            } else if (obj.get("RuntimeInfo")) |ri| {
                if (ri == .object) {
                    const comp = if (ri.object.get("compositor")) |c_val| if (c_val == .string) c_val.string else "rediwm" else "rediwm";
                    const ver = if (ri.object.get("version")) |v| if (v == .string) v.string else "0.1.0" else "0.1.0";
                    const wlv = if (ri.object.get("wlroots_version")) |w| if (w == .string) w.string else "0.20" else "0.20";
                    const backend = if (ri.object.get("backend")) |b| if (b == .string) b.string else "?" else "?";
                    const renderer = if (ri.object.get("renderer")) |r| if (r == .string) r.string else "?" else "?";
                    const session = if (ri.object.get("session_id")) |s| if (s == .string) s.string else "" else "";
                    printOut("{s} {s} (wlroots {s}, backend: {s}, renderer: {s}, session: {s})\n", .{ comp, ver, wlv, backend, renderer, session });
                }
            } else if (obj.get("PerformanceStats")) |ps| {
                if (ps == .object) {
                    const commits = if (ps.object.get("output_commits")) |c_val| if (c_val == .integer) c_val.integer else 0 else 0;
                    const failed = if (ps.object.get("output_failed_commits")) |f| if (f == .integer) f.integer else 0 else 0;
                    const fps = if (ps.object.get("fps")) |v| switch (v) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 0,
                    } else 0;
                    const frame_ms = if (ps.object.get("frame_time_ms")) |v| switch (v) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 0,
                    } else 0;
                    const missed = if (ps.object.get("missed_frames")) |v| if (v == .integer) v.integer else 0 else 0;
                    const tb_paints = if (ps.object.get("titlebar_paints")) |tp| if (tp == .integer) tp.integer else 0 else 0;
                    const ft_paints = if (ps.object.get("footer_paints")) |fp| if (fp == .integer) fp.integer else 0 else 0;
                    const edge_att = if (ps.object.get("edge_samples_attempted")) |v| if (v == .integer) v.integer else 0 else 0;
                    const edge_ok = if (ps.object.get("edge_samples_succeeded")) |v| if (v == .integer) v.integer else 0 else 0;
                    const edge_skip = if (ps.object.get("edge_samples_skipped")) |v| if (v == .integer) v.integer else 0 else 0;
                    const pnl_paints = if (ps.object.get("panel_paints")) |pp| if (pp == .integer) pp.integer else 0 else 0;
                    printOut("Performance Stats:\n", .{});
                    printOut("  {d:.1} commits/s, {d:.1} ms commit interval, {d} estimated missed\n", .{ fps, frame_ms, missed });
                    if (ps.object.get("frame_work")) |work| {
                        if (work == .object) {
                            inline for (.{ "cpu_frame", "taskbar_cpu", "chrome_cpu", "panels_cpu", "projection_cpu", "glass_cpu", "scene_commit_cpu", "gpu_elapsed" }) |name| {
                                if (work.object.get(name)) |duration| {
                                    if (duration == .object) {
                                        printOut("  {s}: {f}\n", .{ name, std.json.fmt(duration, .{}) });
                                    }
                                }
                            }
                            if (work.object.get("gpu_timing_available")) |available| {
                                if (available == .bool and !available.bool)
                                    printOut("  GPU timing unavailable on this renderer\n", .{});
                            }
                        }
                    }
                    printOut("  Output commits: {d} (failed: {d})\n", .{ commits, failed });
                    printOut("  Titlebar paints: {d}, Footer paints: {d}\n", .{ tb_paints, ft_paints });
                    printOut("  Edge samples: {d} attempted, {d} succeeded, {d} skipped\n", .{ edge_att, edge_ok, edge_skip });
                    printOut("  Panel paints: {d}\n", .{pnl_paints});
                }
            } else if (obj.get("WaitFor")) |wf| {
                if (wf == .object) {
                    const cond = if (wf.object.get("condition")) |c_val| if (c_val == .string) c_val.string else "?" else "?";
                    const elapsed = if (wf.object.get("elapsed_ms")) |e| if (e == .integer) e.integer else 0 else 0;
                    const timed_out = if (wf.object.get("timed_out")) |t| if (t == .bool) t.bool else false else false;
                    if (timed_out) {
                        printOut("Wait condition '{s}' timed out after {d}ms\n", .{ cond, elapsed });
                    } else {
                        printOut("Wait condition '{s}' satisfied in {d}ms\n", .{ cond, elapsed });
                    }
                }
            } else if (obj.get("WaitForFrame")) |wff| {
                if (wff == .object) {
                    const out = if (wff.object.get("output")) |o| if (o == .string) o.string else "?" else "?";
                    const seq = if (wff.object.get("frame_seq")) |s| if (s == .integer) s.integer else 0 else 0;
                    const elapsed = if (wff.object.get("elapsed_ms")) |e| if (e == .integer) e.integer else 0 else 0;
                    const timed_out = if (wff.object.get("timed_out")) |t| if (t == .bool) t.bool else false else false;
                    if (timed_out) {
                        printOut("Wait for frame on {s} timed out after {d}ms\n", .{ out, elapsed });
                    } else {
                        printOut("Frame {d} rendered on {s} in {d}ms\n", .{ seq, out, elapsed });
                    }
                }
            } else if (obj.get("DumpBuffer")) |db| {
                if (db == .object) {
                    const tgt = if (db.object.get("target")) |t| if (t == .string) t.string else "?" else "?";
                    const w = if (db.object.get("width")) |v| if (v == .integer) v.integer else 0 else 0;
                    const h = if (db.object.get("height")) |v| if (v == .integer) v.integer else 0 else 0;
                    const stride = if (db.object.get("stride")) |s| if (s == .integer) s.integer else 0 else 0;
                    printOut("Dumped buffer ({s}): {d}x{d}, stride {d}\n", .{ tgt, w, h, stride });
                }
            } else if (obj.get("SamplePixels")) |sp| {
                if (sp == .object) {
                    const out = if (sp.object.get("output")) |o| if (o == .string) o.string else "?" else "?";
                    const w = if (sp.object.get("width")) |v| if (v == .integer) v.integer else 0 else 0;
                    const h = if (sp.object.get("height")) |v| if (v == .integer) v.integer else 0 else 0;
                    printOut("Sampled {d}x{d} pixels on {s}\n", .{ w, h, out });
                }
            } else if (obj.get("WindowRules")) |wr| {
                if (wr == .object) {
                    const wid = if (wr.object.get("window_id")) |w| if (w == .integer) w.integer else 0 else 0;
                    printOut("Window Rules for [{d}]:\n", .{wid});
                    if (wr.object.get("matched_rules")) |mr| {
                        if (mr == .array) {
                            printOut("  Matched rules: [", .{});
                            for (mr.array.items, 0..) |item, i| {
                                if (i > 0) printOut(", ", .{});
                                if (item == .integer) printOut("{d}", .{item.integer});
                            }
                            printOut("]\n", .{});
                        }
                    }
                    if (wr.object.get("open")) |o| {
                        printOut("  Open rules: {f}\n", .{std.json.fmt(o, .{})});
                    }
                    if (wr.object.get("live")) |l| {
                        printOut("  Live rules: {f}\n", .{std.json.fmt(l, .{})});
                    }
                    if (wr.object.get("resolved_before_app_id")) |r| {
                        if (r == .bool) printOut("  Resolved before app_id: {}\n", .{r.bool});
                    }
                }
            } else if (obj.get("MatchWindowRules")) |mwr| {
                if (mwr == .object) {
                    printOut("Match Window Rules:\n", .{});
                    if (mwr.object.get("matched_rules")) |mr| {
                        if (mr == .array) {
                            printOut("  Matched rules: [", .{});
                            for (mr.array.items, 0..) |item, i| {
                                if (i > 0) printOut(", ", .{});
                                if (item == .integer) printOut("{d}", .{item.integer});
                            }
                            printOut("]\n", .{});
                        }
                    }
                    if (mwr.object.get("open")) |o| {
                        printOut("  Open rules: {f}\n", .{std.json.fmt(o, .{})});
                    }
                    if (mwr.object.get("live")) |l| {
                        printOut("  Live rules: {f}\n", .{std.json.fmt(l, .{})});
                    }
                }
            } else if (obj.get("NightLight")) |nl| {
                if (nl == .object) {
                    const enabled = if (nl.object.get("enabled")) |e| if (e == .bool) e.bool else false else false;
                    const sched = if (nl.object.get("schedule")) |s| if (s == .string) s.string else "?" else "?";
                    const phase = if (nl.object.get("phase")) |p| if (p == .string) p.string else "?" else "?";
                    const temp = if (nl.object.get("temperature")) |t| if (t == .integer) t.integer else 0 else 0;
                    const overridden = if (nl.object.get("clock_overridden")) |c| if (c == .bool) c.bool else false else false;
                    printOut("Night Light: {s} (schedule: {s}, phase: {s}, temp: {d}K", .{
                        if (enabled) "enabled" else "disabled",
                        sched,
                        phase,
                        temp,
                    });
                    if (overridden) {
                        printOut(", clock overridden", .{});
                    }
                    if (nl.object.get("next_change_unix")) |nc| {
                        if (nc == .integer) {
                            printOut(", next change: {d}", .{nc.integer});
                        }
                    }
                    printOut(")\n", .{});
                    if (nl.object.get("outputs")) |outs| {
                        if (outs == .array) {
                            for (outs.array.items) |out_item| {
                                if (out_item == .object) {
                                    const name = if (out_item.object.get("name")) |n| if (n == .string) n.string else "?" else "?";
                                    const gsize = if (out_item.object.get("gamma_size")) |g| if (g == .integer) g.integer else 0 else 0;
                                    const on = if (out_item.object.get("night_light")) |n| if (n == .bool) n.bool else false else false;
                                    const ot = if (out_item.object.get("temperature")) |t| if (t == .integer) t.integer else 0 else 0;
                                    const st = if (out_item.object.get("status")) |s| if (s == .string) s.string else "?" else "?";
                                    printOut("  {s}: status={s} gamma_size={d} night_light={s} temp={d}K", .{
                                        name,
                                        st,
                                        gsize,
                                        if (on) "on" else "off",
                                        ot,
                                    });
                                    if (out_item.object.get("gamma")) |gm| {
                                        if (gm == .float) {
                                            printOut(" gamma={d:.2}", .{gm.float});
                                        } else if (gm == .integer) {
                                            printOut(" gamma={d:.1}", .{@as(f64, @floatFromInt(gm.integer))});
                                        }
                                    }
                                    printOut("\n", .{});
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("KeyboardLayouts")) |state| {
                printOut("Keyboard layouts:\n{f}\n", .{std.json.fmt(state, .{ .whitespace = .indent_2 })});
            } else if (obj.get("InputSources")) |state| {
                printOut("Input sources:\n{f}\n", .{std.json.fmt(state, .{ .whitespace = .indent_2 })});
            } else if (obj.get("TextInput")) |state| {
                printOut("Text input:\n{f}\n", .{std.json.fmt(state, .{ .whitespace = .indent_2 })});
            } else if (obj.get("Notifications")) |notif_val| {
                if (notif_val == .object) {
                    const dnd = if (notif_val.object.get("dnd")) |d| if (d == .bool) d.bool else false else false;
                    printOut("Notifications (DND: {s}):\n", .{if (dnd) "on" else "off"});
                    if (notif_val.object.get("toasts")) |toasts| {
                        if (toasts == .array) {
                            printOut("Active Toasts ({d}):\n", .{toasts.array.items.len});
                            for (toasts.array.items) |item| {
                                if (item == .object) {
                                    const id = if (item.object.get("id")) |v| if (v == .integer) v.integer else 0 else 0;
                                    const app = if (item.object.get("app_name")) |v| if (v == .string) v.string else "" else "";
                                    const summary = if (item.object.get("summary")) |v| if (v == .string) v.string else "" else "";
                                    printOut("  [{d}] {s}: {s}\n", .{ id, app, summary });
                                }
                            }
                        }
                    }
                }
            } else {
                printOut("Handled\n", .{});
            }
        },
        else => printOut("Handled\n", .{}),
    }
}
