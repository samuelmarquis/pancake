import CoreAudio
import Foundation

/// What to build an aggregate device out of. Mirrors the composition dictionary that
/// `AudioHardwareCreateAggregateDevice` takes.
public struct AggregateComposition: Hashable {
    public struct SubDevice: Hashable {
        public var uid: String
        public var driftCompensation: Bool
        public init(uid: String, driftCompensation: Bool) {
            self.uid = uid
            self.driftCompensation = driftCompensation
        }
    }

    public struct Tap: Hashable {
        public var uid: String
        public var driftCompensation: Bool
        public init(uid: String, driftCompensation: Bool = true) {
            self.uid = uid
            self.driftCompensation = driftCompensation
        }
    }

    public var uid: String
    public var name: String
    public var subDevices: [SubDevice]
    public var taps: [Tap] = []
    /// The sub-device whose clock everything else is resampled to. Should be real hardware.
    public var mainSubDeviceUID: String?
    /// Private aggregates don't show up in Sound settings or to other apps.
    public var isPrivate = true
    public var isStacked = false

    public init(uid: String, name: String, subDevices: [SubDevice], taps: [Tap] = [], mainSubDeviceUID: String?, isPrivate: Bool = true) {
        self.uid = uid
        self.name = name
        self.subDevices = subDevices
        self.taps = taps
        self.mainSubDeviceUID = mainSubDeviceUID
        self.isPrivate = isPrivate
    }

    var dictionary: [String: Any] {
        var d: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceIsPrivateKey: isPrivate ? 1 : 0,
            kAudioAggregateDeviceIsStackedKey: isStacked ? 1 : 0,
            kAudioAggregateDeviceSubDeviceListKey: subDevices.map { sd -> [String: Any] in
                [kAudioSubDeviceUIDKey: sd.uid, kAudioSubDeviceDriftCompensationKey: sd.driftCompensation ? 1 : 0]
            },
        ]
        if let main = mainSubDeviceUID { d[kAudioAggregateDeviceMainSubDeviceKey] = main }
        if !taps.isEmpty {
            d[kAudioAggregateDeviceTapListKey] = taps.map { t -> [String: Any] in
                [kAudioSubTapUIDKey: t.uid, kAudioSubTapDriftCompensationKey: t.driftCompensation ? 1 : 0]
            }
        }
        return d
    }
}

/// A live aggregate device this process created. Destroyed on `destroy()` or deinit.
public final class AggregateDevice {
    public let id: AudioObjectID
    public let composition: AggregateComposition
    private var destroyed = false

    public static func create(_ composition: AggregateComposition) throws -> AggregateDevice {
        var id: AudioObjectID = kAudioObjectUnknown
        try check(AudioHardwareCreateAggregateDevice(composition.dictionary as CFDictionary, &id), "create aggregate \(composition.uid)")
        return AggregateDevice(id: id, composition: composition)
    }

    private init(id: AudioObjectID, composition: AggregateComposition) {
        self.id = id
        self.composition = composition
    }

    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        let status = AudioHardwareDestroyAggregateDevice(id)
        if status != noErr {
            Log.warn("destroy aggregate \(id): \(status.fourCharCodeDescription)")
        }
    }

    deinit { destroy() }

    // MARK: Inspection

    public var fullSubDeviceList: [String] {
        (try? id.getPropertyCFObject(.init(kAudioAggregateDevicePropertyFullSubDeviceList), as: [String].self)) ?? []
    }
    /// AudioObjectIDs of the active sub-devices. On macOS 26 these are the plain device IDs
    /// (not AudioSubDevice objects — querying kAudioSubDeviceProperty* on them returns 'who?'),
    /// so drift compensation can only be requested through the composition dictionary.
    public var activeSubDeviceIDs: [AudioObjectID] {
        (try? id.getPropertyArray(.init(kAudioAggregateDevicePropertyActiveSubDeviceList), of: AudioObjectID.self)) ?? []
    }
    public var mainSubDeviceUID: String? {
        try? id.getPropertyString(.init(kAudioAggregateDevicePropertyMainSubDevice))
    }
    public var nominalSampleRate: Double {
        (try? id.getProperty(.init(kAudioDevicePropertyNominalSampleRate), as: Float64.self)) ?? 0
    }
    public func setNominalSampleRate(_ rate: Double) throws {
        try id.setProperty(.init(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }
    public func streams(scope: AudioObjectPropertyScope) -> [AudioStreamInfo] {
        AudioStreamInfo.streams(of: id, scope: scope)
    }
    public func streamConfiguration(scope: AudioObjectPropertyScope) -> [Int] {
        id.streamConfiguration(scope: scope)
    }

    /// Everything the HAL will tell us about this aggregate, for probes and bug reports.
    public func describe() -> String {
        var lines: [String] = []
        lines.append("aggregate id=\(id) uid=\(composition.uid) rate=\(Int(nominalSampleRate)) main=\(mainSubDeviceUID ?? "?")")
        lines.append("  full sub-device list: \(fullSubDeviceList)")
        for sub in activeSubDeviceIDs {
            let name = (try? sub.getPropertyString(.init(kAudioObjectPropertyName))) ?? "?"
            let uid = (try? sub.getPropertyString(.init(kAudioDevicePropertyDeviceUID))) ?? "?"
            let rate = (try? sub.getProperty(.init(kAudioDevicePropertyNominalSampleRate), as: Float64.self)) ?? 0
            lines.append("  active sub-device \(sub): \(name) [\(uid)] @\(Int(rate))")
        }
        for (scope, label) in [(kAudioObjectPropertyScopeInput, "input"), (kAudioObjectPropertyScopeOutput, "output")] {
            lines.append("  \(label) ABL: \(streamConfiguration(scope: scope))")
            for s in streams(scope: scope) { lines.append("    \(s)") }
        }
        return lines.joined(separator: "\n")
    }
}
