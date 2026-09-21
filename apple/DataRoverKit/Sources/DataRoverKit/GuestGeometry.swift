// Guest screen geometry: the 480x320 guest buffer is shown aspect-fit
// (letterboxed) inside the hosting view, so host points must have the
// letterbox offset removed before they become pen coordinates.
import CoreGraphics

public enum GuestGeometry {
    public static let width = 480
    public static let height = 320

    /// The aspect-fit rect the guest screen occupies inside `bounds`.
    public static func screenRect(in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let fit = min(bounds.width / CGFloat(width), bounds.height / CGFloat(height))
        let size = CGSize(width: CGFloat(width) * fit, height: CGFloat(height) * fit)
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Guest-space coordinate for a host point, or nil outside the guest
    /// screen (letterbox bars). Clamps inclusive at the right/bottom edge,
    /// matching the driver's defensive clamp.
    public static func guestCoords(point: CGPoint, in bounds: CGRect) -> (x: Int, y: Int)? {
        let rect = screenRect(in: bounds)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let gx = (point.x - rect.minX) / rect.width * CGFloat(width - 1)
        let gy = (point.y - rect.minY) / rect.height * CGFloat(height - 1)
        guard gx >= 0, gy >= 0, gx <= CGFloat(width - 1), gy <= CGFloat(height - 1) else { return nil }
        return (min(width - 1, max(0, Int(gx))), min(height - 1, max(0, Int(gy))))
    }
}
