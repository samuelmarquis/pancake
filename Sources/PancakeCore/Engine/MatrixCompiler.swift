import CPancakeRT
import Foundation

/// Turns a graph plus a channel layout into the flat route program the IOProc executes.
public enum MatrixCompiler {
    public struct Route: Hashable, CustomStringConvertible {
        public let inBuffer: Int, inChannel: Int, outBuffer: Int, outChannel: Int
        public let gain: Float
        public var description: String { "\(Self.name(inBuffer))c\(inChannel) -> \(Self.name(outBuffer))c\(outChannel) ×\(gain)" }
        static func name(_ b: Int) -> String {
            if b & Int(PK_REC_FLAG) != 0 { return "rec\(b & ~Int(PK_REC_FLAG))" }
            if b & Int(PK_BUS_FLAG) != 0 { return "bus\(b & ~Int(PK_BUS_FLAG))" }
            return "b\(b)"
        }
        var readsBus: Int? { inBuffer & Int(PK_BUS_FLAG) != 0 ? inBuffer & ~Int(PK_BUS_FLAG) : nil }
        var writesBus: Int? { outBuffer & Int(PK_BUS_FLAG) != 0 ? outBuffer & ~Int(PK_BUS_FLAG) : nil }
    }

    /// One bus's baked processing: `pk_bus_params` with the time constants turned into per-sample
    /// coefficients for the run's sample rate.
    public struct Bus: Hashable {
        public let slot: Int
        public let params: BusParams
        public let sampleRate: Double
        var rt: pk_bus_params {
            func coef(_ ms: Float) -> Float {
                guard ms > 0, sampleRate > 0 else { return 0 }
                return Float(exp(-1.0 / (Double(ms) * 0.001 * sampleRate)))
            }
            return pk_bus_params(active: 1, comp_enabled: params.compressor ? 1 : 0,
                                 threshold_db: params.threshold, ratio: max(1, params.ratio), knee_db: max(0, params.knee),
                                 attack_coef: coef(params.attack), release_coef: coef(params.release),
                                 makeup: powf(10, params.makeup / 20), trim: params.trim)
        }
    }

    public struct Result {
        /// Routes in evaluation order: stage 1 (device/tap sources) first, then one segment per bus
        /// in `busOrder`, each holding the routes that read that bus.
        public var routes: [Route]
        public var stage1Count: Int
        /// Bus slots in evaluation order, and for each the index one past its segment's last route.
        public var busOrder: [Int]
        public var segmentEnds: [Int]
        public var buses: [Bus]
        public var warnings: [String]
    }

