// List aggregate devices and their sub-devices.
//   swift lsaggregate.swift
// Useful for spotting aggregates that depend on a virtual device you're about
// to remove (see ../MIGRATION.md).
import Foundation
import CoreAudio

let sysObj = AudioObjectID(kAudioObjectSystemObject)

var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &size)
var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &ids)

func str(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var s = UInt32(MemoryLayout<CFString?>.size)
    var cf: Unmanaged<CFString>? = nil
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cf) == noErr, let c = cf else { return "?" }
    return c.takeRetainedValue() as String
}

for id in ids {
    var a = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    guard AudioObjectHasProperty(id, &a) else { continue }
    var s = UInt32(MemoryLayout<CFArray?>.size)
    var cf: Unmanaged<CFArray>? = nil
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cf) == noErr, let arr = cf else { continue }
    let subs = arr.takeRetainedValue() as? [String] ?? []
    print("AGGREGATE: \(str(id, kAudioObjectPropertyName))")
    print("   uid: \(str(id, kAudioDevicePropertyDeviceUID))")
    for sub in subs { print("   sub: \(sub)") }
    if subs.isEmpty { print("   sub: (none listed)") }
}
