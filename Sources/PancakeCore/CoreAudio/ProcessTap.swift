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

    /// Every process object in an app's bundle-id *family*: the main process plus its helpers
    /// (`<bundle>.helper`, `.helper.GPU`, `.helper.Renderer`, …). This matters because Chromium- and
    /// Electron-based apps — browsers (Helium, Chrome), Discord, Slack — render their audio in a
    /// helper process, not the main one, so a tap on the main bundle id alone captures silence.
    public static func processObjects(forBundleID bundleID: String) -> [AudioObjectID] {
        let prefix = bundleID + "."
        return processes()
            .filter { $0.bundleID == bundleID || $0.bundleID.hasPrefix(prefix) }
            .map(\.id)
    }

    // MARK: Creation

    /// Create a stereo tap on the app with this bundle id — a mixdown of its whole process family, so
    /// the audio-producing helper is included. Returns nil if none of the family is a HAL process
    /// (app not running) or the tap can't be made.
    public static func create(bundleID: String, name: String) -> ProcessTap? {
        let family = processObjects(forBundleID: bundleID)
        guard !family.isEmpty else { return nil }
        let desc = CATapDescription(stereoMixdownOfProcesses: family)
        desc.name = name
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tapID = AudioObjectID(0)
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != 0 else { return nil }
        return ProcessTap(bundleID: bundleID, tapID: tapID, uuid: desc.uuid.uuidString)
    }
}
