// CPancakeRT — the realtime half of pancake.
//
// One IOProc, installed on the engine's private aggregate device, applies a routing
// matrix over the aggregate's AudioBufferLists. The matrix is published with an
// atomic pointer swap so gains and routes can change without stopping IO.
//
// Rules on this side of the fence: no allocation, no locks, no Objective-C, no Swift.

#ifndef CPANCAKERT_H
#define CPANCAKERT_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Recorders: sink nodes that aren't devices. A route whose `out_buffer` has PK_REC_FLAG set
/// targets recorder `out_buffer & ~PK_REC_FLAG` instead of an aggregate output stream — the IOProc
/// mixes into that recorder's per-cycle scratch and, while armed, pushes the result into a lock-free
/// ring the drain side reads with pk_recorder_read. Everything is preallocated at context creation,
/// so arming/recording adds no allocation or locks to the IOProc.
#define PK_MAX_RECORDERS      4u
#define PK_REC_CHANNELS       2u          /* recorders are stereo (the mix caps at two channels) */
#define PK_REC_FLAG           0x80000000u /* set on pk_route.out_buffer to mean "recorder index"  */
#define PK_REC_RING_FRAMES    262144u     /* per-recorder ring, ~5.46 s @48k (power of two)        */
#define PK_REC_MAX_CYCLE_FRAMES 8192u     /* scratch is sized for this many frames per IO cycle    */

/// Buses: summing nodes with an intermediate mix buffer. A route whose `out_buffer` has PK_BUS_FLAG
/// set mixes into bus `out_buffer & ~PK_BUS_FLAG`; a route whose `in_buffer` has it set reads from
/// that bus. Between the two, the bus is *processed* in place — the self-authored compressor and a
/// trim — which is why a bus exists at all (the matrix already sums). Bus scratch is preallocated at
/// context creation; the compressor's state (its envelope) lives in the context so a parameter change
/// (a new matrix) never resets it.
#define PK_MAX_BUSES          8u
#define PK_BUS_CHANNELS       2u          /* buses are stereo, like recorders                      */
#define PK_BUS_FLAG           0x40000000u /* set on pk_route.in_buffer / out_buffer: "bus index"   */

/// One mono connection inside an IO cycle:
///   out[out_buffer].channel[out_channel] += in[in_buffer].channel[in_channel] * gain
/// Buffers are indices into the aggregate's input / output AudioBufferList; channels
/// are interleaved within a buffer. If `out_buffer & PK_REC_FLAG`, the destination is a recorder
/// (see above) rather than an output stream; if either side carries PK_BUS_FLAG, that side is a bus.
typedef struct pk_route {
    uint32_t in_buffer;
    uint32_t in_channel;
    uint32_t out_buffer;
    uint32_t out_channel;
    float    gain;
} pk_route;

/// Per-bus processing, baked for one sample rate by the compiler (coefficients, not milliseconds —
/// the IOProc does no math it doesn't have to). A feed-forward, stereo-linked, peak-sensing
/// compressor with a soft knee, gain smoothed in the log domain (attack when reduction grows,
/// release when it shrinks), then makeup, then trim.
typedef struct pk_bus_params {
    uint32_t active;        /* the bus slot is in use by this matrix (its scratch is cleared + processed) */
    uint32_t comp_enabled;
    float    threshold_db;  /* dBFS                                                    */
    float    ratio;         /* ≥ 1                                                     */
    float    knee_db;       /* soft-knee width in dB, 0 = hard knee                    */
    float    attack_coef;   /* per-sample one-pole coefficient, 0 = instant            */
    float    release_coef;
    float    makeup;        /* linear, applied with the compressor                     */
    float    trim;          /* linear, always applied (the bus's own master gain)      */
} pk_bus_params;

/// A routing program. Evaluated in stages so a bus is fully summed before it's processed and read:
///   1. routes[0 .. stage1_count) — every route that reads a device/tap input (they may target
///      buses, recorders or outputs).
///   2. for k in 0 .. bus_count: bus `bus_order[k]` is processed in place, then the routes in
///      [previous end, bus_seg_end[k]) — every route reading from that bus — run. The compiler
///      orders buses so a bus feeding another bus is processed first (bus→bus is a DAG).
typedef struct pk_matrix {
    uint32_t  route_count;
    pk_route* _Nullable routes;
    uint32_t  stage1_count;
    uint32_t  bus_count;
    uint32_t  bus_order[PK_MAX_BUSES];
    uint32_t  bus_seg_end[PK_MAX_BUSES];
    pk_bus_params bus[PK_MAX_BUSES];
} pk_matrix;

typedef struct pk_stats {
    uint64_t cycles;                 // IO cycles seen since the context was created
    uint64_t frames;                 // frames processed
    uint32_t last_frames;            // frames in the most recent cycle
    uint32_t last_in_buffers;        // buffers in the most recent input ABL
    uint32_t last_out_buffers;       // buffers in the most recent output ABL
    uint64_t cycles_without_matrix;  // cycles that ran with no matrix installed (silence)
    uint64_t routes_skipped;         // route evaluations that fell outside the ABLs seen
} pk_stats;

