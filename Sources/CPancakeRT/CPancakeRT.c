#include "CPancakeRT.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/// One recorder slot. `ring`/`scratch` are allocated once at context creation, never in the IOProc.
/// The IOProc is the single producer (writes `scratch`, pushes to `ring`, advances write_frames);
/// pk_recorder_read is the single consumer (reads `ring`, advances read_frames). Classic SPSC.
typedef struct pk_recorder {
    _Atomic uint32_t active;         // routes may target this slot
    _Atomic uint32_t armed;          // currently capturing (IOProc pushes to the ring)
    _Atomic uint64_t write_frames;   // frames the IOProc has pushed since start (monotonic)
    _Atomic uint64_t read_frames;    // frames the drain side has consumed
    _Atomic uint64_t overrun_frames; // frames dropped because the reader fell behind
    float* _Nullable ring;           // PK_REC_RING_FRAMES * PK_REC_CHANNELS, interleaved
    float* _Nullable scratch;        // PK_REC_MAX_CYCLE_FRAMES * PK_REC_CHANNELS, this cycle's mix
} pk_recorder;

struct pk_context {
    _Atomic(pk_matrix*) matrix;
    _Atomic uint64_t    cycles;
    _Atomic uint64_t    frames;
    _Atomic uint32_t    last_frames;
    _Atomic uint32_t    last_in_buffers;
    _Atomic uint32_t    last_out_buffers;
    _Atomic uint64_t    cycles_without_matrix;
    _Atomic uint64_t    routes_skipped;
    _Atomic uint32_t    in_peak_bits[PK_METER_BUFFERS];   // float bits; atomics on floats aren't portable
    _Atomic uint32_t    out_peak_bits[PK_METER_BUFFERS];
    pk_recorder         recorders[PK_MAX_RECORDERS];
};

static inline float buffer_peak(const AudioBuffer* b)
{
    float peak = 0.0f;
    if (!b->mData) return peak;
    const float* p = (const float*)b->mData;
    uint32_t n = b->mDataByteSize / (uint32_t)sizeof(float);
    for (uint32_t i = 0; i < n; i++) {
        float v = p[i] < 0 ? -p[i] : p[i];
        if (v > peak) peak = v;
    }
    return peak;
}

static inline float bits_to_float(uint32_t b) { float f; memcpy(&f, &b, sizeof f); return f; }
static inline uint32_t float_to_bits(float f) { uint32_t b; memcpy(&b, &f, sizeof b); return b; }

pk_context* pk_context_create(void)
{
    pk_context* ctx = calloc(1, sizeof(pk_context));
    if (!ctx) return NULL;
    // Preallocate every recorder's ring + scratch once, so arming/recording never allocates.
    for (uint32_t i = 0; i < PK_MAX_RECORDERS; i++) {
        ctx->recorders[i].ring    = calloc((size_t)PK_REC_RING_FRAMES * PK_REC_CHANNELS, sizeof(float));
        ctx->recorders[i].scratch = calloc((size_t)PK_REC_MAX_CYCLE_FRAMES * PK_REC_CHANNELS, sizeof(float));
        if (!ctx->recorders[i].ring || !ctx->recorders[i].scratch) { pk_context_destroy(ctx); return NULL; }
    }
    return ctx;
}

void pk_context_destroy(pk_context* ctx)
{
    if (!ctx) return;
    pk_matrix* m = atomic_exchange_explicit(&ctx->matrix, NULL, memory_order_acq_rel);
    pk_matrix_free(m);
    for (uint32_t i = 0; i < PK_MAX_RECORDERS; i++) {
        free(ctx->recorders[i].ring);
        free(ctx->recorders[i].scratch);
    }
    free(ctx);
}

pk_matrix* pk_matrix_alloc(uint32_t route_count)
{
    pk_matrix* m = calloc(1, sizeof(pk_matrix));
    if (!m) return NULL;
    m->route_count = route_count;
    if (route_count) {
        m->routes = calloc(route_count, sizeof(pk_route));
        if (!m->routes) { free(m); return NULL; }
    }
    return m;
}

void pk_matrix_free(pk_matrix* m)
{
    if (!m) return;
    free(m->routes);
    free(m);
}

