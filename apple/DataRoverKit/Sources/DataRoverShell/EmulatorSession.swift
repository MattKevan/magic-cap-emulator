// EmulatorSession.swift — UI-owned emulator session lifecycle.
//
// The session owns the core handle and is a nil-handle state machine: it
// starts on a detached task (booting), and a nil handle means the ROM could
// not boot, so the UI shows an empty state instead of a white screen.
import CDataRoverABI
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
    /// Platform services the host supplies (see `HostHooks`).
    public let hooks: HostHooks
    private let packagesDir: String
    private var foreground = true
    private var menuVisible = false

    public init(nvramDir: String, cfgDir: String, packagesDir: String, romPath: String, hooks: HostHooks) {
        self.packagesDir = packagesDir
        self.hooks = hooks
        Task.detached(priority: .userInitiated) { [weak self] in
            let handle = coreCreate(nvram: nvramDir, cfg: cfgDir, rom: romPath)
            await MainActor.run {
                guard let self else { coreDestroy(handle); return }
                self.handle = handle
                self.alive = handle != nil
                self.bootError = handle == nil ? "Could not start this ROM. Check that it is a DataRover 840 image." : nil
                self.booting = false
                if let handle { datarover_set_paused(handle, self.isPaused ? 1 : 0) }
            }
        }
    }

    /// A session for platforms that are never suspended mid-save.
    public convenience init(nvramDir: String, cfgDir: String, packagesDir: String, romPath: String) {
        self.init(nvramDir: nvramDir, cfgDir: cfgDir, packagesDir: packagesDir, romPath: romPath,
                  hooks: NoOpHostHooks())
    }

    public func option(_ side: Int, pressed: Bool) {
        guard let handle, !isPaused else { return }
        datarover_set_option(handle, Int32(side), pressed ? 1 : 0)
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
        if let handle { datarover_set_paused(handle, paused ? 1 : 0) }
    }

    public func saveNow() {
        guard let handle else { return }
        datarover_request_save(handle)
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
                switch datarover_save_status(handle) {
                case 2: self.saveMessage = "State saved"; return
                case -1: self.saveMessage = "Could not save state. Check available storage."; return
                default: break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.saveMessage = "Save has not finished yet"
        }
    }

    public func restart() {
        guard let handle else { return }
        datarover_request_save(handle)
        datarover_restart(handle)
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

    deinit { coreDestroy(handle) }
}
