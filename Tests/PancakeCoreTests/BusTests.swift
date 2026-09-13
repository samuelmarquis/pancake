import CoreAudio
import CPancakeRT
import Testing

/// Proves the bus path inside `pk_ioproc`: two inputs summed into a bus, the bus fanned to an output
/// and a recorder, sample-exact with the compressor off; and the compressor itself — gain reduction
/// above threshold, nothing below, meter reporting what it did.
@Suite struct BusTests {
    private func matrix(_ rs: [(UInt32, UInt32, UInt32, UInt32, Float)], stage1: Int, order: [UInt32], ends: [UInt32],
                        buses: [(UInt32, pk_bus_params)]) -> UnsafeMutablePointer<pk_matrix>? {
        guard let m = pk_matrix_alloc(UInt32(rs.count)), let slots = m.pointee.routes else { return nil }
        for (i, r) in rs.enumerated() {
            slots[i] = pk_route(in_buffer: r.0, in_channel: r.1, out_buffer: r.2, out_channel: r.3, gain: r.4)
        }
        pk_matrix_set_stages(m, UInt32(stage1), UInt32(order.count), order, ends)
        for (slot, p) in buses { pk_matrix_set_bus(m, slot, p) }
        return m
    }

    private func params(comp: Bool = false, threshold: Float = -18, ratio: Float = 4, knee: Float = 0,
                        attack: Float = 0, release: Float = 0, makeup: Float = 1, trim: Float = 1) -> pk_bus_params {
        pk_bus_params(active: 1, comp_enabled: comp ? 1 : 0, threshold_db: threshold, ratio: ratio, knee_db: knee,
                      attack_coef: attack, release_coef: release, makeup: makeup, trim: trim)
    }

