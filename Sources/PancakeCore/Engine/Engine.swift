import CoreAudio
import CPancakeRT
import Foundation

/// The routing engine.
///
/// Owns one private aggregate device built from every device the graph touches, one IOProc
/// on it, and the routing matrix that IOProc applies. Everything that mutates engine state
/// runs on `queue` — HAL callbacks, graph updates, rebuilds, all of it — so there is exactly
/// one place hot-plug races could live, and it's serialized.
///
/// Lifecycle of a rebuild (the only way topology changes):
///   teardown → snapshot devices → derive effective graph → create aggregate → resolve
///   layout → compile matrix → install IOProc → start → pin default output.
///
/// Gain-only changes skip all that and atomically swap the matrix under the running IOProc.
public final class Engine {
    public struct Configuration {
        /// UID of the virtual device apps play into. The engine reads it.
        public var hubUID = "Pancake_UID"
        /// UID of the virtual device apps record from. The engine writes it.
        public var micUID = "PancakeMic_UID"
        /// Keep the system default output (and system-sounds output) on the hub.
        public var pinDefaultOutput = true
        /// When the default output moves to a *physical* device (the user picked one in Control
        /// Center, or macOS auto-switched on AirPods connect), route the hub there and re-pin.
        /// This turns the native output picker into pancake's picker for free.
        public var followDefaultOutput = true
        /// Where the hub goes when nothing it's linked to is present, tried in order. Empty
        /// (the default) means *mute*: nobody wants their AirPods walking off to mean the
        /// library hears their speakers.
        public var fallbackOutputUIDs: [String] = []
        /// When the desired output is an absent Bluetooth device and the hub is carrying
        /// signal, ask macOS to reconnect it — at most this often.
        public var bluetoothReconnectInterval: TimeInterval? = 8
        /// Peak level on the hub that counts as "something is playing".
        public var signalThreshold: Float = 0.001
        /// HAL events arrive in bursts; coalesce them.
        public var rebuildDebounce: TimeInterval = 0.35
        /// A Bluetooth device that has just appeared needs a moment before its audio link is
        /// usable; building an aggregate on it too early has left it running-but-silent.
        public var bluetoothSettleDelay: TimeInterval = 2.5
        /// How often the watchdog checks that IO is actually cycling and logs a health line.
        public var watchdogInterval: TimeInterval = 5
        /// Sample rate to run the aggregate at, or nil to adopt the main sub-device's rate.
        public var sampleRate: Double? = nil
        /// Hold the hardware volume of the device the hub is routed to at unity while it's routed
        /// there, so what you hear is exactly Pancake's own volume — the one the keys drive — and
        /// nothing outside (the phone rewriting the AirPods' level) can quietly change it. The
        /// previous value comes back when the device stops being the output; on quit the device is
        /// left at Pancake's level so the audible volume doesn't jump. DESIGN.md § Gain.
        public var holdOutputVolumeAtUnity = true
        /// Name of the private aggregate, for Audio MIDI Setup / bug reports.
        public var aggregateName = "pancake engine"
        public var aggregateUID = "com.pancake.engine.aggregate"

        public init() {}
    }

    public struct RunInfo: CustomStringConvertible {
        public let aggregateID: AudioObjectID
        public let mainSubDeviceUID: String
        public let subDeviceUIDs: [String]
        public let sampleRate: Double
        public let routes: [MatrixCompiler.Route]
        public let layout: ChannelLayout
        public let effectiveGraph: Graph
        public var description: String {
            "aggregate \(aggregateID) @\(Int(sampleRate))Hz main=\(mainSubDeviceUID) subs=\(subDeviceUIDs) routes=\(routes.count)"
        }
    }

    public enum State: CustomStringConvertible {
        case stopped
        case running(RunInfo)
        /// Couldn't build — usually the hub device is missing. Retries on the next HAL event.
        case degraded(String)

        public var description: String {
            switch self {
            case .stopped: return "stopped"
            case .running(let info): return "running: \(info)"
            case .degraded(let why): return "degraded: \(why)"
            }
        }
    }

    // MARK: Public surface

    public private(set) var configuration: Configuration
    /// Fires on `queue`. Hook it to update a UI or print a line.
    public var onStateChange: ((State) -> Void)?

    public init(graph: Graph, configuration: Configuration = Configuration()) {
        self.desiredGraph = graph
        self.configuration = configuration
        self.rt = pk_context_create()!
    }

    deinit {
        stop()
        pk_context_destroy(rt)
    }

