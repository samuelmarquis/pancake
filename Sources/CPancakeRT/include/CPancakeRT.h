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

/// One mono connection inside an IO cycle:
///   out[out_buffer].channel[out_channel] += in[in_buffer].channel[in_channel] * gain
/// Buffers are indices into the aggregate's input / output AudioBufferList; channels
/// are interleaved within a buffer.
typedef struct pk_route {
    uint32_t in_buffer;
    uint32_t in_channel;
    uint32_t out_buffer;
    uint32_t out_channel;
    float    gain;
} pk_route;

typedef struct pk_matrix {
    uint32_t  route_count;
    pk_route* _Nullable routes;
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

pk_matrix* _Nullable pk_matrix_alloc(uint32_t route_count);
void        pk_matrix_free(pk_matrix* _Nullable m);

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
