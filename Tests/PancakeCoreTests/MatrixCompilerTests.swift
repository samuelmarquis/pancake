import CPancakeRT
import Testing
@testable import PancakeCore

@Suite struct MatrixCompilerTests {
    // Aggregate: [hub(in 2ch / out 2ch), airpods(in 1ch / out 2ch), pancake-mic(in 2ch / out 2ch),
    //             pancake-program(in 2ch / out 2ch)] + one process tap (in 2ch)
    // Input ABL:  b0 = hub L/R,  b1 = airpods mic,  b2 = pancake-mic loopback,  b3 = program loopback,  b4 = tap
    // Output ABL: b0 = hub out,  b1 = airpods L/R,  b2 = pancake-mic in,        b3 = program in
    var layout: ChannelLayout {
        var l = ChannelLayout()
        l.inputBuffers = [2, 1, 2, 2, 2]
        l.outputBuffers = [2, 2, 2, 2]
        l.inputs = ["hub": [.init(buffer: 0, channel: 0), .init(buffer: 0, channel: 1)],
                    "pods": [.init(buffer: 1, channel: 0)],
                    "pmic": [.init(buffer: 2, channel: 0), .init(buffer: 2, channel: 1)],
                    "prog": [.init(buffer: 3, channel: 0), .init(buffer: 3, channel: 1)],
                    "com.example.app": [.init(buffer: 4, channel: 0), .init(buffer: 4, channel: 1)]]
        l.outputs = ["hub": [.init(buffer: 0, channel: 0), .init(buffer: 0, channel: 1)],
                     "pods": [.init(buffer: 1, channel: 0), .init(buffer: 1, channel: 1)],
                     "pmic": [.init(buffer: 2, channel: 0), .init(buffer: 2, channel: 1)],
                     "prog": [.init(buffer: 3, channel: 0), .init(buffer: 3, channel: 1)]]
        return l
    }

    @Test func stereoRoute() {
        let g = Graph.stereoOutput("pods")
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic", programUID: "prog")
        #expect(r.warnings.isEmpty, Comment(rawValue: "\(r.warnings)"))
        #expect(r.routes.map { "\($0)" } == ["b0c0 -> b1c0 ×1.0", "b0c1 -> b1c1 ×1.0"])
    }

    @Test func micMixIntoPancakeMic() {
        var g = Graph.stereoOutput("pods")
        g.upsert(.mic)
        g.upsert(.input("pods"))            // the AirPods' own mic, mono
        g.connect(Port("in:pods", 0), Port(Graph.micID, 0))
        g.connect(Port("in:pods", 0), Port(Graph.micID, 1))
        g.connect(Port(Graph.hubID, 0), Port(Graph.micID, 0), gain: 0.5)  // plus what's playing, at half
        g.connect(Port(Graph.hubID, 1), Port(Graph.micID, 1), gain: 0.5)
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic", programUID: "prog")
        #expect(r.warnings.isEmpty, Comment(rawValue: "\(r.warnings)"))
        #expect(r.routes.count == 6)
        #expect(r.routes.contains { $0.inBuffer == 1 && $0.inChannel == 0 && $0.outBuffer == 2 && $0.outChannel == 1 })
        #expect(r.routes.contains { $0.inBuffer == 0 && $0.inChannel == 1 && $0.outBuffer == 2 && $0.outChannel == 1 && $0.gain == 0.5 })
    }

