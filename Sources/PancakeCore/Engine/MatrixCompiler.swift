import CPancakeRT
import Foundation

/// Turns a graph plus a channel layout into the flat route list the IOProc executes.
public enum MatrixCompiler {
    public struct Route: Hashable, CustomStringConvertible {
        public let inBuffer: Int, inChannel: Int, outBuffer: Int, outChannel: Int
        public let gain: Float
        public var description: String { "b\(inBuffer)c\(inChannel) -> b\(outBuffer)c\(outChannel) ×\(gain)" }
    }

    public struct Result {
        public var routes: [Route]
        public var warnings: [String]
    }

    /// `hubUID` / `micUID` say which sub-devices back the `.hub` and `.mic` nodes. `recorderSlots`
    /// maps each `.recorder` node to its `pk_context` recorder index; those sinks route into the
    /// recorder ring (out_buffer carries PK_REC_FLAG) rather than an aggregate output stream.
    public static func compile(graph: Graph, layout: ChannelLayout, hubUID: String, micUID: String,
                               recorderSlots: [NodeID: Int] = [:]) -> Result {
        var routes: [Route] = []
        var warnings: [String] = []

        func sourceSlots(_ node: Node) -> [ChannelLayout.Slot]? {
            switch node.kind {
            case .hub: return layout.inputs[hubUID]
            case .input(let uid): return layout.inputs[uid]
            case .tap(let bundleID): return layout.inputs[bundleID]   // taps are keyed by bundle id
            case .mic, .output, .recorder: return nil
            }
        }
        func sinkSlots(_ node: Node) -> [ChannelLayout.Slot]? {
            switch node.kind {
            case .mic: return layout.outputs[micUID]
            case .output(let uid): return layout.outputs[uid]
            case .recorder:
                guard let slot = recorderSlots[node.id] else { return nil }   // unassigned → not routed
                let base = Int(PK_REC_FLAG) | slot
                return (0..<Int(PK_REC_CHANNELS)).map { ChannelLayout.Slot(buffer: base, channel: $0) }
            case .hub, .input, .tap: return nil
            }
        }

        for link in graph.links {
            guard let from = graph.node(link.from.node), let to = graph.node(link.to.node) else {
                warnings.append("link \(link): references a node that isn't in the graph")
                continue
            }
            guard let srcSlots = sourceSlots(from) else {
                warnings.append("link \(link): \(from.id) is not a source in this aggregate")
                continue
            }
            guard let dstSlots = sinkSlots(to) else {
                warnings.append("link \(link): \(to.id) is not a sink in this aggregate")
                continue
            }
            guard link.from.channel >= 0, link.from.channel < srcSlots.count else {
                warnings.append("link \(link): \(from.id) has \(srcSlots.count) channels")
                continue
            }
            guard link.to.channel >= 0, link.to.channel < dstSlots.count else {
                warnings.append("link \(link): \(to.id) has \(dstSlots.count) channels")
                continue
            }
            let s = srcSlots[link.from.channel], d = dstSlots[link.to.channel]
            routes.append(Route(inBuffer: s.buffer, inChannel: s.channel, outBuffer: d.buffer, outChannel: d.channel, gain: link.gain))
        }
        return Result(routes: routes, warnings: warnings)
    }

    /// Allocates a C matrix for the IOProc. Caller owns it (see pk_context_swap_matrix).
    public static func makeMatrix(_ routes: [Route]) -> UnsafeMutablePointer<pk_matrix>? {
        guard let m = pk_matrix_alloc(UInt32(routes.count)) else { return nil }
        guard let slots = m.pointee.routes else { return m } // zero routes: nothing to fill
        for (i, r) in routes.enumerated() {
            slots[i] = pk_route(in_buffer: UInt32(r.inBuffer), in_channel: UInt32(r.inChannel),
                                           out_buffer: UInt32(r.outBuffer), out_channel: UInt32(r.outChannel), gain: r.gain)
        }
        return m
    }
}
