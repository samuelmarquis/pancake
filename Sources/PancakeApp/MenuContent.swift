import AppKit
import PancakeCore
import SwiftUI

/// The menu bar panel, styled after macOS's own Sound menu (see the reference in the repo):
/// a title, a volume slider, then Output and Input sections of device rows with a circular
/// device glyph that fills blue when selected. Each section carries one lock that pins whatever
/// is selected in it, and a pin per row that keeps a device listed even when it's away.
/// Rendered in a `.window`-style MenuBarExtra so it's real SwiftUI, not an NSMenu.
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

            if let warning = model.coreAudioWarning {
                CoreAudioWarningRow(text: warning)
            }

            Divider().padding(.vertical, 2)
            DeviceSection(model: model, role: .output)

            Divider().padding(.vertical, 2)
            DeviceSection(model: model, role: .input)

            Divider().padding(.vertical, 2)
            StageSection(model: model)

            Divider().padding(.vertical, 2)

            MenuRow(action: { model.rebuildRouting() }) { ActionLabel("Rebuild audio routing", "arrow.triangle.2.circlepath") }
            MenuRow(action: { showGraph() }) { ActionLabel("Show graph…", "point.3.connected.trianglepath.dotted") }
            MenuRow(action: { model.showRecordingsFolder() }) { ActionLabel("Show recordings folder", "folder") }
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
        .onAppear {
            model.refreshLaunchAtLogin()
            // Cheap, and it's what gives a Bluetooth row its real icon (earbuds vs speaker).
            model.refreshPairedBluetooth()
        }
    }

    /// Open the routing window. We're an `.accessory` app (no Dock icon), so nudge ourselves to the
    /// front or the window would open unfocused behind whatever's active. The menu-bar popover is the
    /// key window while the menu is open; close it first so it doesn't linger behind the window. If the
    /// graph is already open on another desktop it comes to this one (`GraphWindow`) — before the
    /// activation, which would otherwise switch Spaces to wherever the app has a window.
    private func showGraph() {
        NSApp.keyWindow?.close()
        GraphWindow.prepareToShow()
        openWindow(id: "graph")
        NSApp.activate(ignoringOtherApps: true)
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

// MARK: - A device section (Output or Input)

/// One half of the menu. The rows are every device that's here plus the ones pinned to this list
/// that aren't — a pinned Bluetooth row is a button that goes and gets the device, which is also how
/// you take it back from a phone that's holding it. The `+` in the header pins something that isn't
/// here to pin from the list itself: anything already paired in Bluetooth.
private struct DeviceSection: View {
    @ObservedObject var model: AppModel
    let role: DeviceRole
    @State private var picking = false

    private var rows: [MenuDevice] { role == .output ? model.menuOutputs : model.menuInputs }
    private var selectedUID: String? { role == .output ? model.desiredOutputUID : model.desiredInputUID }
    private var locked: Bool { role == .output ? model.lockOutput : model.lockInput }

    private var lockHelp: String {
        switch (role, locked) {
        case (.output, true):
            return "Locked: holding this output. Won't auto-switch to another device that connects; if it disconnects you get silence, not the speakers."
        case (.output, false):
            return "Unlocked: follows the system default output (AirPods connecting switch to them)."
        case (.input, true):
            return "Locked: pinning this as the system input so nothing (like AirPods on connect) can steal it and drag Bluetooth into low-quality call mode."
        case (.input, false):
            return "Unlocked: this mic feeds Pancake Mic, but the system default input is left alone."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: role.title,
                          locked: locked,
                          lockHelp: lockHelp,
                          toggleLock: { role == .output ? model.toggleOutputLock() : model.toggleInputLock() },
                          picking: $picking,
                          pickHelp: "Pin a paired Bluetooth device to the \(role.title) list")

            if rows.isEmpty {
                EmptyRow(text: "No \(role.rawValue) devices")
            }
            ForEach(rows) { item in
                DeviceRow(model: model, item: item, selected: isSelected(item))
            }

            if picking {
                PinPicker(model: model, role: role, showing: $picking)
            }
        }
    }

    private func isSelected(_ item: MenuDevice) -> Bool {
        guard let selectedUID else { return false }
        return MenuDevice.sameUID(item.uid, selectedUID)
    }
}

