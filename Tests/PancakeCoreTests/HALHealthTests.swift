import Testing
@testable import PancakeCore

@Suite struct HALHealthTests {
    @Test func healthyPlugInListHasNoDuplicates() {
        let list = ["com.apple.audio.CoreAudio", "com.apple.AirPlayXPCHelper", "com.pancake.driver"]
        #expect(HALHealth.duplicatePlugIns(in: list).isEmpty)
        #expect(HALHealth.describe([:]) == nil)
    }

    /// The 2026-09-13 shape: AirPlayXPCHelper registered 32 times after five coreaudiod restarts.
    @Test func airPlayLeakIsReportedWithItsCount() {
        let list = ["com.apple.audio.CoreAudio"] + Array(repeating: "com.apple.AirPlayXPCHelper", count: 32) + ["com.pancake.driver"]
        let dupes = HALHealth.duplicatePlugIns(in: list)
        #expect(dupes == ["com.apple.AirPlayXPCHelper": 32])
        let text = HALHealth.describe(dupes) ?? ""
        #expect(text.contains("com.apple.AirPlayXPCHelper ×32"))
        #expect(text.contains(HALHealth.resetCommand))
    }
}

@Suite struct RebuildTimingTests {
    /// A lone request waits the normal debounce.
    @Test func singleRequestWaitsTheDebounce() {
        #expect(Engine.rebuildFireDelay(sinceWindowStart: 0, requested: 0.35, explicit: false, maxLatency: 2) == 0.35)
    }

    /// A continuous burst (a request every 150 ms) must still fire within the max latency — the
    /// starvation seen after a coreaudiod restart, when a pure debounce postponed the rebuild for a minute.
    @Test func burstCannotStarveTheRebuild() {
        var t = 0.0
        var firesAt = Double.infinity
        while t < 60 {
            let d = Engine.rebuildFireDelay(sinceWindowStart: t, requested: 0.35, explicit: false, maxLatency: 2)
            firesAt = t + d
            if firesAt <= t + 0.15 { break }   // it fires before the next request in the burst arrives
            t += 0.15
        }
        #expect(firesAt <= 2.0 + 1e-9, "fired at \(firesAt)s")
    }

    /// An explicit delay (a Bluetooth device settling) is a hard minimum, never shortened.
    @Test func explicitDelayIsHonoured() {
        #expect(Engine.rebuildFireDelay(sinceWindowStart: 1.9, requested: 2.5, explicit: true, maxLatency: 2) == 2.5)
    }
}
