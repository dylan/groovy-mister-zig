#ifndef GROOVY_MISTER_H
#define GROOVY_MISTER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque connection handle.
typedef struct gmz_conn *gmz_conn_t;

/// LZ4 compression mode constants for gmz_connect_ex().
#define GMZ_LZ4_OFF          0
#define GMZ_LZ4              1
#define GMZ_LZ4_DELTA        2
#define GMZ_LZ4_HC           3
#define GMZ_LZ4_HC_DELTA     4
#define GMZ_LZ4_ADAPTIVE     5
#define GMZ_LZ4_ADAPTIVE_DELTA 6

/// Modeline parameters for gmz_set_modeline.
/// Layout matches Zig extern struct (C ABI, natural alignment).
typedef struct {
    double pixel_clock;   ///< Pixel clock in MHz.
    uint16_t h_active;    ///< Horizontal active pixels.
    uint16_t h_begin;     ///< Horizontal sync start.
    uint16_t h_end;       ///< Horizontal sync end.
    uint16_t h_total;     ///< Horizontal total pixels per line.
    uint16_t v_active;    ///< Vertical active lines.
    uint16_t v_begin;     ///< Vertical sync start.
    uint16_t v_end;       ///< Vertical sync end.
    uint16_t v_total;     ///< Vertical total lines per frame.
    uint8_t interlaced;   ///< 1 = interlaced, 0 = progressive.
    uint8_t _pad[6];
} gmz_modeline_t;

/// Combined FPGA status + health state returned by gmz_tick.
/// Layout matches Zig extern struct (C ABI, natural alignment).
typedef struct {
    uint32_t frame;              ///< FPGA's current frame counter.
    uint32_t frame_echo;         ///< Last frame number acknowledged by FPGA.
    uint16_t vcount;             ///< FPGA's current scanline position.
    uint16_t vcount_echo;        ///< Scanline position when FPGA sent the ACK.
    uint8_t vram_ready;          ///< 1 = FPGA VRAM is ready for the next frame.
    uint8_t vram_end_frame;      ///< 1 = FPGA finished displaying the current frame.
    uint8_t vram_synced;         ///< 1 = FPGA VRAM is in sync with host.
    uint8_t vga_frameskip;       ///< 1 = FPGA skipped a frame (host too slow).
    uint8_t vga_vblank;          ///< 1 = FPGA is currently in vertical blank.
    uint8_t vga_f1;              ///< Current field for interlaced modes (0 or 1).
    uint8_t audio_active;        ///< 1 = FPGA audio pipeline is active.
    uint8_t vram_queue;          ///< Number of frames queued in FPGA VRAM.
    double avg_sync_wait_ms;     ///< Rolling average sync wait time (128 samples).
    double p95_sync_wait_ms;     ///< 95th percentile sync wait time (128 samples).
    double vram_ready_rate;      ///< Fraction of ticks where VRAM was ready (0.0–1.0).
    double stall_threshold_ms;   ///< Sync wait above this suggests a stall.
} gmz_state_t;

/// Connect to FPGA and send CMD_INIT. Returns handle or NULL on failure.
/// sound_rate: 0=off, 1=22050, 2=44100, 3=48000
/// sound_channels: 0=off, 1=mono, 2=stereo
gmz_conn_t gmz_connect(const char *host, uint16_t mtu, uint8_t rgb_mode,
                        uint8_t sound_rate, uint8_t sound_channels);

/// Connect to FPGA with optional LZ4 compression and send CMD_INIT.
/// When lz4_mode > 0, allocates a compression buffer internally.
/// Returns handle or NULL on failure.
gmz_conn_t gmz_connect_ex(const char *host, uint16_t mtu, uint8_t rgb_mode,
                           uint8_t sound_rate, uint8_t sound_channels,
                           uint8_t lz4_mode);

/// Send CMD_CLOSE and free the connection. Null-safe.
void gmz_disconnect(gmz_conn_t conn);

/// Poll for ACKs, record vram_ready, and return combined FPGA status + health.
gmz_state_t gmz_tick(gmz_conn_t conn);

/// Send CMD_SWITCHRES with the given modeline. Returns 0 on success, -1 on error.
int gmz_set_modeline(gmz_conn_t conn, const gmz_modeline_t *modeline);

/// Send frame data to FPGA and record sync timing. Returns 0 on success, -1 on error.
int gmz_submit(gmz_conn_t conn, const uint8_t *data, size_t len,
               uint32_t frame, uint8_t field, uint16_t vsync_line,
               double sync_wait_ms);

/// Send raw PCM audio data to FPGA. Returns 0 on success, -1 on error.
/// data: raw 16-bit signed PCM (interleaved if stereo).
/// len: total byte count of PCM data.
int gmz_submit_audio(gmz_conn_t conn, const uint8_t *data, size_t len);

/// Block until ACK received or timeout. Returns 0=ACK, 1=timeout, -1=null handle.
int gmz_wait_sync(gmz_conn_t conn, int timeout_ms);

