import Testing
@testable import PancakeCore

@Suite struct GraphTests {
    @Test func stereoOutputBuildsTwoLinks() {
        let g = Graph.stereoOutput("dev-a", label: "A")
        #expect(g.hubOutputDeviceUIDs == ["dev-a"])
        #expect(g.links.count == 2)
        #expect(g.links.map(\.gain) == [1, 1])
    }

    @Test func setOutputReplacesOnlyHubOutputLinks() {
        var g = Graph.stereoOutput("dev-a")
        // An unrelated link (mic input → Pancake Mic) must survive an output change.
        g.upsert(.input("mic-1"))
        g.upsert(.mic)
        g.connect(Port("in:mic-1", 0), Port(Graph.micID, 0), gain: 0.5)
        g.setOutput(uid: "dev-b")
        #expect(g.hubOutputDeviceUIDs == ["dev-b"])
        #expect(g.node("out:dev-a") == nil, "old output node pruned")
        #expect(g.links.filter { $0.to.node == Graph.micID }.count == 1)
        #expect(g.links.first { $0.to.node == Graph.micID }?.gain == 0.5)
    }

    @Test func topologyComparisonIgnoresGains() {
        let a = Graph.stereoOutput("dev-a")
        var b = a
        b.links[0].gain = 0.25
        #expect(a.hasSameTopology(as: b))
        b.setOutput(uid: "dev-b")
        #expect(!a.hasSameTopology(as: b))
    }

    @Test func jsonRoundTripAndShape() throws {
        var g = Graph.stereoOutput("AA-BB-CC-DD-EE-FF:output", label: "AirPods")
        g.upsert(.mic)
        g.upsert(.input("BuiltInMicrophoneDevice", label: "MacBook Pro Microphone"))
        g.connect(Port("in:BuiltInMicrophoneDevice", 0), Port(Graph.micID, 0))
        g.connect(Port("in:BuiltInMicrophoneDevice", 0), Port(Graph.micID, 1))
        let text = try g.jsonString()
        let compact = text.filter { $0 != " " && $0 != "\n" }   // pretty-printing adds whitespace
        #expect(compact.contains(#""type":"output""#), Comment(rawValue: text))
        #expect(compact.contains(#""device":"AA-BB-CC-DD-EE-FF:output""#), Comment(rawValue: text))
        #expect(!compact.contains("deviceUID"), "hand-written Codable should be in effect")
        let back = try Graph(jsonString: text)
        #expect(back == g)
    }

    @Test func missingGainDecodesAsUnity() throws {
        let json = #"{"nodes":[{"id":"hub","kind":{"type":"hub"}},{"id":"out:x","kind":{"type":"output","device":"x"}}],"links":[{"from":{"node":"hub","channel":0},"to":{"node":"out:x","channel":0}}]}"#
        let g = try Graph(jsonString: json)
        #expect(g.links.first?.gain == 1)
    }
}
