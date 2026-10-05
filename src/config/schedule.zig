const std = @import("std");

pub const ScheduleMode = enum {
    fixed,
    sun,
    always,
};

pub const NightLightConfig = struct {
    enabled: bool = true,
    schedule: ScheduleMode = .always,
    temperature: u16 = 5000,
    day_temperature: u16 = 6500,
    /// Minutes from midnight (0..1439)
    start: u16 = 21 * 60,
    /// Minutes from midnight (0..1439)
    end: u16 = 7 * 60,
    /// Duration of warming / cooling ramps in minutes (0..180)
    transition_minutes: u16 = 30,
    latitude: ?f64 = null,
    longitude: ?f64 = null,
};

pub const Phase = enum {
    off,
    day,
    to_night,
    night,
    to_day,
};

pub const EvaluationResult = struct {
    temperature: u16,
    phase: Phase,
    next_change_unix: ?i64,
};

/// Parses a 24-hour "HH:MM" clock string into minutes from midnight (0..1439).
pub fn parseClock(str: []const u8) !u16 {
    if (str.len != 5 or str[2] != ':') return error.InvalidValue;
    const hours = std.fmt.parseInt(u16, str[0..2], 10) catch return error.InvalidValue;
    const minutes = std.fmt.parseInt(u16, str[3..5], 10) catch return error.InvalidValue;
    if (hours > 23 or minutes > 59) return error.InvalidValue;
    return hours * 60 + minutes;
}

/// Evaluates the target color temperature, phase, and next scheduled boundary.
/// Takes explicit unix seconds and UTC offset in seconds so DST changes and midnight
/// crossings are deterministic and unit-testable without host clock dependencies.
pub fn evaluate(cfg: NightLightConfig, now_unix: i64, utc_offset_s: i32) EvaluationResult {
    if (!cfg.enabled) {
        return .{
            .temperature = cfg.day_temperature,
            .phase = .off,
            .next_change_unix = null,
        };
    }

    switch (cfg.schedule) {
        .always => return .{
            .temperature = cfg.temperature,
            .phase = .night,
            .next_change_unix = null,
        },
        .sun => {
            // Evaluated in Stage 4; placeholder returns day until solar.zig is integrated
            return .{
                .temperature = cfg.day_temperature,
                .phase = .day,
                .next_change_unix = null,
            };
        },
        .fixed => {
            const local_unix = now_unix + utc_offset_s;
            const local_sec = @mod(local_unix, 86400);

            const start_s: i64 = @as(i64, cfg.start) * 60;
            const end_s: i64 = @as(i64, cfg.end) * 60;
            const trans_s: i64 = @as(i64, cfg.transition_minutes) * 60;

            const night_span_s = @mod(end_s - start_s, 86400);
            const day_span_s = 86400 - night_span_s;

            const t_since_start = @mod(local_sec - start_s, 86400);

            const m_day = 1_000_000.0 / @as(f64, @floatFromInt(cfg.day_temperature));
            const m_night = 1_000_000.0 / @as(f64, @floatFromInt(cfg.temperature));

            if (t_since_start < night_span_s) {
                // Within night window
                if (trans_s > 0 and t_since_start < trans_s) {
                    const progress = @as(f64, @floatFromInt(t_since_start)) / @as(f64, @floatFromInt(trans_s));
                    const mired = m_day + progress * (m_night - m_day);
                    const temp = @as(u16, @intFromFloat(@round(1_000_000.0 / mired)));
                    return .{
                        .temperature = temp,
                        .phase = .to_night,
                        .next_change_unix = now_unix + (trans_s - t_since_start),
                    };
                } else {
                    return .{
                        .temperature = cfg.temperature,
                        .phase = .night,
                        .next_change_unix = now_unix + (night_span_s - t_since_start),
                    };
                }
            } else {
                // Within day window
                const t_since_end = t_since_start - night_span_s;
                if (trans_s > 0 and t_since_end < trans_s) {
                    const progress = @as(f64, @floatFromInt(t_since_end)) / @as(f64, @floatFromInt(trans_s));
                    const mired = m_night + progress * (m_day - m_night);
                    const temp = @as(u16, @intFromFloat(@round(1_000_000.0 / mired)));
                    return .{
                        .temperature = temp,
                        .phase = .to_day,
                        .next_change_unix = now_unix + (trans_s - t_since_end),
                    };
                } else {
                    return .{
                        .temperature = cfg.day_temperature,
                        .phase = .day,
                        .next_change_unix = now_unix + (day_span_s - t_since_end),
                    };
                }
            }
        },
    }
}

