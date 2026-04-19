/**
 * ETS2/ATS force-feedback telemetry plugin for ThrustmasterWheel (macOS).
 *
 * Writes a single live struct of driving telemetry into a POSIX shared memory
 * segment at /ets2_ff_v1 so a separate userspace daemon can compute
 * force-feedback effects and send them to a T300RS wheel over USB interrupt OUT.
 *
 * Target: x86_64 macOS .so placed in
 *   "Euro Truck Simulator 2.app/Contents/MacOS/plugins/ff_telemetry.so"
 *
 * Build:
 *   clang++ -arch x86_64 -std=c++17 -O2 -fPIC -Wall -shared \
 *     -Wl,-install_name,ff_telemetry.so \
 *     -I../scs_sdk_1_14/include -I../scs_sdk_1_14/include/common \
 *     -I../scs_sdk_1_14/include/eurotrucks2 -I../scs_sdk_1_14/include/amtrucks \
 *     -o ff_telemetry.so ff_plugin.cpp
 */

#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include "scssdk_telemetry.h"
#include "eurotrucks2/scssdk_eut2.h"
#include "eurotrucks2/scssdk_telemetry_eut2.h"
#include "amtrucks/scssdk_ats.h"
#include "amtrucks/scssdk_telemetry_ats.h"

#include "ets2_ff_shm.h"

#define UNUSED(x)

static scs_log_t game_log = NULL;
static int shm_fd = -1;
static struct ets2_ff_state *shm_state = NULL;

// Local mirror of the telemetry state — channel callbacks update this.
// We commit it into shm under a seqlock once per frame_end.
static struct ets2_ff_state local_state;

// Tracks whether the in-game telemetry source is currently paused.
static bool output_paused = true;

// Substance index -> surface category, built from the "substances" config event.
static uint8_t substance_map[256];

static void log_msg(scs_log_type_t type, const char *fmt, ...) {
    if (!game_log) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    game_log(type, buf);
}

// ---------- surface category lookup ---------------------------------------

static uint8_t classify_substance(const char *name) {
    if (!name) return ETS2_SURF_UNKNOWN;
    if (strcasecmp(name, "road") == 0 || strcasecmp(name, "road_smooth") == 0 ||
        strcasecmp(name, "concrete") == 0 || strcasecmp(name, "metal") == 0 ||
        strcasecmp(name, "glass") == 0 || strcasecmp(name, "plastic") == 0)
        return ETS2_SURF_SMOOTH;
    if (strcasecmp(name, "road_coarse") == 0)
        return ETS2_SURF_COARSE;
    if (strcasecmp(name, "road_dirt") == 0 || strcasecmp(name, "dirt") == 0 ||
        strcasecmp(name, "gravel") == 0)
        return ETS2_SURF_DIRT;
    if (strcasecmp(name, "grass") == 0 || strcasecmp(name, "soft") == 0 ||
        strcasecmp(name, "wood") == 0 || strcasecmp(name, "rubber") == 0)
        return ETS2_SURF_GRASS;
    if (strcasecmp(name, "ice") == 0 || strcasecmp(name, "snow") == 0 ||
        strcasecmp(name, "road_snow") == 0)
        return ETS2_SURF_SLIPPERY;
    if (strcasecmp(name, "rumble_stripe") == 0)
        return ETS2_SURF_RUMBLE;
    return ETS2_SURF_UNKNOWN;
}

// ---------- shared memory --------------------------------------------------

