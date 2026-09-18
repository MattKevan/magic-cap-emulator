// DataRoverApp.swift — app entry: WindowGroup + toolbar + ROM picker placeholder.
//
// Wiring: on appear, resolve nvram/cfg/rom directories inside the app
// container and create the EmulatorSession (datarover_create boots the
// core on its own worker thread). The framebuffer view + touch overlay
// fill the window; the toolbar sits below. The ROM picker button is a
// placeholder — real fileImporter import (security-scoped copy into the
// container, Task 3) replaces `romURL` with the imported path.
import SwiftUI

@main
struct DataRoverApp: App {
    @StateObject private var session: EmulatorSession = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let nvram = base.appendingPathComponent("nvram").path
        let cfg = base.appendingPathComponent("cfg").path
        // Placeholder ROM path: Task 3's fileImporter supplies the real
        // user-imported image. Until then, boot from the bundled/known
        // container location if present.
        let rom = base.appendingPathComponent("roms/datarover.zip").path
        try? FileManager.default.createDirectory(atPath: nvram, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        return EmulatorSession(nvramDir: nvram, cfgDir: cfg, romPath: rom)
    }()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                ZStack {
                    EmulatorView(session: session)
                    TouchPenView(session: session)
                }
                .background(.black)
                // Power/Option need a fork button ABI (see ToolbarView):
                // pass nil so the buttons render disabled, not fake-live.
                ToolbarView(pressPower: nil, pressOption: nil)
                // ROM picker placeholder (Task 3 owns the real fileImporter).
                Button("Choose ROM…") {
                    // No-op: replaced by fileImporter in Task 3.
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 8)
            }
        }
    }
}