/// A section title, the "pin a device" toggle, and the lock that holds the section's selection.
private struct SectionHeader: View {
    let title: String
    let locked: Bool
    let lockHelp: String
    let toggleLock: () -> Void
    @Binding var picking: Bool
    let pickHelp: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { picking.toggle() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(picking ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(picking ? Color.accentColor.opacity(0.15) : Color.clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(pickHelp)
            Button(action: toggleLock) {
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

/// One device. Clicking it selects it — or, when it isn't here and it's Bluetooth, asks for it and
/// selects it when it arrives (the ↻ and "connecting…" say which is happening; a device that never
/// comes ends up "unreachable"). The pin on the right keeps the device in this list for good.
///
/// The row is two buttons side by side rather than a pin nested inside the row's button: nesting
/// buttons makes hit-testing a coin toss, and the pin must never be mistaken for "use this device".
private struct DeviceRow: View {
    @ObservedObject var model: AppModel
    let item: MenuDevice
    let selected: Bool
    @State private var hover = false

    /// Absent, but it's Bluetooth: we can go and get it.
    private var connectable: Bool { !item.present && item.address != nil }
    private var connectState: AppModel.ConnectState? {
        item.address.flatMap { model.connectState[$0.lowercased()] }
    }

    private var subtitle: String? {
        guard !item.present else { return nil }
        switch connectState {
        case .asking: return "connecting…"
        case .unreachable: return "unreachable"
        case nil: return "not connected"
        }
    }

    private var mark: RowMark {
        guard connectable else { return .none }
        return connectState == .asking ? .working : .connect
    }

    private var help: String {
        if connectable { return "Connect \(item.name)" }
        if !item.present { return "\(item.name) isn't connected" }
        switch (item.role, selected) {
        case (.output, _): return "Play to \(item.name)"
        case (.input, false): return "Send \(item.name) to Pancake Mic"
        case (.input, true): return "Stop sending \(item.name) to Pancake Mic"
        }
    }

    private var glyph: String {
        if let kind = item.kind { return kind == .speaker ? "hifispeaker.fill" : "airpodspro" }
        if item.isBluetooth { return "airpodspro" }
        if item.role == .input { return "mic.fill" }
        let n = item.name.lowercased()
        if n.contains("macbook") || n.contains("built-in") || n.contains("built in") { return "laptopcomputer" }
        if n.contains("display") || n.contains("studio") || n.contains("pro xdr") { return "display" }
        return "hifispeaker.fill"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { model.select(item) }) {
                DeviceLabel(glyph: glyph, name: item.name, subtitle: subtitle, battery: item.battery,
                            selected: selected, dimmed: !item.present, mark: mark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.present && !connectable)
            .help(help)

            // The machine's own speakers/mic can't go anywhere, so there's nothing to pin them for.
            if !item.onboard {
                PinButton(pinned: item.pinned, showing: hover, name: item.name) { model.togglePin(item) }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.10) : .clear))
        .onHover { hover = $0 }
    }
}

/// Keeps a device in the menu whether or not it's connected. Invisible until you hover the row,
/// unless the device is already pinned — then it stays lit, so you can see what's a resident.
private struct PinButton: View {
    let pinned: Bool
    let showing: Bool
    let name: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(pinned ? Color.accentColor : (hover ? Color.primary : Color.secondary))
                .frame(width: 22, height: 22)
                .background(Circle().fill(pinned ? Color.accentColor.opacity(0.15) : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(pinned || showing ? 1 : 0)
        .allowsHitTesting(pinned || showing)
        .onHover { hover = $0 }
        .help(pinned ? "Stop keeping \(name) in this menu" : "Keep \(name) in this menu, connected or not")
    }
}

/// What sits at the right-hand end of a device label: nothing, the "I'll go and get it" arrow, or a
/// spinner while we're getting it.
private enum RowMark { case none, connect, working }

private struct DeviceLabel: View {
    let glyph: String
    let name: String
    let subtitle: String?
    let battery: [Int]
    let selected: Bool
    let dimmed: Bool
    var mark: RowMark = .none

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

            switch mark {
            case .none:
                EmptyView()
            case .connect:
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            case .working:
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 16, height: 16)
            }
        }
        .opacity(dimmed ? 0.55 : 1)
    }
}

// MARK: - Pinning something that isn't here

/// Every paired Bluetooth audio device this section doesn't already list. These are ordinary device
/// rows: clicking one connects it (and uses it once it arrives), and its pin keeps it in the list
/// for good — so you can reach a device you've never pinned without pinning it first. Pairing
/// something *new* is still System Settings' job, hence the last row.
private struct PinPicker: View {
    @ObservedObject var model: AppModel
    let role: DeviceRole
    /// The section's picker toggle, so the list can fold itself away from its own header.
    @Binding var showing: Bool

    private var candidates: [Bluetooth.Device] { model.pinnable(role) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PickerHeader(showing: $showing)

            if candidates.isEmpty {
                EmptyRow(text: model.pairedBluetooth.isEmpty
                         ? "No paired Bluetooth audio devices"
                         : "Everything paired is already listed here")
            }
            ForEach(candidates) { d in
                DeviceRow(model: model, item: model.row(for: d, role: role), selected: false)
            }
            MenuRow(action: { model.openBluetoothSettings() }) { ActionLabel("Bluetooth settings…", "gearshape") }
        }
        .padding(.leading, 10)
        .onAppear { model.refreshPairedBluetooth() }
    }
}

/// The picker's own title, which folds it away: a disclosure chevron and a hover highlight, so it
/// reads as the control it is rather than a label.
private struct PickerHeader: View {
    @Binding var showing: Bool
    @State private var hover = false

    var body: some View {
        Button(action: { showing = false }) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                Text("PAIRED BLUETOOTH")
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hover ? Color.primary : Color.secondary)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Hide the paired Bluetooth devices")
    }
}

// MARK: - Screen share (Pancake Stage)

/// Start/stop the Pancake Stage. The *source* (which app is streamed) is chosen in the graph now —
/// wire an app tap to the Pancake Program node — so this is just process control + status.
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
                Text(model.programSourceNames.isEmpty
                     ? "Sharing silence · wire sources into Pancake Program in the graph"
                     : "Sharing \(model.programSourceNames.joined(separator: " + "))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                MenuRow(action: { model.stopStage() }) { ActionLabel("Stop screen share", "stop.circle") }
            } else {
                MenuRow(action: { model.startStage() }) { ActionLabel("Start screen share", "play.rectangle") }
            }
        }
        .onAppear { model.refreshStage() }
    }
}

/// coreaudiod is unhealthy in a way that slows every app's audio (duplicate plug-in registrations).
/// Not pancake's state, so the fix is a command, offered with a copy button.
private struct CoreAudioWarningRow: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("Core Audio is degraded").font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(copied ? "Copied" : "Copy fix command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HALHealth.resetCommand, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 4)
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
