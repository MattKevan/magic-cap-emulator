// DataRoverApp.swift — app entry: WindowGroup + toolbar + ROM/package import.
//
// Wiring: nvram/cfg/roms/packages directories resolve inside the app
// container. The session boots lazily on first ROM (imported or restored);
// EmulatorSession is a nil-handle state machine (noROM -> ready) so the
// UI shows an empty state instead of a white screen before import.
// ROM/package import uses fileImporter with security-scoped copy into
// the container (start -> copy -> stop pairing per Apple docs).
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let magicCapPackage = UTType(filenameExtension: "pkg", conformingTo: .data)!
    static let magicCapImage = UTType(filenameExtension: "image", conformingTo: .data)!
}

final class ROMStore: ObservableObject {
    @Published var romURL: URL?
    @Published var lastImportError: String?
    let romsDir: URL

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        romsDir = base.appendingPathComponent("roms", isDirectory: true)
        try? FileManager.default.createDirectory(at: romsDir, withIntermediateDirectories: true)
        // Restore: prefer the exact image layout, fall back to any image/zip.
        let fm = FileManager.default
        let exact = romsDir.appendingPathComponent("datarover840/magiccap-usa.image")
        if fm.fileExists(atPath: exact.path) {
            romURL = exact
        } else if let found = ((try? fm.contentsOfDirectory(at: romsDir, includingPropertiesForKeys: nil)) ?? []).first(where: {
            ["image", "zip", "pkg"].contains($0.pathExtension.lowercased())
        }) {
            romURL = found
        }
    }

    func importROM(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            lastImportError = "Could not access the picked file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let destDir = romsDir.appendingPathComponent("datarover840", isDirectory: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = destDir.appendingPathComponent("magiccap-usa.image")
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

@main
struct DataRoverApp: App {
    @StateObject private var romStore = ROMStore()
    @State private var showImporter = false
    @State private var showPackageImporter = false

    var body: some Scene {
        WindowGroup {
            EmulatorRootView(showImporter: $showImporter)
                .environmentObject(romStore)
                .fileImporter(isPresented: $showImporter,
                              allowedContentTypes: [.magicCapImage, .zip, .data],
                              allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        romStore.importROM(url)
                    }
                }
                .fileImporter(isPresented: $showPackageImporter,
                              allowedContentTypes: [.magicCapPackage, .zip, .data],
                              allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        PackageImport.store(url)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("ROM") { showImporter = true }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Package") { showPackageImporter = true }
                    }
                }
        }
    }
}

/// Root view: empty state when no ROM, emulator when imported.
struct EmulatorRootView: View {
    @EnvironmentObject var romStore: ROMStore
    @Binding var showImporter: Bool
    var body: some View {
        if let romURL = romStore.romURL {
            EmulatorContainerView(romURL: romURL)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No ROM imported")
                    .font(.headline)
                Text("Import your MagicCap-USA image to boot the DataRover 840.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Import ROM…") {
                    showImporter = true
                }
                .buttonStyle(.borderedProminent)
                if let error = romStore.lastImportError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding()
        }
    }
}

/// Session-owning container: boots the core once for the given ROM.
struct EmulatorContainerView: View {
    let romURL: URL
    @StateObject private var session: EmulatorSession

    init(romURL: URL) {
        self.romURL = romURL
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let nvram = base.appendingPathComponent("nvram").path
        let cfg = base.appendingPathComponent("cfg").path
        try? FileManager.default.createDirectory(atPath: nvram, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        _session = StateObject(wrappedValue: EmulatorSession(
            nvramDir: nvram, cfgDir: cfg, romPath: romURL.path))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                EmulatorView(session: session)
                TouchPenView(session: session)
            }
            .background(.black)
            // Power/Option need a fork button ABI (see ToolbarView):
            // pass nil so the buttons render disabled, not fake-live.
            ToolbarView(pressPower: nil, pressOption: nil)
        }
    }
}

/// Package import helper: scoped copy into Documents/packages/.
enum PackageImport {
    static func store(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("packages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }
}
