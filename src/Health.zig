//! Rolling-window health metrics for FPGA streaming.

const std = @import("std");

const Health = @This();

/// Ring buffer capacity: 128 samples (~2 seconds at 60 Hz).
pub const window_size = 128;

// --- Sync wait tracking (recorded per submit) ---
sync_wait_ring: [window_size]f64 = [_]f64{0} ** window_size,
sync_ring_idx: usize = 0,
sync_samples: usize = 0,

avg_sync_wait_ms: f64 = 0,
p95_sync_wait_ms: f64 = 0,

// --- VRAM ready tracking (recorded per tick) ---
ready_ring: [window_size]bool = [_]bool{true} ** window_size,
ready_ring_idx: usize = 0,
ready_samples: usize = 0,

vram_ready_rate: f64 = 1.0,

/// Record vram_ready on every tick (including drops).
pub fn recordReady(self: *Health, vram_ready: bool) void {
    self.ready_ring[self.ready_ring_idx] = vram_ready;
    self.ready_ring_idx = (self.ready_ring_idx + 1) % window_size;
    self.ready_samples = @min(self.ready_samples + 1, window_size);
    self.recomputeReady();
}

/// Record sync timing on successful frame submissions only.
pub fn record(self: *Health, sync_wait_ms: f64, vram_ready: bool) void {
    self.sync_wait_ring[self.sync_ring_idx] = sync_wait_ms;
    self.sync_ring_idx = (self.sync_ring_idx + 1) % window_size;
    self.sync_samples = @min(self.sync_samples + 1, window_size);
    self.recomputeSync();

    // Also record ready status for backwards compatibility
    self.recordReady(vram_ready);
}

/// Suggested stall timeout in ms based on observed timing.
pub fn stallThreshold(self: *const Health, period_ms: f64) f64 {
    return @max(period_ms * 3, self.p95_sync_wait_ms * 2);
}

fn recomputeReady(self: *Health) void {
    const n = self.ready_samples;
    if (n == 0) return;

    var ready_count: usize = 0;
    for (0..n) |i| {
        if (self.ready_ring[i]) ready_count += 1;
    }
    self.vram_ready_rate = @as(f64, @floatFromInt(ready_count)) / @as(f64, @floatFromInt(n));
}

fn recomputeSync(self: *Health) void {
    const n = self.sync_samples;
    if (n == 0) return;

    // Average sync wait
    var sum: f64 = 0;
    for (0..n) |i| {
        sum += self.sync_wait_ring[i];
    }
    self.avg_sync_wait_ms = sum / @as(f64, @floatFromInt(n));

    // P95 sync wait — sort a copy of the active window, take 95th percentile
    var sorted: [window_size]f64 = undefined;
    @memcpy(sorted[0..n], self.sync_wait_ring[0..n]);
    std.sort.insertion(f64, sorted[0..n], {}, std.sort.asc(f64));
    const p95_idx = @min(n - 1, (n * 95) / 100);
    self.p95_sync_wait_ms = sorted[p95_idx];
}

// --- Tests ---

test "Health records and computes averages" {
    var h = Health{};

    // Record 10 samples at 1.0ms, all ready
    for (0..10) |_| {
        h.record(1.0, true);
    }

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), h.avg_sync_wait_ms, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), h.vram_ready_rate, 0.01);
}

test "Health tracks vram_ready_rate" {
    var h = Health{};

    // 5 ready, 5 not ready
    for (0..5) |_| h.record(1.0, true);
    for (0..5) |_| h.record(1.0, false);

    try std.testing.expectApproxEqAbs(@as(f64, 0.5), h.vram_ready_rate, 0.01);
}

test "Health p95 picks high value" {
    var h = Health{};

    // 19 samples at 1.0ms, 1 sample at 10.0ms
    for (0..19) |_| h.record(1.0, true);
    h.record(10.0, true);

    // p95 of 20 samples = index 19 = 10.0
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), h.p95_sync_wait_ms, 0.01);
}

