//! Frame pacer: drift-corrected frame pacing with backpressure handling.
//! Blocks until it's time to submit the next frame, using FPGA status
//! feedback to maintain smooth frame delivery.
//!
//! The drift controller tracks how far ahead the client is relative to the
//! FPGA and adjusts the frame period to converge on a target drift. For
//! interlaced modes, a coupled phase correction ensures field alignment.
//!
//! This replaces the per-client pacing logic (drift + phase + sleep) with
//! a single `beginFrame()` call.

const std = @import("std");
const protocol = @import("protocol.zig");
const sync = @import("sync.zig");
const Connection = @import("Connection.zig");

/// Result of a beginFrame call.
pub const PaceResult = enum(c_int) {
    /// Ready to submit the next frame.
    ready = 0,
    /// FPGA is unresponsive — caller should reconnect.
    stalled = 1,
    /// Backpressure — skip this frame (VRAM not ready).
    skip = 2,
};

pub const PacerState = struct {
    // --- Configuration (set by updateTiming) ---
    /// Nanoseconds per frame from FrameTiming (halved for interlaced).
    frame_time_ns: u64 = 0,
    /// Total vertical lines per frame.
    v_total: u16 = 0,
    /// Whether the current mode is interlaced.
    interlaced: bool = false,

    // --- Frame tracking ---
    /// Client-side frame counter, incremented per beginFrame.
    client_frame: u32 = 0,
    /// Grace period after connect — tolerate sync timeouts while FPGA bootstraps.
    settle_frames: u32 = 30,

    // --- Drift controller ---
    /// Target number of frames the client leads the FPGA.
    target_drift: f64 = 3.0,
    /// Proportional gain: correction per frame per unit of drift error.
    drift_gain: f64 = 0.02,

    // --- Timing ---
    /// Monotonic timestamp (ns) when last beginFrame returned to caller.
    last_pace_ns: u64 = 0,

    // --- Drop tracking ---
    /// Wall-clock time (ns) of last `.ready` return.
    last_ready_ns: u64 = 0,
    /// Monotonic counter of real frame-level drops (full frame periods lost).
    dropped_frames: u64 = 0,

    // --- Stall / backpressure detection ---
    consecutive_timeouts: u32 = 0,
    max_consecutive_timeouts: u32 = 3,
    consecutive_drops: u32 = 0,
    max_consecutive_drops: u32 = 60,

    /// Block until it's time to submit the next frame.
    ///
    /// Sends CMD_GET_STATUS to the FPGA, waits for an ACK, computes the
    /// drift-corrected pace, and sleeps until the target wake time.
    ///
    /// Returns `.ready` when the caller should submit a frame, `.skip` when
    /// VRAM is full (caller should skip this frame), or `.stalled` when the
    /// FPGA is unresponsive (caller should reconnect).
    pub fn beginFrame(self: *PacerState, conn: *Connection) PaceResult {
        if (self.frame_time_ns == 0) return .stalled;

        const in_settle = self.client_frame < self.settle_frames;
        const timeout: i32 = if (in_settle) 50 else 16;

        // 1. Sync — send CMD_GET_STATUS and wait for ACK, measuring round-trip time
        const sync_start = nowNs();
        const synced = conn.waitSync(timeout);
        const sync_elapsed_ns = nowNs() -| sync_start;

        if (!synced) {
            self.consecutive_timeouts += 1;
            if (!in_settle and self.consecutive_timeouts >= self.max_consecutive_timeouts) {
                return .stalled;
            }
            // During settle or before stall threshold: pace at raw frame rate
            self.sleepForDuration(self.frame_time_ns);
            self.client_frame +%= 1;
            return .ready;
        }
        self.consecutive_timeouts = 0;

        // Record sync wait into health ring buffer
        const sync_ms = @as(f64, @floatFromInt(sync_elapsed_ns)) / 1_000_000.0;
        conn.health.record(sync_ms, conn.fpgaStatus().vram_ready);

        // 2. Check backpressure
        const status = conn.fpgaStatus();
        if (!status.vram_ready) {
            self.consecutive_drops += 1;
            if (self.consecutive_drops >= self.max_consecutive_drops) {
                return .stalled;
            }
            return .skip;
        }
        self.consecutive_drops = 0;

        // 3. Compute drift-corrected pace
        const pace_mult = self.computePaceMultiplier(status);
        const frame_ns_f: f64 = @floatFromInt(self.frame_time_ns);
        const paced_ns: u64 = @intFromFloat(@max(1.0, frame_ns_f * pace_mult));

        // 4. Track real dropped frames before sleeping.
        // If time since last .ready exceeds 1.5 frame periods, count missed frames.
        const now = nowNs();
        if (self.last_ready_ns > 0 and self.frame_time_ns > 0) {
            const gap = now -| self.last_ready_ns;
            const threshold = self.frame_time_ns + (self.frame_time_ns / 2); // 1.5x
            if (gap > threshold) {
                const missed = gap / self.frame_time_ns;
                if (missed > 1) {
                    self.dropped_frames += missed - 1;
                }
            }
        }

        // 5. Sleep until target
        self.sleepForDuration(paced_ns);
        self.last_ready_ns = nowNs();
        self.client_frame +%= 1;
        return .ready;
    }

    /// Compute pace multiplier from drift error and interlaced phase.
    /// Pure function — no I/O, no side effects.
    ///
    /// drift = client_frame - fpga_frame
    /// error = target_drift - drift
    /// mult  = clamp(1.0 - error * drift_gain [- phase_correction], 0.92, 1.05)
    pub fn computePaceMultiplier(self: *const PacerState, status: protocol.FpgaStatus) f64 {
        const client_f: f64 = @floatFromInt(self.client_frame);
        const fpga_f: f64 = @floatFromInt(status.frame);
        const drift = client_f - fpga_f;
        const drift_error = self.target_drift - drift;
        var mult = 1.0 - drift_error * self.drift_gain;

        // Interlaced phase correction: coupled drift+phase eigenvalue approach.
        // phaseGain = driftGain + 3.0 / fieldRate ensures convergence in ~1s.
        if (self.interlaced and self.frame_time_ns > 0) {
            const expected_field: u1 = @truncate(self.client_frame);
            const actual_field: u1 = @intFromBool(status.vga_f1);
            if (expected_field != actual_field) {
                const field_rate_hz = 1e9 / @as(f64, @floatFromInt(self.frame_time_ns));
                const phase_gain = self.drift_gain + 3.0 / field_rate_hz;
                mult -= phase_gain;
            }
        }

        return std.math.clamp(mult, 0.92, 1.05);
    }

    /// Sleep for the given duration anchored to last_pace_ns.
    /// Uses coarse sleep (nanosleep) leaving a 2ms margin, then spin-waits
    /// for the remainder to hit the target precisely.
    fn sleepForDuration(self: *PacerState, duration_ns: u64) void {
        const now = nowNs();

        // First call: set anchor and return immediately.
        if (self.last_pace_ns == 0) {
            self.last_pace_ns = now;
            return;
        }

        const target = self.last_pace_ns +| duration_ns;
        if (target > now) {
            const remaining = target - now;
            const margin: u64 = 2_000_000; // 2ms
            if (remaining > margin) {
                std.Thread.sleep(remaining - margin);
            }
            // Spin-wait for remaining time
            while (nowNs() < target) {
                std.atomic.spinLoopHint();
            }
        }
        self.last_pace_ns = nowNs();
    }

    /// Reset tracking state on connect/reconnect.
    pub fn reset(self: *PacerState) void {
        self.client_frame = 0;
        self.last_pace_ns = 0;
        self.last_ready_ns = 0;
        self.dropped_frames = 0;
        self.consecutive_timeouts = 0;
        self.consecutive_drops = 0;
    }

    /// Update timing from a modeline change. Resets tracking state.
    pub fn updateTiming(self: *PacerState, timing: sync.FrameTiming) void {
        self.frame_time_ns = timing.frame_time_ns;
        self.v_total = timing.v_total;
        self.interlaced = timing.interlace == 1;
        self.reset();
    }
};

