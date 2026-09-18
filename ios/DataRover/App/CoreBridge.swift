// CoreBridge.swift — thin Swift wrapper over the 9-function libdatarover
// C ABI. No logic beyond the ABI: string bridging, nullability surfacing,
// and the pen phase dispatch. The machine handle is intentionally opaque
// (UnsafeMutableRawPointer) — lifecycle owned by whoever creates it.
//
// ABI: datarover_create/destroy, datarover_framebuffer_bytes/size,
// datarover_pen_down/move/up, datarover_install_package(_named).
// Declared in CoreBridge.h (bridging header); implemented in
// libDataRoverCore.a.
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
