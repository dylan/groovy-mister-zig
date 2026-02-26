const std = @import("std");
const posix = std.posix;

const Input = @This();

// --- Types ---

/// Joystick button bitmask constants (matches MiSTer firmware).
pub const JoyButton = struct {
    pub const right: u16 = 0x0001;
    pub const left: u16 = 0x0002;
    pub const down: u16 = 0x0004;
    pub const up: u16 = 0x0008;
    pub const b1: u16 = 0x0010;
    pub const b2: u16 = 0x0020;
    pub const b3: u16 = 0x0040;
    pub const b4: u16 = 0x0080;
    pub const b5: u16 = 0x0100;
    pub const b6: u16 = 0x0200;
    pub const b7: u16 = 0x0400;
    pub const b8: u16 = 0x0800;
    pub const b9: u16 = 0x1000;
    pub const b10: u16 = 0x2000;
};

/// Latest joystick state from FPGA.
pub const JoystickState = struct {
    frame: u32 = 0,
    order: u8 = 0,
    joy1: u16 = 0,
    joy2: u16 = 0,
    j1_lx: i8 = 0,
    j1_ly: i8 = 0,
    j1_rx: i8 = 0,
    j1_ry: i8 = 0,
    j2_lx: i8 = 0,
    j2_ly: i8 = 0,
    j2_rx: i8 = 0,
    j2_ry: i8 = 0,
};

/// Latest PS/2 keyboard + mouse state from FPGA.
pub const Ps2State = struct {
    frame: u32 = 0,
    order: u8 = 0,
    keys: [32]u8 = .{0} ** 32,
    mouse_btns: u8 = 0,
    mouse_x: u8 = 0,
    mouse_y: u8 = 0,
    mouse_z: u8 = 0,
};

/// Errors that can occur during input socket operations.
pub const Error = error{
    SocketCreateFailed,
    ResolveFailed,
    SendFailed,
};

// --- State ---

sock: posix.socket_t,
recv_buf: [64]u8 = undefined,
joy: JoystickState = .{},
ps2: Ps2State = .{},

// --- Pure parsing functions ---

/// Parse a 9-byte digital joystick packet.
/// Layout: frame:u32 order:u8 joy1:u16 joy2:u16 (all LE).
pub fn parseJoyDigital(buf: *const [9]u8) JoystickState {
    return .{
        .frame = std.mem.readInt(u32, buf[0..4], .little),
        .order = buf[4],
        .joy1 = std.mem.readInt(u16, buf[5..7], .little),
        .joy2 = std.mem.readInt(u16, buf[7..9], .little),
    };
}

/// Parse a 17-byte analog joystick packet.
/// Layout: frame:u32 order:u8 joy1:u16 joy2:u16 + 8 axis bytes (i8).
pub fn parseJoyAnalog(buf: *const [17]u8) JoystickState {
    return .{
        .frame = std.mem.readInt(u32, buf[0..4], .little),
        .order = buf[4],
        .joy1 = std.mem.readInt(u16, buf[5..7], .little),
        .joy2 = std.mem.readInt(u16, buf[7..9], .little),
        .j1_lx = @bitCast(buf[9]),
        .j1_ly = @bitCast(buf[10]),
        .j1_rx = @bitCast(buf[11]),
        .j1_ry = @bitCast(buf[12]),
        .j2_lx = @bitCast(buf[13]),
        .j2_ly = @bitCast(buf[14]),
        .j2_rx = @bitCast(buf[15]),
        .j2_ry = @bitCast(buf[16]),
    };
}

/// Parse a 37-byte PS/2 keyboard packet.
/// Layout: frame:u32 order:u8 keys:[32]u8 (SDL scancode bitfield).
pub fn parsePs2Keyboard(buf: *const [37]u8) Ps2State {
    return .{
        .frame = std.mem.readInt(u32, buf[0..4], .little),
        .order = buf[4],
        .keys = buf[5..37].*,
    };
}

/// Parse a 41-byte PS/2 keyboard + mouse packet.
/// Layout: frame:u32 order:u8 keys:[32]u8 mouse_btns:u8 mouse_x:u8 mouse_y:u8 mouse_z:u8.
pub fn parsePs2Mouse(buf: *const [41]u8) Ps2State {
    return .{
        .frame = std.mem.readInt(u32, buf[0..4], .little),
        .order = buf[4],
        .keys = buf[5..37].*,
        .mouse_btns = buf[37],
        .mouse_x = buf[38],
        .mouse_y = buf[39],
        .mouse_z = buf[40],
    };
}

