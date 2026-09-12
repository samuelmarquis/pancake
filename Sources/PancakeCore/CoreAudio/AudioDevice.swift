import CoreAudio
import Foundation

public enum TransportType: Hashable, CustomStringConvertible {
    case builtIn, bluetooth, bluetoothLE, usb, virtual, aggregate, airPlay, thunderbolt, pci, fireWire, hdmi, displayPort, avb, continuityCapture, unknown(UInt32)

    init(raw: UInt32) {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAVB: self = .avb
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: self = .continuityCapture
        default: self = .unknown(raw)
        }
    }

    public var description: String {
        switch self {
        case .builtIn: return "built-in"
        case .bluetooth: return "bluetooth"
        case .bluetoothLE: return "bluetooth-le"
        case .usb: return "usb"
        case .virtual: return "virtual"
        case .aggregate: return "aggregate"
        case .airPlay: return "airplay"
        case .thunderbolt: return "thunderbolt"
        case .pci: return "pci"
        case .fireWire: return "firewire"
        case .hdmi: return "hdmi"
        case .displayPort: return "displayport"
        case .avb: return "avb"
        case .continuityCapture: return "continuity"
        case .unknown(let raw): return OSStatus(bitPattern: raw).fourCharCodeDescription
        }
    }

    /// Bluetooth devices are the ones that drop into headset (SCO) mode when their input runs.
    public var isBluetooth: Bool { self == .bluetooth || self == .bluetoothLE }
}

/// A snapshot of one CoreAudio device. Value type; re-fetch with `AudioDevice.all()` after a
/// hardware change rather than holding on to these.
public struct AudioDevice: Identifiable, Hashable, CustomStringConvertible {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: TransportType
    /// Channels per input stream, in AudioBufferList order. Empty for output-only devices.
    public let inputStreamChannels: [Int]
    /// Channels per output stream, in AudioBufferList order.
    public let outputStreamChannels: [Int]
    public let nominalSampleRate: Double
    public let isHidden: Bool

