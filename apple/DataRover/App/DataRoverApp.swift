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

    var body: some Scene {
        WindowGroup {
            Group {
                if let romURL = romStore.romURL {
                    EmulatorContainerView(romURL: romURL)
                } else {
                    VStack(spacing: 16) {
                        Text("DataRover").font(.largeTitle)
                        Text("Import your Magic Cap ROM to begin.")
                        Button("Import ROM…") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                        if let error = romStore.lastImportError { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .statusBarHidden()
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.magicCapImage, .zip, .data]) { result in
                if case .success(let url) = result { romStore.importROM(url) }
            }
        }
    }
}

struct EmulatorContainerView: View {
    @StateObject private var session: EmulatorSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var showControls = false
    @State private var showPackageImporter = false
    @State private var importMessage: String?

    init(romURL: URL) {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let nvram = base.appendingPathComponent("nvram").path
        let cfg = base.appendingPathComponent("cfg").path
        try? FileManager.default.createDirectory(atPath: nvram, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        _session = StateObject(wrappedValue: EmulatorSession(nvramDir: nvram, cfgDir: cfg, romPath: romURL.path))
    }

    private func requestLandscape() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
    }

    var body: some View {
        DeviceShellView(session: session, openMenu: { showControls = true }) {
            ZStack {
                Color.black
                if session.booting {
                    ProgressView("Starting DataRover…").tint(.white).foregroundStyle(.white)
                } else if let error = session.bootError {
                    Text(error).foregroundStyle(.white).padding()
                } else {
                    EmulatorView(session: session)
                    TouchPenView(session: session)
                }
                if session.installing || !session.packageMessage.isEmpty {
                    InstallStatusBanner(session: session)
                }
            }
        }
        .onAppear {
            session.setForeground(scenePhase == .active)
            requestLandscape()
        }
        .onChange(of: scenePhase) { phase in
            session.setForeground(phase == .active)
            if phase == .active { requestLandscape() }
        }
        .onChange(of: showControls) { visible in session.setMenuVisible(visible) }
        .sheet(isPresented: $showControls) {
            EmulatorControlsSheet(session: session, loadPackage: { showPackageImporter = true })
                .fileImporter(isPresented: $showPackageImporter, allowedContentTypes: [.magicCapPackage, .zip, .data]) { result in
                    do {
                        let url = try result.get()
                        // The guest paces the transfer, so it must be running:
                        // close the sheet, which un-pauses the emulation worker.
                        showControls = false
                        session.installPackage(url)
                    } catch { importMessage = error.localizedDescription }
                }
                .alert("Package", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                    Button("OK") { importMessage = nil }
                } message: { Text(importMessage ?? "") }
        }
    }
}

/// Install progress and result, overlaid on the guest screen. Tap to dismiss
/// a finished message.
struct InstallStatusBanner: View {
    @ObservedObject var session: EmulatorSession

    var body: some View {
        VStack(spacing: 10) {
            if session.installing {
                ProgressView(value: session.installProgress >= 0 ? Double(session.installProgress) / 100 : nil)
                    .progressViewStyle(.linear)
                    .frame(width: 240)
            }
            Text(session.packageMessage)
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        .padding()
        .onTapGesture { if !session.installing { session.clearPackageMessage() } }
        .accessibilityElement(children: .combine)
    }
}

enum PackageImport {
    static func store(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("packages", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}
