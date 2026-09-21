import DataRoverShell
import SwiftUI

/// Single-finger UITouch -> guest pen. The letterbox math lives in
/// DataRoverKit.GuestGeometry via PenRouter.
struct TouchPenView: UIViewRepresentable {
    var session: EmulatorSession

    func makeCoordinator() -> PenRouter { PenRouter(session: session) }

    func makeUIView(context: Context) -> PenView {
        let view = PenView()
        view.router = context.coordinator
        view.isMultipleTouchEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PenView, context: Context) {}

    final class PenView: UIView {
        weak var router: PenRouter?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            router?.send(.down, point: touch.location(in: self), bounds: bounds)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            router?.send(.move, point: touch.location(in: self), bounds: bounds)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { router?.lift() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { router?.lift() }
    }
}
