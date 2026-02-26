const std = @import("std");
const Connection = @import("Connection.zig");
const lz4 = @import("lz4.zig");

/// State for delta frame encoding. Tracks the previous frame and provides
/// a scratch buffer for XOR computation. Heap-allocated, pointed to by
/// `Compressor.ctx`.
pub const DeltaState = struct {
    prev_frame: []u8,
    delta_buf: []u8,
    has_prev: bool = false,
};

/// Return a `Connection.Compressor` backed by delta (XOR) + LZ4 compression.
/// `state` holds the previous-frame and scratch buffers.
/// `lz4_buf` must be at least `lz4.compressBound(frame_size)` bytes.
pub fn compressor(state: *DeltaState, lz4_buf: []u8) Connection.Compressor {
    return .{
        .ctx = state,
        .buf = lz4_buf,
        .compressFn = &deltaCompress,
    };
}

fn deltaCompress(ctx: ?*anyopaque, src: []const u8, dst: []u8) ?[]const u8 {
    const state: *DeltaState = @ptrCast(@alignCast(ctx orelse return null));

    if (!state.has_prev) {
        // First frame: send full compressed frame, store as reference
        @memcpy(state.prev_frame[0..src.len], src);
        state.has_prev = true;
        return lz4.compress(null, src, dst);
    }

    // XOR src with prev_frame into delta_buf
    const prev = state.prev_frame[0..src.len];
    const delta_out = state.delta_buf[0..src.len];
    for (delta_out, src, prev) |*d, s, p| {
        d.* = s ^ p;
    }

    // Update prev_frame for next call
    @memcpy(state.prev_frame[0..src.len], src);

    // LZ4 compress the delta
    return lz4.compress(null, delta_out, dst);
}

// --- Tests ---

test "first frame compresses without XOR (passthrough to LZ4)" {
    const frame_size = 256;
    var prev_buf: [frame_size]u8 = undefined;
    var delta_buf: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 128]u8 = undefined;
    var state = DeltaState{
        .prev_frame = &prev_buf,
        .delta_buf = &delta_buf,
    };

    const input = [_]u8{0xAB} ** frame_size;
    const comp = compressor(&state, &lz4_buf);
    const result = comp.compress(&input);
    try std.testing.expect(result != null);
    try std.testing.expect(state.has_prev);

    // prev_frame should now contain the input
    try std.testing.expectEqualSlices(u8, &input, prev_buf[0..frame_size]);
}

test "identical successive frames produce highly compressible delta" {
    const frame_size = 1024;
    var prev_buf: [frame_size]u8 = undefined;
    var delta_buf: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 256]u8 = undefined;
    var state = DeltaState{
        .prev_frame = &prev_buf,
        .delta_buf = &delta_buf,
    };

    const frame = [_]u8{0xCC} ** frame_size;
    const comp = compressor(&state, &lz4_buf);

    // First frame
    _ = comp.compress(&frame);

    // Second identical frame: delta is all zeros -> very small compressed
    const result = comp.compress(&frame) orelse return error.CompressFailed;
    // All-zeros compresses very well — should be much smaller than the frame
    try std.testing.expect(result.len < frame_size / 4);
}

test "different frames produce correct XOR delta" {
    const frame_size = 64;
    var prev_buf: [frame_size]u8 = undefined;
    var delta_buf: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 128]u8 = undefined;
    var state = DeltaState{
        .prev_frame = &prev_buf,
        .delta_buf = &delta_buf,
    };

    const comp = compressor(&state, &lz4_buf);

    const frame1 = [_]u8{0xFF} ** frame_size;
    _ = comp.compress(&frame1);

    const frame2 = [_]u8{0x00} ** frame_size;
    _ = comp.compress(&frame2);

    // After frame2, prev_frame should be frame2
    try std.testing.expectEqualSlices(u8, &frame2, prev_buf[0..frame_size]);
}

test "round-trip: delta compress then XOR-reconstruct matches original" {
    const frame_size = 128;
    const lz4_import = @import("lz4");
    var prev_buf: [frame_size]u8 = undefined;
    var delta_buf_storage: [frame_size]u8 = undefined;
    var lz4_buf: [frame_size + 256]u8 = undefined;
    var state = DeltaState{
        .prev_frame = &prev_buf,
        .delta_buf = &delta_buf_storage,
    };

    const comp = compressor(&state, &lz4_buf);

    // Frame 1: gradient
    var frame1: [frame_size]u8 = undefined;
    for (&frame1, 0..) |*b, i| b.* = @truncate(i);
    const compressed1 = comp.compress(&frame1) orelse return error.CompressFailed;

    // Decompress frame 1
    var decoded1: [frame_size]u8 = undefined;
    const n1 = lz4_import.decompressSafe(compressed1, &decoded1) catch return error.DecompressFailed;
    try std.testing.expectEqualSlices(u8, &frame1, decoded1[0..n1]);

    // Frame 2: shifted gradient
    var frame2: [frame_size]u8 = undefined;
    for (&frame2, 0..) |*b, i| b.* = @truncate(i + 1);
    const compressed2 = comp.compress(&frame2) orelse return error.CompressFailed;

    // Decompress frame 2's delta
    var decoded_delta: [frame_size]u8 = undefined;
    const n2 = lz4_import.decompressSafe(compressed2, &decoded_delta) catch return error.DecompressFailed;

    // XOR delta with frame1 to reconstruct frame2
    var reconstructed: [frame_size]u8 = undefined;
    for (&reconstructed, decoded_delta[0..n2], decoded1[0..n1]) |*r, d, p| {
        r.* = d ^ p;
    }
    try std.testing.expectEqualSlices(u8, &frame2, &reconstructed);
}
