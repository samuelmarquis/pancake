// Dump what the HAL thinks right now: plug-ins, every device (incl. hidden) with transport and
// hidden/running flags, process taps, the three system defaults, and processes running IO.
//   swift halstate.swift        (or compile it: swiftc -O -o halstate halstate.swift)
// Read-only. If coreaudiod is saturated this can hang on the first call — run it under a timeout
// (storm-snapshot.sh does).
import CoreAudio
import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let sys = AudioObjectID(kAudioObjectSystemObject)
func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain) }
func ids(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = addr(s); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(o, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    guard AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &out) == noErr else { return [] }
    return out }
func str(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s); guard AudioObjectHasProperty(o, &a) else { return "-" }
    var v: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &v) == noErr else { return "?" }
    return (v?.takeRetainedValue() as String?) ?? "nil" }
func u32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32? {
    var a = addr(s); guard AudioObjectHasProperty(o, &a) else { return nil }
    var v: UInt32 = 0; var sz = UInt32(4)
    return AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &v) == noErr ? v : nil }
func fourcc(_ v: UInt32?) -> String { guard let v else { return "-" }
    let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
    return b.allSatisfy { $0 >= 32 && $0 < 127 } ? String(bytes: b, encoding: .ascii)! : "\(v)" }
print("== plug-ins")
for p in ids(sys, kAudioHardwarePropertyPlugInList) { print("  \(p) \(str(p, kAudioPlugInPropertyBundleID))") }
print("== devices (incl. hidden)")
for d in ids(sys, kAudioHardwarePropertyDevices) {
    let plug = u32(d, kAudioDevicePropertyPlugIn).map { str(AudioObjectID($0), kAudioPlugInPropertyBundleID) } ?? "-"
    print("  \(d) uid=\(str(d, kAudioDevicePropertyDeviceUID)) name=\(str(d, kAudioObjectPropertyName)) transport=\(fourcc(u32(d, kAudioDevicePropertyTransportType))) hidden=\(u32(d, kAudioDevicePropertyIsHidden).map(String.init) ?? "-") running=\(u32(d, kAudioDevicePropertyDeviceIsRunningSomewhere).map(String.init) ?? "-") plugin=\(plug)")
}
print("== taps")
for t in ids(sys, kAudioHardwarePropertyTapList) { print("  \(t) uid=\(str(t, kAudioTapPropertyUID))") }
print("== defaults")
for (s, n) in [(kAudioHardwarePropertyDefaultOutputDevice, "output"), (kAudioHardwarePropertyDefaultSystemOutputDevice, "system"), (kAudioHardwarePropertyDefaultInputDevice, "input")] {
    let d = ids(sys, s).first ?? 0; print("  \(n): \(d) \(str(d, kAudioObjectPropertyName)) [\(str(d, kAudioDevicePropertyDeviceUID))]") }
print("== processes running IO")
for p in ids(sys, kAudioHardwarePropertyProcessObjectList) where (u32(p, kAudioProcessPropertyIsRunning) ?? 0) != 0 {
    print("  pid=\(u32(p, kAudioProcessPropertyPID).map(String.init) ?? "?") \(str(p, kAudioProcessPropertyBundleID)) in=\(u32(p, kAudioProcessPropertyIsRunningInput) ?? 0) out=\(u32(p, kAudioProcessPropertyIsRunningOutput) ?? 0)") }
print("done")
