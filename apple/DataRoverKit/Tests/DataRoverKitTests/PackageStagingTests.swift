import Foundation
import Testing
@testable import DataRoverKit

@Suite struct PackageStagingTests {
    @Test func copiesAndKeepsBothOnNameCollision() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("DvorakKeyboard.pkg")
        try Data("first".utf8).write(to: src)
        let dest = dir.appendingPathComponent("packages", isDirectory: true)

        let first = try PackageStaging.store(src, into: dest)
        let second = try PackageStaging.store(src, into: dest)

        #expect(first.lastPathComponent == "DvorakKeyboard.pkg")
        #expect(second.lastPathComponent.hasSuffix("DvorakKeyboard.pkg"))
        #expect(second.lastPathComponent != first.lastPathComponent)
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: second) == Data("first".utf8))
        try? FileManager.default.removeItem(at: dir)
    }
}
