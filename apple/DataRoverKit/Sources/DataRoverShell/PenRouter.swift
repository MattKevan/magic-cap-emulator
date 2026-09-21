// PenRouter.swift — host pointer events to guest pen events.
import CoreGraphics
import DataRoverKit

/// Forwards host pointer events to the core as guest pen events, removing
/// the aspect-fit letterbox offset first. One instance per host view.
public final class PenRouter {
    private let session: EmulatorSession

    public init(session: EmulatorSession) { self.session = session }

    public func send(_ phase: PenPhase, point: CGPoint, bounds: CGRect) {
        guard let handle = session.handle,
              let (x, y) = GuestGeometry.guestCoords(point: point, in: bounds) else { return }
        corePen(handle, phase: phase, x: x, y: y)
    }

    /// Pen-up carries no coordinates in the ABI: lifting always releases.
    public func lift() {
        guard let handle = session.handle else { return }
        corePen(handle, phase: .up, x: 0, y: 0)
    }
}
