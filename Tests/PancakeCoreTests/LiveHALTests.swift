import Testing
@testable import PancakeCore

/// Runs against the real HAL (Command Line Tools tests have HAL access).
@Suite struct LiveHALTests {
    @Test func translateUIDMatchesEnumeration() {
        for d in AudioDevice.all(includeHidden: true) {
            #expect(AudioDevice.id(forUID: d.uid) == d.id, "translate \(d.uid)")
        }
        #expect(AudioDevice.id(forUID: "definitely-not-a-device") == nil)
    }
}
