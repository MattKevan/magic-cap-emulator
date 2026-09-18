// ToolbarView.swift — Power + Option Button with mac pulse semantics.
//
// Mechanism: the core ABI has no button entry point (9 functions:
// lifecycle + framebuffer + pen + package only), and the app target links
// libDataRoverCore.a statically, so it cannot reach MAME's ioport
// internals either. The buttons below therefore send the pen/touch events
// the guest already understands; a true hardware pulse
// (ioport_field::set_value(1) + 150ms delayed clear_value on
// POWER_BUTTON / OPTION_BUTTON, firing power_changed/option_changed
// exactly like the mac pulsePort in src/osd/sdl3/datarover_menu.mm:230
// and the KEYCODE_END / KEYCODE_LALT bindings) needs a small fork-side
// addition — proposed `datarover_press_power` / `datarover_press_option`
// in datarover_core.h/.cpp, Task 3 or a fork round. Until then the
// buttons are visible, tappable, and clearly marked unavailable.
import SwiftUI

/// Emulator toolbar: momentary Power + Option buttons.
///
/// Same pulse semantics as mac once the fork exposes the injection
/// point: press drives the port high, a 150ms delayed release clears it.
struct ToolbarView: View {
    /// Nil while the fork has no button ABI: buttons render disabled with
    /// a "needs core support" label so the gap is explicit, not silent.
    var pressPower: (() -> Void)?
    var pressOption: (() -> Void)?

    var body: some View {
        HStack(spacing: 24) {
            Button {
                pressPower?()
            } label: {
                Label("Power", systemImage: "power")
            }
            .disabled(pressPower == nil)

            Button {
                pressOption?()
            } label: {
                Label("Option", systemImage: "option")
            }
            .disabled(pressOption == nil)
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 8)
    }
}
