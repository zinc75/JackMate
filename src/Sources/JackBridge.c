//
//  JackBridge.c
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Implementation of the libjack wrapper with runtime loading via dlopen.
//
//  v3 — use-after-free crash fix:
//  - Callbacks are nullified BEFORE closing the client
//  - Atomic is_closing flag used to discard callbacks during teardown
//

#include "JackBridge.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <unistd.h>

// ── Jack function-pointer signatures (minimal required subset) ────────────────

typedef void*    jack_client_t;
typedef uint32_t jack_port_id_t;
typedef uint32_t jack_options_t;
typedef uint32_t jack_status_t;

#define JackNullOption      0
#define JackNoStartServer   1
#define JackPortIsInput     0x1
#define JackPortIsOutput    0x2
#define JACK_DEFAULT_AUDIO_TYPE "32 bit float mono audio"
#define JACK_DEFAULT_MIDI_TYPE  "8 bit raw midi"

typedef jack_client_t* (*fn_jack_client_open)(const char*, jack_options_t, jack_status_t*, ...);
typedef int            (*fn_jack_client_close)(jack_client_t*);
typedef int            (*fn_jack_activate)(jack_client_t*);
typedef int            (*fn_jack_deactivate)(jack_client_t*);
typedef const char*    (*fn_jack_get_client_name)(jack_client_t*);
typedef const char**   (*fn_jack_get_ports)(jack_client_t*, const char*, const char*, unsigned long);
typedef void           (*fn_jack_free)(void*);
typedef void*          (*fn_jack_port_by_name)(jack_client_t*, const char*);
typedef int            (*fn_jack_port_flags2)(void*);
typedef const char*    (*fn_jack_port_type)(void*);
typedef const char**   (*fn_jack_port_get_connections)(const void*);
typedef int            (*fn_jack_connect)(jack_client_t*, const char*, const char*);
typedef int            (*fn_jack_disconnect)(jack_client_t*, const char*, const char*);
typedef void           (*fn_jack_set_port_registration_callback)(jack_client_t*,
                            void (*)(jack_port_id_t, int, void*), void*);
typedef void           (*fn_jack_set_port_connect_callback)(jack_client_t*,
                            void (*)(jack_port_id_t, jack_port_id_t, int, void*), void*);
typedef void           (*fn_jack_on_shutdown)(jack_client_t*, void (*)(void*), void*);
typedef void*          (*fn_jack_port_by_id2)(jack_client_t*, jack_port_id_t);
typedef const char*    (*fn_jack_port_name)(const void*);
typedef int            (*fn_jack_set_xrun_callback)(jack_client_t*, int (*)(void*), void*);

// ── Types Jack — Transport ─────────────────────────────────────────────────────

typedef uint32_t jack_nframes_t;
typedef uint32_t jack_transport_state_t;

// jack_position_t — exact Jack2 layout (136 bytes on 64-bit)
// Must match bit-for-bit the struct defined in <jack/transport.h>
typedef struct {
    uint64_t   unique_1;
    uint64_t   usecs;
    uint32_t   frame_rate;
    uint32_t   frame;
    uint32_t   valid;            // JM_JACK_POSITION_BBT = 0x10 when BBT is valid
    int32_t    bar;
    int32_t    beat;
    int32_t    tick;
    double     bar_start_tick;
    float      beats_per_bar;
    float      beat_type;
    double     ticks_per_beat;
    double     beats_per_minute;
    double     frame_time;
    double     next_time;
    uint32_t   bbt_offset;
    float      audio_frames_per_video_frame;
    uint32_t   video_offset;
    int32_t    padding[7];
    uint64_t   unique_2;
} jm_jack_position_t;

#define JM_JACK_TRANSPORT_STOPPED  0
#define JM_JACK_TRANSPORT_ROLLING  1
#define JM_JACK_TRANSPORT_STARTING 3
#define JM_JACK_POSITION_BBT       0x10

typedef jack_transport_state_t (*fn_jack_transport_query)(jack_client_t*, jm_jack_position_t*);
typedef void (*fn_jack_transport_start)(jack_client_t*);
typedef void (*fn_jack_transport_stop)(jack_client_t*);
typedef int  (*fn_jack_transport_locate)(jack_client_t*, jack_nframes_t);
typedef jack_nframes_t (*fn_jack_get_sample_rate)(jack_client_t*);
typedef int  (*fn_jack_set_timebase_callback)(jack_client_t*, int,
                  void (*)(jack_transport_state_t, jack_nframes_t,
                           jm_jack_position_t*, int, void*),
                  void*);
typedef void (*fn_jack_release_timebase)(jack_client_t*);
typedef int  (*fn_jack_set_process_callback)(jack_client_t*,
                  int (*)(jack_nframes_t, void*), void*);

