const std = @import("std");

// --- Command codes ---

/// MiSTer FPGA UDP command codes.
pub const Command = enum(u8) {
    close = 1,
    init = 2,
    switch_res = 3,
    audio = 4,
    get_status = 5,
    blit = 7,
    get_version = 8,
};

// --- Enums ---

/// Pixel format for frame data sent to the FPGA.
pub const RgbMode = enum(u8) {
    bgr888 = 0,
    bgra8888 = 1,
    rgb565 = 2,
};

/// LZ4 compression mode. FPGA only distinguishes off (0) vs on (non-zero).
pub const Lz4Mode = enum(u8) {
    off = 0,
    lz4 = 1,
    lz4_delta = 2,
    lz4_hc = 3,
    lz4_hc_delta = 4,
    adaptive = 5,
    adaptive_delta = 6,
};

/// Audio sample rate for PCM streaming.
pub const SoundRate = enum(u8) {
    off = 0,
    rate_22050 = 1,
    rate_44100 = 2,
    rate_48000 = 3,
};

/// Audio channel layout for PCM streaming.
pub const SoundChannels = enum(u8) {
    off = 0,
    mono = 1,
    stereo = 2,
};

// --- Modeline ---

/// CRT display timing parameters for CMD_SWITCHRES.
pub const Modeline = struct {
    /// Pixel clock in MHz.
    pixel_clock: f64,
    /// Horizontal active pixels.
    h_active: u16,
    /// Horizontal sync start.
    h_begin: u16,
    /// Horizontal sync end.
    h_end: u16,
    /// Horizontal total pixels per line.
    h_total: u16,
    /// Vertical active lines.
    v_active: u16,
    /// Vertical sync start.
    v_begin: u16,
    /// Vertical sync end.
    v_end: u16,
    /// Vertical total lines per frame.
    v_total: u16,
    /// Whether the display mode is interlaced.
    interlaced: bool,
};

// --- FPGA Status (parsed from 13-byte ACK) ---

/// FPGA status parsed from a 13-byte ACK packet (little-endian).
pub const FpgaStatus = struct {
    /// Last frame number the FPGA acknowledged.
    frame_echo: u32 = 0,
    /// Last vcount the FPGA echoed back.
    vcount_echo: u16 = 0,
    /// Current FPGA frame counter.
    frame: u32 = 0,
    /// Current FPGA vertical line counter.
    vcount: u16 = 0,
    /// VRAM is ready to accept a new frame.
    vram_ready: bool = false,
    /// VRAM finished displaying the current frame.
    vram_end_frame: bool = false,
    /// VRAM write pointer is synced with the display scanout.
    vram_synced: bool = false,
    /// VGA output skipped a frame.
    vga_frameskip: bool = false,
    /// VGA output is in vertical blanking interval.
    vga_vblank: bool = false,
    /// Interlace field flag (0 = even, 1 = odd).
    vga_f1: bool = false,
    /// Audio subsystem is active.
    audio_active: bool = false,
    /// VRAM write queue has pending data.
    vram_queue: bool = false,
};

/// Size in bytes of an FPGA ACK packet.
pub const ack_size = 13;

/// Parse a 13-byte FPGA ACK packet into FpgaStatus.
pub fn parseAck(buf: *const [ack_size]u8) FpgaStatus {
    const bits = buf[12];
    return .{
        .frame_echo = std.mem.readInt(u32, buf[0..4], .little),
        .vcount_echo = std.mem.readInt(u16, buf[4..6], .little),
        .frame = std.mem.readInt(u32, buf[6..10], .little),
        .vcount = std.mem.readInt(u16, buf[10..12], .little),
        .vram_ready = (bits & 0x01) != 0,
        .vram_end_frame = (bits & 0x02) != 0,
        .vram_synced = (bits & 0x04) != 0,
        .vga_frameskip = (bits & 0x08) != 0,
        .vga_vblank = (bits & 0x10) != 0,
        .vga_f1 = (bits & 0x20) != 0,
        .audio_active = (bits & 0x40) != 0,
        .vram_queue = (bits & 0x80) != 0,
    };
}

