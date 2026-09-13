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
///
/// One tap per app, ever: two taps on the same process family fight over the audio and one of them
/// goes silent (seen live with the Stage and the engine both tapping Helium). So the engine is the
/// only thing in pancake that creates taps, and it fans one tap out to every sink the graph asks for.
public final class ProcessTap {
    public let bundleID: String
    public let tapID: AudioObjectID
    /// The tap's UID — its CATapDescription UUID string — for the aggregate tap list.
    public let uuid: String
    /// The process objects the tap currently mixes. Updated in place (`update`) as the app's helpers
    /// come and go, so the tap — and the aggregate it sits in — outlives any one process.
    public private(set) var processObjects: [AudioObjectID]

    private let name: String
    private let uuidObject: UUID

    private init(bundleID: String, name: String, tapID: AudioObjectID, uuid: UUID, processObjects: [AudioObjectID]) {
        self.bundleID = bundleID
        self.name = name
        self.tapID = tapID
        self.uuidObject = uuid
        self.uuid = uuid.uuidString
        self.processObjects = processObjects
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
            .sorted()
    }

    // MARK: Creation

    private static func description(name: String, uuid: UUID, processes: [AudioObjectID]) -> CATapDescription {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.name = name
        desc.uuid = uuid
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        return desc
    }

    /// Create a stereo tap on the app with this bundle id — a mixdown of its whole process family, so
    /// the audio-producing helper is included. Returns nil if none of the family is a HAL process
    /// (app not running) or the tap can't be made.
    public static func create(bundleID: String, name: String) -> ProcessTap? {
        let family = processObjects(forBundleID: bundleID)
        guard !family.isEmpty else { return nil }
        let uuid = UUID()
        let desc = description(name: name, uuid: uuid, processes: family)
        var tapID = AudioObjectID(0)
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != 0 else { return nil }
        return ProcessTap(bundleID: bundleID, name: name, tapID: tapID, uuid: uuid, processObjects: family)
    }

    /// Re-point the live tap at a new set of process objects — the app relaunched, or a helper
    /// spawned/quit — without destroying it. The tap keeps its UUID, so an aggregate holding it
    /// carries on untouched: no rebuild, no glitch on the outputs. Returns false if the HAL refused,
    /// in which case the caller should fall back to destroy + create.
    @discardableResult
    public func update(processObjects newObjects: [AudioObjectID]) -> Bool {
        let sorted = newObjects.sorted()
        guard sorted != processObjects else { return true }
        let desc = Self.description(name: name, uuid: uuidObject, processes: sorted)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var unmanaged = Unmanaged.passUnretained(desc)
        let status = withUnsafePointer(to: &unmanaged) { ptr in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), ptr)
        }
        guard status == noErr else { return false }
        processObjects = sorted
        return true
    }
}
