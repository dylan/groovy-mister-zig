const std = @import("std");
const Connection = @import("Connection.zig");
const protocol = @import("protocol.zig");
const Health = @import("Health.zig");

// --- Internal handle ---

const ConnHandle = struct {
    conn: Connection,
    modeline: ?protocol.Modeline = null,

    fn periodMs(self: *const ConnHandle) f64 {
        const m = self.modeline orelse return 16.7;
        return (@as(f64, @floatFromInt(m.h_total)) * @as(f64, @floatFromInt(m.v_total))) /
            (m.pixel_clock * 1000.0);
    }
};

// --- C-visible structs ---

/// Combined modeline parameters for `gmz_set_modeline`.
pub const gmz_modeline_t = extern struct {
    pixel_clock: f64 = 0,
    h_active: u16 = 0,
    h_begin: u16 = 0,
    h_end: u16 = 0,
    h_total: u16 = 0,
    v_active: u16 = 0,
    v_begin: u16 = 0,
    v_end: u16 = 0,
    v_total: u16 = 0,
    interlaced: u8 = 0,
    _pad: [6]u8 = .{0} ** 6,
};

/// Combined FPGA status + health returned by `gmz_tick`.
pub const gmz_state_t = extern struct {
    frame: u32 = 0,
    frame_echo: u32 = 0,
    vcount: u16 = 0,
    vcount_echo: u16 = 0,
    vram_ready: u8 = 0,
    vram_end_frame: u8 = 0,
    vram_synced: u8 = 0,
    vga_frameskip: u8 = 0,
    vga_vblank: u8 = 0,
    vga_f1: u8 = 0,
    audio_active: u8 = 0,
    vram_queue: u8 = 0,
    avg_sync_wait_ms: f64 = 0,
    p95_sync_wait_ms: f64 = 0,
    vram_ready_rate: f64 = 1.0,
    stall_threshold_ms: f64 = 0,
};

// --- Exported functions ---

/// Open a UDP connection to the FPGA and send CMD_INIT.
/// Returns an opaque handle, or null on failure.
/// sound_rate: 0=off, 1=22050, 2=44100, 3=48000
/// sound_channels: 0=off, 1=mono, 2=stereo
pub export fn gmz_connect(host: [*:0]const u8, mtu: u16, rgb_mode: u8, sound_rate: u8, sound_channels: u8) callconv(.c) ?*ConnHandle {
    const host_slice = std.mem.span(host);
    const mode: protocol.RgbMode = std.meta.intToEnum(protocol.RgbMode, rgb_mode) catch return null;
    const rate: protocol.SoundRate = std.meta.intToEnum(protocol.SoundRate, sound_rate) catch return null;
    const channels: protocol.SoundChannels = std.meta.intToEnum(protocol.SoundChannels, sound_channels) catch return null;
    const handle = std.heap.c_allocator.create(ConnHandle) catch return null;
    handle.* = .{
        .conn = Connection.open(.{
            .host = host_slice,
            .port = 32100,
            .mtu = mtu,
            .rgb_mode = mode,
            .sound_rate = rate,
            .sound_channels = channels,
        }) catch {
            std.heap.c_allocator.destroy(handle);
            return null;
        },
    };
    handle.conn.sendInit() catch {
        handle.conn.close();
        std.heap.c_allocator.destroy(handle);
        return null;
    };
    return handle;
}

/// Send CMD_CLOSE, close the socket, and free the handle. Null-safe.
pub export fn gmz_disconnect(conn: ?*ConnHandle) callconv(.c) void {
    const handle = conn orelse return;
    handle.conn.close();
    std.heap.c_allocator.destroy(handle);
}

