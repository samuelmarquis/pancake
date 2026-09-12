import CoreAudio
import Foundation

/// Where every sub-device's channels landed in the aggregate device's AudioBufferLists.
///
/// The IOProc sees one AudioBuffer per stream, input and output separately, with the
/// sub-devices' streams concatenated in `fullSubDeviceList` order. This resolves that into
/// "device X, channel c" → (buffer index, channel within buffer), and refuses to guess if
/// the numbers don't add up.
public struct ChannelLayout: Hashable, CustomStringConvertible {
    public struct Slot: Hashable, CustomStringConvertible {
        public let buffer: Int
        public let channel: Int
        public var description: String { "b\(buffer)c\(channel)" }
    }

    /// Sub-device UID → its input channels' slots (index = channel on that device).
    public var inputs: [String: [Slot]] = [:]
    /// Sub-device UID → its output channels' slots.
    public var outputs: [String: [Slot]] = [:]
    /// Channels per input buffer, as the HAL reported them.
    public var inputBuffers: [Int] = []
    public var outputBuffers: [Int] = []

    public var description: String {
        let ins = inputs.keys.sorted().map { "\($0)=\(inputs[$0]!)" }.joined(separator: " ")
        let outs = outputs.keys.sorted().map { "\($0)=\(outputs[$0]!)" }.joined(separator: " ")
        return "in \(inputBuffers) {\(ins)} | out \(outputBuffers) {\(outs)}"
    }

    public struct ResolutionError: Error, CustomStringConvertible {
        public let description: String
    }

    /// `subDevices` must be in `aggregate.fullSubDeviceList` order and contain only devices that
    /// actually made it into the aggregate. `tapBundleIDs` are the process taps in the aggregate's
    /// tap-list order; each contributes one input stream, keyed here by its bundle id, appearing in
    /// the input buffer list *after* every sub-device's input streams.
    public static func resolve(aggregate: AggregateDevice, subDevices: [AudioDevice], tapBundleIDs: [String] = []) throws -> ChannelLayout {
        var layout = ChannelLayout()
        layout.inputBuffers = aggregate.streamConfiguration(scope: kAudioObjectPropertyScopeInput)
        layout.outputBuffers = aggregate.streamConfiguration(scope: kAudioObjectPropertyScopeOutput)

        // Sequential attribution: walk the sub-devices, consuming their streams from the
        // aggregate's buffer list in order.
        func attributeSubDevices(_ expected: KeyPath<AudioDevice, [Int]>, buffers: [Int], label: String) throws -> ([String: [Slot]], Int) {
            var result: [String: [Slot]] = [:]
            var next = 0
            for dev in subDevices {
                var slots: [Slot] = []
                for streamChannels in dev[keyPath: expected] {
                    guard next < buffers.count else {
                        throw ResolutionError(description: "\(label): ran out of aggregate buffers attributing \(dev.name); expected \(dev[keyPath: expected]), aggregate has \(buffers)")
                    }
                    guard buffers[next] == streamChannels else {
                        throw ResolutionError(description: "\(label): buffer \(next) has \(buffers[next]) channels but \(dev.name) expected a \(streamChannels)-channel stream; aggregate has \(buffers)")
                    }
                    for ch in 0..<streamChannels { slots.append(Slot(buffer: next, channel: ch)) }
                    next += 1
                }
                result[dev.uid] = slots
            }
            return (result, next)
        }

        // Outputs: sub-devices only (a tap has no output), and they must account for every buffer.
        let (outputs, outNext) = try attributeSubDevices(\.outputStreamChannels, buffers: layout.outputBuffers, label: "output")
        guard outNext == layout.outputBuffers.count else {
            throw ResolutionError(description: "output: aggregate has \(layout.outputBuffers.count) buffers but the sub-devices account for \(outNext) (\(layout.outputBuffers))")
        }
        layout.outputs = outputs

        // Inputs: sub-devices first, then one trailing buffer per tap (keyed by bundle id).
        var (inputs, next) = try attributeSubDevices(\.inputStreamChannels, buffers: layout.inputBuffers, label: "input")
        for bundleID in tapBundleIDs {
            guard next < layout.inputBuffers.count else {
                throw ResolutionError(description: "input: ran out of aggregate buffers attributing tap \(bundleID); aggregate has \(layout.inputBuffers)")
            }
            let channels = layout.inputBuffers[next]
            inputs[bundleID] = (0..<channels).map { Slot(buffer: next, channel: $0) }
            next += 1
        }
        guard next == layout.inputBuffers.count else {
            throw ResolutionError(description: "input: aggregate has \(layout.inputBuffers.count) buffers but sub-devices + \(tapBundleIDs.count) tap(s) account for \(next) (\(layout.inputBuffers))")
        }
        layout.inputs = inputs
        return layout
    }
}
