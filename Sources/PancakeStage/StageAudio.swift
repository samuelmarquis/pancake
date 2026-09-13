import CoreAudio
import PancakeCore

/// The Stage's audio half: play the **Pancake Program** bus back as *this* process's output.
///
/// Discord's window-share of the Stage carries the Stage process's audio output (proven: a
/// window-shared app's audio is captured even when it's inaudible to you), with none of the call's
/// own audio — no echo. So whatever the engine mixes into Program — the app taps, the hub, a mic,
/// each with its own gain in the graph — is what your friends hear.
///
/// The Stage creates no process taps. It used to tap the chosen app itself, but two taps on one
/// app (the engine's, for a recorder or the mic, and the Stage's) fight and one goes silent. Now
/// the engine owns the one tap and fans it out; the Stage is a dumb repeater: one private
/// aggregate of [Program (input) + Pancake Stage (output)] and a copy IOProc. It renders into its
/// *own* silent device, **Pancake Stage**, rather than back into Program (that would be feedback).
final class StageAudio {
    /// What we read: the screen-share bus the engine writes.
    static let programUID = "PancakeProgram_UID"
    /// Where we render it. Inaudible to you (nobody monitors it); the window-share is what carries it.
    static let sinkUID = "PancakeStage_UID"
    static let aggregateUID = "com.pancake.stage.aggregate"

    private var aggregate: AggregateDevice?
    private var procID: AudioDeviceIOProcID?

    var isRunning: Bool { procID != nil }

    /// True if our aggregate still exists as we built it (a coreaudiod restart leaves us holding a
    /// dead object ID).
    var isHealthy: Bool {
        guard let agg = aggregate, procID != nil else { return false }
        return (try? AudioDevice(id: agg.id))?.uid == Self.aggregateUID
    }

    /// Returns a human-readable status.
    func start() -> String {
        stop()
        guard let program = AudioDevice.find(uid: Self.programUID) else { return "no program device (\(Self.programUID)) — is Pancake.driver installed?" }
        guard let sink = AudioDevice.find(uid: Self.sinkUID) else { return "no stage device (\(Self.sinkUID)) — reinstall Pancake.driver (sudo make install-driver)" }

        // Program is the clock master (both are the driver's devices, on one host-time clock).
        let comp = AggregateComposition(
            uid: Self.aggregateUID, name: "pancake stage",
            subDevices: [.init(uid: Self.programUID, driftCompensation: false),
                         .init(uid: Self.sinkUID, driftCompensation: true)],
            taps: [],
            mainSubDeviceUID: Self.programUID, isPrivate: true)
        guard let agg = try? AggregateDevice.create(comp) else { return "aggregate create failed" }
        aggregate = agg

        // Re-snapshot: joining an aggregate can change a device's stream layout.
        let subs = [program, sink].compactMap { try? AudioDevice(id: $0.id) }
        guard subs.count == 2,
              let layout = try? ChannelLayout.resolve(aggregate: agg, subDevices: subs),
              let inSlot = layout.inputs[Self.programUID]?.first,
              let outSlot = layout.outputs[Self.sinkUID]?.first else { stop(); return "layout resolve failed" }
        let inBuf = inSlot.buffer, outBuf = outSlot.buffer

        var p: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&p, agg.id, nil) { _, inData, _, outData, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let outs = UnsafeMutableAudioBufferListPointer(outData)
            guard inBuf < ins.count, outBuf < outs.count else { return }
            let src = ins[inBuf], dst = outs[outBuf]
            guard let s = src.mData, let d = dst.mData else { return }
            memcpy(d, s, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        guard st == noErr, let p else { stop(); return "IOProc create failed (\(st))" }
        procID = p
        AudioDeviceStart(agg.id, p)
        return "playing \(Self.programUID) → \(Self.sinkUID) as this process's output"
    }

    func stop() {
        if let agg = aggregate, let p = procID {
            AudioDeviceStop(agg.id, p)
            AudioDeviceDestroyIOProcID(agg.id, p)
        }
        procID = nil
        aggregate?.destroy(); aggregate = nil
    }
}