/// Poll for ACKs, record health metrics, and return combined FPGA status + health.
/// Null-safe (returns zeroed state).
pub export fn gmz_tick(conn: ?*ConnHandle) callconv(.c) gmz_state_t {
    const handle = conn orelse return .{};
    handle.conn.poll();
    const s = handle.conn.fpgaStatus();
    handle.conn.health.recordReady(s.vram_ready);
    const h = handle.conn.getHealth();
    return .{
        .frame = s.frame,
        .frame_echo = s.frame_echo,
        .vcount = s.vcount,
        .vcount_echo = s.vcount_echo,
        .vram_ready = @intFromBool(s.vram_ready),
        .vram_end_frame = @intFromBool(s.vram_end_frame),
        .vram_synced = @intFromBool(s.vram_synced),
        .vga_frameskip = @intFromBool(s.vga_frameskip),
        .vga_vblank = @intFromBool(s.vga_vblank),
        .vga_f1 = @intFromBool(s.vga_f1),
        .audio_active = @intFromBool(s.audio_active),
        .vram_queue = @intFromBool(s.vram_queue),
        .avg_sync_wait_ms = h.avg_sync_wait_ms,
        .p95_sync_wait_ms = h.p95_sync_wait_ms,
        .vram_ready_rate = h.vram_ready_rate,
        .stall_threshold_ms = h.stallThreshold(handle.periodMs()),
    };
}

/// Send CMD_SWITCHRES to change display timing. Returns 0 on success, -1 on error.
pub export fn gmz_set_modeline(conn: ?*ConnHandle, m: *const gmz_modeline_t) callconv(.c) c_int {
    const handle = conn orelse return -1;
    const modeline = protocol.Modeline{
        .pixel_clock = m.pixel_clock,
        .h_active = m.h_active,
        .h_begin = m.h_begin,
        .h_end = m.h_end,
        .h_total = m.h_total,
        .v_active = m.v_active,
        .v_begin = m.v_begin,
        .v_end = m.v_end,
        .v_total = m.v_total,
        .interlaced = m.interlaced != 0,
    };
    handle.modeline = modeline;
    handle.conn.switchRes(modeline) catch return -1;
    return 0;
}

/// Send a BGR frame to the FPGA and record sync timing for health.
/// Returns 0 on success, -1 on error.
pub export fn gmz_submit(
    conn: ?*ConnHandle,
    data: [*]const u8,
    len: usize,
    frame: u32,
    field: u8,
    vsync_line: u16,
    sync_wait_ms: f64,
) callconv(.c) c_int {
    const handle = conn orelse return -1;
    handle.conn.sendFrame(data[0..len], .{
        .frame_num = frame,
        .field = field,
        .vsync_line = vsync_line,
    }) catch return -1;
    handle.conn.health.record(sync_wait_ms, handle.conn.fpgaStatus().vram_ready);
    return 0;
}

/// Send raw PCM audio data to the FPGA. Returns 0 on success, -1 on error.
/// `data` is raw 16-bit signed PCM (interleaved if stereo).
/// `len` is the total byte count of PCM data.
pub export fn gmz_submit_audio(conn: ?*ConnHandle, data: [*]const u8, len: usize) callconv(.c) c_int {
    const handle = conn orelse return -1;
    handle.conn.sendAudio(data[0..len]) catch return -1;
    return 0;
}

/// Block until ACK received or timeout. Returns 0=ACK, 1=timeout, -1=null handle.
pub export fn gmz_wait_sync(conn: ?*ConnHandle, timeout_ms: c_int) callconv(.c) c_int {
    const handle = conn orelse return -1;
    return if (handle.conn.waitSync(timeout_ms)) 0 else 1;
}

// --- Tests ---

