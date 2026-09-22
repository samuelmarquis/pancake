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

    /// Is there a Core Audio device — the `:output` or `:input` half — for this address? That, and not
    /// IOBluetooth's `isConnected()`, is what "connected" has to mean here: see `summon`.
    public static func hasAudioDevice(address: String) -> Bool {
        AudioDevice.all().contains { dev in
            Self.address(fromDeviceUID: dev.uid).map { sameAddress($0, address) } ?? false
        }
    }

    /// Bring a paired device's audio here, escalating until it comes or the deadline passes. Returns
    /// nil once an audio device for the address exists, otherwise what was tried. Blocking — call it
    /// off the main thread.
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
    @discardableResult
    public static func summon(address: String, deadline: TimeInterval = 12) -> String? {
        guard let device = IOBluetoothDevice(addressString: address) else { return "unknown device \(address)" }
        if hasAudioDevice(address: address) { return nil }
        let end = Date().addingTimeInterval(deadline)
        var tried: [String] = []

        // The plain ask, for a device that's simply away (off, out of range, idle).
        if !device.isConnected() {
            tried.append("openConnection=\(device.openConnection())")
            if waitForAudio(address: address, until: min(end, Date().addingTimeInterval(4))) { return nil }
        }

        // Still no audio: the link is stale, or the plain ask wasn't enough. Take it apart and rebuild
        // it, for as long as the deadline allows.
        while Date() < end {
            let closed = device.closeConnection()
            Thread.sleep(forTimeInterval: 0.75)   // the stale "connected" doesn't clear instantly
            let sdp = device.performSDPQuery(nil)
            tried.append("close=\(closed) sdp=\(sdp)")
            Log.info("bluetooth: \(device.name ?? address) didn't come; dropped the stale link and paged it again")
            if waitForAudio(address: address, until: min(end, Date().addingTimeInterval(5))) { return nil }
        }
        return "no audio device after \(tried.joined(separator: ", "))"
    }

    private static func waitForAudio(address: String, until: Date) -> Bool {
        repeat {
            if hasAudioDevice(address: address) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < until
        return hasAudioDevice(address: address)
    }
}