    /// Runs one cycle: 2 mono input buffers (values a, b), 1 stereo output buffer. Returns the output.
    private func cycle(_ ctx: OpaquePointer, a: [Float], b: [Float]) -> [Float] {
        var a = a, b = b
        let frames = a.count
        var out = [Float](repeating: 0, count: frames * 2)
        var ts = AudioTimeStamp()
        a.withUnsafeMutableBufferPointer { ap in
            b.withUnsafeMutableBufferPointer { bp in
                out.withUnsafeMutableBufferPointer { op in
                    let bytes = UInt32(frames * MemoryLayout<Float>.size)
                    var inABL = AudioBufferList.allocate(maximumBuffers: 2)
                    inABL[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: ap.baseAddress)
                    inABL[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: bp.baseAddress)
                    var outABL = AudioBufferList(mNumberBuffers: 1,
                                                 mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes * 2, mData: op.baseAddress))
                    _ = pk_ioproc(0, &ts, inABL.unsafePointer, &ts, &outABL, &ts, UnsafeMutableRawPointer(ctx))
                    free(inABL.unsafeMutablePointer)
                }
            }
        }
        return out
    }

    @Test func busSumsAndFansOutSampleExact() {
        guard let ctx = pk_context_create() else { Issue.record("context alloc failed"); return }
        defer { pk_context_destroy(ctx) }
        let BUS = PK_BUS_FLAG | 0
        // Stage 1: in0 → bus0 L (×1), in1 → bus0 L (×0.5), in1 → bus0 R (×1).
        // Bus 0 segment: bus0 L → out L (×1), bus0 R → out R (×2), bus0 L → recorder 0 L (×1).
        _ = pk_context_swap_matrix(ctx, matrix([
            (0, 0, BUS, 0, 1.0), (1, 0, BUS, 0, 0.5), (1, 0, BUS, 1, 1.0),
            (BUS, 0, 0, 0, 1.0), (BUS, 1, 0, 1, 2.0), (BUS, 0, PK_REC_FLAG, 0, 1.0),
        ], stage1: 3, order: [0], ends: [6], buses: [(0, params(trim: 1))]))
        pk_recorder_set_active(ctx, 0, 1); pk_recorder_start(ctx, 0)

        let a: [Float] = [1, 2, 3, 4], b: [Float] = [10, 20, 30, 40]
        let out = cycle(ctx, a: a, b: b)
        for f in 0..<4 {
            #expect(out[f * 2] == a[f] + 0.5 * b[f])        // L: sum, at the wire gains
            #expect(out[f * 2 + 1] == 2 * b[f])             // R: only in1, ×2 on the way out
        }
        var rec = [Float](repeating: -1, count: 8)
        let got = rec.withUnsafeMutableBufferPointer { pk_recorder_read(ctx, 0, $0.baseAddress!, 4) }
        #expect(got == 4)
        for f in 0..<4 { #expect(rec[f * 2] == a[f] + 0.5 * b[f]); #expect(rec[f * 2 + 1] == 0) }
        #expect(pk_bus_peak(ctx, 0) == 40)                  // post-processing peak on the bus (R = 40)
        #expect(pk_bus_gain_reduction_db(ctx, 0) == 0)      // compressor off
    }

    @Test func trimScalesTheBus() {
        guard let ctx = pk_context_create() else { Issue.record("context alloc failed"); return }
        defer { pk_context_destroy(ctx) }
        let BUS = PK_BUS_FLAG | 3   // any slot works
        _ = pk_context_swap_matrix(ctx, matrix([(0, 0, BUS, 0, 1.0), (BUS, 0, 0, 0, 1.0)],
                                               stage1: 1, order: [3], ends: [2], buses: [(3, params(trim: 0.25))]))
        let out = cycle(ctx, a: [4, 8], b: [0, 0])
        #expect(out[0] == 1 && out[2] == 2)
    }

    @Test func compressorReducesAboveThresholdOnly() {
        guard let ctx = pk_context_create() else { Issue.record("context alloc failed"); return }
        defer { pk_context_destroy(ctx) }
        let BUS = PK_BUS_FLAG | 0
        // Hard knee, 20:1, threshold −20 dBFS, instant attack/release (coefficients 0).
        _ = pk_context_swap_matrix(ctx, matrix([(0, 0, BUS, 0, 1.0), (BUS, 0, 0, 0, 1.0)],
                                               stage1: 1, order: [0], ends: [2],
                                               buses: [(0, params(comp: true, threshold: -20, ratio: 20))]))
        // 0 dBFS in: 20 dB over → reduction (1/20 − 1)·20 = −19 dB → 10^(−19/20) ≈ 0.1122
        let loud = cycle(ctx, a: [1, 1, 1, 1], b: [0, 0, 0, 0])
        #expect(abs(loud[0] - 0.1122) < 0.001, "got \(loud[0])")
        #expect(abs(pk_bus_gain_reduction_db(ctx, 0) - (-19)) < 0.01)
        // −40 dBFS in (0.01): 20 dB under → untouched, no reduction reported.
        let quiet = cycle(ctx, a: [0.01, 0.01], b: [0, 0])
        #expect(quiet[0] == 0.01)
        #expect(pk_bus_gain_reduction_db(ctx, 0) == 0)
    }

    @Test func attackSmoothsGainReduction() {
        guard let ctx = pk_context_create() else { Issue.record("context alloc failed"); return }
        defer { pk_context_destroy(ctx) }
        let BUS = PK_BUS_FLAG | 0
        // Slow attack: the first sample is barely reduced, later ones more.
        _ = pk_context_swap_matrix(ctx, matrix([(0, 0, BUS, 0, 1.0), (BUS, 0, 0, 0, 1.0)],
                                               stage1: 1, order: [0], ends: [2],
                                               buses: [(0, params(comp: true, threshold: -20, ratio: 20, attack: 0.9, release: 0.9))]))
        let out = cycle(ctx, a: [Float](repeating: 1, count: 64), b: [Float](repeating: 0, count: 64))
        #expect(out[0] > 0.7, "first sample nearly untouched, got \(out[0])")
        #expect(out[126] < out[0], "reduction grows over the attack")
        #expect(out[126] > 0.1122, "and hasn't fully arrived yet")
    }
}
