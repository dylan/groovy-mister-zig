const std = @import("std");
const Connection = @import("Connection.zig");
const lz4 = @import("lz4.zig");

/// State for delta frame encoding. Tracks the previous frame and provides
/// a scratch buffer for wrapping subtraction. Heap-allocated, pointed to by
/// `Compressor.ctx`.
pub const DeltaState = struct {
    prev_frames: [2][]u8,
    delta_buf: []u8,
    has_prev: [2]bool = .{ false, false },
    frame_count: [2]u32 = .{ 0, 0 },
    keyframe_interval: u32 = 0, // 0 = disabled
};

/// Return a `Connection.Compressor` backed by delta (wrapping subtract) + LZ4 compression.
/// `state` holds the previous-frame and scratch buffers.
/// `lz4_buf` must be at least `lz4.compressBound(frame_size)` bytes.
pub fn compressor(state: *DeltaState, lz4_buf: []u8) Connection.Compressor {
    return .{
        .ctx = state,
        .buf = lz4_buf,
        .compressFn = &deltaCompress,
    };
}

fn deltaCompress(ctx: ?*anyopaque, src: []const u8, dst: []u8, field: u8) ?Connection.CompressResult {
    const state: *DeltaState = @ptrCast(@alignCast(ctx orelse return null));
    const f: usize = @min(field, 1);

    if (!state.has_prev[f]) {
        // First frame for this field: send full compressed frame, store as reference
        @memcpy(state.prev_frames[f][0..src.len], src);
        state.has_prev[f] = true;
        state.frame_count[f] = 0;
        const result = lz4.compress(null, src, dst, field) orelse return null;
        return .{ .data = result.data, .is_delta = false };
    }

    state.frame_count[f] += 1;

    // Periodic keyframe: send a full (non-delta) frame so the FPGA can resync
    if (state.keyframe_interval > 0 and state.frame_count[f] >= state.keyframe_interval) {
        state.frame_count[f] = 0;
        @memcpy(state.prev_frames[f][0..src.len], src);
        const result = lz4.compress(null, src, dst, field) orelse return null;
        return .{ .data = result.data, .is_delta = false };
    }

    // Wrapping-subtract src with prev_frame into delta_buf.
    // The FPGA reconstructs via wrapping addition: output[i] = delta[i] + prev[i].
    const prev = state.prev_frames[f][0..src.len];
    const delta_out = state.delta_buf[0..src.len];
    for (delta_out, src, prev) |*d, s, p| {
        d.* = s -% p;
    }

    // Update prev_frame for next call
    @memcpy(state.prev_frames[f][0..src.len], src);

    // LZ4 compress the delta
    const result = lz4.compress(null, delta_out, dst, field) orelse return null;
    return .{ .data = result.data, .is_delta = true };
}

// --- Tests ---

test "first frame compresses without delta (passthrough to LZ4)" {
    const frame_size = 256;
    var prev_buf: [frame_size]u8 = undefined;
    var prev_buf1: [frame_size]u8 = undefined;
    var delta_buf: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 128]u8 = undefined;
    var state = DeltaState{
        .prev_frames = .{ &prev_buf, &prev_buf1 },
        .delta_buf = &delta_buf,
    };

    const input = [_]u8{0xAB} ** frame_size;
    const comp = compressor(&state, &lz4_buf);
    const result = comp.compress(&input, 0) orelse return error.CompressFailed;
    try std.testing.expect(!result.is_delta);
    try std.testing.expect(state.has_prev[0]);

    // prev_frame should now contain the input
    try std.testing.expectEqualSlices(u8, &input, prev_buf[0..frame_size]);
}

