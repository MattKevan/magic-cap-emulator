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
        private var penDownAt: TimeInterval?
        private var pendingLift: DispatchWorkItem?
        private let minimumPressDuration: TimeInterval = 0.05

        /// NSView's default origin is bottom-left; GuestGeometry (and the
        /// guest screen) count down from the top, so flip the axis.
        override var isFlipped: Bool { true }

        /// Let the click that activates the window also reach the guest.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            pendingLift?.cancel()
            pendingLift = nil
            penDownAt = ProcessInfo.processInfo.systemUptime
            router?.send(.down, point: convert(event.locationInWindow, from: nil), bounds: bounds)
        }
        override func mouseDragged(with event: NSEvent) {
            router?.send(.move, point: convert(event.locationInWindow, from: nil), bounds: bounds)
        }
        override func mouseUp(with event: NSEvent) {
            let elapsed = penDownAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? minimumPressDuration
            penDownAt = nil

            guard elapsed < minimumPressDuration else {
                router?.lift()
                return
            }

            let lift = DispatchWorkItem { [weak self] in
                self?.router?.lift()
                self?.pendingLift = nil
            }
            pendingLift = lift
            DispatchQueue.main.asyncAfter(deadline: .now() + minimumPressDuration - elapsed, execute: lift)
        }
    }
}
