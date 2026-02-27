const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const Health = @import("Health.zig");

const Connection = @This();

/// Connection configuration for opening a UDP socket to the FPGA.
pub const Config = struct {
    host: []const u8,
    port: u16 = 32100,
    mtu: u16 = 1500,
    rgb_mode: protocol.RgbMode = .bgr888,
    sound_rate: protocol.SoundRate = .off,
    sound_channels: protocol.SoundChannels = .off,
    compressor: ?Compressor = null,
    lz4_mode: protocol.Lz4Mode = .off,
};

/// Result of a compression operation, including whether delta encoding was used.
pub const CompressResult = struct {
    data: []const u8,
    is_delta: bool,
};

/// Optional LZ4 compressor passed as a function pointer + context.
pub const Compressor = struct {
    ctx: ?*anyopaque,
    buf: []u8,
    compressFn: *const fn (ctx: ?*anyopaque, src: []const u8, dst: []u8, field: u8) ?CompressResult,

    pub fn compress(self: Compressor, src: []const u8, field: u8) ?CompressResult {
        return self.compressFn(self.ctx, src, self.buf, field);
    }
};

/// Per-frame metadata sent with CMD_BLIT.
pub const FrameOpts = struct {
    frame_num: u32,
    field: u8 = 0,
    vsync_line: u16 = 0,
};

/// Errors that can occur during socket operations.
pub const Error = error{
    SocketCreateFailed,
    ResolveFailed,
    SendFailed,
    SetSendBufFailed,
    AudioTooLarge,
    CompressFailed,
};

// --- State ---
sock: posix.socket_t,
dest_addr: std.net.Address,
config: Config,
status: protocol.FpgaStatus = .{},
health: Health = .{},
recv_buf: [64]u8 = undefined, // ACK is 13 bytes, generous buffer
mtu: u16,

/// Create a non-blocking UDP socket and resolve the destination address.
pub fn open(config: Config) Error!Connection {
    // Resolve host to IPv4 address
    const addr = std.net.Address.parseIp4(config.host, config.port) catch
        return Error.ResolveFailed;

    // Create non-blocking UDP socket
    const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, posix.IPPROTO.UDP) catch
        return Error.SocketCreateFailed;
    errdefer posix.close(sock);

    // Set send buffer to 2MB.
    const send_buf_size: u32 = 2 * 1024 * 1024;
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(send_buf_size)) catch
        return Error.SetSendBufFailed;

    return .{
        .sock = sock,
        .dest_addr = addr,
        .config = config,
        .mtu = config.mtu - 28, // subtract UDP/IP header overhead
    };
}

/// Send CMD_CLOSE and close the socket. Always safe to call.
pub fn close(self: *Connection) void {
    // Best-effort close packet — fire-and-forget.
    var buf: [1]u8 = undefined;
    protocol.buildClosePacket(&buf);
    _ = posix.sendto(self.sock, &buf, 0, &self.dest_addr.any, self.dest_addr.getOsSockLen()) catch {};
    posix.close(self.sock);
    self.* = undefined;
}

/// Drain all pending ACK packets from the socket. Non-blocking.
/// Updates self.status with the latest FPGA status.
pub fn poll(self: *Connection) void {
    while (true) {
        const result = posix.recvfrom(self.sock, &self.recv_buf, 0, null, null) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return,
        };
        if (result >= protocol.ack_size) {
            self.status = protocol.parseAck(self.recv_buf[0..protocol.ack_size]);
        }
    }
}

/// Send CMD_INIT to start the streaming session.
pub fn sendInit(self: *Connection) Error!void {
    var buf: [5]u8 = undefined;
    protocol.buildInitPacket(&buf, self.config.lz4_mode, self.config.sound_rate, self.config.sound_channels, self.config.rgb_mode);
    try self.sendRaw(&buf);
}