// jack_get_client_pid — JACK_OPTIONAL_WEAK_EXPORT, may not exist on older builds
typedef int  (*fn_jack_get_client_pid)(const char*);

// ── Internal client structure ─────────────────────────────────────────────────

struct JMClient {
    void              *lib_handle;
    jack_client_t     *jack_client;
    char               error[512];
    char               client_name[128];
    
    // Atomic flag — set to true before teardown to discard in-flight callbacks
    atomic_bool        is_closing;
    atomic_bool        is_active;

    // Xrun counter — atomic for lock-free access from the Jack thread
    atomic_uint        xrun_count;

    // Function pointers loaded from libjack at runtime
    fn_jack_client_open                     f_open;
    fn_jack_client_close                    f_close;
    fn_jack_activate                        f_activate;
    fn_jack_deactivate                      f_deactivate;
    fn_jack_get_client_name                 f_get_name;
    fn_jack_get_ports                       f_get_ports;
    fn_jack_free                            f_free;
    fn_jack_port_by_name                    f_port_by_name;
    fn_jack_port_flags2                     f_port_flags;
    fn_jack_port_type                       f_port_type;
    fn_jack_port_get_connections            f_port_get_conns;
    fn_jack_connect                         f_connect;
    fn_jack_disconnect                      f_disconnect;
    fn_jack_set_port_registration_callback  f_set_port_reg_cb;
    fn_jack_set_port_connect_callback       f_set_port_conn_cb;
    fn_jack_on_shutdown                     f_on_shutdown;
    fn_jack_port_by_id2                     f_port_by_id2;
    fn_jack_port_name                       f_port_name;
    fn_jack_set_xrun_callback               f_set_xrun_cb;

    // Transport
    fn_jack_transport_query        f_transport_query;
    fn_jack_transport_start        f_transport_start;
    fn_jack_transport_stop         f_transport_stop;
    fn_jack_transport_locate       f_transport_locate;
    fn_jack_get_sample_rate        f_get_sample_rate;
    fn_jack_set_timebase_callback  f_set_timebase_cb;
    fn_jack_release_timebase       f_release_timebase;
    fn_jack_set_process_callback   f_set_process_cb;

    // Client introspection (optional)
    fn_jack_get_client_pid         f_get_client_pid;

    // Transport cache — written by _jm_process_cb (Jack RT thread),
    // read by the UI from any thread. Lock-free, zero IPC overhead.
    // BPM stored as integer * 10 (120.0 → 1200) to avoid atomic float.
    atomic_uint  tp_state;           // jack_transport_state_t (STOPPED/ROLLING/STARTING)
    atomic_uint  tp_frame;           // current position in frames
    atomic_uint  tp_sample_rate;     // server sample rate in Hz
    atomic_int   tp_bbt_valid;       // 1 when BBT data is available
    atomic_int   tp_bar;
    atomic_int   tp_beat;
    atomic_int   tp_tick;
    atomic_uint  tp_bpm_x10;         // BPM * 10  (e.g. 120.0 → 1200)
    atomic_int   tp_bpb_x10;         // beats_per_bar * 10
    atomic_int   tp_beat_type_x10;   // beat_type * 10

    // Timebase master — values read from the Jack RT thread (volatile to prevent
    // the compiler from caching writes from the main thread)
    atomic_bool      is_timebase_master;
    volatile double  timebase_bpm;
    volatile float   timebase_beats_per_bar;
    volatile float   timebase_beat_type;

    // Callbacks Swift
    JMPortRegistrationCallback  port_reg_cb;
    void                       *port_reg_ctx;
    JMPortConnectCallback       port_conn_cb;
    void                       *port_conn_ctx;
    JMShutdownCallback          shutdown_cb;
    void                       *shutdown_ctx;
};

// ── Default library search paths ──────────────────────────────────────────────

static const char *DEFAULT_LIBJACK_PATHS[] = {
    "/usr/local/lib/libjack.dylib",
    "/opt/homebrew/lib/libjack.dylib",
    "/opt/local/lib/libjack.dylib",
    NULL
};

// ── Symbol loading helpers ─────────────────────────────────────────────────────

#define LOAD_SYM(client, sym, field) do { \
    (client)->field = (typeof((client)->field))dlsym((client)->lib_handle, sym); \
    if (!(client)->field) { \
        snprintf((client)->error, sizeof((client)->error), \
                 "Symbole manquant: %s", sym); \
        return false; \
    } \
} while(0)

#define LOAD_SYM_OPTIONAL(client, sym, field) do { \
    (client)->field = (typeof((client)->field))dlsym((client)->lib_handle, sym); \
} while(0)

