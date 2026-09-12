import AppKit
import AVFoundation
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
    private var videoLabel: NSTextField!
    private var audioLabel: NSTextField!
    private let audio = StageAudio()

    /// The app currently being shared, if any.
    private var currentBundleID: String?
    /// Preferred app to select automatically at launch when it's available.
    private let preferredBundleID = "com.ableton.live"

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
    }

    // MARK: Windows

    private func buildMirrorWindow() {
        let mirror = MirrorView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        mirrorWindow = NSWindow(contentRect: mirror.bounds,
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
        mirrorWindow.title = "Pancake Stage"
        mirrorWindow.center()
        mirrorWindow.contentView = mirror
        mirrorWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildControlsWindow() {
        let width: CGFloat = 440, height: CGFloat = 150
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
        heading.frame = NSRect(x: 16, y: height - 34, width: 200, height: 18)
        container.addSubview(heading)

        appPopup = NSPopUpButton(frame: NSRect(x: 16, y: height - 64, width: width - 32, height: 26), pullsDown: false)
        appPopup.target = self
        appPopup.action = #selector(pickApp(_:))
        appPopup.menu?.delegate = self          // rebuild the list each time it opens
        container.addSubview(appPopup)

        let hint = NSTextField(labelWithString: "Window-share the “Pancake Stage” window in Discord.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: height - 88, width: width - 32, height: 16)
        container.addSubview(hint)

        videoLabel = statusField(y: 30, in: container, width: width); videoLabel.stringValue = "video: starting…"
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

    // MARK: Picker

    private func enableAudioPicker() {
        rebuildPopup()
        // Auto-select the preferred app (Ableton) if it's tappable right now; otherwise wait for the
        // user to choose. We don't auto-tap a random app.
        if tappableApps().contains(where: { $0.bundleID == preferredBundleID }) {
            selectAndShare(preferredBundleID)
        } else {
            audioLabel.stringValue = "audio: pick an app to share ↑"
        }
    }

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

    func applicationWillTerminate(_ n: Notification) { audio.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