/// Send CMD_SWITCHRES to change the display modeline.
pub fn switchRes(self: *Connection, modeline: protocol.Modeline) Error!void {
    var buf: [26]u8 = undefined;
    protocol.buildSwitchResPacket(&buf, modeline);
    try self.sendRaw(&buf);
}

/// Send a frame to the FPGA. If a compressor is configured, compresses
/// the frame and sends a 12-byte LZ4 header; otherwise sends the raw
/// 8-byte header. Frame data is chunked into MTU-sized UDP packets.
/// Caller retains ownership of `frame` -- data is read synchronously.
pub fn sendFrame(self: *Connection, frame: []const u8, opts: FrameOpts) Error!void {
    if (self.config.compressor) |comp| {
        // Compressed path
        const result = comp.compress(frame, opts.field) orelse return Error.CompressFailed;

        if (result.is_delta) {
            // Delta frame: 13-byte header with compressed size + delta flag
            var header: [13]u8 = undefined;
            protocol.buildBlitHeaderLz4Delta(&header, opts.frame_num, opts.field, opts.vsync_line, @intCast(result.data.len));
            try self.sendRaw(&header);
        } else {
            // Non-delta frame: 12-byte header with compressed size
            var header: [12]u8 = undefined;
            protocol.buildBlitHeaderLz4(&header, opts.frame_num, opts.field, opts.vsync_line, @intCast(result.data.len));
            try self.sendRaw(&header);
        }

        // Chunk compressed data
        var offset: usize = 0;
        while (offset < result.data.len) {
            const end = @min(offset + self.mtu, result.data.len);
            try self.sendRaw(result.data[offset..end]);
            offset = end;
        }
    } else {
        // Uncompressed path: 8-byte header
        var header: [8]u8 = undefined;
        protocol.buildBlitHeader(&header, opts.frame_num, opts.field, opts.vsync_line);
        try self.sendRaw(&header);

        // Chunk frame data into MTU-sized UDP packets
        var offset: usize = 0;
        while (offset < frame.len) {
            const end = @min(offset + self.mtu, frame.len);
            try self.sendRaw(frame[offset..end]);
            offset = end;
        }
    }
}

/// Send CMD_AUDIO header + PCM data in MTU-sized chunks.
/// `pcm` contains raw 16-bit signed PCM data (interleaved if stereo).
/// Maximum 65535 bytes per call (uint16 header field limit).
/// Caller retains ownership of `pcm` — data is read synchronously.
pub fn sendAudio(self: *Connection, pcm: []const u8) Error!void {
    if (pcm.len == 0) return;
    if (pcm.len > std.math.maxInt(u16)) return Error.AudioTooLarge;
    const sample_bytes: u16 = @intCast(pcm.len);

    // Send 3-byte audio header
    var header: [3]u8 = undefined;
    protocol.buildAudioHeader(&header, sample_bytes);
    try self.sendRaw(&header);

    // Chunk PCM data into MTU-sized UDP packets
    var offset: usize = 0;
    while (offset < pcm.len) {
        const end = @min(offset + self.mtu, pcm.len);
        try self.sendRaw(pcm[offset..end]);
        offset = end;
    }
}

/// Read the latest FPGA status (updated by poll).
pub fn fpgaStatus(self: *const Connection) protocol.FpgaStatus {
    return self.status;
}

/// Poll for pending ACKs and return the latest FPGA status.
/// Convenience method combining poll() + fpgaStatus().
pub fn pollStatus(self: *Connection) protocol.FpgaStatus {
    self.poll();
    return self.status;
}

/// Read the health stats (updated by poll).
pub fn getHealth(self: *const Connection) Health {
    return self.health;
}