pk_matrix* pk_context_swap_matrix(pk_context* ctx, pk_matrix* m)
{
    return atomic_exchange_explicit(&ctx->matrix, m, memory_order_acq_rel);
}

uint64_t pk_context_cycles(const pk_context* ctx)
{
    return atomic_load_explicit(&ctx->cycles, memory_order_relaxed);
}

float pk_context_input_peak(const pk_context* ctx, uint32_t buffer)
{
    if (!ctx || buffer >= PK_METER_BUFFERS) return 0.0f;
    return bits_to_float(atomic_load_explicit(&ctx->in_peak_bits[buffer], memory_order_relaxed));
}

float pk_context_output_peak(const pk_context* ctx, uint32_t buffer)
{
    if (!ctx || buffer >= PK_METER_BUFFERS) return 0.0f;
    return bits_to_float(atomic_load_explicit(&ctx->out_peak_bits[buffer], memory_order_relaxed));
}

void pk_context_get_stats(const pk_context* ctx, pk_stats* out)
{
    if (!ctx || !out) return;
    out->cycles                = atomic_load_explicit(&ctx->cycles, memory_order_relaxed);
    out->frames                = atomic_load_explicit(&ctx->frames, memory_order_relaxed);
    out->last_frames           = atomic_load_explicit(&ctx->last_frames, memory_order_relaxed);
    out->last_in_buffers       = atomic_load_explicit(&ctx->last_in_buffers, memory_order_relaxed);
    out->last_out_buffers      = atomic_load_explicit(&ctx->last_out_buffers, memory_order_relaxed);
    out->cycles_without_matrix = atomic_load_explicit(&ctx->cycles_without_matrix, memory_order_relaxed);
    out->routes_skipped        = atomic_load_explicit(&ctx->routes_skipped, memory_order_relaxed);
}

// MARK: - Recorders

void pk_recorder_set_active(pk_context* ctx, uint32_t index, int active)
{
    if (!ctx || index >= PK_MAX_RECORDERS) return;
    atomic_store_explicit(&ctx->recorders[index].active, active ? 1u : 0u, memory_order_release);
}

void pk_recorder_start(pk_context* ctx, uint32_t index)
{
    if (!ctx || index >= PK_MAX_RECORDERS) return;
    pk_recorder* rec = &ctx->recorders[index];
    atomic_store_explicit(&rec->armed, 0u, memory_order_release);          // stop any push first
    atomic_store_explicit(&rec->write_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&rec->read_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&rec->overrun_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&rec->armed, 1u, memory_order_release);          // cursors visible before armed
}

void pk_recorder_stop(pk_context* ctx, uint32_t index)
{
    if (!ctx || index >= PK_MAX_RECORDERS) return;
    atomic_store_explicit(&ctx->recorders[index].armed, 0u, memory_order_release);
}

uint32_t pk_recorder_read(pk_context* ctx, uint32_t index, float* dst, uint32_t max_frames)
{
    if (!ctx || index >= PK_MAX_RECORDERS || !dst || !max_frames) return 0;
    pk_recorder* rec = &ctx->recorders[index];
    if (!rec->ring) return 0;
    const uint64_t w  = atomic_load_explicit(&rec->write_frames, memory_order_acquire);
    const uint64_t rd = atomic_load_explicit(&rec->read_frames, memory_order_relaxed);
    const uint64_t avail = w - rd;
    if (avail == 0) return 0;
    uint32_t n = avail > max_frames ? max_frames : (uint32_t)avail;
    const uint32_t off = (uint32_t)(rd & (PK_REC_RING_FRAMES - 1));
    uint32_t first = PK_REC_RING_FRAMES - off;
    if (first > n) first = n;
    memcpy(dst, rec->ring + (size_t)off * PK_REC_CHANNELS, (size_t)first * PK_REC_CHANNELS * sizeof(float));
    if (first < n)
        memcpy(dst + (size_t)first * PK_REC_CHANNELS, rec->ring, (size_t)(n - first) * PK_REC_CHANNELS * sizeof(float));
    atomic_store_explicit(&rec->read_frames, rd + n, memory_order_release);
    return n;
}

