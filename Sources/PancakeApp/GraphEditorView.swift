import AppKit
import PancakeCore
import SwiftUI

/// The visual routing editor — a pipewire-style patchbay. Sources (Pancake, inputs, app taps) on the
/// left, sinks (outputs, Pancake Mic) on the right; drag between node ports to route. A connection is
/// a whole stereo/mono bus (L/R fungible), drawn as bundled strands whose colour blends from the
/// source node's hue to the sink's. Hover a wire for a gain knob; ⌫ removes the hovered wire/node.
/// Edits apply to the running engine at once and persist to graph.json; node positions live in a
/// separate graph-layout.json so the IPC file stays clean.
struct GraphEditorView: View {
    @ObservedObject var app: AppModel
    @StateObject private var editor: GraphEditorModel
    @FocusState private var canvasFocused: Bool

    init(app: AppModel) {
        _app = ObservedObject(wrappedValue: app)
        _editor = StateObject(wrappedValue: GraphEditorModel(app: app))
    }

    var body: some View {
        ZStack(alignment: .top) {
            GraphCanvas(app: app, editor: editor)
                .focusable()
                .focusEffectDisabled()
                .focused($canvasFocused)
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in editor.deleteHovered(); return .handled }

            TopBar(app: app, editor: editor)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(WindowBackground())
        .onAppear { app.refreshStage(); editor.sync(); canvasFocused = true }
        .onChange(of: app.graph) { _, _ in editor.sync() }
        .onChange(of: app.stageConfig) { _, _ in editor.sync() }
        .onChange(of: app.stageRunning) { _, _ in editor.sync() }
    }
}

// MARK: - Background

private struct WindowBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(nsColor: .windowBackgroundColor),
                                Color(nsColor: .underPageBackgroundColor)],
                       startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
}

// MARK: - Canvas

/// A wire ready to draw: endpoints in screen space, the two endpoint colours to blend, strand count.
private struct DrawEdge: Identifiable {
    let id: String
    let from: CGPoint
    let to: CGPoint
    let c0: Color
    let c1: Color
    let strands: Int
    let live: Bool
}

private struct GraphCanvas: View {
    @ObservedObject var app: AppModel
    @ObservedObject var editor: GraphEditorModel

    private var liveEdgeIDs: Set<String> {
        var s = Set<String>()
        for l in app.effectiveGraph?.links ?? [] { s.insert("\(l.from.node.rawValue)\u{2192}\(l.to.node.rawValue)") }
        return s
    }

    var body: some View {
        let desc = editor.descByID
        let live = liveEdgeIDs
        let draws: [DrawEdge] = editor.edges.compactMap { e in
            guard let (a, b) = editor.edgeEndpoints(e) else { return nil }
            let isLive = e.kind == .stage ? app.stageRunning : live.contains(e.id)
            return DrawEdge(id: e.id,
                            from: a.offset(editor.pan), to: b.offset(editor.pan),
                            c0: desc[e.from].map { GraphPalette.color(for: $0.kind) } ?? .gray,
                            c1: desc[e.to].map { GraphPalette.color(for: $0.kind) } ?? .gray,
                            strands: e.strands, live: isLive)
        }

        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                DotGrid(pan: editor.pan)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { editor.panBy($0.translation) }.onEnded { _ in editor.endPan() })

                WiresCanvas(edges: draws, hovered: editor.hoveredEdge)