test "Health stallThreshold" {
    var h = Health{};
    h.record(5.0, true);
    // With p95=5.0: max(16.7*3, 5.0*2) = max(50.1, 10.0) = 50.1
    const threshold = h.stallThreshold(16.7);
    try std.testing.expect(threshold >= 49.0); // comfortably above period*3 floor
    try std.testing.expect(threshold <= 52.0);
}

test "Health wraps ring buffer" {
    var h = Health{};
    // Fill entire window + overflow
    for (0..Health.window_size + 10) |_| {
        h.record(2.0, true);
    }
    try std.testing.expectEqual(Health.window_size, h.sync_samples);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), h.avg_sync_wait_ms, 0.01);
}

// --- Comprehensive edge-case tests ---

test "Health zero samples has correct defaults" {
    const h = Health{};
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), h.avg_sync_wait_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), h.p95_sync_wait_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), h.vram_ready_rate, 0.001);
    try std.testing.expectEqual(@as(usize, 0), h.sync_samples);
    try std.testing.expectEqual(@as(usize, 0), h.ready_samples);
}

test "Health single sample" {
    var h = Health{};
    h.record(3.5, false);

    try std.testing.expectEqual(@as(usize, 1), h.sync_samples);
    try std.testing.expectEqual(@as(usize, 1), h.ready_samples);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), h.avg_sync_wait_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), h.p95_sync_wait_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), h.vram_ready_rate, 0.001);
}

test "Health exactly window_size samples (boundary)" {
    var h = Health{};
    for (0..Health.window_size) |_| {
        h.record(1.0, true);
    }
    try std.testing.expectEqual(Health.window_size, h.sync_samples);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), h.avg_sync_wait_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), h.vram_ready_rate, 0.001);
}

test "Health all-false vram_ready gives 0% rate" {
    var h = Health{};
    for (0..20) |_| {
        h.record(1.0, false);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), h.vram_ready_rate, 0.001);
}

test "Health p95 with uniform data (all same value)" {
    var h = Health{};
    for (0..50) |_| {
        h.record(7.77, true);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 7.77), h.p95_sync_wait_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 7.77), h.avg_sync_wait_ms, 0.001);
}

test "Health stallThreshold with very large period" {
    var h = Health{};
    h.record(2.0, true);
    // period*3 = 1000*3 = 3000, p95*2 = 2*2 = 4 -> max = 3000
    const threshold = h.stallThreshold(1000.0);
    try std.testing.expectApproxEqAbs(@as(f64, 3000.0), threshold, 0.01);
}

test "Health stallThreshold with very small period" {
    var h = Health{};
    h.record(50.0, true);
    // period*3 = 0.1*3 = 0.3, p95*2 = 50*2 = 100 -> max = 100
    const threshold = h.stallThreshold(0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), threshold, 0.01);
}

test "Health rapid alternating true/false" {
    var h = Health{};
    for (0..100) |i| {
        h.record(1.0, i % 2 == 0);
    }
    // 50 true, 50 false out of 100 samples (capped at window_size=128)
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), h.vram_ready_rate, 0.01);
}

test "recordReady independent of sync timing" {
    var h = Health{};

    // Record 10 ready states without any sync timing
    for (0..10) |_| h.recordReady(true);
    for (0..10) |_| h.recordReady(false);

    try std.testing.expectEqual(@as(usize, 20), h.ready_samples);
    try std.testing.expectEqual(@as(usize, 0), h.sync_samples);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), h.vram_ready_rate, 0.01);
    // Sync stats unchanged from defaults
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), h.avg_sync_wait_ms, 0.001);
}

test "recordReady and record use independent ring buffers" {
    var h = Health{};

    // Record 5 ready-only ticks (all not ready)
    for (0..5) |_| h.recordReady(false);
    // Record 5 submit samples (all ready)
    for (0..5) |_| h.record(1.0, true);

    // ready ring: 5 false + 5 true = 50%
    try std.testing.expectEqual(@as(usize, 10), h.ready_samples);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), h.vram_ready_rate, 0.01);
    // sync ring: only the 5 submit samples
    try std.testing.expectEqual(@as(usize, 5), h.sync_samples);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), h.avg_sync_wait_ms, 0.01);
}