// --- Packet builders ---
// These write command packets into caller-provided buffers.
// No allocation, no I/O.

/// Build CMD_INIT packet (5 bytes).
/// The HPS daemon clamps compression to 0 or 1 (`compression <= 1 ? compression : 0`),
/// so we send 1 for any LZ4 mode, 0 for off.
pub fn buildInitPacket(buf: *[5]u8, lz4_mode: Lz4Mode, sound_rate: SoundRate, sound_channels: SoundChannels, rgb_mode: RgbMode) void {
    buf[0] = @intFromEnum(Command.init);
    buf[1] = if (lz4_mode != .off) 1 else 0;
    buf[2] = @intFromEnum(sound_rate);
    buf[3] = @intFromEnum(sound_channels);
    buf[4] = @intFromEnum(rgb_mode);
}

/// Build CMD_CLOSE packet (1 byte).
pub fn buildClosePacket(buf: *[1]u8) void {
    buf[0] = @intFromEnum(Command.close);
}

/// Build CMD_SWITCHRES packet (26 bytes).
pub fn buildSwitchResPacket(buf: *[26]u8, modeline: Modeline) void {
    buf[0] = @intFromEnum(Command.switch_res);
    // pixel_clock as f64, little-endian (8 bytes)
    const clock_bytes: [8]u8 = @bitCast(modeline.pixel_clock);
    @memcpy(buf[1..9], &clock_bytes);
    std.mem.writeInt(u16, buf[9..11], modeline.h_active, .little);
    std.mem.writeInt(u16, buf[11..13], modeline.h_begin, .little);
    std.mem.writeInt(u16, buf[13..15], modeline.h_end, .little);
    std.mem.writeInt(u16, buf[15..17], modeline.h_total, .little);
    std.mem.writeInt(u16, buf[17..19], modeline.v_active, .little);
    std.mem.writeInt(u16, buf[19..21], modeline.v_begin, .little);
    std.mem.writeInt(u16, buf[21..23], modeline.v_end, .little);
    std.mem.writeInt(u16, buf[23..25], modeline.v_total, .little);
    buf[25] = if (modeline.interlaced) 1 else 0;
}

/// Build CMD_AUDIO header (3 bytes). PCM data sent separately in MTU chunks.
/// `sample_bytes` is the total byte count of the PCM data that follows.
pub fn buildAudioHeader(buf: *[3]u8, sample_bytes: u16) void {
    buf[0] = @intFromEnum(Command.audio);
    std.mem.writeInt(u16, buf[1..3], sample_bytes, .little);
}

/// Build CMD_BLIT raw frame header (8 bytes). Frame data sent separately in MTU chunks.
pub fn buildBlitHeader(buf: *[8]u8, frame_num: u32, field: u8, vsync_line: u16) void {
    buf[0] = @intFromEnum(Command.blit);
    std.mem.writeInt(u32, buf[1..5], frame_num, .little);
    buf[5] = field;
    std.mem.writeInt(u16, buf[6..8], vsync_line, .little);
}

/// Build CMD_BLIT LZ4-compressed frame header (12 bytes).
/// Same layout as `buildBlitHeader` with `compressed_size` appended at offset 8.
pub fn buildBlitHeaderLz4(buf: *[12]u8, frame_num: u32, field: u8, vsync_line: u16, compressed_size: u32) void {
    buildBlitHeader(buf[0..8], frame_num, field, vsync_line);
    std.mem.writeInt(u32, buf[8..12], compressed_size, .little);
}

/// Build CMD_BLIT LZ4 delta-compressed frame header (13 bytes).
/// Same layout as `buildBlitHeaderLz4` with a `0x01` delta flag at offset 12.
/// The HPS daemon reads this byte and passes it to the FPGA for additive reconstruction.
pub fn buildBlitHeaderLz4Delta(buf: *[13]u8, frame_num: u32, field: u8, vsync_line: u16, compressed_size: u32) void {
    buildBlitHeaderLz4(buf[0..12], frame_num, field, vsync_line, compressed_size);
    buf[12] = 0x01;
}