/// Input buffers beyond this index aren't metered.
#define PK_METER_BUFFERS 16

typedef struct pk_context pk_context;

pk_context* _Nullable pk_context_create(void);
void        pk_context_destroy(pk_context* _Nullable ctx);

/// A fresh matrix runs every route in stage 1 (no buses) until pk_matrix_set_stages says otherwise.
pk_matrix* _Nullable pk_matrix_alloc(uint32_t route_count);
void        pk_matrix_free(pk_matrix* _Nullable m);
/// Describe the bus stages: `order` lists bus slots in evaluation order, `seg_end[k]` is the index one
/// past the last route reading from `order[k]` (routes must already be sorted into these segments).
void        pk_matrix_set_stages(pk_matrix* _Nonnull m, uint32_t stage1_count, uint32_t bus_count,
                                 const uint32_t* _Nullable order, const uint32_t* _Nullable seg_end);
void        pk_matrix_set_bus(pk_matrix* _Nonnull m, uint32_t slot, pk_bus_params params);

/// Publishes `m` (may be NULL) to the IO thread and returns the previous matrix.
/// The returned matrix may still be mid-use for one more cycle: free it only after
/// pk_context_cycles() has advanced past the value it had at the swap, or once the
/// IOProc has been stopped.
pk_matrix* _Nullable pk_context_swap_matrix(pk_context* _Nonnull ctx, pk_matrix* _Nullable m);
uint64_t    pk_context_cycles(const pk_context* _Nonnull ctx);
/// Peak absolute sample value seen in input buffer `buffer` during the last cycle (0 if unmetered).
float       pk_context_input_peak(const pk_context* _Nonnull ctx, uint32_t buffer);
/// Peak absolute sample value *written* to output buffer `buffer` in the last cycle — i.e. what
/// the routing matrix produced for that device. Proves we're feeding a device even if it's mute.
float       pk_context_output_peak(const pk_context* _Nonnull ctx, uint32_t buffer);
void        pk_context_get_stats(const pk_context* _Nonnull ctx, pk_stats* _Nonnull out);

// MARK: - Recorders (RT-safe capture to a ring the drain side writes to disk)

/// Mark a recorder slot in use (routes may target it). Off means the IOProc ignores it entirely.
/// Safe to call from the engine while IO runs — it only flips an atomic.
void        pk_recorder_set_active(pk_context* _Nonnull ctx, uint32_t index, int active);
/// Begin capture on a slot: resets the ring cursors and arms it. Call while the drain side is not
/// mid-read (the engine serializes this with start/stop of its writer).
void        pk_recorder_start(pk_context* _Nonnull ctx, uint32_t index);
/// Stop capture (the IOProc stops pushing; already-captured frames stay in the ring to be drained).
void        pk_recorder_stop(pk_context* _Nonnull ctx, uint32_t index);
/// Drain side: copy up to `max_frames` of interleaved stereo (PK_REC_CHANNELS) from the ring into
/// `dst`, advancing the read cursor. Returns frames copied (0 if none available). Single consumer.
uint32_t    pk_recorder_read(pk_context* _Nonnull ctx, uint32_t index, float* _Nonnull dst, uint32_t max_frames);
/// Total frames the IOProc has captured on this slot since the last start (for elapsed time).
uint64_t    pk_recorder_captured_frames(const pk_context* _Nonnull ctx, uint32_t index);
/// Frames dropped because the drain side fell behind (should stay zero; a warning signal if not).
uint64_t    pk_recorder_overrun_frames(const pk_context* _Nonnull ctx, uint32_t index);

// MARK: - Buses

/// The most gain reduction (dB, ≤ 0) the bus's compressor applied during the last cycle — a meter.
float       pk_bus_gain_reduction_db(const pk_context* _Nonnull ctx, uint32_t index);
/// Peak absolute sample value on the bus after processing, last cycle.
float       pk_bus_peak(const pk_context* _Nonnull ctx, uint32_t index);

/// The IOProc. `inClientData` must be the pk_context*. Expects every stream in
/// Float32 interleaved format (the HAL's default client format); the engine
/// verifies that before starting IO.
OSStatus pk_ioproc(AudioObjectID inDevice,
                   const AudioTimeStamp* _Nonnull inNow,
                   const AudioBufferList* _Nonnull inInputData,
                   const AudioTimeStamp* _Nonnull inInputTime,
                   AudioBufferList* _Nonnull outOutputData,
                   const AudioTimeStamp* _Nonnull inOutputTime,
                   void* _Nullable inClientData);

#ifdef __cplusplus
}
#endif

#endif /* CPANCAKERT_H */
