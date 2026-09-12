import Testing
@testable import PancakeCore

/// ChannelLayout.resolve needs a live aggregate (see `pancake probe-aggregate`); the
/// sequential-attribution logic is exercised through a fake layout in MatrixCompilerTests.
@Suite struct ChannelLayoutTests {
    @Test func slotDescription() {
        #expect("\(ChannelLayout.Slot(buffer: 3, channel: 1))" == "b3c1")
    }
}
