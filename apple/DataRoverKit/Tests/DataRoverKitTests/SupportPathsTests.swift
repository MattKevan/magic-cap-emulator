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
        for dir in [paths.roms, paths.nvram, paths.cfg, paths.packages] {
            #expect(FileManager.default.fileExists(atPath: dir.path))
        }
        try? FileManager.default.removeItem(at: root)
    }
}
