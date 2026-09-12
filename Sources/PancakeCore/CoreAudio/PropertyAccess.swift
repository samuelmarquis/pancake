import CoreAudio
import Foundation

/// A CoreAudio call failed. `status` is the raw OSStatus; `context` says what was being done.
public struct CoreAudioError: Error, CustomStringConvertible, Equatable {
    public let status: OSStatus
    public let context: String

    public init(_ status: OSStatus, _ context: String) {
        self.status = status
        self.context = context
    }

    public var description: String { "\(context): \(status.fourCharCodeDescription)" }

    /// Throws when `status` isn't `noErr`.
    public static func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
        if status != noErr { throw CoreAudioError(status, context()) }
    }
}

extension OSStatus {
    /// CoreAudio errors are usually four-char codes ('!obj', 'nope', …). Render them as such.
    public var fourCharCodeDescription: String {
        let u = UInt32(bitPattern: self)
        let bytes = [UInt8((u >> 24) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 8) & 0xff), UInt8(u & 0xff)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
            return "'\(String(decoding: bytes, as: UTF8.self))' (\(self))"
        }
        return "\(self)"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    try CoreAudioError.check(status, context())
}

extension AudioObjectPropertyAddress {
    public init(_ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }

    var debugName: String {
        "\(OSStatus(bitPattern: mSelector).fourCharCodeDescription)/\(OSStatus(bitPattern: mScope).fourCharCodeDescription)/\(mElement)"
    }
}

public let systemAudioObject = AudioObjectID(kAudioObjectSystemObject)

// MARK: - Typed property access on any AudioObjectID

extension AudioObjectID {
    public func hasProperty(_ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(self, &a)
    }

    public func isPropertySettable(_ address: AudioObjectPropertyAddress) throws -> Bool {
        var a = address
        var settable: DarwinBoolean = false
        try check(AudioObjectIsPropertySettable(self, &a, &settable), "isSettable \(address.debugName) on \(self)")
        return settable.boolValue
    }

    public func propertyDataSize(_ address: AudioObjectPropertyAddress) throws -> UInt32 {
        var a = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &a, 0, nil, &size), "dataSize \(address.debugName) on \(self)")
        return size
    }

    /// Reads a fixed-size plain-data property (UInt32, Float64, AudioObjectID, ASBD, …).
    /// `as:` is deliberately not defaulted: `try? getProperty(...)` bound to an optional would otherwise
    /// infer `T` as `Optional<…>` and hand the HAL the wrong size.
    public func getProperty<T>(_ address: AudioObjectPropertyAddress, as type: T.Type) throws -> T {
        var a = address
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        try check(AudioObjectGetPropertyData(self, &a, 0, nil, &size, raw), "get \(address.debugName) on \(self)")
        return raw.load(as: T.self)
    }

    /// Reads a variable-length array property ([AudioObjectID], [AudioValueRange], …).
    public func getPropertyArray<T>(_ address: AudioObjectPropertyAddress, of type: T.Type) throws -> [T] {
        var a = address
        var size = try propertyDataSize(address)
        let count = Int(size) / MemoryLayout<T>.stride
        if count == 0 { return [] }
        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            try check(AudioObjectGetPropertyData(self, &a, 0, nil, &size, buffer.baseAddress!), "getArray \(address.debugName) on \(self)")
            initialized = Int(size) / MemoryLayout<T>.stride
        }
    }

    /// Reads a CFString property. CoreAudio hands these back +1 retained.
    public func getPropertyString(_ address: AudioObjectPropertyAddress) throws -> String {
        var a = address
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cf: Unmanaged<CFString>? = nil
        try check(AudioObjectGetPropertyData(self, &a, 0, nil, &size, &cf), "getString \(address.debugName) on \(self)")
        guard let cf else { throw CoreAudioError(kAudioHardwareUnspecifiedError, "getString \(address.debugName) on \(self): null") }
        return cf.takeRetainedValue() as String
    }

    /// Reads a CFArray / CFDictionary / CFURL property (+1 retained), bridged to Swift.
    public func getPropertyCFObject<T>(_ address: AudioObjectPropertyAddress, as type: T.Type) throws -> T {
        var a = address
        var size = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
        var cf: Unmanaged<CFTypeRef>? = nil
        try check(AudioObjectGetPropertyData(self, &a, 0, nil, &size, &cf), "getCF \(address.debugName) on \(self)")
        guard let cf else { throw CoreAudioError(kAudioHardwareUnspecifiedError, "getCF \(address.debugName) on \(self): null") }
        let value = cf.takeRetainedValue()
        guard let typed = value as? T else {
            throw CoreAudioError(kAudioHardwareUnspecifiedError, "getCF \(address.debugName) on \(self): unexpected type \(CFGetTypeID(value))")
        }
        return typed
    }

    /// Reads a property that takes a qualifier (e.g. translate-UID-to-device takes a CFString).
    public func getProperty<T, Q>(_ address: AudioObjectPropertyAddress, qualifier: Q, as type: T.Type) throws -> T {
        var a = address
        var q = qualifier
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        try withUnsafePointer(to: &q) { qp in
            try check(AudioObjectGetPropertyData(self, &a, UInt32(MemoryLayout<Q>.size), qp, &size, raw), "get(q) \(address.debugName) on \(self)")
        }
        return raw.load(as: T.self)
    }

    public func setProperty<T>(_ address: AudioObjectPropertyAddress, _ value: T) throws {
        var a = address
        var v = value
        try withUnsafePointer(to: &v) { vp in
            try check(AudioObjectSetPropertyData(self, &a, 0, nil, UInt32(MemoryLayout<T>.size), UnsafeRawPointer(vp)), "set \(address.debugName) on \(self)")
        }
    }

    public func setPropertyString(_ address: AudioObjectPropertyAddress, _ value: String) throws {
        var a = address
        var cf = Unmanaged.passUnretained(value as CFString)
        try withUnsafePointer(to: &cf) { cp in
            try check(AudioObjectSetPropertyData(self, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>>.size), UnsafeRawPointer(cp)), "setString \(address.debugName) on \(self)")
        }
    }

    /// Reads the AudioBufferList-shaped stream configuration: channels per buffer, in ABL order.
    public func streamConfiguration(scope: AudioObjectPropertyScope) -> [Int] {
        let address = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard hasProperty(address), let size = try? propertyDataSize(address), size > 0 else { return [] }
        var a = address
        var s = size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &a, 0, nil, &s, raw) == noErr else { return [] }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(abl).map { Int($0.mNumberChannels) }
    }

    // MARK: Listeners

    /// Adds a property listener whose block runs on `queue`. The returned token removes the
    /// listener when it is deallocated or `remove()` is called.
    public func addPropertyListener(_ address: AudioObjectPropertyAddress,
                                    queue: DispatchQueue,
                                    handler: @escaping () -> Void) throws -> PropertyListener {
        try PropertyListener(object: self, address: address, queue: queue, handler: handler)
    }
}

public final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    fileprivate init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue, handler: @escaping () -> Void) throws {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        try check(AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block), "addListener \(address.debugName) on \(object)")
        installed = true
    }

    public func remove() {
        guard installed else { return }
        installed = false
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }

    deinit { remove() }
}