    /// One app tap fans out to every sink the graph wires it to — the screen-share bus, the mic and
    /// a recorder all read the same tap input buffer. (This is the whole point of the engine owning
    /// the tap: two taps on one app fight and one goes silent.)
    @Test func oneTapFansOutToProgramMicAndRecorder() {
        var g = Graph.stereoOutput("pods")
        g.upsert(.mic); g.upsert(.program)
        g.upsert(.tap("com.example.app", label: "App"))
        let rec = Node.recorder(id: "r1"); g.upsert(rec)
        for ch in 0..<2 {
            g.connect(Port("tap:com.example.app", ch), Port(Graph.programID, ch))
            g.connect(Port("tap:com.example.app", ch), Port(Graph.micID, ch), gain: 0.5)
            g.connect(Port("tap:com.example.app", ch), Port(rec.id, ch))
        }
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic", programUID: "prog",
                                       recorderSlots: [rec.id: 2])
        #expect(r.warnings.isEmpty, Comment(rawValue: "\(r.warnings)"))
        #expect(r.routes.count == 8)
        // program: tap b4 → program out b3, unity
        #expect(r.routes.contains { $0.inBuffer == 4 && $0.inChannel == 1 && $0.outBuffer == 3 && $0.outChannel == 1 && $0.gain == 1 })
        // mic: same tap buffer → mic out b2, at half
        #expect(r.routes.contains { $0.inBuffer == 4 && $0.inChannel == 0 && $0.outBuffer == 2 && $0.outChannel == 0 && $0.gain == 0.5 })
        // recorder: same tap buffer → recorder slot 2 (flagged)
        #expect(r.routes.contains { $0.inBuffer == 4 && $0.outBuffer == (Int(PK_REC_FLAG) | 2) && $0.outChannel == 0 })
    }

    /// The program bus is a sink like the mic: the hub (everything you hear) can be streamed too.
    @Test func hubIntoProgram() {
        var g = Graph.stereoOutput("pods")
        g.upsert(.program)
        g.connect(Port(Graph.hubID, 0), Port(Graph.programID, 0))
        g.connect(Port(Graph.hubID, 1), Port(Graph.programID, 1))
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic", programUID: "prog")
        #expect(r.warnings.isEmpty, Comment(rawValue: "\(r.warnings)"))
        #expect(r.routes.map { "\($0)" }.sorted() == ["b0c0 -> b1c0 ×1.0", "b0c0 -> b3c0 ×1.0", "b0c1 -> b1c1 ×1.0", "b0c1 -> b3c1 ×1.0"])
    }

    /// Bus routes are staged: device-sourced routes first, then each bus's outgoing routes after it,
    /// with a bus that feeds another bus ordered first.
    @Test func busesAreStagedInDependencyOrder() {
        var g = Graph.stereoOutput("pods")
        let a = Node.bus(id: "a"), b = Node.bus(id: "b")
        g.upsert(a); g.upsert(b); g.upsert(.mic)
        g.upsert(.tap("com.example.app", label: "App"))
        for ch in 0..<2 {
            g.connect(Port("tap:com.example.app", ch), Port(b.id, ch))       // tap → B
            g.connect(Port(b.id, ch), Port(a.id, ch))                        // B → A  (so B must run first)
            g.connect(Port(Graph.hubID, ch), Port(a.id, ch), gain: 0.5)      // hub → A
            g.connect(Port(a.id, ch), Port(Graph.micID, ch))                 // A → mic
        }
        var p = BusParams(); p.compressor = true; p.attack = 0; p.threshold = -12
        g.setBusParams(a.id, p)
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic", programUID: "prog",
                                       busSlots: [a.id: 0, b.id: 1], sampleRate: 48000)
        #expect(r.warnings.isEmpty, Comment(rawValue: "\(r.warnings)"))
        #expect(r.busOrder == [1, 0], "B (slot 1) feeds A (slot 0), so B is processed first")
        // stage 1 = hub→pods (2) + tap→B (2) + hub→A (2) = 6; then B's segment (B→A, 2); then A's (A→mic, 2)
        #expect(r.stage1Count == 6)
        #expect(r.segmentEnds == [8, 10])
        #expect(r.routes.count == 10)
        #expect(r.routes[0..<6].allSatisfy { $0.readsBus == nil })
        #expect(r.routes[6..<8].allSatisfy { $0.readsBus == 1 && $0.writesBus == 0 })
        #expect(r.routes[8..<10].allSatisfy { $0.readsBus == 0 })
        // A's baked params: compressor on, instant attack (coef 0), default release baked for 48k.
        let ba = r.buses.first { $0.slot == 0 }!
        #expect(ba.rt.comp_enabled == 1 && ba.rt.threshold_db == -12 && ba.rt.attack_coef == 0)
        #expect(ba.rt.release_coef > 0.99 && ba.rt.release_coef < 1)
        #expect(r.buses.first { $0.slot == 1 }!.rt.comp_enabled == 0)
    }

    @Test func busCycleIsBrokenWithAWarning() {
        var g = Graph.stereoOutput("pods")
        let a = Node.bus(id: "a"), b = Node.bus(id: "b")
        g.upsert(a); g.upsert(b); g.upsert(.mic)
        g.connect(Port(Graph.hubID, 0), Port(a.id, 0))
        g.connect(Port(a.id, 0), Port(b.id, 0))
        g.connect(Port(b.id, 0), Port(a.id, 0))      // closes a cycle
        g.connect(Port(b.id, 0), Port(Graph.micID, 0))
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic", programUID: "prog",
                                       busSlots: [a.id: 0, b.id: 1])
        #expect(r.warnings.contains { $0.contains("cycle") })
        #expect(!r.routes.contains { $0.readsBus != nil && $0.writesBus != nil }, "bus↔bus links dropped")
        #expect(r.routes.count == 4)   // hub→pods ×2, hub→A, B→mic
        #expect(Set(r.busOrder) == [0, 1])
    }

    @Test func outOfRangeChannelIsWarnedNotCrashed() {
        var g = Graph.stereoOutput("pods")
        g.links.append(Link(from: Port(Graph.hubID, 7), to: Port("out:pods", 0)))
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic", programUID: "prog")
        #expect(r.routes.count == 2)
        #expect(r.warnings.count == 1)
    }

    @Test func makeMatrixCopiesRoutes() throws {
        let g = Graph.stereoOutput("pods")
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic", programUID: "prog")
        let m = try #require(MatrixCompiler.makeMatrix(r.routes))
        defer { pk_matrix_free(m) }
        #expect(m.pointee.route_count == 2)
        let routes = try #require(m.pointee.routes)
        #expect(routes[1].in_channel == 1)
        #expect(routes[1].out_buffer == 1)
    }
}
