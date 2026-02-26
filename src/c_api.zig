const std = @import("std");
const Connection = @import("Connection.zig");
const protocol = @import("protocol.zig");
const Health = @import("Health.zig");
const lz4 = @import("lz4.zig");
const delta = @import("delta.zig");
const version_info = @import("version.zig");
const sync = @import("sync.zig");

// --- Internal handle ---

const ConnHandle = struct {
    conn: Connection,
    modeline: ?protocol.Modeline = null,
    timing: ?sync.FrameTiming = null,
    compress_buf: ?[]u8 = null,
    delta_state: ?*delta.DeltaState = null,
    delta_buf: ?[]u8 = null,
    prev_frame: ?[]u8 = null,

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

/// Open a UDP connection with optional LZ4 compression and send CMD_INIT.
/// When `lz4_mode` > 0, allocates a compression buffer and configures the
/// LZ4 compressor. Returns an opaque handle, or null on failure.
pub export fn gmz_connect_ex(host: [*:0]const u8, mtu: u16, rgb_mode: u8, sound_rate: u8, sound_channels: u8, lz4_mode: u8) callconv(.c) ?*ConnHandle {
    const host_slice = std.mem.span(host);
    const mode: protocol.RgbMode = std.meta.intToEnum(protocol.RgbMode, rgb_mode) catch return null;
    const rate: protocol.SoundRate = std.meta.intToEnum(protocol.SoundRate, sound_rate) catch return null;
    const channels: protocol.SoundChannels = std.meta.intToEnum(protocol.SoundChannels, sound_channels) catch return null;
    const handle = std.heap.c_allocator.create(ConnHandle) catch return null;

    const lz4_enum: protocol.Lz4Mode = std.meta.intToEnum(protocol.Lz4Mode, lz4_mode) catch return null;

    // Max frame size: generous 2MB covering up to ~800x600 BGR888
    const max_frame_size = 2 * 1024 * 1024;

    var compressor_val: ?Connection.Compressor = null;
    var compress_buf: ?[]u8 = null;
    var delta_state_ptr: ?*delta.DeltaState = null;
    var delta_buf_alloc: ?[]u8 = null;
    var prev_frame_alloc: ?[]u8 = null;

    if (lz4_mode > 0) {
        const buf = std.heap.c_allocator.alloc(u8, lz4.compressBound(max_frame_size)) catch {
            std.heap.c_allocator.destroy(handle);
            return null;
        };
        compress_buf = buf;

        // Delta modes: lz4_delta(2), lz4_hc_delta(4), adaptive_delta(6)
        const is_delta = (lz4_mode == 2 or lz4_mode == 4 or lz4_mode == 6);
        if (is_delta) {
            const pf = std.heap.c_allocator.alloc(u8, max_frame_size) catch {
                std.heap.c_allocator.free(buf);
                std.heap.c_allocator.destroy(handle);
                return null;
            };
            prev_frame_alloc = pf;

            const db = std.heap.c_allocator.alloc(u8, max_frame_size) catch {
                std.heap.c_allocator.free(pf);
                std.heap.c_allocator.free(buf);
                std.heap.c_allocator.destroy(handle);
                return null;
            };
            delta_buf_alloc = db;

            const ds = std.heap.c_allocator.create(delta.DeltaState) catch {
                std.heap.c_allocator.free(db);
                std.heap.c_allocator.free(pf);
                std.heap.c_allocator.free(buf);
                std.heap.c_allocator.destroy(handle);
                return null;
            };
            ds.* = .{
                .prev_frame = pf,
                .delta_buf = db,
            };
            delta_state_ptr = ds;
            compressor_val = delta.compressor(ds, buf);
        } else {
            compressor_val = lz4.compressor(buf);
        }
    }

    handle.* = .{
        .conn = Connection.open(.{
            .host = host_slice,
            .port = 32100,
            .mtu = mtu,
            .rgb_mode = mode,
            .sound_rate = rate,
            .sound_channels = channels,
            .compressor = compressor_val,
            .lz4_mode = lz4_enum,
        }) catch {
            if (delta_state_ptr) |ds| std.heap.c_allocator.destroy(ds);
            if (delta_buf_alloc) |db| std.heap.c_allocator.free(db);
            if (prev_frame_alloc) |pf| std.heap.c_allocator.free(pf);
            if (compress_buf) |buf| std.heap.c_allocator.free(buf);
            std.heap.c_allocator.destroy(handle);
            return null;
        },
        .compress_buf = compress_buf,
        .delta_state = delta_state_ptr,
        .delta_buf = delta_buf_alloc,
        .prev_frame = prev_frame_alloc,
    };
    handle.conn.sendInit() catch {
        if (handle.delta_state) |ds| std.heap.c_allocator.destroy(ds);
        if (handle.delta_buf) |db| std.heap.c_allocator.free(db);
        if (handle.prev_frame) |pf| std.heap.c_allocator.free(pf);
        if (handle.compress_buf) |buf| std.heap.c_allocator.free(buf);
        handle.conn.close();
        std.heap.c_allocator.destroy(handle);
        return null;
    };
    return handle;
}

/// Send CMD_CLOSE, close the socket, and free the handle. Null-safe.
pub export fn gmz_disconnect(conn: ?*ConnHandle) callconv(.c) void {
    const handle = conn orelse return;
    if (handle.delta_state) |ds| std.heap.c_allocator.destroy(ds);
    if (handle.delta_buf) |db| std.heap.c_allocator.free(db);
    if (handle.prev_frame) |pf| std.heap.c_allocator.free(pf);
    if (handle.compress_buf) |buf| std.heap.c_allocator.free(buf);
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
    handle.timing = sync.frameTiming(modeline);
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

/// Return the library version string (e.g. "0.1.0"). Null-terminated.
pub export fn gmz_version() callconv(.c) [*:0]const u8 {
    return version_info.version_string;
}

/// Return the library major version number.
pub export fn gmz_version_major() callconv(.c) u32 {
    return @intCast(version_info.version.major);
}

/// Return the library minor version number.
pub export fn gmz_version_minor() callconv(.c) u32 {
    return @intCast(version_info.version.minor);
}

/// Return the library patch version number.
pub export fn gmz_version_patch() callconv(.c) u32 {
    return @intCast(version_info.version.patch);
}

/// Get raster time offset in nanoseconds for the given submitted frame.
/// Polls for the latest ACK internally. Returns 0 if no modeline set.
pub export fn gmz_raster_offset_ns(conn: ?*ConnHandle, submitted_frame: u32) callconv(.c) i32 {
    const handle = conn orelse return 0;
    const timing = handle.timing orelse return 0;
    handle.conn.poll();
    const offset = sync.rasterOffsetNs(timing, handle.conn.fpgaStatus(), submitted_frame);
    return std.math.lossyCast(i32, offset);
}

/// Compute optimal vsync line for next frame submission.
/// Returns v_total/2 if no modeline set (safe default).
pub export fn gmz_calc_vsync(conn: ?*ConnHandle, margin_ns: u32, emulation_ns: u64, stream_ns: u64) callconv(.c) u16 {
    const handle = conn orelse return 0;
    const timing = handle.timing orelse return if (handle.modeline) |m| m.v_total / 2 else 262;
    // Use last measured health for ping estimate (avg_sync_wait * 1e6 to convert ms -> ns).
    const h = handle.conn.getHealth();
    const ping_ns: u64 = @intFromFloat(@round(h.avg_sync_wait_ms * 1_000_000.0));
    return sync.calcVsyncLine(timing, ping_ns, @intCast(margin_ns), emulation_ns, stream_ns);
}

/// Get frame period in nanoseconds from current modeline. 0 if no modeline set.
pub export fn gmz_frame_time_ns(conn: ?*ConnHandle) callconv(.c) u64 {
    const handle = conn orelse return 0;
    const timing = handle.timing orelse return 0;
    return timing.frame_time_ns;
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

test "null handle safety: gmz_raster_offset_ns" {
    try std.testing.expectEqual(@as(i32, 0), gmz_raster_offset_ns(null, 1));
}

test "null handle safety: gmz_calc_vsync" {
    try std.testing.expectEqual(@as(u16, 0), gmz_calc_vsync(null, 0, 0, 0));
}

test "null handle safety: gmz_frame_time_ns" {
    try std.testing.expectEqual(@as(u64, 0), gmz_frame_time_ns(null));
}

test "gmz_connect_ex without lz4 behaves like gmz_connect" {
    const handle = gmz_connect_ex("127.0.0.1", 1500, 0, 0, 0, 0);
    // May fail to connect (no FPGA) but should not crash
    if (handle) |h| gmz_disconnect(h);
}

test "gmz_connect_ex with lz4 enabled" {
    const handle = gmz_connect_ex("127.0.0.1", 1500, 0, 0, 0, 1);
    // May fail to connect (no FPGA) but should not crash
    if (handle) |h| gmz_disconnect(h);
}

test "gmz_connect_ex with lz4_delta mode" {
    const handle = gmz_connect_ex("127.0.0.1", 1500, 0, 0, 0, 2);
    if (handle) |h| {
        // Delta state should be allocated
        try std.testing.expect(h.delta_state != null);
        try std.testing.expect(h.delta_buf != null);
        try std.testing.expect(h.prev_frame != null);
        gmz_disconnect(h);
    }
}

test "gmz_connect_ex with invalid lz4_mode returns null" {
    const handle = gmz_connect_ex("127.0.0.1", 1500, 0, 0, 0, 255);
    try std.testing.expect(handle == null);
}

test "gmz_version returns non-null string" {
    const v = gmz_version();
    try std.testing.expect(v[0] != 0);
    try std.testing.expectEqualStrings("0.1.0", std.mem.span(v));
}

test "gmz_version_major/minor/patch" {
    try std.testing.expectEqual(@as(u32, 0), gmz_version_major());
    try std.testing.expectEqual(@as(u32, 1), gmz_version_minor());
    try std.testing.expectEqual(@as(u32, 0), gmz_version_patch());
}
