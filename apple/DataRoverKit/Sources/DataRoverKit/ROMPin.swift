// ROMPin.swift — checksum gate for the supported guest ROM.
//
// The app only claims to support the US DataRover 840 image, so a picked
// file can be checked against the pinned digest before it is copied in.
import CryptoKit
import Foundation

/// The pinned MagicCap-USA.image: the one ROM this app claims to support.
public enum ROMPin {
    public static let sha256 = "94785cb334f14eac00ed200af014c35972b4f25694103bc6a49b3afa280a6f1b"

    /// 1 MiB: the image is 4.5 MB, so this is a handful of reads and never
    /// holds more than a chunk in memory.
    private static let chunkSize = 1 << 20

    /// True when `url` reads to completion and hashes to `sha256`. A missing,
    /// unreadable, or truncated file is false — never a trap.
    public static func verify(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                return false
            }
            // nil is EOF; the loop only ends here once the whole file is in.
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256
    }
}
