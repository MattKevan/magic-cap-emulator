import DataRoverShell
import SwiftUI

/// Left-button drag is a pen stroke; press = down, drag = move, release = up.
struct PointerPenView: NSViewRepresentable {
    var session: EmulatorSession

    func makeCoordinator() -> PenRouter { PenRouter(session: session) }

    func makeNSView(context: Context) -> PenTrackingView {
        let view = PenTrackingView()
        view.router = context.coordinator
        view.session = session
        return view
    }

    func updateNSView(_ view: PenTrackingView, context: Context) {}

    final class PenTrackingView: NSView {
        weak var router: PenRouter?
        weak var session: EmulatorSession?
        private var penDownAt: TimeInterval?
        private var pendingLift: DispatchWorkItem?
        private let minimumPressDuration: TimeInterval = 0.05

        /// NSView's default origin is bottom-left; GuestGeometry (and the
        /// guest screen) count down from the top, so flip the axis.
        override var isFlipped: Bool { true }

        /// Let the click that activates the window also reach the guest.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Match the old MAME shell: leave the pointer free and visible, but
        /// replace the arrow with its small circular stylus over the display.
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: Self.stylusCursor)
        }

        private static let stylusCursor: NSCursor = {
            let size = NSSize(width: 16, height: 16)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.black.setStroke()
            let outer = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14))
            outer.lineWidth = 3
            outer.stroke()
            NSColor.white.setStroke()
            let inner = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12))
            inner.lineWidth = 1.5
            inner.stroke()
            image.unlockFocus()
            return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
        }()

        override func mouseDown(with event: NSEvent) {
            pendingLift?.cancel()
            pendingLift = nil
            penDownAt = ProcessInfo.processInfo.systemUptime
            let point = convert(event.locationInWindow, from: nil)
            let mapped = router?.send(.down, point: point, bounds: bounds)
            let paused = session?.isPaused ?? true
            let active = session?.handle.map { coreFramebuffer(of: $0).bytes != nil } ?? false
            NSLog("[DataRover input] mouseDown host=(%.1f, %.1f) view=%@ result=%@ paused=%@ active=%@",
                  point.x, point.y, NSStringFromRect(bounds),
                  String(describing: mapped ?? .noSession), paused ? "yes" : "no",
                  active ? "yes" : "no")
        }
        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            router?.send(.move, point: point, bounds: bounds)
        }
        override func mouseUp(with event: NSEvent) {
            let elapsed = penDownAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? minimumPressDuration
            penDownAt = nil

            guard elapsed < minimumPressDuration else {
                router?.lift()
                NSLog("[DataRover input] mouseUp; pen lifted")
                return
            }

            let lift = DispatchWorkItem { [weak self] in
                self?.router?.lift()
                self?.pendingLift = nil
                NSLog("[DataRover input] short click; pen lifted after minimum press")
            }
            pendingLift = lift
            DispatchQueue.main.asyncAfter(deadline: .now() + minimumPressDuration - elapsed, execute: lift)
        }
    }
}
