// EmulatorControls.swift — the DataRover controls shown from the logo.
import DataRoverKit
import SwiftUI

/// A popover on Mac and iPad. iPhone's compact width adapts the popover to a
/// sheet, which then needs its own title bar and Done button.
public struct EmulatorControls: View {
    @ObservedObject private var session: EmulatorSession
    private let loadPackage: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("datarover.network.enabled") private var networkEnabled = false

    public init(session: EmulatorSession, loadPackage: @escaping () -> Void) {
        self.session = session
        self.loadPackage = loadPackage
    }

    @ViewBuilder private var webBrowserStatus: some View {
        switch session.webBrowserSetup {
        case .idle:
            Text("Downloads Web Browser 4.0, JavaScript and the Ethernet driver, then installs them.")
                .font(.footnote).foregroundStyle(.secondary)
        case .downloading:
            Text("Downloading…").font(.footnote).foregroundStyle(.secondary)
        case .needsRelaunch:
            Text("Guest networking is on. Quit and reopen DataRover, then choose Install Web Browser again.")
                .font(.footnote)
        case .installing(let name):
            Text("Installing \(name). Open the Storeroom computer on the DataRover.").font(.footnote)
        case .installed:
            VStack(alignment: .leading, spacing: 4) {
                Text("Installed. To finish, on the DataRover:").font(.footnote)
                Text("1. Downtown, open the Internet Center and add a provider.").font(.footnote)
                Text("2. Add the EtherLink LAN connection with address 10.0.2.15.").font(.footnote)
                Text("3. On the provider’s locations tab, set home to use EtherLink LAN.").font(.footnote)
                Text("4. Open Web Browser and go to http://10.0.2.2/").font(.footnote)
            }
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.red)
        }
    }

    public var body: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            NavigationStack {
                form
                    .navigationTitle("DataRover")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        } else {
            form.frame(width: 380, height: 560)
        }
        #else
        // A Form has no ideal height of its own, so the popover states one.
        form.frame(width: 380, height: 560)
        #endif
    }

    private var form: some View {
        Form {
            Section {
                Button("Save state", systemImage: "square.and.arrow.down") { session.saveNow() }
                Button("Restart", systemImage: "arrow.clockwise") {
                    session.restart()
                    dismiss()
                }
                Button("Load package…", systemImage: "shippingbox") { loadPackage() }
            }
            Section {
                Button("Install Web Browser", systemImage: "globe") {
                    session.installWebBrowser()
                    dismiss()   // the guest must run to answer the Storeroom transfer
                }
                .disabled(session.installing || session.webBrowserSetup == .downloading)
                webBrowserStatus
                Toggle("Simplify pages", isOn: $session.simplifyPages)
                Text("Removes scripts and styles and shrinks images so modern sites fit. Turn off to see pages as sent.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Web browser")
            }
            Section {
                Toggle("Sync date and time with host", isOn: $session.syncHostClock)
                Text("Uses the host’s local date and time on launch and resume, including saved states.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !session.clockMessage.isEmpty {
                    Text(session.clockMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Mirror host battery", isOn: $session.mirrorHostBattery)
                Text("Matches the host’s battery level and external power. It never drops low enough for Magic Cap to turn off communications.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !session.batteryMessage.isEmpty {
                    Text(session.batteryMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Guest networking", isOn: $networkEnabled)
                Text("Enables the guest’s emulated Ethernet and an HTTPS proxy through the host. Takes effect the next time you launch DataRover.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(session.networkMessage).font(.footnote).foregroundStyle(.secondary)
                if !session.audioMessage.isEmpty {
                    Text(session.audioMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Bridges")
            }
            Section {
                Text(session.saveMessage.isEmpty ? "State is saved automatically when you leave the app." : session.saveMessage)
                    .foregroundStyle(.secondary)
                Text("To install a package, open the Storeroom computer on the DataRover first, then choose the file here. The transfer runs while the DataRover is left on that screen.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