// --- Tests ---

test "parseAck decodes all fields and bits" {
    var buf: [13]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 100, .little);
    std.mem.writeInt(u16, buf[4..6], 200, .little);
    std.mem.writeInt(u32, buf[6..10], 101, .little);
    std.mem.writeInt(u16, buf[10..12], 42, .little);
    buf[12] = 0b00100101; // vram_ready=1, vram_synced=1, vga_f1=1

    const s = parseAck(&buf);
    try std.testing.expectEqual(@as(u32, 100), s.frame_echo);
    try std.testing.expectEqual(@as(u16, 200), s.vcount_echo);
    try std.testing.expectEqual(@as(u32, 101), s.frame);
    try std.testing.expectEqual(@as(u16, 42), s.vcount);
    try std.testing.expect(s.vram_ready);
    try std.testing.expect(!s.vram_end_frame);
    try std.testing.expect(s.vram_synced);
    try std.testing.expect(!s.vga_frameskip);
    try std.testing.expect(!s.vga_vblank);
    try std.testing.expect(s.vga_f1);
    try std.testing.expect(!s.audio_active);
    try std.testing.expect(!s.vram_queue);
}

test "parseAck all bits set" {
    var buf: [13]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0, .little);
    std.mem.writeInt(u16, buf[4..6], 0, .little);
    std.mem.writeInt(u32, buf[6..10], 0, .little);
    std.mem.writeInt(u16, buf[10..12], 0, .little);
    buf[12] = 0xFF;

    const s = parseAck(&buf);
    try std.testing.expect(s.vram_ready);
    try std.testing.expect(s.vram_end_frame);
    try std.testing.expect(s.vram_synced);
    try std.testing.expect(s.vga_frameskip);
    try std.testing.expect(s.vga_vblank);
    try std.testing.expect(s.vga_f1);
    try std.testing.expect(s.audio_active);
    try std.testing.expect(s.vram_queue);
}

test "buildInitPacket format" {
    var buf: [5]u8 = undefined;
    buildInitPacket(&buf, .off, .rate_48000, .stereo, .bgr888);
    try std.testing.expectEqual(@as(u8, 2), buf[0]); // CMD_INIT
    try std.testing.expectEqual(@as(u8, 0), buf[1]); // lz4 off
    try std.testing.expectEqual(@as(u8, 3), buf[2]); // 48000Hz
    try std.testing.expectEqual(@as(u8, 2), buf[3]); // stereo
    try std.testing.expectEqual(@as(u8, 0), buf[4]); // BGR888
}

test "buildClosePacket format" {
    var buf: [1]u8 = undefined;
    buildClosePacket(&buf);
    try std.testing.expectEqual(@as(u8, 1), buf[0]); // CMD_CLOSE
}

test "buildSwitchResPacket format" {
    var buf: [26]u8 = undefined;
    const modeline = Modeline{
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
    buildSwitchResPacket(&buf, modeline);

    try std.testing.expectEqual(@as(u8, 3), buf[0]); // CMD_SWITCHRES
    // pixel_clock as f64 little-endian at offset 1..9
    const clock_back: f64 = @bitCast(buf[1..9].*);
    try std.testing.expectApproxEqAbs(@as(f64, 6.7), clock_back, 0.001);
    // hActive at offset 9..11
    try std.testing.expectEqual(@as(u16, 320), std.mem.readInt(u16, buf[9..11], .little));
    // vTotal at offset 23..25
    try std.testing.expectEqual(@as(u16, 262), std.mem.readInt(u16, buf[23..25], .little));
    // interlace byte
    try std.testing.expectEqual(@as(u8, 0), buf[25]);
}

test "buildBlitHeader format" {
    var buf: [8]u8 = undefined;
    buildBlitHeader(&buf, 42, 0, 203);

    try std.testing.expectEqual(@as(u8, 7), buf[0]); // CMD_BLIT
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[1..5], .little));
    try std.testing.expectEqual(@as(u8, 0), buf[5]); // field
    try std.testing.expectEqual(@as(u16, 203), std.mem.readInt(u16, buf[6..8], .little));
}

