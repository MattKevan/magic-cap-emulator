// SaveState.swift — the save-status contract of the C ABI, as a Swift enum.
import Foundation

/// Status of the core's asynchronous state save (`datarover_save_status`).
public enum SaveState: Equatable {
    case idle
    case pending
    case saved
    case failed

    /// 0 not saved, 1 pending, 2 saved; anything else — including the core's
    /// -1 failure — is a failure.
    public static func decode(_ raw: Int32) -> SaveState {
        switch raw {
        case 0: return .idle
        case 1: return .pending
        case 2: return .saved
        default: return .failed
        }
    }
}