test "ConnHandle.periodMs with modeline" {
    // 320x240 @ 60Hz: pixel_clock ≈ 6.7 MHz
    // h_total=408, v_total=262 → period = (408*262) / (6.7*1000) ≈ 15.95ms
    // Use a more standard example: 640x480 @ ~60Hz
    // h_total=800, v_total=525, pixel_clock=25.175 MHz
    // period = (800*525) / (25175) ≈ 16.669ms
    var handle: ConnHandle = undefined;
    handle.modeline = .{
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
    const period = handle.periodMs();
    try std.testing.expectApproxEqAbs(@as(f64, 16.683), period, 0.1);
}

test "ConnHandle.periodMs without modeline defaults to 16.7" {
    var handle: ConnHandle = undefined;
    handle.modeline = null;
    try std.testing.expectApproxEqAbs(@as(f64, 16.7), handle.periodMs(), 0.001);
}

test "gmz_state_t field layout" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(gmz_state_t, "frame"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(gmz_state_t, "frame_echo"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(gmz_state_t, "vcount"));
    try std.testing.expectEqual(@as(usize, 10), @offsetOf(gmz_state_t, "vcount_echo"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(gmz_state_t, "vram_ready"));
    try std.testing.expectEqual(@as(usize, 13), @offsetOf(gmz_state_t, "vram_end_frame"));
    try std.testing.expectEqual(@as(usize, 14), @offsetOf(gmz_state_t, "vram_synced"));
    try std.testing.expectEqual(@as(usize, 15), @offsetOf(gmz_state_t, "vga_frameskip"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(gmz_state_t, "vga_vblank"));
    try std.testing.expectEqual(@as(usize, 17), @offsetOf(gmz_state_t, "vga_f1"));
    try std.testing.expectEqual(@as(usize, 18), @offsetOf(gmz_state_t, "audio_active"));
    try std.testing.expectEqual(@as(usize, 19), @offsetOf(gmz_state_t, "vram_queue"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(gmz_state_t, "avg_sync_wait_ms"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(gmz_state_t, "p95_sync_wait_ms"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(gmz_state_t, "vram_ready_rate"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(gmz_state_t, "stall_threshold_ms"));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(gmz_state_t));
}

test "gmz_modeline_t field layout" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(gmz_modeline_t, "pixel_clock"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(gmz_modeline_t, "h_active"));
    try std.testing.expectEqual(@as(usize, 10), @offsetOf(gmz_modeline_t, "h_begin"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(gmz_modeline_t, "h_end"));
    try std.testing.expectEqual(@as(usize, 14), @offsetOf(gmz_modeline_t, "h_total"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(gmz_modeline_t, "v_active"));
    try std.testing.expectEqual(@as(usize, 18), @offsetOf(gmz_modeline_t, "v_begin"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(gmz_modeline_t, "v_end"));
    try std.testing.expectEqual(@as(usize, 22), @offsetOf(gmz_modeline_t, "v_total"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(gmz_modeline_t, "interlaced"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(gmz_modeline_t));
}

test "gmz_state_t defaults" {
    const s = gmz_state_t{};
    try std.testing.expectEqual(@as(u32, 0), s.frame);
    try std.testing.expectEqual(@as(u32, 0), s.frame_echo);
    try std.testing.expectEqual(@as(u16, 0), s.vcount);
    try std.testing.expectEqual(@as(u16, 0), s.vcount_echo);
    try std.testing.expectEqual(@as(u8, 0), s.vram_ready);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), s.avg_sync_wait_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), s.p95_sync_wait_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), s.vram_ready_rate, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), s.stall_threshold_ms, 0.001);
}

test "null handle safety: gmz_disconnect" {
    gmz_disconnect(null);
}

test "null handle safety: gmz_tick" {
    const state = gmz_tick(null);
    try std.testing.expectEqual(@as(u32, 0), state.frame);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), state.vram_ready_rate, 0.001);
}

test "null handle safety: gmz_set_modeline" {
    var m = gmz_modeline_t{};
    try std.testing.expectEqual(@as(c_int, -1), gmz_set_modeline(null, &m));
}

test "null handle safety: gmz_submit" {
    const dummy = [_]u8{0};
    try std.testing.expectEqual(@as(c_int, -1), gmz_submit(null, &dummy, 1, 0, 0, 0, 0.0));
}

test "null handle safety: gmz_submit_audio" {
    const dummy = [_]u8{0};
    try std.testing.expectEqual(@as(c_int, -1), gmz_submit_audio(null, &dummy, 1));
}

test "null handle safety: gmz_wait_sync" {
    try std.testing.expectEqual(@as(c_int, -1), gmz_wait_sync(null, 10));
}
