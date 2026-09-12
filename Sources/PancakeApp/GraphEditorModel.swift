import AppKit
import Foundation
import PancakeCore
import SwiftUI

// MARK: - Geometry

/// Node cards are fixed-size and carry a single *bus* port per side (L/R is fungible here — a
/// connection is one stereo-or-mono bus, drawn as bundled strands, never split). Sources put their
/// port on the right edge, sinks on the left. `origin` is the card's top-left corner in canvas space.
enum GraphGeom {
    static let nodeWidth: CGFloat = 198
    static let nodeHeight: CGFloat = 60
    static let cornerRadius: CGFloat = 15
    static let portRadius: CGFloat = 7

    static func portCenter(origin: CGPoint, isSource: Bool) -> CGPoint {
        CGPoint(x: isSource ? origin.x + nodeWidth : origin.x, y: origin.y + nodeHeight / 2)
    }
}

// MARK: - Node / edge view models

/// What a canvas node is. Most nodes are graph nodes; `program` is the screen-share bus — a synthetic
/// sink the Stage renders into. It's driven by stage.json, not the routing graph, so the engine never
/// touches it (no double-tap): the Stage self-taps the chosen app and renders it into Pancake Program.
enum GKind: Equatable {
    case graph(NodeKind)
    case program
    var isSource: Bool { if case .graph(let k) = self { return k.isSource } else { return false } }
    var nodeKind: NodeKind? { if case .graph(let k) = self { return k } else { return nil } }
}

struct GNode: Identifiable, Equatable {
    let id: NodeID
    let kind: GKind
    let title: String
    let subtitle: String
    let channels: Int
    let present: Bool
    var isSource: Bool { kind.isSource }
    /// Fixed buses — hub, Pancake Mic, the screen-share program — are never deletable.
    var isPermanent: Bool { id == Graph.hubID || id == Graph.micID || id == GraphEditorModel.programID }
}

/// A connection between two nodes — the editor's unit of routing. `audio` edges are graph links;
/// `stage` edges are the screen-share source→program relationship (backed by stage.json).
enum EdgeKind: Equatable { case audio, stage }

struct BusEdge: Identifiable, Equatable {
    let from: NodeID
    let to: NodeID
    let strands: Int
    let gain: Float
    let kind: EdgeKind
    var id: String { "\(from.rawValue)\u{2192}\(to.rawValue)" }
}

// MARK: - Colour per node kind

enum GraphPalette {
    static func color(for kind: GKind) -> Color {
        switch kind {
        case .program: return Color(red: 0.46, green: 0.50, blue: 0.96)   // stream indigo
        case .graph(let k):
            switch k {
            case .hub: return Color(red: 0.98, green: 0.60, blue: 0.25)   // pancake amber
            case .mic: return Color(red: 0.78, green: 0.42, blue: 0.95)   // voice purple
            case .input: return Color(red: 0.30, green: 0.62, blue: 0.98) // input blue
            case .output: return Color(red: 0.20, green: 0.78, blue: 0.66) // output teal
            case .tap: return Color(red: 0.38, green: 0.80, blue: 0.42)   // app green
            }
        }
    }
}

// MARK: - dB ↔ linear

enum GainMath {
    static func dB(_ g: Float) -> Double { g <= 0.0016 ? -48 : Double(20 * log10f(g)) }
    static func linear(_ db: Double) -> Float { db <= -48 ? 0 : powf(10, Float(db) / 20) }
    static func label(_ g: Float) -> String {
        if abs(g - 1) < 0.001 { return "0.0" }
        if g <= 0.0016 { return "−∞" }
        return String(format: "%+.1f", 20 * log10f(g))
    }
    /// Knob angle in degrees: −48…+12 dB maps to −135°…+135°.
    static func angle(_ g: Float) -> Double {
        let t = (min(12, max(-48, dB(g))) + 48) / 60     // 0…1
        return -135 + t * 270
    }
}

// MARK: - Layout persistence

private struct GraphLayoutFile: Codable, Equatable {
    struct P: Codable, Equatable { var x: Double; var y: Double }
    var positions: [String: P] = [:]
}

