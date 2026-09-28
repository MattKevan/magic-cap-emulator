import DataRoverKit
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit.ps
#endif

/// Read only the computer's own battery, excluding UPS and accessory batteries.
@MainActor
final class HostBatteryReader {
    #if os(iOS)
    private var enabledMonitoring = false
    #endif

    func read(enabled: Bool) -> HostBattery? {
        #if os(iOS)
        let device = UIDevice.current
        if enabled, !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
            enabledMonitoring = true
        } else if !enabled, enabledMonitoring {
            device.isBatteryMonitoringEnabled = false
            enabledMonitoring = false
        }
        guard enabled, device.batteryState != .unknown else { return nil }
        return HostBattery(level: Double(device.batteryLevel),
                           externalPower: device.batteryState == .charging || device.batteryState == .full)
        #elseif os(macOS)
        guard enabled,
              let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0,
                  let power = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            return HostBattery(level: current.doubleValue / maximum.doubleValue,
                               externalPower: power == kIOPSACPowerValue)
        }
        return nil
        #else
        return nil
        #endif
    }
}
