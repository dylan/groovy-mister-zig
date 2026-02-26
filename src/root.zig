//! GroovyMisterZig — UDP streaming library for MiSTer FPGA.
//!
//! Streams desktop frames to a MiSTer FPGA over UDP port 32100.
//! Provides a C ABI for integration with Swift/ObjC hosts.
//!
//! ## Modules
//! - `protocol`: Packet formats, command codes, FPGA status parsing
//! - `Connection`: Non-blocking UDP socket, frame chunking, sync polling
//! - `Health`: Rolling-window metrics (sync wait, VRAM ready rate)
//! - `c_api`: C-exported functions (`gmz_connect`, `gmz_submit`, etc.)

/// UDP protocol: command codes, packet builders, ACK parsing, modeline/status types.
pub const protocol = @import("protocol.zig");
/// Rolling-window health metrics: sync wait timing, VRAM ready rate, stall detection.
pub const Health = @import("Health.zig");
/// Non-blocking UDP connection: socket lifecycle, frame chunking, sync polling.
pub const Connection = @import("Connection.zig");
/// LZ4 block compression: compressor factory and buffer sizing.
pub const lz4 = @import("lz4.zig");
/// Delta frame encoding: XOR successive frames for bandwidth reduction.
pub const delta = @import("delta.zig");
/// Library version from build.zig.zon.
pub const version = @import("version.zig");
/// CRT sync primitives: frame timing, raster offset, vsync line computation.
pub const sync = @import("sync.zig");
/// C ABI exports: `gmz_connect`, `gmz_disconnect`, `gmz_tick`, `gmz_set_modeline`, `gmz_submit`, `gmz_submit_audio`, `gmz_wait_sync`, `gmz_connect_ex`.
pub const c_api = @import("c_api.zig");

// Force export of C ABI symbols
comptime {
    _ = &c_api.gmz_connect;
    _ = &c_api.gmz_connect_ex;
    _ = &c_api.gmz_disconnect;
    _ = &c_api.gmz_tick;
    _ = &c_api.gmz_set_modeline;
    _ = &c_api.gmz_submit;
    _ = &c_api.gmz_submit_audio;
    _ = &c_api.gmz_wait_sync;
    _ = &c_api.gmz_version;
    _ = &c_api.gmz_version_major;
    _ = &c_api.gmz_version_minor;
    _ = &c_api.gmz_version_patch;
    _ = &c_api.gmz_raster_offset_ns;
    _ = &c_api.gmz_calc_vsync;
    _ = &c_api.gmz_frame_time_ns;
}

test {
    _ = protocol;
    _ = Health;
    _ = Connection;
    _ = lz4;
    _ = delta;
    _ = version;
    _ = sync;
    _ = c_api;
}
