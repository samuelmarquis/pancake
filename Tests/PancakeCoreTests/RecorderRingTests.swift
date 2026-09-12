import CoreAudio
import CPancakeRT
import Testing

/// Proves the realtime recorder path is sample-exact without needing a live device: pump known
/// audio through `pk_ioproc` with a matrix that routes it into a recorder, then read it back out of
/// the ring and check every sample. Also checks the mono→stereo fan (one source channel, two dest
/// channels, different gains) and that nothing overruns.
@Suite struct RecorderRingTests {

    /// Build a C matrix from (inBuffer, inChannel, outBuffer, outChannel, gain) tuples.
    private func matrix(_ rs: [(UInt32, UInt32, UInt32, UInt32, Float)]) -> UnsafeMutablePointer<pk_matrix>? {
        guard let m = pk_matrix_alloc(UInt32(rs.count)), let slots = m.pointee.routes else { return nil }
        for (i, r) in rs.enumerated() {
            slots[i] = pk_route(in_buffer: r.0, in_channel: r.1, out_buffer: r.2, out_channel: r.3, gain: r.4)
        }
        return m
    }

    @Test func ringCapturesRoutedAudioSampleExact() {
        guard let ctx = pk_context_create() else { Issue.record("context alloc failed"); return }
        defer { pk_context_destroy(ctx) }

        let frames = 8
        let cycles = 3

        var input = (0..<frames).map { Float($0 + 1) }          // 1,2,…,8 — exact under ×1 and ×0.5
        var output = [Float](repeating: 0, count: frames * 2)

        // Route input ch0 → recorder 0 ch0 at unity, and → recorder 0 ch1 at 0.5 (mono fan).
        _ = pk_context_swap_matrix(ctx, matrix([
            (0, 0, PK_REC_FLAG, 0, 1.0),
            (0, 0, PK_REC_FLAG, 1, 0.5),
        ]))   // context now owns the matrix; freed with the context

        pk_recorder_set_active(ctx, 0, 1)
        pk_recorder_start(ctx, 0)

        var ts = AudioTimeStamp()
        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                var inABL = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1,
                                          mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                                          mData: inPtr.baseAddress))
                var outABL = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2,
                                          mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                                          mData: outPtr.baseAddress))
                for _ in 0..<cycles {
                    _ = pk_ioproc(0, &ts, &inABL, &ts, &outABL, &ts, UnsafeMutableRawPointer(ctx))
                }
            }
        }

        #expect(pk_recorder_captured_frames(ctx, 0) == UInt64(frames * cycles))
        #expect(pk_recorder_overrun_frames(ctx, 0) == 0)

        // Drain and verify every interleaved stereo sample.
        let total = frames * cycles
        var dst = [Float](repeating: -999, count: total * 2)
        let got = dst.withUnsafeMutableBufferPointer { pk_recorder_read(ctx, 0, $0.baseAddress!, UInt32(total)) }
        #expect(Int(got) == total)

        for f in 0..<total {
            let expected = input[f % frames]
            #expect(dst[f * 2 + 0] == expected)          // ch0: unity
            #expect(dst[f * 2 + 1] == expected * 0.5)    // ch1: half
        }
        // Ring is drained: a second read yields nothing.
        let again = dst.withUnsafeMutableBufferPointer { pk_recorder_read(ctx, 0, $0.baseAddress!, UInt32(total)) }
        #expect(again == 0)
    }

    @Test func disarmedRecorderCapturesNothing() {
        guard let ctx = pk_context_create() else { Issue.record("context alloc failed"); return }
        defer { pk_context_destroy(ctx) }

        _ = pk_context_swap_matrix(ctx, matrix([(0, 0, PK_REC_FLAG, 0, 1.0)]))
        pk_recorder_set_active(ctx, 0, 1)
        // Deliberately not started/armed.

        var input = [Float](repeating: 1, count: 8)
        var output = [Float](repeating: 0, count: 16)
        var ts = AudioTimeStamp()
        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                var inABL = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 32, mData: inPtr.baseAddress))
                var outABL = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 64, mData: outPtr.baseAddress))
                _ = pk_ioproc(0, &ts, &inABL, &ts, &outABL, &ts, UnsafeMutableRawPointer(ctx))
            }
        }
        #expect(pk_recorder_captured_frames(ctx, 0) == 0)
        var dst = [Float](repeating: 0, count: 16)
        let got = dst.withUnsafeMutableBufferPointer { pk_recorder_read(ctx, 0, $0.baseAddress!, 8) }
        #expect(got == 0)
    }
}
