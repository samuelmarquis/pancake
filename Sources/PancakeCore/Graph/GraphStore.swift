import Foundation

/// Reads and writes the graph file, and watches it for edits.
///
/// The file *is* the IPC: the menu bar, the CLI and a text editor all just write it, and the
/// running engine picks the change up. That keeps the daemon dumb and the config version-
/// controllable from home-manager.
extension Graph {
    /// The on-disk representation: pretty-printed, keys sorted, so diffs stay readable.
    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public func jsonString() throws -> String { String(decoding: try jsonData(), as: UTF8.self) }

    public init(jsonData data: Data) throws {
        self = try JSONDecoder().decode(Graph.self, from: data)
    }

    public init(jsonString: String) throws {
        try self.init(jsonData: Data(jsonString.utf8))
    }
}

public struct GraphStore {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? GraphStore.defaultURL
    }

    public static var defaultURL: URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        return base.appendingPathComponent("pancake/graph.json")
    }

    /// Returns nil when the file doesn't exist yet.
    public func load() throws -> Graph? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Graph(jsonData: try Data(contentsOf: url))
    }

    public func save(_ graph: Graph) throws {
        let data = try graph.jsonData()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Calls `handler` (on `queue`) whenever the graph file changes on disk. Watches the
    /// directory rather than the file, because editors and atomic writes replace the inode.
    public func watch(queue: DispatchQueue, debounce: TimeInterval = 0.2, handler: @escaping () -> Void) -> FileWatcher? {
        FileWatcher(directory: url.deletingLastPathComponent(), queue: queue, debounce: debounce, handler: handler)
    }
}

public final class FileWatcher {
    private let source: DispatchSourceFileSystemObject
    private let fd: Int32
    private var pending: DispatchWorkItem?

    init?(directory: URL, queue: DispatchQueue, debounce: TimeInterval, handler: @escaping () -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let item = DispatchWorkItem(block: handler)
            self.pending = item
            queue.asyncAfter(deadline: .now() + debounce, execute: item)
        }
        let fd = self.fd
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    public func stop() { source.cancel() }
    deinit { source.cancel() }
}
