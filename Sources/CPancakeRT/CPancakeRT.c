#include "CPancakeRT.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

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
    return calloc(1, sizeof(pk_context));
}

void pk_context_destroy(pk_context* ctx)
{
    if (!ctx) return;
    pk_matrix* m = atomic_exchange_explicit(&ctx->matrix, NULL, memory_order_acq_rel);
    pk_matrix_free(m);
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

    pk_matrix* m = atomic_load_explicit(&ctx->matrix, memory_order_acquire);
    if (!m) {
        atomic_fetch_add_explicit(&ctx->cycles_without_matrix, 1, memory_order_relaxed);
    } else if (inInputData && outOutputData) {
        uint64_t skipped = 0;
        for (uint32_t i = 0; i < m->route_count; i++) {
            const pk_route r = m->routes[i];
            if (r.in_buffer >= inInputData->mNumberBuffers || r.out_buffer >= outOutputData->mNumberBuffers) { skipped++; continue; }
            const AudioBuffer* ib = &inInputData->mBuffers[r.in_buffer];
            AudioBuffer* ob = &outOutputData->mBuffers[r.out_buffer];
            if (!ib->mData || !ob->mData) { skipped++; continue; }
            if (r.in_channel >= ib->mNumberChannels || r.out_channel >= ob->mNumberChannels) { skipped++; continue; }
            uint32_t n = frames_in(ib);
            uint32_t no = frames_in(ob);
            if (no < n) n = no;
            if (!n || r.gain == 0.0f) continue;

            const float* src = (const float*)ib->mData + r.in_channel;
            float* dst = (float*)ob->mData + r.out_channel;
            const uint32_t is = ib->mNumberChannels;
            const uint32_t os = ob->mNumberChannels;
            const float g = r.gain;
            for (uint32_t f = 0; f < n; f++) {
                dst[f * os] += src[f * is] * g;
            }
        }
        if (skipped) atomic_fetch_add_explicit(&ctx->routes_skipped, skipped, memory_order_relaxed);
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
