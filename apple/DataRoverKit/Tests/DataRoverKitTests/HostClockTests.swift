import Foundation
import Testing
@testable import DataRoverKit

@Suite struct HostClockTests {
    @Test func usesTheOffsetAtTheRequestedDate() throws {
        let london = try #require(TimeZone(identifier: "Europe/London"))
        let summer = Date(timeIntervalSince1970: 1_790_512_496.125)
        let winter = Date(timeIntervalSince1970: 1_767_225_600)
        #expect(HostClock.localMilliseconds(for: summer, in: london) == 1_790_516_096_125)
        #expect(HostClock.localMilliseconds(for: winter, in: london) == 1_767_225_600_000)
    }

    @Test func preservesDatesBeforeUnixEpochAndRejectsInvalidDates() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        #expect(HostClock.localMilliseconds(for: Date(timeIntervalSince1970: -1.5), in: utc) == -1500)
        #expect(HostClock.localMilliseconds(for: Date(timeIntervalSince1970: .infinity), in: utc) == nil)
        #expect(HostClock.localMilliseconds(for: Date(timeIntervalSince1970: .nan), in: utc) == nil)
    }
}
