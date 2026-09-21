import Foundation
import Testing
@testable import DataRoverKit

@Suite struct ROMPinTests {
    @Test func rejectsAMissingFile() {
        #expect(ROMPin.verify(URL(fileURLWithPath: "/nonexistent.image")) == false)
    }

    @Test func acceptsThePinnedImageWhenPresent() throws {
        let pinned = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/DataRover/roms/datarover840/magiccap-usa.image")
        guard FileManager.default.fileExists(atPath: pinned.path) else {
            // Prerequisite: the MagicCap-USA.image fixture in the app's support
            // directory. A machine that has never run the app lacks it, so skip
            // rather than fail the suite.
            return
        }
        #expect(ROMPin.verify(pinned))
    }

    @Test func rejectsAWrongFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try Data("not a rom".utf8).write(to: url)
        #expect(ROMPin.verify(url) == false)
        try? FileManager.default.removeItem(at: url)
    }
}
