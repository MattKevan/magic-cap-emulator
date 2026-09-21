import Foundation
import Testing
@testable import DataRoverKit

@MainActor
@Suite struct ROMStoreTests {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func prefersTheExactImageLayout() throws {
        let root = try makeRoot()
        let paths = SupportPaths(root: root)
        try paths.createDirectories()
        try FileManager.default.createDirectory(at: paths.canonicalROM.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data("exact".utf8).write(to: paths.canonicalROM)
        try Data("other".utf8).write(to: paths.roms.appendingPathComponent("other.image"))
        #expect(ROMStore(paths: paths).romURL?.lastPathComponent == "magiccap-usa.image")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func fallsBackToAnyImage() throws {
        let root = try makeRoot()
        let paths = SupportPaths(root: root)
        try paths.createDirectories()
        try Data("other".utf8).write(to: paths.roms.appendingPathComponent("other.image"))
        #expect(ROMStore(paths: paths).romURL?.lastPathComponent == "other.image")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func importsIntoTheCanonicalPath() throws {
        let root = try makeRoot()
        let paths = SupportPaths(root: root)
        let store = ROMStore(paths: paths)
        let src = root.appendingPathComponent("picked.image")
        try Data("picked".utf8).write(to: src)
        store.importROM(src)
        #expect(store.romURL?.path == paths.canonicalROM.path)
        #expect(try Data(contentsOf: paths.canonicalROM) == Data("picked".utf8))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func rejectsAFileThatFailsThePinCheck() throws {
        let root = try makeRoot()
        let paths = SupportPaths(root: root)
        let store = ROMStore(paths: paths)
        let src = root.appendingPathComponent("bogus.image")
        try Data("not the pinned image".utf8).write(to: src)
        store.importROM(src, verifyPin: true)
        #expect(store.romURL == nil)
        #expect(store.lastImportError != nil)
        #expect(FileManager.default.fileExists(atPath: paths.canonicalROM.path) == false)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func reportsAMissingSource() throws {
        let root = try makeRoot()
        let store = ROMStore(paths: SupportPaths(root: root))
        store.importROM(root.appendingPathComponent("absent.image"))
        #expect(store.romURL == nil)
        #expect(store.lastImportError != nil)
        try? FileManager.default.removeItem(at: root)
    }
}
