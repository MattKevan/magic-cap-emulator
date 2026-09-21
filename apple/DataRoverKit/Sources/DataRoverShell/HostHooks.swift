// HostHooks.swift — the platform services the session needs from its host.
//
// The session saves state on its worker whenever the app leaves the
// foreground; a suspended process would be killed mid-save. What keeps the
// process alive is platform-specific (an iOS background task, a macOS
// activity), so the host supplies it.
import Foundation

/// A platform-held assertion that keeps the process alive while a save
/// finishes: an iOS background task, a macOS activity, or nothing.
public final class SaveAssertion {
    public let payload: Any
    public init(_ payload: Any) { self.payload = payload }
}

public protocol HostHooks: AnyObject {
    func beginSaveAssertion() -> SaveAssertion
    func endSaveAssertion(_ assertion: SaveAssertion)
}

/// Default for platforms that are never suspended mid-save.
public final class NoOpHostHooks: HostHooks {
    public init() {}
    public func beginSaveAssertion() -> SaveAssertion { SaveAssertion(()) }
    public func endSaveAssertion(_ assertion: SaveAssertion) {}
}
