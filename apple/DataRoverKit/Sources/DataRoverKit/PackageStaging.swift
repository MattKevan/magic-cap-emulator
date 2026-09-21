// PackageStaging.swift — keep a copy of an imported package on disk.
//
// The guest reads the package bytes from the emulator's own support
// directory, so an imported file is copied there first. The picked file is
// only security-scoped for the duration of this call.
import Foundation

public enum PackageStaging {
    /// Copy `url` into `packagesDir`, keeping both files when the name is
    /// already taken. Returns the copy's URL.
    public static func store(_ url: URL, into packagesDir: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: packagesDir, withIntermediateDirectories: true)
        var dest = packagesDir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = packagesDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}