/// Send CMD_GET_STATUS then block until the FPGA responds or timeout.
/// Actively requests status so the FPGA always has a reason to send an ACK.
/// This breaks two deadlocks:
///   1. Bootstrap: no ACKs arrive until we send something
///   2. Backpressure: vram_ready=0 prevents frame submission, but we
///      still need ACKs to detect recovery
pub fn waitSync(self: *Connection, timeout_ms: i32) bool {
    // Request status — gives FPGA a reason to send an ACK
    self.sendGetStatus();

    var fds = [1]std.posix.pollfd{.{
        .fd = self.sock,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, timeout_ms) catch return false;
    if (ready > 0) {
        self.poll(); // drain ACKs, update status
        return true;
    }
    return false;
}

/// Best-effort CMD_GET_STATUS (1 byte). Fire-and-forget.
fn sendGetStatus(self: *Connection) void {
    var buf: [1]u8 = .{@intFromEnum(protocol.Command.get_status)};
    _ = posix.sendto(self.sock, &buf, 0, &self.dest_addr.any, self.dest_addr.getOsSockLen()) catch {};
}

// --- Internal ---

fn sendRaw(self: *Connection, data: []const u8) Error!void {
    _ = posix.sendto(
        self.sock,
        data,
        0,
        &self.dest_addr.any,
        self.dest_addr.getOsSockLen(),
    ) catch return Error.SendFailed;
}

// --- Tests ---

test "Connection open and close without crash" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    conn.close();
}

test "Connection poll returns immediately on empty socket" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // Should return immediately without blocking (non-blocking socket)
    conn.poll();
    // Status should be default zeros
    const s = conn.fpgaStatus();
    try std.testing.expectEqual(@as(u32, 0), s.frame);
}

test "Connection sendInit does not error on loopback" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // sendto on UDP doesn't fail even with no listener (fire-and-forget)
    try conn.sendInit();
}

test "Connection switchRes does not error on loopback" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    try conn.switchRes(.{
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
    });
}

test "Connection sendFrame chunks correctly" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // 320x240x3 = 230400 bytes, MTU=1472 -> 157 chunks
    const frame = [_]u8{0xAB} ** (320 * 240 * 3);
    try conn.sendFrame(&frame, .{ .frame_num = 1 });
}

// --- Comprehensive edge-case tests ---

test "Connection open with invalid host returns error" {
    const result = Connection.open(.{ .host = "not.a.valid.ip" });
    try std.testing.expectError(Error.ResolveFailed, result);
}

test "Connection multiple poll calls in a row" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // Multiple polls on empty socket should be safe and idempotent
    conn.poll();
    conn.poll();
    conn.poll();
    const s = conn.fpgaStatus();
    try std.testing.expectEqual(@as(u32, 0), s.frame);
}

test "Connection sendFrame with empty frame (0 bytes)" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // Empty frame: only the 8-byte header gets sent, no chunk loop iterations
    const empty: []const u8 = &.{};
    try conn.sendFrame(empty, .{ .frame_num = 0 });
}

test "Connection sendFrame with exactly MTU bytes (1 chunk)" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // conn.mtu = 1500 - 28 = 1472
    const frame = [_]u8{0xCC} ** 1472;
    try conn.sendFrame(&frame, .{ .frame_num = 5 });
}

test "Connection sendFrame with MTU+1 bytes (2 chunks)" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // 1473 bytes = 1472 + 1 -> 2 chunks
    const frame = [_]u8{0xDD} ** 1473;
    try conn.sendFrame(&frame, .{ .frame_num = 10 });
}

test "Connection mtu calculation subtracts UDP/IP overhead" {
    const conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999, .mtu = 1500 });
    try std.testing.expectEqual(@as(u16, 1472), conn.mtu);
    // use a variable to close cleanly (close takes *Connection)
    var conn2 = conn;
    conn2.close();
}

test "Connection mtu calculation with custom mtu" {
    const conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999, .mtu = 9000 });
    try std.testing.expectEqual(@as(u16, 8972), conn.mtu);
    var conn2 = conn;
    conn2.close();
}

test "Connection waitSync returns false on timeout (no peer)" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // No peer sending ACKs, so poll() should timeout immediately
    const got_data = conn.waitSync(1); // 1ms timeout
    try std.testing.expect(!got_data);
}

// --- Audio tests ---

