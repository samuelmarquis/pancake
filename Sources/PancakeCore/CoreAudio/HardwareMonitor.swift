import CoreAudio
import Foundation

/// Watches the HAL for the events the engine cares about and delivers them on one queue.
public final class HardwareMonitor {
    public enum Event: Equatable, CustomStringConvertible {
        case devicesChanged
        case defaultOutputChanged
        case defaultSystemOutputChanged
        case defaultInputChanged

        public var description: String {
            switch self {
            case .devicesChanged: return "devices changed"
            case .defaultOutputChanged: return "default output changed"
            case .defaultSystemOutputChanged: return "default system output changed"
            case .defaultInputChanged: return "default input changed"
            }
        }
    }

    private var listeners: [PropertyListener] = []

    public init(queue: DispatchQueue, handler: @escaping (Event) -> Void) throws {
        let subscriptions: [(AudioObjectPropertySelector, Event)] = [
            (kAudioHardwarePropertyDevices, .devicesChanged),
            (kAudioHardwarePropertyDefaultOutputDevice, .defaultOutputChanged),
            (kAudioHardwarePropertyDefaultSystemOutputDevice, .defaultSystemOutputChanged),
            (kAudioHardwarePropertyDefaultInputDevice, .defaultInputChanged),
        ]
        for (selector, event) in subscriptions {
            listeners.append(try systemAudioObject.addPropertyListener(.init(selector), queue: queue) { handler(event) })
        }
    }

    public func stop() {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
    }

    deinit { stop() }
}
