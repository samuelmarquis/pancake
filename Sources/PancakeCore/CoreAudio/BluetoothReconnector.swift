import Foundation
import IOBluetooth

/// Asks macOS to (re)connect a Bluetooth audio device. This is what "aggressively get the
/// AirPods back" means in practice: the equivalent of `blueutil --connect`. Whether the
/// AirPods come is up to them (and the phone holding them); we can only ask.
public enum BluetoothReconnector {
    /// Bluetooth device UIDs look like `AA-BB-CC-DD-EE-FF:output`. Returns the address part.
    public static func address(fromDeviceUID uid: String) -> String? {
        let head = uid.split(separator: ":", maxSplits: 1).first.map(String.init) ?? uid
        let parts = head.split(separator: "-")
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return head
    }

    public static func isConnected(address: String) -> Bool {
        IOBluetoothDevice(addressString: address)?.isConnected() ?? false
    }

    /// Blocking; call off the main thread. Returns nil on success, otherwise a description.
    @discardableResult
    public static func connect(address: String) -> String? {
        guard let device = IOBluetoothDevice(addressString: address) else { return "unknown device \(address)" }
        if device.isConnected() { return nil }
        let status = device.openConnection()
        return status == kIOReturnSuccess ? nil : "openConnection failed: \(status)"
    }
}