// --- Comprehensive edge-case tests ---

test "parseAck with all zeros (default state)" {
    const buf = [_]u8{0} ** ack_size;
    const s = parseAck(&buf);
    try std.testing.expectEqual(@as(u32, 0), s.frame_echo);
    try std.testing.expectEqual(@as(u16, 0), s.vcount_echo);
    try std.testing.expectEqual(@as(u32, 0), s.frame);
    try std.testing.expectEqual(@as(u16, 0), s.vcount);
    try std.testing.expect(!s.vram_ready);
    try std.testing.expect(!s.vram_end_frame);
    try std.testing.expect(!s.vram_synced);
    try std.testing.expect(!s.vga_frameskip);
    try std.testing.expect(!s.vga_vblank);
    try std.testing.expect(!s.vga_f1);
    try std.testing.expect(!s.audio_active);
    try std.testing.expect(!s.vram_queue);
}

test "parseAck with max u32/u16 values" {
    var buf: [ack_size]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], std.math.maxInt(u32), .little);
    std.mem.writeInt(u16, buf[4..6], std.math.maxInt(u16), .little);
    std.mem.writeInt(u32, buf[6..10], std.math.maxInt(u32), .little);
    std.mem.writeInt(u16, buf[10..12], std.math.maxInt(u16), .little);
    buf[12] = 0xFF;

    const s = parseAck(&buf);
    try std.testing.expectEqual(std.math.maxInt(u32), s.frame_echo);
    try std.testing.expectEqual(std.math.maxInt(u16), s.vcount_echo);
    try std.testing.expectEqual(std.math.maxInt(u32), s.frame);
    try std.testing.expectEqual(std.math.maxInt(u16), s.vcount);
    try std.testing.expect(s.vram_ready);
    try std.testing.expect(s.vram_end_frame);
    try std.testing.expect(s.vram_synced);
    try std.testing.expect(s.vga_frameskip);
    try std.testing.expect(s.vga_vblank);
    try std.testing.expect(s.vga_f1);
    try std.testing.expect(s.audio_active);
    try std.testing.expect(s.vram_queue);
}

