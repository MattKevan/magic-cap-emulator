import SwiftUI

/// The two side rails share the original device's Option input.
struct DeviceShellView<Screen: View>: View {
    @ObservedObject var session: EmulatorSession
    var openMenu: () -> Void
    @ViewBuilder var screen: () -> Screen
    private let shell = Color(red: 74 / 255, green: 75 / 255, blue: 77 / 255)

    var body: some View {
        GeometryReader { geometry in
            let rail = min(142.0, max(72.0, geometry.size.width * 0.163))
            let width = min(geometry.size.width - rail * 2 - 20, (geometry.size.height - 20) * 1.5)
            HStack(spacing: 0) {
                VStack {
                    OptionControl(side: 0, session: session)
                    Spacer(minLength: 12)
                    Button(action: openMenu) {
                        Image("GeneralMagicLogo")
                            .resizable().scaledToFit()
                            .frame(width: 64, height: 75)
                            .rotationEffect(.degrees(90))
                            .frame(width: min(76, rail - 20), height: 64)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("DataRover controls")
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
                Image("OptionRing").resizable().frame(width: 74, height: 74)
                Image("OptionFace").resizable().frame(width: 64, height: 66).offset(y: 3)
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

struct EmulatorControlsSheet: View {
    @ObservedObject var session: EmulatorSession
    var loadPackage: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Save state", systemImage: "square.and.arrow.down") { session.saveNow() }
                    Button("Restart", systemImage: "arrow.clockwise") {
                        session.restart()
                        dismiss()
                    }
                    Button("Load package…", systemImage: "shippingbox") { loadPackage() }
                }
                Section {
                    Text(session.saveMessage.isEmpty ? "State is saved automatically when you leave the app." : session.saveMessage)
                        .foregroundStyle(.secondary)
                    Text("To install a package, open the Storeroom computer on the DataRover first, then choose the file here. The transfer runs while the DataRover is left on that screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("DataRover")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
