// CoreHandle.swift — C ABI wrappers shared by both app targets.
//
// The C ABI itself is declared in `CDataRoverABI` (a copy of the app's
// bridging header); these wrappers are the Swift-side spelling of it, so
// every call site goes through one place.
import CDataRoverABI
import DataRoverKit
import Foundation

/// Touch phase for the single-finger pen.
public enum PenPhase {
    case down
    case move
    case up
}

/// Create a core handle. Returns nil when the fork returns NULL
/// (boot failure). Caller owns the handle; destroy with `coreDestroy`.
public func coreCreate(nvram: String, cfg: String, rom: String, networkEnabled: Bool) -> UnsafeMutableRawPointer? {
    var options = datarover_create_options(
        struct_size: UInt32(MemoryLayout<datarover_create_options>.size),
        network_enabled: networkEnabled ? 1 : 0,
        audio_output_enabled: 1
    )
    return withUnsafePointer(to: &options) { optionsPointer in
        datarover_create_with_options(nvram, cfg, rom, optionsPointer)
    }
}

/// Destroy a handle created by `coreCreate`. Safe to call with nil.
public func coreDestroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    datarover_destroy(handle)
}

/// Framebuffer access. `bytes` is nil pre-boot or for non-RAM-backed
/// mappings — the caller must null-check and skip the frame.
public func coreFramebuffer(of handle: UnsafeMutableRawPointer) -> (bytes: UnsafePointer<UInt8>?, size: Int) {
    (datarover_framebuffer_bytes(handle), datarover_framebuffer_size())
}

/// Single-finger pen event. Clamping to the 480x320 guest grid is the
/// caller's job; the core clamps defensively as well.
public func corePen(_ handle: UnsafeMutableRawPointer, phase: PenPhase, x: Int, y: Int) {
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
public func coreInstallPackage(_ handle: UnsafeMutableRawPointer, data: Data, filename: String) -> Bool {
    guard !data.isEmpty else { return false }
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
        return filename.withCString { name in
            datarover_install_package_named(handle, base, data.count, name) == 0
        }
    }
}

/// Progress of an install running on another thread: 0-100, or -1 when none.
public func coreInstallProgress(_ handle: UnsafeMutableRawPointer) -> Int {
    Int(datarover_install_progress(handle))
}

/// Option input; the core applies it on its worker.
public func coreSetOption(_ handle: UnsafeMutableRawPointer, side: Int, pressed: Bool) {
    datarover_set_option(handle, Int32(side), pressed ? 1 : 0)
}

/// Pause or resume the emulation worker.
public func coreSetPaused(_ handle: UnsafeMutableRawPointer, paused: Bool) {
    datarover_set_paused(handle, paused ? 1 : 0)
}

/// Ask the core to checkpoint its state. Poll with `coreSaveStatus`.
public func coreRequestSave(_ handle: UnsafeMutableRawPointer) {
    datarover_request_save(handle)
}

/// Status of the last checkpoint request, as the ABI's 0/1/2/-1 contract.
public func coreSaveStatus(_ handle: UnsafeMutableRawPointer) -> SaveState {
    SaveState.decode(Int32(datarover_save_status(handle)))
}

/// Reboot the guest in place.
public func coreRestart(_ handle: UnsafeMutableRawPointer) {
    datarover_restart(handle)
}

/// Counter the core bumps per rendered guest frame; the presenter skips a
/// draw whose revision it has already shown.
public func coreFrameRevision(_ handle: UnsafeMutableRawPointer) -> UInt64 {
    datarover_frame_revision(handle)
}

/// Current host network backend status: 0 disabled, 1 ready, -1 unavailable.
public func coreNetworkStatus(_ handle: UnsafeMutableRawPointer) -> Int {
    Int(datarover_network_status(handle))
}

/// Pull mono signed PCM frames from the bounded core queue without blocking.
public func coreAudioRead(_ handle: UnsafeMutableRawPointer, into samples: UnsafeMutablePointer<Int16>, capacity: Int) -> Int {
    Int(datarover_audio_read(handle, samples, capacity))
}

/// Discard queued guest sound after audio output has stopped.
public func coreAudioClear(_ handle: UnsafeMutableRawPointer) {
    datarover_audio_clear(handle)
}
