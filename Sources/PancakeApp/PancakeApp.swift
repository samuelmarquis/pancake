import AppKit
import PancakeCore
import SwiftUI

/// The menu bar app. It *is* the engine process: the engine runs in here, the menu is a thin
/// view over it, and the graph file stays the source of truth so the CLI and a text editor
/// can still drive a running app.
@main
struct PancakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: model.statusImage)
        }
        .menuBarExtraStyle(.window)

        // The visual routing editor. Opened from the menu's "Show graph…"; one instance.
        Window("Pancake Routing", id: "graph") {
            GraphEditorView(app: model)
        }
        .defaultSize(width: 680, height: 430)   // opens fitting a tidied graph; shrinks much smaller
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// How long Quit waits for the engine to tear down and hand the default output back.
    private static let shutdownDeadline: TimeInterval = 4
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no app menu. (Info.plist also sets LSUIElement; this covers a bare binary.)
        NSApp.setActivationPolicy(.accessory)
    }

    /// Tear the aggregate down and hand the default output back to real hardware — but never let a
    /// hung coreaudiod turn Quit into a beachball. The engine stops on a background thread; if it isn't
    /// done by the deadline the app exits anyway. (The private aggregate and the process taps die with
    /// the process; the one thing lost is the default-output hand-back, which coreaudiod couldn't have
    /// honoured in that state either.) Before this, a quit during a coreaudiod storm hung until the
    /// app was force-killed — which skipped the hand-back entirely.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        let stop = MainActor.assumeIsolated { AppModel.shared.shutdownWork() }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { stop(); finished.signal() }
        DispatchQueue.global(qos: .userInitiated).async {
            if finished.wait(timeout: .now() + Self.shutdownDeadline) == .timedOut {
                Log.warn("quit: the engine didn't stop within \(Int(Self.shutdownDeadline)) s (coreaudiod not answering?); exiting anyway")
            }
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
