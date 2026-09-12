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
// It's a faceless background helper: no Dock icon, no control panel. You drive it entirely from the
// pancake menu bar, which writes ~/.config/pancake/stage.json (StageConfig); the Stage watches that
// file and obeys. Its one window — the chrome-free "Pancake Stage" mirror — is always parked
// off-desktop (a 1pt on-screen sliver), so it's invisible to you but stays composited and listed in
// Discord's window picker. You just window-share "Pancake Stage".

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
    /// Our own window, excluded so we don't mirror ourselves (recursion).
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
            // Exclude our own window so we don't capture ourselves (infinite mirror).
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

// TappableApp + tappableApps() live in PancakeCore (shared with the menu bar).

final class StageDelegate: NSObject, NSApplicationDelegate {
    private var mirrorWindow: NSWindow!
    private var capture: Capture!
    private let audio = StageAudio()

    // The file IS the IPC. The menu bar writes it; we watch it and obey.
    private let store = StageStore()
    private var config = StageConfig()
    private var watcher: FileWatcher?
    private let ioQueue = DispatchQueue(label: "com.pancake.stage.config")

    /// The bundle id the audio tap is *actually* running on (vs. `config.bundleID`, the desired one).
    private var currentBundleID: String?
    /// Preferred app to select automatically when it becomes available (until an app is chosen).
    private let preferredBundleID = "com.ableton.live"
    /// Auto-select is a one-shot: it disarms as soon as any app has been chosen (here or in the
    /// menu), so we never override a later choice. Makes "start the share, then open Ableton" work.
    private var autoSelectArmed = true

    /// Fires when the HAL's process set changes — i.e. an app becomes (un)tappable. Drives auto-tap.
    private var processListener: PropertyListener?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)   // faceless: no Dock icon; driven from the menu bar
        buildMirrorWindow()

        // Exclude our own window from the capture (anti-recursion).
        let excluded: Set<CGWindowID> = [CGWindowID(mirrorWindow.windowNumber)]
        capture = Capture(view: mirrorWindow.contentView as! MirrorView, excludeWindowIDs: excluded)
        capture.onDisplaySize = { [weak self] size in self?.matchMirrorAspect(size) }
        capture.start()

        // Load the saved config and watch for edits (from the menu, us, or a text editor).
        config = (try? store.load()) ?? StageConfig()
        installConfigWatcher()

        // Tapping an app is "audio capture" to TCC → Microphone permission (same gate the engine's
        // taps use). Ask, then start the audio half.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            enableAudio()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.enableAudio() } else { NSLog("stage: microphone access denied") }
                }
            }
        default:
            NSLog("stage: microphone access denied")
        }

        // Report — via ScreenCaptureKit, the same API Discord uses — whether the parked window is
        // shareable, for the log.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.logShareability("launch") }
    }

    // MARK: Config (the IPC)

    private func installConfigWatcher() {
        watcher = store.watch(queue: ioQueue) { [weak self] in
            guard let self, let loaded = try? self.store.load() else { return }
            DispatchQueue.main.async {
                guard loaded != self.config else { return }   // ignore our own save coming back around
                NSLog("stage: config changed on disk; applying")
                self.applyConfig(loaded, persist: false)
            }
        }
    }

    /// Apply a config: reconcile the audio tap to `bundleID`, and (when the change is local) persist.
    private func applyConfig(_ new: StageConfig, persist: Bool) {
        config = new
        if new.bundleID != nil { autoSelectArmed = false }   // an app was chosen; stop auto-tapping
        if persist {
            do { try store.save(new) } catch { NSLog("stage: save config: \(error)") }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { applyAudio() }
    }

    /// Start/stop the tap so the running audio matches `config.bundleID`.
    private func applyAudio() {
        guard config.bundleID != currentBundleID else { return }
        if let bid = config.bundleID, !bid.isEmpty {
            currentBundleID = bid
            NSLog("stage: audio: \(audio.start(bundleID: bid))")
        } else {
            audio.stop()
            currentBundleID = nil
            NSLog("stage: audio stopped (none selected)")
        }
    }

    /// Mutate the config from a local trigger (auto-tap) and apply + persist it.
    private func update(_ mutate: (inout StageConfig) -> Void) {
        var c = config
        mutate(&c)
        applyConfig(c, persist: true)
    }

    // MARK: Mirror window — chrome-free and always parked off-desktop

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
        mirrorWindow.hasShadow = false
        // Live on every Space, so it's always on whatever desktop Discord is on — no hunting.
        mirrorWindow.collectionBehavior = [.canJoinAllSpaces]
        mirrorWindow.contentView = mirror
        // Position it off-desktop *before* ordering in, so it never flashes on-screen.
        mirrorWindow.setFrameOrigin(parkedOrigin(for: mirrorWindow.frame.size))
        mirrorWindow.orderFrontRegardless()
    }

    /// Origin that leaves the window's top-right corner 1pt inside the screen's bottom-left corner:
    /// on-screen (so it stays composited and in Discord's picker) but invisible behind the Dock.
    private func parkedOrigin(for size: NSSize) -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        return NSPoint(x: frame.minX + 1 - size.width, y: frame.minY + 1 - size.height)
    }

    /// Size the mirror to the display's exact aspect ratio (so Discord sees no letterbox bars),
    /// keeping it parked. The window stays full-size — only its position is off-desktop.
    private func matchMirrorAspect(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        mirrorWindow.contentAspectRatio = size
        let w: CGFloat = 1000
        mirrorWindow.setContentSize(NSSize(width: w, height: (w * size.height / size.width).rounded()))
        mirrorWindow.setFrameOrigin(parkedOrigin(for: mirrorWindow.frame.size))   // re-park at the new size
    }

    /// Log whether ScreenCaptureKit (Discord's own API) lists our parked window, in both filter
    /// modes. onScreenWindowsOnly:true is what a typical picker uses.
    private func logShareability(_ tag: String) {
        guard let win = mirrorWindow else { return }
        let id = CGWindowID(win.windowNumber)
        Task {
            for onScreenOnly in [true, false] {
                let mode = onScreenOnly ? "onScreen" : "all"
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenOnly) else {
                    NSLog("stage: shareability[\(tag)/\(mode)]: query failed"); continue
                }
                if let w = content.windows.first(where: { $0.windowID == id }) {
                    NSLog("stage: shareability[\(tag)/\(mode)]: LISTED title=\(w.title ?? "nil") isOnScreen=\(w.isOnScreen)")
                } else {
                    NSLog("stage: shareability[\(tag)/\(mode)]: NOT listed (windowID \(id))")
                }
            }
        }
    }

    // MARK: Auto-tap when the target app appears

    private func enableAudio() {
        installProcessListener()
        applyAudio()   // honour a bundleID already in the saved config
        guard config.bundleID == nil else { return }
        // Nothing chosen yet: auto-select the preferred app if it's tappable right now; otherwise
        // wait for the process listener to catch it launching (or for a menu pick).
        if autoSelectArmed && tappableApps().contains(where: { $0.bundleID == preferredBundleID }) {
            update { $0.bundleID = preferredBundleID }
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
        guard autoSelectArmed, config.bundleID == nil else { return }
        if tappableApps().contains(where: { $0.bundleID == preferredBundleID }) {
            NSLog("stage: preferred app became tappable — auto-selecting")
            update { $0.bundleID = preferredBundleID }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        processListener?.remove()
        watcher?.stop()
        audio.stop()
    }
}
