import Foundation
import PancakeCore

/// Which half of the menu a device row belongs to. A pair of AirPods is two Core Audio devices —
/// `…:output` and `…:input` — so it can be pinned to each list independently.
enum DeviceRole: String, Codable, Hashable, CaseIterable {
    case output, input
    var title: String { self == .output ? "Output" : "Input" }
}

/// A device the user wants listed in the menu whether or not it's here — the AirPods that a phone
/// keeps stealing, the Bluetooth speaker that's usually off. Pinned rows sit in the list at their
/// usual place, dimmed while absent, and a Bluetooth one is a button that summons the device.
///
/// `uid` is the Core Audio device UID. For a device pinned from the paired-Bluetooth list we've
/// possibly never *seen* as an audio device, it's synthesised (`Bluetooth.deviceUID`) and healed
/// from the real device the first time it connects — along with the name, so the row matches what
/// the rest of the system calls it.
struct PinnedDevice: Codable, Hashable, Identifiable {
    var uid: String
    var name: String
    var role: DeviceRole

    var id: String { role.rawValue + "\u{0}" + uid }
    /// The Bluetooth address, when this is a Bluetooth device — what `connect` asks for.
    var bluetoothAddress: String? { Bluetooth.address(fromDeviceUID: uid) }
}

/// `~/.config/pancake/pins.json`, next to the graph. Deliberately *not* in the graph: pins are not
/// routing — the engine neither reads nor cares about them — and the graph file is the engine's IPC
/// (same reasoning as `graph-layout.json`). Small, sorted and hand-editable, like everything else here.
struct PinStore {
    let url = GraphStore.defaultURL.deletingLastPathComponent().appendingPathComponent("pins.json")

    private struct File: Codable { var pinned: [PinnedDevice] = [] }

    func load() -> [PinnedDevice] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.pinned
    }

    func save(_ pinned: [PinnedDevice]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(File(pinned: pinned)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// One row in the menu's Output or Input list: a device that's here, or a pinned (or wanted) one
/// that isn't. `uid` identifies it; Bluetooth UIDs are compared case-insensitively because
/// IOBluetooth and Core Audio disagree about the case of an address (see `Bluetooth`).
struct MenuDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    let role: DeviceRole
    let present: Bool
    let isBluetooth: Bool
    let pinned: Bool
    /// Built into the machine: it can't go away, so it sits at the top of its list and has no pin
    /// (pinning it would promise nothing it doesn't already do).
    var onboard: Bool = false
    /// What sort of Bluetooth device this is, when it's paired and we've looked: a speaker gets a
    /// speaker icon rather than the generic earbuds.
    var kind: Bluetooth.Kind? = nil
    /// Battery percentages to show under a Bluetooth row (left, right, case), when known.
    var battery: [Int] = []

    var id: String { uid }
    /// The Bluetooth address to summon this device with, if that's a thing that can be done to it.
    var address: String? { Bluetooth.address(fromDeviceUID: uid) }

    /// Device UIDs name the same device.
    static func sameUID(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }
}