uint64_t pk_recorder_captured_frames(const pk_context* ctx, uint32_t index)
{
    if (!ctx || index >= PK_MAX_RECORDERS) return 0;
    return atomic_load_explicit(&ctx->recorders[index].write_frames, memory_order_relaxed);
}

uint64_t pk_recorder_overrun_frames(const pk_context* ctx, uint32_t index)
{
    if (!ctx || index >= PK_MAX_RECORDERS) return 0;
    return atomic_load_explicit(&ctx->recorders[index].overrun_frames, memory_order_relaxed);
}

static inline uint32_t frames_in(const AudioBuffer* b)
{
    uint32_t ch = b->mNumberChannels ? b->mNumberChannels : 1;
    return b->mDataByteSize / (ch * (uint32_t)sizeof(float));
}

OSStatus pk_ioproc(AudioObjectID inDevice,
                   const AudioTimeStamp* _Nonnull inNow,
                   const AudioBufferList* _Nonnull inInputData,
                   const AudioTimeStamp* _Nonnull inInputTime,
                   AudioBufferList* _Nonnull outOutputData,
                   const AudioTimeStamp* _Nonnull inOutputTime,
                   void* _Nullable inClientData)
{
    (void)inDevice; (void)inNow; (void)inInputTime; (void)inOutputTime;
    pk_context* ctx = (pk_context*)inClientData;
    if (!ctx) return noErr;

    // Silence every output buffer first; routes accumulate into them, so an
    // unrouted output channel is silent rather than stale.
    uint32_t frames = 0;
    if (outOutputData) {
        for (UInt32 b = 0; b < outOutputData->mNumberBuffers; b++) {
            AudioBuffer* ob = &outOutputData->mBuffers[b];
            if (ob->mData && ob->mDataByteSize) memset(ob->mData, 0, ob->mDataByteSize);
            if (!frames) frames = frames_in(ob);
        }
    }
    if (!frames && inInputData && inInputData->mNumberBuffers) {
        frames = frames_in(&inInputData->mBuffers[0]);
    }

    // Meter the inputs: one max-abs per buffer, so the engine can tell silence from signal
    // (used to decide when it's worth chasing a Bluetooth device that walked away).
    if (inInputData) {
        UInt32 nb = inInputData->mNumberBuffers < PK_METER_BUFFERS ? inInputData->mNumberBuffers : PK_METER_BUFFERS;
        for (UInt32 b = 0; b < nb; b++) {
            atomic_store_explicit(&ctx->in_peak_bits[b], float_to_bits(buffer_peak(&inInputData->mBuffers[b])), memory_order_relaxed);
        }
    }

    // Clear each active recorder's per-cycle scratch (recorder routes accumulate into it, like an
    // output buffer). Bounded to the scratch capacity.
    const uint32_t rec_frames = frames > PK_REC_MAX_CYCLE_FRAMES ? PK_REC_MAX_CYCLE_FRAMES : frames;
    for (uint32_t ri = 0; ri < PK_MAX_RECORDERS; ri++) {
        pk_recorder* rec = &ctx->recorders[ri];
        if (rec->scratch && atomic_load_explicit(&rec->active, memory_order_relaxed)) {
            memset(rec->scratch, 0, (size_t)rec_frames * PK_REC_CHANNELS * sizeof(float));
        }
    }

    pk_matrix* m = atomic_load_explicit(&ctx->matrix, memory_order_acquire);
    if (!m) {
        atomic_fetch_add_explicit(&ctx->cycles_without_matrix, 1, memory_order_relaxed);
    } else if (inInputData && outOutputData) {
        uint64_t skipped = 0;
        for (uint32_t i = 0; i < m->route_count; i++) {
            const pk_route r = m->routes[i];
            if (r.in_buffer >= inInputData->mNumberBuffers) { skipped++; continue; }
            const AudioBuffer* ib = &inInputData->mBuffers[r.in_buffer];
            if (!ib->mData || r.in_channel >= ib->mNumberChannels) { skipped++; continue; }
            const uint32_t is = ib->mNumberChannels;
            const float* src = (const float*)ib->mData + r.in_channel;
            const float g = r.gain;
            const uint32_t n_in = frames_in(ib);

            if (r.out_buffer & PK_REC_FLAG) {
                // Recorder destination: mix into its stereo scratch.
                const uint32_t ri = r.out_buffer & ~PK_REC_FLAG;
                if (ri >= PK_MAX_RECORDERS || r.out_channel >= PK_REC_CHANNELS) { skipped++; continue; }
                pk_recorder* rec = &ctx->recorders[ri];
                if (!rec->scratch || !atomic_load_explicit(&rec->active, memory_order_relaxed)) { skipped++; continue; }
                uint32_t n = n_in < rec_frames ? n_in : rec_frames;
                if (!n || g == 0.0f) continue;
                float* dst = rec->scratch + r.out_channel;
                for (uint32_t f = 0; f < n; f++) dst[f * PK_REC_CHANNELS] += src[f * is] * g;
            } else {
                // Aggregate output stream.
                if (r.out_buffer >= outOutputData->mNumberBuffers) { skipped++; continue; }
                AudioBuffer* ob = &outOutputData->mBuffers[r.out_buffer];
                if (!ob->mData || r.out_channel >= ob->mNumberChannels) { skipped++; continue; }
                uint32_t n = n_in;
                uint32_t no = frames_in(ob);
                if (no < n) n = no;
                if (!n || g == 0.0f) continue;
                float* dst = (float*)ob->mData + r.out_channel;
                const uint32_t os = ob->mNumberChannels;
                for (uint32_t f = 0; f < n; f++) dst[f * os] += src[f * is] * g;
            }
        }
        if (skipped) atomic_fetch_add_explicit(&ctx->routes_skipped, skipped, memory_order_relaxed);
    }

    // Push armed recorders' scratch into their rings (single producer). Drop-and-count on overrun,
    // which only happens if the drain side stalls for seconds.
    for (uint32_t ri = 0; ri < PK_MAX_RECORDERS; ri++) {
        pk_recorder* rec = &ctx->recorders[ri];
        if (!rec->ring || !rec->scratch || !rec_frames) continue;
        if (!atomic_load_explicit(&rec->armed, memory_order_acquire)) continue;
        const uint64_t w  = atomic_load_explicit(&rec->write_frames, memory_order_relaxed);
        const uint64_t rd = atomic_load_explicit(&rec->read_frames, memory_order_acquire);
        if ((w - rd) + rec_frames > PK_REC_RING_FRAMES) {
            atomic_fetch_add_explicit(&rec->overrun_frames, rec_frames, memory_order_relaxed);
            continue;
        }
        const uint32_t off = (uint32_t)(w & (PK_REC_RING_FRAMES - 1));
        uint32_t first = PK_REC_RING_FRAMES - off;
        if (first > rec_frames) first = rec_frames;
        memcpy(rec->ring + (size_t)off * PK_REC_CHANNELS, rec->scratch, (size_t)first * PK_REC_CHANNELS * sizeof(float));
        if (first < rec_frames)
            memcpy(rec->ring, rec->scratch + (size_t)first * PK_REC_CHANNELS, (size_t)(rec_frames - first) * PK_REC_CHANNELS * sizeof(float));
        atomic_store_explicit(&rec->write_frames, w + rec_frames, memory_order_release);
    }

    if (outOutputData) {
        UInt32 nb = outOutputData->mNumberBuffers < PK_METER_BUFFERS ? outOutputData->mNumberBuffers : PK_METER_BUFFERS;
        for (UInt32 b = 0; b < nb; b++) {
            atomic_store_explicit(&ctx->out_peak_bits[b], float_to_bits(buffer_peak(&outOutputData->mBuffers[b])), memory_order_relaxed);
        }
    }

    atomic_fetch_add_explicit(&ctx->cycles, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&ctx->frames, frames, memory_order_relaxed);
    atomic_store_explicit(&ctx->last_frames, frames, memory_order_relaxed);
    atomic_store_explicit(&ctx->last_in_buffers, inInputData ? inInputData->mNumberBuffers : 0, memory_order_relaxed);
    atomic_store_explicit(&ctx->last_out_buffers, outOutputData ? outOutputData->mNumberBuffers : 0, memory_order_relaxed);
    return noErr;
}
