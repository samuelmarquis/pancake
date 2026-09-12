import CoreAudio
import PancakeCore

/// The Stage's audio half: tap a chosen app and render its audio, as *this* process's output, into
/// a silent sink device. Discord's window-share of the Stage then carries that audio (proven: a
/// window-shared app's audio is captured even when it's inaudible to you), with none of the call's
/// own audio — no echo. It's one private aggregate of [sink + tap] and a copy IOProc.
final class StageAudio {
    /// Where the tapped audio is rendered. Inaudible to you (nobody monitors it); the Stage
    /// window-share is what carries it. This is the dedicated **Pancake Program** bus, separate
    /// from **Pancake Mic** (your voice) — so the shared program never bleeds into the Discord
    /// voice channel. Discord voice input can stay on Pancake Mic (or the built-in mic).
    static let sinkUID = "PancakeProgram_UID"
    static let aggregateUID = "com.pancake.stage.aggregate"

    private var tap: ProcessTap?
    private var aggregate: AggregateDevice?
    private var procID: AudioDeviceIOProcID?

    /// Returns a human-readable status.
    func start(bundleID: String) -> String {
        stop()
        guard AudioDevice.find(uid: Self.sinkUID) != nil else { return "no sink device (\(Self.sinkUID))" }
        guard let tap = ProcessTap.create(bundleID: bundleID, name: "pancake stage: \(bundleID)") else {
            return "couldn't tap \(bundleID) — is it running and playing?"
        }
        self.tap = tap

        let comp = AggregateComposition(
            uid: Self.aggregateUID, name: "pancake stage",
            subDevices: [.init(uid: Self.sinkUID, driftCompensation: false)],
            taps: [.init(uid: tap.uuid, driftCompensation: true)],
            mainSubDeviceUID: Self.sinkUID, isPrivate: true)
        guard let agg = try? AggregateDevice.create(comp) else { stop(); return "aggregate create failed" }
        aggregate = agg

        let sink = (AudioDevice.find(uid: Self.sinkUID)).flatMap { try? AudioDevice(id: $0.id) }
        guard let sink,
              let layout = try? ChannelLayout.resolve(aggregate: agg, subDevices: [sink], tapBundleIDs: [bundleID]),
              let tapSlot = layout.inputs[bundleID]?.first,
              let sinkSlot = layout.outputs[Self.sinkUID]?.first else { stop(); return "layout resolve failed" }
        let tapBuf = tapSlot.buffer, sinkBuf = sinkSlot.buffer

        var p: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&p, agg.id, nil) { _, inData, _, outData, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let outs = UnsafeMutableAudioBufferListPointer(outData)
            guard tapBuf < ins.count, sinkBuf < outs.count else { return }
            let src = ins[tapBuf], dst = outs[sinkBuf]
            guard let s = src.mData, let d = dst.mData else { return }
            memcpy(d, s, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        guard st == noErr, let p else { stop(); return "IOProc create failed (\(st))" }
        procID = p
        AudioDeviceStart(agg.id, p)
        return "sharing \(bundleID) audio → \(Self.sinkUID)"
    }

    func stop() {
        if let agg = aggregate, let p = procID {
            AudioDeviceStop(agg.id, p)
            AudioDeviceDestroyIOProcID(agg.id, p)
        }
        procID = nil
        aggregate?.destroy(); aggregate = nil
        tap?.destroy(); tap = nil
    }
}
