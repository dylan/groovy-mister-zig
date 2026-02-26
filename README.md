# GroovyMisterZig

Zig implementation of the [Groovy_MiSTer](https://github.com/psakhis/Groovy_MiSTer) UDP streaming protocol by [@psakhis](https://github.com/psakhis). With a focus on zero-allocation packet building, non-blocking I/O, and a clean C ABI for integration from Swift, C, C++, or any language with C FFI.

## Requirements

- [Zig](https://ziglang.org/) 0.15.2+

## Build

```bash
zig build          # produces zig-out/lib/libgroovy-mister.a (static)
zig build test     # run unit tests
zig build docs     # generate documentation
```

## C API

The library exposes a C API via `include/groovy_mister.h`:

| Function | Description |
|----------|-------------|
| `gmz_connect` | Connect to FPGA, send CMD_INIT. Returns opaque handle. |
| `gmz_connect_ex` | Connect with LZ4/delta compression. Pass `GMZ_LZ4_*` mode. |
| `gmz_disconnect` | Send CMD_CLOSE and free the connection. |
| `gmz_tick` | Poll for ACKs, return combined FPGA status + health. |
| `gmz_set_modeline` | Send CMD_SWITCHRES with display timing parameters. |
| `gmz_submit` | Send a video frame to the FPGA. |
| `gmz_submit_audio` | Send raw 16-bit PCM audio to the FPGA. |
| `gmz_wait_sync` | Block until FPGA ACK or timeout. |
| `gmz_version` | Return library version string (e.g. `"0.1.0"`). |
| `gmz_version_major` | Return library major version number. |
| `gmz_version_minor` | Return library minor version number. |
| `gmz_raster_offset_ns` | Get raster time offset (ns) for frame pacing. |
| `gmz_calc_vsync` | Compute optimal vsync scanline for next submission. |
| `gmz_frame_time_ns` | Get frame period in nanoseconds from modeline. |
| `gmz_version_patch` | Return library patch version number. |

### Types

- `gmz_conn_t` -- Opaque connection handle
- `gmz_modeline_t` -- Display timing parameters (pixel clock, h/v active/blank/sync/total, interlace)
- `gmz_state_t` -- Combined FPGA status + health metrics (frame counters, VRAM state, sync stats)

### LZ4 Mode Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `GMZ_LZ4_OFF` | 0 | No compression |
| `GMZ_LZ4` | 1 | LZ4 block compression |
| `GMZ_LZ4_DELTA` | 2 | LZ4 + delta frame encoding (XOR) |
| `GMZ_LZ4_HC` | 3 | LZ4 high-compression |
| `GMZ_LZ4_HC_DELTA` | 4 | LZ4 HC + delta |
| `GMZ_LZ4_ADAPTIVE` | 5 | Adaptive LZ4 |
| `GMZ_LZ4_ADAPTIVE_DELTA` | 6 | Adaptive LZ4 + delta |

## Usage

### C / C++

```c
#include "groovy_mister.h"

// Basic connection (no compression)
gmz_conn_t conn = gmz_connect("192.168.1.123", 1470, 0, 3, 2);

// With delta frame encoding (50-80% bandwidth reduction)
gmz_conn_t conn_delta = gmz_connect_ex("192.168.1.123", 1470, 0, 3, 2, GMZ_LZ4_DELTA);

// Query library version
printf("GroovyMisterZig v%s\n", gmz_version());

// ... set modeline, submit frames ...
gmz_disconnect(conn);
```

Link with `-lgroovy-mister` and add the `include/` directory to your header search path.

### Swift (via module map)

The `include/module.modulemap` enables direct import:

```swift
import GroovyMisterZig

// Basic connection
let conn = gmz_connect("192.168.1.123", 1470, 0, 3, 2)

// With delta frame encoding
let conn_delta = gmz_connect_ex("192.168.1.123", 1470, 0, 3, 2, UInt8(GMZ_LZ4_DELTA))

// Query library version
let version = String(cString: gmz_version())

// ... set modeline, submit frames ...
gmz_disconnect(conn)
```

Xcode build settings:
- `LIBRARY_SEARCH_PATHS = $(SRCROOT)/GroovyMisterZig/zig-out/lib`
- `SWIFT_INCLUDE_PATHS = $(SRCROOT)/GroovyMisterZig/include`
- `OTHER_LDFLAGS = -lgroovy-mister`

### Zig

```zig
const gmz = @import("groovy_mister");
```

## Architecture

```
src/
  root.zig        -- library root, re-exports public API
  protocol.zig    -- UDP protocol: commands, packet builders, ACK parsing
  Connection.zig  -- non-blocking UDP socket, frame chunking, poll()-based sync
  Health.zig      -- 128-sample rolling window for sync/VRAM metrics
  lz4.zig         -- LZ4 block compression wrapper
  delta.zig       -- delta frame encoding: XOR successive frames + LZ4
  version.zig     -- library version from build.zig.zon
  c_api.zig       -- C ABI function exports

include/
  groovy_mister.h    -- C header
  module.modulemap   -- Clang module map for Swift
```

## TODO

- [x] **LZ4 compression** — Wired up via `gmz_connect_ex()` with `GMZ_LZ4` mode.
- [ ] **Input support** — Joystick/PS2 keyboard/mouse feedback from FPGA (second UDP socket). Required for interactive applications.
- [x] **Precise CRT sync** — Pure timing primitives: `gmz_frame_time_ns()`, `gmz_raster_offset_ns()`, `gmz_calc_vsync()`. Caller-driven sync loop.
- [x] **Delta frame encoding** — XOR successive frames + LZ4 compression. 50-80% bandwidth reduction for slowly-changing content. Use `GMZ_LZ4_DELTA` mode.
- [x] **Library version** — `gmz_version()` returns the version string; `gmz_version_major/minor/patch()` for programmatic access.

### Frame Sync

The library exposes pure timing primitives — the caller owns the sync loop:

```c
// After setting a modeline:
uint64_t frame_ns = gmz_frame_time_ns(conn);

// Each frame:
// 1. Emulate frame, measure emulation_ns
// 2. Compute optimal vsync line (2ms margin)
uint16_t vsync = gmz_calc_vsync(conn, 2000000, emulation_ns, stream_ns);
// 3. Submit frame at the computed vsync line
gmz_submit(conn, data, len, frame, 0, vsync, 0.0);
// 4. Caller sleeps/yields for remaining frame budget
// 5. Optionally read raster offset to fine-tune timing:
int32_t offset_ns = gmz_raster_offset_ns(conn, frame);
```

## License

GPL-2.0. See [LICENSE](LICENSE).