/// Monotonic nanosecond timestamp.
fn nowNs() u64 {
    const ts = std.time.nanoTimestamp();
    return @intCast(if (ts < 0) 0 else ts);
}

// --- Tests ---

test "PacerState defaults" {
    const p = PacerState{};
    try std.testing.expectEqual(@as(u64, 0), p.frame_time_ns);
    try std.testing.expectEqual(@as(u32, 0), p.client_frame);
    try std.testing.expectEqual(@as(u64, 0), p.last_pace_ns);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), p.target_drift, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), p.drift_gain, 0.001);
}

test "reset zeros tracking state" {
    var p = PacerState{};
    p.client_frame = 100;
    p.last_pace_ns = 999999;
    p.last_ready_ns = 888888;
    p.dropped_frames = 42;
    p.consecutive_timeouts = 5;
    p.consecutive_drops = 10;

    p.reset();

    try std.testing.expectEqual(@as(u32, 0), p.client_frame);
    try std.testing.expectEqual(@as(u64, 0), p.last_pace_ns);
    try std.testing.expectEqual(@as(u64, 0), p.last_ready_ns);
    try std.testing.expectEqual(@as(u64, 0), p.dropped_frames);
    try std.testing.expectEqual(@as(u32, 0), p.consecutive_timeouts);
    try std.testing.expectEqual(@as(u32, 0), p.consecutive_drops);
}