/// Return the library version string (e.g. "0.1.0"). Null-terminated, static storage.
const char *gmz_version(void);

/// Return the library major version number.
uint32_t gmz_version_major(void);

/// Return the library minor version number.
uint32_t gmz_version_minor(void);

/// Return the library patch version number.
uint32_t gmz_version_patch(void);

/// Get raster time offset in nanoseconds for the given submitted frame.
/// Positive = FPGA is behind (need to wait), negative = running late.
/// Calls poll() internally to get latest ACK. Returns 0 if no modeline set.
int32_t gmz_raster_offset_ns(gmz_conn_t conn, uint32_t submitted_frame);

/// Compute optimal vsync line for next frame submission.
/// margin_ns: safety margin in nanoseconds (e.g. 2000000 for 2ms).
/// emulation_ns: time spent generating this frame (nanoseconds).
/// stream_ns: time spent transmitting last frame (nanoseconds).
/// Returns target scanline, or v_total/2 if no modeline set.
uint16_t gmz_calc_vsync(gmz_conn_t conn, uint32_t margin_ns,
                         uint64_t emulation_ns, uint64_t stream_ns);

/// Get frame period in nanoseconds from current modeline. 0 if no modeline set.
uint64_t gmz_frame_time_ns(gmz_conn_t conn);

/* --- Input (FPGA joystick/keyboard/mouse on UDP port 32101) --- */

/// Opaque input handle.
typedef struct gmz_input *gmz_input_t;

/// Joystick button bitmask constants.
#define GMZ_JOY_RIGHT  0x0001
#define GMZ_JOY_LEFT   0x0002
#define GMZ_JOY_DOWN   0x0004
#define GMZ_JOY_UP     0x0008
#define GMZ_JOY_B1     0x0010
#define GMZ_JOY_B2     0x0020
#define GMZ_JOY_B3     0x0040
#define GMZ_JOY_B4     0x0080
#define GMZ_JOY_B5     0x0100
#define GMZ_JOY_B6     0x0200
#define GMZ_JOY_B7     0x0400
#define GMZ_JOY_B8     0x0800
#define GMZ_JOY_B9     0x1000
#define GMZ_JOY_B10    0x2000

/// Joystick state (digital buttons + analog axes).
typedef struct {
    uint32_t frame;    ///< FPGA frame counter when this state was sent.
    uint16_t joy1;     ///< Player 1 digital buttons (bitfield of GMZ_JOY_*).
    uint16_t joy2;     ///< Player 2 digital buttons (bitfield of GMZ_JOY_*).
    uint8_t order;     ///< Sequence counter within a frame (for dedup).
    int8_t j1_lx;     ///< Player 1 left stick X (-128..127).
    int8_t j1_ly;     ///< Player 1 left stick Y.
    int8_t j1_rx;     ///< Player 1 right stick X.
    int8_t j1_ry;     ///< Player 1 right stick Y.
    int8_t j2_lx;     ///< Player 2 left stick X.
    int8_t j2_ly;     ///< Player 2 left stick Y.
    int8_t j2_rx;     ///< Player 2 right stick X.
    int8_t j2_ry;     ///< Player 2 right stick Y.
    uint8_t _pad[3];
} gmz_joy_state_t;

/// PS/2 keyboard + mouse state.
typedef struct {
    uint32_t frame;       ///< FPGA frame counter when this state was sent.
    uint8_t order;        ///< Sequence counter within a frame (for dedup).
    uint8_t mouse_btns;   ///< PS/2 mouse status byte [yo,xo,ys,xs,1,bm,br,bl].
    uint8_t mouse_x;      ///< Raw PS/2 mouse X movement.
    uint8_t mouse_y;      ///< Raw PS/2 mouse Y movement.
    uint8_t mouse_z;      ///< Raw PS/2 mouse Z (scroll wheel).
    uint8_t _pad[3];
    uint8_t keys[32];     ///< 256-bit SDL scancode bitfield.
} gmz_ps2_state_t;

/// Connect to FPGA input stream (joystick/keyboard/mouse on UDP port 32101).
/// Sends a 1-byte hello to start receiving input state. Returns handle or NULL.
gmz_input_t gmz_input_bind(const char *host);

/// Close the input connection and free the handle. Null-safe.
void gmz_input_close(gmz_input_t input);

/// Poll for pending input packets. Returns 1 if new data received, 0 if none.
int gmz_input_poll(gmz_input_t input);

/// Read the latest joystick state. Null-safe (returns zeroed state).
gmz_joy_state_t gmz_input_joy(gmz_input_t input);

/// Read the latest PS/2 keyboard + mouse state. Null-safe (returns zeroed state).
gmz_ps2_state_t gmz_input_ps2(gmz_input_t input);

#ifdef __cplusplus
}
#endif

#endif /* GROOVY_MISTER_H */