test "identical successive frames produce highly compressible delta" {
    const frame_size = 1024;
    var prev_buf: [frame_size]u8 = undefined;
    var prev_buf1: [frame_size]u8 = undefined;
    var delta_buf: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 256]u8 = undefined;
    var state = DeltaState{
        .prev_frames = .{ &prev_buf, &prev_buf1 },
        .delta_buf = &delta_buf,
    };

    const frame = [_]u8{0xCC} ** frame_size;
    const comp = compressor(&state, &lz4_buf);

    // First frame
    _ = comp.compress(&frame, 0);

    // Second identical frame: delta is all zeros -> very small compressed
    const result = comp.compress(&frame, 0) orelse return error.CompressFailed;
    try std.testing.expect(result.is_delta);
    // All-zeros compresses very well — should be much smaller than the frame
    try std.testing.expect(result.data.len < frame_size / 4);
}

test "different frames produce correct subtraction delta" {
    const frame_size = 64;
    var prev_buf: [frame_size]u8 = undefined;
    var prev_buf1: [frame_size]u8 = undefined;
    var delta_buf: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 128]u8 = undefined;
    var state = DeltaState{
        .prev_frames = .{ &prev_buf, &prev_buf1 },
        .delta_buf = &delta_buf,
    };

    const comp = compressor(&state, &lz4_buf);

    const frame1 = [_]u8{0xFF} ** frame_size;
    _ = comp.compress(&frame1, 0);

    const frame2 = [_]u8{0x00} ** frame_size;
    _ = comp.compress(&frame2, 0);

    // After frame2, prev_frame should be frame2
    try std.testing.expectEqualSlices(u8, &frame2, prev_buf[0..frame_size]);
}

test "round-trip: delta compress then add-reconstruct matches original" {
    const frame_size = 128;
    const lz4_import = @import("lz4");
    var prev_buf: [frame_size]u8 = undefined;
    var prev_buf1: [frame_size]u8 = undefined;
    var delta_buf_storage: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 256]u8 = undefined;
    var state = DeltaState{
        .prev_frames = .{ &prev_buf, &prev_buf1 },
        .delta_buf = &delta_buf_storage,
    };

    const comp = compressor(&state, &lz4_buf);

    // Frame 1: gradient
    var frame1: [frame_size]u8 = undefined;
    for (&frame1, 0..) |*b, i| b.* = @truncate(i);
    const result1 = comp.compress(&frame1, 0) orelse return error.CompressFailed;
    try std.testing.expect(!result1.is_delta);

    // Decompress frame 1
    var decoded1: [frame_size]u8 = undefined;
    const n1 = lz4_import.decompressSafe(result1.data, &decoded1) catch return error.DecompressFailed;
    try std.testing.expectEqualSlices(u8, &frame1, decoded1[0..n1]);

    // Frame 2: shifted gradient
    var frame2: [frame_size]u8 = undefined;
    for (&frame2, 0..) |*b, i| b.* = @truncate(i + 1);
    const result2 = comp.compress(&frame2, 0) orelse return error.CompressFailed;
    try std.testing.expect(result2.is_delta);

    // Decompress frame 2's delta
    var decoded_delta: [frame_size]u8 = undefined;
    const n2 = lz4_import.decompressSafe(result2.data, &decoded_delta) catch return error.DecompressFailed;

    // Add delta to frame1 to reconstruct frame2 (matches FPGA logic)
    var reconstructed: [frame_size]u8 = undefined;
    for (&reconstructed, decoded_delta[0..n2], decoded1[0..n1]) |*r, d, p| {
        r.* = d +% p;
    }
    try std.testing.expectEqualSlices(u8, &frame2, &reconstructed);
}