static bool jm_load_symbols(JMClient *c) {
    LOAD_SYM(c, "jack_client_open",                     f_open);
    LOAD_SYM(c, "jack_client_close",                    f_close);
    LOAD_SYM(c, "jack_activate",                        f_activate);
    LOAD_SYM_OPTIONAL(c, "jack_deactivate",             f_deactivate);
    LOAD_SYM(c, "jack_get_client_name",                 f_get_name);
    LOAD_SYM(c, "jack_get_ports",                       f_get_ports);
    LOAD_SYM(c, "jack_free",                            f_free);
    LOAD_SYM(c, "jack_port_by_name",                    f_port_by_name);
    LOAD_SYM(c, "jack_port_flags",                      f_port_flags);
    LOAD_SYM(c, "jack_port_type",                       f_port_type);
    LOAD_SYM(c, "jack_port_get_connections",            f_port_get_conns);
    LOAD_SYM(c, "jack_connect",                         f_connect);
    LOAD_SYM(c, "jack_disconnect",                      f_disconnect);
    LOAD_SYM(c, "jack_set_port_registration_callback",  f_set_port_reg_cb);
    LOAD_SYM(c, "jack_set_port_connect_callback",       f_set_port_conn_cb);
    LOAD_SYM(c, "jack_on_shutdown",                     f_on_shutdown);
    LOAD_SYM(c, "jack_port_by_id",                      f_port_by_id2);
    LOAD_SYM(c, "jack_port_name",                       f_port_name);
    LOAD_SYM_OPTIONAL(c, "jack_set_xrun_callback",      f_set_xrun_cb);
    // Transport — all optional; missing symbols do not cause failure
    LOAD_SYM_OPTIONAL(c, "jack_transport_query",        f_transport_query);
    LOAD_SYM_OPTIONAL(c, "jack_transport_start",        f_transport_start);
    LOAD_SYM_OPTIONAL(c, "jack_transport_stop",         f_transport_stop);
    LOAD_SYM_OPTIONAL(c, "jack_transport_locate",       f_transport_locate);
    LOAD_SYM_OPTIONAL(c, "jack_get_sample_rate",        f_get_sample_rate);
    LOAD_SYM_OPTIONAL(c, "jack_set_timebase_callback",  f_set_timebase_cb);
    LOAD_SYM_OPTIONAL(c, "jack_release_timebase",       f_release_timebase);
    LOAD_SYM_OPTIONAL(c, "jack_set_process_callback",   f_set_process_cb);
    // Client introspection — optional, weak export in Jack2
    LOAD_SYM_OPTIONAL(c, "jack_get_client_pid",         f_get_client_pid);
    return true;
}

// ── Forward declarations ─────────────────────────────────────────────

static int  _jm_process_cb(jack_nframes_t nframes, void *arg);
static void _jm_port_reg_cb(jack_port_id_t port_id, int registered, void *arg);
static void _jm_port_conn_cb(jack_port_id_t a, jack_port_id_t b, int connected, void *arg);
static void _jm_shutdown_cb(void *arg);
static int  _jm_xrun_cb(void *arg);
static void _jm_timebase_cb(jack_transport_state_t, jack_nframes_t,
                           jm_jack_position_t*, int, void*);

// ── Internal callbacks (Jack thread → dispatch to Swift callbacks) ─────────────

static void _jm_port_reg_cb(jack_port_id_t port_id, int registered, void *arg) {
    JMClient *c = (JMClient *)arg;
    
    // CRITICAL: Multiple checks to prevent race conditions during teardown
    if (!c) return;
    if (atomic_load(&c->is_closing)) return;
    if (!atomic_load(&c->is_active)) return;
    if (!c->jack_client) return;
    if (!c->port_reg_cb || !c->f_port_by_id2 || !c->f_port_name) return;
    
    void *port = c->f_port_by_id2(c->jack_client, port_id);
    if (!port) return;
    const char *name = c->f_port_name(port);
    
    if (name && c->port_reg_cb) {
        c->port_reg_cb(name, registered != 0, c->port_reg_ctx);
    }
}

static void _jm_port_conn_cb(jack_port_id_t a, jack_port_id_t b, int connected, void *arg) {
    JMClient *c = (JMClient *)arg;
    // CRITICAL: Multiple checks to prevent race conditions during teardown
    if (!c) return;
    if (atomic_load(&c->is_closing)) return;
    if (!atomic_load(&c->is_active)) return;
    if (!c->jack_client) return;
    if (!c->port_conn_cb || !c->f_port_by_id2 || !c->f_port_name) return;
    
    void *portA = c->f_port_by_id2(c->jack_client, a);
    void *portB = c->f_port_by_id2(c->jack_client, b);
    if (!portA || !portB) return;
    const char *from = c->f_port_name(portA);
    const char *to   = c->f_port_name(portB);
    if (from && to && c->port_conn_cb) {
        c->port_conn_cb(from, to, connected != 0, c->port_conn_ctx);
    }
}

