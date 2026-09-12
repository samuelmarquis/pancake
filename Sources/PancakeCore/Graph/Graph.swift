import Foundation

/// The routing graph. This is the *desired* state, as the user wrote it — it may reference
/// devices that are unplugged right now. The engine derives what can actually run from it.
///
/// Persisted as JSON at `~/.config/pancake/graph.json`; see `GraphStore`.

public struct NodeID: Hashable, Codable, ExpressibleByStringLiteral, CustomStringConvertible, Comparable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
    public static func < (a: NodeID, b: NodeID) -> Bool { a.rawValue < b.rawValue }
}

public enum NodeKind: Hashable, Codable {
    /// "Pancake" — the virtual device apps play into. A *source* from the graph's point of view.
    case hub
    /// "Pancake Mic" — the virtual device apps record from. A *sink*.
    case mic
    /// A physical input device (microphone, interface input). Source.
    case input(deviceUID: String)
    /// A physical output device. Sink.
    case output(deviceUID: String)
    /// A per-process tap (macOS 14.2+). Source. Reserved for M5; the engine ignores it today.
    case tap(bundleID: String)
    /// A capture-to-disk sink. Not a device — the engine mixes what's wired in into a ring and a
    /// drain thread writes it to a file. `id` is a stable identifier so multiple recorders persist.
    case recorder(id: String)

    public var isSource: Bool {
        switch self {
        case .hub, .input, .tap: return true
        case .mic, .output, .recorder: return false
        }
    }
    public var isSink: Bool { !isSource }

    /// The device UID this node is backed by, for the kinds that are backed by a device.
    public var deviceUID: String? {
        switch self {
        case .input(let uid), .output(let uid): return uid
        case .hub, .mic, .tap, .recorder: return nil
        }
    }

    // Hand-written Codable so the config file reads as {"type":"output","device":"…"} rather
    // than Swift's synthesized {"output":{"deviceUID":"…"}}.
    private enum CodingKeys: String, CodingKey { case type, device, bundle, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hub": self = .hub
        case "mic": self = .mic
        case "input": self = .input(deviceUID: try c.decode(String.self, forKey: .device))
        case "output": self = .output(deviceUID: try c.decode(String.self, forKey: .device))
        case "tap": self = .tap(bundleID: try c.decode(String.self, forKey: .bundle))
        case "recorder": self = .recorder(id: try c.decode(String.self, forKey: .id))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown node type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hub: try c.encode("hub", forKey: .type)
        case .mic: try c.encode("mic", forKey: .type)
        case .input(let uid): try c.encode("input", forKey: .type); try c.encode(uid, forKey: .device)
        case .output(let uid): try c.encode("output", forKey: .type); try c.encode(uid, forKey: .device)
        case .tap(let b): try c.encode("tap", forKey: .type); try c.encode(b, forKey: .bundle)
        case .recorder(let id): try c.encode("recorder", forKey: .type); try c.encode(id, forKey: .id)
        }
    }
}

public struct Node: Hashable, Codable, Identifiable {
    public var id: NodeID
    public var kind: NodeKind
    /// Human label, purely cosmetic (the device name at the time it was added).
    public var label: String?

    public init(id: NodeID, kind: NodeKind, label: String? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
    }

    public static let hub = Node(id: Graph.hubID, kind: .hub, label: "Pancake")
    public static let mic = Node(id: Graph.micID, kind: .mic, label: "Pancake Mic")
    public static func output(_ uid: String, label: String? = nil) -> Node { Node(id: NodeID("out:" + uid), kind: .output(deviceUID: uid), label: label) }
    public static func input(_ uid: String, label: String? = nil) -> Node { Node(id: NodeID("in:" + uid), kind: .input(deviceUID: uid), label: label) }
    public static func tap(_ bundleID: String, label: String? = nil) -> Node { Node(id: NodeID("tap:" + bundleID), kind: .tap(bundleID: bundleID), label: label) }
    public static func recorder(id: String = UUID().uuidString, label: String? = nil) -> Node { Node(id: NodeID("rec:" + id), kind: .recorder(id: id), label: label) }
}

public struct Port: Hashable, Codable, CustomStringConvertible {
    public var node: NodeID
    public var channel: Int
    public init(_ node: NodeID, _ channel: Int) {
        self.node = node
        self.channel = channel
    }
    public var description: String { "\(node):\(channel)" }
}

public struct Link: Hashable, Codable, CustomStringConvertible {
    public var from: Port
    public var to: Port
    /// Linear gain. Defaults to unity and is never written by the program — see DESIGN.md.
    public var gain: Float

    public init(from: Port, to: Port, gain: Float = 1) {
        self.from = from
        self.to = to
        self.gain = gain
    }

