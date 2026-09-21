import DataRoverShell
import MetalKit
import SwiftUI

/// Hosts the shared Metal presenter; MTKView exists on both platforms, so the
/// only per-platform part is this representable.
struct MetalFramebufferView: UIViewRepresentable {
    @ObservedObject var session: EmulatorSession

    func makeCoordinator() -> FramebufferPresenter { FramebufferPresenter(session: session) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        context.coordinator.attach(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.setPaused(session.isPaused)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: FramebufferPresenter) {
        coordinator.detach()
    }
}
