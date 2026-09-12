import AppKit
import AVFoundation
import CoreAudio
import Foundation
import PancakeCore
import ServiceManagement


/// One row in the output list: a present device, or the device the graph wants that isn't here.
struct MenuOutput: Identifiable, Hashable {
    let uid: String
    let name: String
    let present: Bool
    let isBluetooth: Bool
    /// Battery percentages to show under a Bluetooth row (left, right, case), when known.
    var battery: [Int] = []
    var id: String { uid }
}

/// One row in the input list: a physical input device that can feed Pancake Mic.
struct MenuInput: Identifiable, Hashable {
    let uid: String
    let name: String
    let present: Bool
    let isBluetooth: Bool
    var id: String { uid }
}

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

    // Pancake Stage (clean Discord screen-share) — driven via the stage.json IPC. The Stage process
    // watches the same file and obeys; this is just a second thin view over it.
    @Published private(set) var stageConfig = StageConfig()
    @Published private(set) var stageRunning = false
    @Published private(set) var stageApps: [TappableApp] = []
    static let stageBundleID = "com.pancake.stage"

    /// Whether the app is registered to launch at login (SMAppService).
    @Published private(set) var launchAtLogin = false

    private let store = GraphStore()
    /// The desired routing graph. Published so the visual editor re-renders when it changes —
    /// whether the change came from the menu, the editor itself, the CLI, or a hand-edit of the file.
    @Published private(set) var graph: Graph
    private let engine: Engine
    private let queue = DispatchQueue(label: "com.pancake.app")
    private var monitor: HardwareMonitor?
    private var watcher: FileWatcher?
    private let stageStore = StageStore()
    private var stageWatcher: FileWatcher?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Listeners on Pancake's volume/mute so the slider tracks the hardware keys live.
    private var hubVolumeListeners: [PropertyListener] = []

    private init() {
        Log.logToFile()
        Log.minimumLevel = .debug   // bring-up: the watchdog's health lines are the evidence we need
        Log.info("pancake app starting (pid \(ProcessInfo.processInfo.processIdentifier))")

        let loaded = (try? store.load()) ?? Graph()
        graph = loaded
        engine = Engine(graph: loaded)

        engine.onStateChange = { [weak self] s in
            Task { @MainActor in self?.state = s }
        }
        syncFromGraph()
        refreshDevices()

        monitor = try? HardwareMonitor(queue: queue) { [weak self] event in
            guard event == .devicesChanged else { return }
            Task { @MainActor in self?.refreshDevices() }
        }

        let store = self.store
        watcher = store.watch(queue: queue) { [weak self] in
            guard let g = try? store.load() else { return }
            Task { @MainActor in self?.graphFileChanged(g) }
        }

        stageConfig = (try? stageStore.load()) ?? StageConfig()
        let stageStore = self.stageStore
        stageWatcher = stageStore.watch(queue: queue) { [weak self] in
            guard let cfg = try? stageStore.load() else { return }
            Task { @MainActor in self?.stageConfigFileChanged(cfg) }
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

    var menuOutputs: [MenuOutput] {
        var rows = outputs.map { MenuOutput(uid: $0.uid, name: $0.name, present: true, isBluetooth: $0.transport.isBluetooth) }
        if let want = desiredOutputUID, !rows.contains(where: { $0.uid == want }) {
            rows.append(MenuOutput(uid: want, name: desiredOutputLabel ?? want, present: false,
                                   isBluetooth: BluetoothReconnector.address(fromDeviceUID: want) != nil))
        }
        return rows
    }

    var absentBluetoothDesired: MenuOutput? {
        menuOutputs.first { !$0.present && $0.isBluetooth }
    }

    var menuInputs: [MenuInput] {
        var rows = inputs.map { MenuInput(uid: $0.uid, name: $0.name, present: true, isBluetooth: $0.transport.isBluetooth) }
        if let want = desiredInputUID, !rows.contains(where: { $0.uid == want }) {
            rows.append(MenuInput(uid: want, name: desiredInputLabel ?? want, present: false,
                                  isBluetooth: BluetoothReconnector.address(fromDeviceUID: want) != nil))
        }
        return rows
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

    func select(_ item: MenuOutput) {
        guard item.present, let d = outputs.first(where: { $0.uid == item.uid }) else {
            // The device the graph already wants, but it isn't here: the only useful thing is to ask for it.
            reconnect()
            return
        }
        graph.setOutput(uid: d.uid, channels: min(2, max(1, d.outputChannels)), label: d.name)
        desiredOutputUID = d.uid
        desiredOutputLabel = d.name
        engine.apply(graph)
        save()
        Log.info("menu: output → \(d.name)")
    }

    /// Select an input to feed Pancake Mic; tapping the current one again clears it.
    func selectInput(_ item: MenuInput) {
        if item.uid == desiredInputUID { clearInput(); return }
        guard item.present, let d = inputs.first(where: { $0.uid == item.uid }) else { return }
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

    // MARK: Stage (screen share)

    /// The app the Stage is set to render, as a friendly name (for the menu label).
    var stageAppName: String? {
        guard let bid = stageConfig.bundleID else { return nil }
        return stageApps.first { $0.bundleID == bid }?.name ?? bid
    }

    func setStageApp(_ bundleID: String?) {
        stageConfig.bundleID = bundleID
        saveStage()
        Log.info("menu: stage app → \(bundleID ?? "none")")
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

    private func saveStage() {
        do { try stageStore.save(stageConfig) } catch { Log.warn("save stage config: \(error)") }
    }

    private func stageConfigFileChanged(_ cfg: StageConfig) {
        guard cfg != stageConfig else { return }   // our own save coming back around
        stageConfig = cfg
    }

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
        stageApps = tappableApps()
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

    /// Drive Pancake's own output volume (what the volume keys move).
    func setHubVolume(_ v: Double) {
        hubVolume = v
        try? AudioDevice.find(uid: engine.configuration.hubUID)?.setOutputVolumeScalar(Float32(v))
    }

    func toggleMute() {
        guard let hub = AudioDevice.find(uid: engine.configuration.hubUID) else { return }
        let newMuted = !(hub.outputMuted ?? false)
        try? hub.setOutputMuted(newMuted)
        hubMuted = newMuted
    }

    private func save() {
        do { try store.save(graph) } catch { Log.warn("save graph: \(error)") }
    }

    func reconnect() {
        engine.reconnectDesiredOutputIfBluetooth()
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

    /// The two fixed buses may not be named in the graph yet; make sure an endpoint exists before wiring it.
    private func ensureNode(_ g: inout Graph, _ id: NodeID) {
        guard g.node(id) == nil else { return }
        if id == Graph.hubID { g.upsert(.hub) }
        else if id == Graph.micID { g.upsert(.mic) }
        // Device and tap nodes are added through the palette before they can be wired, so they exist.
    }

    func connect(from: Port, to: Port) {
        var g = graph
        ensureNode(&g, from.node)
        ensureNode(&g, to.node)
        g.connect(from, to)
        applyEditedGraph(g)
        Log.info("editor: connect \(from) → \(to)")
    }

    /// Remove one link. Deliberately does *not* prune the now-possibly-orphan node — disconnecting a
    /// wire leaves the node on the canvas (pipewire-style); deleting a node is a separate action.
    func disconnect(from: Port, to: Port) {
        var g = graph
        g.links.removeAll { $0.from == from && $0.to == to }
        applyEditedGraph(g)
        Log.info("editor: disconnect \(from) → \(to)")
    }

    func setGain(from: Port, to: Port, gain: Float) {
        var g = graph
        guard let i = g.links.firstIndex(where: { $0.from == from && $0.to == to }) else { return }
        g.links[i].gain = gain
        applyEditedGraph(g)
    }

    func addOutputNode(_ d: AudioDevice) { addNode(.output(d.uid, label: d.name)) }
    func addInputNode(_ d: AudioDevice) { addNode(.input(d.uid, label: d.name)) }
    func addTapNode(_ a: TappableApp) { addNode(.tap(a.bundleID, label: a.name)) }

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

    func shutdown() {
        Log.info("pancake app quitting")
        engine.stop()
    }

    // MARK: Reacting to the world

    private func refreshDevices() {
        let all = AudioDevice.all()
        outputs = all.filter { $0.hasOutput && !$0.isSoftware }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        inputs = all.filter { $0.hasInput && !$0.isSoftware }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        installHubVolumeListeners()
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

    private func installHubVolumeListeners() {
        hubVolumeListeners.forEach { $0.remove() }
        hubVolumeListeners = []
        guard let hub = AudioDevice.find(uid: engine.configuration.hubUID) else { return }
        refreshVolume(from: hub)
        let hubID = hub.id
        var addresses = hub.outputVolumes().keys.sorted().map {
            AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: $0)
        }
        addresses.append(AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: kAudioObjectPropertyElementMain))
        for address in addresses {
            if let l = try? hubID.addPropertyListener(address, queue: queue, handler: { [weak self] in
                guard let dev = try? AudioDevice(id: hubID) else { return }
                Task { @MainActor in self?.refreshVolume(from: dev) }
            }) {
                hubVolumeListeners.append(l)
            }
        }
    }

    private func refreshVolume(from hub: AudioDevice) {
        if let v = hub.outputVolumeScalar, abs(Double(v) - hubVolume) > 0.001 { hubVolume = Double(v) }
        hubMuted = hub.outputMuted ?? false
    }
}
