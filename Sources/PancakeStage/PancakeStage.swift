import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import ScreenCaptureKit
import PancakeCore

// Pancake Stage — a clean desktop mirror you window-share in Discord. Because a window-share scopes
// audio to the shared window's *process*, sharing THIS window never picks up the call's own audio
// (no echo); and the audio it *does* carry is whatever app you pick, rendered as this process's
// output into the silent "Pancake Program" bus.
//
// Two windows on purpose:
//   • "Pancake Stage"  — the pristine mirror. This is the one you share. No pancake chrome.
//   • "Pancake Stage — Controls" — the app picker + status. Never shared, and excluded from the
//     capture so it doesn't appear inside the mirror either.

/// The view that displays captured frames.
final class MirrorView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
    func enqueue(_ sb: CMSampleBuffer) {
        if displayLayer.requiresFlushToResumeDecoding || displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sb)
    }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let view: MirrorView
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.pancake.stage.capture")
    /// Our own windows, excluded so we neither mirror ourselves (recursion) nor show the controls.
    private let excludeWindowIDs: Set<CGWindowID>
    var onStatus: ((String) -> Void)?
    /// The captured display's size in points, so the mirror window can match its aspect ratio.
    var onDisplaySize: ((CGSize) -> Void)?

    init(view: MirrorView, excludeWindowIDs: Set<CGWindowID>) {
        self.view = view
        self.excludeWindowIDs = excludeWindowIDs
    }

    func start() {
        Task { await self.startAsync() }
    }

    private func startAsync() async {
        do {
            // Prompts for Screen Recording permission on first use; throws until granted.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                await status("no display found"); return
            }
            let dsize = CGSize(width: display.width, height: display.height)
            DispatchQueue.main.async { [weak self] in self?.onDisplaySize?(dsize) }
            // Exclude our own windows so we don't capture ourselves (infinite mirror) or the controls.
            let mine = content.windows.filter { excludeWindowIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: mine)

            let config = SCStreamConfiguration()
            config.width = display.width * 2      // retina backing
            config.height = display.height * 2
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 5
            config.showsCursor = true

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            await status("mirroring \(display.width)×\(display.height)")
        } catch {
            await status("capture failed: \(error.localizedDescription) — grant Screen Recording in System Settings › Privacy & Security, then reopen.")
        }
    }

    @MainActor private func status(_ s: String) { onStatus?(s); NSLog("stage: \(s)") }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only enqueue frames the compositor marked complete (skip idle/blank status frames).
        guard let attach = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attach.first?[.status] as? Int, let s = SCFrameStatus(rawValue: raw), s == .complete else { return }
        DispatchQueue.main.async { [weak self] in self?.view.enqueue(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { await status("stream stopped: \(error.localizedDescription)") }
    }
}

/// A running app the Stage can tap, with a human-friendly name.
struct TappableApp: Hashable {
    let bundleID: String
    let name: String
    let isRunningOutput: Bool
}

