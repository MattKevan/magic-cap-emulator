/// A valid host charge observation. Unknown readings never become an empty cell.
public struct HostBattery: Equatable, Sendable {
    public let percentage: Int
    public let externalPower: Bool

    public init?(level: Double, externalPower: Bool) {
        guard level.isFinite, (0...1).contains(level) else { return nil }
        percentage = Int((level * 100).rounded())
        self.externalPower = externalPower
    }
}