/// Check if key with given SDL scancode is pressed in the bitfield.
pub fn isKeyPressed(keys: *const [32]u8, scancode: u8) bool {
    return (keys[scancode / 8] >> @intCast(scancode % 8)) & 1 != 0;
}

/// Check if a new packet is newer than stored state (for dedup).
/// Accept if new_frame > stored_frame, or same frame with new_order > stored_order.
pub fn isNewer(stored_frame: u32, stored_order: u8, new_frame: u32, new_order: u8) bool {
    if (new_frame > stored_frame) return true;
    if (new_frame == stored_frame and new_order > stored_order) return true;
    return false;
}

// --- Socket methods ---

/// Create a non-blocking UDP socket and send a 1-byte hello to host:32101.
/// The hello packet registers the client address with the FPGA, which then
/// starts streaming input state back.
pub fn bind(host: []const u8) Error!Input {
    const addr = std.net.Address.parseIp4(host, 32101) catch
        return Error.ResolveFailed;

    const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, posix.IPPROTO.UDP) catch
        return Error.SocketCreateFailed;
    errdefer posix.close(sock);

    // Send 1-byte hello to register with FPGA
    const hello = [_]u8{0};
    _ = posix.sendto(
        sock,
        &hello,
        0,
        &addr.any,
        addr.getOsSockLen(),
    ) catch return Error.SendFailed;

    return .{ .sock = sock };
}

/// Close the input socket.
pub fn close(self: *Input) void {
    posix.close(self.sock);
    self.* = undefined;
}

/// Drain all pending input packets. Returns true if any new data was accepted.
/// Dispatches by packet length and deduplicates by frame+order.
pub fn poll(self: *Input) bool {
    var got_data = false;
    while (true) {
        const n = posix.recvfrom(self.sock, &self.recv_buf, 0, null, null) catch |err| switch (err) {
            error.WouldBlock => return got_data,
            else => return got_data,
        };
        switch (n) {
            9 => {
                const state = parseJoyDigital(self.recv_buf[0..9]);
                if (isNewer(self.joy.frame, self.joy.order, state.frame, state.order)) {
                    self.joy = state;
                    got_data = true;
                }
            },
            17 => {
                const state = parseJoyAnalog(self.recv_buf[0..17]);
                if (isNewer(self.joy.frame, self.joy.order, state.frame, state.order)) {
                    self.joy = state;
                    got_data = true;
                }
            },
            37 => {
                const state = parsePs2Keyboard(self.recv_buf[0..37]);
                if (isNewer(self.ps2.frame, self.ps2.order, state.frame, state.order)) {
                    self.ps2 = state;
                    got_data = true;
                }
            },
            41 => {
                const state = parsePs2Mouse(self.recv_buf[0..41]);
                if (isNewer(self.ps2.frame, self.ps2.order, state.frame, state.order)) {
                    self.ps2 = state;
                    got_data = true;
                }
            },
            else => {}, // Unknown packet size, ignore
        }
    }
}

/// Read the latest joystick state.
pub fn joyState(self: *const Input) JoystickState {
    return self.joy;
}

/// Read the latest PS/2 keyboard + mouse state.
pub fn ps2State(self: *const Input) Ps2State {
    return self.ps2;
}

// --- Tests ---

test "parseJoyDigital with known bytes" {
    // frame=0x04030201, order=5, joy1=0x0201, joy2=0x0403
    const buf = [9]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x01, 0x02, 0x03, 0x04 };
    const s = parseJoyDigital(&buf);
    try std.testing.expectEqual(@as(u32, 0x04030201), s.frame);
    try std.testing.expectEqual(@as(u8, 5), s.order);
    try std.testing.expectEqual(@as(u16, 0x0201), s.joy1);
    try std.testing.expectEqual(@as(u16, 0x0403), s.joy2);
    // Analog axes default to zero for digital packets
    try std.testing.expectEqual(@as(i8, 0), s.j1_lx);
    try std.testing.expectEqual(@as(i8, 0), s.j2_ry);
}

