import CryptoKit
import Foundation
import Testing
@testable import DataRoverWeb

extension StubbedNetworkTests {
@Suite struct BrowserPackagesTests {
    private let bytes = Data("fake package".utf8)
    private var digest: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func downloader() -> PackageDownloader {
        StubURLProtocol.seen = []
        return PackageDownloader(session: URLSession(configuration: StubURLProtocol.configuration()))
    }

    @Test func listsThePinnedPackagesInInstallOrder() {
        #expect(BrowserPackages.all.map(\.name) == ["EtherLinkIII.pkg", "WebBrowser40.mc2", "MagicJavaScript.pkg"])
        #expect(BrowserPackages.all[1].sha256 == "b401b0f82beff0d945a4eb0361c8cf02aa16ec3fd79a3267edd46248c92bc706")
        #expect(BrowserPackages.all.allSatisfy { $0.url.scheme == "https" && $0.sha256.count == 64 })
    }

    @Test func downloadsAndVerifies() async throws {
        let package = BrowserPackage(name: "Test.pkg", url: URL(string: "https://p.example/Test.pkg")!,
                                     size: bytes.count, sha256: digest)
        StubURLProtocol.replies = [package.url.absoluteString: .response(200, [:], bytes)]
        let dir = try directory()
        let file = try await downloader().ensure(package, in: dir)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(file.lastPathComponent == "Test.pkg")
    }

    @Test func skipsFilesThatAlreadyVerify() async throws {
        let package = BrowserPackage(name: "Test.pkg", url: URL(string: "https://p.example/Test.pkg")!,
                                     size: bytes.count, sha256: digest)
        let dir = try directory()
        try bytes.write(to: dir.appendingPathComponent("Test.pkg"))
        StubURLProtocol.replies = [:]
        _ = try await downloader().ensure(package, in: dir)
        #expect(StubURLProtocol.seen.isEmpty)
    }

    @Test func replacesACorruptExistingFileWithAVerifiedDownload() async throws {
        let package = BrowserPackage(name: "Test.pkg", url: URL(string: "https://p.example/Test.pkg")!,
                                     size: bytes.count, sha256: digest)
        StubURLProtocol.replies = [package.url.absoluteString: .response(200, [:], bytes)]
        let dir = try directory()
        try Data("corrupt".utf8).write(to: dir.appendingPathComponent("Test.pkg"))
        let file = try await downloader().ensure(package, in: dir)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func rejectsAndDeletesMismatches() async throws {
        let package = BrowserPackage(name: "Bad.pkg", url: URL(string: "https://p.example/Bad.pkg")!,
                                     size: 3, sha256: String(repeating: "0", count: 64))
        StubURLProtocol.replies = [package.url.absoluteString: .response(200, [:], Data("bad".utf8))]
        let dir = try directory()
        try Data("stale".utf8).write(to: dir.appendingPathComponent("Bad.pkg"))
        await #expect(throws: PackageDownloadError.checksumMismatch("Bad.pkg")) {
            try await downloader().ensure(package, in: dir)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Bad.pkg").path))
    }

    @Test func reportsDownloadFailures() async throws {
        let package = BrowserPackage(name: "Gone.pkg", url: URL(string: "https://p.example/Gone.pkg")!, size: 1, sha256: digest)
        StubURLProtocol.replies = [package.url.absoluteString: .response(404, [:], Data())]
        await #expect(throws: PackageDownloadError.download("Gone.pkg")) {
            try await downloader().ensure(package, in: try directory())
        }
    }
}
}
