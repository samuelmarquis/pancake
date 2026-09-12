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
        .ignoresSafeArea(.container, edges: .top)   // let the top bar reach up flush with the traffic lights
        .frame(minWidth: 460, minHeight: 340)
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
                    // Right-click over a wire → Remove; over empty canvas → add a node at the cursor.
                    .contextMenu {
                        if let eid = editor.hoveredEdge ?? editor.edgeUnderCursor() {
                            Button("Remove", role: .destructive) { editor.removeEdge(eid) }
                        } else {
                            addNodeItems(app: app, editor: editor, atCursor: true)
                        }
                    }

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
            .contentShape(Rectangle())
            // One tracker for the whole canvas decides hover geometrically — robust against layering.
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): editor.hoverAt(p)
                case .ended: editor.hoverEnded()
                }
            }
        }
    }

    private var nodeCards: some View {
        ForEach(editor.gnodes) { node in
            if let origin = editor.positions[node.id] {
                let center = CGPoint(x: origin.x + GraphGeom.nodeWidth / 2,
                                     y: origin.y + GraphGeom.nodeHeight / 2).offset(editor.pan)
                cardBody(node)
                    .frame(width: GraphGeom.nodeWidth, height: GraphGeom.nodeHeight)
                    .position(center)
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { editor.dragNode(node.id, translation: $0.translation) }
                            .onEnded { _ in editor.endNodeDrag(node.id) }
                    )
            }
        }
    }

    @ViewBuilder private func cardBody(_ node: GNode) -> some View {
        if case .graph(.recorder) = node.kind {
            RecorderCard(editor: editor, node: node, hovered: editor.hoveredNode == node.id)
        } else {
            NodeCard(node: node, hovered: editor.hoveredNode == node.id)
        }
    }

    private var portDots: some View {
        ForEach(editor.gnodes) { node in
            if let c = editor.portCenter(node.id) {
                PortDot(editor: editor, node: node, model: c)
            }
        }
    }

    /// The iOS-style floating delete bubble at a hovered node's top-right corner.
    private var deleteBubbles: some View {
        ForEach(editor.gnodes) { node in
            if editor.hoveredNode == node.id, !node.isPermanent, let origin = editor.positions[node.id] {
                DeleteBubble(onRemove: { editor.removeNode(node.id) })
                    .position(CGPoint(x: origin.x + GraphGeom.nodeWidth, y: origin.y).offset(editor.pan))
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
                    ColorBlend.oklch(e.c0, e.c1), startPoint: e.from, endPoint: e.to)
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

// MARK: - Edge interaction (gain knob / stage badge at the midpoint)

/// Renders the knob (audio) or record badge (screen share) at a hovered wire's midpoint, and carries
/// their drag/tap gestures. Hover itself is decided centrally (GraphEditorModel.hoverAt) — this view
/// has no hit region of its own, so it can never steal hover from nodes or other wires.
private struct EdgeInteractor: View {
    @ObservedObject var editor: GraphEditorModel
    let edge: BusEdge
    let from: CGPoint
    let to: CGPoint

    private var mid: CGPoint { bezierMid(from, to) }
    private var hot: Bool { editor.hoveredEdge == edge.id || editor.knobEdge == edge.id }

    /// The wire's endpoint colours (source hue on the left, sink hue on the right) — the knob wears
    /// the same gradient the wire does.
    private var wireColors: (Color, Color) {
        let d = editor.descByID
        let a = d[edge.from].map { GraphPalette.color(for: $0.kind) } ?? .gray
        let b = d[edge.to].map { GraphPalette.color(for: $0.kind) } ?? .gray
        return (a, b)
    }

    var body: some View {
        if hot {
            switch edge.kind {
            case .audio:
                Knob(gain: edge.gain, c0: wireColors.0, c1: wireColors.1)
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
                    .contextMenu { Button("Remove", role: .destructive) { editor.removeEdge(edge.id) } }
                    .help("Drag to set gain · double-click for unity")
                    .position(mid)
            case .stage:
                StageBadge()
                    .contextMenu { Button("Remove", role: .destructive) { editor.removeEdge(edge.id) } }
                    .help("Screen-share source. ⌫ to stop sharing this app.")
                    .position(mid)
            }
        }
    }
}

/// A ring-gauge gain knob (per the mock): a thick arc open at the bottom, filled to the current
/// gain, with the dB value large in the centre. Drag it to set gain, double-click for unity.
private struct Knob: View {
    let gain: Float
    let c0: Color      // wire's left (source) hue
    let c1: Color      // wire's right (sink) hue
    private var fraction: CGFloat { CGFloat((min(12, max(-48, GainMath.dB(gain))) + 48) / 60) }
    /// The wire's own gradient (blended in OKLCH, like the wires), left-to-right across the knob —
    /// worn by both the filled arc and the dB text.
    private var wire: LinearGradient { LinearGradient(gradient: ColorBlend.oklch(c0, c1), startPoint: .leading, endPoint: .trailing) }

    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)             // legible backing over the wires
                .frame(width: 38, height: 38)
                .overlay(Circle().stroke(.primary.opacity(0.10), lineWidth: 1))
            GaugeArc(fraction: 1)
                .stroke(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            GaugeArc(fraction: fraction)
                .stroke(wire, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            Text(GainMath.label(gain))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(wire)
                .padding(.horizontal, 8)
        }
        .frame(width: 48, height: 48)
        .shadow(color: .black.opacity(0.22), radius: 4, y: 1)
        .contentShape(Circle())
    }
}

/// A 270°-sweep arc, open at the bottom, starting lower-left. `fraction` is how much of the sweep to
/// draw (1 = full track). Sampled by hand so the sweep direction is unambiguous.
private struct GaugeArc: Shape {
    var fraction: CGFloat
    var animatableData: CGFloat { get { fraction } set { fraction = newValue } }
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2 - 2.5
        let sweep = 270.0 * Double(max(0, min(1, fraction)))
        var p = Path()
        let steps = 64
        for i in 0...steps {
            let a = (135.0 + sweep * Double(i) / Double(steps)) * .pi / 180
            let pt = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
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

/// A recorder sink: the usual card, but its second line is a transport — a record/stop button, the
/// elapsed time while capturing, and a folder button to choose where the next take is saved.
private struct RecorderCard: View {
    @ObservedObject var editor: GraphEditorModel
    let node: GNode
    let hovered: Bool

    private var color: Color { GraphPalette.color(for: node.kind) }
    private var recording: Bool { editor.isRecording(node.id) }
    private var elapsed: TimeInterval { editor.recordElapsed[node.id] ?? 0 }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.9))
                Image(systemName: "recordingtape").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 7) {
                    Button(action: { editor.toggleRecording(node.id) }) {
                        Image(systemName: recording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(color)
                            .symbolEffect(.pulse, isActive: recording)
                    }
                    .buttonStyle(.plain)
                    .help(recording ? "Stop recording" : "Start recording")
                    Text(recording ? timeString(elapsed) : "ready")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(recording ? color : .secondary)
                    Spacer(minLength: 0)
                    Button(action: { editor.chooseRecordingDestination(node.id) }) {
                        Image(systemName: editor.hasChosenDestination(node.id) ? "folder.fill" : "folder")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(recording)
                    .help("Choose where to save the next recording (default: ~/Music/Pancake)")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(width: GraphGeom.nodeWidth, height: GraphGeom.nodeHeight, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: GraphGeom.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GraphGeom.cornerRadius, style: .continuous)
                .stroke(recording || hovered ? color : Color.primary.opacity(0.10), lineWidth: recording || hovered ? 1.8 : 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color)
                .frame(width: 3.5, height: GraphGeom.nodeHeight - 18).padding(.leading, 4).opacity(0.9)
        }
        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
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
        GeometryReader { geo in
            HStack(spacing: 10) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                Text("Routing").font(.system(size: 13, weight: .semibold))

                Divider().frame(height: 16)

                AddMenu(app: app, editor: editor)
                Button { editor.snapToGrid() } label: { Label("Tidy", systemImage: "square.grid.3x3") }
                    .glassButton()
                    .help("Snap nodes to the grid")
                Button { editor.resetView() } label: { Label("Recenter", systemImage: "scope") }
                    .glassButton()

                Spacer()
                if geo.size.width > 600 { Legend() }   // drops out when the window is narrow
            }
            .controlSize(.small)
            .padding(.leading, 82)   // clear the traffic lights
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.primary.opacity(0.08)), alignment: .bottom)
        }
        .frame(height: 30)   // title-bar band height → flush with the traffic lights
    }
}

