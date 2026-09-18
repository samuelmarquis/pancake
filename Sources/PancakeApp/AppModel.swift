import AppKit
import AVFoundation
import CoreAudio
import Foundation
import PancakeCore
import ServiceManagement


@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var desiredOutputUID: String?
    @Published private(set) var desiredOutputLabel: String?
    @Published private(set) var desiredInputUID: String?
    @Published private(set) var desiredInputLabel: String?
    @Published private(set) var lockOutput: Bool = false
    @Published private(set) var lockInput: Bool = false
    /// Pancake's own output volume (0…1) — the value the volume keys move and the slider drives.
    @Published var hubVolume: Double = 1
    @Published private(set) var hubMuted: Bool = false
    @Published private(set) var state: Engine.State = .stopped

    // Pancake Stage (clean Discord screen-share). It has no configuration: the menu launches and quits
    // the process, and *what* it shares is whatever the graph wires into the Pancake Program node.
    @Published private(set) var stageRunning = false
    /// Apps that can be tapped (the graph palette), refreshed off the main thread on launch/quit and
    /// whenever the HAL's process list changes.
    @Published private(set) var tapCandidates: [TappableApp] = []
    /// Set when coreaudiod itself is unhealthy in a way pancake can see (duplicate plug-in
    /// registrations — see `HALHealth`). Shown in the menu with the fix.
    @Published private(set) var coreAudioWarning: String?
    static let stageBundleID = "com.pancake.stage"

    /// Whether the app is registered to launch at login (SMAppService).
    @Published private(set) var launchAtLogin = false

    /// Devices the user wants listed whether or not they're connected (`PinnedDevices.swift`).
    @Published private(set) var pins: [PinnedDevice] = []
    /// Paired Bluetooth audio devices, for the menu's "pin a device" picker. Refreshed off the main
    /// thread when the picker opens.
    @Published private(set) var pairedBluetooth: [Bluetooth.Device] = []
    /// What a summoned Bluetooth device's row is showing, keyed by lowercased address. Lives here
    /// rather than in the row so it survives closing the menu mid-connect.
    @Published private(set) var connectState: [String: ConnectState] = [:]

    enum ConnectState { case asking, unreachable }

    private let store = GraphStore()
    private let pinStore = PinStore()
    /// A Bluetooth device we asked for and mean to select once the HAL lists it, per section.
    /// Clicking a row that isn't here means "play here" — it just has to arrive first.
    private var awaiting: [DeviceRole: (address: String, deadline: Date)] = [:]
    /// How long we wait for a summoned device before calling it unreachable. `openConnection` itself
    /// can sit for several seconds, and the HAL takes a moment more to list the device.
    private static let connectWindow: TimeInterval = 12
    /// The desired routing graph. Published so the visual editor re-renders when it changes —
    /// whether the change came from the menu, the editor itself, the CLI, or a hand-edit of the file.
    @Published private(set) var graph: Graph
    private let engine: Engine
    private let queue = DispatchQueue(label: "com.pancake.app")
    private var monitor: HardwareMonitor?
    private var watcher: FileWatcher?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Everything that talks to the HAL on the app's behalf lives on `queue`, never the main thread.
    /// When coreaudiod is overloaded a single property read can take seconds; done on the main thread
    /// that froze the menu and the graph window with it (2026-09-13). This holds the `queue`-only state.
    private final class HALWork: @unchecked Sendable {
        /// Listeners on Pancake's volume/mute so the slider tracks the hardware keys live.
        var hubVolumeListeners: [PropertyListener] = []
        /// Coalescing: a burst of HAL events runs each refresh at most once more after the current one.
        var devicesBusy = false, devicesAgain = false
        var appsBusy = false, appsAgain = false
        /// Latest slider value not yet written (a drag produces far more values than the HAL needs).
        var pendingVolume: Float32?
    }
    private let hal = HALWork()

    private init() {
        Log.logToFile()
        Log.minimumLevel = .debug   // bring-up: the watchdog's health lines are the evidence we need
        Log.info("pancake app starting (pid \(ProcessInfo.processInfo.processIdentifier))")

        var loaded = (try? store.load()) ?? Graph()
        if Self.migrateLegacyStageConfig(into: &loaded) {
            do { try store.save(loaded) } catch { Log.warn("save migrated graph: \(error)") }
        }
        graph = loaded
        pins = pinStore.load()
        engine = Engine(graph: loaded)

        let engineRef = engine
        engine.onStateChange = { [weak self] s in
            let warning = HALHealth.describe(engineRef.plugInDuplicates)   // snapshot read, never waits
            Task { @MainActor in
                self?.state = s
                if self?.coreAudioWarning != warning { self?.coreAudioWarning = warning }
            }
        }
        syncFromGraph()
        refreshDevices()

        monitor = try? HardwareMonitor(queue: queue) { [weak self] event in
            switch event {
            case .devicesChanged, .serviceRestarted: Task { @MainActor in self?.refreshDevices() }
            case .processListChanged: Task { @MainActor in self?.refreshTapCandidates() }
            default: break
            }
        }

        let store = self.store
        watcher = store.watch(queue: queue) { [weak self] in
            guard let g = try? store.load() else { return }
            Task { @MainActor in self?.graphFileChanged(g) }
        }

        observeStageLifecycle()
        refreshLaunchAtLogin()

        engine.start()
        ensureMicrophoneAccess()
    }

    // MARK: Microphone permission

    /// Reading any input stream — including our own Pancake device inside the aggregate — is
    /// "microphone access" to TCC. A client without it gets zero-filled input and no error, which
    /// looks exactly like a routing bug. Ask explicitly, log the answer, and restart IO once granted.
    private func ensureMicrophoneAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.info("microphone access: \(Self.describe(status))")
        switch status {
        case .authorized:
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        Log.info("microphone access granted; restarting IO so the aggregate reads real input")
                        self?.engine.rebuildNow()
                    } else {
                        Log.warn(Self.deniedHint)
                    }
                }
            }
        default:
            Log.warn(Self.deniedHint)
        }
    }

    private static let deniedHint =
        "microphone access is not granted: the engine will read silence from every input, including Pancake. " +
        "System Settings › Privacy & Security › Microphone → pancake, or `tccutil reset Microphone com.pancake.app` and relaunch."

    private static func describe(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    // MARK: Derived state for the menu

    var menuOutputs: [MenuDevice] { menuRows(.output) }
    var menuInputs: [MenuDevice] { menuRows(.input) }

    /// One section's rows: every device that's here, plus the pinned ones that aren't and (always)
    /// the one the graph wants, so a selection is never invisible. The machine's own speakers/mic come
    /// first — they can't go away, so they're the one row always worth knowing where to find — and the
    /// rest sort by name as one list: absent rows sit where the device *usually* sits, so nothing
    /// jumps around when it connects.
    private func menuRows(_ role: DeviceRole) -> [MenuDevice] {
        let devices = role == .output ? outputs : inputs
        var rows = devices.map {
            MenuDevice(uid: $0.uid, name: $0.name, role: role, present: true,
                       isBluetooth: $0.transport.isBluetooth, pinned: isPinned($0.uid, role),
                       onboard: $0.transport == .builtIn, kind: bluetoothKind($0.uid))
        }
        var absent: [(uid: String, name: String, pinned: Bool)] =
            pins.filter { $0.role == role }.map { ($0.uid, $0.name, true) }
        let want = role == .output ? desiredOutputUID : desiredInputUID
        if let want {
            absent.append((want, (role == .output ? desiredOutputLabel : desiredInputLabel) ?? want,
                           isPinned(want, role)))
        }
        for a in absent where !rows.contains(where: { MenuDevice.sameUID($0.uid, a.uid) }) {
            rows.append(MenuDevice(uid: a.uid, name: a.name, role: role, present: false,
                                   isBluetooth: Bluetooth.address(fromDeviceUID: a.uid) != nil,
                                   pinned: a.pinned, kind: bluetoothKind(a.uid)))
        }
        return rows.sorted {
            if $0.onboard != $1.onboard { return $0.onboard }   // the machine's own first: it's the fallback
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            return byName == .orderedSame ? $0.uid < $1.uid : byName == .orderedAscending
        }
    }

    func isPinned(_ uid: String, _ role: DeviceRole) -> Bool {
        pins.contains { $0.role == role && MenuDevice.sameUID($0.uid, uid) }
    }

    /// What the paired list says this device is, if it's Bluetooth and we've read the list (the menu
    /// refreshes it when it opens). Only drives the icon.
    private func bluetoothKind(_ uid: String) -> Bluetooth.Kind? {
        guard let address = Bluetooth.address(fromDeviceUID: uid) else { return nil }
        return pairedBluetooth.first { Bluetooth.sameAddress($0.address, address) }?.kind
    }

    /// A paired Bluetooth device as a row for the picker: not here yet (if it were, the section would
    /// already list it), so clicking it asks for it exactly like an absent pinned row.
    func row(for d: Bluetooth.Device, role: DeviceRole) -> MenuDevice {
        let uid = Bluetooth.deviceUID(address: d.address, input: role == .input)
        return MenuDevice(uid: uid, name: d.name, role: role, present: false,
                          isBluetooth: true, pinned: isPinned(uid, role), kind: d.kind)
    }

    /// The paired Bluetooth devices this section doesn't already list — what the picker offers to pin.
    /// A loudspeaker has no microphone, so the Input picker doesn't offer one.
    func pinnable(_ role: DeviceRole) -> [Bluetooth.Device] {
        let listed = menuRows(role).compactMap(\.address)
        return pairedBluetooth.filter { d in
            (role == .output || d.kind.mayHaveMicrophone)
                && !listed.contains { Bluetooth.sameAddress($0, d.address) }
        }
    }

    var statusLine: String {
        switch state {
        case .stopped:
            return "Stopped"
        case .degraded(let why):
            return "Not running — \(why)"
        case .running(let info):
            if let uid = info.effectiveGraph.hubOutputDeviceUIDs.first {
                return "Playing to \(outputs.first { $0.uid == uid }?.name ?? uid)"
            }
            if let want = desiredOutputLabel ?? desiredOutputUID {
                return "Muted — \(want) not connected"
            }
            return "Muted — no output selected"
        }
    }

    /// The engine state distilled to the four icon faces (see `PancakeIcon`).
    var iconState: PancakeIconState {
        switch state {
        case .running(let info):
            return info.effectiveGraph.hubOutputDeviceUIDs.isEmpty ? .muted : .nominal
        case .degraded:
            return .degraded
        case .stopped:
            return .stopped
        }
    }

    /// The hand-drawn pancake-stack template image for the menu bar.
    var statusImage: NSImage { PancakeIcon.image(for: iconState) }

    // MARK: Actions

    /// Click a device row. A device that's here becomes this section's device (clicking the current
    /// input again clears it); one that isn't here is a request to summon it — see `connect`.
    func select(_ item: MenuDevice) {
        guard item.present else { connect(item); return }
        switch item.role {
        case .output:
            guard let d = outputs.first(where: { $0.uid == item.uid }) else { return }
            selectOutput(d)
        case .input:
            if let current = desiredInputUID, MenuDevice.sameUID(item.uid, current) { clearInput(); return }
            guard let d = inputs.first(where: { $0.uid == item.uid }) else { return }
            selectInput(d)
        }
    }

    private func selectOutput(_ d: AudioDevice) {
        awaiting[.output] = nil   // an explicit choice supersedes whatever we were waiting for
        graph.setOutput(uid: d.uid, channels: min(2, max(1, d.outputChannels)), label: d.name)
        desiredOutputUID = d.uid
        desiredOutputLabel = d.name
        engine.apply(graph)
        save()
        Log.info("menu: output → \(d.name)")
    }

    /// Feed Pancake Mic from this input (what apps like Discord then record).
    private func selectInput(_ d: AudioDevice) {
        awaiting[.input] = nil
        graph.setInput(uid: d.uid, channels: min(2, max(1, d.inputChannels)), label: d.name)
        desiredInputUID = d.uid
        desiredInputLabel = d.name
        engine.apply(graph)
        save()
        Log.info("menu: input → \(d.name)")
    }

    func clearInput() {
        graph.clearInput()
        desiredInputUID = nil
        desiredInputLabel = nil
        engine.apply(graph)
        save()
        Log.info("menu: input cleared")
    }

    // MARK: Pinned devices, and summoning the ones that aren't here

    /// Keep this device in the menu, or stop. A pinned device is listed in its usual place even when
    /// it's off or a phone has it, and a Bluetooth one is then a button that fetches it back.
    func togglePin(_ item: MenuDevice) {
        guard !item.onboard else { return }   // built in; it's never absent, so a pin means nothing
        if isPinned(item.uid, item.role) {
            pins.removeAll { $0.role == item.role && MenuDevice.sameUID($0.uid, item.uid) }
            Log.info("menu: unpinned \(item.name) from \(item.role.rawValue)")
        } else {
            pins.append(PinnedDevice(uid: item.uid, name: item.name, role: item.role))
            Log.info("menu: pinned \(item.name) to \(item.role.rawValue)")
        }
        pinStore.save(pins)
    }

    /// Pin a paired Bluetooth device we may never have seen as an audio device — it's off, or a phone
    /// has it. Its UID is synthesised now and healed from the real device the first time it connects.
    func pin(_ d: Bluetooth.Device, role: DeviceRole) {
        let uid = Bluetooth.deviceUID(address: d.address, input: role == .input)
        guard !isPinned(uid, role) else { return }
        pins.append(PinnedDevice(uid: uid, name: d.name, role: role))
        pinStore.save(pins)
        Log.info("menu: pinned \(d.name) to \(role.rawValue) (paired Bluetooth)")
    }

    /// Re-read the paired Bluetooth devices (an IPC to bluetoothd, so not on the main thread).
    func refreshPairedBluetooth() {
        queue.async { [weak self] in
            let paired = Bluetooth.pairedAudioDevices()
            Task { @MainActor in if self?.pairedBluetooth != paired { self?.pairedBluetooth = paired } }
        }
    }

    /// Pairing something *new* is still System Settings' job — pancake connects what's already paired.
    func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Ask Bluetooth for a device that isn't here, and select it when it arrives: clicking a row in
    /// the Output list means "play here", even when "here" has to be summoned first. This is also how
    /// you take a device back from a phone that's holding it. Best effort — it may not come, in which
    /// case the row says so once the window is up.
    func connect(_ item: MenuDevice) {
        guard let address = item.address else { return }
        let key = address.lowercased()
        guard connectState[key] != .asking else { return }   // already on its way
        connectState[key] = .asking
        awaiting[item.role] = (address: address, deadline: Date().addingTimeInterval(Self.connectWindow))
        Log.info("menu: asking Bluetooth for \(item.name)")
        let role = item.role, name = item.name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure = Bluetooth.connect(address: address)
            Task { @MainActor in self?.connectReturned(key, role: role, name: name, failure: failure) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectWindow) { [weak self] in
            Task { @MainActor in self?.connectWindowClosed(key, role: role) }
        }
    }

    private func connectReturned(_ key: String, role: DeviceRole, name: String, failure: String?) {
        guard let failure else {
            // Connected as far as Bluetooth is concerned; the row clears when the HAL lists the device.
            Log.info("connect \(name): connected (waiting for the HAL to list it)")
            return
        }
        Log.warn("connect \(name): \(failure)")
        connectState[key] = .unreachable
        if let a = awaiting[role], Bluetooth.sameAddress(a.address, key) { awaiting[role] = nil }
    }

    /// The device never showed up. Stop claiming to be working on it, and stop meaning to select it.
    private func connectWindowClosed(_ key: String, role: DeviceRole) {
        if connectState[key] == .asking { connectState[key] = .unreachable }
        if let a = awaiting[role], Bluetooth.sameAddress(a.address, key), Date() >= a.deadline { awaiting[role] = nil }
    }

    /// After a device-list refresh: heal pinned rows from the live devices (a device pinned from the
    /// paired-Bluetooth list only learns its real UID and name when it first connects), drop the
    /// "connecting…" state for anything that showed up, and select a device we were waiting for.
    private func devicesSettled() {
        var healed = pins
        var changed = false
        for i in healed.indices {
            let list = healed[i].role == .output ? outputs : inputs
            guard let d = list.first(where: { MenuDevice.sameUID($0.uid, healed[i].uid) }),
                  healed[i].uid != d.uid || healed[i].name != d.name else { continue }
            Log.info("menu: pinned \(healed[i].name) is \(d.name) (\(d.uid))")
            healed[i].uid = d.uid
            healed[i].name = d.name
            changed = true
        }
        if changed { pins = healed; pinStore.save(pins) }

        let here = Set((outputs + inputs).compactMap { Bluetooth.address(fromDeviceUID: $0.uid)?.lowercased() })
        for key in connectState.keys where here.contains(key) { connectState[key] = nil }

        for (role, want) in awaiting {
            let list = role == .output ? outputs : inputs
            guard let d = list.first(where: { device in
                Bluetooth.address(fromDeviceUID: device.uid).map { Bluetooth.sameAddress($0, want.address) } ?? false
            }) else { continue }
            awaiting[role] = nil
            Log.info("menu: \(d.name) arrived; selecting it as the \(role.rawValue)")
            if role == .output { selectOutput(d) } else { selectInput(d) }
        }
    }

    // MARK: Stage (screen share)

    /// What the screen share carries — the nodes wired into Pancake Program — as friendly names.
    var programSourceNames: [String] {
        graph.programSourceNodeIDs.compactMap { id -> String? in
            guard let n = graph.node(id) else { return nil }
            switch n.kind {
            case .hub: return "Pancake"
            case .tap(let b): return n.label ?? tapCandidates.first { $0.bundleID == b }?.name ?? b
            default: return n.label ?? id.rawValue
            }
        }
    }

    /// Before the engine owned every tap, the Stage tapped the shared app itself, chosen through a
    /// separate `stage.json`. That file is now meaningless (the Stage just plays the Program bus);
    /// fold its choice into the graph as `tap → program` once, then delete it. Returns true if the
    /// graph changed.
    private static func migrateLegacyStageConfig(into g: inout Graph) -> Bool {
        let url = GraphStore.defaultURL.deletingLastPathComponent().appendingPathComponent("stage.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bundleID = obj["bundleID"] as? String, !bundleID.isEmpty else {
            Log.info("legacy stage.json had no app chosen; removed")
            return false
        }
        let tap = Node.tap(bundleID, label: g.node(Node.tap(bundleID).id)?.label
                           ?? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName)
        g.upsert(.program)
        if g.node(tap.id) == nil { g.upsert(tap) }
        if !g.links.contains(where: { $0.from.node == tap.id && $0.to.node == Graph.programID }) {
            g.connect(Port(tap.id, 0), Port(Graph.programID, 0))
            g.connect(Port(tap.id, 1), Port(Graph.programID, 1))
        }
        Log.info("migrated legacy stage.json: \(bundleID) → Pancake Program is now a graph wire; file removed")
        return true
    }

    func startStage() {
        refreshStage()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.stageBundleID) else {
            Log.warn("stage app not found by bundle id \(Self.stageBundleID); run it once (make run-stage) so LaunchServices registers it")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            if let err { Log.warn("launch stage: \(err.localizedDescription)") }
        }
        Log.info("menu: starting screen share")
    }

    func stopStage() {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == Self.stageBundleID {
            app.terminate()
        }
        Log.info("menu: stopping screen share")
    }

    /// Re-read who's running and which apps are tappable (call when the menu opens).
    func refreshStage() { refreshStageState() }

    private func observeStageLifecycle() {
        refreshStageState()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let obs = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshStageState() }
            }
            workspaceObservers.append(obs)
        }
    }

    private func refreshStageState() {
        stageRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.stageBundleID }
        refreshTapCandidates()
    }

    /// Re-list tappable apps on `queue` (it reads every HAL process object) and publish the result.
    private func refreshTapCandidates() {
        let hal = self.hal
        queue.async { [weak self] in
            if hal.appsBusy { hal.appsAgain = true; return }
            hal.appsBusy = true
            repeat {
                hal.appsAgain = false
                let apps = tappableApps()
                Task { @MainActor in if self?.tapCandidates != apps { self?.tapCandidates = apps } }
            } while hal.appsAgain
            hal.appsBusy = false
        }
    }

    // MARK: Launch at login

    func refreshLaunchAtLogin() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.warn("launch at login toggle failed: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
        Log.info("menu: launch at login \(launchAtLogin ? "on" : "off")")
    }

    func toggleOutputLock() {
        graph.policy.lockOutput.toggle()
        lockOutput = graph.policy.lockOutput
        engine.apply(graph)
        save()
        Log.info("menu: output lock \(lockOutput ? "on" : "off")")
    }

    func toggleInputLock() {
        graph.policy.lockInput.toggle()
        lockInput = graph.policy.lockInput
        engine.apply(graph)
        save()
        Log.info("menu: input lock \(lockInput ? "on" : "off")")
    }

    /// Drive Pancake's own output volume (what the volume keys move). The UI updates at once; the HAL
    /// write happens on `queue`, latest value wins.
    func setHubVolume(_ v: Double) {
        hubVolume = v
        let hal = self.hal, hubUID = engine.configuration.hubUID, queue = self.queue
        queue.async {
            let writerQueued = hal.pendingVolume != nil
            hal.pendingVolume = Float32(v)
            guard !writerQueued else { return }   // the queued writer will pick up this newer value
            queue.async {
                guard let value = hal.pendingVolume else { return }
                hal.pendingVolume = nil
                try? AudioDevice.find(uid: hubUID)?.setOutputVolumeScalar(value)
            }
        }
    }

    func toggleMute() {
        let newMuted = !hubMuted
        hubMuted = newMuted
        let hubUID = engine.configuration.hubUID
        queue.async { try? AudioDevice.find(uid: hubUID)?.setOutputMuted(newMuted) }
    }

    private func save() {
        do { try store.save(graph) } catch { Log.warn("save graph: \(error)") }
    }

    func rebuildRouting() {
        Log.info("menu: rebuild requested")
        engine.rebuildNow()
    }

    // MARK: Visual graph editor

    /// A present device by UID, output or input — used by the editor for channel counts and presence.
    func device(forUID uid: String) -> AudioDevice? {
        outputs.first { $0.uid == uid } ?? inputs.first { $0.uid == uid }
    }

    /// The graph the engine is actually running right now (absent devices/dead taps dropped). The
    /// editor compares against it to show which links are live.
    var effectiveGraph: Graph? {
        if case .running(let info) = state { return info.effectiveGraph }
        return nil
    }

    /// Apply an edited graph everywhere at once: publish it, re-derive the menu's mirrored state,
    /// hand it to the engine (which debounces and hot-swaps gain-only changes), and persist it. The
    /// save is debounced so a gain-slider drag — dozens of edits a second — doesn't hammer the disk;
    /// the engine still gets every edit live, and `graph` is already current for the watcher's guard.
    private func applyEditedGraph(_ g: Graph) {
        graph = g
        syncFromGraph()
        engine.apply(g)
        scheduleGraphSave()
    }

    private var graphSaveWork: DispatchWorkItem?
    private func scheduleGraphSave() {
        graphSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        graphSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The fixed buses may not be named in the graph yet; make sure an endpoint exists before wiring it.
    private func ensureNode(_ g: inout Graph, _ id: NodeID) {
        guard g.node(id) == nil else { return }
        if id == Graph.hubID { g.upsert(.hub) }
        else if id == Graph.micID { g.upsert(.mic) }
        else if id == Graph.programID { g.upsert(.program) }
        // Every other node is added through the palette with a label, so it already exists.
    }

    /// Wire one bus between two nodes: replace every existing link between the pair with the given
    /// channel pairs (L/R is fungible — the editor decides the mapping). One apply, so the engine
    /// rebuilds at most once.
    func wireBus(from: NodeID, to: NodeID, pairs: [(Int, Int)]) {
        var g = graph
        ensureNode(&g, from)
        ensureNode(&g, to)
        g.links.removeAll { $0.from.node == from && $0.to.node == to }
        for p in pairs { g.links.append(Link(from: Port(from, p.0), to: Port(to, p.1))) }
        applyEditedGraph(g)
        Log.info("editor: wire \(from) → \(to) (\(pairs.count) ch)")
    }

    /// Remove the whole bus between two nodes. Deliberately does *not* prune the now-orphan nodes —
    /// disconnecting leaves them on the canvas (pipewire-style); deleting a node is a separate action.
    func disconnectBus(from: NodeID, to: NodeID) {
        var g = graph
        g.links.removeAll { $0.from.node == from && $0.to.node == to }
        applyEditedGraph(g)
        Log.info("editor: disconnect bus \(from) → \(to)")
    }

    /// Set the gain on every channel link of a bus (they share one gain in the editor). Gain-only, so
    /// the engine hot-swaps the matrix with no rebuild.
    func setBusGain(from: NodeID, to: NodeID, gain: Float) {
        var g = graph
        var changed = false
        for i in g.links.indices where g.links[i].from.node == from && g.links[i].to.node == to {
            g.links[i].gain = gain
            changed = true
        }
        if changed { applyEditedGraph(g) }
    }

    func addOutputNode(_ d: AudioDevice) { addNode(.output(d.uid, label: d.name)) }
    func addInputNode(_ d: AudioDevice) { addNode(.input(d.uid, label: d.name)) }
    func addTapNode(_ a: TappableApp) { addNode(.tap(a.bundleID, label: a.name)) }
    func addRecorderNode() { addNode(.recorder()) }
    func addBusNode() {
        let n = graph.nodes.filter { if case .bus = $0.kind { return true } else { return false } }.count + 1
        addNode(.bus(label: "Bus \(n)"))
    }

    // MARK: Buses

    /// Set a bus's processing (compressor, trim). Not topology, so the engine hot-swaps the matrix.
    func setBusParams(_ id: NodeID, _ p: BusParams) {
        var g = graph
        guard g.node(id) != nil, g.busParams(id) != p else { return }
        g.setBusParams(id, p)
        applyEditedGraph(g)
    }

    /// Live meter for a bus node: compressor gain reduction (dB, ≤ 0) and post-processing peak.
    func busMeter(_ id: NodeID) -> (gainReduction: Float, peak: Float) { engine.busMeter(id) }

    // MARK: Recording (a .recorder node captures whatever's wired into it to a file)

    func startRecording(_ node: NodeID, to url: URL) {
        do { try engine.startRecording(node: node, to: url) }
        catch { Log.warn("start recording \(node): \(error)") }
    }
    func stopRecording(_ node: NodeID) { engine.stopRecording(node) }
    func isRecording(_ node: NodeID) -> Bool { engine.isRecording(node) }
    func recordingElapsed(_ node: NodeID) -> Double? { engine.recordingElapsed(node) }

    /// Reveal the recordings folder in Finder (creating it if it doesn't exist yet).
    func showRecordingsFolder() {
        let folder = RecordingLocation.defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func addNode(_ node: Node) {
        var g = graph
        g.upsert(node)
        applyEditedGraph(g)
        Log.info("editor: add node \(node.id)")
    }

    func removeNode(_ id: NodeID) {
        guard id != Graph.hubID else { return }
        var g = graph
        g.remove(id)
        applyEditedGraph(g)
        Log.info("editor: remove node \(id)")
    }

    func openLog() {
        NSWorkspace.shared.open(Log.defaultFileURL)
    }

    /// Stop the engine (tear down the aggregate, hand the default output back). Blocks until the engine
    /// is done — which can be forever if coreaudiod isn't answering, so the app delegate runs this off the
    /// main thread with a deadline. Returned as a closure so it can be called from any thread.
    func shutdownWork() -> () -> Void {
        Log.info("pancake app quitting")
        let engine = self.engine
        return { engine.stop() }
    }

    // MARK: Reacting to the world

    /// Re-read the device lists and re-arm the Pancake volume listeners, on `queue`, and publish the
    /// result. Coalesced: a burst of devices-changed events runs it at most once more.
    private func refreshDevices() {
        let hal = self.hal, hubUID = engine.configuration.hubUID, queue = self.queue
        queue.async { [weak self] in
            if hal.devicesBusy { hal.devicesAgain = true; return }
            hal.devicesBusy = true
            repeat {
                hal.devicesAgain = false
                let all = AudioDevice.all()
                let outs = all.filter { $0.hasOutput && !$0.isSoftware }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                let ins = all.filter { $0.hasInput && !$0.isSoftware }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                let volume = Self.installHubVolumeListeners(hal: hal, hubUID: hubUID, queue: queue) { v, m in
                    Task { @MainActor in self?.applyHubVolume(v, muted: m) }
                }
                Task { @MainActor in
                    guard let self else { return }
                    if self.outputs != outs { self.outputs = outs }
                    if self.inputs != ins { self.inputs = ins }
                    if let volume { self.applyHubVolume(volume.0, muted: volume.1) }
                    self.devicesSettled()
                }
            } while hal.devicesAgain
            hal.devicesBusy = false
        }
    }

    private func graphFileChanged(_ g: Graph) {
        guard g != graph else { return }   // our own save coming back around
        Log.info("graph file changed on disk; applying")
        graph = g
        syncFromGraph()
        engine.apply(g)
    }

    /// Mirror the graph's selections and locks into the published UI state.
    private func syncFromGraph() {
        desiredOutputUID = graph.hubOutputDeviceUIDs.first
        desiredOutputLabel = graph.nodes.first { $0.kind.deviceUID == desiredOutputUID }?.label
        desiredInputUID = graph.micInputDeviceUIDs.first
        desiredInputLabel = graph.nodes.first { $0.kind.deviceUID == desiredInputUID }?.label
        lockOutput = graph.policy.lockOutput
        lockInput = graph.policy.lockInput
    }

    // MARK: Pancake volume, tracked live so the slider follows the volume keys

    /// On `queue`: re-arm listeners on Pancake's volume/mute (they fire on `queue` and read there) and
    /// return the current (volume, muted). `publish` delivers later changes.
    private nonisolated static func installHubVolumeListeners(hal: HALWork, hubUID: String, queue: DispatchQueue,
                                                              publish: @escaping (Float32?, Bool) -> Void) -> (Float32?, Bool)? {
        hal.hubVolumeListeners.forEach { $0.remove() }
        hal.hubVolumeListeners = []
        guard let hub = AudioDevice.find(uid: hubUID) else { return nil }
        let hubID = hub.id
        var addresses = hub.outputVolumes().keys.sorted().map {
            AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: $0)
        }
        addresses.append(AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: kAudioObjectPropertyElementMain))
        for address in addresses {
            if let l = try? hubID.addPropertyListener(address, queue: queue, handler: {
                guard let dev = try? AudioDevice(id: hubID) else { return }
                publish(dev.outputVolumeScalar, dev.outputMuted ?? false)
            }) {
                hal.hubVolumeListeners.append(l)
            }
        }
        return (hub.outputVolumeScalar, hub.outputMuted ?? false)
    }

    private func applyHubVolume(_ v: Float32?, muted: Bool) {
        if let v, abs(Double(v) - hubVolume) > 0.001 { hubVolume = Double(v) }
        if hubMuted != muted { hubMuted = muted }
    }
}