test "parseJoyAnalog with known bytes" {
    var buf: [17]u8 = undefined;
    // frame=100 (LE), order=2, joy1=0x0010 (B1), joy2=0
    std.mem.writeInt(u32, buf[0..4], 100, .little);
    buf[4] = 2;
    std.mem.writeInt(u16, buf[5..7], 0x0010, .little);
    std.mem.writeInt(u16, buf[7..9], 0, .little);
    // Axes: j1_lx=-10, j1_ly=20, j1_rx=-30, j1_ry=40
    //       j2_lx=-50, j2_ly=60, j2_rx=-70, j2_ry=80
    buf[9] = @bitCast(@as(i8, -10));
    buf[10] = @bitCast(@as(i8, 20));
    buf[11] = @bitCast(@as(i8, -30));
    buf[12] = @bitCast(@as(i8, 40));
    buf[13] = @bitCast(@as(i8, -50));
    buf[14] = @bitCast(@as(i8, 60));
    buf[15] = @bitCast(@as(i8, -70));
    buf[16] = @bitCast(@as(i8, 80));

    const s = parseJoyAnalog(&buf);
    try std.testing.expectEqual(@as(u32, 100), s.frame);
    try std.testing.expectEqual(@as(u8, 2), s.order);
    try std.testing.expectEqual(@as(u16, 0x0010), s.joy1);
    try std.testing.expectEqual(@as(u16, 0), s.joy2);
    try std.testing.expectEqual(@as(i8, -10), s.j1_lx);
    try std.testing.expectEqual(@as(i8, 20), s.j1_ly);
    try std.testing.expectEqual(@as(i8, -30), s.j1_rx);
    try std.testing.expectEqual(@as(i8, 40), s.j1_ry);
    try std.testing.expectEqual(@as(i8, -50), s.j2_lx);
    try std.testing.expectEqual(@as(i8, 60), s.j2_ly);
    try std.testing.expectEqual(@as(i8, -70), s.j2_rx);
    try std.testing.expectEqual(@as(i8, 80), s.j2_ry);
}

test "analog first 9 bytes match digital parse for same prefix" {
    var buf: [17]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 42, .little);
    buf[4] = 7;
    std.mem.writeInt(u16, buf[5..7], 0x000F, .little);
    std.mem.writeInt(u16, buf[7..9], 0x00F0, .little);
    @memset(buf[9..17], 0);

    const digital = parseJoyDigital(buf[0..9]);
    const analog = parseJoyAnalog(&buf);
    try std.testing.expectEqual(digital.frame, analog.frame);
    try std.testing.expectEqual(digital.order, analog.order);
    try std.testing.expectEqual(digital.joy1, analog.joy1);
    try std.testing.expectEqual(digital.joy2, analog.joy2);
}

test "parsePs2Keyboard with known bytes" {
    var buf: [37]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 200, .little);
    buf[4] = 3;
    // Set key 4 (bit 4 of byte 0) and key 16 (bit 0 of byte 2)
    @memset(buf[5..37], 0);
    buf[5] = 0x10; // key 4
    buf[7] = 0x01; // key 16

    const s = parsePs2Keyboard(&buf);
    try std.testing.expectEqual(@as(u32, 200), s.frame);
    try std.testing.expectEqual(@as(u8, 3), s.order);
    try std.testing.expectEqual(@as(u8, 0x10), s.keys[0]);
    try std.testing.expectEqual(@as(u8, 0x01), s.keys[2]);
    // Mouse fields default to zero
    try std.testing.expectEqual(@as(u8, 0), s.mouse_btns);
    try std.testing.expectEqual(@as(u8, 0), s.mouse_x);
}

test "parsePs2Mouse with known bytes" {
    var buf: [41]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 300, .little);
    buf[4] = 1;
    @memset(buf[5..37], 0xFF); // all keys pressed
    buf[37] = 0x09; // mouse_btns: left + middle
    buf[38] = 0x80; // mouse_x
    buf[39] = 0x40; // mouse_y
    buf[40] = 0x02; // mouse_z

    const s = parsePs2Mouse(&buf);
    try std.testing.expectEqual(@as(u32, 300), s.frame);
    try std.testing.expectEqual(@as(u8, 1), s.order);
    for (s.keys) |k| try std.testing.expectEqual(@as(u8, 0xFF), k);
    try std.testing.expectEqual(@as(u8, 0x09), s.mouse_btns);
    try std.testing.expectEqual(@as(u8, 0x80), s.mouse_x);
    try std.testing.expectEqual(@as(u8, 0x40), s.mouse_y);
    try std.testing.expectEqual(@as(u8, 0x02), s.mouse_z);
}

test "PS2 mouse first 37 bytes match keyboard parse" {
    var buf: [41]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 500, .little);
    buf[4] = 2;
    @memset(buf[5..37], 0xAA);
    buf[37] = 0xFF;
    buf[38] = 0x10;
    buf[39] = 0x20;
    buf[40] = 0x30;

    const kb = parsePs2Keyboard(buf[0..37]);
    const mouse = parsePs2Mouse(&buf);
    try std.testing.expectEqual(kb.frame, mouse.frame);
    try std.testing.expectEqual(kb.order, mouse.order);
    try std.testing.expectEqualSlices(u8, &kb.keys, &mouse.keys);
}

