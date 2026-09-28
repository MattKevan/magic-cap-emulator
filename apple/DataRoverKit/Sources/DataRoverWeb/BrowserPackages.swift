import CryptoKit
import Foundation

public struct BrowserPackage: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let size: Int
    public let sha256: String
    public init(name: String, url: URL, size: Int, sha256: String) {
        self.name = name; self.url = url; self.size = size; self.sha256 = sha256
    }
}

/// Web Browser 4.0 and what it needs, fetched from their original host.
public enum BrowserPackages {
    public static let all: [BrowserPackage] = [
        BrowserPackage(name: "EtherLinkIII.pkg",
                       url: URL(string: "https://joshcarter.com/magic_cap/packages/EtherLinkIII.pkg")!, size: 65_624,
                       sha256: "c0b23f24a91e7b03f4adf1a356dc4356f4091284a424119bbdd9d89f72279b34"),
        BrowserPackage(name: "WebBrowser40.mc2",
                       url: URL(string: "https://joshcarter.com/magic_cap/packages/WebBrowser40.mc2")!, size: 508_892,
                       sha256: "b401b0f82beff0d945a4eb0361c8cf02aa16ec3fd79a3267edd46248c92bc706"),
        BrowserPackage(name: "MagicJavaScript.pkg",
                       url: URL(string: "https://joshcarter.com/magic_cap/packages/MagicJavaScript.pkg")!, size: 467_876,
                       sha256: "beb0de0cdb51207534c280c88402ec11972dd7dfce11cd08514adc92c2f6f406"),
    ]
}

public enum PackageDownloadError: Error, Equatable {
    case download(String)
    case checksumMismatch(String)
}

public struct PackageDownloader: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// The verified file in `directory`, downloading it only if needed.
    public func ensure(_ package: BrowserPackage, in directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(package.name)
        if let existing = try? Data(contentsOf: destination), Self.digest(existing) == package.sha256 {
            return destination
        }
        let data: Data
        do {
            let (body, response) = try await session.data(from: package.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PackageDownloadError.download(package.name) }
            data = body
        } catch let error as PackageDownloadError {
            throw error
        } catch {
            throw PackageDownloadError.download(package.name)
        }
        guard Self.digest(data) == package.sha256 else {
            try? FileManager.default.removeItem(at: destination)
            throw PackageDownloadError.checksumMismatch(package.name)
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
