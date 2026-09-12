// List every CoreAudio output device with its UID and per-element volume.
//   swift listvol.swift
import Foundation
import CoreAudio

let sysObj = AudioObjectID(kAudioObjectSystemObject)

func devices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func str(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var cf: Unmanaged<CFString>? = nil
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let c = cf else { return "?" }
    return c.takeRetainedValue() as String
}

func hasOutput(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                          mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return false }
    let abl = buf.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + Int($1.mNumberChannels) } > 0
}

// Devices disagree about which element carries the volume control, so probe 0, 1, 2.
func volumes(_ id: AudioDeviceID) -> [(UInt32, Float32, Bool)] {
    var out: [(UInt32, Float32, Bool)] = []
    for el in [UInt32(0), 1, 2] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: el)
        guard AudioObjectHasProperty(id, &addr) else { continue }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { continue }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(id, &addr, &settable)
        out.append((el, v, settable.boolValue))
    }
    return out
}

for id in devices() where hasOutput(id) {
    let vs = volumes(id)
    let vdesc = vs.isEmpty ? "<no volume control>" :
        vs.map { "el\($0.0)=\(String(format: "%.4f", $0.1))\($0.2 ? "" : " (READ-ONLY)")" }
          .joined(separator: "  ")
    print(str(id, kAudioObjectPropertyName))
    print("   uid: \(str(id, kAudioDevicePropertyDeviceUID))")
    print("   vol: \(vdesc)")
}
