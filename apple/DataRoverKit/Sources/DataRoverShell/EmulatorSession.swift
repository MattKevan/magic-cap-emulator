// EmulatorSession.swift — UI-owned emulator session lifecycle.
//
// The session owns the core handle and is a nil-handle state machine: it
// starts on a detached task (booting), and a nil handle means the ROM could
// not boot, so the UI shows an empty state instead of a white screen.
import DataRoverKit
import Foundation

/// UI-owned session; the C core serializes controls and saves on its worker.
public final class EmulatorSession: ObservableObject {
    public private(set) var handle: UnsafeMutableRawPointer?
    public private(set) var alive = true
    @Published public private(set) var booting = true
    @Published public private(set) var bootError: String?
    @Published public private(set) var isPaused = false
    @Published public private(set) var saveMessage = ""
    @Published public private(set) var installing = false
    @Published public private(set) var installProgress = -1
    @Published public private(set) var packageMessage = ""
    @Published public private(set) var networkMessage = "Network bridge off"
    @Published public private(set) var audioMessage = ""
    /// Platform services the host supplies (see `HostHooks`).
    public let hooks: HostHooks
    private let packagesDir: String
    private var foreground = true
    private var menuVisible = false
    private var proxy: HTTPSProxy?
    private var audioOutput: HostAudioOutput?
    private let networkEnabled: Bool

    public init(nvramDir: String, cfgDir: String, packagesDir: String, romPath: String, hooks: HostHooks) {
        self.packagesDir = packagesDir
        self.hooks = hooks
        networkEnabled = UserDefaults.standard.bool(forKey: "datarover.network.enabled")
        let requestedNetwork = networkEnabled
        Task.detached(priority: .userInitiated) { [weak self] in
            let handle = coreCreate(nvram: nvramDir, cfg: cfgDir, rom: romPath, networkEnabled: requestedNetwork)
            await MainActor.run {
                guard let self else { coreDestroy(handle); return }
                self.handle = handle
                self.alive = handle != nil
                self.bootError = handle == nil ? "Could not start this ROM. Check that it is a DataRover 840 image." : nil
                self.booting = false
                if let handle {
                    coreSetPaused(handle, paused: self.isPaused)
                    self.startHostBridges(handle)
                }
            }
        }
    }

    private func startHostBridges(_ handle: UnsafeMutableRawPointer) {
        audioOutput = HostAudioOutput(handle: handle)
        if !isPaused, audioOutput?.start() == false { audioMessage = "Speaker playback is unavailable" }
        guard networkEnabled else { return }
        switch coreNetworkStatus(handle) {
        case 1: networkMessage = "Guest Ethernet ready; HTTPS proxy on port 8765"
        case -1: networkMessage = "Guest networking could not start"
        default: networkMessage = "Guest networking is starting"
        }
        let proxy = HTTPSProxy()
        proxy.start()
        self.proxy = proxy
    }

    /// A session for platforms that are never suspended mid-save.
    public convenience init(nvramDir: String, cfgDir: String, packagesDir: String, romPath: String) {
        self.init(nvramDir: nvramDir, cfgDir: cfgDir, packagesDir: packagesDir, romPath: romPath,
                  hooks: NoOpHostHooks())
    }

    public func option(_ side: Int, pressed: Bool) {
        guard let handle, !isPaused else { return }
        coreSetOption(handle, side: side, pressed: pressed)
    }

    public func setForeground(_ active: Bool) {
        foreground = active
        updatePause()
        if !active, handle != nil {
            // Leaving the foreground starts a save; the host holds an
            // assertion so the process survives until the core finishes.
            let assertion = hooks.beginSaveAssertion()
            pollSave(assertion: assertion)
        }
    }

    public func setMenuVisible(_ visible: Bool) {
        menuVisible = visible
        updatePause()
        if visible { pollSave() }
    }

    private func updatePause() {
        let paused = !foreground || menuVisible
        guard paused != isPaused else { return }
        isPaused = paused
        if let handle { coreSetPaused(handle, paused: paused) }
        if paused { audioOutput?.stop() } else if audioOutput?.start() == false { audioMessage = "Speaker playback is unavailable" }
    }

    public func saveNow() {
        guard let handle else { return }
        coreRequestSave(handle)
        pollSave()
    }

    private func pollSave(assertion: SaveAssertion? = nil) {
        saveMessage = "Saving…"
        let hooks = self.hooks
        Task { @MainActor [weak self] in
            defer {
                if let assertion { hooks.endSaveAssertion(assertion) }
            }
            for _ in 0..<50 {
                guard let self, let handle = self.handle else { return }
                switch coreSaveStatus(handle) {
                case .saved: self.saveMessage = "State saved"; return
                case .failed: self.saveMessage = "Could not save state. Check available storage."; return
                default: break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.saveMessage = "Save has not finished yet"
        }
    }

    public func restart() {
        guard let handle else { return }
        audioOutput?.stop()
        coreRestart(handle)
        if !isPaused, audioOutput?.start() == false { audioMessage = "Speaker playback is unavailable" }
    }

    /// Keep a copy of the picked package in the support directory, then
    /// install it into the running guest. The handshake is guest-paced and
    /// blocking, so it runs off the main thread; progress is polled for the
    /// UI. The caller must leave the emulator running (not paused behind a
    /// sheet), or the guest never answers the PCLink request.
    public func installPackage(_ url: URL) {
        guard let handle, !installing else { return }
        let name = url.lastPathComponent
        installing = true
        installProgress = 0
        // The guest speaks first, and only once its Storeroom computer is
        // opened, so say what the user has to do on the device.
        packageMessage = "Installing \(name). Open the Storeroom computer on the DataRover to start the transfer."
        let packagesDir = self.packagesDir
        Task.detached(priority: .userInitiated) { [weak self] in
            let data: Data
            do {
                let stored = try PackageStaging.store(url, into: URL(fileURLWithPath: packagesDir))
                data = try Data(contentsOf: stored)
            } catch {
                await MainActor.run { self?.finishInstall(ok: false, name: name) }
                return
            }
            let poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, let handle = self.handle else { return }
                    self.installProgress = coreInstallProgress(handle)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            let ok = coreInstallPackage(handle, data: data, filename: name)
            poll.cancel()
            await MainActor.run { self?.finishInstall(ok: ok, name: name) }
        }
    }

    private func finishInstall(ok: Bool, name: String) {
        installing = false
        installProgress = -1
        packageMessage = ok
            ? "\(name) installed."
            : "The DataRover did not accept \(name). Leave it running on its desk and try again."
    }

    public func clearPackageMessage() {
        packageMessage = ""
    }

    deinit {
        proxy?.stop()
        audioOutput?.stop()
        coreDestroy(handle)
    }
}
