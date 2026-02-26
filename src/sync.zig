//! CRT sync primitives: pure timing computation from modeline parameters
//! and FPGA status fields. No I/O, no connection state — callers compose
//! these into their own sync loops.

const std = @import("std");
const protocol = @import("protocol.zig");

/// Precomputed frame timing derived from a modeline.
pub const FrameTiming = struct {
    /// Nanoseconds per scanline.
    line_time_ns: u64,
    /// Nanoseconds per frame (halved for interlaced modes).
    frame_time_ns: u64,
    /// Total vertical lines per frame.
    v_total: u16,
    /// 1 for interlaced, 0 for progressive (used as right-shift amount).
    interlace: u1,
};

/// Compute frame timing constants from a modeline.
pub fn frameTiming(modeline: protocol.Modeline) FrameTiming {
    const h_total: f64 = @floatFromInt(modeline.h_total);
    // pixel_clock is in MHz, so h_total / (pixel_clock * 1e6) gives seconds per line.
    // Multiply by 1e9 to get nanoseconds: h_total * 1000 / pixel_clock.
    const line_ns: u64 = @intFromFloat(@round(h_total * 1000.0 / modeline.pixel_clock));
    const interlace: u1 = if (modeline.interlaced) 1 else 0;
    const frame_ns = (@as(u64, modeline.v_total) * line_ns) >> interlace;
    return .{
        .line_time_ns = line_ns,
        .frame_time_ns = frame_ns,
        .v_total = modeline.v_total,
        .interlace = interlace,
    };
}

/// Compute the raster time offset between where the FPGA was when it ACK'd
/// our frame and where it is now. Pure function — no I/O.
///
/// Returns nanoseconds: positive = FPGA is behind (caller should wait),
/// negative = running late. Returns 0 if the ACK doesn't match the submitted frame.
pub fn rasterOffsetNs(timing: FrameTiming, status: protocol.FpgaStatus, submitted_frame: u32) i64 {
    if (status.frame_echo != submitted_frame) return 0;

    // Absolute raster positions (in scanlines from time zero).
    // vcount1: where the FPGA was when it echoed our frame.
    // vcount2: where the FPGA is now.
    const v_total: i64 = @intCast(timing.v_total);
    const frame_echo: i64 = @intCast(status.frame_echo);
    const vcount_echo: i64 = @intCast(status.vcount_echo);
    const frame: i64 = @intCast(status.frame);
    const vcount: i64 = @intCast(status.vcount);

    const vcount1 = (((frame_echo -% 1) * v_total) + vcount_echo) >> timing.interlace;
    const vcount2 = ((frame * v_total) + vcount) >> timing.interlace;

    // Dicotomic dampening: halve the difference to converge smoothly.
    const dif = @divTrunc(vcount1 - vcount2, 2);

    return @as(i64, @intCast(timing.line_time_ns)) * dif;
}

/// Compute the optimal vsync line for the next frame submission.
///
/// Given the timing budget (ping + margin + emulation time) and how long
/// streaming takes, returns the scanline at which the host should submit
/// so the frame arrives just in time.
///
/// All durations are in nanoseconds.
pub fn calcVsyncLine(timing: FrameTiming, ping_ns: u64, margin_ns: u64, emulation_ns: u64, stream_ns: u64) u16 {
    const budget = ping_ns + margin_ns + emulation_ns;
    if (budget >= timing.frame_time_ns) return 1; // can't catch this frame

    const time_calc = if (stream_ns > budget) 0 else budget - stream_ns;
    const v_total: u64 = @intCast(timing.v_total);
    const vsync = v_total -| (v_total * time_calc / timing.frame_time_ns);

    // Clamp to [1, v_total]
    if (vsync == 0) return 1;
    if (vsync > timing.v_total) return timing.v_total;
    return @intCast(vsync);
}

// --- Tests ---

test "frameTiming 640x480@60Hz" {
    const modeline = protocol.Modeline{
        .pixel_clock = 25.175,
        .h_active = 640,
        .h_begin = 656,
        .h_end = 752,
        .h_total = 800,
        .v_active = 480,
        .v_begin = 490,
        .v_end = 492,
        .v_total = 525,
        .interlaced = false,
    };
    const t = frameTiming(modeline);
    // line_time_ns = round(800 * 1000 / 25.175) = round(31778.18...) = 31778
    try std.testing.expectEqual(@as(u64, 31778), t.line_time_ns);
    // frame_time_ns = 31778 * 525 = 16_683_450
    try std.testing.expectEqual(@as(u64, 31778 * 525), t.frame_time_ns);
    try std.testing.expectEqual(@as(u16, 525), t.v_total);
    try std.testing.expectEqual(@as(u1, 0), t.interlace);
}

test "frameTiming 320x240@60Hz" {
    const modeline = protocol.Modeline{
        .pixel_clock = 6.7,
        .h_active = 320,
        .h_begin = 336,
        .h_end = 368,
        .h_total = 426,
        .v_active = 240,
        .v_begin = 244,
        .v_end = 247,
        .v_total = 262,
        .interlaced = false,
    };
    const t = frameTiming(modeline);
    // line_time_ns = round(426 * 1000 / 6.7) = round(63582.089...) = 63582
    try std.testing.expectEqual(@as(u64, 63582), t.line_time_ns);
    try std.testing.expectEqual(@as(u64, 63582 * 262), t.frame_time_ns);
    try std.testing.expectEqual(@as(u16, 262), t.v_total);
    try std.testing.expectEqual(@as(u1, 0), t.interlace);
}

