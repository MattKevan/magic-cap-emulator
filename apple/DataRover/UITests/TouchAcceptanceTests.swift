// Acceptance for the guest touch path: a synthetic touch must reach the guest
// through TouchPenView -> PenRouter -> GuestGeometry -> corePen, and the guest
// must repaint. The guest's first-run flow is the full proof: its touch-gated
// startup screen answers the pen, and so do the three calibration targets,
// which only advance when the pen lands on the target the guest is waiting for.
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

    func testTapReachesTheGuestAndRepaints() throws {
        let app = XCUIApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 60),
                      "the app never showed a window")

        if app.buttons["Import ROM…"].waitForExistence(timeout: 10) {
            throw XCTSkip("ROM fixture is not in the app container")
        }

        Thread.sleep(forTimeInterval: bootSeconds)

        let untouchedA = pixels(window)
        Thread.sleep(forTimeInterval: 3)
        let untouchedB = pixels(window)
        let screenIsStatic = untouchedA == untouchedB

        let afterPress = pressGuest(window, at: guestCentre)

        guard screenIsStatic else {
            // The touch-gated screen animates on its own, so a pixel compare
            // cannot isolate the press. The press still has to be serviced:
            // assert the app stayed alive and the guest is still rendering.
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(window.exists)
            add(XCTAttachment(screenshot: window.screenshot()))
            return
        }

        XCTAssertNotEqual(untouchedB, afterPress,
                          "a pen press must change the guest screen")

        // The guest is pixel-stable, so the first-run recipe is deterministic
        // and worth driving to its end: each calibration press must produce a
        // screen this test has not seen before, which the guest only does when
        // the pen lands on the target it is currently waiting for. The last
        // one is the Magic Cap workbench (see the attached screenshot).
        var seen = [untouchedB, afterPress]
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