    /// Starts watching the HAL and builds the aggregate. Idempotent.
    public func start() {
        queue.async { [self] in
            guard monitor == nil else { return }
            do {
                monitor = try HardwareMonitor(queue: queue) { [weak self] event in self?.handle(event) }
            } catch {
                Log.error("hardware monitor: \(error)")
            }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.attemptBluetoothReconnect(force: false) }
            t.resume()
            signalTimer = t
            let w = DispatchSource.makeTimerSource(queue: queue)
            w.schedule(deadline: .now() + configuration.watchdogInterval, repeating: configuration.watchdogInterval)
            w.setEventHandler { [weak self] in self?.watchdogTick() }
            w.resume()
            watchdog = w
            rebuild()
        }
    }

    /// Tears everything down and stops watching. Safe to call from any thread, blocks until done.
    /// If we had pinned the default output to the hub, hand it back to the device the hub was
    /// feeding, so stopping pancake never leaves the system on a silent virtual device.
    public func stop() {
        queue.sync { [self] in
            pendingRebuild?.cancel()
            pendingRebuild = nil
            signalTimer?.cancel()
            signalTimer = nil
            watchdog?.cancel()
            watchdog = nil
            monitor?.stop()
            monitor = nil
            let wasFeeding: String? = { if case .running(let info) = currentState { return info.effectiveGraph.hubOutputDeviceUIDs.first } else { return nil } }()
            let hubLevel = AudioDevice.find(uid: configuration.hubUID)?.outputVolumes()[0]
            teardown()
            destroyAllTaps()
            releaseAllVolumeHolds(leavingAt: hubLevel)
            unpinDefaultOutput(to: wasFeeding)
            setState(.stopped)
        }
    }

    /// The desired output is what the graph says; if it's a Bluetooth device that isn't
    /// present and audio is playing into the hub (or `force`), ask macOS to bring it back.
    private func attemptBluetoothReconnect(force: Bool) {
        guard case .running(let info) = currentState,
              let wantUID = desiredGraph.hubOutputDeviceUIDs.first,
              info.effectiveGraph.hubOutputDeviceUIDs.first != wantUID,
              let address = BluetoothReconnector.address(fromDeviceUID: wantUID),
              !reconnectInFlight else { return }
        if !force {
            guard let interval = configuration.bluetoothReconnectInterval,
                  Date().timeIntervalSince(lastReconnectAttempt) >= interval else { return }
            let peak = layout?.inputs[configuration.hubUID]?.first.map { pk_context_input_peak(rt, UInt32($0.buffer)) } ?? 0
            guard peak >= configuration.signalThreshold else { return }
            Log.info("audio is playing and \(wantUID) is away; asking Bluetooth to reconnect")
        } else {
            Log.info("reconnect requested for \(wantUID)")
        }
        lastReconnectAttempt = Date()
        reconnectInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let failure = BluetoothReconnector.connect(address: address)
            self?.queue.async {
                self?.reconnectInFlight = false
                if let failure { Log.warn("bluetooth reconnect \(address): \(failure)") }
                else { Log.info("bluetooth reconnect \(address): connected (waiting for the HAL to list it)") }
            }
        }
    }

    private func unpinDefaultOutput(to uid: String?) {
        guard configuration.pinDefaultOutput,
              let hubID = AudioDevice.id(forUID: configuration.hubUID),
              AudioDevice.defaultOutputID == hubID || AudioDevice.defaultSystemOutputID == hubID else { return }
        let candidates = [uid].compactMap { $0 } + configuration.fallbackOutputUIDs
        guard let target = candidates.lazy.compactMap({ AudioDevice.find(uid: $0) }).first(where: { $0.hasOutput }) else {
            Log.warn("stopping with default output still on the hub: no physical output to hand back to")
            return
        }
        do {
            try AudioDevice.setDefaultOutput(target.id)
            try AudioDevice.setDefaultSystemOutput(target.id)
            Log.info("handed default output back to \(target.name)")
        } catch {
            Log.warn("hand back default output: \(error)")
        }
    }

    /// The graph as the user wants it (may reference absent devices).
    public var graph: Graph { queue.sync { desiredGraph } }

    /// Replace the desired graph. Topology changes rebuild; gain-only changes hot-swap the matrix.
    public func apply(_ graph: Graph) {
        queue.async { [self] in
            let topologyChanged = !desiredGraph.hasSameTopology(as: graph)
            desiredGraph = graph
            if topologyChanged || !isRunning {
                scheduleRebuild(reason: "graph changed")
            } else {
                recompileMatrix(reason: "gains changed")
            }
        }
    }

    /// Fast path: "select output device".
    public func selectOutput(uid: String, label: String? = nil) {
        queue.async { [self] in
            var g = desiredGraph
            g.setOutput(uid: uid, label: label)
            desiredGraph = g
            scheduleRebuild(reason: "select output \(label ?? uid)")
        }
    }

    public var state: State { queue.sync { currentState } }

    /// Peak level on the hub's first input channel during the last IO cycle (0…1).
    public func hubInputPeak() -> Float {
        queue.sync {
            guard let b = layout?.inputs[configuration.hubUID]?.first?.buffer else { return 0 }
            return pk_context_input_peak(rt, UInt32(b))
        }
    }

    /// Ask macOS to reconnect the desired output right now, if it's an absent Bluetooth device.
    public func reconnectDesiredOutputIfBluetooth() {
        queue.async { [self] in attemptBluetoothReconnect(force: true) }
    }

    /// Tear the aggregate down and build it again, even if nothing changed. The escape hatch.
    public func rebuildNow() {
        queue.async { [self] in
            pendingRebuild?.cancel()
            pendingRebuild = nil
            Log.info("rebuild: forced")
            rebuild(force: true)
        }
    }

    public func stats() -> pk_stats {
        var s = pk_stats()
        pk_context_get_stats(rt, &s)
        return s
    }

    // MARK: - Internals (queue only)

    private let queue = DispatchQueue(label: "com.pancake.engine", qos: .userInitiated)
    private let rt: OpaquePointer
    private var desiredGraph: Graph
    private var currentState: State = .stopped
    private var monitor: HardwareMonitor?
    private var pendingRebuild: DispatchWorkItem?

    private var aggregate: AggregateDevice?
    /// UIDs of every device (except our own aggregate) as of the last rebuild. Our own
    /// create/destroy fires kAudioHardwarePropertyDevices too — without this we'd rebuild forever.
    private var knownDeviceUIDs: Set<String> = []
    private var ioProcID: AudioDeviceIOProcID?
    private var layout: ChannelLayout?
    private var retired: [(matrix: UnsafeMutablePointer<pk_matrix>, cycles: UInt64)] = []
    private var signalTimer: DispatchSourceTimer?
    private var lastReconnectAttempt: Date = .distantPast
    private var reconnectInFlight = false
    private var currentComposition: AggregateComposition?
    private var watchdog: DispatchSourceTimer?
    private var watchdogLastCycles: UInt64 = 0
    private var watchdogStalls = 0
    private var overloadListener: PropertyListener?
    /// Live process taps, keyed by bundle id. Created/destroyed on rebuild; reused across them.
    private var taps: [String: ProcessTap] = [:]
    /// Physical outputs whose hardware volume is held at unity: what to put back, and the
    /// listeners that re-assert unity if anything else writes it meanwhile.
    private var heldVolumes: [String: HeldVolume] = [:]
    private struct HeldVolume {
        let deviceID: AudioObjectID
        let name: String
        let saved: [UInt32: Float32]
        var listeners: [PropertyListener]
    }

    private var isRunning: Bool { if case .running = currentState { return true } else { return false } }

    private func setState(_ s: State) {
        currentState = s
        onStateChange?(s)
    }

    private func scheduleRebuild(reason: String, delay: TimeInterval? = nil) {
        pendingRebuild?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRebuild = nil
            Log.info("rebuild: \(reason)")
            self.rebuild()
        }
        pendingRebuild = item
        queue.asyncAfter(deadline: .now() + (delay ?? configuration.rebuildDebounce), execute: item)
    }

    // MARK: HAL events

    private func handle(_ event: HardwareMonitor.Event) {
        Log.debug("hal: \(event)")
        switch event {
        case .devicesChanged:
            let devices = AudioDevice.all(includeHidden: true)
            let now = relevantDeviceUIDs(devices)
            if now == knownDeviceUIDs, isRunning {
                Log.debug("devices changed: same set, ignoring")
            } else {
                let added = now.subtracting(knownDeviceUIDs), removed = knownDeviceUIDs.subtracting(now)
                let bluetoothArrived = devices.contains { added.contains($0.uid) && $0.transport.isBluetooth }
                scheduleRebuild(reason: "devices changed (+\(added.sorted()) -\(removed.sorted()))",
                                delay: bluetoothArrived ? configuration.bluetoothSettleDelay : nil)
            }

        case .defaultOutputChanged:
            guard let newID = AudioDevice.defaultOutputID, let dev = try? AudioDevice(id: newID) else { return }
            if dev.uid == configuration.hubUID { return }
            if configuration.followDefaultOutput, !desiredGraph.policy.lockOutput, !dev.isSoftware, dev.hasOutput,
               desiredGraph.hubOutputDeviceUIDs.first != dev.uid {   // locked = don't auto-adopt; else already where we're routing
                Log.info("default output moved to \(dev.name); routing hub there")
                var g = desiredGraph
                g.setOutput(uid: dev.uid, channels: min(2, max(1, dev.outputChannels)), label: dev.name)
                desiredGraph = g
                scheduleRebuild(reason: "follow default output → \(dev.name)")
            }
            if configuration.pinDefaultOutput { pinDefaultOutput() }

        case .defaultSystemOutputChanged:
            if configuration.pinDefaultOutput { pinDefaultOutput() }

        case .defaultInputChanged:
            if desiredGraph.policy.lockInput { reconcileInputPin() }
        }
    }

    /// Every device UID the HAL lists, minus aggregates we (or Pancake Stage) created — their
    /// create/destroy fires kAudioHardwarePropertyDevices at us, and rebuilding on it would loop
    /// (ours) or blip audio whenever Stage starts/stops (its).
    private func relevantDeviceUIDs(_ devices: [AudioDevice]? = nil) -> Set<String> {
        Set((devices ?? AudioDevice.all(includeHidden: true)).map(\.uid))
            .subtracting([configuration.aggregateUID, "com.pancake.stage.aggregate"])
    }

    private func pinDefaultOutput() {
        guard let hubID = AudioDevice.id(forUID: configuration.hubUID) else { return }
        if AudioDevice.defaultOutputID != hubID {
            do { try AudioDevice.setDefaultOutput(hubID); Log.info("pinned default output to hub") }
            catch { Log.warn("pin default output: \(error)") }
        }
        if AudioDevice.defaultSystemOutputID != hubID {
            do { try AudioDevice.setDefaultSystemOutput(hubID) }
            catch { Log.warn("pin default system output: \(error)") }
        }
    }

    /// After any (re)build or matrix swap, re-establish the engine's holds on the world: pin the
    /// system default output to the hub, hold the routed output device's volume at unity, and —
    /// when the input section is locked — pin the system default input to the device feeding the mic.
    private func settle(routedUIDs: [String], devices: [AudioDevice]) {
        if configuration.pinDefaultOutput { pinDefaultOutput() }
        reconcileVolumeHolds(routedUIDs: routedUIDs, devices: devices)
        reconcileInputPin()
    }

    /// When the input section is locked, keep the system default input on the device feeding Pancake
    /// Mic, re-asserting it against anything (AirPods on connect) that grabs it — the thing that pulls
    /// Bluetooth output down into low-quality HFP. Unlocked, the system default input is left alone.
    private func reconcileInputPin() {
        guard desiredGraph.policy.lockInput,
              let uid = desiredGraph.micInputDeviceUIDs.first,
              let id = AudioDevice.id(forUID: uid) else { return }
        if AudioDevice.defaultInputID != id {
            do { try AudioDevice.setDefaultInput(id); Log.info("locked input: pinned system default input to \(uid)") }
            catch { Log.warn("pin default input \(uid): \(error)") }
        }
    }

    // MARK: Hardware volume hold

    /// Bring the set of held devices in line with what the hub is routed to right now.
    private func reconcileVolumeHolds(routedUIDs: [String], devices: [AudioDevice]) {
        guard configuration.holdOutputVolumeAtUnity else { return }
        // A hold on a device object that no longer exists (coreaudiod restarted, device came back
        // with a new ID) is just a stale record: drop it so the device gets held afresh.
        for (uid, held) in heldVolumes where (try? AudioDevice(id: held.deviceID))?.uid != uid {
            held.listeners.forEach { $0.remove() }
            heldVolumes[uid] = nil
        }
        let wanted = Set(routedUIDs)
        for uid in heldVolumes.keys where !wanted.contains(uid) { releaseVolumeHold(uid: uid, leavingAt: nil) }
        for uid in routedUIDs where heldVolumes[uid] == nil {
            if let dev = devices.first(where: { $0.uid == uid }) { holdVolume(of: dev) }
        }
    }

    private static func describe(_ volumes: [UInt32: Float32]) -> String {
        volumes.keys.sorted().map { String(format: "el%d=%.2f", $0, volumes[$0] ?? 0) }.joined(separator: " ")
    }

    private func holdVolume(of dev: AudioDevice) {
        let current = dev.outputVolumes()
        guard !current.isEmpty else {
            Log.debug("volume hold: \(dev.name) has no settable output volume; nothing to hold")
            return
        }
        let elements = current.keys.sorted()
        var listeners: [PropertyListener] = []
        for element in elements {
            let address = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            let uid = dev.uid
            if let l = try? dev.id.addPropertyListener(address, queue: queue, handler: { [weak self] in self?.reassertVolumeHold(uid: uid) }) {
                listeners.append(l)
            }
        }
        heldVolumes[dev.uid] = HeldVolume(deviceID: dev.id, name: dev.name, saved: current, listeners: listeners)
        if current.values.allSatisfy({ abs($0 - 1) < 0.001 }) {
            Log.info("holding \(dev.name) hardware volume at unity (already there)")
            return
        }
        do {
            try dev.setOutputVolume(1, elements: elements)
            Log.info("holding \(dev.name) hardware volume at unity (was \(Self.describe(current)); put back when it stops being the output)")
        } catch { Log.warn("volume hold: set \(dev.name) to unity: \(error)") }
    }

    /// Something wrote the held device's volume. Our own write comes back through here too and
    /// reads as unity, so that's a no-op; anything else gets re-asserted and logged.
    private func reassertVolumeHold(uid: String) {
        guard let held = heldVolumes[uid], let dev = try? AudioDevice(id: held.deviceID), dev.uid == uid else { return }
        let off = dev.outputVolumes().filter { abs($0.value - 1) >= 0.001 }
        guard !off.isEmpty else { return }
        do {
            try dev.setOutputVolume(1, elements: off.keys.sorted())
            Log.info("something set \(held.name) hardware volume to \(Self.describe(off)); re-asserted unity")
        } catch { Log.warn("volume hold: re-assert \(held.name): \(error)") }
    }

    /// Stop holding. `leavingAt: nil` puts the saved values back (the device is no longer our
    /// output); a level leaves the device there instead (we're quitting and it becomes the
    /// system output, so it should sound exactly as loud as it did a moment ago).
    private func releaseVolumeHold(uid: String, leavingAt level: Float32?) {
        guard let held = heldVolumes.removeValue(forKey: uid) else { return }
        held.listeners.forEach { $0.remove() }
        guard let dev = try? AudioDevice(id: held.deviceID), dev.uid == uid else {
            Log.debug("volume hold: \(held.name) is gone; nothing to put back")
            return
        }
        do {
            if let level {
                try dev.setOutputVolume(level, elements: held.saved.keys.sorted())
                Log.info("released \(held.name) hardware volume at Pancake's level (\(String(format: "%.2f", level))) so nothing jumps")
            } else {
                for (element, value) in held.saved { try dev.setOutputVolume(value, elements: [element]) }
                Log.info("released \(held.name) hardware volume (put back \(Self.describe(held.saved)))")
            }
        } catch { Log.warn("volume hold: release \(held.name): \(error)") }
    }

    private func releaseAllVolumeHolds(leavingAt level: Float32?) {
        for uid in Array(heldVolumes.keys) { releaseVolumeHold(uid: uid, leavingAt: level) }
    }

    // MARK: Build / teardown

    /// Bring the live process taps in line with the graph's `.tap` nodes: create one per app that
    /// is a live HAL process, reuse ones already made, destroy the rest. Returns the live taps in
    /// `wanted` order — the order they'll take in the aggregate's tap list and the input layout.
    private func reconcileTaps(wanted: [String]) -> [(bundleID: String, tap: ProcessTap)] {
        for (bundleID, tap) in taps where !wanted.contains(bundleID) {
            tap.destroy(); taps[bundleID] = nil
            Log.info("tap \(bundleID): released")
        }
        var ordered: [(bundleID: String, tap: ProcessTap)] = []
        for bundleID in wanted where !ordered.contains(where: { $0.bundleID == bundleID }) {
            if let existing = taps[bundleID], ProcessTap.processObject(forBundleID: bundleID) != nil {
                ordered.append((bundleID, existing)); continue
            }
            if let stale = taps[bundleID] { stale.destroy(); taps[bundleID] = nil }
            if let tap = ProcessTap.create(bundleID: bundleID, name: "pancake: \(bundleID)") {
                taps[bundleID] = tap
                ordered.append((bundleID, tap))
                Log.info("tap \(bundleID): capturing (uuid \(tap.uuid))")
            }
        }
        return ordered
    }

    private func destroyAllTaps() {
        for (_, tap) in taps { tap.destroy() }
        taps.removeAll()
    }

    private func teardown() {
        if let agg = aggregate {
            if let proc = ioProcID {
                AudioDeviceStop(agg.id, proc)
                AudioDeviceDestroyIOProcID(agg.id, proc)
                ioProcID = nil
            }
            overloadListener?.remove()
            overloadListener = nil
            agg.destroy()
            aggregate = nil
        }
        // IOProc is stopped: every matrix is now free to release.
        if let old = pk_context_swap_matrix(rt, nil) { pk_matrix_free(old) }
        for r in retired { pk_matrix_free(r.matrix) }
        retired.removeAll()
        layout = nil
        currentComposition = nil
    }

    /// What can run right now: the desired graph minus absent devices, plus a fallback output
    /// if that left the hub with nowhere to go.
    func effectiveGraph(from desired: Graph, devices: [AudioDevice]) -> (Graph, [String]) {
        var notes: [String] = []
        let present = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0) })
        var g = desired
        g.upsert(.hub)

        for node in g.nodes {
            switch node.kind {
            case .input(let uid), .output(let uid):
                if present[uid] == nil {
                    notes.append("\(node.label ?? uid) is not connected; skipping")
                    g.remove(node.id)
                }
            case .tap:
                break   // handled in rebuild: a tap is created if the app is live, else the node is dropped there
            case .hub, .mic:
                break
            }
        }
        if g.node(Graph.micID) != nil, present[configuration.micUID] == nil {
            notes.append("mic device \(configuration.micUID) not found; skipping")
            g.remove(Graph.micID)
        }

        if g.hubOutputDeviceUIDs.isEmpty {
            if let fb = configuration.fallbackOutputUIDs.lazy.compactMap({ present[$0] }).first(where: { $0.hasOutput }) {
                notes.append("hub has no present output; falling back to \(fb.name)")
                for ch in 0..<min(2, fb.outputChannels) {
                    let out = Node.output(fb.uid, label: fb.name)
                    g.upsert(out)
                    g.links.append(Link(from: Port(Graph.hubID, ch), to: Port(out.id, ch)))
                }
            } else {
                notes.append("hub has no present output and no fallback is available")
            }
        }
        g.pruneOrphans()
        return (g, notes)
    }

    private func rebuild(force: Bool = false) {
        let devices = AudioDevice.all(includeHidden: true)
        knownDeviceUIDs = relevantDeviceUIDs(devices)
        guard let hub = devices.first(where: { $0.uid == configuration.hubUID }) else {
            teardown()
            setState(.degraded("hub device \(configuration.hubUID) not found — is Pancake.driver installed?"))
            return
        }

        let (effective, notes) = effectiveGraph(from: desiredGraph, devices: devices)
        notes.forEach { Log.info($0) }
        var graph = effective

        // Process taps: create/reuse one for each .tap node whose app is a live HAL process, and
        // drop the nodes whose app isn't running so the compiler never routes a dead source.
        let wantedTaps = graph.nodes.compactMap { node -> String? in
            if case .tap(let bundleID) = node.kind { return bundleID } else { return nil }
        }
        let liveTaps = reconcileTaps(wanted: wantedTaps)
        let liveTapBundleIDs = liveTaps.map(\.bundleID)
        let liveTapSet = Set(liveTapBundleIDs)
        for node in graph.nodes {
            if case .tap(let bundleID) = node.kind, !liveTapSet.contains(bundleID) {
                Log.info("tap \(bundleID): app not running; skipping")
                graph.remove(node.id)
            }
        }
        graph.pruneOrphans()

        // Sub-devices: the hub first, then everything the effective graph references, in a stable order.
        var subUIDs: [String] = [hub.uid]
        for uid in graph.referencedDeviceUIDs.sorted() where !subUIDs.contains(uid) { subUIDs.append(uid) }
        if graph.node(Graph.micID) != nil, !subUIDs.contains(configuration.micUID) { subUIDs.append(configuration.micUID) }
        let subDevices = subUIDs.compactMap { uid in devices.first { $0.uid == uid } }

        // Clock master: the first physical output in the graph; the hub only if there's nothing else.
        let main = subDevices.first { !$0.isSoftware && $0.hasOutput }
            ?? subDevices.first { !$0.isSoftware }
            ?? hub

        let composition = AggregateComposition(
            uid: configuration.aggregateUID,
            name: configuration.aggregateName,
            subDevices: subDevices.map { .init(uid: $0.uid, driftCompensation: $0.uid != main.uid) },
            taps: liveTaps.map { .init(uid: $0.tap.uuid, driftCompensation: true) },
            mainSubDeviceUID: main.uid,
            isPrivate: true
        )

        // Same devices, same taps, same clock master, still running: don't stop and restart
        // anything — stopping and restarting a Bluetooth output within a second has left it silent.
        if !force, let agg = aggregate, let layout, ioProcID != nil, let cur = currentComposition,
           cur.subDevices == composition.subDevices, cur.taps == composition.taps,
           cur.mainSubDeviceUID == composition.mainSubDeviceUID,
           case .running(let info) = currentState {
            let compiled = MatrixCompiler.compile(graph: graph, layout: layout, hubUID: configuration.hubUID, micUID: configuration.micUID)
            compiled.warnings.forEach { Log.warn($0) }
            if let matrix = MatrixCompiler.makeMatrix(compiled.routes) {
                let cycles = pk_context_cycles(rt)
                if let old = pk_context_swap_matrix(rt, matrix) { retired.append((old, cycles)) }
                drainRetiredLater()
            }
            Log.info("rebuild: composition unchanged, kept aggregate \(agg.id); \(compiled.routes.count) routes")
            setState(.running(RunInfo(aggregateID: agg.id, mainSubDeviceUID: info.mainSubDeviceUID, subDeviceUIDs: info.subDeviceUIDs,
                                      sampleRate: agg.nominalSampleRate, routes: compiled.routes, layout: layout, effectiveGraph: graph)))
            settle(routedUIDs: graph.hubOutputDeviceUIDs, devices: devices)
            return
        }

        teardown()
        do {
            let agg = try AggregateDevice.create(composition)
            currentComposition = composition
            aggregate = agg
            // An underrun on the aggregate is otherwise invisible; make it a log line.
            overloadListener = try? agg.id.addPropertyListener(.init(kAudioDeviceProcessorOverload), queue: queue) {
                Log.warn("aggregate processor overload (underrun)")
            }

            let rate = configuration.sampleRate ?? main.nominalSampleRate
            if rate > 0, agg.nominalSampleRate != rate {
                do { try agg.setNominalSampleRate(rate) } catch { Log.warn("set aggregate rate \(rate): \(error)") }
            }

            // The HAL lists sub-devices in composition order, but only the ones it accepted.
            let accepted = agg.fullSubDeviceList
            let ordered = accepted.compactMap { uid in subDevices.first { $0.uid == uid } }
            if ordered.count != subDevices.count {
                Log.warn("aggregate accepted \(accepted) of \(subUIDs)")
            }
            // Re-snapshot the accepted devices: joining an aggregate can change their stream layout/rate.
            let fresh = ordered.map { (try? AudioDevice(id: $0.id)) ?? $0 }

            for s in agg.streams(scope: kAudioObjectPropertyScopeInput) + agg.streams(scope: kAudioObjectPropertyScopeOutput) where !s.isFloat32Interleaved {
                throw ChannelLayout.ResolutionError(description: "unexpected stream format: \(s)")
            }

            let layout = try ChannelLayout.resolve(aggregate: agg, subDevices: fresh, tapBundleIDs: liveTapBundleIDs)
            self.layout = layout
            Log.debug("layout: \(layout)")

            let compiled = MatrixCompiler.compile(graph: graph, layout: layout, hubUID: configuration.hubUID, micUID: configuration.micUID)
            compiled.warnings.forEach { Log.warn($0) }
            guard let matrix = MatrixCompiler.makeMatrix(compiled.routes) else {
                throw ChannelLayout.ResolutionError(description: "matrix allocation failed")
            }
            if let old = pk_context_swap_matrix(rt, matrix) { pk_matrix_free(old) }

            var proc: AudioDeviceIOProcID? = nil
            try check(AudioDeviceCreateIOProcID(agg.id, pk_ioproc, UnsafeMutableRawPointer(rt), &proc), "create IOProc")
            ioProcID = proc
            try check(AudioDeviceStart(agg.id, proc), "start aggregate")

            let info = RunInfo(aggregateID: agg.id, mainSubDeviceUID: main.uid, subDeviceUIDs: accepted,
                               sampleRate: agg.nominalSampleRate, routes: compiled.routes, layout: layout, effectiveGraph: graph)
            Log.info("running: \(info)")
            for r in compiled.routes { Log.debug("  route \(r)") }
            setState(.running(info))
            settle(routedUIDs: graph.hubOutputDeviceUIDs, devices: devices)
        } catch {
            Log.error("rebuild failed: \(error)")
            teardown()
            setState(.degraded("\(error)"))
        }
    }

    /// Gains changed but topology didn't: recompile against the existing layout and swap.
    private func recompileMatrix(reason: String) {
        guard let layout, case .running(let info) = currentState else {
            scheduleRebuild(reason: reason)
            return
        }
        let devices = AudioDevice.all(includeHidden: true)
        let (graph, _) = effectiveGraph(from: desiredGraph, devices: devices)
        let compiled = MatrixCompiler.compile(graph: graph, layout: layout, hubUID: configuration.hubUID, micUID: configuration.micUID)
        compiled.warnings.forEach { Log.warn($0) }
        guard let matrix = MatrixCompiler.makeMatrix(compiled.routes) else { return }
        let cycles = pk_context_cycles(rt)
        if let old = pk_context_swap_matrix(rt, matrix) { retired.append((old, cycles)) }
        Log.info("matrix swapped (\(reason)): \(compiled.routes.count) routes")
        setState(.running(RunInfo(aggregateID: info.aggregateID, mainSubDeviceUID: info.mainSubDeviceUID, subDeviceUIDs: info.subDeviceUIDs,
                                  sampleRate: info.sampleRate, routes: compiled.routes, layout: layout, effectiveGraph: graph)))
        settle(routedUIDs: graph.hubOutputDeviceUIDs, devices: devices)
        drainRetiredLater()
    }

    /// Periodic health check. Logs what the IOProc is doing and forces a rebuild if IO has
    /// stalled or the aggregate lost a sub-device without telling us.
    private func watchdogTick() {
        guard case .running(let info) = currentState, let agg = aggregate, let layout else { return }
        let cycles = pk_context_cycles(rt)
        let hubPeak = layout.inputs[configuration.hubUID]?.first.map { pk_context_input_peak(rt, UInt32($0.buffer)) } ?? 0
        var outs: [String] = []
        for uid in info.effectiveGraph.hubOutputDeviceUIDs {
            let peak = layout.outputs[uid]?.first.map { pk_context_output_peak(rt, UInt32($0.buffer)) } ?? 0
            let running = AudioDevice.id(forUID: uid).map { id -> String in
                let r = (try? id.getProperty(.init(kAudioDevicePropertyDeviceIsRunning), as: UInt32.self)) ?? 9
                return "\(r)"
            } ?? "?"
            outs.append("\(uid): wrote=\(String(format: "%.3f", peak)) running=\(running)")
        }
        let aggRunning = (try? agg.id.getProperty(.init(kAudioDevicePropertyDeviceIsRunning), as: UInt32.self)) ?? 9
        Log.debug("health: cycles=\(cycles) (+\(cycles &- watchdogLastCycles)) hub=\(String(format: "%.3f", hubPeak)) agg=\(agg.id) running=\(aggRunning) subs=\(agg.fullSubDeviceList.count) | \(outs.joined(separator: "; "))")

        if cycles == watchdogLastCycles {
            watchdogStalls += 1
            if watchdogStalls >= 2 {
                Log.warn("watchdog: IO has not cycled for \(watchdogStalls) checks; rebuilding")
                watchdogStalls = 0
                rebuild(force: true)
                return
            }
        } else {
            watchdogStalls = 0
        }
        watchdogLastCycles = cycles

        let listed = Set(agg.fullSubDeviceList)
        let missing = info.subDeviceUIDs.filter { !listed.contains($0) }
        if !missing.isEmpty {
            Log.warn("watchdog: aggregate lost \(missing); rebuilding")
            rebuild(force: true)
        }
    }

    /// A swapped-out matrix may be mid-use for one more IO cycle. Free it once the cycle
    /// counter has moved on (or IO has stopped, in which case teardown already freed it).
    private func drainRetiredLater() {
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.retired.isEmpty else { return }
            let now = pk_context_cycles(self.rt)
            let running = self.ioProcID != nil
            var keep: [(matrix: UnsafeMutablePointer<pk_matrix>, cycles: UInt64)] = []
            for r in self.retired {
                if !running || now > r.cycles + 1 { pk_matrix_free(r.matrix) } else { keep.append(r) }
            }
            self.retired = keep
            if !keep.isEmpty { self.drainRetiredLater() }
        }
    }
}
