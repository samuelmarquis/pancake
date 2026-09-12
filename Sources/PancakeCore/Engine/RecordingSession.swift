import AudioToolbox
import CoreAudio
import CPancakeRT
import Foundation

public enum RecordingError: Error, CustomStringConvertible {
    case notRunning
    case noSlot
    case create(OSStatus)
    case setClientFormat(OSStatus)
    public var description: String {
        switch self {
        case .notRunning: return "the engine isn't running"
        case .noSlot: return "no recorder slot for that node (is it in the graph, under the \(PK_MAX_RECORDERS)-recorder limit?)"
        case .create(let s): return "couldn't create the audio file (OSStatus \(s))"
        case .setClientFormat(let s): return "couldn't set the recording format (OSStatus \(s))"
        }
    }
}

/// Where recordings go by default and how they're named. `~/Music/Pancake` (not `~/Documents`,
/// which is TCC-protected and would prompt; `~/Music` is where macOS audio apps write).
public enum RecordingLocation {
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Pancake", isDirectory: true)
    }
    /// A timestamped file in `folder` (default folder if nil): "Pancake 2026-09-12 at 18.03.24.wav".
    public static func defaultFile(in folder: URL? = nil, date: Date = Date()) -> URL {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return (folder ?? defaultFolder).appendingPathComponent("Pancake \(fmt.string(from: date)).wav")
    }
}

/// Drains one recorder's ring to a WAV file. Created and driven entirely on the engine queue (the
/// single consumer of the ring); the realtime IOProc is the single producer. 24-bit PCM WAV, stereo,
/// at the aggregate's sample rate; ExtAudioFile converts from the Float32 the ring holds.
final class RecordingSession {
    let url: URL
    let slot: UInt32
    let sampleRate: Double
    private let rt: OpaquePointer
    private var file: ExtAudioFileRef?
    private let chunk = 8192                     // frames per drain read
    private var scratch: [Float]
    private(set) var framesWritten: UInt64 = 0

    init(rt: OpaquePointer, slot: UInt32, url: URL, sampleRate: Double) throws {
        self.rt = rt
        self.slot = slot
        self.url = url
        self.sampleRate = sampleRate
        self.scratch = [Float](repeating: 0, count: chunk * Int(PK_REC_CHANNELS))

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let ch = PK_REC_CHANNELS
        // On-disk format: 24-bit signed PCM, little-endian (WAV default), interleaved.
        var fileFmt = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 3 * ch, mFramesPerPacket: 1, mBytesPerFrame: 3 * ch,
            mChannelsPerFrame: ch, mBitsPerChannel: 24, mReserved: 0)

        var f: ExtAudioFileRef?
        let cs = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &fileFmt, nil,
                                           AudioFileFlags.eraseFile.rawValue, &f)
        guard cs == noErr, let file = f else { throw RecordingError.create(cs) }
        self.file = file

        // What we hand ExtAudioFile: Float32 interleaved stereo (exactly the ring's layout).
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * ch, mFramesPerPacket: 1, mBytesPerFrame: 4 * ch,
            mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
        let ss = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard ss == noErr else {
            ExtAudioFileDispose(file); self.file = nil
            throw RecordingError.setClientFormat(ss)
        }
    }

    /// Pull everything available out of the ring and write it. Cheap when the ring is empty.
    @discardableResult
    func drain() -> Int {
        guard let file else { return 0 }
        var total = 0
        while true {
            let n = scratch.withUnsafeMutableBufferPointer { pk_recorder_read(rt, slot, $0.baseAddress!, UInt32(chunk)) }
            if n == 0 { break }
            let status = scratch.withUnsafeMutableBufferPointer { ptr -> OSStatus in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: PK_REC_CHANNELS,
                                          mDataByteSize: n * PK_REC_CHANNELS * 4,
                                          mData: ptr.baseAddress))
                return ExtAudioFileWrite(file, n, &abl)
            }
            if status != noErr { Log.warn("recorder \(slot): write failed (OSStatus \(status))"); break }
            total += Int(n)
            framesWritten += UInt64(n)
            if Int(n) < chunk { break }   // ring drained
        }
        return total
    }

    /// Final drain, then close the file. Idempotent.
    func close() {
        drain()
        if let file { ExtAudioFileDispose(file); self.file = nil }
    }
}