static bool shm_init(void) {
    shm_unlink(ETS2_FF_SHM_NAME); // best-effort, ignore result

    shm_fd = shm_open(ETS2_FF_SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (shm_fd < 0) {
        log_msg(SCS_LOG_TYPE_error, "[FF] shm_open failed: %s", strerror(errno));
        return false;
    }
    if (ftruncate(shm_fd, sizeof(struct ets2_ff_state)) != 0) {
        log_msg(SCS_LOG_TYPE_error, "[FF] ftruncate failed: %s", strerror(errno));
        close(shm_fd); shm_fd = -1;
        return false;
    }
    void *mapped = mmap(NULL, sizeof(struct ets2_ff_state),
                        PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
    if (mapped == MAP_FAILED) {
        log_msg(SCS_LOG_TYPE_error, "[FF] mmap failed: %s", strerror(errno));
        close(shm_fd); shm_fd = -1;
        return false;
    }
    shm_state = (struct ets2_ff_state *)mapped;
    memset(shm_state, 0, sizeof(*shm_state));
    shm_state->magic = ETS2_FF_SHM_MAGIC;
    shm_state->version = ETS2_FF_SHM_VERSION;
    shm_state->seq = 0;
    shm_state->plugin_alive = 1;
    return true;
}

static void shm_teardown(void) {
    if (shm_state) {
        shm_state->plugin_alive = 0;
        munmap(shm_state, sizeof(*shm_state));
        shm_state = NULL;
    }
    if (shm_fd >= 0) {
        close(shm_fd);
        shm_fd = -1;
    }
    shm_unlink(ETS2_FF_SHM_NAME);
}

// Commit local_state into shm under seqlock.
// local_state mirrors ets2_ff_state except for magic/version/seq which are
// fixed by shm_init(); we copy every other field after marking the seq odd.
static void shm_commit(void) {
    if (!shm_state) return;
    uint64_t s = shm_state->seq;
    __atomic_store_n(&shm_state->seq, s + 1, __ATOMIC_RELEASE); // odd: writing

    // Copy only the mutable body, preserving magic/version/seq.
    shm_state->render_ts_us = local_state.render_ts_us;
    shm_state->sim_ts_us    = local_state.sim_ts_us;

    shm_state->speed             = local_state.speed;
    shm_state->engine_rpm        = local_state.engine_rpm;
    shm_state->engine_gear       = local_state.engine_gear;
    shm_state->effective_steering = local_state.effective_steering;
    shm_state->input_steering    = local_state.input_steering;

    shm_state->accel_x = local_state.accel_x;
    shm_state->accel_y = local_state.accel_y;
    shm_state->accel_z = local_state.accel_z;

    shm_state->wheel_count     = local_state.wheel_count;
    shm_state->collision_count = local_state.collision_count;
    shm_state->gearshift_count = local_state.gearshift_count;

    memcpy(shm_state->wheel_susp,       local_state.wheel_susp,       sizeof(local_state.wheel_susp));
    memcpy(shm_state->wheel_angvel,     local_state.wheel_angvel,     sizeof(local_state.wheel_angvel));
    memcpy(shm_state->wheel_on_ground,  local_state.wheel_on_ground,  sizeof(local_state.wheel_on_ground));
    memcpy(shm_state->wheel_surface,    local_state.wheel_surface,    sizeof(local_state.wheel_surface));

    shm_state->plugin_alive      = local_state.plugin_alive;
    shm_state->paused            = local_state.paused;
    shm_state->connected         = local_state.connected;
    shm_state->trailer_connected = local_state.trailer_connected;

    shm_state->yaw_rate = local_state.yaw_rate;

    __atomic_store_n(&shm_state->seq, s + 2, __ATOMIC_RELEASE); // even: stable
}

// ---------- channel callbacks ---------------------------------------------

static SCSAPI_VOID store_float(const scs_string_t UNUSED(name),
                                const scs_u32_t UNUSED(index),
                                const scs_value_t *const value,
                                const scs_context_t context) {
    if (!value || !context) return;
    assert(value->type == SCS_VALUE_TYPE_float);
    *(float *)context = value->value_float.value;
}

static SCSAPI_VOID store_s32(const scs_string_t UNUSED(name),
                              const scs_u32_t UNUSED(index),
                              const scs_value_t *const value,
                              const scs_context_t context) {
    if (!value || !context) return;
    assert(value->type == SCS_VALUE_TYPE_s32);
    *(int32_t *)context = value->value_s32.value;
}

static SCSAPI_VOID store_accel(const scs_string_t UNUSED(name),
                                const scs_u32_t UNUSED(index),
                                const scs_value_t *const value,
                                const scs_context_t UNUSED(context)) {
    if (!value) return;
    assert(value->type == SCS_VALUE_TYPE_fvector);
    local_state.accel_x = value->value_fvector.x;
    local_state.accel_y = value->value_fvector.y;
    local_state.accel_z = value->value_fvector.z;
}

// Angular velocity in truck-local frame (fvector, rad/s).
// SCS axes: x = right, y = up, z = forward. Y-axis rotation = yaw.
static SCSAPI_VOID store_angvel(const scs_string_t UNUSED(name),
                                 const scs_u32_t UNUSED(index),
                                 const scs_value_t *const value,
                                 const scs_context_t UNUSED(context)) {
    if (!value) return;
    assert(value->type == SCS_VALUE_TYPE_fvector);
    local_state.yaw_rate = value->value_fvector.y;
}

static SCSAPI_VOID store_trailer_connected(const scs_string_t UNUSED(name),
                                            const scs_u32_t UNUSED(index),
                                            const scs_value_t *const value,
                                            const scs_context_t UNUSED(context)) {
    if (!value) { local_state.trailer_connected = 0; return; }
    local_state.trailer_connected = value->value_bool.value ? 1 : 0;
}

// Per-wheel callbacks. Context holds the wheel index (cast to/from pointer).
static SCSAPI_VOID store_wheel_on_ground(const scs_string_t UNUSED(name),
                                          const scs_u32_t index,
                                          const scs_value_t *const value,
                                          const scs_context_t UNUSED(context)) {
    if (index >= ETS2_FF_MAX_WHEELS) return;
    if (!value) { local_state.wheel_on_ground[index] = 0; return; }
    local_state.wheel_on_ground[index] = value->value_bool.value ? 1 : 0;
}

static SCSAPI_VOID store_wheel_substance(const scs_string_t UNUSED(name),
                                          const scs_u32_t index,
                                          const scs_value_t *const value,
                                          const scs_context_t UNUSED(context)) {
    if (index >= ETS2_FF_MAX_WHEELS) return;
    if (!value) return;
    uint32_t si = value->value_u32.value;
    local_state.wheel_surface[index] = (si < 256) ? substance_map[si] : ETS2_SURF_UNKNOWN;
}

static SCSAPI_VOID store_wheel_susp(const scs_string_t UNUSED(name),
                                     const scs_u32_t index,
                                     const scs_value_t *const value,
                                     const scs_context_t UNUSED(context)) {
    if (index >= ETS2_FF_MAX_WHEELS) return;
    if (!value) return;
    local_state.wheel_susp[index] = value->value_float.value;
}

static SCSAPI_VOID store_wheel_angvel(const scs_string_t UNUSED(name),
                                       const scs_u32_t index,
                                       const scs_value_t *const value,
                                       const scs_context_t UNUSED(context)) {
    if (index >= ETS2_FF_MAX_WHEELS) return;
    if (!value) return;
    local_state.wheel_angvel[index] = value->value_float.value;
}

// ---------- event callbacks ----------------------------------------------

static SCSAPI_VOID ev_frame_start(const scs_event_t UNUSED(event),
                                   const void *const event_info,
                                   const scs_context_t UNUSED(context)) {
    const struct scs_telemetry_frame_start_t *info =
        (const struct scs_telemetry_frame_start_t *)event_info;
    local_state.render_ts_us = info->render_time;
    local_state.sim_ts_us = info->simulation_time;
}

static SCSAPI_VOID ev_frame_end(const scs_event_t UNUSED(event),
                                 const void *const UNUSED(event_info),
                                 const scs_context_t UNUSED(context)) {
    local_state.paused = output_paused ? 1 : 0;
    local_state.connected = output_paused ? 0 : 1;
    local_state.plugin_alive = 1;
    shm_commit();
}

static SCSAPI_VOID ev_pause(const scs_event_t event,
                             const void *const UNUSED(event_info),
                             const scs_context_t UNUSED(context)) {
    output_paused = (event == SCS_TELEMETRY_EVENT_paused);
    log_msg(SCS_LOG_TYPE_message, output_paused ? "[FF] paused" : "[FF] running");
}

static SCSAPI_VOID ev_configuration(const scs_event_t UNUSED(event),
                                     const void *const event_info,
                                     const scs_context_t UNUSED(context)) {
    const struct scs_telemetry_configuration_t *info =
        (const struct scs_telemetry_configuration_t *)event_info;

    if (strcmp(info->id, SCS_TELEMETRY_CONFIG_substances) == 0) {
        memset(substance_map, ETS2_SURF_UNKNOWN, sizeof(substance_map));
        for (const scs_named_value_t *cur = info->attributes; cur->name; ++cur) {
            if (cur->index == SCS_U32_NIL) continue;
            if (cur->index >= 256) continue;
            if (cur->value.type != SCS_VALUE_TYPE_string) continue;
            const char *n = cur->value.value_string.value;
            uint8_t cat = classify_substance(n);
            substance_map[cur->index] = cat;
        }
        log_msg(SCS_LOG_TYPE_message, "[FF] substance map rebuilt");
    }
    if (strcmp(info->id, "truck") == 0) {
        // find wheels.count
        for (const scs_named_value_t *cur = info->attributes; cur->name; ++cur) {
            if (strcmp(cur->name, "wheels.count") == 0 &&
                cur->value.type == SCS_VALUE_TYPE_u32) {
                uint32_t wc = cur->value.value_u32.value;
                if (wc > ETS2_FF_MAX_WHEELS) wc = ETS2_FF_MAX_WHEELS;
                local_state.wheel_count = wc;
                break;
            }
        }
    }
}

static SCSAPI_VOID ev_gameplay(const scs_event_t UNUSED(event),
                                const void *const event_info,
                                const scs_context_t UNUSED(context)) {
    const struct scs_telemetry_gameplay_event_t *info =
        (const struct scs_telemetry_gameplay_event_t *)event_info;
    // No explicit collision channel exists in SDK 1.14; daemon derives collisions
    // from accel spikes. We only bump counters for anything noteworthy.
    if (info && info->id) {
        if (strstr(info->id, "fined") != NULL) {
            local_state.collision_count++;  // crash fines often mean a collision
        }
    }
}

// ---------- init / shutdown ----------------------------------------------

extern "C" SCSAPI_RESULT scs_telemetry_init(const scs_u32_t version,
                                             const scs_telemetry_init_params_t *const params) {
    if (version != SCS_TELEMETRY_VERSION_1_01) return SCS_RESULT_unsupported;

    const scs_telemetry_init_params_v101_t *vp =
        (const scs_telemetry_init_params_v101_t *)params;
    game_log = vp->common.log;

    log_msg(SCS_LOG_TYPE_message, "[FF] telemetry plugin starting (game='%s' v%u.%u)",
            vp->common.game_id,
            SCS_GET_MAJOR_VERSION(vp->common.game_version),
            SCS_GET_MINOR_VERSION(vp->common.game_version));

    memset(&local_state, 0, sizeof(local_state));
    memset(substance_map, ETS2_SURF_UNKNOWN, sizeof(substance_map));
    output_paused = true;

    if (!shm_init()) {
        log_msg(SCS_LOG_TYPE_error, "[FF] shared memory init failed");
        return SCS_RESULT_generic_error;
    }

    // Required events
    if (vp->register_for_event(SCS_TELEMETRY_EVENT_frame_start, ev_frame_start, NULL) != SCS_RESULT_ok ||
        vp->register_for_event(SCS_TELEMETRY_EVENT_frame_end,   ev_frame_end,   NULL) != SCS_RESULT_ok ||
        vp->register_for_event(SCS_TELEMETRY_EVENT_paused,      ev_pause,       NULL) != SCS_RESULT_ok ||
        vp->register_for_event(SCS_TELEMETRY_EVENT_started,     ev_pause,       NULL) != SCS_RESULT_ok) {
        log_msg(SCS_LOG_TYPE_error, "[FF] failed to register core events");
        shm_teardown();
        return SCS_RESULT_generic_error;
    }
    vp->register_for_event(SCS_TELEMETRY_EVENT_configuration, ev_configuration, NULL);
    vp->register_for_event(SCS_TELEMETRY_EVENT_gameplay,      ev_gameplay,      NULL);

    // Simple float/int channels
    vp->register_for_channel(SCS_TELEMETRY_TRUCK_CHANNEL_speed,
        SCS_U32_NIL, SCS_VALUE_TYPE_float,
        SCS_TELEMETRY_CHANNEL_FLAG_none, store_float, &local_state.speed);
    vp->register_for_channel(SCS_TELEMETRY_TRUCK_CHANNEL_engine_rpm,
        SCS_U32_NIL, SCS_VALUE_TYPE_float,
        SCS_TELEMETRY_CHANNEL_FLAG_none, store_float, &local_state.engine_rpm);
    vp->register_for_channel(SCS_TELEMETRY_TRUCK_CHANNEL_engine_gear,
        SCS_U32_NIL, SCS_VALUE_TYPE_s32,
        SCS_TELEMETRY_CHANNEL_FLAG_none, store_s32, &local_state.engine_gear);
    vp->register_for_channel(SCS_TELEMETRY_TRUCK_CHANNEL_effective_steering,
        SCS_U32_NIL, SCS_VALUE_TYPE_float,
        SCS_TELEMETRY_CHANNEL_FLAG_none, store_float, &local_state.effective_steering);
    vp->register_for_channel(SCS_TELEMETRY_TRUCK_CHANNEL_input_steering,
        SCS_U32_NIL, SCS_VALUE_TYPE_float,
        SCS_TELEMETRY_CHANNEL_FLAG_none, store_float, &local_state.input_steering);

    // Lateral / longitudinal acceleration (local frame)
    vp->register_for_channel(SCS_TELEMETRY_TRUCK_CHANNEL_local_linear_acceleration,
        SCS_U32_NIL, SCS_VALUE_TYPE_fvector,
        SCS_TELEMETRY_CHANNEL_FLAG_none, store_accel, NULL);

    // Angular velocity (yaw rate = y axis in truck-local frame)
    vp->register_for_channel(SCS_TELEMETRY_TRUCK_CHANNEL_local_angular_velocity,
        SCS_U32_NIL, SCS_VALUE_TYPE_fvector,
        SCS_TELEMETRY_CHANNEL_FLAG_none, store_angvel, NULL);

    // Trailer connected: first trailer (index 0) is the main one in ETS2.
    vp->register_for_channel(SCS_TELEMETRY_TRAILER_CHANNEL_connected,
        0, SCS_VALUE_TYPE_bool,
        SCS_TELEMETRY_CHANNEL_FLAG_none, store_trailer_connected, NULL);

    // Per-wheel arrays (register each index)
    for (scs_u32_t i = 0; i < ETS2_FF_MAX_WHEELS; ++i) {
        vp->register_for_channel(SCS_TELEMETRY_TRUCK_CHANNEL_wheel_on_ground,
            i, SCS_VALUE_TYPE_bool,
            SCS_TELEMETRY_CHANNEL_FLAG_none, store_wheel_on_ground, NULL);
        vp->register_for_channel(SCS_TELEMETRY_TRUCK_CHANNEL_wheel_substance,
            i, SCS_VALUE_TYPE_u32,
            SCS_TELEMETRY_CHANNEL_FLAG_none, store_wheel_substance, NULL);
        vp->register_for_channel(SCS_TELEMETRY_TRUCK_CHANNEL_wheel_susp_deflection,
            i, SCS_VALUE_TYPE_float,
            SCS_TELEMETRY_CHANNEL_FLAG_none, store_wheel_susp, NULL);
        vp->register_for_channel(SCS_TELEMETRY_TRUCK_CHANNEL_wheel_velocity,
            i, SCS_VALUE_TYPE_float,
            SCS_TELEMETRY_CHANNEL_FLAG_none, store_wheel_angvel, NULL);
    }

    log_msg(SCS_LOG_TYPE_message, "[FF] ready, shm=%s", ETS2_FF_SHM_NAME);
    return SCS_RESULT_ok;
}

extern "C" SCSAPI_VOID scs_telemetry_shutdown(void) {
    log_msg(SCS_LOG_TYPE_message, "[FF] shutting down");
    shm_teardown();
    game_log = NULL;
}
