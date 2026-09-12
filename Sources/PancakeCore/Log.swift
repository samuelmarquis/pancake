import Foundation
import os

/// Tiny logging façade: everything goes to os_log (visible in Console / `log stream`), and to
/// `sink` — stderr by default — so the CLI is readable in a terminal.
public enum Log {
    public enum Level: Int, Comparable {
        case debug = 0, info, warn, error
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var tag: String {
            switch self {
            case .debug: return "dbg"
            case .info: return "inf"
            case .warn: return "WRN"
            case .error: return "ERR"
            }
        }
    }

    public static var minimumLevel: Level = .info
    public static var sink: (Level, String) -> Void = { level, line in
        FileHandle.standardError.write((Log.timestamp() + " " + level.tag + " " + line + "\n").data(using: .utf8)!)
    }

    private static let logger = Logger(subsystem: "com.pancake", category: "engine")
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func timestamp() -> String { clock.string(from: Date()) }

    /// Default location for the app's log file.
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/pancake.log")
    }

    /// Route `sink` to a file (appending). The app uses this since it has no useful stderr.
    public static func logToFile(_ url: URL = defaultFileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        let lock = NSLock()
        sink = { level, line in
            lock.lock(); defer { lock.unlock() }
            handle.write((Log.timestamp() + " " + level.tag + " " + line + "\n").data(using: .utf8)!)
        }
    }

    public static func debug(_ s: @autoclosure () -> String) { emit(.debug, s()) }
    public static func info(_ s: @autoclosure () -> String) { emit(.info, s()) }
    public static func warn(_ s: @autoclosure () -> String) { emit(.warn, s()) }
    public static func error(_ s: @autoclosure () -> String) { emit(.error, s()) }

    private static func emit(_ level: Level, _ s: String) {
        switch level {
        case .debug: logger.debug("\(s, privacy: .public)")
        case .info: logger.info("\(s, privacy: .public)")
        case .warn: logger.warning("\(s, privacy: .public)")
        case .error: logger.error("\(s, privacy: .public)")
        }
        if level >= minimumLevel { sink(level, s) }
    }
}
