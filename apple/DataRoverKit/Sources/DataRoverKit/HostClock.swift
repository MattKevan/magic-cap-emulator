import Foundation

public enum HostClock {
    /// Magic Cap displays local calendar time; its separate time-zone settings
    /// are not the host's time zone. Preserve the host's local date across DST.
    public static func localMilliseconds(for date: Date, in timeZone: TimeZone = .current) -> Int64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return nil }
        let milliseconds = (seconds + Double(timeZone.secondsFromGMT(for: date))) * 1000
        guard (-2_208_988_800_000...253_402_300_799_999).contains(milliseconds) else { return nil }
        return Int64(milliseconds.rounded())
    }
}
