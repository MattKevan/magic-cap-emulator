import Testing
@testable import DataRoverKit

@Suite struct HostBatteryTests {
    @Test func rejectsUnavailableReadings() {
        #expect(HostBattery(level: -1, externalPower: false) == nil)
        #expect(HostBattery(level: .nan, externalPower: true) == nil)
        #expect(HostBattery(level: .infinity, externalPower: true) == nil)
        #expect(HostBattery(level: 1.1, externalPower: true) == nil)
    }

    @Test func preservesChargeAndPowerIndependently() {
        #expect(HostBattery(level: 0, externalPower: true)?.percentage == 0)
        #expect(HostBattery(level: 1, externalPower: false)?.percentage == 100)
        let battery = HostBattery(level: 0.426, externalPower: true)
        #expect(battery?.percentage == 43)
        #expect(battery?.externalPower == true)
    }
}