test "periodic keyframe fires at expected interval" {
    const frame_size = 64;
    var prev_buf: [frame_size]u8 = undefined;
    var prev_buf1: [frame_size]u8 = undefined;
    var delta_buf: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 128]u8 = undefined;
    var state = DeltaState{
        .prev_frames = .{ &prev_buf, &prev_buf1 },
        .delta_buf = &delta_buf,
        .keyframe_interval = 4,
    };

    const comp = compressor(&state, &lz4_buf);
    var frame: [frame_size]u8 = undefined;

    // Frame 0 (first frame): always a keyframe
    for (&frame, 0..) |*b, i| b.* = @truncate(i);
    const r0 = comp.compress(&frame, 0) orelse return error.CompressFailed;
    try std.testing.expect(!r0.is_delta);
    try std.testing.expectEqual(@as(u32, 0), state.frame_count[0]);

    // Frames 1-3: deltas
    for (0..3) |_| {
        for (&frame, 0..) |*b, i| b.* = @truncate(i +% 1);
        const r = comp.compress(&frame, 0) orelse return error.CompressFailed;
        try std.testing.expect(r.is_delta);
    }
    try std.testing.expectEqual(@as(u32, 3), state.frame_count[0]);

    // Frame 4: keyframe (frame_count reaches keyframe_interval)
    for (&frame, 0..) |*b, i| b.* = @truncate(i +% 2);
    const r4 = comp.compress(&frame, 0) orelse return error.CompressFailed;
    try std.testing.expect(!r4.is_delta);
    try std.testing.expectEqual(@as(u32, 0), state.frame_count[0]);
}

test "keyframe_interval = 0 disables periodic keyframes" {
    const frame_size = 64;
    var prev_buf: [frame_size]u8 = undefined;
    var prev_buf1: [frame_size]u8 = undefined;
    var delta_buf: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 128]u8 = undefined;
    var state = DeltaState{
        .prev_frames = .{ &prev_buf, &prev_buf1 },
        .delta_buf = &delta_buf,
        .keyframe_interval = 0,
    };

    const comp = compressor(&state, &lz4_buf);
    var frame: [frame_size]u8 = undefined;

    // First frame: keyframe
    for (&frame) |*b| b.* = 0xAA;
    _ = comp.compress(&frame, 0);

    // 200 subsequent frames should all be deltas (no periodic keyframe)
    for (0..200) |_| {
        for (&frame) |*b| b.* = 0xBB;
        const r = comp.compress(&frame, 0) orelse return error.CompressFailed;
        try std.testing.expect(r.is_delta);
    }
}

test "frame counter resets after keyframe" {
    const frame_size = 64;
    var prev_buf: [frame_size]u8 = undefined;
    var prev_buf1: [frame_size]u8 = undefined;
    var delta_buf: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 128]u8 = undefined;
    var state = DeltaState{
        .prev_frames = .{ &prev_buf, &prev_buf1 },
        .delta_buf = &delta_buf,
        .keyframe_interval = 2,
    };

    const comp = compressor(&state, &lz4_buf);
    const frame = [_]u8{0xCC} ** frame_size;

    // Frame 0: first frame keyframe, count = 0
    _ = comp.compress(&frame, 0);
    try std.testing.expectEqual(@as(u32, 0), state.frame_count[0]);

    // Frame 1: delta, count = 1
    _ = comp.compress(&frame, 0);
    try std.testing.expectEqual(@as(u32, 1), state.frame_count[0]);

    // Frame 2: keyframe fires, count resets to 0
    const r = comp.compress(&frame, 0) orelse return error.CompressFailed;
    try std.testing.expect(!r.is_delta);
    try std.testing.expectEqual(@as(u32, 0), state.frame_count[0]);

    // Frame 3: delta again, count = 1
    const r2 = comp.compress(&frame, 0) orelse return error.CompressFailed;
    try std.testing.expect(r2.is_delta);
    try std.testing.expectEqual(@as(u32, 1), state.frame_count[0]);
}

