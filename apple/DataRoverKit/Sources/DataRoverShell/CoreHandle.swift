// CoreHandle.swift — C ABI wrappers shared by both app targets.
//
// The C ABI itself is declared in `CDataRoverABI` (a copy of the app's
// bridging header); these wrappers are the Swift-side spelling of it, so
// every call site goes through one place.
import CDataRoverABI
import Foundation

/// Touch phase for the single-finger pen.
public enum PenPhase {
    case down
    case move
    case up
}

/// Create a core handle. Returns nil when the fork returns NULL
/// (boot failure). Caller owns the handle; destroy with `coreDestroy`.
public func coreCreate(nvram: String, cfg: String, rom: String) -> UnsafeMutableRawPointer? {
    datarover_create(nvram, cfg, rom)
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