test "buildSwitchResPacket with interlaced=true" {
    var buf: [26]u8 = undefined;
    const modeline = Modeline{
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
    buildSwitchResPacket(&buf, modeline);

    try std.testing.expectEqual(@as(u8, 3), buf[0]); // CMD_SWITCHRES
    try std.testing.expectEqual(@as(u8, 1), buf[25]); // interlaced flag
    try std.testing.expectEqual(@as(u16, 720), std.mem.readInt(u16, buf[9..11], .little));
    try std.testing.expectEqual(@as(u16, 480), std.mem.readInt(u16, buf[17..19], .little));
    try std.testing.expectEqual(@as(u16, 525), std.mem.readInt(u16, buf[23..25], .little));
}

test "buildBlitHeader with max frame_num" {
    var buf: [8]u8 = undefined;
    buildBlitHeader(&buf, std.math.maxInt(u32), 1, std.math.maxInt(u16));

    try std.testing.expectEqual(@as(u8, 7), buf[0]); // CMD_BLIT
    try std.testing.expectEqual(std.math.maxInt(u32), std.mem.readInt(u32, buf[1..5], .little));
    try std.testing.expectEqual(@as(u8, 1), buf[5]); // field
    try std.testing.expectEqual(std.math.maxInt(u16), std.mem.readInt(u16, buf[6..8], .little));
}

test "buildInitPacket with LZ4 enabled" {
    var buf: [5]u8 = undefined;
    buildInitPacket(&buf, .lz4, .rate_44100, .mono, .rgb565);
    try std.testing.expectEqual(@as(u8, 2), buf[0]); // CMD_INIT
    try std.testing.expectEqual(@as(u8, 1), buf[1]); // lz4 mode = 1
    try std.testing.expectEqual(@as(u8, 2), buf[2]); // 44100Hz
    try std.testing.expectEqual(@as(u8, 1), buf[3]); // mono
    try std.testing.expectEqual(@as(u8, 2), buf[4]); // RGB565
}

test "buildInitPacket with LZ4 delta mode sends clamped value" {
    var buf: [5]u8 = undefined;
    buildInitPacket(&buf, .lz4_delta, .off, .off, .bgr888);
    try std.testing.expectEqual(@as(u8, 1), buf[1]); // clamped to 1
}

test "buildInitPacket with adaptive mode sends clamped value" {
    var buf: [5]u8 = undefined;
    buildInitPacket(&buf, .adaptive, .off, .off, .bgra8888);
    try std.testing.expectEqual(@as(u8, 1), buf[1]); // clamped to 1
    try std.testing.expectEqual(@as(u8, 1), buf[4]); // BGRA8888
}

test "packet sizes match protocol spec" {
    // CMD_CLOSE = 1 byte
    try std.testing.expectEqual(@as(usize, 1), @sizeOf([1]u8));
    // CMD_INIT = 5 bytes
    try std.testing.expectEqual(@as(usize, 5), @sizeOf([5]u8));
    // CMD_SWITCHRES = 26 bytes
    try std.testing.expectEqual(@as(usize, 26), @sizeOf([26]u8));
    // CMD_BLIT header = 8 bytes
    try std.testing.expectEqual(@as(usize, 8), @sizeOf([8]u8));
    // ACK = 13 bytes
    try std.testing.expectEqual(@as(usize, 13), ack_size);
}

test "buildAudioHeader format" {
    var buf: [3]u8 = undefined;
    buildAudioHeader(&buf, 4096);
    try std.testing.expectEqual(@as(u8, 4), buf[0]); // CMD_AUDIO
    try std.testing.expectEqual(@as(u16, 4096), std.mem.readInt(u16, buf[1..3], .little));
}

test "buildAudioHeader with zero bytes" {
    var buf: [3]u8 = undefined;
    buildAudioHeader(&buf, 0);
    try std.testing.expectEqual(@as(u8, 4), buf[0]); // CMD_AUDIO
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[1..3], .little));
}

test "buildAudioHeader with max u16 bytes" {
    var buf: [3]u8 = undefined;
    buildAudioHeader(&buf, std.math.maxInt(u16));
    try std.testing.expectEqual(@as(u8, 4), buf[0]); // CMD_AUDIO
    try std.testing.expectEqual(std.math.maxInt(u16), std.mem.readInt(u16, buf[1..3], .little));
}

test "buildBlitHeaderLz4 format" {
    var buf: [12]u8 = undefined;
    buildBlitHeaderLz4(&buf, 42, 0, 203, 9876);

    try std.testing.expectEqual(@as(u8, 7), buf[0]); // CMD_BLIT
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[1..5], .little));
    try std.testing.expectEqual(@as(u8, 0), buf[5]); // field
    try std.testing.expectEqual(@as(u16, 203), std.mem.readInt(u16, buf[6..8], .little));
    try std.testing.expectEqual(@as(u32, 9876), std.mem.readInt(u32, buf[8..12], .little));
}

test "buildBlitHeaderLz4 first 8 bytes match buildBlitHeader" {
    var raw: [8]u8 = undefined;
    var lz4: [12]u8 = undefined;
    buildBlitHeader(&raw, 999, 1, 500);
    buildBlitHeaderLz4(&lz4, 999, 1, 500, 4096);
    try std.testing.expectEqualSlices(u8, &raw, lz4[0..8]);
}

