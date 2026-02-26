const std = @import("std");
const lz4 = @import("lz4");
const Connection = @import("Connection.zig");

/// Return a `Connection.Compressor` backed by LZ4 block compression.
/// `buf` must be at least `compressBound(max_frame_size)` bytes.
pub fn compressor(buf: []u8) Connection.Compressor {
    return .{
        .ctx = null,
        .buf = buf,
        .compressFn = &compress,
    };
}

/// Maximum compressed output size for a given input size.
/// Use this to size the compression buffer.
pub fn compressBound(input_size: usize) usize {
    return lz4.compressBound(input_size);
}

/// LZ4 block compress `src` into `dst`. Returns the compressed result (never delta).
pub fn compress(_: ?*anyopaque, src: []const u8, dst: []u8, _: u8) ?Connection.CompressResult {
    const n = lz4.compressDefault(src, dst) catch return null;
    return .{ .data = dst[0..n], .is_delta = false };
}

// --- Tests ---

test "compressBound returns value larger than input" {
    const bound = compressBound(1000);
    try std.testing.expect(bound > 1000);
}

test "compressBound of zero" {
    try std.testing.expectEqual(@as(usize, 16), compressBound(0));
}

test "compress known compressible data" {
    // Highly compressible: 4096 identical bytes
    const input = [_]u8{0xAA} ** 4096;
    var buf: [4096 + 256]u8 = undefined;
    const result = compress(null, &input, &buf, 0);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_delta);
    try std.testing.expect(result.?.data.len < input.len);
}

test "compress and decompress round-trip" {
    const input = "The quick brown fox jumps over the lazy dog. " ** 10;
    const bound = compressBound(input.len);
    var comp_buf: [2048]u8 = undefined;
    const result = compress(null, input, comp_buf[0..bound], 0) orelse
        return error.CompressFailed;

    var decomp_buf: [input.len]u8 = undefined;
    const n = lz4.decompressSafe(result.data, &decomp_buf) catch
        return error.DecompressFailed;
    try std.testing.expectEqualSlices(u8, input, decomp_buf[0..n]);
}

test "compressor factory returns working compressor" {
    var buf: [4096]u8 = undefined;
    const comp = compressor(&buf);
    const input = [_]u8{0xBB} ** 1000;
    const result = comp.compress(&input, 0);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_delta);
    try std.testing.expect(result.?.data.len < input.len);
}