private struct AddMenu: View {
    @ObservedObject var app: AppModel
    @ObservedObject var editor: GraphEditorModel

    var body: some View {
        Menu {
            addNodeItems(app: app, editor: editor, atCursor: false)
        } label: {
            Label("Add node", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// The palette of addable nodes (live output/input devices and tappable apps), shared by the top-bar
/// "Add node" menu and the canvas right-click menu. `atCursor` drops the node where you clicked;
/// otherwise it lands in the auto-layout column.
@MainActor @ViewBuilder
private func addNodeItems(app: AppModel, editor: GraphEditorModel, atCursor: Bool) -> some View {
    let existing = Set(app.graph.nodes.compactMap { $0.kind.deviceUID })
    let outs = app.outputs.filter { !existing.contains($0.uid) }
    let ins = app.inputs.filter { !existing.contains($0.uid) }
    let existingTaps = Set(app.graph.micTapBundleIDs)
    let apps = tappableApps().filter { !existingTaps.contains($0.bundleID) }

    Section("Capture") {
        Button { editor.addRecorder(atCursor: atCursor) } label: { Label("Recorder", systemImage: "recordingtape") }
    }
    if outs.isEmpty && ins.isEmpty && apps.isEmpty {
        Text("All devices are already on the canvas")
    }
    if !outs.isEmpty {
        Section("Output devices") {
            ForEach(outs, id: \.uid) { d in
                Button(d.name) { atCursor ? editor.addOutputAtCursor(d) : app.addOutputNode(d) }
            }
        }
    }
    if !ins.isEmpty {
        Section("Input devices") {
            ForEach(ins, id: \.uid) { d in
                Button(d.name) { atCursor ? editor.addInputAtCursor(d) : app.addInputNode(d) }
            }
        }
    }
    if !apps.isEmpty {
        Section("App audio (process taps)") {
            ForEach(apps, id: \.bundleID) { a in
                Button(a.name + (a.isRunningOutput ? "  ●" : "")) { atCursor ? editor.addTapAtCursor(a) : app.addTapNode(a) }
            }
        }
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
            case .recorder: return "recordingtape"
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