    public var inputChannels: Int { inputStreamChannels.reduce(0, +) }
    public var outputChannels: Int { outputStreamChannels.reduce(0, +) }
    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }
    /// Virtual and aggregate devices are software; pancake never treats them as a physical sink.
    public var isSoftware: Bool { transport == .virtual || transport == .aggregate }

    public var description: String {
        "\(name) [\(uid)] \(transport) in:\(inputStreamChannels) out:\(outputStreamChannels) @\(Int(nominalSampleRate))"
    }

    public init(id: AudioObjectID) throws {
        self.id = id
        uid = try id.getPropertyString(.init(kAudioDevicePropertyDeviceUID))
        name = (try? id.getPropertyString(.init(kAudioObjectPropertyName))) ?? uid
        transport = TransportType(raw: (try? id.getProperty(.init(kAudioDevicePropertyTransportType), as: UInt32.self)) ?? 0)
        inputStreamChannels = id.streamConfiguration(scope: kAudioObjectPropertyScopeInput)
        outputStreamChannels = id.streamConfiguration(scope: kAudioObjectPropertyScopeOutput)
        nominalSampleRate = (try? id.getProperty(.init(kAudioDevicePropertyNominalSampleRate), as: Float64.self)) ?? 0
        isHidden = ((try? id.getProperty(.init(kAudioDevicePropertyIsHidden), as: UInt32.self)) ?? 0) != 0
    }

    // MARK: Enumeration

    public static func allIDs() -> [AudioObjectID] {
        (try? systemAudioObject.getPropertyArray(.init(kAudioHardwarePropertyDevices), of: AudioObjectID.self)) ?? []
    }

    public static func all(includeHidden: Bool = false) -> [AudioDevice] {
        allIDs().compactMap { try? AudioDevice(id: $0) }.filter { includeHidden || !$0.isHidden }
    }

    public static func id(forUID uid: String) -> AudioObjectID? {
        let cf = uid as CFString
        guard let id = try? systemAudioObject.getProperty(.init(kAudioHardwarePropertyTranslateUIDToDevice), qualifier: cf, as: AudioObjectID.self),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    public static func find(uid: String) -> AudioDevice? {
        guard let id = id(forUID: uid) else { return nil }
        return try? AudioDevice(id: id)
    }

    /// Resolves a user-supplied name: exact UID, then case-insensitive name, then unique name prefix.
    public static func find(nameOrUID query: String, in devices: [AudioDevice]? = nil) -> AudioDevice? {
        let devices = devices ?? all(includeHidden: true)
        if let d = devices.first(where: { $0.uid == query }) { return d }
        if let d = devices.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) { return d }
        let prefix = devices.filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
        return prefix.count == 1 ? prefix[0] : nil
    }

    // MARK: Defaults

    public static var defaultOutputID: AudioObjectID? {
        get { try? systemAudioObject.getProperty(.init(kAudioHardwarePropertyDefaultOutputDevice), as: AudioObjectID.self) }
    }
    public static var defaultSystemOutputID: AudioObjectID? {
        get { try? systemAudioObject.getProperty(.init(kAudioHardwarePropertyDefaultSystemOutputDevice), as: AudioObjectID.self) }
    }
    public static var defaultInputID: AudioObjectID? {
        get { try? systemAudioObject.getProperty(.init(kAudioHardwarePropertyDefaultInputDevice), as: AudioObjectID.self) }
    }

    public static func setDefaultOutput(_ id: AudioObjectID) throws {
        try systemAudioObject.setProperty(.init(kAudioHardwarePropertyDefaultOutputDevice), id)
    }
    public static func setDefaultSystemOutput(_ id: AudioObjectID) throws {
        try systemAudioObject.setProperty(.init(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
    }
    public static func setDefaultInput(_ id: AudioObjectID) throws {
        try systemAudioObject.setProperty(.init(kAudioHardwarePropertyDefaultInputDevice), id)
    }

    // MARK: Live queries (not cached in the snapshot)

    public var isAlive: Bool {
        ((try? id.getProperty(.init(kAudioDevicePropertyDeviceIsAlive), as: UInt32.self)) ?? 0) != 0
    }
    public var isRunningSomewhere: Bool {
        ((try? id.getProperty(.init(kAudioDevicePropertyDeviceIsRunningSomewhere), as: UInt32.self)) ?? 0) != 0
    }
    public func availableSampleRates() -> [ClosedRange<Double>] {
        let ranges = (try? id.getPropertyArray(.init(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)) ?? []
        return ranges.map { $0.mMinimum...$0.mMaximum }
    }
    public func canBeDefault(scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Bool {
        ((try? id.getProperty(.init(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: scope), as: UInt32.self)) ?? 0) != 0
    }
    public func setNominalSampleRate(_ rate: Double) throws {
        try id.setProperty(.init(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }
    // MARK: Hardware output volume

    /// Output volume elements that exist and are settable, with their current values. Devices
    /// disagree about where the control lives — the built-in speakers expose the main element
    /// (0), the AirPods expose 1 and 2 and no main — so always iterate; never assume element 0.
    public func outputVolumes() -> [UInt32: Float32] {
        var volumes: [UInt32: Float32] = [:]
        for element in UInt32(0)...UInt32(max(2, outputChannels)) {
            let address = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            guard id.hasProperty(address), (try? id.isPropertySettable(address)) == true,
                  let value = try? id.getProperty(address, as: Float32.self) else { continue }
            volumes[element] = value
        }
        return volumes
    }

    /// Writes one value to the given output volume elements (see `outputVolumes()`).
    public func setOutputVolume(_ value: Float32, elements: [UInt32]) throws {
        for element in elements {
            let address = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            try id.setProperty(address, value)
        }
    }

    /// A single 0…1 reading of the device's output volume — the main element if it has one, else
    /// the mean of the per-channel elements. Nil if the device exposes no output volume control.
    public var outputVolumeScalar: Float32? {
        let vols = outputVolumes()
        if let main = vols[0] { return main }
        guard !vols.isEmpty else { return nil }
        return vols.values.reduce(0, +) / Float32(vols.count)
    }

    /// Writes one value to every settable output volume element the device has.
    public func setOutputVolumeScalar(_ value: Float32) throws {
        let elements = outputVolumes().keys.sorted()
        guard !elements.isEmpty else { return }
        try setOutputVolume(max(0, min(1, value)), elements: elements)
    }

    private var outputMuteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: kAudioObjectPropertyElementMain)
    }
    /// Output mute state on the main element, or nil if the device has no mute control.
    public var outputMuted: Bool? {
        guard id.hasProperty(outputMuteAddress) else { return nil }
        return ((try? id.getProperty(outputMuteAddress, as: UInt32.self)) ?? 0) != 0
    }
    public func setOutputMuted(_ muted: Bool) throws {
        guard id.hasProperty(outputMuteAddress), (try? id.isPropertySettable(outputMuteAddress)) == true else { return }
        try id.setProperty(outputMuteAddress, UInt32(muted ? 1 : 0))
    }

    public func streams(scope: AudioObjectPropertyScope) -> [AudioStreamInfo] {
        AudioStreamInfo.streams(of: id, scope: scope)
    }
}

/// One stream of a device, with the bits the engine cares about.
public struct AudioStreamInfo: CustomStringConvertible {
    public let id: AudioStreamID
    public let isInput: Bool
    public let startingChannel: UInt32
    public let isActive: Bool
    public let owner: AudioObjectID
    public let virtualFormat: AudioStreamBasicDescription?

    public var channels: Int { Int(virtualFormat?.mChannelsPerFrame ?? 0) }

    /// True when the HAL will hand us this stream as Float32 interleaved — the only format pk_ioproc understands.
    public var isFloat32Interleaved: Bool {
        guard let f = virtualFormat else { return false }
        return f.mFormatID == kAudioFormatLinearPCM
            && (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            && f.mBitsPerChannel == 32
    }

    public var description: String {
        let f = virtualFormat.map { "\(Int($0.mSampleRate))Hz \($0.mChannelsPerFrame)ch \($0.mBitsPerChannel)bit\(isFloat32Interleaved ? " f32i" : " (unexpected format)")" } ?? "?"
        return "stream \(id) \(isInput ? "in" : "out") start=\(startingChannel) active=\(isActive) owner=\(owner) \(f)"
    }

    public static func streams(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioStreamInfo] {
        let ids = (try? device.getPropertyArray(.init(kAudioDevicePropertyStreams, scope: scope), of: AudioStreamID.self)) ?? []
        return ids.map { sid in
            AudioStreamInfo(
                id: sid,
                isInput: ((try? sid.getProperty(.init(kAudioStreamPropertyDirection), as: UInt32.self)) ?? 0) == 1,
                startingChannel: (try? sid.getProperty(.init(kAudioStreamPropertyStartingChannel), as: UInt32.self)) ?? 0,
                isActive: ((try? sid.getProperty(.init(kAudioStreamPropertyIsActive), as: UInt32.self)) ?? 1) != 0,
                owner: (try? sid.getProperty(.init(kAudioObjectPropertyOwner), as: AudioObjectID.self)) ?? kAudioObjectUnknown,
                virtualFormat: try? sid.getProperty(.init(kAudioStreamPropertyVirtualFormat), as: AudioStreamBasicDescription.self)
            )
        }.sorted { $0.startingChannel < $1.startingChannel }
    }

    public func setActive(_ active: Bool) throws {
        try id.setProperty(.init(kAudioStreamPropertyIsActive), UInt32(active ? 1 : 0))
    }
}
