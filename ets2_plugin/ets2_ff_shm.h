/**
 * Shared memory layout between the ETS2 SCS telemetry plugin and the
 * ThrustmasterWheel force-feedback daemon.
 *
 * Protocol: single-writer (plugin) / single-reader (daemon) seqlock.
 *   writer:  seq++  (now odd)  -> write body -> seq++  (now even)
 *   reader:  s1 = seq; if (s1 & 1) retry; read body; s2 = seq; if (s1 != s2) retry
 *
 * shm name:  /ets2_ff_v1
 *
 * Field order is chosen so that the natural C layout has NO implicit padding
 * (on both x86_64 and arm64 LP64). All 8-byte fields first, then 4-byte,
 * then 1-byte arrays at the tail. The static_assert at the bottom catches any
 * future drift.
 */
#ifndef ETS2_FF_SHM_H
#define ETS2_FF_SHM_H

#include <stdint.h>

#define ETS2_FF_SHM_NAME   "/ets2_ff_v1"
#define ETS2_FF_SHM_MAGIC  0x46464632U     /* 'FFE2' */
/* Version history:
 *   1 — initial layout (phase 2).
 *   2 — added trailer_connected + yaw_rate (repurposed former _reserved byte
 *        and first 4 bytes of _tail_pad; total size unchanged at 184).
 */
#define ETS2_FF_SHM_VERSION 2
#define ETS2_FF_MAX_WHEELS 8

enum ets2_surface {
    ETS2_SURF_UNKNOWN   = 0,
    ETS2_SURF_SMOOTH    = 1,
    ETS2_SURF_COARSE    = 2,
    ETS2_SURF_DIRT      = 3,
    ETS2_SURF_GRASS     = 4,
    ETS2_SURF_SLIPPERY  = 5,
    ETS2_SURF_RUMBLE    = 6,
};

struct ets2_ff_state {
    /* -- 8-byte fields -- */
    volatile uint64_t seq;          /* offset 0  — seqlock */
    uint64_t render_ts_us;          /* offset 8  */
    uint64_t sim_ts_us;             /* offset 16 */

    /* -- 4-byte fields -- */
    uint32_t magic;                 /* offset 24 */
    uint32_t version;               /* offset 28 */

    float speed;                    /* offset 32 */
    float engine_rpm;               /* offset 36 */
    int32_t engine_gear;            /* offset 40 */
    float effective_steering;       /* offset 44 */
    float input_steering;           /* offset 48 */

    float accel_x;                  /* offset 52 */
    float accel_y;                  /* offset 56 */
    float accel_z;                  /* offset 60 */

    uint32_t wheel_count;           /* offset 64 */
    uint32_t collision_count;       /* offset 68 */
    uint32_t gearshift_count;       /* offset 72 */
    uint32_t _flags_pad;            /* offset 76  — kept for 8-byte alignment of float array below is irrelevant; placeholder */

    /* Per-wheel float arrays (offset 80, size 32 each, total 64) */
    float wheel_susp[ETS2_FF_MAX_WHEELS];    /* offset 80  */
    float wheel_angvel[ETS2_FF_MAX_WHEELS];  /* offset 112 */

    /* -- 1-byte fields at tail -- */
    uint8_t plugin_alive;           /* offset 144 */
    uint8_t paused;                 /* offset 145 */
    uint8_t connected;              /* offset 146 */
    uint8_t trailer_connected;      /* offset 147  (v2: was _reserved) */

    uint8_t wheel_on_ground[ETS2_FF_MAX_WHEELS]; /* offset 148 */
    uint8_t wheel_surface[ETS2_FF_MAX_WHEELS];   /* offset 156 */

    /* v2 additions (carved out of former _tail_pad[20] → [16]) */
    float yaw_rate;                 /* offset 164  rad/s around truck up axis */

    uint8_t _tail_pad[16];          /* offset 168, ends at 184 */
};

/* Catch accidental layout drift at compile time. */
#ifdef __cplusplus
static_assert(sizeof(struct ets2_ff_state) == 184,
              "ets2_ff_state layout changed — update reader offsets");
static_assert(__builtin_offsetof(struct ets2_ff_state, render_ts_us) == 8, "off");
static_assert(__builtin_offsetof(struct ets2_ff_state, speed) == 32, "off");
static_assert(__builtin_offsetof(struct ets2_ff_state, wheel_susp) == 80, "off");
static_assert(__builtin_offsetof(struct ets2_ff_state, plugin_alive) == 144, "off");
static_assert(__builtin_offsetof(struct ets2_ff_state, wheel_on_ground) == 148, "off");
static_assert(__builtin_offsetof(struct ets2_ff_state, trailer_connected) == 147, "off");
static_assert(__builtin_offsetof(struct ets2_ff_state, yaw_rate) == 164, "off");
#endif

#endif /* ETS2_FF_SHM_H */
