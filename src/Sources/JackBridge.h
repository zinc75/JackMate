//
//  JackBridge.h
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  C interface to libjack loaded at runtime via dlopen.
//  Avoids static linking against libjack — JackMate works even when
//  Jack is not installed (the sheet is presented instead).
//
//  v3 — Native xrun counter (Jack callback, no stderr parsing)
//

#ifndef JackBridge_h
#define JackBridge_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Opaque types ──────────────────────────────────────────────────────────────

typedef struct JMClient JMClient;

// ── Port types ────────────────────────────────────────────────────────────────

typedef enum {
    JMPortDirectionInput  = 0,
    JMPortDirectionOutput = 1
} JMPortDirection;

typedef enum {
    JMPortTypeAudio = 0,
    JMPortTypeMIDI  = 1,
    JMPortTypeCV    = 2,
    JMPortTypeOther = 3
} JMPortType;

typedef struct {
    char           name[256];        // full "client:port" name
    char           client_name[128]; // part before ':'
    char           port_name[128];   // part after ':'
    JMPortDirection direction;
    JMPortType      type;
} JMPortInfo;

typedef struct {
    char from[256];  // output port
    char to[256];    // input port
} JMConnection;

// ── Callbacks ─────────────────────────────────────────────────────────────────

/// Called when a port is registered or unregistered.
/// Warning: invoked from the Jack real-time thread.
typedef void (*JMPortRegistrationCallback)(const char *portName,
                                            bool registered,
                                            void *context);

/// Called when two ports are connected or disconnected.
/// Warning: invoked from the Jack real-time thread.
typedef void (*JMPortConnectCallback)(const char *portA,
                                       const char *portB,
                                       bool connected,
                                       void *context);

/// Called when the Jack server shuts down.
typedef void (*JMShutdownCallback)(void *context);

// ── Lifecycle ─────────────────────────────────────────────────────────────────

/// Opens a Jack client. Returns NULL on memory allocation failure.
/// Check jm_last_error() for connection errors.
/// @param client_name Desired client name (may be modified by Jack if taken).
/// @param lib_path    Path to libjack.dylib, or NULL for automatic discovery.
JMClient *jm_client_open(const char *client_name, const char *lib_path);

/// Closes the Jack client and frees all resources.
void jm_client_close(JMClient *c);

/// Activates the client (starts callbacks).
/// @return 0 on success, -1 on error.
int jm_client_activate(JMClient *c);

/// Returns the last error message, or NULL if none.
const char *jm_last_error(JMClient *c);

/// Returns the effective client name as assigned by Jack.
const char *jm_client_name(JMClient *c);

// ── Callback registration ─────────────────────────────────────────────────────

void jm_set_port_registration_callback(JMClient *c,
                                        JMPortRegistrationCallback cb,
                                        void *context);

void jm_set_port_connect_callback(JMClient *c,
                                   JMPortConnectCallback cb,
                                   void *context);

void jm_set_shutdown_callback(JMClient *c,
                               JMShutdownCallback cb,
                               void *context);

// ── Port and connection queries ───────────────────────────────────────────────

/// Returns all visible ports. Caller must call jm_free_ports() when done.
JMPortInfo *jm_get_ports(JMClient *c, int *out_count);
void jm_free_ports(JMPortInfo *ports);

/// Returns all active connections. Caller must call jm_free_connections() when done.
JMConnection *jm_get_connections(JMClient *c, int *out_count);
void jm_free_connections(JMConnection *conns);

// ── Connection management ─────────────────────────────────────────────────────

/// Connects two ports. @return 0 on success.
int jm_connect(JMClient *c, const char *from, const char *to);

/// Disconnects two ports. @return 0 on success.
int jm_disconnect(JMClient *c, const char *from, const char *to);

// ── Xrun counter ──────────────────────────────────────────────────────────────

/// Returns the xrun count since the last reset.
/// Thread-safe and lock-free (atomic counter).
uint32_t jm_get_xrun_count(JMClient *c);

/// Resets the xrun counter to zero.
void jm_reset_xrun_count(JMClient *c);

// ── Transport ──────────────────────────────────────────────────────────────────

typedef enum {
    JMTransportStopped  = 0,
    JMTransportRolling  = 1,
    JMTransportStarting = 3
} JMTransportState;

/// Complete transport position snapshot.
/// bbt_valid is false when no timebase master is active.
typedef struct {
    uint32_t frame;           // current position in samples
    uint32_t sample_rate;     // server sample rate in Hz
    int32_t  bar;             // current bar (1-based)
    int32_t  beat;            // beat within the bar (1-based)
    int32_t  tick;            // tick within the beat
    double   bpm;             // tempo in BPM (0 if no timebase master)
    float    beats_per_bar;   // time signature numerator
    float    beat_type;       // time signature denominator
    bool     bbt_valid;       // true when a timebase master provides BBT
} JMTransportPosition;

/// Queries Jack directly for the transport state; fills out_pos (may be NULL).
/// Prefer jm_get_transport_atomic() for UI polling to avoid IPC overhead.
JMTransportState jm_transport_query(JMClient *c, JMTransportPosition *out_pos);

/// Reads the transport state from the lock-free atomic cache updated by the process callback.
/// Zero IPC, zero server overhead — safe to call from any thread.
JMTransportState jm_get_transport_atomic(JMClient *c, JMTransportPosition *out_pos);

/// Starts the Jack transport.
void jm_transport_start(JMClient *c);

/// Stops the Jack transport (does not rewind — use jm_transport_locate to rewind).
void jm_transport_stop(JMClient *c);

/// Repositions the transport to an absolute frame offset (does not change play/stop state).
void jm_transport_locate(JMClient *c, uint32_t frame);

/// Returns the Jack server sample rate in Hz.
uint32_t jm_get_sample_rate(JMClient *c);

/// Attempts to become the Jack timebase master.
/// @param conditional  If true, fails silently when another master is already active.
/// @return true if JackMate is now the timebase master.
bool jm_set_timebase_master(JMClient *c, double bpm,
                             float beats_per_bar, float beat_type,
                             bool conditional);

/// Updates the BPM while holding the timebase master role (no-op otherwise).
void jm_update_timebase_bpm(JMClient *c, double bpm);

/// Releases the timebase master role.
void jm_release_timebase(JMClient *c);

/// Returns true if JackMate is currently the active timebase master.
bool jm_is_timebase_master(JMClient *c);

// ── Client introspection ─────────────────────────────────────────────────────

/// Returns the PID of a Jack client by name, or -1 if unavailable.
/// Requires jack_get_client_pid (JACK_OPTIONAL_WEAK_EXPORT in Jack2).
int32_t jm_get_client_pid(JMClient *c, const char *client_name);

#ifdef __cplusplus
}
#endif

#endif /* JackBridge_h */