                // Order matters: knobs sit above nodes (grabbable over a card), but ports sit above
                // knobs so a drag that starts on a port always begins a connection. Delete bubbles sit
                // on top so they're always clickable.
                nodeCards
                edgeKnobs
                portDots
                deleteBubbles
                pendingWire
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var nodeCards: some View {
        ForEach(editor.gnodes) { node in
            if let origin = editor.positions[node.id] {
                let center = CGPoint(x: origin.x + GraphGeom.nodeWidth / 2,
                                     y: origin.y + GraphGeom.nodeHeight / 2).offset(editor.pan)
                NodeCard(node: node, hovered: editor.hoveredNode == node.id)
                    .frame(width: GraphGeom.nodeWidth, height: GraphGeom.nodeHeight)
                    .position(center)
                    .onHover { $0 ? editor.hoverNode(node.id) : editor.unhoverNode(node.id) }
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { editor.dragNode(node.id, translation: $0.translation) }
                            .onEnded { _ in editor.endNodeDrag(node.id) }
                    )
            }
        }
    }

    private var portDots: some View {
        ForEach(editor.gnodes) { node in
            if let c = editor.portCenter(node.id) {
                PortDot(editor: editor, node: node, model: c)
            }
        }
    }

    /// The iOS-style floating delete bubble at a hovered node's top-left corner.
    private var deleteBubbles: some View {
        ForEach(editor.gnodes) { node in
            if editor.hoveredNode == node.id, !node.isPermanent, let origin = editor.positions[node.id] {
                DeleteBubble(onRemove: { editor.removeNode(node.id) })
                    .position(CGPoint(x: origin.x, y: origin.y).offset(editor.pan))
                    .onHover { $0 ? editor.hoverNode(node.id) : editor.unhoverNode(node.id) }
            }
        }
    }

    private var edgeKnobs: some View {
        ForEach(editor.edges) { edge in
            if let (a, b) = editor.edgeEndpoints(edge) {
                EdgeInteractor(editor: editor, edge: edge,
                               from: a.offset(editor.pan), to: b.offset(editor.pan))
            }
        }
    }

    @ViewBuilder private var pendingWire: some View {
        if let p = editor.pending {
            let from = (p.fromIsSource ? p.start : p.current).offset(editor.pan)
            let to = (p.fromIsSource ? p.current : p.start).offset(editor.pan)
            WireShape(from: from, to: to)
                .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))
                .allowsHitTesting(false)
        }
    }
}

private struct DotGrid: View {
    let pan: CGSize
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 26
            let ox = pan.width.truncatingRemainder(dividingBy: step)
            let oy = pan.height.truncatingRemainder(dividingBy: step)
            let dot = Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2))
            var y = oy - step
            while y < size.height + step {
                var x = ox - step
                while x < size.width + step {
                    ctx.fill(dot.offsetBy(dx: x, dy: y), with: .color(.primary.opacity(0.06)))
                    x += step
                }
                y += step
            }
        }
    }
}

// MARK: - Wires (one Canvas, colour-blended, bundled strands)

private struct WiresCanvas: View {
    let edges: [DrawEdge]
    let hovered: String?

    var body: some View {
        Canvas { ctx, _ in
            for e in edges {
                let hot = hovered == e.id
                let offsets: [CGFloat] = e.strands >= 2 ? [-2.6, 2.6] : [0]
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [e.c0, e.c1]), startPoint: e.from, endPoint: e.to)
                let style = StrokeStyle(lineWidth: hot ? 3.4 : 2.4, lineCap: .round, dash: e.live ? [] : [5, 6])
                ctx.opacity = e.live ? 1 : 0.5
                for off in offsets {
                    ctx.stroke(bezier(from: CGPoint(x: e.from.x, y: e.from.y + off),
                                      to: CGPoint(x: e.to.x, y: e.to.y + off)),
                               with: shading, style: style)
                }
                ctx.opacity = 1
            }
        }
        .allowsHitTesting(false)
    }
}

private func bezier(from: CGPoint, to: CGPoint) -> Path {
    var p = Path()
    let dx = max(40, abs(to.x - from.x) * 0.5)
    p.move(to: from)
    p.addCurve(to: to, control1: CGPoint(x: from.x + dx, y: from.y), control2: CGPoint(x: to.x - dx, y: to.y))
    return p
}

private func bezierMid(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
    let dx = max(40, abs(to.x - from.x) * 0.5)
    let c1 = CGPoint(x: from.x + dx, y: from.y), c2 = CGPoint(x: to.x - dx, y: to.y)
    return CGPoint(x: 0.125 * from.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * to.x,
                   y: 0.125 * from.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * to.y)
}

private struct WireShape: Shape {
    var from: CGPoint
    var to: CGPoint
    func path(in rect: CGRect) -> Path { bezier(from: from, to: to) }
}

// MARK: - Edge interaction (hover hit area + gain knob)

private struct EdgeInteractor: View {
    @ObservedObject var editor: GraphEditorModel
    let edge: BusEdge
    let from: CGPoint
    let to: CGPoint

    private var mid: CGPoint { bezierMid(from, to) }
    private var hot: Bool { editor.hoveredEdge == edge.id || editor.knobEdge == edge.id }

