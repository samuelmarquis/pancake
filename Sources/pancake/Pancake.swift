import ArgumentParser
import CoreAudio
import Foundation
import PancakeCore

@main
struct Pancake: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "pancake — a routing engine for macOS audio.",
        subcommands: [Devices.self, Status.self, Run.self, Record.self, SetOutput.self, ShowGraph.self, ProbeAggregate.self],
        defaultSubcommand: Status.self
    )
}

struct Verbose: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Debug logging.") var verbose = false
    func apply() { Log.minimumLevel = verbose ? .debug : .info }
}

struct ConfigOption: ParsableArguments {
    @Option(name: .long, help: "Graph file (default: ~/.config/pancake/graph.json).") var config: String?
    var store: GraphStore { GraphStore(url: config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) }
}

// MARK: - devices

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List CoreAudio devices as the HAL sees them.")
    @Flag(name: .long, help: "Include hidden devices.") var all = false

    func run() throws {
        let defaultOut = AudioDevice.defaultOutputID, defaultIn = AudioDevice.defaultInputID, sysOut = AudioDevice.defaultSystemOutputID
        for d in AudioDevice.all(includeHidden: all) {
            var marks: [String] = []
            if d.id == defaultOut { marks.append("default-out") }
            if d.id == sysOut { marks.append("system-out") }
            if d.id == defaultIn { marks.append("default-in") }
            if d.isHidden { marks.append("hidden") }
            print("\(d.name)")
            print("    uid: \(d.uid)")
            print("    \(d.transport)  in:\(d.inputStreamChannels) out:\(d.outputStreamChannels)  \(Int(d.nominalSampleRate)) Hz  \(marks.joined(separator: " "))")
        }
    }
}

// MARK: - status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Where things stand: defaults, driver, config.")
    @OptionGroup var config: ConfigOption

    func run() throws {
        func name(_ id: AudioObjectID?) -> String { id.flatMap { try? AudioDevice(id: $0) }.map { "\($0.name) [\($0.uid)]" } ?? "?" }
        print("default output:        \(name(AudioDevice.defaultOutputID))")
        print("default system output: \(name(AudioDevice.defaultSystemOutputID))")
        print("default input:         \(name(AudioDevice.defaultInputID))")
        let hub = AudioDevice.find(uid: "Pancake_UID")
        let others = ["PancakeMic_UID", "PancakeProgram_UID", "PancakeStage_UID"].compactMap { AudioDevice.find(uid: $0)?.name }
        print("Pancake.driver:        \(hub != nil ? "loaded (\(hub!.name))" : "NOT loaded")\(others.isEmpty ? "" : " + " + others.joined(separator: ", "))")
        if hub != nil, others.count < 3 {
            print("                       (missing \(3 - others.count) device(s) — the installed driver is older than this build; sudo make install-driver)")
        }
        print("graph file:            \(config.store.url.path) \(FileManager.default.fileExists(atPath: config.store.url.path) ? "" : "(missing)")")
        if let g = try? config.store.load() {
            print("graph outputs:         \(g.hubOutputDeviceUIDs)")
        }
    }
}

