import AppKit
import PancakeCore
import SwiftUI

/// Makes "Show graph…" bring the routing window to the desktop you're on.
///
/// SwiftUI's `openWindow` on a `Window` scene that's already open orders the existing window front,
/// and ordering front a window that lives on another Space makes macOS switch to that Space — so the
/// graph always yanked you back to whichever desktop it was first opened on. AppKit's purpose-built
/// answer is `NSWindow.CollectionBehavior.moveToActiveSpace` ("making the window active moves it to
/// the active space instead of switching spaces"). It's set only for the duration of one show request
/// and cleared once the window has become key: left on permanently, merely activating the app (opening
/// the menu bar panel) could drag the graph off the desktop you left it on.
///
/// A full-screen graph is left where it is: it *is* its own Space, and the flag doesn't apply to it.
@MainActor
enum GraphWindow {
    /// The graph's NSWindow, once SwiftUI has created it (registered by `GraphWindowAccessor`).
    private static weak var window: NSWindow?
    private static var restore: (behavior: NSWindow.CollectionBehavior, observer: NSObjectProtocol)?

    static func register(_ w: NSWindow) { window = w }

    /// Call right before `openWindow(id: "graph")`. If the window is open on another desktop, let the
    /// coming order-front move it here instead of switching Spaces.
    static func prepareToShow() {
        guard let w = window, w.isVisible, !w.isOnActiveSpace,
              !w.styleMask.contains(.fullScreen), restore == nil else { return }
        let original = w.collectionBehavior
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main
        ) { _ in
            MainActor.assumeIsolated { finishShow() }
        }
        restore = (original, observer)
        w.collectionBehavior.insert(.moveToActiveSpace)
        Log.info("graph window is on another desktop; moving it to this one")
    }

    private static func finishShow() {
        guard let (behavior, observer) = restore else { return }
        NotificationCenter.default.removeObserver(observer)
        restore = nil
        guard let w = window else { return }
        w.collectionBehavior = behavior
        Log.info("graph window shown (on this desktop: \(w.isOnActiveSpace))")
    }
}

/// Hands the hosting NSWindow to `GraphWindow`. Zero-size, invisible; lives in the editor's background.
struct GraphWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { GraphWindow.register(window) }
        }
    }
}
