const std = @import("std");

/// Calculates the solar elevation in degrees above the horizon for a given UTC Unix
/// timestamp and geographic coordinates (latitude and longitude in degrees), using
/// the NOAA Solar Calculations algorithm.
pub fn elevation(unix_seconds: i64, lat_deg: f64, lon_deg: f64) f64 {
    const jd = @as(f64, @floatFromInt(unix_seconds)) / 86400.0 + 2440587.5;
    const t = (jd - 2451545.0) / 36525.0;

    const rad = std.math.rad_per_deg;

    // Geometric mean longitude of the sun (degrees)
    var l0 = @mod(280.46646 + t * (36000.76983 + 0.0003032 * t), 360.0);
    if (l0 < 0.0) l0 += 360.0;

    // Mean anomaly of the sun (degrees)
    const m = 357.52911 + t * (35999.05029 - 0.0001537 * t);

    // Eccentricity of Earth orbit
    const e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t);

    // Sun equation of center
    const c = @sin(m * rad) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
        @sin(2.0 * m * rad) * (0.019993 - 0.000101 * t) +
        @sin(3.0 * m * rad) * 0.000289;

    // Sun true longitude and apparent longitude (degrees)
    const sun_true_long = l0 + c;
    const sun_app_long = sun_true_long - 0.00569 - 0.00478 * @sin((125.04 - 1934.136 * t) * rad);

    // Mean obliquity of the ecliptic (degrees)
    const mean_obliq = 23.0 + (26.0 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60.0) / 60.0;
    const obliq_corr = mean_obliq + 0.00256 * @cos((125.04 - 1934.136 * t) * rad);

    // Sun declination (radians)
    const sin_declin = @sin(obliq_corr * rad) * @sin(sun_app_long * rad);
    const declin = std.math.asin(std.math.clamp(sin_declin, -1.0, 1.0));

    // Equation of time (minutes)
    const y = std.math.pow(f64, @tan(obliq_corr * rad / 2.0), 2.0);
    const eq_of_time = 4.0 * std.math.deg_per_rad * (y * @sin(2.0 * l0 * rad) -
        2.0 * e * @sin(m * rad) +
        4.0 * e * y * @sin(m * rad) * @cos(2.0 * l0 * rad) -
        0.5 * y * y * @sin(4.0 * l0 * rad) -
        1.25 * e * e * @sin(2.0 * m * rad));

    // True solar time in minutes from midnight
    const time_of_day_s = @mod(unix_seconds, 86400);
    const time_offset = eq_of_time + 4.0 * lon_deg;
    var true_solar_time = @as(f64, @floatFromInt(time_of_day_s)) / 60.0 + time_offset;
    true_solar_time = @mod(true_solar_time, 1440.0);
    if (true_solar_time < 0.0) true_solar_time += 1440.0;

    // Hour angle (degrees)
    var hour_angle = true_solar_time / 4.0 - 180.0;
    if (hour_angle < -180.0) hour_angle += 360.0;

    // Solar zenith angle (degrees)
    const lat_rad = lat_deg * rad;
    const cos_zenith = @sin(lat_rad) * @sin(declin) +
        @cos(lat_rad) * @cos(declin) * @cos(hour_angle * rad);
    const zenith = std.math.acos(std.math.clamp(cos_zenith, -1.0, 1.0)) * std.math.deg_per_rad;

    return 90.0 - zenith;
}

test "solar elevation polar cases and reference values" {
    // Tromsø (69.65° N, 18.96° E):
    // 2026-06-21 22:00:00 UTC (near local midnight) is day (> 0°)
    const tromso_june_midnight: i64 = 1782079200;
    const el_tromso_june = elevation(tromso_june_midnight, 69.65, 18.96);
    try std.testing.expect(el_tromso_june > 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 3.46), el_tromso_june, 0.1);

    // Tromsø: 2026-12-21 10:44:00 UTC (local noon) is partway civil twilight (≈ -3°)
    const tromso_dec_noon: i64 = 1797849840;
    const el_tromso_dec = elevation(tromso_dec_noon, 69.65, 18.96);
    try std.testing.expect(el_tromso_dec < 0.0 and el_tromso_dec > -6.0);
    try std.testing.expectApproxEqAbs(@as(f64, -3.09), el_tromso_dec, 0.1);

    // Longyearbyen (78.22° N, 15.65° E) on 2026-12-21 at noon is night all day (<-6°)
    const el_longyearbyen_dec = elevation(tromso_dec_noon, 78.22, 15.65);
    try std.testing.expect(el_longyearbyen_dec < -6.0);
    try std.testing.expectApproxEqAbs(@as(f64, -11.67), el_longyearbyen_dec, 0.1);
}