// MARK: - run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the engine in the foreground until Ctrl-C.")
    @OptionGroup var verbose: Verbose
    @OptionGroup var config: ConfigOption
    @Option(name: .shortAndLong, help: "Output device (name or UID). Overrides the graph file's output.") var output: String?
    @Option(name: .long, help: "Hub device UID or name (default: Pancake). Use 'Loopback Audio' to test before the driver is installed.") var hub: String?
    @Flag(name: .long, help: "Don't pin the system default output to the hub.") var noPin = false
    @Flag(name: .long, help: "Don't follow default-output changes.") var noFollow = false
    @Option(name: .long, help: "Print IO stats every N seconds (0 = off).") var stats: Int = 0
    @Flag(name: .long, help: "Don't watch the graph file for changes.") var noWatch = false

    func run() throws {
        verbose.apply()
        var cfg = Engine.Configuration()
        cfg.pinDefaultOutput = !noPin
        cfg.followDefaultOutput = !noFollow
        if let hub {
            guard let d = AudioDevice.find(nameOrUID: hub) else { throw ValidationError("no device matches '\(hub)'") }
            cfg.hubUID = d.uid
            Log.info("hub: \(d.name) [\(d.uid)]")
        }

        var graph = (try config.store.load()) ?? Graph()
        if let output {
            guard let d = AudioDevice.find(nameOrUID: output) else { throw ValidationError("no device matches '\(output)'") }
            graph.setOutput(uid: d.uid, channels: min(2, max(1, d.outputChannels)), label: d.name)
        }
        if graph.hubOutputDeviceUIDs.isEmpty {
            Log.info("graph has no output; engine will use the fallback (\(cfg.fallbackOutputUIDs))")
        }

        let engine = Engine(graph: graph, configuration: cfg)
        engine.onStateChange = { state in
            if case .degraded(let why) = state { Log.warn("engine degraded: \(why)") }
        }
        engine.start()

        let store = config.store
        var watcher: FileWatcher? = nil
        if !noWatch {
            watcher = store.watch(queue: DispatchQueue(label: "com.pancake.cli.watch")) {
                do {
                    if let g = try store.load() {
                        Log.info("graph file changed; applying")
                        engine.apply(g)
                    }
                } catch {
                    Log.warn("graph file unreadable: \(error)")
                }
            }
        }

        if stats > 0 {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + .seconds(stats), repeating: .seconds(stats))
            t.setEventHandler {
                let s = engine.stats()
                Log.info("io: cycles=\(s.cycles) frames=\(s.frames) last=\(s.last_frames)f in=\(s.last_in_buffers)b out=\(s.last_out_buffers)b noMatrix=\(s.cycles_without_matrix) skipped=\(s.routes_skipped)")
            }
            t.resume()
            _ = Unmanaged.passRetained(t)
        }

        // Clean shutdown on Ctrl-C / SIGTERM: destroy the aggregate rather than leaking it into coreaudiod.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler {
                Log.info("stopping")
                watcher?.stop()
                engine.stop()
                Pancake.exit(withError: nil)
            }
            s.resume()
            return s
        }
        _ = sources
        dispatchMain()
    }
}

// MARK: - record

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record a source to a WAV via a recorder node (proves the recorder path). Stop the app first — one engine at a time.")
    @OptionGroup var verbose: Verbose
    @OptionGroup var config: ConfigOption
    @Option(name: .long, help: "What to record: 'hub' (everything playing), 'tap:<bundleID>' (one app), or an input device name/UID.") var source: String = "hub"
    @Option(name: .shortAndLong, help: "Seconds to record.") var seconds: Double = 5
    @Option(name: .long, help: "Output WAV path (default: ~/Music/Pancake/…).") var to: String?

    func run() throws {
        verbose.apply()
        var graph = (try config.store.load()) ?? Graph()

        // Wire the chosen source into a fresh recorder node.
        let srcID: NodeID
        let srcChannels: Int
        if source.lowercased() == "hub" {
            graph.upsert(.hub)
            srcID = Graph.hubID
            srcChannels = 2
        } else if source.hasPrefix("tap:") {
            let bundleID = String(source.dropFirst("tap:".count))
            let n = Node.tap(bundleID)
            graph.upsert(n)
            srcID = n.id
            srcChannels = 2
        } else {
            guard let d = AudioDevice.find(nameOrUID: source), d.hasInput else { throw ValidationError("no input device matches '\(source)'") }
            let n = Node.input(d.uid, label: d.name)
            graph.upsert(n)
            srcID = n.id
            srcChannels = max(1, d.inputChannels)
        }
        let rec = Node.recorder()
        graph.upsert(rec)
        if srcChannels >= 2 {
            graph.connect(Port(srcID, 0), Port(rec.id, 0))
            graph.connect(Port(srcID, 1), Port(rec.id, 1))
        } else {
            graph.connect(Port(srcID, 0), Port(rec.id, 0))   // mono → both recorder channels
            graph.connect(Port(srcID, 0), Port(rec.id, 1))
        }

        let engine = Engine(graph: graph)
        let ready = DispatchSemaphore(value: 0)
        var signalled = false
        engine.onStateChange = { state in
            switch state {
            case .running where !signalled: signalled = true; ready.signal()
            case .degraded(let why): Log.warn("engine degraded: \(why)")
            default: break
            }
        }
        engine.start()
        if ready.wait(timeout: .now() + 6) == .timedOut {
            engine.stop()
            throw ValidationError("engine didn't reach running — is Pancake.driver installed and no other engine (the app?) running?")
        }

        let url = to.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? RecordingLocation.defaultFile()
        try engine.startRecording(node: rec.id, to: url)
        Log.info("recording \(source) for \(seconds)s → \(url.path)")
        Thread.sleep(forTimeInterval: seconds)
        let elapsed = engine.recordingElapsed(rec.id) ?? 0
        engine.stopRecording(rec.id)
        engine.stop()
        print("wrote \(url.path)  (~\(String(format: "%.2f", elapsed))s captured)")
    }
}

