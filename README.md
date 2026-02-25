# GroovyMisterZig

Zig library for streaming video and audio to a [MiSTer FPGA](https://mister-devel.github.io/MkDocs_MiSTer/) over UDP. Provides a C API suitable for integration from C, C++, Swift, or any language with C FFI.

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
| `gmz_disconnect` | Send CMD_CLOSE and free the connection. |
| `gmz_tick` | Poll for ACKs, return combined FPGA status + health. |
| `gmz_set_modeline` | Send CMD_SWITCHRES with display timing parameters. |
| `gmz_submit` | Send a video frame to the FPGA. |
| `gmz_submit_audio` | Send raw 16-bit PCM audio to the FPGA. |
| `gmz_wait_sync` | Block until FPGA ACK or timeout. |

### Types

- `gmz_conn_t` -- Opaque connection handle
- `gmz_modeline_t` -- Display timing parameters (pixel clock, h/v active/blank/sync/total, interlace)
- `gmz_state_t` -- Combined FPGA status + health metrics (frame counters, VRAM state, sync stats)

## Usage

### C / C++

```c
#include "groovy_mister.h"

gmz_conn_t conn = gmz_connect("192.168.1.123", 1470, 0, 3, 2);
// ... set modeline, submit frames ...
gmz_disconnect(conn);
```

Link with `-lgroovy-mister` and add the `include/` directory to your header search path.

### Swift (via module map)

The `include/module.modulemap` enables direct import:

```swift
import GroovyMisterZig

let conn = gmz_connect("192.168.1.123", 1470, 0, 3, 2)
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
  c_api.zig       -- C ABI function exports

include/
  groovy_mister.h    -- C header
  module.modulemap   -- Clang module map for Swift
```

## License

GPL-3.0. See [LICENSE](LICENSE).
