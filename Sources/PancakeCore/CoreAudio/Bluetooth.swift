import Foundation
import IOBluetooth

/// The Bluetooth side of "give me my headphones back": which audio devices are paired, whether
/// they're here, and asking one to come. Connecting is the equivalent of `blueutil --connect` —
/// which is also how you *steal* a device back from a phone that's holding it. Whether it comes is
/// up to the device; we can only ask.
///
/// Addresses are spelled two ways on this machine and both turn up here: IOBluetooth says
/// `f0-04-e1-c9-6a-f8`, Core Audio says `F0-04-E1-C9-6A-F8:output`. Nothing compares them with `==`
/// — use `sameAddress`, and build UIDs with `deviceUID`.
public enum Bluetooth {
    /// A paired audio device, connected or not. This is what lets the menu list a device that has no
    /// Core Audio device at all right now (it's off, or a phone took it) and still offer to connect it.
    public struct Device: Hashable, Sendable, Identifiable {
        public let address: String
        public let name: String
        public let isConnected: Bool
        public let kind: Kind
        public var id: String { address }
    }

    /// What the device is, from its Bluetooth minor device class — enough to pick an icon, and to
    /// guess whether it can feed the Input list at all.
    public enum Kind: Sendable, Hashable {
        case headphones, headset, speaker, other

        /// Devices that plausibly carry a microphone. A loudspeaker doesn't, so the menu doesn't
        /// offer to pin one as an input. (A device that lies about its class can still be pinned
        /// from the Input list itself, while it's connected.)
        public var mayHaveMicrophone: Bool { self != .speaker }
    }

    /// Bluetooth device UIDs look like `AA-BB-CC-DD-EE-FF:output`. Returns the address part.
    public static func address(fromDeviceUID uid: String) -> String? {
        let head = uid.split(separator: ":", maxSplits: 1).first.map(String.init) ?? uid
        let parts = head.split(separator: "-")
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return head
    }

