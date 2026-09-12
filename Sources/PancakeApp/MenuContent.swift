import AppKit
import PancakeCore
import SwiftUI

/// The menu bar panel, styled after macOS's own Sound menu (see the reference in the repo):
/// a title, a volume slider, then Output and Input sections of device rows with a circular
/// device glyph that fills blue when selected. Each section carries one lock that pins whatever
/// is selected in it. Rendered in a `.window`-style MenuBarExtra so it's real SwiftUI, not an
/// NSMenu.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sound")
                .font(.system(size: 15, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.top, 2)

            VolumeSlider(model: model)

            Divider().padding(.vertical, 2)

            // OUTPUT
            SectionHeader(title: "Output",
                          locked: model.lockOutput,
                          lockHelp: model.lockOutput
                            ? "Locked: holding this output. Won't auto-switch to another device that connects; if it disconnects you get silence, not the speakers."
                            : "Unlocked: follows the system default output (AirPods connecting switch to them).",
                          toggle: { model.toggleOutputLock() })
            if model.menuOutputs.isEmpty {
                EmptyRow(text: "No output devices")
            }
            ForEach(model.menuOutputs) { item in
                MenuRow(action: { model.select(item) }) {
                    DeviceLabel(glyph: Self.outputGlyph(item),
                                name: item.name,
                                subtitle: item.present ? nil : "not connected",
                                battery: item.battery,
                                selected: item.uid == model.desiredOutputUID,
                                dimmed: !item.present,
                                trailing: (!item.present && item.isBluetooth) ? "arrow.clockwise" : nil)
                }
                .disabled(!item.present && !item.isBluetooth)
            }

            Divider().padding(.vertical, 2)

            // INPUT
            SectionHeader(title: "Input",
                          locked: model.lockInput,
                          lockHelp: model.lockInput
                            ? "Locked: pinning this as the system input so nothing (like AirPods on connect) can steal it and drag Bluetooth into low-quality call mode."
                            : "Unlocked: this mic feeds Pancake Mic, but the system default input is left alone.",
                          toggle: { model.toggleInputLock() })
            if model.menuInputs.isEmpty {
                EmptyRow(text: "No input devices")
            }
            ForEach(model.menuInputs) { item in
                MenuRow(action: { model.selectInput(item) }) {
                    DeviceLabel(glyph: "mic.fill",
                                name: item.name,
                                subtitle: item.present ? nil : "not connected",
                                battery: [],
                                selected: item.uid == model.desiredInputUID,
                                dimmed: !item.present,
                                trailing: nil)
                }
                .disabled(!item.present)
            }

            Divider().padding(.vertical, 2)
            StageSection(model: model)

            Divider().padding(.vertical, 2)

            MenuRow(action: { model.rebuildRouting() }) { ActionLabel("Rebuild audio routing", "arrow.triangle.2.circlepath") }
            MenuRow(action: { showGraph() }) { ActionLabel("Show graph…", "point.3.connected.trianglepath.dotted") }
            MenuRow(action: { model.openLog() }) { ActionLabel("Show log", "list.bullet.rectangle") }
            MenuRow(action: { model.toggleLaunchAtLogin() }) {
                HStack(spacing: 10) {
                    Image(systemName: model.launchAtLogin ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12)).frame(width: 20)
                        .foregroundStyle(model.launchAtLogin ? Color.accentColor : Color.secondary)
                    Text("Start at login").font(.system(size: 13))
                }
            }

            Divider().padding(.vertical, 2)

            MenuRow(action: { NSApp.terminate(nil) }) { ActionLabel("Quit pancake", "power") }
        }
        .padding(8)
        .frame(width: 300)
        .onAppear { model.refreshLaunchAtLogin() }
    }

    /// Open the routing window. We're an `.accessory` app (no Dock icon), so nudge ourselves to the
    /// front or the window would open unfocused behind whatever's active.
    private func showGraph() {
        openWindow(id: "graph")
        NSApp.activate(ignoringOtherApps: true)
    }

    static func outputGlyph(_ item: MenuOutput) -> String {
        if item.isBluetooth { return "airpodspro" }
        let n = item.name.lowercased()
        if n.contains("macbook") || n.contains("built-in") || n.contains("built in") { return "laptopcomputer" }
        if n.contains("display") || n.contains("studio") || n.contains("pro xdr") { return "display" }
        return "hifispeaker.fill"
    }
}

// MARK: - Volume

