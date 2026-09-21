import Testing
@testable import DataRoverKit

@Suite struct SaveStateTests {
    @Test func decodesTheABIContract() {
        #expect(SaveState.decode(0) == .idle)
        #expect(SaveState.decode(1) == .pending)
        #expect(SaveState.decode(2) == .saved)
        #expect(SaveState.decode(-1) == .failed)
        #expect(SaveState.decode(99) == .failed)
    }
}