    private enum CodingKeys: String, CodingKey { case from, to, gain }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(Port.self, forKey: .from)
        to = try c.decode(Port.self, forKey: .to)
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
    }

    public var description: String { "\(from) -> \(to)" + (gain == 1 ? "" : " ×\(gain)") }
}

/// How hard the engine holds a section's selection. Not topology — a change here never rebuilds
/// the aggregate (see `hasSameTopology`), it only changes the engine's follow/pin behaviour.
public struct Policy: Hashable, Codable {
    /// Locked output: don't follow the system default output (no auto-switch to AirPods on connect,
    /// no Control-Center following); pin the chosen device; if it vanishes, stay muted rather than
    /// falling to speakers, and keep asking Bluetooth for it back. Unlocked (default) = follow.
    public var lockOutput: Bool = false
    /// Locked input: pin the *system default input* to the device feeding Pancake Mic, re-asserting
    /// it whenever something (AirPods connecting) tries to steal it — which is what drags Bluetooth
    /// output into low-quality HFP. Unlocked (default) = leave the system default input alone.
    public var lockInput: Bool = false

    public init(lockOutput: Bool = false, lockInput: Bool = false) {
        self.lockOutput = lockOutput
        self.lockInput = lockInput
    }

    // Tolerant of hand-edits: a policy block missing either key just defaults it to false, so
    // `"policy": {"lockInput": true}` in the graph file loads fine.
    private enum CodingKeys: String, CodingKey { case lockOutput, lockInput }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lockOutput = try c.decodeIfPresent(Bool.self, forKey: .lockOutput) ?? false
        lockInput = try c.decodeIfPresent(Bool.self, forKey: .lockInput) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lockOutput, forKey: .lockOutput)
        try c.encode(lockInput, forKey: .lockInput)
    }
}

public struct Graph: Hashable, Codable {
    public static let hubID: NodeID = "hub"
    public static let micID: NodeID = "mic"

    public var nodes: [Node]
    public var links: [Link]
    /// Holding behaviour for the output/input sections. Persisted only when non-default so the
    /// graph file stays clean, and old files without it still load.
    public var policy: Policy