// MARK: - set-output

struct SetOutput: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-output", abstract: "Point the hub at an output device (edits the graph file; a running engine picks it up).")
    @OptionGroup var config: ConfigOption
    @Argument(help: "Output device name or UID.") var device: String

    func run() throws {
        guard let d = AudioDevice.find(nameOrUID: device) else { throw ValidationError("no device matches '\(device)'") }
        var g = (try config.store.load()) ?? Graph()
        g.setOutput(uid: d.uid, channels: min(2, max(1, d.outputChannels)), label: d.name)
        try config.store.save(g)
        print("hub → \(d.name) [\(d.uid)]  (\(config.store.url.path))")
    }
}

// MARK: - graph

struct ShowGraph: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "graph", abstract: "Print the graph file.")
    @OptionGroup var config: ConfigOption

    func run() throws {
        guard let g = try config.store.load() else { print("no graph at \(config.store.url.path)"); return }
        print(try g.jsonString())
    }
}

// MARK: - probe-aggregate

struct ProbeAggregate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "probe-aggregate", abstract: "Build a private aggregate from the given devices, dump what the HAL made of it, tear it down.")
    @OptionGroup var verbose: Verbose
    @Argument(help: "Device names or UIDs, in order.") var devices: [String]
    @Option(name: .long, help: "Clock master (name or UID). Default: first physical output given.") var main: String?
    @Option(name: .customLong("run"), help: "Run an IOProc on it for N seconds (to see e.g. whether Bluetooth drops into headset mode).") var seconds: Int = 0

    func run() throws {
        verbose.apply()
        let all = AudioDevice.all(includeHidden: true)
        let devs = try devices.map { q -> AudioDevice in
            guard let d = AudioDevice.find(nameOrUID: q, in: all) else { throw ValidationError("no device matches '\(q)'") }
            return d
        }
        let mainDev: AudioDevice
        if let main {
            guard let d = AudioDevice.find(nameOrUID: main, in: all) else { throw ValidationError("no device matches '\(main)'") }
            mainDev = d
        } else {
            mainDev = devs.first { !$0.isSoftware && $0.hasOutput } ?? devs[0]
        }
        print("sub-devices:")
        for d in devs { print("  \(d)\(d.id == mainDev.id ? "  <- main" : "")") }

        let comp = AggregateComposition(uid: "com.pancake.probe", name: "pancake probe",
                                        subDevices: devs.map { .init(uid: $0.uid, driftCompensation: $0.id != mainDev.id) },
                                        mainSubDeviceUID: mainDev.uid)
        let agg = try AggregateDevice.create(comp)
        defer { agg.destroy() }
        print(agg.describe())

        let ordered = agg.fullSubDeviceList.compactMap { uid in devs.first { $0.uid == uid } }
        do {
            let layout = try ChannelLayout.resolve(aggregate: agg, subDevices: ordered.map { (try? AudioDevice(id: $0.id)) ?? $0 })
            print("layout: \(layout)")
        } catch {
            print("layout: FAILED — \(error)")
        }

        if seconds > 0 {
            let ctx = pk_context_create()!
            defer { pk_context_destroy(ctx) }
            var procID: AudioDeviceIOProcID? = nil
            try CoreAudioError.check(AudioDeviceCreateIOProcID(agg.id, pk_ioproc, UnsafeMutableRawPointer(ctx), &procID), "create IOProc")
            guard let proc = procID else { throw ValidationError("no IOProc ID returned") }
            try CoreAudioError.check(AudioDeviceStart(agg.id, proc), "start")
            print("running IO (silence) for \(seconds)s …")
            for i in 1...seconds {
                Thread.sleep(forTimeInterval: 1)
                var s = pk_stats()
                pk_context_get_stats(ctx, &s)
                let rates = devs.map { d in "\(d.name)=\(Int((try? AudioDevice(id: d.id))?.nominalSampleRate ?? 0))" }.joined(separator: " ")
                let peaks = (0..<Int(s.last_in_buffers)).map { String(format: "%.3f", pk_context_input_peak(ctx, UInt32($0))) }.joined(separator: ",")
                print("  t=\(i)s cycles=\(s.cycles) frames=\(s.frames) last=\(s.last_frames) in=\(s.last_in_buffers)b out=\(s.last_out_buffers)b peaks=[\(peaks)]  rates: \(rates)")
            }
            AudioDeviceStop(agg.id, proc)
            AudioDeviceDestroyIOProcID(agg.id, proc)
        }
    }
}