    /// The same device? Addresses differ in case between IOBluetooth and Core Audio.
    public static func sameAddress(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    /// The Core Audio device UID macOS gives a Bluetooth device's output (or input) half — how a
    /// device that has never been connected while pancake watched gets named in the graph and pins.
    /// If the real UID ever turns up spelled differently, the pin heals itself from the live device.
    public static func deviceUID(address: String, input: Bool) -> String {
        address.uppercased() + (input ? ":input" : ":output")
    }

    /// Every paired device whose *major* class is Audio — headsets, headphones, speakers. Mice and
    /// keyboards (major class Peripheral) and BLE-only gadgets (which report no class at all) are
    /// left out. Cheap, but it's an IPC to bluetoothd: call it off the main thread.
    public static func pairedAudioDevices() -> [Device] {
        let paired = IOBluetoothDevice.pairedDevices() ?? []
        return paired.compactMap { entry -> Device? in
            guard let d = entry as? IOBluetoothDevice,
                  d.deviceClassMajor == kBluetoothDeviceClassMajorAudio,
                  let address = d.addressString else { return nil }
            return Device(address: address,
                          name: d.name ?? address,
                          isConnected: d.isConnected(),
                          kind: kind(minorClass: d.deviceClassMinor))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func kind(minorClass: BluetoothDeviceClassMinor) -> Kind {
        switch Int(minorClass) {
        case kBluetoothDeviceClassMinorAudioHeadphones: return .headphones
        case kBluetoothDeviceClassMinorAudioHeadset, kBluetoothDeviceClassMinorAudioHandsFree: return .headset
        case kBluetoothDeviceClassMinorAudioLoudspeaker, kBluetoothDeviceClassMinorAudioHiFi,
             kBluetoothDeviceClassMinorAudioPortable: return .speaker
        default: return .other
        }
    }

    // MARK: Headphone status and listening mode (private API, read the comment)

    /// What the AirPods menu shows and lets you change: Off / Noise Cancellation / Transparency /
    /// Adaptive. Raw values are what bluetoothd uses for `listeningMode` (established live on
    /// 2026-10-11: 2 is what the Apple menu calls Noise Cancellation, 3 is Off).
    public enum ListeningMode: UInt8, CaseIterable, Sendable, Hashable {
        case transparency = 1, noiseCancellation = 2, off = 3, adaptive = 4

        public var title: String {
            switch self {
            case .off: return "Off"
            case .noiseCancellation: return "Noise Cancellation"
            case .transparency: return "Transparency"
            case .adaptive: return "Adaptive"
            }
        }
        /// The order the Apple menu lists them in.
        public static let menuOrder: [ListeningMode] = [.off, .noiseCancellation, .transparency, .adaptive]
    }

    /// What a connected pair of Apple headphones reports about itself: the current listening mode
    /// (nil for a device that doesn't have one), which modes it offers, and battery per part.
    public struct HeadphoneStatus: Equatable, Sendable {
        public var mode: ListeningMode?
        public var modes: [ListeningMode]
        /// Left, right, case — only the parts that report (a speaker reports one, as "left").
        public var battery: [Int]
    }

    /// Read what bluetoothd knows about a paired device. Returns nil when there's nothing to show
    /// (not an Apple audio device, or no status at all).
    ///
    /// **This is private API, and here's why it's acceptable.** There is no public way to read or
    /// set a listening mode. What there is: IOBluetooth's device object wraps CoreBluetooth's
    /// `CBClassicPeer`, which bluetoothd keeps *live* in every client process — mode, mode cycle,
    /// in-ear, per-bud battery — and whose `setListeningMode:` is real code (it compares against the
    /// current value and, if different, sends bluetoothd message 0x30), not a field store. Measured
    /// 2026-10-11 from an unentitled process: the write lands on the AirPods within a second, the
    /// user heard it. Everything else that could do this needs `com.apple.bluetooth.system`
    /// (CLAUDE.md). All of it is reached by selector, so if Apple renames or removes a method the
    /// result is a missing control in the menu, never a crash: every selector is checked first.
    public static func headphoneStatus(address: String) -> HeadphoneStatus? {
        guard let device = IOBluetoothDevice(addressString: address), device.isConnected(),
              let peer = Private.peer(of: device) else { return nil }
        let raw = Private.u8(peer, "listeningMode")
        let mode = raw.flatMap(ListeningMode.init(rawValue:))
        var battery: [Int] = []
        for key in ["batteryPercentLeft", "batteryPercentRight", "batteryPercentCase"] {
            if let v = Private.u8(peer, key), v > 0 { battery.append(Int(v)) }
        }
        if battery.isEmpty, let v = Private.u8(peer, "batteryPercentSingle"), v > 0 { battery.append(Int(v)) }
        guard mode != nil || !battery.isEmpty else { return nil }
        let modes: [ListeningMode] = mode == nil ? [] : ListeningMode.menuOrder.filter {
            $0 != .adaptive || Private.supportsAdaptive(peer: peer)
        }
        return HeadphoneStatus(mode: mode, modes: modes, battery: battery)
    }

    /// Ask bluetoothd to put the device in this mode. Returns false if the ask couldn't even be
    /// made; whether it *took* is only knowable by reading `headphoneStatus` again a moment later —
    /// the caller does that. Call off the main thread (it's an IPC), from a process whose main run
    /// loop is live (the XPC link to bluetoothd needs it; a cold process's first write is dropped).
    @discardableResult
    public static func setListeningMode(_ mode: ListeningMode, address: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address), device.isConnected(),
              let peer = Private.peer(of: device) else { return false }
        return Private.setU8(peer, "setListeningMode:", mode.rawValue)
    }

    /// The selector plumbing, kept in one place. Every call checks `responds(to:)` first.
    private enum Private {
        static func peer(of device: IOBluetoothDevice) -> NSObject? {
            let sel = NSSelectorFromString("classicPeer")
            guard device.responds(to: sel) else { return nil }
            return device.perform(sel)?.takeUnretainedValue() as? NSObject
        }

        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        typealias SetterU8 = @convention(c) (AnyObject, Selector, UInt8) -> Void

        /// A scalar getter, read as its low byte — these are all `unsigned char` properties.
        static func u8(_ obj: NSObject, _ name: String) -> UInt8? {
            let sel = NSSelectorFromString(name)
            guard let m = class_getInstanceMethod(type(of: obj), sel),
                  let enc = method_getTypeEncoding(m), "CcBIi".contains(Character(UnicodeScalar(UInt8(enc.pointee)))) else { return nil }
            return UInt8(truncatingIfNeeded: unsafeBitCast(method_getImplementation(m), to: Getter.self)(obj, sel))
        }

        static func setU8(_ obj: NSObject, _ name: String, _ value: UInt8) -> Bool {
            let sel = NSSelectorFromString(name)
            guard let m = class_getInstanceMethod(type(of: obj), sel) else { return false }
            unsafeBitCast(method_getImplementation(m), to: SetterU8.self)(obj, sel, value)
            return true
        }

        /// Adaptive exists on the second-generation AirPods Pro and later. No capability bit for it
        /// has been identified, so this is by product id; a device not listed gets the three modes
        /// every ANC pair has.
        static func supportsAdaptive(peer: NSObject) -> Bool {
            let sel = NSSelectorFromString("productID")
            guard let m = class_getInstanceMethod(type(of: peer), sel) else { return false }
            let pid = unsafeBitCast(method_getImplementation(m), to: Getter.self)(peer, sel) & 0xffff
            return [0x2014, 0x2024, 0x2019, 0x201f, 0x2029].contains(pid)
        }
    }

    /// Is there a Core Audio device — the `:output` or `:input` half — for this address? That, and not
    /// IOBluetooth's `isConnected()`, is what "connected" has to mean here: see `summon`.
    public static func hasAudioDevice(address: String) -> Bool {
        AudioDevice.all().contains { dev in
            Self.address(fromDeviceUID: dev.uid).map { sameAddress($0, address) } ?? false
        }
    }

    /// Bring a paired device's audio here, escalating until it comes or the deadline passes. Returns
    /// nil once an audio device for the address exists, otherwise what was tried. Blocking, and it
    /// returns within `deadline` (plus a poll interval) — call it off the main thread.
    ///
    /// Why this is more than one call. **While a phone is holding a pair of AirPods, this Mac still
    /// reports `isConnected() == true` for them** — a link exists, it just isn't carrying audio — and
    /// in that state `openConnection()` returns success *instantly* having done nothing at all
    /// (measured 2026-09-22: three asks, 20 ms each, "connected" every time, while the AirPods stayed
    /// on the phone and no audio device ever appeared). That's why "Connect" in the menu could report
    /// success and then time out as unreachable.
    ///
    /// The way through is to stop believing that link and force a real one: `closeConnection()` drops
    /// our stale end, and an SDP query *requires* a live ACL connection, so asking for one makes
    /// IOBluetooth page the device for real — after which macOS's own Bluetooth audio driver connects
    /// the profile and the device appears. Live, with the phone holding them: 1.7 s.
    ///
    /// Why nothing here blocks on IOBluetooth. A synchronous `openConnection()` sits for the whole of
    /// bluetoothd's page — 15 s for an address that never answers, 20 s for the AirPods when they're
    /// in the case — and `openConnection:withPageTimeout:` is ignored (measured 2026-09-24: asked for
    /// 1 s and 3 s, blocked 15.4 s both times). A 12 s deadline can't bound that, so the menu was
    /// saying "unreachable" while the page was still running, and a second click queued a second
    /// page behind it. So pages and SDP queries go out asynchronously (the completion arrives on the
    /// main run loop), and this polls the HAL for the audio device at its own pace. A page that
    /// bluetoothd is still running after we've given up can still land the device — the AirPods
    /// arrived 28 s after the first click on 2026-09-24 — and callers treat that arrival as the
    /// answer to their ask (`AppModel.awaiting`, the engine's rebuild).
    ///
    /// One ask per device at a time, process-wide: the menu and the engine are both allowed to ask,
    /// and a second caller waits for the first instead of paging on top of it.
    @discardableResult
    public static func summon(address: String, deadline: TimeInterval = 12) -> String? {
        guard let device = IOBluetoothDevice(addressString: address) else { return "unknown device \(address)" }
        let end = Date().addingTimeInterval(deadline)
        guard let link = Link.claim(address: address, until: end) else {
            return hasAudioDevice(address: address) ? nil : "an earlier ask for it is still in progress"
        }
        defer { link.release() }
        if hasAudioDevice(address: address) { return nil }

        let name = device.name ?? address
        var tried: [String] = []
        // A link that's up before we've asked for anything is the stale one: escalate at once. A link
        // that comes up *during* the ask gets `linkGrace` for the audio driver to follow it.
        var linkSince: Date? = device.isConnected() ? .distantPast : nil
        var lastPage = Date.distantPast

        while true {
            if hasAudioDevice(address: address) { return nil }
            let now = Date()
            guard now < end else { break }

            if device.isConnected() {
                if linkSince == nil { linkSince = now }
                if now.timeIntervalSince(linkSince!) >= linkGrace {
                    let closed = device.closeConnection()
                    Thread.sleep(forTimeInterval: 0.75)   // the stale "connected" doesn't clear instantly
                    let sdp = link.page { device.performSDPQuery($0) }
                    tried.append("close=\(describe(closed)) sdp=\(describe(sdp))")
                    Log.info("bluetooth: \(name) didn't come; dropped the stale link and paged it again")
                    linkSince = nil
                    lastPage = Date()
                }
            } else {
                linkSince = nil
                if !link.pagePending, now.timeIntervalSince(lastPage) >= 2 {
                    // The plain ask, for a device that's simply away (off, out of range, idle). If
                    // bluetoothd won't even start one, nothing below will do better.
                    let r = link.page { device.openConnection($0) }
                    tried.append("page=\(describe(r))")
                    if r != kIOReturnSuccess { break }
                    lastPage = now
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if hasAudioDevice(address: address) { return nil }
        if let status = link.lastPageStatus { tried.append("last page ended \(describe(status))") }
        else if link.pagePending { tried.append("bluetoothd is still paging it") }
        return "no audio device after \(tried.joined(separator: ", "))"
    }

    /// How long a link that appeared during an ask gets to grow an audio device before we decide
    /// it's the stale kind and take it apart. The real thing follows in 1–2 s.
    private static let linkGrace: TimeInterval = 3

    private static func describe(_ r: IOReturn) -> String {
        switch r {
        case kIOReturnSuccess: return "ok"
        case kIOReturnTimeout: return "timed out"
        default: return "0x" + String(UInt32(bitPattern: r), radix: 16)
        }
    }

    /// The in-flight ask for one address: the lock that serialises callers, and the target that
    /// IOBluetooth tells when a page it issued for us has ended (on the main run loop — which is
    /// why nothing here waits for it; `summon` polls the HAL instead).
    private final class Link: NSObject {
        private static let lock = NSCondition()
        private static var links: [String: Link] = [:]   // by lowercased address; kept once created

        private var claimed = false
        private var pending = false
        private var status: IOReturn?

        /// Wait for any earlier ask for this address to finish, up to `until`. Nil if it hasn't by then.
        static func claim(address: String, until: Date) -> Link? {
            let key = address.lowercased()
            lock.lock(); defer { lock.unlock() }
            let link = links[key] ?? { let l = Link(); links[key] = l; return l }()
            while link.claimed {
                guard lock.wait(until: until) else { return nil }
            }
            link.claimed = true
            return link
        }

        func release() {
            Self.lock.lock(); claimed = false; Self.lock.broadcast(); Self.lock.unlock()
        }

        /// Issue an asynchronous page (open connection, SDP query) with this as the completion target.
        func page(_ issue: (Link) -> IOReturn) -> IOReturn {
            Self.lock.lock(); pending = true; status = nil; Self.lock.unlock()
            let r = issue(self)
            if r != kIOReturnSuccess { Self.lock.lock(); pending = false; Self.lock.unlock() }
            return r
        }

        var pagePending: Bool { Self.lock.lock(); defer { Self.lock.unlock() }; return pending }
        var lastPageStatus: IOReturn? { Self.lock.lock(); defer { Self.lock.unlock() }; return status }

        @objc func connectionComplete(_ device: IOBluetoothDevice, status s: IOReturn) {
            Self.lock.lock(); pending = false; status = s; Self.lock.unlock()
        }
        @objc func sdpQueryComplete(_ device: IOBluetoothDevice, status s: IOReturn) {
            Self.lock.lock(); pending = false; status = s; Self.lock.unlock()
        }
    }
}
