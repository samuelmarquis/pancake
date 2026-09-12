// Set a CoreAudio device's hardware output volume.
//   swift setvol.swift <deviceUID> <0.0-1.0>
// Writes every settable volume element, since devices differ (AirPods use
// elements 1+2, built-in speakers use element 0).
import Foundation
import CoreAudio

let args = CommandLine.arguments
guard args.count == 3, let target = Float32(args[2]) else {
    FileHandle.standardError.write("usage: setvol <uid> <0..1>\n".data(using: .utf8)!)
    exit(2)
}
let wantUID = args[1]
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

for id in ids where str(id, kAudioDevicePropertyDeviceUID) == wantUID {
    var changed = false
    for el in [UInt32(0), 1, 2] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                           mScope: kAudioDevicePropertyScopeOutput, mElement: el)
        guard AudioObjectHasProperty(id, &a) else { continue }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(id, &a, &settable)
        guard settable.boolValue else { continue }
        var v = target
        let st = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if st == noErr { changed = true; print("set el\(el) -> \(target)") }
        else { print("el\(el) set FAILED status=\(st)") }
    }
    exit(changed ? 0 : 1)
}
print("device not found: \(wantUID)")
exit(1)
