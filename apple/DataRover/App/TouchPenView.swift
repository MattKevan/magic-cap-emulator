// TouchPenView.swift — single-finger UITouch -> guest pen coordinates.
//
// Mapping: x = touch.x / width * 479, y = touch.y / height * 319, clamped
// to [0,479] / [0,319]. Touch locations arrive in the view's point space;
// the host wraps EmulatorView aspect-fit, so the letterbox offset must be
// removed first: the guest image occupies the largest centered 3:2 rect.
import SwiftUI

/// Transparent single-touch pen overlay. Sits above the framebuffer view
/// and forwards down/move/up to the core handle.
struct TouchPenView: UIViewRepresentable {
    var session: EmulatorSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> PenView {
        let view = PenView()
        view.coordinator = context.coordinator
        view.isMultipleTouchEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PenView, context: Context) {}

    final class Coordinator {
        let session: EmulatorSession

        init(session: EmulatorSession) {
            self.session = session
        }

        /// Convert a touch point in `bounds` to guest coords, accounting
        /// for the aspect-fit letterbox. Returns nil outside the guest rect.
        static func guestCoords(_ point: CGPoint, in bounds: CGRect) -> (x: Int, y: Int)? {
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let fit = min(bounds.width / 480, bounds.height / 320)
            let w = 480 * fit
            let h = 320 * fit
            let ox = (bounds.width - w) / 2
            let oy = (bounds.height - h) / 2
            let gx = (point.x - ox) / w * 479
            let gy = (point.y - oy) / h * 319
            guard gx >= 0, gy >= 0, gx <= 479, gy <= 319 else { return nil }
            return (min(479, max(0, Int(gx))), min(319, max(0, Int(gy))))
        }

        func send(_ phase: PenPhase, point: CGPoint, bounds: CGRect) {
            guard let handle = session.handle,
                  let (x, y) = Self.guestCoords(point, in: bounds) else { return }
            corePen(handle, phase: phase, x: x, y: y)
        }
    }

    final class PenView: UIView {
        weak var coordinator: Coordinator?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            coordinator?.send(.down, point: touch.location(in: self), bounds: bounds)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            coordinator?.send(.move, point: touch.location(in: self), bounds: bounds)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let handle = coordinator?.session.handle else { return }
            // Pen-up carries no coords in the ABI: lift always releases,
            // wherever it lands, so the button can never latch.
            corePen(handle, phase: .up, x: 0, y: 0)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let handle = coordinator?.session.handle else { return }
            corePen(handle, phase: .up, x: 0, y: 0)
        }
    }
}