    var body: some View {
        ZStack {
            // Hit region: fat stroke of the curve ∪ a disc at the midpoint, so moving onto the knob
            // keeps the wire "hovered" and the knob doesn't flicker away.
            Color.clear
                .contentShape(EdgeHitShape(from: from, to: to, width: 20, knob: mid, knobRadius: 24))
                .onHover { inside in
                    if inside { editor.hoveredEdge = edge.id }
                    else if editor.hoveredEdge == edge.id { editor.hoveredEdge = nil }
                }

            if hot {
                switch edge.kind {
                case .audio:
                    Knob(gain: edge.gain)
                        .position(mid)
                        // minimumDistance > 0 so a plain double-click isn't eaten by the drag.
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { v in
                                    if editor.knobEdge == nil { editor.beginKnob(edge) }
                                    editor.dragKnob(edge, translation: v.translation)
                                }
                                .onEnded { _ in editor.endKnob() }
                        )
                        .onTapGesture(count: 2) { editor.resetKnob(edge) }
                        .help("Drag to set gain · double-click for unity")
                case .stage:
                    StageBadge()
                        .position(mid)
                        .help("Screen-share source. ⌫ to stop sharing this app.")
                }
            }
        }
    }
}

private struct EdgeHitShape: Shape {
    var from: CGPoint, to: CGPoint, width: CGFloat, knob: CGPoint, knobRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = bezier(from: from, to: to).strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
        p.addEllipse(in: CGRect(x: knob.x - knobRadius, y: knob.y - knobRadius, width: knobRadius * 2, height: knobRadius * 2))
        return p
    }
}

private struct Knob: View {
    let gain: Float
    var body: some View {
        let unity = abs(gain - 1) < 0.001
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().stroke(.primary.opacity(0.18), lineWidth: 1)
            // Indicator tick, rotated by the current gain.
            Capsule()
                .fill(unity ? Color.secondary : Color.accentColor)
                .frame(width: 2.5, height: 11)
                .offset(y: -7)
                .rotationEffect(.degrees(GainMath.angle(gain)))
            Text(GainMath.label(gain))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .offset(y: 10)
                .foregroundStyle(.secondary)
        }
        .frame(width: 34, height: 34)
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        .contentShape(Circle())
    }
}

/// The midpoint marker on a screen-share edge — informational; the wire has no gain (it's video+audio
/// captured by the Stage, not a routed gain link). Delete with ⌫ while hovered.
private struct StageBadge: View {
    var body: some View {
        Image(systemName: "rectangle.inset.filled.badge.record")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(GraphPalette.color(for: .program))
            .padding(6)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(.primary.opacity(0.15)))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}

// MARK: - Node card

private struct NodeCard: View {
    let node: GNode
    let hovered: Bool

    private var color: Color { GraphPalette.color(for: node.kind) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.9))
                Image(systemName: NodeGlyph.name(for: node.kind, title: node.title))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(node.present ? node.subtitle : "not connected")
                    .font(.system(size: 10))
                    .foregroundStyle(node.present ? .secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 12)
        .frame(width: GraphGeom.nodeWidth, height: GraphGeom.nodeHeight, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: GraphGeom.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GraphGeom.cornerRadius, style: .continuous)
                .stroke(hovered ? color : Color.primary.opacity(0.10), lineWidth: hovered ? 1.8 : 1)
        )
        .overlay(alignment: .leading) {
            // A slim colour bar on the port side marks the node's hue.
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3.5, height: GraphGeom.nodeHeight - 18)
                .padding(.leading, 4)
                .opacity(0.9)
        }
        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
        .opacity(node.present ? 1 : 0.62)
    }
}

/// Floating delete affordance à la iOS home-screen jiggle (minus the jiggle): a small dark bubble
/// with a ✕, sat on the node's corner. Lives in a top layer so it's always clickable.
private struct DeleteBubble: View {
    let onRemove: () -> Void
    var body: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(Circle().fill(Color(white: 0.25)))
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help("Remove node")
    }
}

// MARK: - Port dot

private struct PortDot: View {
    @ObservedObject var editor: GraphEditorModel
    let node: GNode
    let model: CGPoint       // port centre in canvas/model space

    private var color: Color { GraphPalette.color(for: node.kind) }

