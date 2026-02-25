#ifndef GROOVY_MISTER_H
#define GROOVY_MISTER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque connection handle.
typedef struct gmz_conn *gmz_conn_t;

/// Modeline parameters for gmz_set_modeline.
/// Layout matches Zig extern struct (C ABI, natural alignment).
typedef struct {
    double pixel_clock;
    uint16_t h_active;
    uint16_t h_begin;
    uint16_t h_end;
    uint16_t h_total;
    uint16_t v_active;
    uint16_t v_begin;
    uint16_t v_end;
    uint16_t v_total;
    uint8_t interlaced;
    uint8_t _pad[6];
} gmz_modeline_t;

/// Combined FPGA status + health state returned by gmz_tick.
/// Layout matches Zig extern struct (C ABI, natural alignment).
typedef struct {
    uint32_t frame;
    uint32_t frame_echo;
    uint16_t vcount;
    uint16_t vcount_echo;
    uint8_t vram_ready;
    uint8_t vram_end_frame;
    uint8_t vram_synced;
    uint8_t vga_frameskip;
    uint8_t vga_vblank;
    uint8_t vga_f1;
    uint8_t audio_active;
    uint8_t vram_queue;
    double avg_sync_wait_ms;
    double p95_sync_wait_ms;
    double vram_ready_rate;
    double stall_threshold_ms;
} gmz_state_t;

/// Connect to FPGA and send CMD_INIT. Returns handle or NULL on failure.
/// sound_rate: 0=off, 1=22050, 2=44100, 3=48000
/// sound_channels: 0=off, 1=mono, 2=stereo
gmz_conn_t gmz_connect(const char *host, uint16_t mtu, uint8_t rgb_mode,
                        uint8_t sound_rate, uint8_t sound_channels);

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

#ifdef __cplusplus
}
#endif

#endif /* GROOVY_MISTER_H */
