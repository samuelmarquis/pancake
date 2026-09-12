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
        .defaultSize(width: 1000, height: 660)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no app menu. (Info.plist also sets LSUIElement; this covers a bare binary.)
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tear the aggregate down and hand the default output back to real hardware.
        AppModel.shared.shutdown()
    }
}
