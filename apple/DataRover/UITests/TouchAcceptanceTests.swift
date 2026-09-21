// Acceptance for the guest touch path: a synthetic touch must reach the guest
// through TouchPenView -> PenRouter -> GuestGeometry -> corePen, and the guest
// must repaint. The guest's first-run flow drives the rest of the proof: its
// touch-gated startup screen answers the pen, and so do the three calibration
// targets, which only advance when the pen lands on the target the guest is
// waiting for.
//
// Requires the ROM fixture in the app container; skips, rather than fails,
// when the app shows its "Import ROM…" empty state. It also requires a
// checkpoint-free container, because the guest restores from the app's
// checkpoint otherwise and no longer starts on its touch-gated screen:
//
//   rm -f "$(xcrun simctl get_app_container <udid> com.example.DataRover data)/Documents/cfg/session.sta"
//
// The app writes a checkpoint on every pause and every 60 s, and a restored
// checkpoint makes the guest render but ignore pen input — a pre-existing core
// save-state defect, not a fault in the touch path — so leaving one in place
// would fail this test for a reason outside the touch path. A fresh guest
// paints its power-on screen for ~15 s before it starts listening for the pen.
//
// Synthetic touches here are presses, not `XCUIElement.tap()`: a tap puts the
// pen down and up inside a single emulated frame, which the guest's pen input
// never samples, so the guest ignores it outright. A 0.5 s press is the
// shortest synthetic pen-down the guest reliably sees.
//
// The whole flow runs in one launch on purpose: two test methods would share
// the app container, so the first would leave the guest checkpointed mid-flow
// and the second would start from the wrong screen.
import XCTest

final class TouchAcceptanceTests: XCTestCase {
    /// Long enough for the guest to sample the pen down (see the note above on
    /// why `tap()` is not usable here).
    private let penPress: TimeInterval = 0.5

    /// The emulated machine ignores the pen until it finishes powering on. Its
    /// touch-gated startup screen appears ~15 s after launch on this fixture;
    /// allow 35 s so a cold first launch cannot fail the test.
    private let bootSeconds: TimeInterval = 35

    /// Window-relative points inside the guest screen, measured against the
    /// iPhone 17 Pro's 874x402 pt landscape window, whose letterboxed guest
    /// screen spans roughly x 0.22-0.78, y 0.07-0.93 of that window. The
    /// centre is inside the guest screen (the bezel and Option rails surround
    /// it) and dismisses the startup screen; the three calibration targets are
    /// the ones the guest asks for, in order: upper-left, lower-right, centre.
    private let guestCentre: (dx: CGFloat, dy: CGFloat) = (0.5, 0.5)
    private let calibrationTargets: [(dx: CGFloat, dy: CGFloat)] = [(dx: 0.25, dy: 0.14),
                                                                    (dx: 0.736, dy: 0.798),
                                                                    (dx: 0.5, dy: 0.475)]

    /// The window the calibration targets were measured against; the phase is
    /// skipped on anything else (see `testPressesReachTheGuestAndDriveCalibration`).
    private let calibratedWindow = CGSize(width: 874, height: 402)

    func testPressesReachTheGuestAndDriveCalibration() throws {
        let app = XCUIApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 60),
                      "the app never showed a window")

        if app.buttons["Import ROM…"].waitForExistence(timeout: 10) {
            throw XCTSkip("ROM fixture is not in the app container")
        }

        Thread.sleep(forTimeInterval: bootSeconds)

        // Two samples 3 s apart give the press a settled screen to change; on
        // this fixture the guest's startup screen is pixel-stable, so a pixel
        // compare isolates the press from anything the guest does on its own.
        let untouchedA = pixels(window)
        Thread.sleep(forTimeInterval: 3)
        let untouched = pixels(window)
        let wasStatic = untouchedA == untouched

        // The press is the acceptance claim, so it has to land for every guest
        // screen — not just a stable one. Three attempts cover a boot that is
        // still finishing; after that, silence means the pen path is broken.
        var afterPress = untouched
        var attempts = 0
        repeat {
            afterPress = pressGuest(window, at: guestCentre)
            attempts += 1
        } while afterPress == untouched && attempts < 3

        XCTAssertNotEqual(untouched, afterPress, """
            the guest screen never changed after \(attempts) presses — either the pen path is broken, \
            or the app never reached the guest screen (delete cfg/session.sta in the app container and \
            re-run). The screen was \(wasStatic ? "static" : "already changing") before the press.
            """)

        // The target fractions below are measured against this window. On any
        // other geometry the guest screen sits elsewhere, so the progression
        // cannot be asserted: say the phase was skipped rather than claim a
        // workbench arrival that was not verified.
        guard window.frame.size == calibratedWindow else {
            throw XCTSkip("""
                the centre press reached the guest, but the calibration phase is skipped: this window is \
                \(window.frame.size), not the calibrated \(calibratedWindow) iPhone 17 Pro landscape window
                """)
        }

        // Each calibration press must produce a screen this test has not seen
        // before, which the guest only does when the pen lands on the target it
        // is currently waiting for. The last one is the Magic Cap workbench
        // (see the attached screenshot).
        var seen = [untouched, afterPress]
        for target in calibrationTargets {
            let advanced = pressGuest(window, at: target)
            XCTAssertFalse(seen.contains(advanced),
                           "a press on the calibration target must advance the guest")
            seen.append(advanced)
        }

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Magic Cap workbench after the calibration presses"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pixels(_ window: XCUIElement) -> Data {
        window.screenshot().pngRepresentation
    }

    /// Holds the pen on a window-relative point, lets the guest repaint, and
    /// returns the guest's pixels afterwards.
    private func pressGuest(_ window: XCUIElement, at point: (dx: CGFloat, dy: CGFloat)) -> Data {
        window.coordinate(withNormalizedOffset: CGVector(dx: point.dx, dy: point.dy))
            .press(forDuration: penPress)
        Thread.sleep(forTimeInterval: 3)
        return pixels(window)
    }
}