test "isKeyPressed: scancodes 0, 7, 8, 255" {
    var keys: [32]u8 = .{0} ** 32;
    // No keys pressed
    try std.testing.expect(!isKeyPressed(&keys, 0));
    try std.testing.expect(!isKeyPressed(&keys, 7));
    try std.testing.expect(!isKeyPressed(&keys, 8));
    try std.testing.expect(!isKeyPressed(&keys, 255));

    // Press scancode 0 (bit 0 of byte 0)
    keys[0] = 0x01;
    try std.testing.expect(isKeyPressed(&keys, 0));

    // Press scancode 7 (bit 7 of byte 0)
    keys[0] = 0x80;
    try std.testing.expect(isKeyPressed(&keys, 7));
    try std.testing.expect(!isKeyPressed(&keys, 0));

    // Press scancode 8 (bit 0 of byte 1)
    keys[0] = 0;
    keys[1] = 0x01;
    try std.testing.expect(isKeyPressed(&keys, 8));

    // Press scancode 255 (bit 7 of byte 31)
    keys[1] = 0;
    keys[31] = 0x80;
    try std.testing.expect(isKeyPressed(&keys, 255));
}

test "isKeyPressed: all-zero returns false, all-0xFF returns true" {
    const zeros: [32]u8 = .{0} ** 32;
    try std.testing.expect(!isKeyPressed(&zeros, 0));
    try std.testing.expect(!isKeyPressed(&zeros, 128));

    const ones: [32]u8 = .{0xFF} ** 32;
    try std.testing.expect(isKeyPressed(&ones, 0));
    try std.testing.expect(isKeyPressed(&ones, 128));
    try std.testing.expect(isKeyPressed(&ones, 255));
}

test "isNewer: newer frame accepted" {
    try std.testing.expect(isNewer(10, 0, 11, 0));
}

test "isNewer: same frame higher order accepted" {
    try std.testing.expect(isNewer(10, 0, 10, 1));
}

test "isNewer: same frame same order rejected" {
    try std.testing.expect(!isNewer(10, 5, 10, 5));
}

test "isNewer: older frame rejected" {
    try std.testing.expect(!isNewer(10, 5, 9, 255));
}

test "JoyButton constants match expected bitmask values" {
    try std.testing.expectEqual(@as(u16, 0x0001), JoyButton.right);
    try std.testing.expectEqual(@as(u16, 0x0002), JoyButton.left);
    try std.testing.expectEqual(@as(u16, 0x0004), JoyButton.down);
    try std.testing.expectEqual(@as(u16, 0x0008), JoyButton.up);
    try std.testing.expectEqual(@as(u16, 0x0010), JoyButton.b1);
    try std.testing.expectEqual(@as(u16, 0x0020), JoyButton.b2);
    try std.testing.expectEqual(@as(u16, 0x0040), JoyButton.b3);
    try std.testing.expectEqual(@as(u16, 0x0080), JoyButton.b4);
    try std.testing.expectEqual(@as(u16, 0x0100), JoyButton.b5);
    try std.testing.expectEqual(@as(u16, 0x0200), JoyButton.b6);
    try std.testing.expectEqual(@as(u16, 0x0400), JoyButton.b7);
    try std.testing.expectEqual(@as(u16, 0x0800), JoyButton.b8);
    try std.testing.expectEqual(@as(u16, 0x1000), JoyButton.b9);
    try std.testing.expectEqual(@as(u16, 0x2000), JoyButton.b10);
}

test "bind and close on loopback without crash" {
    var input = try Input.bind("127.0.0.1");
    input.close();
}

test "poll returns false on empty socket" {
    var input = try Input.bind("127.0.0.1");
    defer input.close();
    try std.testing.expect(!input.poll());
}

test "default states are zeroed" {
    var input = try Input.bind("127.0.0.1");
    defer input.close();
    const j = input.joyState();
    try std.testing.expectEqual(@as(u32, 0), j.frame);
    try std.testing.expectEqual(@as(u16, 0), j.joy1);
    try std.testing.expectEqual(@as(i8, 0), j.j1_lx);
    const p = input.ps2State();
    try std.testing.expectEqual(@as(u32, 0), p.frame);
    try std.testing.expectEqual(@as(u8, 0), p.mouse_btns);
    for (p.keys) |k| try std.testing.expectEqual(@as(u8, 0), k);
}

test "invalid host returns ResolveFailed" {
    const result = Input.bind("not.a.valid.ip");
    try std.testing.expectError(Error.ResolveFailed, result);
}