test "round-trip correctness across a keyframe boundary" {
    const frame_size = 128;
    const lz4_import = @import("lz4");
    var prev_buf: [frame_size]u8 = undefined;
    var prev_buf1: [frame_size]u8 = undefined;
    var delta_buf_storage: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 256]u8 = undefined;
    var state = DeltaState{
        .prev_frames = .{ &prev_buf, &prev_buf1 },
        .delta_buf = &delta_buf_storage,
        .keyframe_interval = 3,
    };

    const comp = compressor(&state, &lz4_buf);

    // Simulate FPGA-side reconstruction state
    var fpga_prev: [frame_size]u8 = undefined;

    // Helper: compress a frame and reconstruct on the "FPGA side"
    const frames = [_][frame_size]u8{
        [_]u8{0x10} ** frame_size, // frame 0: keyframe (first)
        [_]u8{0x20} ** frame_size, // frame 1: delta
        [_]u8{0x30} ** frame_size, // frame 2: delta
        [_]u8{0x40} ** frame_size, // frame 3: keyframe (periodic)
        [_]u8{0x50} ** frame_size, // frame 4: delta
    };

    for (&frames) |*frame| {
        const result = comp.compress(frame, 0) orelse return error.CompressFailed;

        var decompressed: [frame_size]u8 = undefined;
        const n = lz4_import.decompressSafe(result.data, &decompressed) catch return error.DecompressFailed;

        if (result.is_delta) {
            // FPGA adds delta to its previous frame
            for (decompressed[0..n], fpga_prev[0..n], 0..) |d, p, i| {
                fpga_prev[i] = d +% p;
            }
        } else {
            // Keyframe: FPGA replaces its reference directly
            @memcpy(fpga_prev[0..n], decompressed[0..n]);
        }

        try std.testing.expectEqualSlices(u8, frame, fpga_prev[0..n]);
    }
}

test "interlaced round-trip: field 0 deltas use field 0 reference, not field 1" {
    const frame_size = 128;
    const lz4_import = @import("lz4");
    var prev_buf0: [frame_size]u8 = undefined;
    var prev_buf1: [frame_size]u8 = undefined;
    var delta_buf_storage: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 256]u8 = undefined;
    var state = DeltaState{
        .prev_frames = .{ &prev_buf0, &prev_buf1 },
        .delta_buf = &delta_buf_storage,
    };

    const comp = compressor(&state, &lz4_buf);

    // Simulate FPGA-side: separate prev_frame per field
    var fpga_prev: [2][frame_size]u8 = undefined;

    // Interleave fields like real interlaced video:
    // field 0 frame A, field 1 frame A, field 0 frame B, field 1 frame B, ...
    const field0_frames = [_][frame_size]u8{
        [_]u8{0x10} ** frame_size,
        [_]u8{0x12} ** frame_size,
        [_]u8{0x14} ** frame_size,
    };
    const field1_frames = [_][frame_size]u8{
        [_]u8{0xA0} ** frame_size,
        [_]u8{0xA2} ** frame_size,
        [_]u8{0xA4} ** frame_size,
    };

    for (0..3) |i| {
        // Field 0
        const r0 = comp.compress(&field0_frames[i], 0) orelse return error.CompressFailed;
        {
            var decompressed: [frame_size]u8 = undefined;
            const n = lz4_import.decompressSafe(r0.data, &decompressed) catch return error.DecompressFailed;
            if (r0.is_delta) {
                for (decompressed[0..n], fpga_prev[0][0..n], 0..) |d, p, j| {
                    fpga_prev[0][j] = d +% p;
                }
            } else {
                @memcpy(fpga_prev[0][0..n], decompressed[0..n]);
            }
            try std.testing.expectEqualSlices(u8, &field0_frames[i], fpga_prev[0][0..n]);
        }

        // Field 1 — submitted between field 0 frames
        const r1 = comp.compress(&field1_frames[i], 1) orelse return error.CompressFailed;
        {
            var decompressed: [frame_size]u8 = undefined;
            const n = lz4_import.decompressSafe(r1.data, &decompressed) catch return error.DecompressFailed;
            if (r1.is_delta) {
                for (decompressed[0..n], fpga_prev[1][0..n], 0..) |d, p, j| {
                    fpga_prev[1][j] = d +% p;
                }
            } else {
                @memcpy(fpga_prev[1][0..n], decompressed[0..n]);
            }
            try std.testing.expectEqualSlices(u8, &field1_frames[i], fpga_prev[1][0..n]);
        }
    }
}
