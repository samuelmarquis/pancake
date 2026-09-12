import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

// Pancake Stage — a single shareable window that mirrors your desktop. You window-share THIS in
// Discord; because window-share scopes audio to this app's process, it never picks up the call's
// own audio. (Audio — playing the Pancake Program bus into this process — comes in the next
// milestone; this build is the video mirror.)

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
    private let excludeWindowID: CGWindowID
    var onStatus: ((String) -> Void)?

    init(view: MirrorView, excludeWindowID: CGWindowID) {
        self.view = view
        self.excludeWindowID = excludeWindowID
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
            // Exclude our own window so we don't capture ourselves (infinite mirror).
            let mine = content.windows.filter { $0.windowID == excludeWindowID }
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

final class StageDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var capture: Capture!
    var statusLabel: NSTextField!
    var audioLabel: NSTextField!
    let audio = StageAudio()
    /// The app whose audio to share. TODO: a picker; hardcoded to Ableton for bring-up.
    let shareBundleID = "com.ableton.live"

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)

        let mirror = MirrorView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        window = NSWindow(contentRect: mirror.bounds,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Pancake Stage"
        window.center()
        window.contentView = mirror

        // A small status strip so bring-up state is visible.
        func strip(_ y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: "")
            l.textColor = .white
            l.backgroundColor = NSColor.black.withAlphaComponent(0.5)
            l.drawsBackground = true
            l.font = .systemFont(ofSize: 11)
            l.frame = NSRect(x: 8, y: y, width: 900, height: 16)
            l.autoresizingMask = [.width]
            mirror.addSubview(l)
            return l
        }
        statusLabel = strip(26); statusLabel.stringValue = "video: starting…"
        audioLabel = strip(8);  audioLabel.stringValue = "audio: starting…"

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        capture = Capture(view: mirror, excludeWindowID: CGWindowID(window.windowNumber))
        capture.onStatus = { [weak self] s in self?.statusLabel.stringValue = "video: \(s)" }
        capture.start()

        // Tapping an app is "audio capture" to TCC, so we need Microphone permission (same gate
        // pancake's taps use). Ask, then start the audio once granted.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startAudio()
        case .notDetermined:
            audioLabel.stringValue = "audio: requesting microphone access…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.startAudio() }
                    else { self?.audioLabel.stringValue = "audio: microphone access denied — enable it in Settings" }
                }
            }
        default:
            audioLabel.stringValue = "audio: microphone access denied — enable it in Settings › Privacy › Microphone"
        }
    }

    private func startAudio() {
        let msg = audio.start(bundleID: shareBundleID)
        audioLabel.stringValue = "audio: \(msg)"
        NSLog("stage: audio: \(msg)")
    }

    func applicationWillTerminate(_ n: Notification) { audio.stop() }
}