test "parseClock: valid and invalid format" {
    try std.testing.expectEqual(@as(u16, 0), try parseClock("00:00"));
    try std.testing.expectEqual(@as(u16, 1260), try parseClock("21:00"));
    try std.testing.expectEqual(@as(u16, 420), try parseClock("07:00"));
    try std.testing.expectEqual(@as(u16, 1439), try parseClock("23:59"));

    try std.testing.expectError(error.InvalidValue, parseClock("24:00"));
    try std.testing.expectError(error.InvalidValue, parseClock("12:60"));
    try std.testing.expectError(error.InvalidValue, parseClock("9:00"));
    try std.testing.expectError(error.InvalidValue, parseClock("09:0"));
    try std.testing.expectError(error.InvalidValue, parseClock("09-00"));
    try std.testing.expectError(error.InvalidValue, parseClock(""));
}

test "schedule: midnight-crossing window 21:00 to 07:00 with 30m transition" {
    const cfg = NightLightConfig{
        .enabled = true,
        .schedule = .fixed,
        .temperature = 4000,
        .day_temperature = 6500,
        .start = 21 * 60,
        .end = 7 * 60,
        .transition_minutes = 30,
    };

    // 20:59 local (1 minute before warming)
    const t_2059 = (20 * 60 + 59) * 60;
    const res_2059 = evaluate(cfg, t_2059, 0);
    try std.testing.expectEqual(Phase.day, res_2059.phase);
    try std.testing.expectEqual(@as(u16, 6500), res_2059.temperature);
    try std.testing.expectEqual(t_2059 + 60, res_2059.next_change_unix.?);

    // 21:00 local (warming begins)
    const t_2100 = 21 * 60 * 60;
    const res_2100 = evaluate(cfg, t_2100, 0);
    try std.testing.expectEqual(Phase.to_night, res_2100.phase);
    try std.testing.expectEqual(@as(u16, 6500), res_2100.temperature);
    try std.testing.expectEqual(t_2100 + 1800, res_2100.next_change_unix.?);

    // 21:15 local (ramp midpoint: mired halfway between 10^6/6500 and 10^6/4000 is 4952 K)
    const t_2115 = (21 * 60 + 15) * 60;
    const res_2115 = evaluate(cfg, t_2115, 0);
    try std.testing.expectEqual(Phase.to_night, res_2115.phase);
    try std.testing.expectEqual(@as(u16, 4952), res_2115.temperature);
    try std.testing.expectEqual(t_2115 + 900, res_2115.next_change_unix.?);

    // 21:30 local (warming finishes, steady night begins)
    const t_2130 = (21 * 60 + 30) * 60;
    const res_2130 = evaluate(cfg, t_2130, 0);
    try std.testing.expectEqual(Phase.night, res_2130.phase);
    try std.testing.expectEqual(@as(u16, 4000), res_2130.temperature);
    try std.testing.expectEqual(t_2130 + 570 * 60, res_2130.next_change_unix.?);

    // 06:59 local (1 minute before cooling)
    const t_0659 = (6 * 60 + 59) * 60;
    const res_0659 = evaluate(cfg, t_0659, 0);
    try std.testing.expectEqual(Phase.night, res_0659.phase);
    try std.testing.expectEqual(@as(u16, 4000), res_0659.temperature);
    try std.testing.expectEqual(t_0659 + 60, res_0659.next_change_unix.?);

    // 07:00 local (cooling begins)
    const t_0700 = 7 * 60 * 60;
    const res_0700 = evaluate(cfg, t_0700, 0);
    try std.testing.expectEqual(Phase.to_day, res_0700.phase);
    try std.testing.expectEqual(@as(u16, 4000), res_0700.temperature);
    try std.testing.expectEqual(t_0700 + 1800, res_0700.next_change_unix.?);

    // 07:15 local (cooling midpoint)
    const t_0715 = (7 * 60 + 15) * 60;
    const res_0715 = evaluate(cfg, t_0715, 0);
    try std.testing.expectEqual(Phase.to_day, res_0715.phase);
    try std.testing.expectEqual(@as(u16, 4952), res_0715.temperature);
    try std.testing.expectEqual(t_0715 + 900, res_0715.next_change_unix.?);

    // 07:30 local (cooling finishes, steady day begins)
    const t_0730 = (7 * 60 + 30) * 60;
    const res_0730 = evaluate(cfg, t_0730, 0);
    try std.testing.expectEqual(Phase.day, res_0730.phase);
    try std.testing.expectEqual(@as(u16, 6500), res_0730.temperature);
    try std.testing.expectEqual(t_0730 + 810 * 60, res_0730.next_change_unix.?);
}