private struct GraphLayoutStore {
    let url = GraphStore.defaultURL.deletingLastPathComponent().appendingPathComponent("graph-layout.json")

    func load() -> [NodeID: CGPoint] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(GraphLayoutFile.self, from: data) else { return [:] }
        var out: [NodeID: CGPoint] = [:]
        for (k, v) in file.positions { out[NodeID(k)] = CGPoint(x: v.x, y: v.y) }
        return out
    }

    func save(_ positions: [NodeID: CGPoint]) {
        var file = GraphLayoutFile()
        for (k, v) in positions { file.positions[k.rawValue] = .init(x: Double(v.x), y: Double(v.y)) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Editor model

@MainActor
final class GraphEditorModel: ObservableObject {
    let app: AppModel

    /// The synthetic screen-share program sink. Not a real graph node — see `GKind.program`.
    static let programID = NodeID("__pancake_program__")

    @Published private(set) var gnodes: [GNode] = []
    @Published private(set) var edges: [BusEdge] = []
    @Published var positions: [NodeID: CGPoint] = [:]
    @Published var pan: CGSize = .zero
    @Published var pending: Pending?
    @Published var hoveredEdge: String?     // BusEdge.id
    @Published var hoveredNode: NodeID?
    @Published var knobEdge: String?        // edge whose knob is being dragged (keeps it pinned open)

    /// A connection being dragged out of a node's port. `start`/`current` are in canvas (model) space.
    struct Pending { let from: NodeID; let fromIsSource: Bool; let start: CGPoint; var current: CGPoint }

    private let layoutStore = GraphLayoutStore()
    private var saveWork: DispatchWorkItem?
    private var dragStart: [NodeID: CGPoint] = [:]
    private var panStart: CGSize?
    private var knobGainStart: Float?

    init(app: AppModel) {
        self.app = app
        positions = layoutStore.load()
    }

    var descByID: [NodeID: GNode] { Dictionary(uniqueKeysWithValues: gnodes.map { ($0.id, $0) }) }

    // MARK: Building nodes + edges from the graph (+ the screen-share overlay)

    func sync() {
        var list: [GNode] = []
        var seen = Set<NodeID>()
        func add(id: NodeID, kind: GKind, label: String?) {
            guard !seen.contains(id) else { return }
            seen.insert(id)
            list.append(GNode(id: id, kind: kind,
                              title: displayTitle(kind: kind, label: label),
                              subtitle: subtitle(kind: kind),
                              channels: channelCount(id: id, kind: kind),
                              present: isPresent(kind: kind)))
        }
        add(id: Graph.hubID, kind: .graph(.hub), label: "Pancake")
        add(id: Graph.micID, kind: .graph(.mic), label: "Pancake Mic")
        add(id: Self.programID, kind: .program, label: "Pancake Program")
        for n in app.graph.nodes { add(id: n.id, kind: .graph(n.kind), label: n.label) }
        // The screen-share source may be an app that isn't otherwise in the graph — show it anyway.
        if let b = app.stageConfig.bundleID {
            add(id: Node.tap(b).id, kind: .graph(.tap(bundleID: b)), label: app.stageAppName ?? b)
        }
        gnodes = list

        // Audio edges: group channel links into one bus edge per (from, to) node pair.
        var order: [String] = []
        var acc: [String: (from: NodeID, to: NodeID, count: Int, gain: Float)] = [:]
        for l in app.graph.links {
            let key = "\(l.from.node.rawValue)\u{2192}\(l.to.node.rawValue)"
            if var e = acc[key] { e.count += 1; acc[key] = e }
            else { acc[key] = (l.from.node, l.to.node, 1, l.gain); order.append(key) }
        }
        var built = order.map { k -> BusEdge in
            let e = acc[k]!
            return BusEdge(from: e.from, to: e.to, strands: min(e.count, 2), gain: e.gain, kind: .audio)
        }
        // The screen-share edge: chosen app tap → program. Backed by stage.json, not the graph.
        if let b = app.stageConfig.bundleID {
            built.append(BusEdge(from: Node.tap(b).id, to: Self.programID, strands: 2, gain: 1, kind: .stage))
        }
        edges = built

        ensurePositions()
    }

    private func channelCount(id: NodeID, kind: GKind) -> Int {
        switch kind {
        case .program: return 2
        case .graph(let k):
            switch k {
            case .hub, .mic, .tap: return 2
            case .output(let uid):
                if let d = app.device(forUID: uid) { return min(16, max(2, d.outputChannels)) }
                return inferredChannels(id: id)
            case .input(let uid):
                if let d = app.device(forUID: uid) { return min(16, max(1, d.inputChannels)) }
                return inferredChannels(id: id)
            }
        }
    }

    private func inferredChannels(id: NodeID) -> Int {
        var maxCh = 1
        for l in app.graph.links {
            if l.from.node == id { maxCh = max(maxCh, l.from.channel + 1) }
            if l.to.node == id { maxCh = max(maxCh, l.to.channel + 1) }
        }
        return max(2, maxCh)
    }

    private func isPresent(kind: GKind) -> Bool {
        switch kind {
        case .program: return true
        case .graph(let k):
            switch k {
            case .hub, .mic: return true
            case .output(let uid), .input(let uid): return app.device(forUID: uid) != nil
            case .tap(let b): return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == b }
            }
        }
    }

    private func displayTitle(kind: GKind, label: String?) -> String {
        switch kind {
        case .program: return "Pancake Program"
        case .graph(let k):
            switch k {
            case .hub: return "Pancake"
            case .mic: return "Pancake Mic"
            case .input(let uid), .output(let uid): return label ?? uid
            case .tap(let b): return label ?? b
            }
        }
    }

    /// Technical, not cute: say what each node actually is.
    private func subtitle(kind: GKind) -> String {
        switch kind {
        case .program: return "screen-share program bus"
        case .graph(let k):
            switch k {
            case .hub: return "virtual output device"
            case .mic: return "virtual input device"
            case .input: return "hardware input"
            case .output: return "hardware output"
            case .tap: return "process tap"
            }
        }
    }

    // MARK: Geometry (canvas/model space)

    func portCenter(_ id: NodeID) -> CGPoint? {
        guard let o = positions[id], let d = descByID[id] else { return nil }
        return GraphGeom.portCenter(origin: o, isSource: d.isSource)
    }

    func edgeEndpoints(_ e: BusEdge) -> (from: CGPoint, to: CGPoint)? {
        guard let a = portCenter(e.from), let b = portCenter(e.to) else { return nil }
        return (a, b)
    }

    // MARK: Positioning

    private func ensurePositions() {
        if positions.isEmpty && !gnodes.isEmpty { autoArrange(); return }
        var changed = false
        for n in gnodes where positions[n.id] == nil { positions[n.id] = placeNew(n); changed = true }
        if changed { scheduleSave() }
    }

    private func placeNew(_ n: GNode) -> CGPoint {
        let x: CGFloat = n.isSource ? 72 : 452
        let bottom = gnodes
            .filter { $0.isSource == n.isSource && $0.id != n.id }
            .compactMap { peer in positions[peer.id].map { $0.y } }
            .max()
        return CGPoint(x: x, y: (bottom ?? 40) + GraphGeom.nodeHeight + 22)
    }

    func autoArrange() {
        let leftX: CGFloat = 72, rightX: CGFloat = 452, topY: CGFloat = 64, gap: CGFloat = GraphGeom.nodeHeight + 22
        let sources = gnodes.filter { $0.isSource }.sorted(by: nodeOrder)
        let sinks = gnodes.filter { !$0.isSource }.sorted(by: nodeOrder)
        for (i, n) in sources.enumerated() { positions[n.id] = CGPoint(x: leftX, y: topY + CGFloat(i) * gap) }
        for (i, n) in sinks.enumerated() { positions[n.id] = CGPoint(x: rightX, y: topY + CGFloat(i) * gap) }
        pan = .zero
        scheduleSave()
    }

    private func nodeOrder(_ a: GNode, _ b: GNode) -> Bool {
        func rank(_ n: GNode) -> Int {
            if n.isPermanent { return 0 }
            if case .graph(let k) = n.kind {
                switch k { case .input, .output: return 1; case .tap: return 2; default: return 3 }
            }
            return 3
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    // MARK: Dragging nodes / panning

    func dragNode(_ id: NodeID, translation: CGSize) {
        let start = dragStart[id] ?? (positions[id] ?? .zero)
        if dragStart[id] == nil { dragStart[id] = start }
        positions[id] = CGPoint(x: start.x + translation.width, y: start.y + translation.height)
    }
    func endNodeDrag(_ id: NodeID) { dragStart[id] = nil; scheduleSave() }

    func panBy(_ translation: CGSize) {
        let start = panStart ?? pan
        if panStart == nil { panStart = start }
        pan = CGSize(width: start.width + translation.width, height: start.height + translation.height)
    }
    func endPan() { panStart = nil }
    func resetView() { pan = .zero }

    // MARK: Hover — one geometric test over the whole canvas

    /// Given the pointer in canvas (screen) space, decide what's hovered. A single continuous tracker
    /// drives this, so nothing — a full-canvas hit view, a knob sitting on a wire — can steal or block
    /// hover. Nodes win over wires; a generous halo/disc keeps the delete bubble and knob reachable.
    func hoverAt(_ p: CGPoint) {
        if let id = nodeHit(p) {
            if hoveredNode != id { hoveredNode = id }
            if hoveredEdge != nil { hoveredEdge = nil }
            return
        }
        if let eid = edgeHit(p) {
            if hoveredEdge != eid { hoveredEdge = eid }
            if hoveredNode != nil { hoveredNode = nil }
            return
        }
        if hoveredNode != nil { hoveredNode = nil }
        if hoveredEdge != nil && knobEdge == nil { hoveredEdge = nil }
    }

    func hoverEnded() {
        if hoveredNode != nil { hoveredNode = nil }
        if hoveredEdge != nil && knobEdge == nil { hoveredEdge = nil }
    }

    private func nodeHit(_ p: CGPoint) -> NodeID? {
        for n in gnodes {
            guard let o = positions[n.id] else { continue }
            // 14pt halo so the corner delete bubble still counts as "over the node".
            let r = CGRect(x: o.x + pan.width - 14, y: o.y + pan.height - 14,
                           width: GraphGeom.nodeWidth + 28, height: GraphGeom.nodeHeight + 28)
            if r.contains(p) { return n.id }
        }
        return nil
    }

    private func edgeHit(_ p: CGPoint) -> String? {
        var best: (String, CGFloat)?
        for e in edges {
            guard let (a, b) = edgeEndpoints(e) else { continue }
            let from = CGPoint(x: a.x + pan.width, y: a.y + pan.height)
            let to = CGPoint(x: b.x + pan.width, y: b.y + pan.height)
            let mid = curveMidpoint(from, to)
            let dm = hypot(p.x - mid.x, p.y - mid.y)
            let d = dm <= 26 ? dm : distanceToCurve(p, from, to)   // knob/badge area counts as the edge
            if d <= 16, best == nil || d < best!.1 { best = (e.id, d) }
        }
        return best?.0
    }

    private func curveMidpoint(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
        let dx = max(40, abs(to.x - from.x) * 0.5)
        let c1 = CGPoint(x: from.x + dx, y: from.y), c2 = CGPoint(x: to.x - dx, y: to.y)
        return CGPoint(x: 0.125*from.x + 0.375*c1.x + 0.375*c2.x + 0.125*to.x,
                       y: 0.125*from.y + 0.375*c1.y + 0.375*c2.y + 0.125*to.y)
    }

    private func distanceToCurve(_ p: CGPoint, _ from: CGPoint, _ to: CGPoint) -> CGFloat {
        let dx = max(40, abs(to.x - from.x) * 0.5)
        let c1 = CGPoint(x: from.x + dx, y: from.y), c2 = CGPoint(x: to.x - dx, y: to.y)
        var best = CGFloat.greatestFiniteMagnitude
        let n = 24
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n), u = 1 - t
            let w0 = u*u*u, w1 = 3*u*u*t, w2 = 3*u*t*t, w3 = t*t*t
            let x = w0*from.x + w1*c1.x + w2*c2.x + w3*to.x
            let y = w0*from.y + w1*c1.y + w2*c2.y + w3*to.y
            best = min(best, hypot(x - p.x, y - p.y))
        }
        return best
    }

    // MARK: Connecting

    func beginConnection(from id: NodeID, isSource: Bool, at start: CGPoint) {
        pending = Pending(from: id, fromIsSource: isSource, start: start, current: start)
    }
    func updateConnection(translation: CGSize) {
        guard var p = pending else { return }
        p.current = CGPoint(x: p.start.x + translation.width, y: p.start.y + translation.height)
        pending = p
    }
    func endConnection() {
        defer { pending = nil }
        guard let p = pending, let target = nearestNode(to: p.current, wantSource: !p.fromIsSource, maxDist: 52) else { return }
        let src = p.fromIsSource ? p.from : target
        let dst = p.fromIsSource ? target : p.from
        guard src != dst else { return }
        if dst == Self.programID {
            // Screen-share: only an app tap can be streamed. Sets stage.json; the Stage obeys.
            if case .graph(.tap(let b))? = descByID[src]?.kind { app.setStageApp(b) }
            return
        }
        if src == Self.programID { return }   // the program bus is a sink only
        app.wireBus(from: src, to: dst, pairs: busPairs(from: src, to: dst))
    }

    private func nearestNode(to point: CGPoint, wantSource: Bool, maxDist: CGFloat) -> NodeID? {
        var best: (NodeID, CGFloat)?
        for n in gnodes where n.isSource == wantSource {
            guard let c = portCenter(n.id) else { continue }
            let d = hypot(c.x - point.x, c.y - point.y)
            if d <= maxDist, best == nil || d < best!.1 { best = (n.id, d) }
        }
        return best?.0
    }

    /// Stereo/mono is fungible: mono fans to both, stereo sums to mono, otherwise straight through
    /// (capped at two — per-channel surgery beyond stereo isn't something this router needs).
    private func busPairs(from: NodeID, to: NodeID) -> [(Int, Int)] {
        let sc = descByID[from]?.channels ?? 2
        let dc = descByID[to]?.channels ?? 2
        if sc <= 1 && dc >= 2 { return [(0, 0), (0, 1)] }
        if sc >= 2 && dc <= 1 { return [(0, 0), (1, 0)] }
        let n = max(1, min(sc, dc, 2))
        return (0..<n).map { ($0, $0) }
    }

    // MARK: Knob (gain) + deletion

    func beginKnob(_ e: BusEdge) { knobEdge = e.id; knobGainStart = e.gain }
    func dragKnob(_ e: BusEdge, translation: CGSize) {
        let startDB = GainMath.dB(knobGainStart ?? e.gain)
        let db = min(12, max(-48, startDB - Double(translation.height) * 0.2))  // drag up = louder
        app.setBusGain(from: e.from, to: e.to, gain: GainMath.linear(db))
    }
    func endKnob() { knobEdge = nil; knobGainStart = nil }
    func resetKnob(_ e: BusEdge) { app.setBusGain(from: e.from, to: e.to, gain: 1) }

    func deleteHovered() {
        if let id = hoveredEdge, let e = edges.first(where: { $0.id == id }) {
            switch e.kind {
            case .stage: app.setStageApp(nil)                       // stop streaming this app
            case .audio: app.disconnectBus(from: e.from, to: e.to)
            }
            hoveredEdge = nil
            return
        }
        if let n = hoveredNode { removeNode(n) }
    }

    func removeNode(_ id: NodeID) {
        guard let d = descByID[id], !d.isPermanent else { return }
        // If this node is the current screen-share source, clearing stage removes the stage edge too.
        if case .graph(.tap(let b))? = descByID[id]?.kind, app.stageConfig.bundleID == b { app.setStageApp(nil) }
        positions[id] = nil
        hoveredNode = nil
        app.removeNode(id)
        scheduleSave()
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let positions = self.positions
        let work = DispatchWorkItem { [layoutStore] in layoutStore.save(positions) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
