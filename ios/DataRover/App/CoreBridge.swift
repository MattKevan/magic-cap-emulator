// C ABI wrappers and UI-owned emulator session lifecycle.
import Foundation

/// Touch phase for the single-finger pen.
enum PenPhase {
    case down
    case move
    case up
}

/// Create a core handle. Returns nil when the fork returns NULL
/// (boot failure). Caller owns the handle; destroy with `coreDestroy`.
func coreCreate(nvram: String, cfg: String, rom: String) -> UnsafeMutableRawPointer? {
    datarover_create(nvram, cfg, rom)
}

/// Destroy a handle created by `coreCreate`. Safe to call with nil.
func coreDestroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    datarover_destroy(handle)
}

/// Framebuffer access. `bytes` is nil pre-boot or for non-RAM-backed
/// mappings — the caller must null-check and skip the frame.
func coreFramebuffer(of handle: UnsafeMutableRawPointer) -> (bytes: UnsafePointer<UInt8>?, size: Int) {
    (datarover_framebuffer_bytes(handle), datarover_framebuffer_size())
}

/// Single-finger pen event. Clamping to the 480x320 guest grid is the
/// caller's job; the core clamps defensively as well.
func corePen(_ handle: UnsafeMutableRawPointer, phase: PenPhase, x: Int, y: Int) {
    switch phase {
    case .down:
        datarover_pen_down(handle, Int32(x), Int32(y))
    case .move:
        datarover_pen_move(handle, Int32(x), Int32(y))
    case .up:
        datarover_pen_up(handle)
    }
}

/// Install a Magic Cap package into the running guest over the in-process
/// PCLink channel. Blocking for the whole handshake — the guest paces the
/// transfer — so callers must run it off the main thread. Returns true when
/// the guest confirmed with its final reply.
func coreInstallPackage(_ handle: UnsafeMutableRawPointer, data: Data, filename: String) -> Bool {
    guard !data.isEmpty else { return false }
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
        return filename.withCString { name in
            datarover_install_package_named(handle, base, data.count, name) == 0
        }
    }
}

/// Progress of an install running on another thread: 0-100, or -1 when none.
func coreInstallProgress(_ handle: UnsafeMutableRawPointer) -> Int {
    Int(datarover_install_progress(handle))
}

import UIKit

/// UI-owned session; the C core serializes controls and saves on its worker.
final class EmulatorSession: ObservableObject {
    private(set) var handle: UnsafeMutableRawPointer?
    private(set) var alive = true
    @Published private(set) var booting = true
    @Published private(set) var bootError: String?
    @Published private(set) var isPaused = false
    @Published private(set) var saveMessage = ""
    @Published private(set) var installing = false
    @Published private(set) var installProgress = -1
    @Published private(set) var packageMessage = ""
    private var foreground = true
    private var menuVisible = false

    init(nvramDir: String, cfgDir: String, romPath: String) {
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

    func option(_ side: Int, pressed: Bool) {
        guard let handle, !isPaused else { return }
        datarover_set_option(handle, Int32(side), pressed ? 1 : 0)
    }

    func setForeground(_ active: Bool) {
        foreground = active
        updatePause()
        if !active, handle != nil {
            let task = UIApplication.shared.beginBackgroundTask(withName: "Save DataRover", expirationHandler: nil)
            pollSave(backgroundTask: task)
        }
    }

    func setMenuVisible(_ visible: Bool) {
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

    func saveNow() {
        guard let handle else { return }
        datarover_request_save(handle)
        pollSave()
    }

    private func pollSave(backgroundTask: UIBackgroundTaskIdentifier = .invalid) {
        saveMessage = "Saving…"
        Task { @MainActor [weak self] in
            defer {
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
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

    func restart() {
        guard let handle else { return }
        datarover_request_save(handle)
        datarover_restart(handle)
    }

    /// Keep a copy of the picked package in the container, then install it into
    /// the running guest. The handshake is guest-paced and blocking, so it runs
    /// off the main thread; progress is polled for the UI. The caller must leave
    /// the emulator running (not paused behind a sheet), or the guest never
    /// answers the PCLink request.
    func installPackage(_ url: URL) {
        guard let handle, !installing else { return }
        let name = url.lastPathComponent
        installing = true
        installProgress = 0
        packageMessage = "Installing \(name)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let data: Data
            do {
                let stored = try PackageImport.store(url)
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

    func clearPackageMessage() {
        packageMessage = ""
    }

    deinit { coreDestroy(handle) }
}