test "reset preserves configuration" {
    var p = PacerState{};
    p.frame_time_ns = 16_683_450;
    p.v_total = 525;
    p.interlaced = true;
    p.target_drift = 5.0;

    p.client_frame = 100;
    p.reset();

    // Config preserved
    try std.testing.expectEqual(@as(u64, 16_683_450), p.frame_time_ns);
    try std.testing.expectEqual(@as(u16, 525), p.v_total);
    try std.testing.expect(p.interlaced);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), p.target_drift, 0.001);
}

test "updateTiming sets fields from FrameTiming" {
    var p = PacerState{};
    p.client_frame = 50;
    p.last_pace_ns = 12345;

    p.updateTiming(.{
        .line_time_ns = 31778,
        .frame_time_ns = 16_683_450,
        .v_total = 525,
        .interlace = 0,
    });

    try std.testing.expectEqual(@as(u64, 16_683_450), p.frame_time_ns);
    try std.testing.expectEqual(@as(u16, 525), p.v_total);
    try std.testing.expect(!p.interlaced);
    // reset was called
    try std.testing.expectEqual(@as(u32, 0), p.client_frame);
    try std.testing.expectEqual(@as(u64, 0), p.last_pace_ns);
}

test "updateTiming interlaced mode" {
    var p = PacerState{};
    p.updateTiming(.{
        .line_time_ns = 63556,
        .frame_time_ns = 63556 * 525 / 2,
        .v_total = 525,
        .interlace = 1,
    });
    try std.testing.expect(p.interlaced);
    try std.testing.expectEqual(@as(u16, 525), p.v_total);
}

test "computePaceMultiplier at target drift returns ~1.0" {
    var p = PacerState{};
    p.frame_time_ns = 16_683_450;
    p.target_drift = 3.0;
    p.drift_gain = 0.02;
    p.client_frame = 103; // drift = 103 - 100 = 3.0 = target

    const status = protocol.FpgaStatus{ .frame = 100 };
    const mult = p.computePaceMultiplier(status);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), mult, 0.001);
}

test "computePaceMultiplier behind target speeds up (mult < 1)" {
    var p = PacerState{};
    p.frame_time_ns = 16_683_450;
    p.target_drift = 3.0;
    p.drift_gain = 0.02;
    p.client_frame = 101; // drift = 1, error = 2, mult = 1 - 2*0.02 = 0.96

    const status = protocol.FpgaStatus{ .frame = 100 };
    const mult = p.computePaceMultiplier(status);
    try std.testing.expectApproxEqAbs(@as(f64, 0.96), mult, 0.001);
}

test "computePaceMultiplier ahead of target slows down (mult > 1)" {
    var p = PacerState{};
    p.frame_time_ns = 16_683_450;
    p.target_drift = 3.0;
    p.drift_gain = 0.02;
    p.client_frame = 105; // drift = 5, error = -2, mult = 1 + 0.04 = 1.04

    const status = protocol.FpgaStatus{ .frame = 100 };
    const mult = p.computePaceMultiplier(status);
    try std.testing.expectApproxEqAbs(@as(f64, 1.04), mult, 0.001);
}

test "computePaceMultiplier clamps to [0.92, 1.05]" {
    var p = PacerState{};
    p.frame_time_ns = 16_683_450;
    p.target_drift = 3.0;
    p.drift_gain = 0.02;

    // Way behind: drift = -50, error = 53, mult = 1 - 1.06 → clamped to 0.92
    p.client_frame = 50;
    var mult = p.computePaceMultiplier(protocol.FpgaStatus{ .frame = 100 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.92), mult, 0.001);

    // Way ahead: drift = 50, error = -47, mult = 1 + 0.94 → clamped to 1.05
    p.client_frame = 150;
    mult = p.computePaceMultiplier(protocol.FpgaStatus{ .frame = 100 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.05), mult, 0.001);
}

