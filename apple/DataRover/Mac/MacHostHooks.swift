// macOS is not suspended mid-save, but App Nap will throttle it, and a quit
// during a save would cut it short; a process activity holds both off.
import DataRoverShell
import Foundation

final class MacHostHooks: HostHooks {
    func beginSaveAssertion() -> SaveAssertion {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Saving DataRover state")
        return SaveAssertion(activity)
    }

    func endSaveAssertion(_ assertion: SaveAssertion) {
        guard let activity = assertion.payload as? NSObjectProtocol else { return }
        ProcessInfo.processInfo.endActivity(activity)
    }
}
