// InstallStatusBanner.swift — install progress and result, over the screen.
import DataRoverKit
import SwiftUI

/// Install progress and result, overlaid on the guest screen. Tap to dismiss
/// a finished message.
public struct InstallStatusBanner: View {
    @ObservedObject private var session: EmulatorSession

    public init(session: EmulatorSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 10) {
            if session.installing {
                ProgressView(value: session.installProgress >= 0 ? Double(session.installProgress) / 100 : nil)
                    .progressViewStyle(.linear)
                    .frame(width: 240)
            }
            Text(session.packageMessage)
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        .padding()
        .onTapGesture { if !session.installing { session.clearPackageMessage() } }
        .accessibilityElement(children: .combine)
    }
}
