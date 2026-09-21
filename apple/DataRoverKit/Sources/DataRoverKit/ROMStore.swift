// ROMStore.swift — restore and import the guest ROM image.
import Foundation

/// Owns the ROM the session boots from: restored from the support directory
/// at launch, or copied there from a file the user picks.
@MainActor
public final class ROMStore: ObservableObject {
    @Published public var romURL: URL?
    @Published public var lastImportError: String?
    /// The layout this store reads and writes (the app hands it on to the
    /// session and the shell).
    public let paths: SupportPaths

    public init(paths: SupportPaths) {
        self.paths = paths
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.roms, withIntermediateDirectories: true)
        // Restore: prefer the exact image layout, fall back to any image/zip.
        if fm.fileExists(atPath: paths.canonicalROM.path) {
            romURL = paths.canonicalROM
        } else if let found = ((try? fm.contentsOfDirectory(at: paths.roms, includingPropertiesForKeys: nil)) ?? []).first(where: {
            ["image", "zip", "pkg"].contains($0.pathExtension.lowercased())
        }) {
            romURL = found
        }
    }

    /// Copy a picked ROM to the canonical path and boot from it.
    public func importROM(_ url: URL) {
        importROM(url, verifyPin: false)
    }

    /// As `importROM(_:)`, but `verifyPin` rejects a file whose contents are
    /// not the pinned MagicCap-USA.image.
    public func importROM(_ url: URL, verifyPin: Bool) {
        guard url.startAccessingSecurityScopedResource() else {
            lastImportError = "Could not access the picked file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        if verifyPin, !ROMPin.verify(url) {
            lastImportError = "That file is not the pinned MagicCap-USA.image."
            return
        }
        do {
            let destDir = paths.canonicalROM.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = paths.canonicalROM
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            romURL = dest
            lastImportError = nil
        } catch {
            lastImportError = error.localizedDescription
        }
    }
}
