import CoreAudio
import Foundation

/// Watches the HAL for the events the engine cares about and delivers them on one queue.
public final class HardwareMonitor {
    public enum Event: Equatable, CustomStringConvertible {
        case devicesChanged
        case defaultOutputChanged
        case defaultSystemOutputChanged
        case defaultInputChanged
        /// The HAL's set of audio-producing processes changed: an app (or one of its helpers)
        /// launched or quit. What process taps key on.
        case processListChanged
        /// coreaudiod restarted (a driver install, a crash, `killall coreaudiod`). Every AudioObjectID
        /// we hold — our aggregate, our process taps — now refers to nothing.
        case serviceRestarted

        public var description: String {
            switch self {
            case .devicesChanged: return "devices changed"
            case .defaultOutputChanged: return "default output changed"
            case .defaultSystemOutputChanged: return "default system output changed"
            case .defaultInputChanged: return "default input changed"
            case .processListChanged: return "process list changed"
            case .serviceRestarted: return "coreaudiod restarted"
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
            (kAudioHardwarePropertyProcessObjectList, .processListChanged),
            (kAudioHardwarePropertyServiceRestarted, .serviceRestarted),
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
