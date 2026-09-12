import CoreAudio
import Foundation

/// A running audio process as the HAL sees it (macOS 14.2+ "process objects").
public struct AudioProcess: Identifiable, Hashable {
    public let id: AudioObjectID          // the process object
    public let bundleID: String
    public let pid: pid_t
    public let isRunningOutput: Bool
}

/// A Core Audio process tap: a private, unmuted capture of another app's *output* audio. Unmuted
/// means the tapped app keeps playing to its normal destination — we're only listening in — so we
/// can send, say, Ableton to Discord while you still hear it on your AirPods. Put `uuid` in an
/// aggregate's tap list (`kAudioAggregateDeviceTapListKey`) and the tapped audio shows up as an
/// input stream on that aggregate. macOS 14.2+.
public final class ProcessTap {
    public let bundleID: String
    public let tapID: AudioObjectID
    /// The tap's UID — its CATapDescription UUID string — for the aggregate tap list.
    public let uuid: String

    private init(bundleID: String, tapID: AudioObjectID, uuid: String) {
        self.bundleID = bundleID
        self.tapID = tapID
        self.uuid = uuid
    }

    public func destroy() { AudioHardwareDestroyProcessTap(tapID) }

    // MARK: Process enumeration

    /// Every process object the HAL lists that carries a bundle id.
    public static func processes() -> [AudioProcess] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let ids = (try? sys.getPropertyArray(.init(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)) ?? []
        return ids.compactMap { id in
            guard let bundleID = try? id.getPropertyString(.init(kAudioProcessPropertyBundleID)), !bundleID.isEmpty else { return nil }
            let pid = (try? id.getProperty(.init(kAudioProcessPropertyPID), as: pid_t.self)) ?? -1
            let out = ((try? id.getProperty(.init(kAudioProcessPropertyIsRunningOutput), as: UInt32.self)) ?? 0) != 0
            return AudioProcess(id: id, bundleID: bundleID, pid: pid, isRunningOutput: out)
        }
    }

    /// The process object for a bundle id, preferring one that's currently producing output (some
    /// apps register several helper processes under one bundle id).
    public static func processObject(forBundleID bundleID: String) -> AudioObjectID? {
        let matches = processes().filter { $0.bundleID == bundleID }
        return (matches.first { $0.isRunningOutput } ?? matches.first)?.id
    }

    // MARK: Creation

    /// Create a stereo tap on the app with this bundle id. Returns nil if the app isn't currently
    /// a HAL process (not running / not producing audio) or the tap can't be made.
    public static func create(bundleID: String, name: String) -> ProcessTap? {
        guard let proc = processObject(forBundleID: bundleID) else { return nil }
        let desc = CATapDescription(stereoMixdownOfProcesses: [proc])
        desc.name = name
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tapID = AudioObjectID(0)
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != 0 else { return nil }
        return ProcessTap(bundleID: bundleID, tapID: tapID, uuid: desc.uuid.uuidString)
    }
}
