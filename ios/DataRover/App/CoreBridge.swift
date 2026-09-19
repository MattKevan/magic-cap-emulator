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

import UIKit

/// UI-owned session; the C core serializes controls and saves on its worker.
final class EmulatorSession: ObservableObject {
    private(set) var handle: UnsafeMutableRawPointer?
    private(set) var alive = true
    @Published private(set) var booting = true
    @Published private(set) var bootError: String?
    @Published private(set) var isPaused = false
    @Published private(set) var saveMessage = ""
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

    deinit { coreDestroy(handle) }
}
