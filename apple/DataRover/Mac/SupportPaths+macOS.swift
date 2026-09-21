// The sandboxed app keeps its state inside its own container. The old
// unsandboxed bundle used ~/Library/Application Support/DataRover, which a
// sandboxed process cannot see at all — hence a fresh boot here.
import DataRoverKit
import Foundation

func macOSSupportPaths() throws -> SupportPaths {
    let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil, create: true)
    let root = base.appendingPathComponent("DataRover", isDirectory: true)
    let paths = SupportPaths(root: root)
    try paths.createDirectories()
    return paths
}
