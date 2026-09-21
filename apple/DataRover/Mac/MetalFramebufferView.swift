import DataRoverShell
import MetalKit
import SwiftUI

/// Hosts the shared Metal presenter; MTKView exists on both platforms, so the
/// only per-platform part is this representable.
struct MetalFramebufferView: NSViewRepresentable {
    @ObservedObject var session: EmulatorSession

    func makeCoordinator() -> FramebufferPresenter { FramebufferPresenter(session: session) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.setPaused(session.isPaused)
    }

    static func dismantleNSView(_ view: MTKView, coordinator: FramebufferPresenter) {
        coordinator.detach()
    }
}
