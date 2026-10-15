import CoreGraphics

/// Whether the Mac's display is asleep. The engine's one use: a dark wake (the sleeping Mac's
/// periodic maintenance wake, display off) parks the audio hardware, so an IOProc that has stopped
/// cycling then is the system's doing, not a fault to rebuild over. Asked only when IO has already
/// been seen not cycling, so the WindowServer round-trip costs nothing in normal running.
enum SystemDisplay {
    static var isAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
}
