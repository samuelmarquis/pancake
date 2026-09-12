import AppKit
import Foundation
import PancakeCore
import SwiftUI


// MARK: - Geometry

/// Fixed node geometry so port positions are computable without measuring views. A node is a
/// rounded card: a header, then one row per channel. Sources put their ports on the right edge,
/// sinks on the left. `origin` is the card's top-left corner in canvas (model) space.
enum GraphGeom {
    static let nodeWidth: CGFloat = 208
    static let headerHeight: CGFloat = 42
    static let topPad: CGFloat = 6
    static let rowHeight: CGFloat = 28
    static let bottomPad: CGFloat = 12
    static let portRadius: CGFloat = 6.5
    static let cornerRadius: CGFloat = 16

    static func nodeHeight(channels: Int) -> CGFloat {
        headerHeight + topPad + CGFloat(max(1, channels)) * rowHeight + bottomPad
    }
    /// Vertical centre of channel `ch`'s row, in model space, for a card at `origin`.
    static func rowCenterY(origin: CGPoint, channel: Int) -> CGFloat {
        origin.y + headerHeight + topPad + CGFloat(channel) * rowHeight + rowHeight / 2
    }
}

// MARK: - Node / link view models

/// A node as the editor sees it: identity, role, how many ports, whether its backing device/app is
/// here right now, and cosmetic bits. Position is kept separately (in `positions`) so dragging a
/// node doesn't force the whole node list to rebuild.
struct GNode: Identifiable, Equatable {
    let id: NodeID
    let kind: NodeKind
    let title: String
    let subtitle: String
    let channels: Int
    let present: Bool
    var isSource: Bool { kind.isSource }
    var height: CGFloat { GraphGeom.nodeHeight(channels: channels) }
    /// Hub and Pancake Mic are the two fixed buses — always on the canvas, never deletable.
    var isPermanent: Bool { id == Graph.hubID || id == Graph.micID }
}

/// A link identified by its endpoints (gain is not part of identity — a link keeps its identity as
/// you change its gain).
struct LinkRef: Hashable {
    let from: Port
    let to: Port
}

enum GraphSelection: Equatable {
    case none
    case link(LinkRef)
    case node(NodeID)
}

/// A connection being dragged out of a port but not yet dropped. `start`/`current` are in model space.
struct PendingConnection {
    let from: Port
    let fromIsSource: Bool
    let start: CGPoint
    var current: CGPoint
}

// MARK: - Colour per node kind

enum GraphPalette {
    static func color(for kind: NodeKind) -> Color {
        switch kind {
        case .hub: return Color(red: 0.98, green: 0.60, blue: 0.25)   // pancake amber
        case .mic: return Color(red: 0.78, green: 0.42, blue: 0.95)   // voice purple
        case .input: return Color(red: 0.30, green: 0.62, blue: 0.98) // input blue
        case .output: return Color(red: 0.20, green: 0.78, blue: 0.66) // output teal
        case .tap: return Color(red: 0.38, green: 0.80, blue: 0.42)   // app green
        }
    }
}

// MARK: - Layout persistence

