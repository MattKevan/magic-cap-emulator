// EmulatorBody.swift — guest screen + install banner + boot state.
import DataRoverKit
import SwiftUI

/// Guest screen + install banner + boot state, parameterized by the
/// platform's framebuffer and pen-overlay views.
public struct EmulatorBody<Framebuffer: View, Overlay: View>: View {
    @ObservedObject private var session: EmulatorSession
    private let framebuffer: () -> Framebuffer
    private let overlay: () -> Overlay

    public init(session: EmulatorSession,
                @ViewBuilder framebuffer: @escaping () -> Framebuffer,
                @ViewBuilder overlay: @escaping () -> Overlay) {
        self.session = session
        self.framebuffer = framebuffer
        self.overlay = overlay
    }

    public var body: some View {
        ZStack {
            Color.black
            if session.booting {
                ProgressView("Starting DataRover…").tint(.white).foregroundStyle(.white)
            } else if let error = session.bootError {
                Text(error).foregroundStyle(.white).padding()
            } else {
                framebuffer()
                overlay()
            }
            if session.installing || !session.packageMessage.isEmpty {
                InstallStatusBanner(session: session)
            }
        }
    }
}
