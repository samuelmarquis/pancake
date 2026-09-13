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
    let bundles = Array(byBundle.keys)
    // A helper (`com.app.helper`, `.helper.GPU`, …) is captured as part of its parent app's family
    // tap, so don't surface it as its own row — list only the top-level app the user recognises.
    func isHelperOfListed(_ bid: String) -> Bool {
        bundles.contains { $0 != bid && bid.hasPrefix($0 + ".") }
    }
    // The app is "playing" if it *or any of its helpers* is producing output (Chromium/Electron apps
    // play through a helper), so the ● indicator is right for browsers, Discord, Slack.
    func familyPlaying(_ bid: String) -> Bool {
        byBundle.contains { k, v in (k == bid || k.hasPrefix(bid + ".")) && v.isRunningOutput }
    }
    let running = NSWorkspace.shared.runningApplications
    var out: [TappableApp] = []
    for (bid, _) in byBundle where !isHelperOfListed(bid) {
        let apps = running.filter { $0.bundleIdentifier == bid }
        let regular = apps.first { $0.activationPolicy == .regular }
        let playing = familyPlaying(bid)
        // Skip background daemons/helpers that aren't actually playing anything.
        guard regular != nil || playing else { continue }
        let name = regular?.localizedName ?? apps.first?.localizedName ?? bid
        out.append(TappableApp(bundleID: bid, name: name, isRunningOutput: playing))
    }
    return out.sorted {
        if $0.isRunningOutput != $1.isRunningOutput { return $0.isRunningOutput }   // playing first
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}
