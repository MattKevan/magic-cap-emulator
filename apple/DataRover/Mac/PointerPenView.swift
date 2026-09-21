import DataRoverShell
import SwiftUI

/// Left-button drag is a pen stroke; press = down, drag = move, release = up.
struct PointerPenView: NSViewRepresentable {
    var session: EmulatorSession

    func makeCoordinator() -> PenRouter { PenRouter(session: session) }

    func makeNSView(context: Context) -> PenTrackingView {
        let view = PenTrackingView()
        view.router = context.coordinator
        return view
    }

    func updateNSView(_ view: PenTrackingView, context: Context) {}

    final class PenTrackingView: NSView {
        weak var router: PenRouter?

        /// NSView's default origin is bottom-left; GuestGeometry (and the
        /// guest screen) count down from the top, so flip the axis.
        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            router?.send(.down, point: convert(event.locationInWindow, from: nil), bounds: bounds)
        }
        override func mouseDragged(with event: NSEvent) {
            router?.send(.move, point: convert(event.locationInWindow, from: nil), bounds: bounds)
        }
        override func mouseUp(with event: NSEvent) { router?.lift() }
    }
}
