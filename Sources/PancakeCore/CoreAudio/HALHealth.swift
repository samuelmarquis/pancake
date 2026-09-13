import CoreAudio
import Foundation

/// Health checks on coreaudiod itself — things that aren't pancake's state but can make the whole
/// machine's audio slow, and that pancake's own development workflow can provoke.
public enum HALHealth {
    /// Bundle ids of every HAL plug-in coreaudiod currently has registered, in list order. One entry
    /// per registration — a plug-in registered twice appears twice. nil where the bundle id can't be
    /// read: normal for a second or so while coreaudiod is still bringing plug-ins up after a restart.
    public static func plugInBundleIDs() -> [String?] {
        let ids = (try? systemAudioObject.getPropertyArray(.init(kAudioHardwarePropertyPlugInList), of: AudioObjectID.self)) ?? []
        return ids.map { try? $0.getPropertyString(.init(kAudioPlugInPropertyBundleID)) }
    }

    /// Plug-ins registered more than once, with their counts. Healthy is empty.
    ///
    /// The case this exists for: Apple's AirPlayXPCHelper re-registers every plug-in instance it holds
    /// each time coreaudiod restarts, so its count *doubles* per restart. Driver installs restart
    /// coreaudiod; weeks of them push the count into the millions and coreaudiod pins the CPU. Seen
    /// 2026-09-13. The cure is `sudo killall AirPlayXPCHelper coreaudiod` (both at once), which
    /// `make install-driver` now does on every install.
    ///
    /// Unreadable entries (nil) are ignored, not counted as one repeated "unknown" plug-in: right after a
    /// coreaudiod restart several plug-ins briefly can't report their bundle id, and counting those raised
    /// a false "×7" alarm (seen during the first verification of this check).
    public static func duplicatePlugIns(in bundleIDs: [String?]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for case let b? in bundleIDs { counts[b, default: 0] += 1 }
        return counts.filter { $0.value > 1 }
    }

    public static func duplicatePlugIns() -> [String: Int] { duplicatePlugIns(in: plugInBundleIDs()) }

    /// A one-line human description of any duplicate registrations, or nil when healthy.
    public static func describe(_ dupes: [String: Int]) -> String? {
        guard !dupes.isEmpty else { return nil }
        let list = dupes.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        return "coreaudiod has duplicate plug-in registrations (\(list)) — each coreaudiod restart doubles them; " +
               "reset with `sudo killall AirPlayXPCHelper coreaudiod`"
    }

    /// The fix command, for UI that wants to show it on its own.
    public static let resetCommand = "sudo killall AirPlayXPCHelper coreaudiod"
}