    public init(nodes: [Node] = [.hub], links: [Link] = [], policy: Policy = Policy()) {
        self.nodes = nodes
        self.links = links
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey { case nodes, links, policy }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decode([Node].self, forKey: .nodes)
        links = try c.decode([Link].self, forKey: .links)
        policy = try c.decodeIfPresent(Policy.self, forKey: .policy) ?? Policy()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nodes, forKey: .nodes)
        try c.encode(links, forKey: .links)
        if policy != Policy() { try c.encode(policy, forKey: .policy) }
    }

    /// The simplest useful graph: everything apps play goes to one output device, L→L, R→R.
    public static func stereoOutput(_ uid: String, label: String? = nil) -> Graph {
        var g = Graph()
        g.setOutput(uid: uid, label: label)
        return g
    }

    // MARK: Queries

    public func node(_ id: NodeID) -> Node? { nodes.first { $0.id == id } }

    public func links(from id: NodeID) -> [Link] { links.filter { $0.from.node == id } }
    public func links(to id: NodeID) -> [Link] { links.filter { $0.to.node == id } }

    /// Output devices fed (directly) by the hub, in link order.
    public var hubOutputDeviceUIDs: [String] {
        var seen: [String] = []
        for l in links(from: Graph.hubID) {
            if case .output(let uid)? = node(l.to.node)?.kind, !seen.contains(uid) { seen.append(uid) }
        }
        return seen
    }

    /// Input devices feeding Pancake Mic (directly), in link order.
    public var micInputDeviceUIDs: [String] {
        var seen: [String] = []
        for l in links(to: Graph.micID) {
            if case .input(let uid)? = node(l.from.node)?.kind, !seen.contains(uid) { seen.append(uid) }
        }
        return seen
    }

    /// Every device UID any node references.
    public var referencedDeviceUIDs: Set<String> {
        Set(nodes.compactMap { $0.kind.deviceUID })
    }

    // MARK: Mutation

    public mutating func upsert(_ node: Node) {
        if let i = nodes.firstIndex(where: { $0.id == node.id }) { nodes[i] = node } else { nodes.append(node) }
    }

    public mutating func remove(_ id: NodeID) {
        nodes.removeAll { $0.id == id }
        links.removeAll { $0.from.node == id || $0.to.node == id }
    }

    /// Drops nodes nothing links to or from (except the hub, which is always present).
    public mutating func pruneOrphans() {
        let used = Set(links.flatMap { [$0.from.node, $0.to.node] })
        nodes.removeAll { $0.id != Graph.hubID && !used.contains($0.id) }
    }

    public mutating func connect(_ from: Port, _ to: Port, gain: Float = 1) {
        links.removeAll { $0.from == from && $0.to == to }
        links.append(Link(from: from, to: to, gain: gain))
    }

    /// "Select output device": the hub feeds exactly this output, channel for channel.
    /// This is the fast path's one and only graph mutation.
    public mutating func setOutput(uid: String, channels: Int = 2, label: String? = nil) {
        // Drop the hub's existing links to output devices; leave everything else alone.
        let outputNodeIDs = Set(nodes.filter { if case .output = $0.kind { return true } else { return false } }.map(\.id))
        links.removeAll { $0.from.node == Graph.hubID && outputNodeIDs.contains($0.to.node) }
        upsert(.hub)
        let out = Node.output(uid, label: label)
        upsert(out)
        for ch in 0..<channels {
            links.append(Link(from: Port(Graph.hubID, ch), to: Port(out.id, ch)))
        }
        pruneOrphans()
    }

    /// "Select input device": exactly this physical input feeds Pancake Mic (what apps like
    /// Discord record), channel for channel. A mono source is fanned to both mic channels so it
    /// arrives centred. Mirror of `setOutput`.
    public mutating func setInput(uid: String, channels: Int = 2, label: String? = nil) {
        let inputNodeIDs = Set(nodes.filter { if case .input = $0.kind { return true } else { return false } }.map(\.id))
        links.removeAll { $0.to.node == Graph.micID && inputNodeIDs.contains($0.from.node) }
        upsert(.mic)
        let inp = Node.input(uid, label: label)
        upsert(inp)
        if channels <= 1 {
            links.append(Link(from: Port(inp.id, 0), to: Port(Graph.micID, 0)))
            links.append(Link(from: Port(inp.id, 0), to: Port(Graph.micID, 1)))
        } else {
            for ch in 0..<min(channels, 2) {
                links.append(Link(from: Port(inp.id, ch), to: Port(Graph.micID, ch)))
            }
        }
        pruneOrphans()
    }

    /// Stop feeding Pancake Mic from any physical input (drops the mic node if nothing else needs it).
    public mutating func clearInput() {
        let inputNodeIDs = Set(nodes.filter { if case .input = $0.kind { return true } else { return false } }.map(\.id))
        links.removeAll { $0.to.node == Graph.micID && inputNodeIDs.contains($0.from.node) }
        pruneOrphans()
    }

    // MARK: Process taps (per-app capture → Pancake Mic)

    /// Capture an app's audio (by bundle id, via a process tap) into Pancake Mic. `send` is the
    /// initial mix gain: 0 (default) means tapped but *not* sent to Discord — the "Send DAW"
    /// toggle flips it — and 1 means sent. Stereo tap → mic L/R; it *sums* with the voice already
    /// feeding the mic, so Discord hears both.
    public mutating func setTap(bundleID: String, label: String? = nil, send: Float = 0) {
        upsert(.mic)
        let tap = Node.tap(bundleID, label: label)
        upsert(tap)
        links.removeAll { $0.from.node == tap.id && $0.to.node == Graph.micID }
        links.append(Link(from: Port(tap.id, 0), to: Port(Graph.micID, 0), gain: send))
        links.append(Link(from: Port(tap.id, 1), to: Port(Graph.micID, 1), gain: send))
        pruneOrphans()
    }

    public mutating func clearTap(bundleID: String) {
        remove(Node.tap(bundleID).id)
        pruneOrphans()
    }

    /// Turn a tap's send-to-Discord on/off by setting its mic-link gains (0 or 1). Gain-only, so
    /// the engine hot-swaps the matrix under the running IOProc — no rebuild, no glitch.
    public mutating func setTapSend(bundleID: String, on: Bool) {
        let tapID = Node.tap(bundleID).id
        for i in links.indices where links[i].from.node == tapID && links[i].to.node == Graph.micID {
            links[i].gain = on ? 1 : 0
        }
    }

    /// Bundle ids of the taps feeding Pancake Mic, in link order.
    public var micTapBundleIDs: [String] {
        var seen: [String] = []
        for l in links(to: Graph.micID) {
            if case .tap(let b)? = node(l.from.node)?.kind, !seen.contains(b) { seen.append(b) }
        }
        return seen
    }

    /// Whether a tap is currently sending to Discord (any of its mic links has nonzero gain).
    public func tapSendOn(bundleID: String) -> Bool {
        let tapID = Node.tap(bundleID).id
        return links.contains { $0.from.node == tapID && $0.to.node == Graph.micID && $0.gain > 0 }
    }

    /// True when the two graphs differ in anything other than gains — i.e. the aggregate must be rebuilt.
    public func hasSameTopology(as other: Graph) -> Bool {
        Set(nodes) == Set(other.nodes)
            && Set(links.map { LinkShape($0) }) == Set(other.links.map { LinkShape($0) })
    }

    private struct LinkShape: Hashable {
        let from: Port, to: Port
        init(_ l: Link) { from = l.from; to = l.to }
    }
}
