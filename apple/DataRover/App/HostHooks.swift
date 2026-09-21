// iOS holds a background task while a checkpoint save finishes; the app is
// otherwise suspended and the save would be cut short.
import DataRoverShell
import UIKit

final class iOSHostHooks: HostHooks {
    func beginSaveAssertion() -> SaveAssertion {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "Save DataRover",
                                                                expirationHandler: nil)
        return SaveAssertion(identifier)
    }

    func endSaveAssertion(_ assertion: SaveAssertion) {
        guard let identifier = assertion.payload as? UIBackgroundTaskIdentifier,
              identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
