// DataRoverApp.swift — iOS entry: platform root, ROM import, device shell.
import DataRoverKit
import DataRoverShell
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let magicCapPackage = UTType(filenameExtension: "pkg", conformingTo: .data)!
    static let magicCapImage = UTType(filenameExtension: "image", conformingTo: .data)!
}

/// iOS keeps the app container's Documents directory as its support root.
func iOSSupportPaths() -> SupportPaths {
    let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return SupportPaths(root: base)
}

@main
struct DataRoverApp: App {
    @StateObject private var romStore = ROMStore(paths: iOSSupportPaths())
    @State private var showImporter = false

    var body: some Scene {
        WindowGroup {
            Group {
                if let romURL = romStore.romURL {
                    EmulatorContainerView(romURL: romURL, paths: romStore.paths)
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
    private let paths: SupportPaths

    init(romURL: URL, paths: SupportPaths) {
        self.paths = paths
        try? paths.createDirectories()
        _session = StateObject(wrappedValue: EmulatorSession(
            nvramDir: paths.nvram.path,
            cfgDir: paths.cfg.path,
            packagesDir: paths.packages.path,
            romPath: romURL.path,
            hooks: iOSHostHooks()))
    }

    private func requestLandscape() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
    }

    var body: some View {
        DeviceShellView(session: session, openMenu: { showControls = true }) {
            EmulatorBody(session: session,
                         framebuffer: { MetalFramebufferView(session: session) },
                         overlay: { TouchPenView(session: session) })
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
                .fileImporter(isPresented: $showPackageImporter,
                              allowedContentTypes: [.magicCapPackage, .zip, .data]) { result in
                    do {
                        let url = try result.get()
                        // The guest paces the transfer, so it must be running:
                        // close the sheet, which un-pauses the emulation worker.
                        showControls = false
                        session.installPackage(url)
                    } catch { importMessage = error.localizedDescription }
                }
                .alert("Package", isPresented: Binding(get: { importMessage != nil },
                                                       set: { if !$0 { importMessage = nil } })) {
                    Button("OK") { importMessage = nil }
                } message: { Text(importMessage ?? "") }
        }
    }
}