static void _jm_shutdown_cb(void *arg) {
    JMClient *c = (JMClient *)arg;
    // CRITICAL: Ignore if teardown is in progress
    if (!c || atomic_load(&c->is_closing)) return;

    // Mark inactive BEFORE invoking the Swift callback
    atomic_store(&c->is_active, false);
    
    if (c->shutdown_cb) {
        c->shutdown_cb(c->shutdown_ctx);
    }
}

// Xrun callback — ULTRA-LIGHTWEIGHT: just increment an atomic counter.
// No dispatch, no allocation, no string formatting — real-time safe.
static int _jm_xrun_cb(void *arg) {
    JMClient *c = (JMClient *)arg;
    if (c && !atomic_load(&c->is_closing)) {
        atomic_fetch_add(&c->xrun_count, 1);
    }
    return 0;  // 0 = OK, Jack continues
}

// ── Port type inference from type string ──────────────────────────────────────

static JMPortType jm_port_type_from_string(const char *type_str) {
    if (!type_str) return JMPortTypeOther;
    if (strstr(type_str, "audio") || strstr(type_str, "float"))
        return JMPortTypeAudio;
    if (strstr(type_str, "midi") || strstr(type_str, "MIDI"))
        return JMPortTypeMIDI;
    if (strstr(type_str, "CV") || strstr(type_str, "cv"))
        return JMPortTypeCV;
    return JMPortTypeOther;
}

// ── "client:port" name splitting ──────────────────────────────────────────────

