import DataRoverKit
import Foundation

/// Host observations live outside checkpoints and are sent through the queued ABI.
@MainActor
final class HostSyncController {
    private let handle: UnsafeMutableRawPointer
    private let batteryReader = HostBatteryReader()
    private let report: (String, String) -> Void
    private var task: Task<Void, Never>?
    private var batteryEnabled: Bool
    private var clockEnabled: Bool
    private var active: Bool
    private var batteryMessage = ""
    private var lastClockSample: (date: Date, uptime: TimeInterval, offset: Int)?

    init(handle: UnsafeMutableRawPointer, batteryEnabled: Bool, clockEnabled: Bool,
         active: Bool, report: @escaping (String, String) -> Void) {
        self.handle = handle
        self.batteryEnabled = batteryEnabled
        self.clockEnabled = clockEnabled
        self.active = active
        self.report = report
        refresh(forceClock: true)
        let reader = batteryReader
        task = Task { @MainActor [weak self] in
            defer { _ = reader.read(enabled: false) }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.refresh()
            }
        }
    }

    func update(batteryEnabled: Bool, clockEnabled: Bool, active: Bool) {
        if batteryEnabled, !self.batteryEnabled, !active {
            batteryMessage = "Host battery will refresh when you resume."
        }
        // Resend the calendar on resume or when sync is switched on; other
        // setting changes leave the guest's running clock alone.
        let forceClock = (active && !self.active) || (clockEnabled && !self.clockEnabled)
        self.batteryEnabled = batteryEnabled
        self.clockEnabled = clockEnabled
        self.active = active
        refresh(forceClock: forceClock)
    }

    private func refresh(forceClock: Bool = false) {
        if !batteryEnabled {
            _ = batteryReader.read(enabled: false)
            coreSetHostBattery(handle, battery: nil)
            batteryMessage = ""
        } else if active {
            let battery = batteryReader.read(enabled: true)
            coreSetHostBattery(handle, battery: battery)
            if let battery {
                batteryMessage = "Host battery: \(battery.percentage)% · \(battery.externalPower ? "External power" : "Battery power")"
            } else {
                batteryMessage = "Host battery unavailable; using the emulated battery."
            }
        } else {
            _ = batteryReader.read(enabled: false)
        }

        if !clockEnabled {
            coreSetHostClock(handle, enabled: false)
            lastClockSample = nil
        } else if active {
            let date = Date()
            let uptime = ProcessInfo.processInfo.systemUptime
            let offset = TimeZone.current.secondsFromGMT(for: date)
            // A host clock or time-zone change needs a fresh request. Normal
            // ticking does not continually overwrite the guest's calendar.
            let changed = lastClockSample.map {
                abs(date.timeIntervalSince($0.date) - (uptime - $0.uptime)) > 2 || offset != $0.offset
            } ?? true
            if forceClock || changed { coreSetHostClock(handle, enabled: true, date: date) }
            lastClockSample = (date, uptime, offset)
        } else {
            lastClockSample = nil
        }

        let clockMessage: String
        if !clockEnabled {
            clockMessage = ""
        } else {
            switch coreHostClockStatus(handle) {
            case 2: clockMessage = "Date and time synchronized with host."
            case -1: clockMessage = "Clock sync is unavailable for this ROM or guest state."
            default: clockMessage = "Clock sync will finish when Magic Cap is ready."
            }
        }
        report(batteryMessage, clockMessage)
    }

    deinit { task?.cancel() }
}
