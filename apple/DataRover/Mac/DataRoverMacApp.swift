// DataRoverMacApp.swift — macOS entry: window, menu bar, settings.
//
// The same composition as the iOS container — shared device shell, session,
// controls sheet — with a pointer pen overlay, a menu bar in place of the
// sheet-only chrome, and no orientation or status-bar handling.
import AppKit
import DataRoverKit
import DataRoverShell
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let magicCapPackage = UTType(filenameExtension: "pkg", conformingTo: .data)!
    static let magicCapImage = UTType(filenameExtension: "image", conformingTo: .data)!
}

/// Open panel for the ROM and package commands; the sandbox grants access to
/// the picked file through the user-selected read-write entitlement.
func chooseFile(type: UTType) -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [type]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
}

/// What the menu bar needs from the window: the running session and the
/// app-level pause flag. The window owns both; the menu bar only reads them.
struct EmulatorMenuContext {
    let session: EmulatorSession
    let paused: Binding<Bool>
}

private struct EmulatorMenuContextKey: FocusedValueKey {
    typealias Value = EmulatorMenuContext
}

extension FocusedValues {
    var emulatorMenu: EmulatorMenuContext? {
        get { self[EmulatorMenuContextKey.self] }
        set { self[EmulatorMenuContextKey.self] = newValue }
    }
}

@main
struct DataRoverMacApp: App {
    @StateObject private var romStore: ROMStore
    @State private var installPackageRequest = false

    init() {
        let paths = (try? macOSSupportPaths()) ?? SupportPaths(root: FileManager.default.temporaryDirectory)
        _romStore = StateObject(wrappedValue: ROMStore(paths: paths))
    }

    var body: some Scene {
        WindowGroup("DataRover") {
            Group {
                if let romURL = romStore.romURL {
                    EmulatorWindowView(romURL: romURL, paths: romStore.paths,
                                       installPackageRequest: $installPackageRequest)
                } else {
                    VStack(spacing: 16) {
                        Text("DataRover").font(.largeTitle)
                        Text("Import your Magic Cap ROM to begin.")
                        Button("Import ROM…") { importROM() }.buttonStyle(.borderedProminent)
                        if let error = romStore.lastImportError {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                    .frame(minWidth: 480, minHeight: 320)
                }
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import ROM…") { importROM() }
                Button("Install Package…") { installPackageRequest = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(romStore.romURL == nil)
                EmulatorFileCommands()
            }
            CommandGroup(after: .toolbar) {
                EmulatorPauseCommand()
            }
        }
        Settings { SettingsView(paths: romStore.paths) }
    }

    private func importROM() {
        guard let url = chooseFile(type: .magicCapImage) else { return }
        romStore.importROM(url, verifyPin: true)   // the launcher's pinned-image contract
    }
}

/// File-menu items that act on the running session, which reaches the menu
/// bar through the window's focused scene value.
private struct EmulatorFileCommands: View {
    @FocusedValue(\.emulatorMenu) private var menu

    var body: some View {
        Button("Save State") {
            guard let menu = menu else { return }
            menu.session.saveNow()
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(menu == nil)
        Button("Restart") {
            guard let menu = menu else { return }
            menu.session.restart()
        }
        .disabled(menu == nil)
    }
}

/// View-menu item. The shell's one pause lever is "the menu is up", so the
/// menu bar raises that same flag rather than reaching around the session.
private struct EmulatorPauseCommand: View {
    @FocusedValue(\.emulatorMenu) private var menu

    var body: some View {
        Button(menu?.paused.wrappedValue == true ? "Resume" : "Pause") {
            guard let menu = menu else { return }
            menu.paused.wrappedValue.toggle()
        }
        .disabled(menu == nil)
    }
}

/// The macOS analogue of the iOS `EmulatorContainerView`: the shared device
/// shell around the guest screen, the pointer overlay, the controls sheet,
/// the physical ⌥-key Option mapping, and the quit-time save.
struct EmulatorWindowView: View {
    @StateObject private var session: EmulatorSession
    @Binding private var installPackageRequest: Bool
    @State private var showControls = false
    @State private var paused = false
    @State private var optionMonitor: Any?

    init(romURL: URL, paths: SupportPaths, installPackageRequest: Binding<Bool>) {
        _installPackageRequest = installPackageRequest
        _session = StateObject(wrappedValue: EmulatorSession(
            nvramDir: paths.nvram.path,
            cfgDir: paths.cfg.path,
            packagesDir: paths.packages.path,
            romPath: romURL.path,
            hooks: MacHostHooks()))
    }

    var body: some View {
        DeviceShellView(session: session, openMenu: { showControls = true }) {
            EmulatorBody(session: session,
                         framebuffer: { MetalFramebufferView(session: session) },
                         overlay: { PointerPenView(session: session) })
        }
        .focusedSceneValue(\.emulatorMenu,
                           EmulatorMenuContext(session: session, paused: $paused))
        .onChange(of: showControls) { _, _ in updatePause() }
        .onChange(of: paused) { _, _ in updatePause() }
        .onChange(of: installPackageRequest) { _, requested in
            guard requested else { return }
            installPackageRequest = false
            choosePackage()
        }
        .sheet(isPresented: $showControls) {
            EmulatorControlsSheet(session: session, loadPackage: loadPackage)
        }
        .onAppear { optionMonitor = installOptionKeyMonitor() }
        .onDisappear {
            if let optionMonitor { NSEvent.removeMonitor(optionMonitor) }
            optionMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // Quitting is this platform's "leaving the app": the session's
            // foreground path saves the checkpoint through MacHostHooks.
            session.setForeground(false)
        }
    }

    /// The controls sheet and the View menu item both pause the guest, and
    /// the shell's only public lever for that is its menu-visible flag.
    private func updatePause() {
        session.setMenuVisible(showControls || paused)
    }

    /// The guest paces the transfer, so it has to be running: close the sheet
    /// (which un-pauses the emulation worker) before the panel opens.
    private func loadPackage() {
        showControls = false
        DispatchQueue.main.async { choosePackage() }
    }

    private func choosePackage() {
        showControls = false
        guard let url = chooseFile(type: .magicCapPackage) else { return }
        session.installPackage(url)
    }

    /// The physical left/right ⌥ keys are the guest's two Option buttons;
    /// macOS reports the sides as separate key codes (58 = left, 61 = right).
    private func installOptionKeyMonitor() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let down = event.modifierFlags.contains(.option)
            switch event.keyCode {
            case 58: session.option(0, pressed: down)
            case 61: session.option(1, pressed: down)
            default: break
            }
            return event
        }
    }
}

/// Settings scene: where the app keeps its state, and a way there.
struct SettingsView: View {
    let paths: SupportPaths

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Support folder").font(.headline)
            Text(paths.root.path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([paths.root])
            }
        }
        .padding(20)
        .frame(minWidth: 460, alignment: .leading)
    }
}