test "frameTiming interlaced halves frame_time_ns" {
    const modeline = protocol.Modeline{
        .pixel_clock = 13.5,
        .h_active = 720,
        .h_begin = 736,
        .h_end = 799,
        .h_total = 858,
        .v_active = 480,
        .v_begin = 489,
        .v_end = 495,
        .v_total = 525,
        .interlaced = true,
    };
    const t = frameTiming(modeline);
    try std.testing.expectEqual(@as(u1, 1), t.interlace);
    // line_time_ns = round(858 * 1000 / 13.5) = round(63555.55...) = 63556
    try std.testing.expectEqual(@as(u64, 63556), t.line_time_ns);
    // frame_time_ns = (63556 * 525) >> 1 = 33_366_900 >> 1 = 16_683_450
    const full_frame = @as(u64, 63556) * 525;
    try std.testing.expectEqual(full_frame >> 1, t.frame_time_ns);
}

test "rasterOffsetNs returns 0 when frame_echo != submitted_frame" {
    const t = FrameTiming{
        .line_time_ns = 31778,
        .frame_time_ns = 31778 * 525,
        .v_total = 525,
        .interlace = 0,
    };
    const status = protocol.FpgaStatus{
        .frame_echo = 10,
        .vcount_echo = 100,
        .frame = 11,
        .vcount = 200,
    };
    try std.testing.expectEqual(@as(i64, 0), rasterOffsetNs(t, status, 9));
    try std.testing.expectEqual(@as(i64, 0), rasterOffsetNs(t, status, 11));
}

test "rasterOffsetNs with matching frame_echo" {
    const t = FrameTiming{
        .line_time_ns = 31778,
        .frame_time_ns = 31778 * 525,
        .v_total = 525,
        .interlace = 0,
    };
    // Scenario: FPGA echoed frame 5 at vcount 200, now at frame 5 vcount 300.
    // vcount1 = ((5-1)*525 + 200) >> 0 = 2300
    // vcount2 = (5*525 + 300) >> 0 = 2925
    // dif = (2300 - 2925) / 2 = -312 (truncated)
    // offset = 31778 * -312
    const status = protocol.FpgaStatus{
        .frame_echo = 5,
        .vcount_echo = 200,
        .frame = 5,
        .vcount = 300,
    };
    const expected: i64 = @as(i64, 31778) * @as(i64, -312);
    try std.testing.expectEqual(expected, rasterOffsetNs(t, status, 5));
}

test "rasterOffsetNs positive offset (FPGA behind)" {
    const t = FrameTiming{
        .line_time_ns = 31778,
        .frame_time_ns = 31778 * 525,
        .v_total = 525,
        .interlace = 0,
    };
    // FPGA echoed frame 5 at vcount 400, now at frame 5 vcount 100 (wrapped around).
    // vcount1 = ((5-1)*525 + 400) >> 0 = 2500
    // vcount2 = (5*525 + 100) >> 0 = 2725
    // dif = (2500 - 2725) / 2 = -112
    const status = protocol.FpgaStatus{
        .frame_echo = 5,
        .vcount_echo = 400,
        .frame = 5,
        .vcount = 100,
    };
    const expected: i64 = @as(i64, 31778) * @as(i64, -112);
    try std.testing.expectEqual(expected, rasterOffsetNs(t, status, 5));
}

test "calcVsyncLine returns 1 when budget exceeds frame time" {
    const t = FrameTiming{
        .line_time_ns = 31778,
        .frame_time_ns = 16_683_450,
        .v_total = 525,
        .interlace = 0,
    };
    // Budget (ping+margin+emu) = 20ms > 16.68ms frame time
    try std.testing.expectEqual(@as(u16, 1), calcVsyncLine(t, 5_000_000, 5_000_000, 10_000_000, 0));
}

test "calcVsyncLine with zero budget returns v_total" {
    const t = FrameTiming{
        .line_time_ns = 31778,
        .frame_time_ns = 16_683_450,
        .v_total = 525,
        .interlace = 0,
    };
    // No budget -> vsync = v_total - 0 = 525
    try std.testing.expectEqual(@as(u16, 525), calcVsyncLine(t, 0, 0, 0, 0));
}

test "calcVsyncLine result is in [1, v_total]" {
    const t = FrameTiming{
        .line_time_ns = 31778,
        .frame_time_ns = 16_683_450,
        .v_total = 525,
        .interlace = 0,
    };
    // Test many different budget values
    const test_values = [_]u64{ 0, 1_000_000, 5_000_000, 8_000_000, 10_000_000, 16_000_000, 16_683_450, 20_000_000, 100_000_000 };
    for (test_values) |budget| {
        const vsync = calcVsyncLine(t, budget, 0, 0, 0);
        try std.testing.expect(vsync >= 1);
        try std.testing.expect(vsync <= t.v_total);
    }
}

test "calcVsyncLine with large stream_ns clamps to v_total" {
    const t = FrameTiming{
        .line_time_ns = 31778,
        .frame_time_ns = 16_683_450,
        .v_total = 525,
        .interlace = 0,
    };
    // stream_ns > budget -> time_calc = 0 -> vsync = v_total
    try std.testing.expectEqual(@as(u16, 525), calcVsyncLine(t, 1_000_000, 0, 0, 5_000_000));
}

test "calcVsyncLine typical usage" {
    const t = FrameTiming{
        .line_time_ns = 31778,
        .frame_time_ns = 16_683_450,
        .v_total = 525,
        .interlace = 0,
    };
    // ping=1ms, margin=2ms, emu=4ms, stream=2ms
    // budget = 1+2+4 = 7ms, time_calc = 7-2 = 5ms
    // vsync = 525 - (525 * 5_000_000 / 16_683_450) = 525 - 157 = 368
    const vsync = calcVsyncLine(t, 1_000_000, 2_000_000, 4_000_000, 2_000_000);
    try std.testing.expect(vsync > 300);
    try std.testing.expect(vsync < 425);
}
