import AppKit

/// A running app the Stage can tap, with a human-friendly name. Shared by the Stage and the menu
/// bar so both show the same list.
public struct TappableApp: Hashable {
    public let bundleID: String
    public let name: String
    public let isRunningOutput: Bool
    public init(bundleID: String, name: String, isRunningOutput: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.isRunningOutput = isRunningOutput
    }
}

/// Tappable apps: HAL process objects that carry a bundle id, deduped, resolved to friendly names,
/// limited to regular (dock) apps or anything currently producing output. Currently-playing apps
/// sort first, then alphabetical.
public func tappableApps() -> [TappableApp] {
    var byBundle: [String: AudioProcess] = [:]
    for p in ProcessTap.processes() where !p.bundleID.isEmpty && !Engine.selfBundleIDs.contains(p.bundleID) {
        if let e = byBundle[p.bundleID] {
            if p.isRunningOutput && !e.isRunningOutput { byBundle[p.bundleID] = p }
        } else {
            byBundle[p.bundleID] = p
        }
    }
    let running = NSWorkspace.shared.runningApplications
    var out: [TappableApp] = []
    for (bid, proc) in byBundle {
        let apps = running.filter { $0.bundleIdentifier == bid }
        let regular = apps.first { $0.activationPolicy == .regular }
        // Skip background daemons/helpers that aren't actually playing anything.
        guard regular != nil || proc.isRunningOutput else { continue }
        let name = regular?.localizedName ?? apps.first?.localizedName ?? bid
        out.append(TappableApp(bundleID: bid, name: name, isRunningOutput: proc.isRunningOutput))
    }
    return out.sorted {
        if $0.isRunningOutput != $1.isRunningOutput { return $0.isRunningOutput }   // playing first
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}