private struct VolumeSlider: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { model.toggleMute() }) {
                Image(systemName: model.hubMuted ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 16)
                    .foregroundStyle(model.hubMuted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Mute Pancake")

            Slider(value: Binding(get: { model.hubVolume }, set: { model.setHubVolume($0) }), in: 0...1)
                .controlSize(.small)
                .disabled(model.hubMuted)

            Image(systemName: "speaker.wave.3.fill")
                .frame(width: 18)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Section header with a lock

private struct SectionHeader: View {
    let title: String
    let locked: Bool
    let lockHelp: String
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: toggle) {
                LockGlyph(locked: locked, color: locked ? Color.accentColor : Color.secondary)
                    .frame(width: 13, height: 15)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(locked ? Color.accentColor.opacity(0.15) : Color.clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(lockHelp)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}

// MARK: - Rows

/// A tappable menu row with a hover highlight, matching the native menu feel.
private struct MenuRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.10) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct DeviceLabel: View {
    let glyph: String
    let name: String
    let subtitle: String?
    let battery: [Int]
    let selected: Bool
    let dimmed: Bool
    let trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(selected ? Color.accentColor : Color.secondary.opacity(0.22))
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                } else if !battery.isEmpty {
                    Text(battery.map { "\($0)%" }.joined(separator: "  "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if let trailing {
                Image(systemName: trailing).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .opacity(dimmed ? 0.55 : 1)
    }
}

// MARK: - Screen share (Pancake Stage)

/// Controls for the Pancake Stage, driven through the stage.json IPC. The Stage process watches the
/// same file, so picking here and picking in the Stage's own window stay in sync.
private struct StageSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("SCREEN SHARE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.stageRunning {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("on").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)

            if model.stageRunning {
                Menu {
                    Button { model.setStageApp(nil) } label: {
                        if model.stageConfig.bundleID == nil { Label("None (no audio)", systemImage: "checkmark") }
                        else { Text("None (no audio)") }
                    }
                    if !model.stageApps.isEmpty { Divider() }
                    ForEach(model.stageApps, id: \.bundleID) { app in
                        Button { model.setStageApp(app.bundleID) } label: {
                            if model.stageConfig.bundleID == app.bundleID { Label(app.name, systemImage: "checkmark") }
                            else { Text(app.name + (app.isRunningOutput ? "  ●" : "")) }
                        }
                    }
                } label: {
                    ActionLabel("Audio: \(model.stageAppName ?? "None")", "music.note")
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 6)

                MenuRow(action: { model.stopStage() }) { ActionLabel("Stop screen share", "stop.circle") }
            } else {
                MenuRow(action: { model.startStage() }) { ActionLabel("Start screen share", "play.rectangle") }
            }
        }
        .onAppear { model.refreshStage() }
    }
}

private struct ActionLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, _ symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 20).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13))
        }
    }
}

private struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
    }
}

/// A padlock whose body never moves between states: locked closes and lowers the shackle,
/// unlocked raises it and breaks the loop open, both keeping the shackle horizontally centred.
struct LockGlyph: View {
    let locked: Bool
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let ox = (size.width - s) / 2, oy = (size.height - s) / 2
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

            // Body (fixed in both states)
            let body = CGRect(x: ox + 0.16 * s, y: oy + 0.46 * s, width: 0.68 * s, height: 0.50 * s)
            ctx.fill(Path(roundedRect: body, cornerRadius: 0.12 * s), with: .color(color))
            // Keyhole carved out
            ctx.blendMode = .destinationOut
            ctx.fill(Path(ellipseIn: CGRect(x: ox + 0.455 * s, y: oy + 0.60 * s, width: 0.09 * s, height: 0.09 * s)), with: .color(.black))
            ctx.blendMode = .normal

            // Shackle — same horizontal centre in both states
            let leftX: CGFloat = 0.32, rightX: CGFloat = 0.68, bodyTop: CGFloat = 0.47
            var shackle = Path()
            if locked {
                let spring: CGFloat = 0.34
                shackle.move(to: P(leftX, bodyTop))
                shackle.addLine(to: P(leftX, spring))
                shackle.addQuadCurve(to: P(rightX, spring), control: P(0.5, -0.06))
                shackle.addLine(to: P(rightX, bodyTop))
            } else {
                let spring: CGFloat = 0.24
                shackle.move(to: P(leftX, bodyTop))                 // left leg stays into the body
                shackle.addLine(to: P(leftX, spring))
                shackle.addQuadCurve(to: P(rightX, spring), control: P(0.5, -0.16))
                shackle.addLine(to: P(rightX, 0.37))                // right leg lifted → loop open
            }
            ctx.stroke(shackle, with: .color(color), style: StrokeStyle(lineWidth: 0.12 * s, lineCap: .round, lineJoin: .round))
        }
    }
}