static void jm_parse_port_name(const char *full_name,
                                char *client_out, size_t client_sz,
                                char *port_out,   size_t port_sz) {
    const char *colon = strchr(full_name, ':');
    if (colon) {
        size_t clen = (size_t)(colon - full_name);
        if (clen >= client_sz) clen = client_sz - 1;
        strncpy(client_out, full_name, clen);
        client_out[clen] = '\0';
        strncpy(port_out, colon + 1, port_sz - 1);
        port_out[port_sz - 1] = '\0';
    } else {
        strncpy(client_out, full_name, client_sz - 1);
        client_out[client_sz - 1] = '\0';
        strncpy(port_out, "", port_sz - 1);
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

JMClient *jm_client_open(const char *client_name, const char *lib_path) {
    JMClient *c = (JMClient *)calloc(1, sizeof(JMClient));
    if (!c) return NULL;

    atomic_store(&c->is_closing, false);
    atomic_store(&c->is_active, false);
    atomic_store(&c->xrun_count, 0);
    atomic_store(&c->is_timebase_master, false);
    c->timebase_bpm           = 120.0;
    c->timebase_beats_per_bar = 4.0f;
    c->timebase_beat_type     = 4.0f;

    // Initialise transport cache with safe default values
    atomic_store(&c->tp_state,         (uint32_t)JM_JACK_TRANSPORT_STOPPED);
    atomic_store(&c->tp_frame,         0u);
    atomic_store(&c->tp_sample_rate,   44100u);
    atomic_store(&c->tp_bbt_valid,     0);
    atomic_store(&c->tp_bar,           1);
    atomic_store(&c->tp_beat,          1);
    atomic_store(&c->tp_tick,          0);
    atomic_store(&c->tp_bpm_x10,       1200u);   // 120.0 BPM
    atomic_store(&c->tp_bpb_x10,       40);      // 4.0 beats/bar
    atomic_store(&c->tp_beat_type_x10, 40);      // beat_type = 4

    // Load libjack
    if (lib_path) {
        c->lib_handle = dlopen(lib_path, RTLD_LAZY | RTLD_LOCAL);
    }
    if (!c->lib_handle) {
        for (int i = 0; DEFAULT_LIBJACK_PATHS[i]; i++) {
            c->lib_handle = dlopen(DEFAULT_LIBJACK_PATHS[i], RTLD_LAZY | RTLD_LOCAL);
            if (c->lib_handle) break;
        }
    }
    if (!c->lib_handle) {
        snprintf(c->error, sizeof(c->error),
                 "libjack.dylib introuvable");
        return c;
    }

    // Resolve all required symbols
    if (!jm_load_symbols(c)) {
        return c;  // error message already set
    }

    // Open the Jack client
    jack_status_t status = 0;
    c->jack_client = c->f_open(client_name, JackNoStartServer, &status);
    if (!c->jack_client) {
        snprintf(c->error, sizeof(c->error),
                 "jack_client_open échoué (status=%u). Jack est-il démarré?", status);
        return c;
    }

    // Store the name actually assigned by the Jack server (may differ from requested)
    const char *assigned = c->f_get_name(c->jack_client);
    if (assigned) strncpy(c->client_name, assigned, sizeof(c->client_name) - 1);

    return c;
}

void jm_client_close(JMClient *c) {
    if (!c) return;
    
    // CRITICAL: Signal teardown so all in-flight callbacks bail out immediately
    atomic_store(&c->is_closing, true);
    atomic_store(&c->is_active, false);

    // Release the timebase master role if we held it
    if (atomic_load(&c->is_timebase_master) && c->jack_client && c->f_release_timebase) {
        c->f_release_timebase(c->jack_client);
        atomic_store(&c->is_timebase_master, false);
    }
    
    // Nullify Swift callbacks before closing to prevent any further invocations
    c->port_reg_cb  = NULL;
    c->port_conn_cb = NULL;
    c->shutdown_cb  = NULL;
    
    // Deactivate the client (stops Jack from invoking any further callbacks)
    if (c->jack_client && c->f_deactivate) {
        c->f_deactivate(c->jack_client);

        // IMPORTANT: Brief sleep to let Jack's internal threads wind down.
        // Without this, jack_client_close can be called while a Jack thread is
        // still exiting, which causes a crash.
        usleep(50000);  // 50 ms
    }

    // Close the Jack client
    if (c->jack_client && c->f_close) {
        c->f_close(c->jack_client);
        c->jack_client = NULL;
    }

    // Close the library handle (must happen after the client is closed)
    if (c->lib_handle) {
        dlclose(c->lib_handle);
        c->lib_handle = NULL;
    }
    
    free(c);
}

int jm_client_activate(JMClient *c) {
    if (!c || !c->jack_client || !c->f_activate) return -1;

    // Register all callbacks before activating
    if (c->f_set_port_reg_cb)
        c->f_set_port_reg_cb(c->jack_client, _jm_port_reg_cb, c);
    if (c->f_set_port_conn_cb)
        c->f_set_port_conn_cb(c->jack_client, _jm_port_conn_cb, c);
    if (c->f_on_shutdown)
        c->f_on_shutdown(c->jack_client, _jm_shutdown_cb, c);
    
    // Xrun callback — ultra-lightweight, just an atomic counter increment
    if (c->f_set_xrun_cb)
        c->f_set_xrun_cb(c->jack_client, _jm_xrun_cb, c);

    // Process callback — snapshots transport state into atomics every audio cycle.
    // Must be registered BEFORE jack_activate().
    if (c->f_set_process_cb && c->f_transport_query)
        c->f_set_process_cb(c->jack_client, _jm_process_cb, c);

    int result = c->f_activate(c->jack_client);
    if (result == 0) {
        atomic_store(&c->is_active, true);
    }
    return result;
}

const char *jm_last_error(JMClient *c) {
    if (!c) return "Client nul";
    return c->error[0] ? c->error : NULL;
}

const char *jm_client_name(JMClient *c) {
    if (!c) return NULL;
    return c->client_name;
}

// ── Callbacks ─────────────────────────────────────────────────────────────────

void jm_set_port_registration_callback(JMClient *c,
                                        JMPortRegistrationCallback cb,
                                        void *context) {
    if (!c) return;
    c->port_reg_cb  = cb;
    c->port_reg_ctx = context;
}

void jm_set_port_connect_callback(JMClient *c,
                                   JMPortConnectCallback cb,
                                   void *context) {
    if (!c) return;
    c->port_conn_cb  = cb;
    c->port_conn_ctx = context;
}

void jm_set_shutdown_callback(JMClient *c,
                               JMShutdownCallback cb,
                               void *context) {
    if (!c) return;
    c->shutdown_cb  = cb;
    c->shutdown_ctx = context;
}

// ── Port enumeration ──────────────────────────────────────────────────────────

JMPortInfo *jm_get_ports(JMClient *c, int *out_count) {
    *out_count = 0;
    if (!c || !c->jack_client || !c->f_get_ports || !c->f_port_by_name) return NULL;
    if (atomic_load(&c->is_closing)) return NULL;

    const char **names = c->f_get_ports(c->jack_client, NULL, NULL, 0);
    if (!names) return NULL;

    int n = 0;
    while (names[n]) n++;
    if (n == 0) { c->f_free((void*)names); return NULL; }

    JMPortInfo *ports = (JMPortInfo *)calloc((size_t)n, sizeof(JMPortInfo));
    if (!ports) { c->f_free((void*)names); return NULL; }

    for (int i = 0; i < n; i++) {
        strncpy(ports[i].name, names[i], sizeof(ports[i].name) - 1);
        jm_parse_port_name(names[i],
                           ports[i].client_name, sizeof(ports[i].client_name),
                           ports[i].port_name,   sizeof(ports[i].port_name));

        void *port = c->f_port_by_name(c->jack_client, names[i]);
        if (port) {
            int flags = c->f_port_flags(port);
            ports[i].direction = (flags & JackPortIsInput)
                                 ? JMPortDirectionInput
                                 : JMPortDirectionOutput;
            const char *type_str = c->f_port_type(port);
            ports[i].type = jm_port_type_from_string(type_str);
        }
    }

    c->f_free((void*)names);
    *out_count = n;
    return ports;
}

void jm_free_ports(JMPortInfo *ports) {
    free(ports);
}

// ── Connection enumeration ────────────────────────────────────────────────────

JMConnection *jm_get_connections(JMClient *c, int *out_count) {
    *out_count = 0;
    if (!c || !c->jack_client || !c->f_get_ports ||
        !c->f_port_by_name || !c->f_port_get_conns) return NULL;
    if (atomic_load(&c->is_closing)) return NULL;

    const char **outputs = c->f_get_ports(c->jack_client, NULL, NULL, JackPortIsOutput);
    if (!outputs) return NULL;

    int capacity = 64;
    int idx = 0;
    JMConnection *result = (JMConnection *)calloc((size_t)capacity, sizeof(JMConnection));
    if (!result) { c->f_free((void*)outputs); return NULL; }

    for (int i = 0; outputs[i]; i++) {
        void *port = c->f_port_by_name(c->jack_client, outputs[i]);
        if (!port) continue;
        
        const char **conns = c->f_port_get_conns(port);
        if (!conns) continue;
        
        for (int j = 0; conns[j]; j++) {
            if (idx >= capacity) {
                capacity *= 2;
                JMConnection *tmp = (JMConnection *)realloc(result,
                    (size_t)capacity * sizeof(JMConnection));
                if (!tmp) {
                    c->f_free((void*)conns);
                    c->f_free((void*)outputs);
                    *out_count = idx;
                    return result;
                }
                result = tmp;
            }
            
            strncpy(result[idx].from, outputs[i], sizeof(result[idx].from) - 1);
            result[idx].from[sizeof(result[idx].from) - 1] = '\0';
            strncpy(result[idx].to, conns[j], sizeof(result[idx].to) - 1);
            result[idx].to[sizeof(result[idx].to) - 1] = '\0';
            idx++;
        }
        c->f_free((void*)conns);
    }

    c->f_free((void*)outputs);
    
    if (idx > 0 && idx < capacity) {
        JMConnection *tmp = (JMConnection *)realloc(result,
            (size_t)idx * sizeof(JMConnection));
        if (tmp) result = tmp;
    }
    
    *out_count = idx;
    return (idx > 0) ? result : (free(result), NULL);
}

void jm_free_connections(JMConnection *conns) {
    free(conns);
}

// ── Connect / Disconnect ──────────────────────────────────────────────────────

int jm_connect(JMClient *c, const char *from, const char *to) {
    if (!c || !c->jack_client || !c->f_connect) return -1;
    if (atomic_load(&c->is_closing)) return -1;
    return c->f_connect(c->jack_client, from, to);
}

int jm_disconnect(JMClient *c, const char *from, const char *to) {
    if (!c || !c->jack_client || !c->f_disconnect) return -1;
    if (atomic_load(&c->is_closing)) return -1;
    return c->f_disconnect(c->jack_client, from, to);
}

// ── Transport ─────────────────────────────────────────────────────────────────

// Internal process callback — invoked by Jack every audio cycle (RT thread).
// Snapshots transport state into atomics: zero IPC, zero malloc.
// The UI then reads those atomics via jm_get_transport_atomic() with no
// server calls — the pattern recommended by the JACK specification.
static int _jm_process_cb(jack_nframes_t nframes, void *arg) {
    (void)nframes;
    JMClient *c = (JMClient *)arg;
    if (!c || atomic_load_explicit(&c->is_closing, memory_order_relaxed)) return 0;
    if (!c->f_transport_query || !c->jack_client) return 0;

    jm_jack_position_t pos;
    jack_transport_state_t state = c->f_transport_query(c->jack_client, &pos);

    atomic_store_explicit(&c->tp_state,       (uint32_t)state,   memory_order_relaxed);
    atomic_store_explicit(&c->tp_frame,        pos.frame,        memory_order_relaxed);
    atomic_store_explicit(&c->tp_sample_rate,  pos.frame_rate,   memory_order_relaxed);

    int bbt = (pos.valid & JM_JACK_POSITION_BBT) != 0;
    atomic_store_explicit(&c->tp_bbt_valid, bbt, memory_order_relaxed);
    if (bbt) {
        atomic_store_explicit(&c->tp_bar,  pos.bar,  memory_order_relaxed);
        atomic_store_explicit(&c->tp_beat, pos.beat, memory_order_relaxed);
        atomic_store_explicit(&c->tp_tick, pos.tick, memory_order_relaxed);
        // BPM → integer * 10 (e.g. 120.5 → 1205) to avoid atomic<double>
        uint32_t bpm10 = (pos.beats_per_minute > 0)
                         ? (uint32_t)(pos.beats_per_minute * 10.0 + 0.5)
                         : 0u;
        atomic_store_explicit(&c->tp_bpm_x10, bpm10, memory_order_relaxed);
        int32_t bpb10 = (int32_t)(pos.beats_per_bar * 10.0f + 0.5f);
        atomic_store_explicit(&c->tp_bpb_x10, bpb10, memory_order_relaxed);
        int32_t bt10  = (int32_t)(pos.beat_type   * 10.0f + 0.5f);
        atomic_store_explicit(&c->tp_beat_type_x10, bt10, memory_order_relaxed);
    }

    return 0;  // 0 = OK, Jack continues processing
}

// Internal timebase callback — invoked by Jack from the RT thread every cycle
// when JackMate is the active timebase master.
// Fills pos->BBT from the current frame and the parameters stored in JMClient.
static void _jm_timebase_cb(jack_transport_state_t state,
                              jack_nframes_t nframes,
                              jm_jack_position_t *pos,
                              int new_pos,
                              void *arg) {
    (void)state; (void)nframes; (void)new_pos;
    JMClient *c = (JMClient *)arg;
    if (!c || !pos || atomic_load(&c->is_closing)) return;

    double bpm           = c->timebase_bpm;
    float  beats_per_bar = c->timebase_beats_per_bar;
    float  beat_type     = c->timebase_beat_type;
    if (bpm < 1.0) bpm = 120.0;

    double ticks_per_beat   = 1920.0;
    double frames_per_beat  = ((double)pos->frame_rate * 60.0) / bpm;
    double frames_per_tick  = frames_per_beat / ticks_per_beat;

    double total_ticks  = (double)pos->frame / frames_per_tick;
    uint32_t total_beats = (uint32_t)(total_ticks / ticks_per_beat);
    uint32_t bpb         = (beats_per_bar > 0) ? (uint32_t)beats_per_bar : 4;

    pos->valid           |= JM_JACK_POSITION_BBT;
    pos->bar              = (int32_t)(total_beats / bpb) + 1;
    pos->beat             = (int32_t)(total_beats % bpb) + 1;
    pos->tick             = (int32_t)(total_ticks - (double)total_beats * ticks_per_beat);
    pos->bar_start_tick   = (double)((pos->bar - 1) * bpb) * ticks_per_beat;
    pos->beats_per_bar    = beats_per_bar;
    pos->beat_type        = beat_type;
    pos->ticks_per_beat   = ticks_per_beat;
    pos->beats_per_minute = bpm;
}

JMTransportState jm_transport_query(JMClient *c, JMTransportPosition *out_pos) {
    if (!c || !c->jack_client || !c->f_transport_query) return JMTransportStopped;
    if (atomic_load(&c->is_closing)) return JMTransportStopped;

    jm_jack_position_t pos;
    jack_transport_state_t state = c->f_transport_query(c->jack_client, &pos);

    if (out_pos) {
        out_pos->frame       = pos.frame;
        out_pos->sample_rate = pos.frame_rate;
        out_pos->bbt_valid   = (pos.valid & JM_JACK_POSITION_BBT) != 0;
        if (out_pos->bbt_valid) {
            out_pos->bar           = pos.bar;
            out_pos->beat          = pos.beat;
            out_pos->tick          = pos.tick;
            out_pos->bpm           = pos.beats_per_minute;
            out_pos->beats_per_bar = pos.beats_per_bar;
            out_pos->beat_type     = pos.beat_type;
        } else {
            out_pos->bar = out_pos->beat = out_pos->tick = 0;
            out_pos->bpm = 0.0;
            out_pos->beats_per_bar = out_pos->beat_type = 0.0f;
        }
    }

    if (state == JM_JACK_TRANSPORT_ROLLING)  return JMTransportRolling;
    if (state == JM_JACK_TRANSPORT_STARTING) return JMTransportStarting;
    return JMTransportStopped;
}

/// Reads the transport cache kept up-to-date by _jm_process_cb (lock-free, zero IPC).
/// Safe to call from any thread — overhead ≈ a few nanoseconds.
JMTransportState jm_get_transport_atomic(JMClient *c, JMTransportPosition *out_pos) {
    if (!c) return JMTransportStopped;

    uint32_t state = atomic_load_explicit(&c->tp_state, memory_order_relaxed);

    if (out_pos) {
        out_pos->frame       = atomic_load_explicit(&c->tp_frame,       memory_order_relaxed);
        out_pos->sample_rate = atomic_load_explicit(&c->tp_sample_rate, memory_order_relaxed);
        int bbt              = atomic_load_explicit(&c->tp_bbt_valid,   memory_order_relaxed);
        out_pos->bbt_valid   = (bbt != 0);
        if (bbt) {
            out_pos->bar  = atomic_load_explicit(&c->tp_bar,  memory_order_relaxed);
            out_pos->beat = atomic_load_explicit(&c->tp_beat, memory_order_relaxed);
            out_pos->tick = atomic_load_explicit(&c->tp_tick, memory_order_relaxed);
            uint32_t bpm10 = atomic_load_explicit(&c->tp_bpm_x10,       memory_order_relaxed);
            int32_t  bpb10 = atomic_load_explicit(&c->tp_bpb_x10,       memory_order_relaxed);
            int32_t  bt10  = atomic_load_explicit(&c->tp_beat_type_x10, memory_order_relaxed);
            out_pos->bpm           = (double)bpm10 / 10.0;
            out_pos->beats_per_bar = (float)bpb10  / 10.0f;
            out_pos->beat_type     = (float)bt10   / 10.0f;
        } else {
            out_pos->bar = out_pos->beat = out_pos->tick = 0;
            out_pos->bpm = 0.0;
            out_pos->beats_per_bar = out_pos->beat_type = 0.0f;
        }
    }

    if (state == JM_JACK_TRANSPORT_ROLLING)  return JMTransportRolling;
    if (state == JM_JACK_TRANSPORT_STARTING) return JMTransportStarting;
    return JMTransportStopped;
}

void jm_transport_start(JMClient *c) {
    if (!c || !c->jack_client || !c->f_transport_start) return;
    if (atomic_load(&c->is_closing)) return;
    c->f_transport_start(c->jack_client);
}

void jm_transport_stop(JMClient *c) {
    if (!c || !c->jack_client || !c->f_transport_stop) return;
    if (atomic_load(&c->is_closing)) return;
    c->f_transport_stop(c->jack_client);
    // No rewind here — the Swift layer decides whether to rewind based on which button was pressed
}

void jm_transport_locate(JMClient *c, uint32_t frame) {
    if (!c || !c->jack_client || !c->f_transport_locate) return;
    if (atomic_load(&c->is_closing)) return;
    c->f_transport_locate(c->jack_client, (jack_nframes_t)frame);
}

uint32_t jm_get_sample_rate(JMClient *c) {
    if (!c || !c->jack_client || !c->f_get_sample_rate) return 44100;
    if (atomic_load(&c->is_closing)) return 44100;
    return (uint32_t)c->f_get_sample_rate(c->jack_client);
}

bool jm_set_timebase_master(JMClient *c, double bpm,
                              float beats_per_bar, float beat_type,
                              bool conditional) {
    if (!c || !c->jack_client || !c->f_set_timebase_cb) return false;
    if (atomic_load(&c->is_closing)) return false;

    c->timebase_bpm           = (bpm > 0) ? bpm : 120.0;
    c->timebase_beats_per_bar = (beats_per_bar > 0) ? beats_per_bar : 4.0f;
    c->timebase_beat_type     = (beat_type > 0) ? beat_type : 4.0f;

    int result = c->f_set_timebase_cb(c->jack_client,
                                       conditional ? 1 : 0,
                                       _jm_timebase_cb, c);
    bool ok = (result == 0);
    atomic_store(&c->is_timebase_master, ok);
    return ok;
}

void jm_update_timebase_bpm(JMClient *c, double bpm) {
    if (!c || !atomic_load(&c->is_timebase_master)) return;
    if (bpm > 0) c->timebase_bpm = bpm;
}

void jm_release_timebase(JMClient *c) {
    if (!c || !c->jack_client || !c->f_release_timebase) return;
    if (!atomic_load(&c->is_timebase_master)) return;
    if (atomic_load(&c->is_closing)) return;
    c->f_release_timebase(c->jack_client);
    atomic_store(&c->is_timebase_master, false);
}

bool jm_is_timebase_master(JMClient *c) {
    if (!c) return false;
    return atomic_load(&c->is_timebase_master);
}

// ── Xrun counter ──────────────────────────────────────────────────────────────

uint32_t jm_get_xrun_count(JMClient *c) {
    if (!c) return 0;
    return atomic_load(&c->xrun_count);
}

void jm_reset_xrun_count(JMClient *c) {
    if (!c) return;
    atomic_store(&c->xrun_count, 0);
}

// ── Client introspection ─────────────────────────────────────────────────────

int32_t jm_get_client_pid(JMClient *c, const char *client_name) {
    if (!c || !client_name || !c->f_get_client_pid) return -1;
    return (int32_t)c->f_get_client_pid(client_name);
}
