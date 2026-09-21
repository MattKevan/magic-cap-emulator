// SupportPaths.swift — the support-directory layout both apps boot from.
//
// Everything the emulator persists lives under one root: the ROM, NVRAM,
// the core's cfg file, staged packages, and logs. iOS points the root at
// the app container's Documents directory; macOS at Application Support.
import Foundation

/// Filesystem layout of the emulator's support directory.
public struct SupportPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var roms: URL { root.appendingPathComponent("roms", isDirectory: true) }
    public var nvram: URL { root.appendingPathComponent("nvram", isDirectory: true) }
    public var cfg: URL { root.appendingPathComponent("cfg", isDirectory: true) }
    public var packages: URL { root.appendingPathComponent("packages", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    /// The exact image layout `ROMStore` restores first.
    public var canonicalROM: URL {
        roms.appendingPathComponent("datarover840", isDirectory: true)
            .appendingPathComponent("magiccap-usa.image")
    }

    /// Create the directories the emulator writes to. Idempotent.
    public func createDirectories() throws {
        let fm = FileManager.default
        for dir in [roms, nvram, cfg, packages] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
