// EmulatorControlsSheet.swift — Save / Restart / Load package.
import DataRoverKit
import SwiftUI

public struct EmulatorControlsSheet: View {
    @ObservedObject private var session: EmulatorSession
    private let loadPackage: () -> Void
    @Environment(\.dismiss) private var dismiss

    public init(session: EmulatorSession, loadPackage: @escaping () -> Void) {
        self.session = session
        self.loadPackage = loadPackage
    }

    public var body: some View {
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