test "schedule: non-midnight-crossing window 01:00 to 06:00" {
    const cfg = NightLightConfig{
        .enabled = true,
        .schedule = .fixed,
        .temperature = 3400,
        .day_temperature = 6500,
        .start = 1 * 60,
        .end = 6 * 60,
        .transition_minutes = 30,
    };

    // 00:30 local (day)
    const res_0030 = evaluate(cfg, 30 * 60, 0);
    try std.testing.expectEqual(Phase.day, res_0030.phase);
    try std.testing.expectEqual(@as(u16, 6500), res_0030.temperature);

    // 01:15 local (to_night)
    const res_0115 = evaluate(cfg, 75 * 60, 0);
    try std.testing.expectEqual(Phase.to_night, res_0115.phase);

    // 03:00 local (night)
    const res_0300 = evaluate(cfg, 180 * 60, 0);
    try std.testing.expectEqual(Phase.night, res_0300.phase);
    try std.testing.expectEqual(@as(u16, 3400), res_0300.temperature);

    // 06:15 local (to_day)
    const res_0615 = evaluate(cfg, 375 * 60, 0);
    try std.testing.expectEqual(Phase.to_day, res_0615.phase);
}

test "schedule: transition_minutes = 0 gives step change" {
    const cfg = NightLightConfig{
        .enabled = true,
        .schedule = .fixed,
        .temperature = 4000,
        .day_temperature = 6500,
        .start = 21 * 60,
        .end = 7 * 60,
        .transition_minutes = 0,
    };

    // 20:59 local: day
    const res_2059 = evaluate(cfg, (20 * 60 + 59) * 60, 0);
    try std.testing.expectEqual(Phase.day, res_2059.phase);
    try std.testing.expectEqual(@as(u16, 6500), res_2059.temperature);

    // 21:00 local: night immediately
    const res_2100 = evaluate(cfg, 21 * 60 * 60, 0);
    try std.testing.expectEqual(Phase.night, res_2100.phase);
    try std.testing.expectEqual(@as(u16, 4000), res_2100.temperature);

    // 06:59 local: night
    const res_0659 = evaluate(cfg, (6 * 60 + 59) * 60, 0);
    try std.testing.expectEqual(Phase.night, res_0659.phase);

    // 07:00 local: day immediately
    const res_0700 = evaluate(cfg, 7 * 60 * 60, 0);
    try std.testing.expectEqual(Phase.day, res_0700.phase);
    try std.testing.expectEqual(@as(u16, 6500), res_0700.temperature);
}

test "schedule: UTC offsets and DST shifts" {
    const cfg = NightLightConfig{
        .enabled = true,
        .schedule = .fixed,
        .temperature = 4000,
        .day_temperature = 6500,
        .start = 21 * 60,
        .end = 7 * 60,
        .transition_minutes = 30,
    };

    // Unix time corresponding to 20:30 UTC
    const now_utc = (20 * 60 + 30) * 60;

    // In UTC+0: local time is 20:30 (day)
    const res_utc = evaluate(cfg, now_utc, 0);
    try std.testing.expectEqual(Phase.day, res_utc.phase);

    // In UTC+1 (BST/CET): local time is 21:30 (night)
    const res_utc1 = evaluate(cfg, now_utc, 3600);
    try std.testing.expectEqual(Phase.night, res_utc1.phase);
    try std.testing.expectEqual(@as(u16, 4000), res_utc1.temperature);
}
