import Foundation
import Testing
@testable import DataRoverKit

@Suite struct SupportPathsTests {
    @Test func layoutMatchesTheContainerContract() {
        let paths = SupportPaths(root: URL(fileURLWithPath: "/tmp/root"))
        #expect(paths.nvram.path == "/tmp/root/nvram")
        #expect(paths.cfg.path == "/tmp/root/cfg")
        #expect(paths.packages.path == "/tmp/root/packages")
        #expect(paths.canonicalROM.path == "/tmp/root/roms/datarover840/magiccap-usa.image")
    }

    @Test func createDirectoriesIsIdempotent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let paths = SupportPaths(root: root)
        try paths.createDirectories()
        try paths.createDirectories()
        #expect(FileManager.default.fileExists(atPath: paths.nvram.path))
        #expect(FileManager.default.fileExists(atPath: paths.packages.path))
        try? FileManager.default.removeItem(at: root)
    }
}