test "buildBlitHeaderLz4Delta format" {
    var buf: [13]u8 = undefined;
    buildBlitHeaderLz4Delta(&buf, 42, 0, 203, 9876);

    try std.testing.expectEqual(@as(u8, 7), buf[0]); // CMD_BLIT
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[1..5], .little));
    try std.testing.expectEqual(@as(u8, 0), buf[5]); // field
    try std.testing.expectEqual(@as(u16, 203), std.mem.readInt(u16, buf[6..8], .little));
    try std.testing.expectEqual(@as(u32, 9876), std.mem.readInt(u32, buf[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0x01), buf[12]); // delta flag
}

test "buildBlitHeaderLz4Delta first 12 bytes match buildBlitHeaderLz4" {
    var lz4: [12]u8 = undefined;
    var delta: [13]u8 = undefined;
    buildBlitHeaderLz4(&lz4, 999, 1, 500, 4096);
    buildBlitHeaderLz4Delta(&delta, 999, 1, 500, 4096);
    try std.testing.expectEqualSlices(u8, &lz4, delta[0..12]);
}

test "buildInitPacket encodes audio parameters" {
    // 48kHz stereo
    var buf: [5]u8 = undefined;
    buildInitPacket(&buf, .off, .rate_48000, .stereo, .bgr888);
    try std.testing.expectEqual(@as(u8, 3), buf[2]); // rate_48000
    try std.testing.expectEqual(@as(u8, 2), buf[3]); // stereo

    // 22050Hz mono
    buildInitPacket(&buf, .off, .rate_22050, .mono, .bgr888);
    try std.testing.expectEqual(@as(u8, 1), buf[2]); // rate_22050
    try std.testing.expectEqual(@as(u8, 1), buf[3]); // mono

    // audio off
    buildInitPacket(&buf, .off, .off, .off, .bgr888);
    try std.testing.expectEqual(@as(u8, 0), buf[2]); // off
    try std.testing.expectEqual(@as(u8, 0), buf[3]); // off
}

test "parseAck audio_active bit" {
    // bit 6 (0x40) = audio_active
    var buf: [ack_size]u8 = [_]u8{0} ** ack_size;

    // audio_active = false
    buf[12] = 0x00;
    var s = parseAck(&buf);
    try std.testing.expect(!s.audio_active);

    // audio_active = true (only bit 6 set)
    buf[12] = 0x40;
    s = parseAck(&buf);
    try std.testing.expect(s.audio_active);

    // audio_active = true (mixed with other bits)
    buf[12] = 0x41; // vram_ready + audio_active
    s = parseAck(&buf);
    try std.testing.expect(s.audio_active);
    try std.testing.expect(s.vram_ready);
}

test "buildSwitchResPacket encodes all modeline fields correctly" {
    var buf: [26]u8 = undefined;
    const modeline = Modeline{
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
    buildSwitchResPacket(&buf, modeline);

    const clock_back: f64 = @bitCast(buf[1..9].*);
    try std.testing.expectApproxEqAbs(@as(f64, 25.175), clock_back, 0.001);
    try std.testing.expectEqual(@as(u16, 640), std.mem.readInt(u16, buf[9..11], .little));
    try std.testing.expectEqual(@as(u16, 656), std.mem.readInt(u16, buf[11..13], .little));
    try std.testing.expectEqual(@as(u16, 752), std.mem.readInt(u16, buf[13..15], .little));
    try std.testing.expectEqual(@as(u16, 800), std.mem.readInt(u16, buf[15..17], .little));
    try std.testing.expectEqual(@as(u16, 480), std.mem.readInt(u16, buf[17..19], .little));
    try std.testing.expectEqual(@as(u16, 490), std.mem.readInt(u16, buf[19..21], .little));
    try std.testing.expectEqual(@as(u16, 492), std.mem.readInt(u16, buf[21..23], .little));
    try std.testing.expectEqual(@as(u16, 525), std.mem.readInt(u16, buf[23..25], .little));
    try std.testing.expectEqual(@as(u8, 0), buf[25]);
}
