import AppKit
import PancakeCore
import SwiftUI


/// The visual routing editor — a pipewire-style patchbay for the pancake graph. Sources (Pancake,
/// inputs, app taps) sit on the left with output ports; sinks (outputs, Pancake Mic) on the right
/// with input ports. Drag between ports to route, channel by channel. Edits apply to the running
/// engine immediately and persist to graph.json; node positions persist separately to
/// graph-layout.json so the IPC file stays clean.
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
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    editor.deleteSelection(); return .handled
                }

            // Leading inset clears the hidden-title-bar traffic lights.
            Toolbar(app: app, editor: editor)
                .padding(.leading, 80)
                .padding(.trailing, 14)
                .padding(.top, 12)

            VStack {
                Spacer()
                Inspector(app: app, editor: editor)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .background(WindowBackground())
        .onAppear {
            editor.syncNodes()
            canvasFocused = true
        }
        .onChange(of: app.graph) { _, _ in editor.syncNodes() }
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

private struct GraphCanvas: View {
    @ObservedObject var app: AppModel
    @ObservedObject var editor: GraphEditorModel

    /// Links that the engine is actually running right now (device present, tap live).
    private var liveLinks: Set<LinkRef> {
        Set((app.effectiveGraph?.links ?? []).map { LinkRef(from: $0.from, to: $0.to) })
    }

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                // Dotted grid + pan/clear-selection surface.
                DotGrid(pan: editor.pan)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { editor.panBy($0.translation) }
                            .onEnded { _ in editor.endPan() }
                    )
                    .onTapGesture { editor.selection = .none }

                wires
                pendingWire
                nodeCards
                portDots
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Existing links.
    private var wires: some View {
        let live = liveLinks
        let desc = editor.descByID
        return ForEach(app.graph.links, id: \.self) { link in
            if let a = editor.portCenter(link.from.node, link.from.channel),
               let b = editor.portCenter(link.to.node, link.to.channel) {
                let from = a.offset(editor.pan), to = b.offset(editor.pan)
                let color = desc[link.from.node].map { GraphPalette.color(for: $0.kind) } ?? .accentColor
                let isLive = live.contains(LinkRef(from: link.from, to: link.to))
                let selected = editor.selection == .link(LinkRef(from: link.from, to: link.to))
                Wire(from: from, to: to, color: color, live: isLive, selected: selected, gain: link.gain) {
                    editor.selection = .link(LinkRef(from: link.from, to: link.to))
                }
            }
        }
    }

    @ViewBuilder private var pendingWire: some View {
        if let p = editor.pending {
            let from = (p.fromIsSource ? p.start : p.current).offset(editor.pan)
            let to = (p.fromIsSource ? p.current : p.start).offset(editor.pan)
            WireShape(from: from, to: to)
                .stroke(Color.accentColor.opacity(0.9),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 6]))
                .allowsHitTesting(false)
        }
    }

    private var nodeCards: some View {
        ForEach(editor.gnodes) { node in
            if let origin = editor.positions[node.id] {
                let center = CGPoint(x: origin.x + GraphGeom.nodeWidth / 2,
                                     y: origin.y + node.height / 2).offset(editor.pan)
                NodeCard(node: node,
                         selected: editor.selection == .node(node.id))
                    .frame(width: GraphGeom.nodeWidth, height: node.height)
                    .position(center)
                    .onTapGesture { editor.selection = .node(node.id) }
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
            ForEach(0..<node.channels, id: \.self) { ch in
                if let c = editor.portCenter(node.id, ch) {
                    PortDot(editor: editor, node: node, channel: ch, model: c)
                }
            }
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

// MARK: - Wire

private struct WireShape: Shape {
    var from: CGPoint
    var to: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let dx = max(36, abs(to.x - from.x) * 0.5)
        p.move(to: from)
        p.addCurve(to: to,
                   control1: CGPoint(x: from.x + dx, y: from.y),
                   control2: CGPoint(x: to.x - dx, y: to.y))
        return p
    }
}

/// The wire's *hit region*: the outline of a fat stroke of the curve, so only taps near the wire
/// select it — the wire view itself fills the canvas, and without this its whole frame would be tappable.
private struct WireHitShape: Shape {
    var from: CGPoint
    var to: CGPoint
    var width: CGFloat
    func path(in rect: CGRect) -> Path {
        WireShape(from: from, to: to).path(in: rect)
            .strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

private struct Wire: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let live: Bool
    let selected: Bool
    let gain: Float
    let onSelect: () -> Void

    var body: some View {
        let shape = WireShape(from: from, to: to)
        ZStack {
            if selected {
                shape.stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .shadow(color: color.opacity(0.6), radius: 4)
            }
            shape.stroke(live ? color : color.opacity(0.45),
                         style: StrokeStyle(lineWidth: selected ? 3 : 2.2,
                                            lineCap: .round,
                                            dash: live ? [] : [5, 6]))
            if gain != 1 {
                GainPill(gain: gain)
                    .position(midpoint)
            }
        }
        .contentShape(WireHitShape(from: from, to: to, width: 18))
        .onTapGesture(perform: onSelect)
    }

    private var midpoint: CGPoint {
        let dx = max(36, abs(to.x - from.x) * 0.5)
        let c1 = CGPoint(x: from.x + dx, y: from.y)
        let c2 = CGPoint(x: to.x - dx, y: to.y)
        // Cubic Bézier at t = 0.5.
        return CGPoint(x: 0.125 * from.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * to.x,
                       y: 0.125 * from.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * to.y)
    }
}

private struct GainPill: View {
    let gain: Float
    var body: some View {
        Text(GainMath.label(gain))
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(0.12)))
    }
}

// MARK: - Node card

private struct NodeCard: View {
    let node: GNode
    let selected: Bool

    private var color: Color { GraphPalette.color(for: node.kind) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: GraphGeom.headerHeight)
            VStack(spacing: 0) {
                ForEach(0..<node.channels, id: \.self) { ch in
                    channelRow(ch)
                        .frame(height: GraphGeom.rowHeight)
                }
            }
            .padding(.top, GraphGeom.topPad)
            .padding(.bottom, GraphGeom.bottomPad)
        }
        .frame(width: GraphGeom.nodeWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: GraphGeom.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GraphGeom.cornerRadius, style: .continuous)
                .stroke(selected ? color : Color.primary.opacity(0.10), lineWidth: selected ? 2 : 1)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: GraphGeom.cornerRadius, style: .continuous)
                .fill(color.opacity(0.14))
                .frame(height: GraphGeom.headerHeight)
                .mask(alignment: .top) { Rectangle().frame(height: GraphGeom.headerHeight) }
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
        .opacity(node.present ? 1 : 0.62)
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(color.opacity(0.9))
                Image(systemName: NodeGlyph.name(for: node.kind, title: node.title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(node.present ? node.subtitle : "not connected")
                    .font(.system(size: 10))
                    .foregroundStyle(node.present ? .secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 11)
    }

    private func channelRow(_ ch: Int) -> some View {
        HStack {
            if node.isSource { Spacer() }
            Text(ChannelName.label(ch, of: node.channels))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            if !node.isSource { Spacer() }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Port dot

private struct PortDot: View {
    @ObservedObject var editor: GraphEditorModel
    let node: GNode
    let channel: Int
    /// Port centre in model space (pan applied here for rendering).
    let model: CGPoint

    private var color: Color { GraphPalette.color(for: node.kind) }

    var body: some View {
        let screen = model.offset(editor.pan)
        // A generous transparent square around the dot makes it easy to grab; the visible dot is centred.
        ZStack {
            Circle().fill(color.opacity(0.22))
                .frame(width: GraphGeom.portRadius * 3.4, height: GraphGeom.portRadius * 3.4)
            Circle().fill(color)
                .overlay(Circle().stroke(.background, lineWidth: 2))
                .frame(width: GraphGeom.portRadius * 2, height: GraphGeom.portRadius * 2)
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .position(screen)
        .highPriorityGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if editor.pending == nil {
                        editor.beginConnection(from: Port(node.id, channel), isSource: node.isSource, at: model)
                    }
                    editor.updateConnection(translation: v.translation)
                }
                .onEnded { _ in editor.endConnection() }
        )
        .help("\(node.title) · \(ChannelName.label(channel, of: node.channels))")
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    @ObservedObject var app: AppModel
    @ObservedObject var editor: GraphEditorModel

    var body: some View {
        HStack(spacing: 10) {
            Label("Routing", systemImage: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .labelStyle(.titleAndIcon)

            Divider().frame(height: 18)

            AddMenu(app: app, editor: editor)

            Button { editor.autoArrange() } label: { Label("Tidy", systemImage: "rectangle.3.offgrid") }
                .glassButton()
            Button { editor.resetView() } label: { Label("Recenter", systemImage: "scope") }
                .glassButton()

            Spacer()

            Legend()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
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
                Section("Output devices") {
                    ForEach(outs, id: \.uid) { d in
                        Button(d.name) { app.addOutputNode(d) }
                    }
                }
            }
            if !ins.isEmpty {
                Section("Input devices") {
                    ForEach(ins, id: \.uid) { d in
                        Button(d.name) { app.addInputNode(d) }
                    }
                }
            }
            if !apps.isEmpty {
                Section("App audio (taps)") {
                    ForEach(apps, id: \.bundleID) { a in
                        Button(a.name + (a.isRunningOutput ? "  ●" : "")) { app.addTapNode(a) }
                    }
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

// MARK: - Inspector

private struct Inspector: View {
    @ObservedObject var app: AppModel
    @ObservedObject var editor: GraphEditorModel

    var body: some View {
        Group {
            switch editor.selection {
            case .link(let ref): LinkInspector(app: app, editor: editor, ref: ref)
            case .node(let id): NodeInspector(app: app, editor: editor, id: id)
            case .none: HintBar()
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
    }
}

private struct HintBar: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw").foregroundStyle(.secondary)
            Text("Drag from a port to another to route it. Select a wire to set its gain or remove it.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct LinkInspector: View {
    @ObservedObject var app: AppModel
    @ObservedObject var editor: GraphEditorModel
    let ref: LinkRef

    private var gain: Float { app.graph.links.first { $0.from == ref.from && $0.to == ref.to }?.gain ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(endpointName(ref.from.node)).fontWeight(.semibold)
                Text(ChannelName.label(ref.from.channel, of: channels(ref.from.node))).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(endpointName(ref.to.node)).fontWeight(.semibold)
                Text(ChannelName.label(ref.to.channel, of: channels(ref.to.node))).foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(size: 13)).lineLimit(1)

            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { GainMath.dB(gain) },
                    set: { editor.setSelectedGain(GainMath.linear($0)) }
                ), in: -48...12)
                Text(GainMath.label(gain))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
                Button("Unity") { editor.setSelectedGain(1) }
                    .controlSize(.small)
                    .glassButton()
                Button(role: .destructive) { editor.disconnectSelected() } label: {
                    Label("Disconnect", systemImage: "scissors")
                }
                .controlSize(.small)
                .glassButton()
            }
        }
    }

    private func endpointName(_ id: NodeID) -> String { editor.descByID[id]?.title ?? id.rawValue }
    private func channels(_ id: NodeID) -> Int { editor.descByID[id]?.channels ?? 2 }
}

private struct NodeInspector: View {
    @ObservedObject var app: AppModel
    @ObservedObject var editor: GraphEditorModel
    let id: NodeID

    var body: some View {
        let node = editor.descByID[id]
        HStack(spacing: 10) {
            if let node {
                Image(systemName: NodeGlyph.name(for: node.kind, title: node.title))
                    .foregroundStyle(GraphPalette.color(for: node.kind))
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(node.subtitle) · \(node.channels) ch · \(node.present ? "connected" : "not connected")")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let node, !node.isPermanent {
                Button(role: .destructive) { editor.deleteSelection() } label: {
                    Label("Remove", systemImage: "trash")
                }
                .controlSize(.small)
                .glassButton()
            } else {
                Text("fixed bus").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Small helpers

private enum GainMath {
    static func dB(_ g: Float) -> Double { g <= 0.0016 ? -48 : Double(20 * log10f(g)) }
    static func linear(_ db: Double) -> Float { db <= -48 ? 0 : powf(10, Float(db) / 20) }
    static func label(_ g: Float) -> String {
        if g == 1 { return "0.0 dB" }
        if g <= 0.0016 { return "−∞ dB" }
        return String(format: "%+.1f dB", 20 * log10f(g))
    }
}

private enum ChannelName {
    static func label(_ ch: Int, of total: Int) -> String {
        if total <= 2 { return ch == 0 ? "L" : "R" }
        return "\(ch + 1)"
    }
}

private enum NodeGlyph {
    static func name(for kind: NodeKind, title: String) -> String {
        switch kind {
        case .hub: return "square.stack.3d.up.fill"
        case .mic: return "mic.fill"
        case .input: return "waveform"
        case .tap: return "app.fill"
        case .output:
            let n = title.lowercased()
            if n.contains("macbook") || n.contains("built-in") || n.contains("built in") { return "laptopcomputer" }
            if n.contains("airpod") || n.contains("âãåä") { return "airpodspro" }
            if n.contains("display") || n.contains("studio") || n.contains("xdr") { return "display" }
            return "hifispeaker.fill"
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
