import CPancakeRT
import Testing
@testable import PancakeCore

@Suite struct MatrixCompilerTests {
    // Aggregate: [hub(in 2ch / out 2ch), airpods(in 1ch / out 2ch), pancake-mic(in 2ch / out 2ch)]
    // Input ABL:  b0 = hub L/R,  b1 = airpods mic,  b2 = pancake-mic loopback
    // Output ABL: b0 = hub out,  b1 = airpods L/R,  b2 = pancake-mic in
    var layout: ChannelLayout {
        var l = ChannelLayout()
        l.inputBuffers = [2, 1, 2]
        l.outputBuffers = [2, 2, 2]
        l.inputs = ["hub": [.init(buffer: 0, channel: 0), .init(buffer: 0, channel: 1)],
                    "pods": [.init(buffer: 1, channel: 0)],
                    "pmic": [.init(buffer: 2, channel: 0), .init(buffer: 2, channel: 1)]]
        l.outputs = ["hub": [.init(buffer: 0, channel: 0), .init(buffer: 0, channel: 1)],
                     "pods": [.init(buffer: 1, channel: 0), .init(buffer: 1, channel: 1)],
                     "pmic": [.init(buffer: 2, channel: 0), .init(buffer: 2, channel: 1)]]
        return l
    }

    @Test func stereoRoute() {
        let g = Graph.stereoOutput("pods")
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic")
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
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic")
        #expect(r.warnings.isEmpty, Comment(rawValue: "\(r.warnings)"))
        #expect(r.routes.count == 6)
        #expect(r.routes.contains { $0.inBuffer == 1 && $0.inChannel == 0 && $0.outBuffer == 2 && $0.outChannel == 1 })
        #expect(r.routes.contains { $0.inBuffer == 0 && $0.inChannel == 1 && $0.outBuffer == 2 && $0.outChannel == 1 && $0.gain == 0.5 })
    }

    @Test func outOfRangeChannelIsWarnedNotCrashed() {
        var g = Graph.stereoOutput("pods")
        g.links.append(Link(from: Port(Graph.hubID, 7), to: Port("out:pods", 0)))
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic")
        #expect(r.routes.count == 2)
        #expect(r.warnings.count == 1)
    }

    @Test func makeMatrixCopiesRoutes() throws {
        let g = Graph.stereoOutput("pods")
        let r = MatrixCompiler.compile(graph: g, layout: layout, hubUID: "hub", micUID: "pmic")
        let m = try #require(MatrixCompiler.makeMatrix(r.routes))
        defer { pk_matrix_free(m) }
        #expect(m.pointee.route_count == 2)
        let routes = try #require(m.pointee.routes)
        #expect(routes[1].in_channel == 1)
        #expect(routes[1].out_buffer == 1)
    }
}