    /// `hubUID` / `micUID` / `programUID` say which sub-devices back the `.hub`, `.mic` and `.program`
    /// nodes. `recorderSlots` maps each `.recorder` node to its `pk_context` recorder index (those
    /// sinks route into the recorder ring — out_buffer carries PK_REC_FLAG); `busSlots` maps each
    /// `.bus` node to its bus index (both sides carry PK_BUS_FLAG). `sampleRate` bakes the buses'
    /// time constants.
    public static func compile(graph: Graph, layout: ChannelLayout, hubUID: String, micUID: String, programUID: String,
                               recorderSlots: [NodeID: Int] = [:], busSlots: [NodeID: Int] = [:],
                               sampleRate: Double = 48000) -> Result {
        var routes: [Route] = []
        var warnings: [String] = []

        func busSlotsFor(_ node: Node) -> [ChannelLayout.Slot]? {
            guard let slot = busSlots[node.id] else { return nil }   // unassigned → not routed
            let base = Int(PK_BUS_FLAG) | slot
            return (0..<Int(PK_BUS_CHANNELS)).map { ChannelLayout.Slot(buffer: base, channel: $0) }
        }
        func sourceSlots(_ node: Node) -> [ChannelLayout.Slot]? {
            switch node.kind {
            case .hub: return layout.inputs[hubUID]
            case .input(let uid): return layout.inputs[uid]
            case .tap(let bundleID): return layout.inputs[bundleID]   // taps are keyed by bundle id
            case .bus: return busSlotsFor(node)
            case .mic, .output, .recorder, .program: return nil
            }
        }
        func sinkSlots(_ node: Node) -> [ChannelLayout.Slot]? {
            switch node.kind {
            case .mic: return layout.outputs[micUID]
            case .program: return layout.outputs[programUID]
            case .output(let uid): return layout.outputs[uid]
            case .recorder:
                guard let slot = recorderSlots[node.id] else { return nil }   // unassigned → not routed
                let base = Int(PK_REC_FLAG) | slot
                return (0..<Int(PK_REC_CHANNELS)).map { ChannelLayout.Slot(buffer: base, channel: $0) }
            case .bus: return busSlotsFor(node)
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
            if s.buffer == d.buffer, s.buffer & Int(PK_BUS_FLAG) != 0 {
                warnings.append("link \(link): a bus can't feed itself; dropped")
                continue
            }
            routes.append(Route(inBuffer: s.buffer, inChannel: s.channel, outBuffer: d.buffer, outChannel: d.channel, gain: link.gain))
        }

        // Buses in use, ordered so every bus is processed after the buses that feed it (Kahn's
        // algorithm over bus→bus routes). A cycle can't be evaluated in one pass: the routes that
        // close it are dropped with a warning and the buses involved fall in id order.
        let used = Set(routes.compactMap(\.readsBus) + routes.compactMap(\.writesBus))
        var indegree: [Int: Int] = Dictionary(uniqueKeysWithValues: used.map { ($0, 0) })
        var succ: [Int: Set<Int>] = [:]
        for r in routes { if let a = r.readsBus, let b = r.writesBus, a != b, succ[a, default: []].insert(b).inserted { indegree[b, default: 0] += 1 } }
        var ready = indegree.filter { $0.value == 0 }.map(\.key).sorted()
        var order: [Int] = []
        while let a = ready.first {
            ready.removeFirst(); order.append(a)
            for b in (succ[a] ?? []).sorted() { indegree[b]! -= 1; if indegree[b] == 0 { ready.append(b); ready.sort() } }
        }
        let cyclic = used.subtracting(order).sorted()
        if !cyclic.isEmpty {
            warnings.append("buses \(cyclic) feed each other in a cycle; the links between them are dropped")
            routes.removeAll { r in
                if let a = r.readsBus, let b = r.writesBus, cyclic.contains(a), cyclic.contains(b) { return true }
                return false
            }
            order += cyclic
        }

        // Segment the routes: stage 1, then one segment per bus (routes reading that bus).
        let stage1 = routes.filter { $0.readsBus == nil }
        var ordered = stage1
        var ends: [Int] = []
        for slot in order {
            ordered += routes.filter { $0.readsBus == slot }
            ends.append(ordered.count)
        }
        let busNodes = Dictionary(uniqueKeysWithValues: busSlots.map { ($0.value, $0.key) })
        let buses = order.map { Bus(slot: $0, params: busNodes[$0].map { graph.busParams($0) } ?? BusParams(), sampleRate: sampleRate) }
        return Result(routes: ordered, stage1Count: stage1.count, busOrder: order, segmentEnds: ends, buses: buses, warnings: warnings)
    }

    /// Allocates a C matrix for the IOProc. Caller owns it (see pk_context_swap_matrix).
    public static func makeMatrix(_ r: Result) -> UnsafeMutablePointer<pk_matrix>? {
        guard let m = pk_matrix_alloc(UInt32(r.routes.count)) else { return nil }
        if let slots = m.pointee.routes {
            for (i, route) in r.routes.enumerated() {
                slots[i] = pk_route(in_buffer: UInt32(route.inBuffer), in_channel: UInt32(route.inChannel),
                                    out_buffer: UInt32(route.outBuffer), out_channel: UInt32(route.outChannel), gain: route.gain)
            }
        }
        let order = r.busOrder.map(UInt32.init), ends = r.segmentEnds.map(UInt32.init)
        pk_matrix_set_stages(m, UInt32(r.stage1Count), UInt32(order.count), order, ends)
        for b in r.buses { pk_matrix_set_bus(m, UInt32(b.slot), b.rt) }
        return m
    }

    /// Routes only — for callers with no buses.
    public static func makeMatrix(_ routes: [Route]) -> UnsafeMutablePointer<pk_matrix>? {
        makeMatrix(Result(routes: routes, stage1Count: routes.count, busOrder: [], segmentEnds: [], buses: [], warnings: []))
    }
}