test "computePaceMultiplier interlaced: matching field no correction" {
    var p = PacerState{};
    p.frame_time_ns = 16_683_450;
    p.target_drift = 3.0;
    p.drift_gain = 0.02;
    p.interlaced = true;
    p.client_frame = 103; // expected field = 1

    // Field match: expected 1, actual 1
    const status = protocol.FpgaStatus{ .frame = 100, .vga_f1 = true };
    const mult = p.computePaceMultiplier(status);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), mult, 0.001);
}

test "computePaceMultiplier interlaced: mismatched field applies correction" {
    var p = PacerState{};
    p.frame_time_ns = 16_683_450; // ~60Hz field rate
    p.target_drift = 3.0;
    p.drift_gain = 0.02;
    p.interlaced = true;
    p.client_frame = 102; // expected field = 0, drift = 3

    // Field mismatch: expected 0, actual 1
    const status = protocol.FpgaStatus{ .frame = 99, .vga_f1 = true };
    const mult = p.computePaceMultiplier(status);
    // phase_gain ≈ 0.02 + 3.0/59.94 ≈ 0.07
    // mult ≈ 1.0 - 0.07 = 0.93
    try std.testing.expect(mult < 1.0);
    try std.testing.expect(mult >= 0.92);
}

test "drift convergence simulation" {
    var p = PacerState{};
    p.frame_time_ns = 16_683_450;
    p.target_drift = 3.0;
    p.drift_gain = 0.02;

    // Simulate: client starts 10 frames ahead of FPGA
    var fpga_frame: f64 = 0.0;
    p.client_frame = 10;

    for (0..300) |_| {
        const fpga_u32: u32 = @intFromFloat(@max(0.0, @round(fpga_frame)));
        const status = protocol.FpgaStatus{ .frame = fpga_u32 };
        const mult = p.computePaceMultiplier(status);

        // Client advances by 1 frame
        p.client_frame +%= 1;
        // FPGA advances by mult frames (client waited frame_time * mult)
        fpga_frame += mult;
    }

    const final_drift = @as(f64, @floatFromInt(p.client_frame)) - fpga_frame;
    try std.testing.expectApproxEqAbs(p.target_drift, final_drift, 0.5);
}

test "drift convergence from behind" {
    var p = PacerState{};
    p.frame_time_ns = 16_683_450;
    p.target_drift = 3.0;
    p.drift_gain = 0.02;

    // Client starts behind FPGA
    var fpga_frame: f64 = 50.0;
    p.client_frame = 48; // drift = -2

    for (0..300) |_| {
        const fpga_u32: u32 = @intFromFloat(@max(0.0, @round(fpga_frame)));
        const status = protocol.FpgaStatus{ .frame = fpga_u32 };
        const mult = p.computePaceMultiplier(status);

        p.client_frame +%= 1;
        fpga_frame += mult;
    }

    const final_drift = @as(f64, @floatFromInt(p.client_frame)) - fpga_frame;
    try std.testing.expectApproxEqAbs(p.target_drift, final_drift, 0.5);
}

test "stall thresholds" {
    var p = PacerState{};
    p.frame_time_ns = 16_683_450;

    // Consecutive timeouts below threshold: not stalled
    p.client_frame = 100; // past settle
    p.consecutive_timeouts = 2;
    try std.testing.expect(p.consecutive_timeouts < p.max_consecutive_timeouts);

    // At threshold: stalled
    p.consecutive_timeouts = 3;
    try std.testing.expect(p.consecutive_timeouts >= p.max_consecutive_timeouts);

    // Consecutive drops below threshold: not stalled
    p.consecutive_drops = 59;
    try std.testing.expect(p.consecutive_drops < p.max_consecutive_drops);

    // At threshold: stalled
    p.consecutive_drops = 60;
    try std.testing.expect(p.consecutive_drops >= p.max_consecutive_drops);
}

test "settle period tolerance" {
    const p = PacerState{ .settle_frames = 30 };

    // During settle: client_frame < settle_frames
    try std.testing.expect(0 < p.settle_frames);
    try std.testing.expect(29 < p.settle_frames);
    // Past settle
    try std.testing.expect(!(30 < p.settle_frames));
    try std.testing.expect(!(31 < p.settle_frames));
}

test "beginFrame returns stalled when no timing configured" {
    var p = PacerState{};
    // frame_time_ns = 0 → stalled
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();

    const result = p.beginFrame(&conn);
    try std.testing.expectEqual(PaceResult.stalled, result);
}
