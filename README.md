# GroovyMisterZig

Zig implementation of the [Groovy_MiSTer](https://github.com/psakhis/Groovy_MiSTer) UDP streaming protocol by [@psakhis](https://github.com/psakhis). Zero-allocation packet building, non-blocking I/O, and a C ABI for integration from Swift, C, C++, or any language with C FFI.

- **Video + audio streaming** to MiSTer FPGA over UDP
- **Input reception** — joystick, PS/2 keyboard, and mouse state from the FPGA
- **Frame sync primitives** — raster offset, vsync line computation, caller-driven timing
- **Library-owned frame pacing** — drift-corrected `gmz_begin_frame` with backpressure handling
- **LZ4 + delta compression** — 50-80% bandwidth reduction for slowly-changing content

## Build

Requires [Zig](https://ziglang.org/) 0.15.2+.

```bash
zig build          # native static + shared library
zig build test     # run unit tests
zig build docs     # generate documentation
zig build cross    # cross-compile for all targets
```

### Cross-Compilation

`zig build cross` produces static and shared libraries for all supported targets:

```
zig-out/lib/x86_64-linux/lib/libgroovy-mister.a      + .so
zig-out/lib/x86_64-macos/lib/libgroovy-mister.a      + .dylib
zig-out/lib/x86_64-windows/lib/libgroovy-mister.a    + .dll
zig-out/lib/aarch64-linux/lib/libgroovy-mister.a     + .so
```

## Overview

The library manages two independent UDP channels to the MiSTer FPGA:

**Video/audio (port 32100)** — PC sends frames to the FPGA. Connect, set a modeline (display timing), then submit frames in a loop. The FPGA sends ACKs back with status (current scanline, VRAM readiness, frame counters) which drive your sync decisions.

**Input (port 32101)** — FPGA sends joystick, keyboard, and mouse state to the PC. Optional — many users only stream video. Send a 1-byte hello to start receiving, then poll for packets. Input has its own handle with an independent lifecycle.

For timing, you have two options. **`gmz_begin_frame`** handles the entire pacing loop for you — drift correction, backpressure, interlaced phase alignment, precision sleep — so you never have to implement timing math. Or use the **low-level primitives** (`gmz_calc_vsync`, `gmz_raster_offset_ns`, `gmz_frame_time_ns`) and own the sync loop yourself.

## Usage

### Video Streaming

The basic flow: connect → set modeline → submit frames. Use `gmz_begin_frame` for automatic pacing, or `gmz_tick` + manual timing for full control.

**C / C++ — with library pacing (recommended)**

```c
#include "groovy_mister.h"

gmz_conn_t conn = gmz_connect_ex("192.168.1.123", 1470, 0, 3, 2, GMZ_LZ4_DELTA);
gmz_modeline_t m = {
    .pixel_clock = 6.7,
    .h_active = 320, .h_begin = 336, .h_end = 368, .h_total = 426,
    .v_active = 240, .v_begin = 244, .v_end = 247, .v_total = 262,
};
gmz_set_modeline(conn, &m);

// Frame loop — gmz_begin_frame handles sync, drift, sleep, backpressure
int result;
while ((result = gmz_begin_frame(conn)) != GMZ_PACE_STALLED) {
    if (result == GMZ_PACE_SKIP) continue;  // VRAM full, skip this frame
    // process + render frame
    gmz_submit(conn, data, len, frame++, 0, 0, 0.0);
}
// stalled — reconnect

gmz_disconnect(conn);
```

**Swift — with library pacing**

```swift
import GroovyMisterZig

guard let conn = gmz_connect_ex("192.168.1.123", 1470, 0, 3, 2,
                                 UInt8(GMZ_LZ4_DELTA)) else {
    fatalError("Failed to connect to FPGA")
}
defer { gmz_disconnect(conn) }

var modeline = gmz_modeline_t()
modeline.pixel_clock = 6.7
modeline.h_active = 320; modeline.h_begin = 336
modeline.h_end = 368;    modeline.h_total = 426
modeline.v_active = 240; modeline.v_begin = 244
modeline.v_end = 247;    modeline.v_total = 262
gmz_set_modeline(conn, &modeline)

// Frame loop
while gmz_begin_frame(conn) == GMZ_PACE_READY {
    frameData.withUnsafeBytes { buf in
        gmz_submit(conn, buf.baseAddress!, buf.count, frameNum, 0, 0, 0)
    }
    frameNum += 1
}
// stalled — reconnect
```

**C / C++ — manual timing (full control)**

```c
// Frame loop — caller owns timing
while (running) {
    gmz_state_t state = gmz_tick(conn);
    if (state.vram_ready) {
        uint16_t vsync = gmz_calc_vsync(conn, 2000000, emulation_ns, stream_ns);
        gmz_submit(conn, data, len, frame, 0, vsync, 0.0);
    }
}
```

**Zig**

```zig
const gmz = @import("groovy_mister");

var conn = try gmz.Connection.open(.{
    .host = "192.168.1.123",
    .mtu = 1470,
    .rgb_mode = .bgr888,
    .sound_rate = .rate_48000,
    .sound_channels = .stereo,
    .lz4_mode = .lz4_delta,
    .compressor = gmz.delta.compressor(&delta_state, compress_buf),
});
defer conn.close();

try conn.switchRes(.{
    .pixel_clock = 6.7,
    .h_active = 320, .h_begin = 336, .h_end = 368, .h_total = 426,
    .v_active = 240, .v_begin = 244, .v_end = 247, .v_total = 262,
    .interlaced = false,
});

// Frame loop
conn.poll();
const status = conn.fpgaStatus();
if (status.vram_ready) {
    try conn.sendFrame(frame_data, .{ .frame_num = frame, .vsync_line = vsync });
}
```

### Frame Sync

**`gmz_begin_frame`** (recommended) handles the entire pacing loop: it syncs with the FPGA via CMD_GET_STATUS, computes a drift-corrected frame period, applies interlaced phase correction, sleeps with 2ms spin-wait precision, and handles backpressure (VRAM full) and stall detection. The drift controller targets 3 frames ahead of the FPGA and converges in ~1s with gain=0.02.

For manual control, the library also exposes pure timing primitives:

```c
uint64_t frame_ns = gmz_frame_time_ns(conn);
uint16_t vsync = gmz_calc_vsync(conn, 2000000, emulation_ns, stream_ns);
int32_t offset_ns = gmz_raster_offset_ns(conn, frame);
```

`gmz_calc_vsync` accounts for network latency, emulation time, and streaming time to place the vsync line so the frame arrives just before the CRT beam reaches it. `gmz_raster_offset_ns` tells you how far off you were — positive means the FPGA is behind (you have headroom), negative means you're late.

### Input

Input is optional and runs on a separate UDP port (32101) with its own handle. The FPGA reads locally-connected USB joysticks, keyboards, and mice, then streams their state to the PC.

**C / C++**

```c
gmz_input_t input = gmz_input_bind("192.168.1.123");

// In your frame loop:
gmz_input_poll(input);

gmz_joy_state_t joy = gmz_input_joy(input);
if (joy.joy1 & GMZ_JOY_B1) { /* player 1 pressed button 1 */ }

gmz_ps2_state_t ps2 = gmz_input_ps2(input);
// Check SDL scancode 4 (key 'A'):
if (ps2.keys[4 / 8] & (1 << (4 % 8))) { /* A is pressed */ }

gmz_input_close(input);
```

**Swift**

```swift
import GroovyMisterZig

guard let input = gmz_input_bind("192.168.1.123") else {
    fatalError("Failed to bind input")
}
defer { gmz_input_close(input) }

gmz_input_poll(input)

let joy = gmz_input_joy(input)
if joy.joy1 & UInt16(GMZ_JOY_B1) != 0 { /* player 1 pressed button 1 */ }
if joy.j1_lx < -64 { /* left stick pushed left */ }

let ps2 = gmz_input_ps2(input)
let scancode: UInt8 = 4  // SDL scancode for 'A'
if ps2.keys[Int(scancode / 8)] & (1 << (scancode % 8)) != 0 { /* A pressed */ }
```

**Zig**

```zig
const gmz = @import("groovy_mister");
const Input = gmz.Input;

var input = try Input.bind("192.168.1.123");
defer input.close();

if (input.poll()) {
    const joy = input.joyState();
    if (joy.joy1 & Input.JoyButton.b1 != 0) { /* player 1 pressed button 1 */ }
    if (joy.j1_lx < -64) { /* left stick pushed left */ }

    const ps2 = input.ps2State();
    if (Input.isKeyPressed(&ps2.keys, 4)) { /* SDL scancode 4 = 'A' */ }
}
```

### Compression

Pass an `LZ4` mode to `gmz_connect_ex` (C/Swift) or set `.lz4_mode` on `Connection.Config` (Zig). Delta modes XOR successive frames before compressing, which is very effective for slowly-changing content (menus, pixel art, retro games).

| Mode | Description |
|------|-------------|
| `GMZ_LZ4` | LZ4 block compression |
| `GMZ_LZ4_DELTA` | LZ4 + delta frame encoding (XOR) |
| `GMZ_LZ4_HC` | LZ4 high-compression (slower, smaller) |
| `GMZ_LZ4_HC_DELTA` | LZ4 HC + delta |
| `GMZ_LZ4_ADAPTIVE` | Adaptive (switches between fast/HC per frame) |
| `GMZ_LZ4_ADAPTIVE_DELTA` | Adaptive + delta |

### Linking

**C / C++**: Link with `-lgroovy-mister` and add `include/` to your header search path.

**Swift / Xcode**: The `include/module.modulemap` enables `import GroovyMisterZig`:
- `LIBRARY_SEARCH_PATHS = $(SRCROOT)/GroovyMisterZig/zig-out/lib`
- `SWIFT_INCLUDE_PATHS = $(SRCROOT)/GroovyMisterZig/include`
- `OTHER_LDFLAGS = -lgroovy-mister`

**Zig**: `const gmz = @import("groovy_mister");`

## Architecture

```
src/
  root.zig        -- library root, re-exports public API
  protocol.zig    -- UDP protocol: commands, packet builders, ACK parsing
  Connection.zig  -- non-blocking UDP socket, frame chunking, poll()-based sync
  Input.zig       -- FPGA input reception: joystick/keyboard/mouse (UDP 32101)
  Health.zig      -- 128-sample rolling window for sync/VRAM metrics
  lz4.zig         -- LZ4 block compression wrapper
  delta.zig       -- delta frame encoding: XOR successive frames + LZ4
  version.zig     -- library version from build.zig.zon
  sync.zig        -- CRT sync primitives: frame timing, raster offset, vsync
  pacer.zig       -- frame pacer: drift correction, phase alignment, precision sleep
  c_api.zig       -- C ABI function exports

include/
  groovy_mister.h    -- C header
  module.modulemap   -- Clang module map for Swift
```

## API Reference

### Functions

| Function | Description |
|----------|-------------|
| **Connection** | |
| `gmz_connect` | Connect to FPGA, send CMD_INIT. Returns opaque handle. |
| `gmz_connect_ex` | Connect with LZ4/delta compression. Pass `GMZ_LZ4_*` mode. |
| `gmz_disconnect` | Send CMD_CLOSE and free the connection. |
| **Streaming** | |
| `gmz_tick` | Poll for ACKs, return combined FPGA status + health. |
| `gmz_set_modeline` | Send CMD_SWITCHRES with display timing parameters. |
| `gmz_submit` | Send a video frame to the FPGA. |
| `gmz_submit_audio` | Send raw 16-bit PCM audio to the FPGA. |
| `gmz_wait_sync` | Block until FPGA ACK or timeout. |
| `gmz_begin_frame` | Block until time to submit next frame (drift-corrected pacing). |
| **Frame sync** | |
| `gmz_frame_time_ns` | Get frame period in nanoseconds from modeline. |
| `gmz_raster_offset_ns` | Get raster time offset (ns) for frame pacing. |
| `gmz_calc_vsync` | Compute optimal vsync scanline for next submission. |
| **Input** | |
| `gmz_input_bind` | Connect to FPGA input stream (UDP 32101). Returns handle. |
| `gmz_input_close` | Close input connection and free handle. |
| `gmz_input_poll` | Poll for pending input packets. Returns 1 if new data. |
| `gmz_input_joy` | Read latest joystick state (digital + analog). |
| `gmz_input_ps2` | Read latest PS/2 keyboard + mouse state. |
| **Version** | |
| `gmz_version` | Return library version string (e.g. `"0.1.0"`). |
| `gmz_version_major` | Return major version number. |
| `gmz_version_minor` | Return minor version number. |
| `gmz_version_patch` | Return patch version number. |

### Types

- `gmz_conn_t` -- Opaque connection handle
- `gmz_input_t` -- Opaque input handle (joystick/keyboard/mouse)
- `gmz_modeline_t` -- Display timing parameters (pixel clock, h/v active/blank/sync/total, interlace)
- `gmz_state_t` -- Combined FPGA status + health metrics (frame counters, VRAM state, sync stats)
- `gmz_joy_state_t` -- Joystick state (digital buttons + analog axes)
- `gmz_ps2_state_t` -- PS/2 keyboard + mouse state (256-bit scancode bitfield + raw mouse)

### Joystick Button Constants

| Constant | Value | | Constant | Value |
|----------|-------|-|----------|-------|
| `GMZ_JOY_RIGHT` | 0x0001 | | `GMZ_JOY_B1` | 0x0010 |
| `GMZ_JOY_LEFT` | 0x0002 | | `GMZ_JOY_B2` | 0x0020 |
| `GMZ_JOY_DOWN` | 0x0004 | | `GMZ_JOY_B3`–`GMZ_JOY_B6` | 0x0040–0x0200 |
| `GMZ_JOY_UP` | 0x0008 | | `GMZ_JOY_B7`–`GMZ_JOY_B10` | 0x0400–0x2000 |

## License

GPL-2.0. See [LICENSE](LICENSE).
