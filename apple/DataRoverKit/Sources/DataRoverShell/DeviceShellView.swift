// DeviceShellView.swift — the physical DataRover shell around the screen.
import DataRoverKit
import SwiftUI

/// The two side rails share the original device's Option input. The logo
/// on the left rail opens the controls in a popover beside it.
public struct DeviceShellView<Screen: View, Controls: View>: View {
    @ObservedObject private var session: EmulatorSession
    @Binding private var showsControls: Bool
    private let screen: () -> Screen
    private let controls: () -> Controls
    private let shell = Color(red: 74 / 255, green: 75 / 255, blue: 77 / 255)

    public init(session: EmulatorSession,
                showsControls: Binding<Bool>,
                @ViewBuilder screen: @escaping () -> Screen,
                @ViewBuilder controls: @escaping () -> Controls) {
        self.session = session
        _showsControls = showsControls
        self.screen = screen
        self.controls = controls
    }

    public var body: some View {
        GeometryReader { geometry in
            let rail = min(142.0, max(72.0, geometry.size.width * 0.163))
            let width = min(geometry.size.width - rail * 2 - 20, (geometry.size.height - 20) * 1.5)
            HStack(spacing: 0) {
                VStack {
                    OptionControl(side: 0, session: session)
                    Spacer(minLength: 12)
                    Button { showsControls.toggle() } label: {
                        Image("GeneralMagicLogo", bundle: .module)
                            .resizable().scaledToFit()
                            .frame(width: 64, height: 75)
                            .rotationEffect(.degrees(90))
                            .frame(width: min(76, rail - 20), height: 64)
                            // The logo is mostly transparent line art; without
                            // this a plain button only takes clicks on its strokes.
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("DataRover controls")
                    .popover(isPresented: $showsControls, arrowEdge: .trailing) { controls() }
                }
                .padding(.vertical, 24)
                .frame(width: rail)
                screen()
                    .frame(width: max(1, width), height: max(1, width / 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 5, y: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack {
                    OptionControl(side: 1, session: session)
                    Spacer(minLength: 12)
                }
                .padding(.vertical, 24)
                .frame(width: rail)
            }
            .background(shell)
        }
        .background(shell.ignoresSafeArea())
    }
}

private struct OptionControl: View {
    let side: Int
    @ObservedObject var session: EmulatorSession
    @GestureState private var pressed = false

    var body: some View {
        VStack(spacing: 6) {
            Text("OPTION").font(.custom("Helvetica-Bold", size: 12)).foregroundStyle(.white)
            ZStack {
                Image("OptionRing", bundle: .module).resizable().frame(width: 74, height: 74)
                Image("OptionFace", bundle: .module).resizable().frame(width: 64, height: 66).offset(y: 3)
            }
        }
            .frame(width: 74, height: 94)
            .brightness(pressed ? -0.15 : 0)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($pressed) { _, state, _ in state = true })
            .onChange(of: pressed) { down in session.option(side, pressed: down) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(side == 0 ? "Left Option" : "Right Option")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                session.option(side, pressed: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    session.option(side, pressed: false)
                }
            }
    }
}