/// Tappable apps: HAL process objects that carry a bundle id, deduped, resolved to friendly names,
/// limited to regular (dock) apps or anything currently producing output. Currently-playing apps
/// sort first, then alphabetical.
func tappableApps() -> [TappableApp] {
    var byBundle: [String: AudioProcess] = [:]
    for p in ProcessTap.processes() where !p.bundleID.isEmpty {
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

final class StageDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var mirrorWindow: NSWindow!
    private var controlsWindow: NSWindow!
    private var capture: Capture!
    private var appPopup: NSPopUpButton!
    private var hideCheckbox: NSButton!
    private var videoLabel: NSTextField!
    private var audioLabel: NSTextField!
    private var shareLabel: NSTextField!
    private let audio = StageAudio()

    /// The app currently being shared, if any.
    private var currentBundleID: String?
    /// Preferred app to select automatically when it becomes available.
    private let preferredBundleID = "com.ableton.live"
    /// Auto-select stays armed until the user makes any manual pick (including "None"), at which
    /// point we stop second-guessing them. This is what makes "launch the Stage, then open Ableton"
    /// just work without us overriding a deliberate choice later.
    private var autoSelectArmed = true

    /// Fires when the HAL's process set changes — i.e. an app becomes (un)tappable. Drives auto-tap.
    private var processListener: PropertyListener?

    /// Hidden-mirror state. When hidden we park the (full-size) mirror window at a 1pt on-screen
    /// sliver so it stays composited and Discord-shareable but is invisible on your desktop.
    private var mirrorHidden = false
    private var lastVisibleFrame: NSRect?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMirrorWindow()
        buildControlsWindow()

        // Exclude BOTH our windows from the capture: anti-recursion for the mirror, and keep the
        // controls out of the shared frame.
        let excluded: Set<CGWindowID> = [CGWindowID(mirrorWindow.windowNumber),
                                         CGWindowID(controlsWindow.windowNumber)]
        capture = Capture(view: mirrorWindow.contentView as! MirrorView, excludeWindowIDs: excluded)
        capture.onStatus = { [weak self] s in self?.videoLabel.stringValue = "video: \(s)" }
        capture.onDisplaySize = { [weak self] size in self?.matchMirrorAspect(size) }
        capture.start()

        // Tapping an app is "audio capture" to TCC → Microphone permission (same gate the engine's
        // taps use). Ask, then enable the picker.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            enableAudioPicker()
        case .notDetermined:
            audioLabel.stringValue = "audio: requesting microphone access…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.enableAudioPicker() }
                    else { self?.audioLabel.stringValue = "audio: microphone access denied — enable it in Settings › Privacy › Microphone" }
                }
            }
        default:
            audioLabel.stringValue = "audio: microphone access denied — enable it in Settings › Privacy › Microphone"
        }

        // Report — for real, via ScreenCaptureKit, the same API Discord uses — whether the mirror
        // window is shareable. Gives us ground truth on the hidden-window question once frames flow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.logShareability("launch") }
    }

    // MARK: Windows

    private func buildMirrorWindow() {
        let mirror = MirrorView(frame: NSRect(x: 0, y: 0, width: 1000, height: 625))
        mirrorWindow = NSWindow(contentRect: mirror.bounds,
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        mirrorWindow.title = "Pancake Stage"                 // kept: Discord lists the window by title
        // Chrome-free: no visible title text, no traffic lights, transparent title bar over full-size
        // content, no drop shadow — it just looks like a stream. Still a normal titled window, so it
        // stays in Discord's window picker.
        mirrorWindow.titleVisibility = .hidden
        mirrorWindow.titlebarAppearsTransparent = true
        mirrorWindow.standardWindowButton(.closeButton)?.isHidden = true
        mirrorWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        mirrorWindow.standardWindowButton(.zoomButton)?.isHidden = true
        mirrorWindow.hasShadow = false                       // kills the darkening in the corner when parked
        mirrorWindow.isMovableByWindowBackground = true      // drag the picture itself to reposition
        // Live on every Space, so it's always on whatever desktop Discord is on — no hunting.
        mirrorWindow.collectionBehavior = [.canJoinAllSpaces]
        mirrorWindow.center()
        mirrorWindow.contentView = mirror
        mirrorWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Size the mirror to the display's exact aspect ratio so there are no letterbox bars.
    private func matchMirrorAspect(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        mirrorWindow.contentAspectRatio = size
        guard !mirrorHidden else { return }
        let w: CGFloat = 1000
        mirrorWindow.setContentSize(NSSize(width: w, height: (w * size.height / size.width).rounded()))
        mirrorWindow.center()
        lastVisibleFrame = mirrorWindow.frame
    }

    private func buildControlsWindow() {
        let width: CGFloat = 460, height: CGFloat = 200
        controlsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
        controlsWindow.title = "Pancake Stage — Controls"
        controlsWindow.isExcludedFromWindowsMenu = false
        // Sit it just below the mirror window.
        if let mf = mirrorWindow?.frame {
            controlsWindow.setFrameOrigin(NSPoint(x: mf.minX, y: mf.minY - height - 12))
        } else {
            controlsWindow.center()
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let heading = NSTextField(labelWithString: "Share audio from:")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.frame = NSRect(x: 16, y: height - 30, width: 200, height: 18)
        container.addSubview(heading)

        appPopup = NSPopUpButton(frame: NSRect(x: 16, y: height - 64, width: width - 32, height: 26), pullsDown: false)
        appPopup.target = self
        appPopup.action = #selector(pickApp(_:))
        appPopup.menu?.delegate = self          // rebuild the list each time it opens
        container.addSubview(appPopup)

        let hint = NSTextField(labelWithString: "Window-share the “Pancake Stage” window in Discord.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: height - 86, width: width - 32, height: 16)
        container.addSubview(hint)

        hideCheckbox = NSButton(checkboxWithTitle: "Hide mirror window (keep it shareable)",
                                target: self, action: #selector(toggleHidden(_:)))
        hideCheckbox.frame = NSRect(x: 14, y: height - 116, width: width - 28, height: 22)
        container.addSubview(hideCheckbox)

        shareLabel = statusField(y: 54, in: container, width: width); shareLabel.stringValue = "shareable: checking…"
        videoLabel = statusField(y: 32, in: container, width: width); videoLabel.stringValue = "video: starting…"
        audioLabel = statusField(y: 10, in: container, width: width); audioLabel.stringValue = "audio: waiting for microphone access…"

        controlsWindow.contentView = container
        controlsWindow.orderFront(nil)
    }

    private func statusField(y: CGFloat, in parent: NSView, width: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        l.frame = NSRect(x: 16, y: y, width: width - 32, height: 14)
        parent.addSubview(l)
        return l
    }

    // MARK: Hidden mirror

    @objc private func toggleHidden(_ sender: NSButton) {
        setMirrorHidden(sender.state == .on)
    }

    /// Park the mirror window at a 1pt on-screen sliver (bottom-left corner, effectively invisible)
    /// or restore it. We keep 1pt on-screen on purpose: a fully off-screen window can report
    /// isOnScreen == false and stop being composited, which would drop it from Discord's picker or
    /// freeze the shared frame. A sliver keeps it "visible" (drawing + capturable) yet out of sight.
    private func setMirrorHidden(_ hidden: Bool) {
        guard hidden != mirrorHidden else { return }
        mirrorHidden = hidden
        if hidden {
            lastVisibleFrame = mirrorWindow.frame
            let screen = mirrorWindow.screen ?? NSScreen.main ?? NSScreen.screens.first
            let f = mirrorWindow.frame
            if let s = screen {
                // Put the window's top-right corner 1pt inside the screen's bottom-left corner.
                let origin = NSPoint(x: s.frame.minX + 1 - f.width, y: s.frame.minY + 1 - f.height)
                mirrorWindow.setFrameOrigin(origin)
            }
            mirrorWindow.orderFront(nil)   // stay composited while parked
            NSLog("stage: mirror hidden (parked off-desktop, still shareable)")
        } else {
            if let prev = lastVisibleFrame { mirrorWindow.setFrame(prev, display: true) }
            else { mirrorWindow.center() }
            mirrorWindow.makeKeyAndOrderFront(nil)
            NSLog("stage: mirror shown")
        }
        // Re-measure shareability after the move settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.logShareability(hidden ? "hidden" : "shown") }
    }

    /// Ask ScreenCaptureKit (Discord's own API) whether our mirror window is listed and on-screen,
    /// in both filter modes. onScreenWindowsOnly:true is what a typical window picker uses, so if we
    /// appear there we should appear in Discord's picker too.
    private func logShareability(_ tag: String) {
        guard let win = mirrorWindow else { return }
        let id = CGWindowID(win.windowNumber)
        Task { @MainActor in
            var summary: [String] = []
            for onScreenOnly in [true, false] {
                let mode = onScreenOnly ? "onScreen" : "all"
                if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenOnly) {
                    if let w = content.windows.first(where: { $0.windowID == id }) {
                        NSLog("stage: shareability[\(tag)/\(mode)]: LISTED title=\(w.title ?? "nil") isOnScreen=\(w.isOnScreen) frame=\(w.frame)")
                        summary.append("\(mode)=\(w.isOnScreen ? "yes" : "on-list")")
                    } else {
                        NSLog("stage: shareability[\(tag)/\(mode)]: NOT listed (windowID \(id))")
                        summary.append("\(mode)=no")
                    }
                } else {
                    NSLog("stage: shareability[\(tag)/\(mode)]: query failed")
                    summary.append("\(mode)=?")
                }
            }
            shareLabel?.stringValue = "shareable: \(summary.joined(separator: "  "))"
        }
    }

    // MARK: Auto-tap when the target app appears

    /// Listen for changes to the HAL process set. When the preferred app becomes tappable and we're
    /// still idle (user hasn't picked anything yet), select it automatically.
    private func enableAudioPicker() {
        installProcessListener()
        rebuildPopup()
        // Auto-select the preferred app (Ableton) if it's tappable right now; otherwise wait — either
        // for the user to choose, or for the process listener to catch it launching.
        if autoSelectArmed && tappableApps().contains(where: { $0.bundleID == preferredBundleID }) {
            selectAndShare(preferredBundleID)
        } else {
            audioLabel.stringValue = "audio: pick an app to share ↑"
        }
    }

    private func installProcessListener() {
        guard processListener == nil else { return }
        processListener = try? systemAudioObject.addPropertyListener(
            .init(kAudioHardwarePropertyProcessObjectList), queue: .main) { [weak self] in
            self?.processListChanged()
        }
    }

    private func processListChanged() {
        rebuildPopup()   // keep the list + ● indicators honest as apps come and go
        guard autoSelectArmed, currentBundleID == nil else { return }
        if tappableApps().contains(where: { $0.bundleID == preferredBundleID }) {
            NSLog("stage: preferred app became tappable — auto-selecting")
            selectAndShare(preferredBundleID)
        }
    }

    // MARK: Picker

    /// Rebuild the popup's items from the current process list, preserving the selection.
    private func rebuildPopup() {
        guard let menu = appPopup.menu else { return }
        menu.removeAllItems()

        let placeholder = NSMenuItem(title: "None (no audio shared)", action: nil, keyEquivalent: "")
        placeholder.representedObject = ""
        menu.addItem(placeholder)
        menu.addItem(.separator())

        for app in tappableApps() {
            let suffix = app.isRunningOutput ? "  ●" : ""
            let item = NSMenuItem(title: app.name + suffix, action: nil, keyEquivalent: "")
            item.representedObject = app.bundleID
            menu.addItem(item)
        }
        selectCurrentInPopup()
    }

    private func selectCurrentInPopup() {
        let target = currentBundleID ?? ""
        if let item = appPopup.menu?.items.first(where: { ($0.representedObject as? String) == target }) {
            appPopup.select(item)
        } else if let cur = currentBundleID {
            // Selected app is no longer in the list (quit) — show it anyway so state is honest.
            let item = NSMenuItem(title: cur + "  (not running)", action: nil, keyEquivalent: "")
            item.representedObject = cur
            appPopup.menu?.addItem(item)
            appPopup.select(item)
        } else {
            appPopup.selectItem(at: 0)
        }
    }

    @objc private func pickApp(_ sender: NSPopUpButton) {
        // Any manual selection disarms auto-tap — we stop overriding the user's choice from here on.
        autoSelectArmed = false
        let bid = (sender.selectedItem?.representedObject as? String) ?? ""
        if bid.isEmpty {
            audio.stop()
            currentBundleID = nil
            audioLabel.stringValue = "audio: none shared"
            NSLog("stage: audio stopped (none selected)")
        } else {
            selectAndShare(bid)
        }
    }

    private func selectAndShare(_ bundleID: String) {
        currentBundleID = bundleID
        let msg = audio.start(bundleID: bundleID)
        audioLabel.stringValue = "audio: \(msg)"
        NSLog("stage: audio: \(msg)")
        selectCurrentInPopup()
    }

    // NSMenuDelegate: refresh the app list right before the popup opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === appPopup.menu { rebuildPopup() }
    }

    func applicationWillTerminate(_ n: Notification) {
        processListener?.remove()
        audio.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
