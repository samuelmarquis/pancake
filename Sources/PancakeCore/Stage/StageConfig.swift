import Foundation

/// What the Pancake Stage should be doing, as chosen from the menu bar (or the Stage's own window).
///
/// The file *is* the IPC — same pattern as the graph. The menu writes `~/.config/pancake/stage.json`;
/// the Stage process watches it and obeys. Keeping the Stage a dumb executor of a file means both
/// the menu and the Stage's own controls are just thin views over the same source of truth, and a
/// text editor or the CLI can drive it too.
///
/// The Stage always mirrors the desktop (that half needs no config). This is only the audio choice
/// and the window visibility:
///   • `bundleID` — the app whose audio to render into the Pancake Program bus (nil = silence).
///   • `hidden`   — park the mirror window off-desktop (still shareable) or show it.
public struct StageConfig: Codable, Equatable {
    public var bundleID: String?
    public var hidden: Bool

    public init(bundleID: String? = nil, hidden: Bool = false) {
        self.bundleID = bundleID
        self.hidden = hidden
    }
}

/// Reads, writes and watches the Stage config file. Mirror of `GraphStore`.
public struct StageStore {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? StageStore.defaultURL
    }

    public static var defaultURL: URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        return base.appendingPathComponent("pancake/stage.json")
    }

    /// Returns nil when the file doesn't exist yet. Throws only on a genuinely malformed file.
    public func load() throws -> StageConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(StageConfig.self, from: try Data(contentsOf: url))
    }

    public func save(_ config: StageConfig) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Calls `handler` (on `queue`) whenever the config file changes on disk. Watches the directory,
    /// because atomic writes replace the inode.
    public func watch(queue: DispatchQueue, debounce: TimeInterval = 0.2, handler: @escaping () -> Void) -> FileWatcher? {
        FileWatcher(directory: url.deletingLastPathComponent(), queue: queue, debounce: debounce, handler: handler)
    }
}