/// Node positions, persisted next to graph.json but *separate* from it — positions are a UI concern
/// and must never leak into the graph IPC the CLI and engine consume.
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

    /// The nodes on the canvas, in a stable order (hub, mic, then graph order). Rebuilt only when the
    /// graph's topology changes, not when a node is dragged.
    @Published private(set) var gnodes: [GNode] = []
    /// Top-left corner of each node in model space.
    @Published var positions: [NodeID: CGPoint] = [:]
    /// Canvas pan (added to every model coordinate at render time).
    @Published var pan: CGSize = .zero
    @Published var selection: GraphSelection = .none
    @Published var pending: PendingConnection?

    private let layoutStore = GraphLayoutStore()
    private var saveWork: DispatchWorkItem?
    private var dragStart: [NodeID: CGPoint] = [:]
    private var panStart: CGSize?

    init(app: AppModel) {
        self.app = app
        positions = layoutStore.load()
    }

    var descByID: [NodeID: GNode] {
        Dictionary(uniqueKeysWithValues: gnodes.map { ($0.id, $0) })
    }

    // MARK: Building the node list from the graph

    /// Rebuild `gnodes` from the current graph. Call on appear and whenever the graph changes.
    func syncNodes() {
        var list: [GNode] = []
        var seen = Set<NodeID>()

        func add(id: NodeID, kind: NodeKind, label: String?) {
            guard !seen.contains(id) else { return }
            seen.insert(id)
            list.append(GNode(id: id, kind: kind,
                              title: displayTitle(kind: kind, label: label),
                              subtitle: subtitle(kind: kind),
                              channels: channelCount(id: id, kind: kind),
                              present: isPresent(kind: kind)))
        }

        // The two fixed buses are always present, even before the graph names them.
        add(id: Graph.hubID, kind: .hub, label: "Pancake")
        add(id: Graph.micID, kind: .mic, label: "Pancake Mic")
        for n in app.graph.nodes { add(id: n.id, kind: n.kind, label: n.label) }

        gnodes = list
        ensurePositions()
    }

    private func channelCount(id: NodeID, kind: NodeKind) -> Int {
        switch kind {
        case .hub, .mic, .tap:
            return 2   // Pancake / Pancake Mic are fixed stereo buses; a tap is a stereo mixdown.
        case .output(let uid):
            if let d = app.device(forUID: uid) { return min(16, max(2, d.outputChannels)) }
            return inferredChannels(id: id)
        case .input(let uid):
            if let d = app.device(forUID: uid) { return min(16, max(1, d.inputChannels)) }
            return inferredChannels(id: id)
        }
    }

    /// When a device isn't here, keep as many ports as its existing links imply, so an unplugged
    /// interface's routing stays visible and editable.
    private func inferredChannels(id: NodeID) -> Int {
        var maxCh = 1
        for l in app.graph.links {
            if l.from.node == id { maxCh = max(maxCh, l.from.channel + 1) }
            if l.to.node == id { maxCh = max(maxCh, l.to.channel + 1) }
        }
        return max(2, maxCh)
    }

    private func isPresent(kind: NodeKind) -> Bool {
        switch kind {
        case .hub, .mic: return true
        case .output(let uid), .input(let uid): return app.device(forUID: uid) != nil
        case .tap(let bundleID): return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
        }
    }

    private func displayTitle(kind: NodeKind, label: String?) -> String {
        switch kind {
        case .hub: return "Pancake"
        case .mic: return "Pancake Mic"
        case .input(let uid), .output(let uid): return label ?? uid
        case .tap(let bundleID): return label ?? bundleID
        }
    }

    private func subtitle(kind: NodeKind) -> String {
        switch kind {
        case .hub: return "what apps play"
        case .mic: return "what Discord records"
        case .input: return "input device"
        case .output: return "output device"
        case .tap: return "app audio"
        }
    }

    // MARK: Geometry helpers (model space)

    func portCenter(_ id: NodeID, _ channel: Int) -> CGPoint? {
        guard let o = positions[id], let d = descByID[id] else { return nil }
        let x = d.isSource ? o.x + GraphGeom.nodeWidth : o.x
        return CGPoint(x: x, y: GraphGeom.rowCenterY(origin: o, channel: channel))
    }

    // MARK: Positioning

    private func ensurePositions() {
        if positions.isEmpty && !gnodes.isEmpty {
            autoArrange()
            return
        }
        var changed = false
        for n in gnodes where positions[n.id] == nil {
            positions[n.id] = placeNew(n)
            changed = true
        }
        if changed { scheduleSave() }
    }

    private func placeNew(_ n: GNode) -> CGPoint {
        let x: CGFloat = n.isSource ? 72 : 452
        let bottom = gnodes
            .filter { $0.isSource == n.isSource && $0.id != n.id }
            .compactMap { peer in positions[peer.id].map { $0.y + peer.height } }
            .max()
        return CGPoint(x: x, y: (bottom ?? 46) + 24)
    }

    /// Lay sources down the left column, sinks down the right, and recentre the view.
    func autoArrange() {
        let leftX: CGFloat = 72, rightX: CGFloat = 452, topY: CGFloat = 64, gap: CGFloat = 26
        let sources = gnodes.filter { $0.isSource }.sorted(by: nodeOrder)
        let sinks = gnodes.filter { !$0.isSource }.sorted(by: nodeOrder)
        var y = topY
        for n in sources { positions[n.id] = CGPoint(x: leftX, y: y); y += n.height + gap }
        y = topY
        for n in sinks { positions[n.id] = CGPoint(x: rightX, y: y); y += n.height + gap }
        pan = .zero
        scheduleSave()
    }

    /// Fixed buses first, then present devices, then absent — a stable, sensible reading order.
    private func nodeOrder(_ a: GNode, _ b: GNode) -> Bool {
        func rank(_ n: GNode) -> Int {
            if n.id == Graph.hubID || n.id == Graph.micID { return 0 }
            switch n.kind {
            case .input, .output: return 1
            case .tap: return 2
            default: return 3
            }
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

    func endNodeDrag(_ id: NodeID) {
        dragStart[id] = nil
        scheduleSave()
    }

    func panBy(_ translation: CGSize) {
        let start = panStart ?? pan
        if panStart == nil { panStart = start }
        pan = CGSize(width: start.width + translation.width, height: start.height + translation.height)
    }

    func endPan() { panStart = nil }

    func resetView() { pan = .zero }

    // MARK: Connecting ports

    func beginConnection(from port: Port, isSource: Bool, at start: CGPoint) {
        pending = PendingConnection(from: port, fromIsSource: isSource, start: start, current: start)
    }

    func updateConnection(translation: CGSize) {
        guard var p = pending else { return }
        p.current = CGPoint(x: p.start.x + translation.width, y: p.start.y + translation.height)
        pending = p
    }

    func endConnection() {
        defer { pending = nil }
        guard let p = pending else { return }
        guard let target = nearestPort(to: p.current, wantSource: !p.fromIsSource, maxDist: 34) else { return }
        let src = p.fromIsSource ? p.from : target
        let dst = p.fromIsSource ? target : p.from
        guard src.node != dst.node else { return }
        app.connect(from: src, to: dst)
        selection = .link(LinkRef(from: src, to: dst))
    }

    private func nearestPort(to point: CGPoint, wantSource: Bool, maxDist: CGFloat) -> Port? {
        var best: (Port, CGFloat)?
        for n in gnodes where n.isSource == wantSource {
            for ch in 0..<n.channels {
                guard let c = portCenter(n.id, ch) else { continue }
                let d = hypot(c.x - point.x, c.y - point.y)
                if d <= maxDist, best == nil || d < best!.1 { best = (Port(n.id, ch), d) }
            }
        }
        return best?.0
    }

    // MARK: Editing actions (all flow through AppModel → engine + graph.json)

    func disconnectSelected() {
        if case .link(let ref) = selection {
            app.disconnect(from: ref.from, to: ref.to)
            selection = .none
        }
    }

    func deleteSelection() {
        switch selection {
        case .link(let ref):
            app.disconnect(from: ref.from, to: ref.to)
            selection = .none
        case .node(let id):
            guard id != Graph.hubID && id != Graph.micID else { return }
            positions[id] = nil
            app.removeNode(id)
            selection = .none
            scheduleSave()
        case .none:
            break
        }
    }

    func setSelectedGain(_ gain: Float) {
        if case .link(let ref) = selection { app.setGain(from: ref.from, to: ref.to, gain: gain) }
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