test "Connection sendAudio with empty data (no-op)" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    const empty: []const u8 = &.{};
    try conn.sendAudio(empty);
}

test "Connection sendAudio with small PCM buffer" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // 100 bytes of PCM data (well under MTU)
    const pcm = [_]u8{0x42} ** 100;
    try conn.sendAudio(&pcm);
}

test "Connection sendAudio with exactly MTU bytes (1 chunk)" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // conn.mtu = 1500 - 28 = 1472
    const pcm = [_]u8{0xAA} ** 1472;
    try conn.sendAudio(&pcm);
}

test "Connection sendAudio with MTU+1 bytes (2 chunks)" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    const pcm = [_]u8{0xBB} ** 1473;
    try conn.sendAudio(&pcm);
}

test "Connection sendAudio with large buffer (multiple chunks)" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // 48kHz stereo 16-bit, ~10ms = 48000*2*2*0.01 = 1920 bytes
    const pcm = [_]u8{0xCC} ** 1920;
    try conn.sendAudio(&pcm);
}

test "Connection sendAudio rejects data exceeding uint16 max" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // 65536 bytes exceeds uint16 max (65535)
    const pcm = [_]u8{0} ** 65536;
    try std.testing.expectError(Error.AudioTooLarge, conn.sendAudio(&pcm));
}

test "Connection sendAudio with exactly uint16 max bytes" {
    var conn = try Connection.open(.{ .host = "127.0.0.1", .port = 9999 });
    defer conn.close();
    // 65535 bytes = uint16 max, should succeed
    const pcm = [_]u8{0} ** 65535;
    try conn.sendAudio(&pcm);
}

test "Connection sendInit passes audio config" {
    // Verify sendInit doesn't crash with audio config set
    var conn = try Connection.open(.{
        .host = "127.0.0.1",
        .port = 9999,
        .sound_rate = .rate_48000,
        .sound_channels = .stereo,
    });
    defer conn.close();
    try conn.sendInit();
}

// --- Compressor tests ---

fn mockCompress(_: ?*anyopaque, src: []const u8, dst: []u8, _: u8) ?CompressResult {
    // Mock: copy first half of input as "compressed" output
    const out_len = src.len / 2;
    if (out_len > dst.len) return null;
    @memcpy(dst[0..out_len], src[0..out_len]);
    return .{ .data = dst[0..out_len], .is_delta = false };
}

fn mockCompressFail(_: ?*anyopaque, _: []const u8, _: []u8, _: u8) ?CompressResult {
    return null;
}

test "Connection sendFrame with compressor uses compressed path" {
    var compress_buf: [4096]u8 = undefined;
    var conn = try Connection.open(.{
        .host = "127.0.0.1",
        .port = 9999,
        .compressor = .{
            .ctx = null,
            .buf = &compress_buf,
            .compressFn = &mockCompress,
        },
    });
    defer conn.close();
    const frame = [_]u8{0xAB} ** 1000;
    try conn.sendFrame(&frame, .{ .frame_num = 1 });
}

test "Connection sendFrame with failing compressor returns CompressFailed" {
    var compress_buf: [4096]u8 = undefined;
    var conn = try Connection.open(.{
        .host = "127.0.0.1",
        .port = 9999,
        .compressor = .{
            .ctx = null,
            .buf = &compress_buf,
            .compressFn = &mockCompressFail,
        },
    });
    defer conn.close();
    const frame = [_]u8{0xAB} ** 100;
    try std.testing.expectError(Error.CompressFailed, conn.sendFrame(&frame, .{ .frame_num = 1 }));
}

test "Connection sendInit signals lz4 when lz4_mode set" {
    var compress_buf: [4096]u8 = undefined;
    var conn = try Connection.open(.{
        .host = "127.0.0.1",
        .port = 9999,
        .lz4_mode = .lz4,
        .compressor = .{
            .ctx = null,
            .buf = &compress_buf,
            .compressFn = &mockCompress,
        },
    });
    defer conn.close();
    try conn.sendInit();
}