    var body: some View {
        let screen = model.offset(editor.pan)
        ZStack {
            Circle().fill(color.opacity(0.22)).frame(width: GraphGeom.portRadius * 3.2, height: GraphGeom.portRadius * 3.2)
            Circle().fill(color).overlay(Circle().stroke(.background, lineWidth: 2))
                .frame(width: GraphGeom.portRadius * 2, height: GraphGeom.portRadius * 2)
        }
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
        .position(screen)
        .highPriorityGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if editor.pending == nil { editor.beginConnection(from: node.id, isSource: node.isSource, at: model) }
                    editor.updateConnection(translation: v.translation)
                }
                .onEnded { _ in editor.endConnection() }
        )
        .help(node.isSource ? "Output — drag to a sink" : "Input — drag to a source")
    }
}

// MARK: - Top bar (flush with the traffic lights)

private struct TopBar: View {
    @ObservedObject var app: AppModel
    @ObservedObject var editor: GraphEditorModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
            Text("Routing").font(.system(size: 13, weight: .semibold))

            Divider().frame(height: 16)

            AddMenu(app: app, editor: editor)
            Button { editor.autoArrange() } label: { Label("Tidy", systemImage: "rectangle.3.offgrid") }
                .glassButton()
            Button { editor.resetView() } label: { Label("Recenter", systemImage: "scope") }
                .glassButton()

            Spacer()
            Legend()
        }
        .controlSize(.small)
        .padding(.leading, 82)   // clear the traffic lights
        .padding(.trailing, 14)
        .padding(.vertical, 3)   // short enough to sit in the title-bar band, flush with the lights
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.primary.opacity(0.08)), alignment: .bottom)
    }
}

private struct AddMenu: View {
    @ObservedObject var app: AppModel
    @ObservedObject var editor: GraphEditorModel

    var body: some View {
        Menu {
            let existing = Set(app.graph.nodes.compactMap { $0.kind.deviceUID })
            let outs = app.outputs.filter { !existing.contains($0.uid) }
            let ins = app.inputs.filter { !existing.contains($0.uid) }
            let existingTaps = Set(app.graph.micTapBundleIDs)
            let apps = tappableApps().filter { !existingTaps.contains($0.bundleID) }

            if outs.isEmpty && ins.isEmpty && apps.isEmpty {
                Text("Everything here is already on the canvas")
            }
            if !outs.isEmpty {
                Section("Output devices") { ForEach(outs, id: \.uid) { d in Button(d.name) { app.addOutputNode(d) } } }
            }
            if !ins.isEmpty {
                Section("Input devices") { ForEach(ins, id: \.uid) { d in Button(d.name) { app.addInputNode(d) } } }
            }
            if !apps.isEmpty {
                Section("App audio (process taps)") {
                    ForEach(apps, id: \.bundleID) { a in Button(a.name + (a.isRunningOutput ? "  ●" : "")) { app.addTapNode(a) } }
                }
            }
        } label: {
            Label("Add node", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 12) {
            swatch(dashed: false, text: "live")
            swatch(dashed: true, text: "waiting")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    private func swatch(dashed: Bool, text: String) -> some View {
        HStack(spacing: 4) {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(p, with: .color(.secondary),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [4, 4] : []))
            }
            .frame(width: 20, height: 8)
            Text(text)
        }
    }
}

// MARK: - Glyphs + small helpers

private enum NodeGlyph {
    static func name(for kind: GKind, title: String) -> String {
        switch kind {
        case .program: return "play.rectangle.fill"
        case .graph(let k):
            switch k {
            case .hub: return "square.stack.3d.up.fill"
            case .mic: return "mic.fill"
            case .input: return "waveform"
            case .tap: return "app.fill"
            case .output:
                let n = title.lowercased()
                if n.contains("macbook") || n.contains("built-in") || n.contains("built in") { return "laptopcomputer" }
                if n.contains("airpod") { return "airpodspro" }
                if n.contains("display") || n.contains("studio") || n.contains("xdr") { return "display" }
                return "hifispeaker.fill"
            }
        }
    }
}

private extension CGPoint {
    func offset(_ s: CGSize) -> CGPoint { CGPoint(x: x + s.width, y: y + s.height) }
}

extension View {
    /// Liquid-glass button where the SDK has it (macOS 26+), a bordered button otherwise.
    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26.0, *) { self.buttonStyle(.glass) }
        else { self.buttonStyle(.bordered) }
    }
}
