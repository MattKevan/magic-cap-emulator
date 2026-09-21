import CoreGraphics
import Testing
@testable import DataRoverKit

@Suite struct GuestGeometryTests {
    /// Exact-fit bounds: the guest grid maps 1:1 apart from the last host
    /// pixel. The shipped mapping scales by (width-1), so x=479 gives
    /// 479/480*479 = 478.002 -> 478 and the guest's 480th column is
    /// unreachable. Pinned as-is: stage 1 must not change behavior.
    @Test func exactFitMapsCorners() {
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 320)
        #expect(GuestGeometry.guestCoords(point: CGPoint(x: 0, y: 0), in: bounds)! == (0, 0))
        #expect(GuestGeometry.guestCoords(point: CGPoint(x: 479, y: 319), in: bounds)! == (478, 318))
    }

    /// Letterboxed bounds: the guest rect is centered, so the pen must be
    /// offset by the bar height before scaling.
    @Test func letterboxOffsetsTheMapping() {
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 720) // 2x fit, 40pt bars
        let center = GuestGeometry.guestCoords(point: CGPoint(x: 480, y: 360), in: bounds)!
        #expect(center == (239, 159))
        let topLeftOfScreen = GuestGeometry.guestCoords(point: CGPoint(x: 0, y: 40), in: bounds)!
        #expect(topLeftOfScreen == (0, 0))
    }

    /// Points in the letterbox bars are outside the guest screen.
    @Test func pointsOutsideTheScreenAreRejected() {
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 720)
        #expect(GuestGeometry.guestCoords(point: CGPoint(x: 480, y: 20), in: bounds) == nil)
        #expect(GuestGeometry.guestCoords(point: CGPoint(x: 480, y: 700), in: bounds) == nil)
    }

    /// The right and bottom edges still clamp into range rather than rejecting.
    @Test func edgesClamp() {
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 720)
        #expect(GuestGeometry.guestCoords(point: CGPoint(x: 960, y: 680), in: bounds)! == (479, 319))
    }

    /// Degenerate bounds never produce coordinates.
    @Test func zeroBoundsAreRejected() {
        #expect(GuestGeometry.guestCoords(point: .zero, in: .zero) == nil)
    }

    @Test func screenRectIsCenteredAndAspectFit() {
        let rect = GuestGeometry.screenRect(in: CGRect(x: 0, y: 0, width: 960, height: 720))
        #expect(rect == CGRect(x: 0, y: 40, width: 960, height: 640))
    }
}
